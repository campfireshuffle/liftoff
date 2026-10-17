#!/usr/bin/env swift
// Exports the Icon Composer app icon, draws the template menu bar rocket, and renders
// the social preview card. Requires Xcode with Icon Composer installed.
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

// Icon Composer exports the tile without macOS's outer safe area.
let composedURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("Liftoff-\(UUID().uuidString).png")
let developerPath = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? "/Applications/Xcode.app/Contents/Developer"
let composer = Process()
composer.executableURL = URL(fileURLWithPath: developerPath)
    .appendingPathComponent("../Applications/Icon Composer.app/Contents/Executables/ictool")
composer.arguments = [assets.appendingPathComponent("Liftoff.icon").path,
    "--export-image", "--output-file", composedURL.path, "--platform", "macOS",
    "--rendition", "Default", "--width", "1024", "--height", "1024", "--scale", "1"]
try composer.run()
composer.waitUntilExit()
guard composer.terminationStatus == 0,
      let composed = NSBitmapImageRep(data: try Data(contentsOf: composedURL))?.cgImage else {
    fatalError("Icon Composer export failed")
}
try FileManager.default.removeItem(at: composedURL)

func appIcon(_ size: Int) -> NSBitmapImageRep {
    bitmap(size) { c in
        let s = CGFloat(size) / 1024
        c.scaleBy(x: s, y: s)
        c.interpolationQuality = .high
        c.setShadow(offset: CGSize(width: 0, height: -10), blur: 22,
                    color: CGColor(gray: 0, alpha: 0.25))
        c.draw(composed, in: CGRect(x: 100, y: 100, width: 824, height: 824))
    }
}

/// The repo's social preview: the app icon beside the name and tagline, on a night sky.
func socialCard() -> NSBitmapImageRep {
    let width = 1280, height = 640
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        CGColor(red: 0.07, green: 0.075, blue: 0.095, alpha: 1), CGColor(red: 0.02, green: 0.022, blue: 0.03, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(sky, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])

    // The icon on the left, its own tile shadow included.
    c.draw(appIcon(1024).cgImage!, in: CGRect(x: 70, y: 110, width: 420, height: 420))

    let title = NSAttributedString(string: "Liftoff", attributes: [
        .font: NSFont.systemFont(ofSize: 132, weight: .bold), .foregroundColor: NSColor(white: 0.97, alpha: 1),
    ])
    title.draw(at: CGPoint(x: 520, y: 330))
    let tagline = NSAttributedString(string: "Give your Mac's windows thrusters.", attributes: [
        .font: NSFont.systemFont(ofSize: 40, weight: .regular), .foregroundColor: NSColor(white: 0.72, alpha: 1),
    ])
    tagline.draw(at: CGPoint(x: 526, y: 268))
    NSGraphicsContext.restoreGraphicsState()
    return rep
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
save(socialCard(), assets.appendingPathComponent("social-preview.png"))
print("Wrote \(assets.path)/Liftoff.icns, Liftoff-1024.png, MenuBarIcon.png and social-preview.png")
