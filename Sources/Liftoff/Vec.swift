import CoreGraphics
import Foundation

/// 2D vector in global screen points, origin top-left of the primary display, y pointing down
/// (the same space as CGWindowList, CGEvent and the Accessibility API).
typealias Vec = SIMD2<Double>

extension Vec {
    init(_ point: CGPoint) { self.init(Double(point.x), Double(point.y)) }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    var length: Double { (x * x + y * y).squareRoot() }

    var normalized: Vec {
        let l = length
        return l > 0 ? self / l : .zero
    }

    func rotated(by angle: Double) -> Vec {
        let c = cos(angle), s = sin(angle)
        return Vec(x * c - y * s, x * s + y * c)
    }

    func clamped(toLength max: Double) -> Vec {
        let l = length
        return l > max ? self * (max / l) : self
    }

    static func unit(_ angle: Double) -> Vec { Vec(cos(angle), sin(angle)) }
}

func dot(_ a: Vec, _ b: Vec) -> Double { a.x * b.x + a.y * b.y }
func cross(_ a: Vec, _ b: Vec) -> Double { a.x * b.y - a.y * b.x }

/// Velocity of a point offset `r` from a body spinning at `spin` rad/s.
func spinVelocity(_ spin: Double, _ r: Vec) -> Vec { Vec(-spin * r.y, spin * r.x) }

func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T { min(max(value, lower), upper) }
