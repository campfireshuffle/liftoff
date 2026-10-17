import CoreGraphics
import Foundation

/// The physics: throws, gravity, thruster flight to a landing spot, hopping over windows, and collisions.
final class World {
    private(set) var bodies: [Body] = []
    var bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// Each display's usable area (below the menu bar, above the Dock). The bottom edge is the floor.
    var floors: [CGRect] = []
    /// Land wherever there's room along the flight path, rather than flying back home.
    var landsAnywhere = true
    /// For staged recordings: where the next throw should aim to land, instead of where its path leads.
    var landingHint: Double?
    var onTouchdown: (Body) -> Void = { _ in }
    var onLanded: (Body) -> Void = { _ in }

    static let gravity = 3200.0
    private static let maxStep = 1.0 / 240

    // Flight tuning. Peak thrust is 2.5x gravity, and changes in thrust are eased in so nothing jolts.
    private let maxThrust = 8_000.0
    private let spoolTime = 0.2  // seconds for the thrusters to reach full power once lit
    private let thrustResponse = 0.1  // seconds; smooths sudden changes in commanded thrust
    private let cruiseSpeed = 1400.0
    private let descentSpeed = 1600.0
    private let landingDeceleration = 2400.0  // the braking curve the final descent follows
    // The last stretch is a slow, deliberate set-down on the thrusters, like the Roadster's landings.
    private let flareHeight = 70.0
    private let flareSpeed = 85.0
    // Before setting down, it holds a hover just above the spot, precessing gently on its thrusters.
    private let hoverHold = 55.0
    private let hoverDuration = 0.6
    private let sideBraking = 9000.0  // thrusters braking a sideways fling before the screen edge
    private let cruiseDeceleration = 1200.0  // how hard it plans to brake for waypoints in flight
    private let edgeBraking = 4000.0  // how hard it plans to brake for screen edges
    private let hoverHeight = 90.0
    private let hopClearance = 30.0

    var isIdle: Bool { bodies.allSatisfy { $0.phase == .settled } }

    func add(_ body: Body) { bodies.append(body) }
    func remove(_ body: Body) { bodies.removeAll { $0 === body } }
    func contains(_ body: Body) -> Bool { bodies.contains { $0 === body } }

    func body(at point: Vec) -> Body? {
        bodies.last { $0.phase != .settled && $0.contains(point) }
    }

    // MARK: Hand

    func grab(_ body: Body, cursor: Vec, time: Double) {
        body.phase = .held
        body.grabOffset = (cursor - body.position).rotated(by: -body.angle)
        body.cursor = cursor
        body.cursorSamples = [(time, cursor)]
        body.velocity = .zero
        body.spin = 0
        body.thrust = .zero
        body.torque = 0
        body.isDescending = false
        body.hasTouchedDown = false
    }

    func drag(_ body: Body, cursor: Vec, time: Double) {
        body.cursor = cursor
        body.cursorSamples.append((time, cursor))
        body.cursorSamples.removeAll { time - $0.time > 0.15 }
    }

    func release(_ body: Body, time: Double, obstacles: [CGRect]) {
        let recent = body.cursorSamples.filter { time - $0.time < 0.1 }
        var velocity = Vec.zero
        if let first = recent.first, let last = recent.last,
           last.time - first.time > 0.008, time - last.time < 0.06 {
            velocity = (last.point - first.point) / (last.time - first.time)
        }
        body.velocity = velocity.clamped(toLength: 7000)
        // A fling harder than the thrusters could stop before the side of the screen is capped.
        let box = body.boundingBox, limits = arena(for: body)
        let room = max(0, (body.velocity.x > 0 ? limits.maxX - box.maxX : box.minX - limits.minX) - 40)
        let stoppable = (2 * sideBraking * 0.8 * room).squareRoot()
        body.velocity.x = clamp(body.velocity.x, -stoppable, stoppable)

        // Flicking from off-center spins it, like flinging a real board by its corner.
        let lever = body.grabOffset.rotated(by: body.angle)
        let spin = cross(lever, body.velocity) * 12 / (body.size.x * body.size.x + body.size.y * body.size.y)
        body.spin = clamp(spin * 0.55, -30, 30)

        body.phase = .ballistic
        body.flightTime = 0
        body.nearbyWindows = obstacles
    }

