import ApplicationServices
import CoreGraphics

/// A window in flight: a rigid rectangle with mass, spin and thrusters.
final class Body {
    enum Phase { case held, ballistic, homing, settled }

    let windowID: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    let size: Vec
    /// Center of the window where it started.
    let home: Vec
    /// Center of where it's going to land: home, or a spot it found along the way.
    var destination: Vec

    var position: Vec
    var velocity = Vec.zero
    var angle = 0.0
    var spin = 0.0
    var phase = Phase.held

    var image: CGImage?
    var driver: CGImage?  // a face riding along in the corner, for demo recordings
    var isParked = false

    // Hand
    var cursor = Vec.zero
    var grabOffset = Vec.zero  // grab point in body space
    var cursorSamples: [(time: Double, point: Vec)] = []

    // Flight
    var flightTime = 0.0
    var thrust = Vec.zero  // thruster acceleration, also drives the jets
    var edgeBrake = Vec.zero  // extra thrust used to stop short of a screen edge
    var spool = 0.0  // 0...1, thrusters warming up after the throw
    var torque = 0.0
    var targetAngle = 0.0
    var isApproaching = false  // lined up over home, heading for the hover point
    var isDescending = false
    var hasTouchedDown = false
    var hoverTime = 0.0  // time spent holding in the hover just above the landing spot
    var timeSinceTouchdown = 0.0
    var groundEffect = 0.0  // 0...1, how much jet blast is hitting the surface below
    // Suspension: how much the window is squashed (0.03 = 3% shorter), and how fast that's changing.
    var squash = 0.0
    /// Random phases for this window's turbulence, so no two flights wobble alike.
    let turbulence = (0..<4).map { _ in Double.random(in: 0..<(2 * .pi)) }
    var squashRate = 0.0
    var nearbyWindows: [CGRect] = []  // everything else on screen when it was thrown
    var obstacles: [CGRect] = []  // the ones to fly around on the way to the destination
    var steeringTarget = Vec.zero  // where navigation is currently heading, for traces

    init(window: WindowInfo, element: AXUIElement) {
        windowID = window.id
        pid = window.pid
        self.element = element
        size = Vec(window.frame.width, window.frame.height)
        home = Vec(window.frame.midX, window.frame.midY)
        destination = home
        position = home
    }

    /// Everything the thrusters are pushing with, for the jets and the hiss.
    var totalThrust: Vec { thrust + edgeBrake }

    var destinationOrigin: CGPoint { (destination - size / 2).cgPoint }
    var destinationRect: CGRect { CGRect(origin: destinationOrigin, size: CGSize(width: size.x, height: size.y)) }

    func rect(centeredAt center: Vec) -> CGRect {
        CGRect(x: center.x - size.x / 2, y: center.y - size.y / 2, width: size.x, height: size.y)
    }

    var mass: Double { size.x * size.y / 100_000 }
    var inverseMass: Double { phase == .held ? 0 : 1 / mass }
    var inverseInertia: Double { inverseMass * 12 / (size.x * size.x + size.y * size.y) }

    var axisX: Vec { .unit(angle) }
    var axisY: Vec { .unit(angle + .pi / 2) }

    func contains(_ point: Vec) -> Bool {
        let local = (point - position).rotated(by: -angle)
        return abs(local.x) <= size.x / 2 && abs(local.y) <= size.y / 2
    }

    func halfExtent(along axis: Vec) -> Double {
        abs(dot(axisX, axis)) * size.x / 2 + abs(dot(axisY, axis)) * size.y / 2
    }

    var corners: [Vec] {
        let hx = axisX * (size.x / 2), hy = axisY * (size.y / 2)
        return [position - hx - hy, position + hx - hy, position + hx + hy, position - hx + hy]
    }

    /// The corner furthest along `direction`.
    func support(_ direction: Vec) -> Vec {
        corners.max { dot($0, direction) < dot($1, direction) }!
    }

    var boundingBox: CGRect {
        let w = 2 * halfExtent(along: Vec(1, 0)), h = 2 * halfExtent(along: Vec(0, 1))
        return CGRect(x: position.x - w / 2, y: position.y - h / 2, width: w, height: h)
    }

    /// Thruster nozzles, one at each corner.
    var jetPorts: [Vec] {
        let inset = 6.0
        let hx = axisX * (size.x / 2 - inset), hy = axisY * (size.y / 2 - inset)
        return [position - hx - hy, position + hx - hy, position + hx + hy, position - hx + hy]
    }
}
