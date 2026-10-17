#!/usr/bin/env swift
// Draws Liftoff's icons from one rocket shape: the app icon (assets/Liftoff.icns) and the
// template menu bar icon (assets/MenuBarIcon.png and @2x).
// Usage: swift scripts/make-icon.swift
import AppKit

let assets = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets")

/// A rocket pointing up and to the right, like 🚀, filling a unit square (y up).
func rocket(in rect: CGRect, flame: Bool) -> (body: CGPath, flame: CGPath?) {
    let body = CGMutablePath()
    // Hull: pointed nose, straight sides, flat base.
    body.move(to: CGPoint(x: 0.5, y: 0.97))
    body.addQuadCurve(to: CGPoint(x: 0.625, y: 0.62), control: CGPoint(x: 0.625, y: 0.84))
    body.addLine(to: CGPoint(x: 0.61, y: 0.33))
    body.addLine(to: CGPoint(x: 0.39, y: 0.33))
    body.addLine(to: CGPoint(x: 0.375, y: 0.62))
    body.addQuadCurve(to: CGPoint(x: 0.5, y: 0.97), control: CGPoint(x: 0.375, y: 0.84))
    body.closeSubpath()
    // Fins.
    body.addLines(between: [CGPoint(x: 0.385, y: 0.52), CGPoint(x: 0.23, y: 0.3), CGPoint(x: 0.25, y: 0.22),
                            CGPoint(x: 0.39, y: 0.34)])
    body.closeSubpath()
    body.addLines(between: [CGPoint(x: 0.615, y: 0.52), CGPoint(x: 0.77, y: 0.3), CGPoint(x: 0.75, y: 0.22),
                            CGPoint(x: 0.61, y: 0.34)])
    body.closeSubpath()
    // Nozzle.
    body.addRect(CGRect(x: 0.43, y: 0.27, width: 0.14, height: 0.07))
    // Porthole (cut out with even-odd filling).
    body.addEllipse(in: CGRect(x: 0.44, y: 0.6, width: 0.12, height: 0.12))

    var flamePath: CGMutablePath?
    if flame {
        let f = CGMutablePath()
        f.move(to: CGPoint(x: 0.44, y: 0.26))
        f.addQuadCurve(to: CGPoint(x: 0.5, y: 0.0), control: CGPoint(x: 0.41, y: 0.1))
        f.addQuadCurve(to: CGPoint(x: 0.56, y: 0.26), control: CGPoint(x: 0.59, y: 0.1))
        f.closeSubpath()
        flamePath = f
    }

    // Tilt 45° to the right and fit the rect.
    var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
        .scaledBy(x: rect.width, y: rect.height)
        .translatedBy(x: 0.5, y: 0.5).rotated(by: -.pi / 4).translatedBy(x: -0.5, y: -0.5)
    return (body.copy(using: &transform)!, flamePath?.copy(using: &transform))
}

func bitmap(_ size: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// The app icon at 1024pt: a night-sky squircle, the red light strip, and a white rocket on a flame.
func appIcon(_ size: Int) -> NSBitmapImageRep {
    bitmap(size) { c in
        let s = CGFloat(size) / 1024
        c.scaleBy(x: s, y: s)
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
        c.addPath(shape)
        c.setFillColor(CGColor(red: 0.07, green: 0.075, blue: 0.09, alpha: 1))
        c.fillPath()
        c.restoreGState()

        c.saveGState()
        c.addPath(shape)
        c.clip()
        let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.12, green: 0.13, blue: 0.17, alpha: 1), CGColor(red: 0.03, green: 0.035, blue: 0.045, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(sky, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
        // The red strip on the horizon, with a glow.
        let horizon: CGFloat = 270
        c.setShadow(offset: .zero, blur: 40, color: CGColor(red: 1, green: 0.15, blue: 0.1, alpha: 0.9))
        c.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.15, alpha: 1))
        c.fill(CGRect(x: 100, y: horizon - 4, width: 824, height: 8))
        c.setShadow(offset: .zero, blur: 0)
        // Exhaust puffs on the ground.
        for (x, r, a) in [(330.0, 70.0, 0.22), (420.0, 90.0, 0.28), (520.0, 64.0, 0.2), (250.0, 52.0, 0.16)] {
            c.setFillColor(CGColor(gray: 0.9, alpha: a))
            c.fillEllipse(in: CGRect(x: x - r, y: horizon - r * 0.55, width: r * 2, height: r * 1.1))
        }
        let (body, flame) = rocket(in: CGRect(x: 250, y: 260, width: 560, height: 560), flame: true)
        if let flame {
            c.saveGState()
            c.addPath(flame)
            c.clip()
            let fire = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                CGColor(red: 1, green: 0.85, blue: 0.4, alpha: 1), CGColor(red: 1, green: 0.3, blue: 0.15, alpha: 1),
            ] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(fire, start: CGPoint(x: 560, y: 520), end: CGPoint(x: 300, y: 270), options: [])
            c.restoreGState()
        }
        c.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: CGColor(gray: 0, alpha: 0.5))
        c.addPath(body)
        c.setFillColor(CGColor(gray: 0.96, alpha: 1))
        c.fillPath(using: .evenOdd)
        c.restoreGState()
    }
}

/// The menu bar icon: the same rocket, black on clear, for a template image.
func menuBarIcon(_ points: Int, scale: Int) -> NSBitmapImageRep {
    bitmap(points * scale) { c in
        let side = CGFloat(points * scale)
        let (body, flame) = rocket(in: CGRect(x: 0, y: 0, width: side, height: side), flame: true)
        c.setFillColor(CGColor(gray: 0, alpha: 1))
        c.addPath(body)
        c.fillPath(using: .evenOdd)
        if let flame {
            c.addPath(flame)
            c.fillPath()
        }
    }
}

let iconset = assets.appendingPathComponent("Liftoff.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    save(appIcon(points), iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    save(appIcon(points * 2), iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("Liftoff.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
save(appIcon(1024), assets.appendingPathComponent("Liftoff-1024.png"))

save(menuBarIcon(18, scale: 1), assets.appendingPathComponent("MenuBarIcon.png"))
save(menuBarIcon(18, scale: 2), assets.appendingPathComponent("MenuBarIcon@2x.png"))
print("Wrote \(assets.path)/Liftoff.icns, Liftoff-1024.png and MenuBarIcon.png")