    // MARK: Simulation

    /// Advances exactly `dt`, split into equal substeps, so every rendered frame shows where things
    /// really are at that moment (a fixed step with leftovers makes motion judder).
    func step(_ dt: Double) {
        let substeps = max(1, Int((dt / Self.maxStep).rounded(.up)))
        let h = dt / Double(substeps)
        for _ in 0..<substeps { integrate(h) }
    }

    private func integrate(_ h: Double) {
        for body in bodies {
            switch body.phase {
            case .held:
                let target = body.cursor - body.grabOffset.rotated(by: body.angle)
                body.velocity = body.velocity * 0.8 + (target - body.position) / h * 0.2
                body.position = target
                // Right itself in the hand if it was caught mid-flip.
                let upright = (body.angle / (2 * .pi)).rounded() * 2 * .pi
                body.angle += (upright - body.angle) * min(1, h * 6)
            case .ballistic:
                flyBallistic(body, h)
            case .homing:
                flyHome(body, h)
            case .settled:
                continue
            }
            updateSuspension(body, h)
        }
        resolveCollisions()
    }

    private func flyBallistic(_ body: Body, _ h: Double) {
        body.flightTime += h
        body.thrust = .zero
        body.torque = 0
        body.velocity.y += Self.gravity * h
        body.velocity *= 1 - 0.1 * h
        body.spin *= 1 - 0.2 * h
        body.edgeBrake = .zero
        advance(body, h)
        cushionEdges(body, h, thrusters: false)

        if shouldIgnite(body) || body.flightTime > 2.5 { startHoming(body) }
    }

    /// Free fall until the last moment the thrusters can still stop it gently on its landing spot,
    /// or until it has sailed off screen and needs fetching back.
    private func shouldIgnite(_ body: Body) -> Bool {
        // Would it reach the side of the screen before the thrusters could stop it?
        let box = body.boundingBox, limits = arena(for: body)
        let sideways = abs(body.velocity.x)
        let sideGap = body.velocity.x > 0 ? limits.maxX - box.maxX : box.minX - limits.minX
        if sideways > 1 && sideGap <= stoppingDistance(sideways, braking: sideBraking * 0.8) { return true }

        // About to fall into another window? Light up now so the thrusters can steer around it.
        let lookAhead = 0.5
        let soon = body.boundingBox.offsetBy(dx: body.velocity.x * lookAhead, dy: max(body.velocity.y, 0) * lookAhead + 80)
        let now = body.boundingBox
        if body.velocity.y > 0, body.nearbyWindows.contains(where: { $0.intersects(soon) && !$0.intersects(now) }) {
            return true
        }

        guard body.velocity.y > 0 else { return false }
        let pad = landsAnywhere ? chooseLanding(body) : body.home
        return pad.y - body.position.y <= stoppingDistance(body.velocity.y, braking: landingDeceleration)
    }

    /// Distance covered while braking from `speed` at `braking`, plus the time the thrusters take to light.
    private func stoppingDistance(_ speed: Double, braking: Double) -> Double {
        speed * speed / (2 * braking) + speed * (spoolTime + thrustResponse) + 30
    }

    private func startHoming(_ body: Body) {
        body.phase = .homing
        body.spool = 0
        body.isApproaching = false
        body.hoverTime = 0
        body.destination = landsAnywhere ? chooseLanding(body) : body.home
        landingHint = nil
        // Windows at the destination (including one it lands on) aren't in the way.
        let landing = body.destinationRect.insetBy(dx: -4, dy: -4)
        body.obstacles = body.nearbyWindows.filter { !$0.insetBy(dx: 8, dy: 8).intersects(landing) }
        // Finish the flip it's already doing rather than unwinding it.
        let lead = body.angle + body.spin * 0.35
        body.targetAngle = (lead / (2 * .pi)).rounded() * 2 * .pi
    }

