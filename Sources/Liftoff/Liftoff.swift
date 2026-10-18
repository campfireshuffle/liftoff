import AppKit
import QuartzCore

/// Wires input, snapshots, physics, rendering and sound together, and owns the frame loop.
@MainActor
final class Liftoff: NSObject {
    let input = InputTap()
    let hiss = Hiss()
    private let world = World()
    let renderer = Renderer()
    private(set) var held: Body?
    var scriptedDriver: CGImage?  // set by the driver debug hook
    var stagedApps: Set<String>?  // set by the cast debug hook: only these apps' windows count
    var afterTouchdown: (() -> Void)?  // set by the debug hooks to chain staged beats
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    let isDebugging = UserDefaults.standard.bool(forKey: "debugHooks")

    override init() {
        super.init()
        world.bounds = WindowSystem.desktopBounds
        world.floors = WindowSystem.usableAreas
        world.onTouchdown = { [weak self] body in
            self?.renderer.burst(under: body)
            self?.hiss.puff()
            self?.afterTouchdown?()
            self?.afterTouchdown = nil
        }
        world.onLanded = { [weak self] body in self?.putBack(body) }

        input.modifier = { Settings.grabKey.flags }
        input.onModifierPressed = { Snapshotter.prefetch() }
        input.onDown = { [weak self] in self?.grab(at: Vec($0)) ?? false }
        input.onDrag = { [weak self] in self?.drag(to: Vec($0)) }
        input.onUp = { [weak self] _ in self?.release() }

        hiss.isEnabled = Settings.soundEnabled
        makeDisplayLink()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        if isDebugging { listenForScriptedThrows() }
    }

    // MARK: Hand

    func grab(at point: Vec, windowID: CGWindowID? = nil) -> Bool {
        let now = CACurrentMediaTime()
        if let body = world.body(at: point) {
            world.grab(body, cursor: point, time: now)
            held = body
            wake()
            return true
        }

        guard Permissions.screenRecording,
              let info = windowID.flatMap({ id in WindowSystem.onScreenWindows().first { $0.id == id } })
                ?? WindowSystem.window(at: point.cgPoint),
              let element = WindowSystem.element(for: info)
        else { return false }

        let body = Body(window: info, element: element)
        world.add(body)
        world.grab(body, cursor: point, time: now)
        held = body
        hiss.prewarm()
        wake()

        Task { @MainActor in
            guard let image = await Snapshotter.capture(info.id) else {
                world.remove(body)
                if held === body { held = nil }
                return
            }
            guard world.contains(body) else { return }
            body.image = image
            renderer.sync(world.bodies)  // the snapshot covers the window before it moves
            body.isParked = true
            WindowSystem.moveInBackground(body.element, pid: body.pid, to: WindowSystem.parkingSpot)
        }
        return true
    }

    func drag(to point: Vec) {
        guard let held else { return }
        world.drag(held, cursor: point, time: CACurrentMediaTime())
    }

    func release() {
        guard let body = held else { return }
        held = nil
        let flying = Set(world.bodies.map(\.windowID))
        let screenArea = world.bounds.width * world.bounds.height
        let obstacles = WindowSystem.onScreenWindows()
            .filter { !flying.contains($0.id) && $0.frame.width * $0.frame.height < screenArea * 0.6 }
            .filter { window in
                guard let stagedApps else { return true }
                let name = NSRunningApplication(processIdentifier: window.pid)?.localizedName?.lowercased() ?? ""
                return stagedApps.contains(name)
            }
            .map(\.frame)
        world.landsAnywhere = Settings.landsAnywhere
        world.release(body, time: CACurrentMediaTime(), obstacles: obstacles)
        if isDebugging {
            logger.notice("Released at \(Int(body.velocity.x), privacy: .public),\(Int(body.velocity.y), privacy: .public) px/s, spin \(body.spin, privacy: .public), \(body.nearbyWindows.count, privacy: .public) windows around")
        }
        wake()
    }

    // MARK: Landing

    private func putBack(_ body: Body) {
        guard body.isParked else {
            world.remove(body)
            return
        }
        WindowSystem.moveInBackground(body.element, pid: body.pid, to: body.destinationOrigin, raise: true) { [weak self] in
            // Give the window server a couple of frames to show the real window before the snapshot goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let self else { return }
                self.world.remove(body)
                self.renderer.sync(self.world.bodies)
            }
        }
    }

    /// Puts every flying window where it was headed, immediately, so none is left parked off-screen
    /// when Liftoff quits or the displays change.
    func landEverythingNow() {
        held = nil
        for body in world.bodies {
            if body.isParked { WindowSystem.move(body.element, pid: body.pid, to: body.destinationOrigin) }
            world.remove(body)
        }
        renderer.sync(world.bodies)
    }

    // MARK: Frame loop

    private func makeDisplayLink() {
        displayLink?.invalidate()
        guard let view = renderer.stages.first?.view else { return }
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
    }

    private func wake() {
        guard let displayLink, displayLink.isPaused else { return }
        lastFrame = nil
        displayLink.isPaused = false
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        if isDebugging, let lastFrame, now - lastFrame > 0.025 {
            logger.notice("Slow frame: \(Int((now - lastFrame) * 1000), privacy: .public) ms")
        }
        let dt = lastFrame.map { min(now - $0, 1.0 / 20) } ?? 1.0 / 120
        lastFrame = now

        world.step(dt)
        renderer.sync(world.bodies)
        if isDebugging { traceFlights(now) }
        let throttle = world.bodies.reduce(0) { $0 + $1.totalThrust.length } / 6000
        hiss.set(throttle)

        if world.bodies.isEmpty {
            hiss.set(0)
            link.isPaused = true
        }
    }

    private var lastTrace: CFTimeInterval = 0

    private func traceFlights(_ now: CFTimeInterval) {
        guard now - lastTrace > 0.03 else { return }
        lastTrace = now
        for body in world.bodies where body.phase != .settled {
            logger.notice("Trace \(body.windowID, privacy: .public) \(String(describing: body.phase), privacy: .public) pos=\(Int(body.position.x), privacy: .public),\(Int(body.position.y), privacy: .public) top=\(Int(body.position.y - body.size.y / 2), privacy: .public) dest=\(Int(body.destination.x), privacy: .public),\(Int(body.destination.y), privacy: .public) v=\(Int(body.velocity.x), privacy: .public),\(Int(body.velocity.y), privacy: .public) squash=\(String(format: "%.3f", body.squash), privacy: .public) aim=\(Int(body.steeringTarget.x), privacy: .public),\(Int(body.steeringTarget.y), privacy: .public) obstacles=\(body.obstacles.count, privacy: .public) down=\(body.hasTouchedDown, privacy: .public)")
        }
    }

    func aimNextLanding(at x: Double?) {
        world.landingHint = x
    }

    func refreshFloors() {
        world.floors = WindowSystem.usableAreas
    }

    private func screensChanged() {
        landEverythingNow()
        world.bounds = WindowSystem.desktopBounds
        world.floors = WindowSystem.usableAreas
        renderer.rebuild()
        makeDisplayLink()
    }
}
