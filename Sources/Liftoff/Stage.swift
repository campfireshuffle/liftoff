import AppKit
import QuartzCore

/// Draws every flying window, its gas jets and landing smoke, with one click-through overlay per display.
@MainActor
final class Renderer {
    private(set) var stages: [Stage] = []

    init() { rebuild() }

    func rebuild() {
        stages.forEach { $0.close() }
        stages = NSScreen.screens.map(Stage.init)
    }

    func sync(_ bodies: [Body]) {
        for stage in stages { stage.sync(bodies) }
    }

    func showMenuBar(_ show: Bool) {
        stages.first?.showMenuBar(show)
    }

    /// A big drawn pointer for recordings, so the gesture reads on a phone. nil hides it.
    func showPointer(at point: Vec?, pressed: Bool = false) {
        for stage in stages { stage.showPointer(at: point, pressed: pressed) }
    }

    func burst(under body: Body) {
        burst(at: body.destination + Vec(0, body.size.y / 2), width: body.size.x)
    }

    func burst(at bottom: Vec, width: Double) {
        for stage in stages { stage.burst(at: bottom, width: width) }
    }

    /// Jets that aren't attached to a flying window, for Liftoff's own windows (the welcome
    /// window's arrival). They fire straight down.
    func showFreeJets(ports: [Vec], throttle: Double) {
        stages.first?.showFreeJets(ports: ports, throttle: throttle)
    }

    func hideFreeJets() {
        stages.first?.hideFreeJets()
    }
}

@MainActor
final class Stage {
    private struct Sprite {
        let window: CALayer
        let jets: [CAEmitterLayer]
        let ground: [CAEmitterLayer]  // left and right bottom edges
    }

    let view: NSView
    private let window: NSWindow
    private let frame: CGRect  // global top-left coordinates
    private let scale: CGFloat
    private let jetLayer = CALayer()
    private let windowLayer = CALayer()
    private let smokeLayer = CALayer()
    private var sprites: [ObjectIdentifier: Sprite] = [:]
    private lazy var pointer: CALayer = {
        let image = Props.pointer(height: 34, scale: scale)
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = scale
        layer.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        layer.anchorPoint = Props.pointerTip
        layer.opacity = 0
        view.layer?.addSublayer(layer)
        return layer
    }()

    init(screen: NSScreen) {
        frame = WindowSystem.cgFrame(of: screen)
        scale = screen.backingScaleFactor

        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let root = CALayer()
        view.layer = root
        view.wantsLayer = true
        for layer in [jetLayer, windowLayer, smokeLayer] {
            layer.frame = root.bounds
            root.addSublayer(layer)
        }
        window.contentView = view
        window.orderFrontRegardless()
    }

    func close() { window.close() }

    private var menuBar: CALayer?
    private var freeJets: [CAEmitterLayer] = []

    func showFreeJets(ports: [Vec], throttle: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while freeJets.count < ports.count {
            let jet = Particles.jet(in: jetLayer.bounds)
            view.layer?.addSublayer(jet)
            freeJets.append(jet)
        }
        for (jet, port) in zip(freeJets, ports) {
            jet.emitterPosition = local(port)
            jet.birthRate = Float(throttle * Double.random(in: 0.85...1.15))
            jet.setValue(longitude(Vec(0, 1)), forKeyPath: "emitterCells.gas.emissionLongitude")
            jet.setValue(longitude(Vec(0, 1)), forKeyPath: "emitterCells.haze.emissionLongitude")
        }
        CATransaction.commit()
    }

    func hideFreeJets() {
        let jets = freeJets
        freeJets = []
        for step in 1...10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(step)) {
                jets.forEach { $0.birthRate = step == 10 ? 0 : $0.birthRate * 0.7 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { jets.forEach { $0.removeFromSuperlayer() } }
    }

    func showMenuBar(_ show: Bool) {
        menuBar?.removeFromSuperlayer()
        menuBar = nil
        guard show, let root = view.layer else { return }
        // The real menu bar's height is the gap above the usable area.
        let barHeight = WindowSystem.usableAreas.first.map { clamp($0.minY - frame.minY, 24, 40) } ?? 30
        let layer = CALayer()
        layer.frame = CGRect(x: 0, y: frame.height - barHeight, width: frame.width, height: barHeight)
        layer.contents = Props.menuBar(size: layer.frame.size, scale: scale)
        layer.contentsScale = scale
        root.addSublayer(layer)
        menuBar = layer
    }

    func showPointer(at point: Vec?, pressed: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        if let point {
            CATransaction.setDisableActions(pointer.opacity == 0)
            pointer.position = local(point)
            pointer.opacity = 1
        } else {
            pointer.opacity = 0
        }
        pointer.setAffineTransform(pressed ? CGAffineTransform(scaleX: 0.86, y: 0.86) : .identity)
        CATransaction.commit()
    }

    /// Global top-left point to this overlay's bottom-left layer space.
    private func local(_ point: Vec) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
    }

    /// Emission angle in layer space for a direction in global space.
    private func longitude(_ direction: Vec) -> CGFloat {
        atan2(-direction.y, direction.x)
    }