    private func flyHome(_ body: Body, _ h: Double) {
        body.flightTime += h
        if body.hasTouchedDown {
            rollOut(body, h)
            return
        }
        let (target, maxSpeed) = navigate(body)
        body.steeringTarget = target

        // Thrusters spool up smoothly instead of snapping on, so the window is caught mid-fall
        // rather than yanked.
        body.spool = min(1, body.spool + h / spoolTime)
        let power = body.spool * body.spool * (3 - 2 * body.spool)

        let toTarget = target - body.position
        // Final descent follows a braking curve that arrives at a gentle touchdown speed rather than
        // zero, so it lands instead of hovering just above the ground.
        // Elsewhere, each axis approaches its target only as fast as it can still stop there, so it
        // doesn't overshoot a cruise height into the window it was climbing over.
        let stoppable = { (distance: Double) in
            (distance < 0 ? -1.0 : 1.0) * (2 * self.cruiseDeceleration * abs(distance)).squareRoot()
        }
        var desiredVelocity = body.isDescending
            ? toTarget.normalized * min(maxSpeed, brakingSpeed(over: toTarget.length))
            : Vec(stoppable(toTarget.x), stoppable(toTarget.y)).clamped(toLength: maxSpeed)
        // Above the pad, never come down faster than the braking curve allows, whatever else it's doing,
        // and hold at flare height until lined up over the spot, so it doesn't land beside it.
        let offset = abs(body.position.x - body.destination.x)
        let drop = body.destination.y - (offset > 16 ? flareHeight : 0) - body.position.y
        if drop > 0 { desiredVelocity.y = min(desiredVelocity.y, brakingSpeed(over: drop)) }
        // Other windows are solid from above: never sink onto one it's passing over, slide past instead.
        let box = body.boundingBox
        for obstacle in body.obstacles where obstacle.minX < box.maxX + 16 && obstacle.maxX > box.minX - 16 {
            let lowest = obstacle.minY - box.height / 2 - 12
            guard body.position.y <= lowest + 1 else { continue }
            let room = (2 * landingDeceleration * max(lowest - body.position.y, 0)).squareRoot()
            desiredVelocity.y = min(desiredVelocity.y, room)
        }
        let gravity = Vec(0, Self.gravity)
        let responsiveness = body.isDescending ? 6.0 : 7.0
        let command = ((desiredVelocity - body.velocity) * responsiveness - gravity).clamped(toLength: maxThrust * power)
        body.thrust += (command - body.thrust) * min(1, h / thrustResponse)

        // Lean into the direction of travel while cruising; on the way down, precess gently instead.
        let lean = body.isDescending ? 0 : clamp(body.velocity.x * 0.00005, -0.12, 0.12)
        let precession = body.isDescending ? 0.035 * sin(6.5 * body.flightTime + body.turbulence[0]) : 0
        let angleError = body.targetAngle + lean + precession - body.angle
        body.torque = clamp(30 * angleError - 10 * body.spin, -90, 90) * max(power, 0.15)

        // Real thrusters don't hold perfectly steady: a gentle wobble and bob, settling out for the landing.
        let t = body.flightTime, phase = body.turbulence
        let calm = body.isDescending ? 0.4 : 1.0
        let buffet = Vec(sin(2.3 * t + phase[0]) + 0.6 * sin(5.1 * t + phase[1]),
                         sin(1.7 * t + phase[2]) + 0.5 * sin(4.3 * t + phase[3])) * (90 * calm * power)
        let wobble = (1.6 * sin(2.9 * t + phase[1]) + 0.9 * sin(6.7 * t + phase[3])) * calm * power

        body.velocity += (body.thrust + buffet + gravity) * h
        body.spin += (body.torque + wobble) * h
        let wasAbovePad = body.position.y <= body.destination.y
        advance(body, h)
        cushionEdges(body, h, thrusters: true)

        // The surface it's landing on is solid: coming down onto the pad, it touches down instead of
        // sinking through the window (or floor) underneath.
        let overPad = abs(body.position.x - body.destination.x) < body.size.x / 2
        if wasAbovePad && overPad && body.position.y > body.destination.y && body.velocity.y > 0 {
            touchDown(body)
            return
        }

        // Count time spent hanging in the hover point before it's allowed to set down.
        if body.isDescending && body.hoverTime < hoverDuration
            && (body.destination - Vec(0, hoverHold) - body.position).length < 14 {
            body.hoverTime += h
        }

        // Jet blast hitting the surface below kicks up smoke as it gets close.
        let overSurface = abs(body.position.x - body.destination.x) < body.size.x / 2
        let height = body.destination.y - body.position.y
        body.groundEffect = overSurface && height >= 0 ? clamp(1 - height / (flareHeight * 2.5), 0, 1) : 0

        // Safety net: never leave a window parked for long, whatever the physics is doing.
        let toGo = (body.destination - body.position).length
        if (body.flightTime > 6 && toGo < 30) || body.flightTime > 10 { settle(body) }
    }

