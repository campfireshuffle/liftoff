import AppKit
import QuartzCore

/// Compressed-gas jets and burnout smoke.
enum Particles {
    private static let puff: CGImage = {
        let size = 64
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray,
            locations: [0, 0.45, 1]
        )!
        let center = CGPoint(x: size / 2, y: size / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: CGFloat(size / 2), options: [])
        return context.makeImage()!
    }()

    /// One nozzle. Its `birthRate` (0...~1.8) is the throttle; aim it via `emitterCells.*.emissionLongitude`.
    static func jet(in bounds: CGRect) -> CAEmitterLayer {
        let gas = CAEmitterCell()
        gas.name = "gas"
        gas.contents = puff
        gas.birthRate = 240
        gas.lifetime = 0.42
        gas.lifetimeRange = 0.18
        gas.velocity = 720
        gas.velocityRange = 200
        gas.emissionRange = 0.13
        gas.scale = 0.16
        gas.scaleRange = 0.05
        gas.scaleSpeed = 1.1
        gas.alphaSpeed = -1.9
        gas.color = CGColor(red: 0.9, green: 0.95, blue: 1, alpha: 0.8)

        // A darker, slower plume so the gas still reads on light wallpapers.
        let haze = CAEmitterCell()
        haze.name = "haze"
        haze.contents = puff
        haze.birthRate = 50
        haze.lifetime = 0.9
        haze.lifetimeRange = 0.3
        haze.velocity = 320
        haze.velocityRange = 120
        haze.emissionRange = 0.3
        haze.scale = 0.35
        haze.scaleSpeed = 1.3
        haze.alphaSpeed = -0.6
        haze.color = CGColor(red: 0.55, green: 0.6, blue: 0.68, alpha: 0.28)

        let layer = CAEmitterLayer()
        layer.frame = bounds
        layer.emitterShape = .point
        layer.emitterCells = [haze, gas]
        layer.birthRate = 0
        layer.beginTime = CACurrentMediaTime()
        return layer
    }

    /// Jet blast deflected off the surface under a landing window, billowing out from one bottom
    /// edge, away from the window. `outward` is +1 for the right edge, -1 for the left.
    /// Its `birthRate` (0...1) follows how close the window is to the ground.
    static func groundBlast(in bounds: CGRect, outward: Double) -> CAEmitterLayer {
        let cell = outwardCloud(outward: outward)
        cell.birthRate = 140
        cell.lifetime = 1.8
        cell.lifetimeRange = 0.6
        cell.velocity = 360
        cell.velocityRange = 160
        cell.scale = 0.4
        cell.color = CGColor(red: 0.82, green: 0.84, blue: 0.88, alpha: 0.45)
        let layer = emitter(in: bounds, cells: [cell])
        layer.birthRate = 0
        return layer
    }

    /// The touchdown burst from one bottom edge, rolling away from the window.
    static func smoke(in bounds: CGRect, at point: CGPoint, outward: Double) -> CAEmitterLayer {
        let cell = outwardCloud(outward: outward)
        cell.birthRate = 700
        cell.lifetime = 2.6
        cell.lifetimeRange = 0.9
        cell.velocity = 420
        cell.velocityRange = 260
        cell.scale = 0.6
        cell.color = CGColor(red: 0.8, green: 0.82, blue: 0.86, alpha: 0.5)
        let layer = emitter(in: bounds, cells: [cell])
        layer.emitterPosition = point
        return layer
    }

    /// Smoke heading sideways and a little upward, spreading as it slows and thins.
    private static func outwardCloud(outward: Double) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = puff
        cell.emissionLongitude = outward > 0 ? 0.15 : .pi - 0.15
        cell.emissionRange = 0.35
        cell.xAcceleration = -outward * 90  // the ground blast loses speed as it spreads
        cell.yAcceleration = 60  // and warm exhaust drifts up
        cell.scaleRange = 0.25
        cell.scaleSpeed = 1.2
        cell.alphaSpeed = -0.45
        cell.spinRange = 2
        return cell
    }

    private static func emitter(in bounds: CGRect, cells: [CAEmitterCell]) -> CAEmitterLayer {
        let layer = CAEmitterLayer()
        layer.frame = bounds
        layer.emitterShape = .point
        layer.emitterCells = cells
        layer.beginTime = CACurrentMediaTime()
        return layer
    }
}
