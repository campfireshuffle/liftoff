import AppKit

/// Scripting hooks for tests and for staging demo recordings. Off unless
/// `defaults write run.lil.liftoff debugHooks -bool true`. Each is a distributed notification whose
/// object is a comma-separated string; a window "target" is a window ID, `title:Some Title` or `app:App Name`.
extension Liftoff {
    func listenForScriptedThrows() {
        // "dx,dy,vx,vy,target": grabs the target at (dx, dy) from its center and flings it at (vx, vy) px/s.
        // The older "x,y,vx,vy[,windowID]" form grabs at an absolute screen point.
        listen("run.lil.liftoff.throw") { [weak self] parts in
            let numbers = parts.prefix(4).compactMap(Double.init)
            guard numbers.count == 4 else { return }
            var start = Vec(numbers[0], numbers[1])
            var windowID: CGWindowID?
            if parts.count > 4 {
                guard let window = Self.findWindow(parts[4]) else { return }
                windowID = window.id
                if CGWindowID(parts[4]) == nil { start += Vec(window.frame.midX, window.frame.midY) }
            }
            self?.scriptedThrow(from: start, velocity: Vec(numbers[2], numbers[3]), windowID: windowID)
        }
        // "target,x,y[,width,height]": moves (and optionally resizes) a window; x, y is its top-left corner.
        listen("run.lil.liftoff.place") { parts in
            let numbers = parts.dropFirst().compactMap(Double.init)
            guard parts.count >= 3, numbers.count == parts.count - 1,
                  let window = Self.findWindow(parts[0]), let element = WindowSystem.element(for: window)
            else { return }
            if numbers.count == 4 { WindowSystem.resize(element, to: CGSize(width: numbers[2], height: numbers[3])) }
            WindowSystem.move(element, pid: window.pid, to: CGPoint(x: numbers[0], y: numbers[1]))
        }
        // "path or emoji": a face to ride along in the corner of the next scripted throw. Empty clears it.
        listen("run.lil.liftoff.driver") { [weak self] parts in
            self?.scriptedDriver = parts.first.flatMap { $0.isEmpty ? nil : Props.face($0) }
        }
        // "points": raises the floor that windows land and park on, to frame a recording. 0 resets it.
        listen("run.lil.liftoff.floor") { [weak self] parts in
            WindowSystem.floorLift = parts.first.flatMap(Double.init).map { CGFloat($0) } ?? 0
            self?.refreshFloors()
        }
        // "on" or "off": a simplified menu bar drawn over the real one, so recordings don't show
        // your status items or whichever app happens to be frontmost.
        listen("run.lil.liftoff.menubar") { [weak self] parts in
            self?.renderer.showMenuBar(parts.first == "on")
        }
        // "x": the next throw aims to land with its center near this x (it still looks for a clear
        // spot there). Empty clears it.
        listen("run.lil.liftoff.landat") { [weak self] parts in
            self?.aimNextLanding(at: parts.first.flatMap(Double.init))
        }
        // "App;App;…": only these apps' windows count as things to avoid and land on, so windows
        // hidden from a recording don't steer the flight. Empty goes back to every window.
        listen("run.lil.liftoff.cast") { [weak self] parts in
            let names = (parts.first ?? "").split(separator: ";").map { $0.lowercased() }
            self?.stagedApps = names.isEmpty ? nil : Set(names)
        }
        // "seconds,dx,dy,vx,vy,target[,landX]": the same throw, fired that long after the next touchdown,
        // so staged beats keep their rhythm however long each flight takes. landX aims its landing.
        listen("run.lil.liftoff.after") { [weak self] parts in
            guard parts.count >= 6, let delay = Double(parts[0]) else { return }
            let throwParts = Array(parts[1...5])
            let landX = parts.count > 6 ? Double(parts[6]) : nil
            self?.afterTouchdown = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if let landX { self?.aimNextLanding(at: landX) }
                    DistributedNotificationCenter.default().postNotificationName(
                        Notification.Name("run.lil.liftoff.throw"), object: throwParts.joined(separator: ","),
                        userInfo: nil, deliverImmediately: true)
                }
            }
        }
        // "gap,entry;entry;…" with each entry "target|width|height[|x]": parks windows side by side on the
        // floor of the main display, left to right, packing by each window's real size after resizing
        // (some apps won't go small). An x pins that window's left edge instead.
        listen("run.lil.liftoff.lineup") { parts in
            guard parts.count == 2, let gap = Double(parts[0]), let area = WindowSystem.usableAreas.first else { return }
            var cursor = Double(area.minX)
            for entry in parts[1].split(separator: ";") {
                let fields = entry.split(separator: "|").map(String.init)
                guard fields.count >= 3, let width = Double(fields[1]), let height = Double(fields[2]),
                      let window = Self.findWindow(fields[0]), let element = WindowSystem.element(for: window)
                else { continue }
                WindowSystem.resize(element, to: CGSize(width: width, height: height))
                let size = WindowSystem.frame(of: element)?.size ?? CGSize(width: width, height: height)
                let x = fields.count > 3 ? Double(area.minX) + (Double(fields[3]) ?? 0) : cursor
                WindowSystem.move(element, pid: window.pid, to: CGPoint(x: x, y: area.maxY - size.height))
                cursor = x + size.width + gap
            }
        }
        // "path,seconds[,keep;keep…]": records the main display to a movie for that long, leaving out
        // every app with windows on screen except the kept ones (app names or bundle identifiers).
        listen("run.lil.liftoff.record") { parts in
            guard parts.count >= 2, let seconds = Double(parts[1]) else { return }
            let keep = parts.count > 2 ? parts[2].split(separator: ";").map(String.init) : []
            guard #available(macOS 15, *) else { return }
            Task { await Recorder().record(to: URL(fileURLWithPath: parts[0]), seconds: seconds, keep: keep) }
        }
        // "directory,count,interval": saves that many screenshots of the main display, overlay included.
        listen("run.lil.liftoff.filmstrip") { parts in
            guard parts.count == 3, let count = Int(parts[1]), let interval = Double(parts[2]) else { return }
            Task { await Snapshotter.filmstrip(to: URL(fileURLWithPath: parts[0]), count: count, interval: interval) }
        }
    }

    private func listen(_ name: String, _ handler: @escaping @MainActor ([String]) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { note in
            let parts = (note.object as? String)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            MainActor.assumeIsolated { handler(parts) }
        }
    }

    private static func findWindow(_ target: String) -> WindowInfo? {
        let windows = WindowSystem.onScreenWindows()
        if let id = CGWindowID(target) { return windows.first { $0.id == id } }
        if target.hasPrefix("app:") {
            let name = target.dropFirst(4).lowercased()
            return windows.first { NSRunningApplication(processIdentifier: $0.pid)?.localizedName?.lowercased() == name }
        }
        if target.hasPrefix("title:") {
            let title = target.dropFirst(6).lowercased()
            return windows.first { window in
                guard let element = WindowSystem.element(for: window) else { return false }
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
                return (value as? String)?.lowercased().contains(title) == true
            }
        }
        return nil
    }

    /// Plays a hand-like throw with a drawn pointer, so a recording shows the gesture: a curved
    /// approach, a small pick-up and wind-back, then an accelerating flick. The real cursor isn't touched.
    private func scriptedThrow(from start: Vec, velocity: Vec, windowID: CGWindowID?) {
        let frame = 1.0 / 60
        let jitter = { (size: Double) in Vec(Double.random(in: -size...size), Double.random(in: -size...size)) }

        // Approach like a hand on a trackpad: a wandering curve at uneven speed, overshooting the
        // window a touch and correcting back onto it.
        // The hand comes in from below, on the side the throw heads away from.
        let side = velocity.x >= 0 ? 1.0 : -1.0
        let from = start + Vec(-260 * side, 210), bend = start + Vec(-20 * side, 220)
        let overshoot = start + Vec(9 * side, -6)
        let wander = (Double.random(in: 0..<6), Double.random(in: 0..<6))
        var approach: [Vec] = []
        var t = 0.0
        while t < 1 {
            t = min(1, t + frame / 0.62 * Double.random(in: 0.55...1.45))
            let s = 1 - pow(1 - t, 2.6)
            var point = from * pow(1 - s, 2) + bend * (2 * s * (1 - s)) + overshoot * (s * s)
            point += Vec(sin(9 * t + wander.0), cos(7 * t + wander.1)) * (7 * (1 - s)) + jitter(2.5)
            approach.append(point)
        }
        for i in 1...6 { approach.append(overshoot + (start - overshoot) * (Double(i) / 6) + jitter(1.2)) }
        for (i, point) in approach.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * frame) { [weak self] in
                self?.renderer.showPointer(at: point)
            }
        }
        let approachTime = Double(approach.count) * frame

        DispatchQueue.main.asyncAfter(deadline: .now() + approachTime + 0.12) { [weak self] in
            guard let self, grab(at: start, windowID: windowID) else { return }
            held?.driver = scriptedDriver
            renderer.showPointer(at: start + jitter(1), pressed: true)

            // Hand path after the grab: lift a touch, pull back like a slingshot, then flick.
            let direction = velocity.normalized
            let windUp = start + Vec(0, -14) - direction * 45
            var path: [Vec] = []
            let lift = 0.28, flick = 0.13
            for i in 1...Int(lift / frame) {
                let t = Double(i) * frame / lift, s = t * t * (3 - 2 * t)
                path.append(start + (windUp - start) * s + jitter(2))
            }
            // Accelerate from rest so the speed over the last tenth of a second matches the throw.
            var point = windUp, speed = Vec.zero
            let steps = Int(flick / frame)
            for _ in 1...steps {
                speed += velocity * (1.6 / Double(steps))
                point += speed * frame
                path.append(point + jitter(3))
            }
            for (i, point) in path.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i + 1) * frame) { [weak self] in
                    self?.renderer.showPointer(at: point, pressed: true)
                    self?.drag(to: point)
                    if i == path.count - 1 {
                        self?.release()
                        self?.renderer.showPointer(at: point)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(path.count) * frame + 0.7) { [weak self] in
                self?.renderer.showPointer(at: nil)
            }
        }
    }
}