    /// Speed allowed with `distance` left: brake down to a slow crawl by the flare height, then
    /// settle the rest of the way at that crawl.
    private func brakingSpeed(over distance: Double) -> Double {
        let aboveFlare = max(distance - flareHeight, 0)
        return (2 * landingDeceleration * aboveFlare + flareSpeed * flareSpeed).squareRoot()
    }

    /// Where it touches down is where it stays: engines cut, no bounce, no sliding along the ground.
    /// The suspension takes the impact.
    private func touchDown(_ body: Body) {
        guard !body.hasTouchedDown else { return }
        body.hasTouchedDown = true
        body.isDescending = true
        body.destination.x = body.position.x
        body.position = body.destination
        body.squashRate += min(max(body.velocity.y, 0), 300) * 0.007
        body.velocity = .zero
        body.spin = 0
        body.timeSinceTouchdown = 0
        onTouchdown(body)
    }

    /// On the ground: engines idle down, it levels off, and the suspension rings out before the real
    /// window takes over.
    private func rollOut(_ body: Body, _ h: Double) {
        body.timeSinceTouchdown += h
        body.position = body.destination
        body.velocity = .zero
        body.angle += (body.targetAngle - body.angle) * min(1, 12 * h)
        body.thrust *= max(0, 1 - 6 * h)
        body.edgeBrake = .zero
        body.groundEffect = min(1, body.thrust.length / Self.gravity)
        let rungOut = abs(body.squash) < 0.002 && abs(body.squashRate) < 0.05
        if body.timeSinceTouchdown > 0.6 || (body.timeSinceTouchdown > 0.25 && rungOut) { settle(body) }
    }

    /// A small spring-damper between the window and its "passengers": it sinks a little under
    /// thruster load and squashes on touchdown, then rings back out.
    private func updateSuspension(_ body: Body, _ h: Double) {
        let load = body.phase == .homing && !body.hasTouchedDown
            ? dot(body.totalThrust, -body.axisY) / Self.gravity : 0
        let omega = 20.0, damping = 0.3, compressionPerG = 0.006
        let accel = omega * omega * (load * compressionPerG - body.squash) - 2 * damping * omega * body.squashRate
        body.squashRate += accel * h
        body.squash = clamp(body.squash + body.squashRate * h, -0.06, 0.08)
    }

    private func settle(_ body: Body) {
        body.position = body.destination
        body.velocity = .zero
        body.angle = 0
        body.spin = 0
        body.torque = 0
        // Thrust is left as it was, so the jets can idle down instead of cutting out.
        body.phase = .settled
        onLanded(body)
    }

    private func advance(_ body: Body, _ h: Double) {
        body.position += body.velocity * h
        body.angle += body.spin * h
    }

    /// Where a window may fly: the usable area (inside the safe margins, above the Dock or floor
    /// margin) plus open sky above it. The sides and the floor are limits it should never touch.
    private func arena(for body: Body) -> CGRect {
        let left = floors.map(\.minX).min() ?? bounds.minX
        let right = floors.map(\.maxX).max() ?? bounds.maxX
        let floor = floors.map(\.maxY).max() ?? bounds.maxY
        let sky = bounds.minY - 3 * bounds.height
        let arena = CGRect(x: left, y: sky, width: right - left, height: floor - sky)
        return arena.union(body.destinationRect)
    }