    func sync(_ bodies: [Body]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var alive = Set<ObjectIdentifier>()
        for body in bodies {
            guard let image = body.image else { continue }
            let key = ObjectIdentifier(body)
            alive.insert(key)
            let sprite = sprites[key] ?? makeSprite(image: image, for: body, key: key)

            // Squash keeps the bottom edge planted: shorter and a touch wider, centered lower.
            let squash = body.squash
            sprite.window.position = local(body.position + body.axisY * (body.size.y * squash / 2))
            let lift: CGFloat = body.phase == .held ? 1.03 : 1
            sprite.window.setAffineTransform(
                CGAffineTransform(rotationAngle: -body.angle)
                    .scaledBy(x: lift * (1 + squash * 0.5), y: lift * (1 - squash)))
            sprite.window.shadowRadius = body.phase == .settled ? 12 : 28
            updateJets(sprite.jets, for: body)
            for (blast, outward) in zip(sprite.ground, [-1.0, 1.0]) {
                let edge = Vec(body.position.x + outward * (body.size.x / 2 - 12), body.destination.y + body.size.y / 2 - 4)
                blast.emitterPosition = local(edge)
                blast.birthRate = Float(body.groundEffect)
            }
        }
        for (key, sprite) in sprites where !alive.contains(key) {
            retire(sprite)
            sprites[key] = nil
        }
        CATransaction.commit()
    }

    private func makeSprite(image: CGImage, for body: Body, key: ObjectIdentifier) -> Sprite {
        let size = body.size
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.contentsScale = scale
        layer.bounds = CGRect(x: 0, y: 0, width: size.x, height: size.y)
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowOffset = .zero
        layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        windowLayer.addSublayer(layer)
        if let driver = body.driver { layer.addSublayer(driverCam(driver, on: layer.bounds.size)) }

        let jets = (0..<4).map { _ in Particles.jet(in: jetLayer.bounds) }
        jets.forEach(jetLayer.addSublayer)
        // Behind the window, so the blast appears to billow out from underneath it.
        let ground = [-1.0, 1.0].map { Particles.groundBlast(in: jetLayer.bounds, outward: $0) }
        ground.forEach(jetLayer.addSublayer)
        let sprite = Sprite(window: layer, jets: jets, ground: ground)
        sprites[key] = sprite
        return sprite
    }

    /// A round face bubble poking out of the window's top-right corner, like a stream's facecam.
    /// It's a sublayer, so it flips and squashes along with the window.
    private func driverCam(_ face: CGImage, on window: CGSize) -> CALayer {
        let side = min(130, min(window.width, window.height) * 0.45)
        let bubble = CALayer()
        bubble.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        bubble.position = CGPoint(x: window.width - side * 0.3, y: window.height - side * 0.3)
        bubble.cornerRadius = side / 2
        bubble.backgroundColor = CGColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 1)
        bubble.borderColor = CGColor(gray: 1, alpha: 1)
        bubble.borderWidth = 3
        bubble.shadowOpacity = 0.4
        bubble.shadowRadius = 10
        bubble.shadowOffset = .zero

        let photo = CALayer()
        photo.frame = bubble.bounds.insetBy(dx: 3, dy: 3)
        photo.cornerRadius = photo.frame.width / 2
        photo.masksToBounds = true
        photo.contents = face
        photo.contentsGravity = .resizeAspectFill
        bubble.addSublayer(photo)
        return bubble
    }

    private func updateJets(_ jets: [CAEmitterLayer], for body: Body) {
        let magnitude = body.totalThrust.length
        let direction = magnitude > 1 ? body.totalThrust / magnitude : Vec(0, -1)
        let base = min(magnitude / 6000, 1.4)
        let twist = tanh(body.torque / 40)
        let exhaust = longitude(-direction)
        let reach = frame.insetBy(dx: -400, dy: -400)

        for (jet, port) in zip(jets, body.jetPorts) {
            // Nozzles whose push would turn the window the way the controller wants fire harder.
            let turn = cross(port - body.position, direction) >= 0 ? 1.0 : -1.0
            let assist = turn * twist
            var intensity = max(0, base * (1 + 0.6 * assist)) + (assist > 0 ? 0.4 * abs(twist) : 0)
            if body.phase == .held || !reach.contains(port.cgPoint) { intensity = 0 }
            intensity *= Double.random(in: 0.85...1.15)  // gas jets sputter a little

            jet.emitterPosition = local(port)
            jet.birthRate = Float(intensity)
            jet.setValue(exhaust, forKeyPath: "emitterCells.gas.emissionLongitude")
            jet.setValue(exhaust, forKeyPath: "emitterCells.haze.emissionLongitude")
        }
    }

    /// The window snapshot goes at once (the real window is in place by now), but the jets idle down
    /// over about half a second and their exhaust drifts away rather than vanishing.
    private func retire(_ sprite: Sprite) {
        sprite.window.removeFromSuperlayer()
        let emitters = sprite.jets + sprite.ground
        let steps = 10
        for step in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(step)) {
                emitters.forEach { $0.birthRate = step == steps ? 0 : $0.birthRate * 0.7 }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            emitters.forEach { $0.removeFromSuperlayer() }
        }
    }

    /// Touchdown: smoke rolls away from both bottom edges.
    func burst(at point: Vec, width: Double) {
        guard frame.insetBy(dx: -200, dy: -200).contains(point.cgPoint) else { return }
        for outward in [-1.0, 1.0] {
            let edge = point + Vec(outward * (width / 2 - 12), -4)
            let smoke = Particles.smoke(in: jetLayer.bounds, at: local(edge), outward: outward)
            jetLayer.addSublayer(smoke)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { smoke.birthRate = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { smoke.removeFromSuperlayer() }
        }
    }
}