    private func cushionEdges(_ body: Body, _ h: Double, thrusters: Bool) {
        let bounds = arena(for: body)
        let box = body.boundingBox

        // See the edge coming and fire the thrusters against it, so the window stops before it hits.
        var brake = Vec.zero
        let fits = [box.width < bounds.width, box.height < bounds.height]
        let gaps = [
            (bounds.maxX - box.maxX, box.minX - bounds.minX),
            (bounds.maxY - box.maxY, box.minY - bounds.minY),
        ]
        for axis in 0..<2 where thrusters && fits[axis] {
            let speed = body.velocity[axis]
            let gap = speed > 0 ? gaps[axis].0 : gaps[axis].1
            guard abs(speed) > 1, gap > 0, gap < speed * speed / (2 * edgeBraking) + 40 else { continue }
            brake[axis] = -(speed > 0 ? 1 : -1) * min(speed * speed / (2 * max(gap, 20)), sideBraking)
        }
        body.velocity += brake * h
        body.edgeBrake = brake

        var depth = Vec.zero
        if box.width < bounds.width {
            if box.minX < bounds.minX { depth.x = bounds.minX - box.minX }
            else if box.maxX > bounds.maxX { depth.x = bounds.maxX - box.maxX }
        }
        if box.height < bounds.height {
            if box.minY < bounds.minY { depth.y = bounds.minY - box.minY }
            else if box.maxY > bounds.maxY { depth.y = bounds.maxY - box.maxY }
        }
        guard depth != .zero else { return }

        // Absorb motion toward the edge and ease the window back inside, without launching it the
        // other way (a spinning window's box widens, and a springy edge would fling it across the screen).
        let inward = depth.normalized
        let outwardSpeed = dot(body.velocity, inward)
        if outwardSpeed < 0 { body.velocity -= inward * (outwardSpeed * min(1, 12 * h)) }
        body.position += depth * min(1, 6 * h)
        body.spin *= 1 - 2 * h

        let maxDepth = 120.0
        for axis in 0..<2 where abs(depth[axis]) > maxDepth {
            body.position[axis] += depth[axis] - (depth[axis] > 0 ? maxDepth : -maxDepth)
            if body.velocity[axis] * depth[axis] < 0 { body.velocity[axis] = 0 }
        }
    }

    // MARK: Navigation

    /// Where to steer next. Like the Roadster hopping parked cars: if windows sit between here and the
    /// destination, climb to just above the tallest of them, cruise across, then drop to a hover point above it.
    private func navigate(_ body: Body) -> (target: Vec, maxSpeed: Double) {
        if body.isDescending { return (descentTarget(body), descentSpeed) }

        var hover = body.destination - Vec(0, hoverHeight)
        hover.y = min(body.destination.y, max(hover.y, bounds.union(body.destinationRect).minY + body.size.y / 2 + 4))
        let nearHover = (body.position - hover).length < 50 && body.velocity.length < 900
        // Already above the spot and lined up: settle straight down rather than climbing back to hover.
        let rightAbove = abs(body.position.x - hover.x) < 60 && body.position.y <= body.destination.y - 20
        if nearHover || rightAbove {
            body.isDescending = true
            return (descentTarget(body), descentSpeed)
        }

        if body.isApproaching { return (hover, cruiseSpeed) }

        // Treat the body as a point by growing every obstacle by its half-size plus a margin.
        let half = body.size / 2 + 16
        let zones = body.obstacles.map { $0.insetBy(dx: -half.x, dy: -half.y) }
        let position = body.position
        guard zones.contains(where: { segment(position, hover, intersects: $0) }),
              let cruise = cruiseAltitude(from: position, to: hover, zones: zones, ceiling: bounds.minY + body.size.y / 2 + 4)
        else { return (hover, cruiseSpeed) }

        let remaining = hover.x - position.x
        if abs(remaining) < 60 {
            // Lined up over the destination: commit to the approach, or small drifts send it back up to cruise.
            body.isApproaching = true
            return (hover, cruiseSpeed)
        }
        if position.y > cruise + 30 {
            // Still climbing: mostly up, drifting a little toward the destination.
            let drift = remaining < 0 ? -min(-remaining, 120) : min(remaining, 120)
            return (Vec(position.x + drift, cruise), cruiseSpeed)
        }
        return (Vec(hover.x, cruise), cruiseSpeed)
    }

    /// Where to land: a little ahead along the flight path, dropping straight down onto the first
    /// surface with room, either the roof of another window or the floor of the screen.
    private func chooseLanding(_ body: Body) -> Vec {
        let half = body.size / 2
        // Far enough ahead that its sideways momentum carries it there rather than past it.
        var ahead = CGPoint(x: body.position.x + body.velocity.x * 0.6, y: body.position.y)
        if let hint = landingHint { ahead.x = hint }
        let area = floors.first { $0.contains(ahead) }
            ?? floors.min { distance(ahead, $0) < distance(ahead, $1) }
            ?? bounds
        guard body.size.y < area.height else { return Vec(Double(area.midX), Double(area.midY)) }

        // The usable area already keeps a safe margin from the screen's edges.
        let x = body.size.x < area.width ? clamp(Double(ahead.x), area.minX + half.x, area.maxX - half.x) : Double(area.midX)
        let span = (x - half.x)...(x + half.x)
        // Windows that are landing count too, so a second throw can stack on the first.
        let others = body.nearbyWindows
            + bodies.filter { $0 !== body && $0.phase == .homing }.map(\.destinationRect)
        let roofs = others
            .filter { min(span.upperBound, $0.maxX) - max(span.lowerBound, $0.minX) >= body.size.x * 0.5 }
            .map(\.minY)
        let floor = Double(area.maxY)

        for surface in (roofs + [floor]).filter({ $0 >= body.position.y }).sorted() {
            let center = Vec(x, surface - half.y)
            let pad = body.rect(centeredAt: center)
            guard pad.minY >= area.minY else { continue }
            if surface == floor {
                // On the floor, slide to the nearest gap with room around it rather than parking in
                // front of another window.
                let spot = clearSpot(near: x, height: center.y, for: body, in: area, avoiding: others)
                return Vec(spot ?? x, center.y)
            }
            let covered = others.reduce(0.0) { total, other in
                let overlap = pad.intersection(other)
                return overlap.isNull ? total : total + overlap.width * overlap.height
            }
            if covered < 0.25 * body.size.x * body.size.y { return center }
        }
        return Vec(x, floor - half.y)
    }

    /// The x nearest `preferred` where the window fits at `height` with a gap around it, or failing
    /// that (a crowded desktop), the spot overlapping other windows least.
    private func clearSpot(near preferred: Double, height: Double, for body: Body, in area: CGRect,
                           avoiding others: [CGRect]) -> Double? {
        let gap = 40.0, half = body.size.x / 2
        let lowest = Double(area.minX) + half, highest = Double(area.maxX) - half
        var leastCovered: (x: Double, area: Double)?
        for step in 0...80 {
            for direction in [1.0, -1.0] where step > 0 || direction > 0 {
                let x = preferred + direction * Double(step) * 20
                guard x >= lowest, x <= highest else { continue }
                let pad = body.rect(centeredAt: Vec(x, height)).insetBy(dx: -gap, dy: 0)
                let covered = others.reduce(0.0) { total, other in
                    let overlap = pad.intersection(other)
                    return overlap.isNull ? total : total + overlap.width * overlap.height
                }
                if covered == 0 { return x }
                if leastCovered == nil || covered < leastCovered!.area { leastCovered = (x, covered) }
            }
        }
        return leastCovered?.x
    }

    private func distance(_ point: CGPoint, _ rect: CGRect) -> Double {
        hypot(point.x - rect.midX, point.y - rect.midY)
    }

    /// On final descent: first a hover point just above the spot, swaying a little, and once it has
    /// hung there long enough, the spot itself.
    private func descentTarget(_ body: Body) -> Vec {
        guard body.hoverTime < hoverDuration else { return body.destination }
        let sway = 5 * sin(4.4 * body.flightTime + body.turbulence[2])
        return body.destination + Vec(sway, -hoverHold)
    }

    /// The highest top (smallest y) among windows in the corridor between `a` and `b`, minus clearance.
    /// Raising the corridor can bring more windows into it, so repeat until it settles.
    private func cruiseAltitude(from a: Vec, to b: Vec, zones: [CGRect], ceiling: Double) -> Double? {
        let left = min(a.x, b.x), right = max(a.x, b.x)
        let bottom = max(a.y, b.y)
        var top = min(a.y, b.y)
        var altitude: Double?
        for _ in 0..<6 {
            let corridor = zones.filter { $0.maxX > left && $0.minX < right && $0.maxY > top && $0.minY < bottom }
            guard let highest = corridor.map(\.minY).min() else { break }
            let next = max(highest - hopClearance, ceiling)
            if let altitude, abs(altitude - next) < 1 { break }
            altitude = next
            if next >= top { break }
            top = next
        }
        return altitude
    }

    /// Liang–Barsky segment/rect test.
    private func segment(_ a: Vec, _ b: Vec, intersects rect: CGRect) -> Bool {
        let d = b - a
        var t0 = 0.0, t1 = 1.0
        let checks = [(-d.x, a.x - rect.minX), (d.x, rect.maxX - a.x), (-d.y, a.y - rect.minY), (d.y, rect.maxY - a.y)]
        for (p, q) in checks {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let t = q / p
                if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
                if t0 > t1 { return false }
            }
        }
        return true
    }

    // MARK: Collisions

    private func resolveCollisions() {
        let flying = bodies.filter { $0.phase != .settled && $0.image != nil && !$0.isDescending }
        guard flying.count > 1 else { return }
        for i in 0..<flying.count {
            for j in (i + 1)..<flying.count {
                let a = flying[i], b = flying[j]
                if a.phase == .homing && b.phase == .homing && a.destinationRect.intersects(b.destinationRect) { continue }
                collide(a, b)
            }
        }
    }

    private func collide(_ a: Body, _ b: Body) {
        let invMass = a.inverseMass + b.inverseMass
        guard invMass > 0, let (normal, depth) = overlap(a, b) else { return }

        a.position -= normal * (depth * a.inverseMass / invMass)
        b.position += normal * (depth * b.inverseMass / invMass)

        var contact = b.support(-normal)
        if !a.contains(contact) { contact = a.support(normal) }
        let ra = contact - a.position, rb = contact - b.position
        let relative = (b.velocity + spinVelocity(b.spin, rb)) - (a.velocity + spinVelocity(a.spin, ra))
        let closing = dot(relative, normal)
        guard closing < 0 else { return }

        let k = invMass + a.inverseInertia * pow(cross(ra, normal), 2) + b.inverseInertia * pow(cross(rb, normal), 2)
        let impulse = normal * (-(1 + 0.4) * closing / k)
        a.velocity -= impulse * a.inverseMass
        a.spin -= cross(ra, impulse) * a.inverseInertia
        b.velocity += impulse * b.inverseMass
        b.spin += cross(rb, impulse) * b.inverseInertia

        for body in [a, b] where body.phase == .homing && (impulse * body.inverseMass).length > 250 {
            knockLoose(body)
        }
    }

    /// A hard hit cuts the thrusters for a moment so the window tumbles before recovering.
    private func knockLoose(_ body: Body) {
        body.phase = .ballistic
        body.flightTime = 0.15
        body.isDescending = false
        body.isApproaching = false
        body.hasTouchedDown = false
        body.hoverTime = 0
    }

    /// Separating-axis test for two rotated rectangles. The normal points from `a` to `b`.
    private func overlap(_ a: Body, _ b: Body) -> (Vec, Double)? {
        let offset = b.position - a.position
        var best: (Vec, Double)?
        for axis in [a.axisX, a.axisY, b.axisX, b.axisY] {
            let distance = dot(offset, axis)
            let depth = a.halfExtent(along: axis) + b.halfExtent(along: axis) - abs(distance)
            if depth <= 0 { return nil }
            if best == nil || depth < best!.1 { best = (distance < 0 ? -axis : axis, depth) }
        }
        return best
    }
}
