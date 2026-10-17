import AppKit

/// Images for staged demo recordings: a big pointer and the "driver cam" face.
enum Props {
    /// The classic macOS arrow, drawn as a vector so it stays crisp at any size. Tip at top-left.
    static func pointer(height: CGFloat, scale: CGFloat) -> CGImage {
        let unit = height / 19
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 16), (4, 12.2), (6.8, 18.6), (9.4, 17.5), (6.7, 11.4), (12, 11.4)]
        let margin = 3 * unit
        let size = CGSize(width: 12 * unit + 2 * margin, height: 19 * unit + 2 * margin)
        let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        let path = CGMutablePath()
        // Flip so the tip sits at the top-left of the image.
        let placed = points.map { CGPoint(x: margin + $0.0 * unit, y: size.height - margin - $0.1 * unit) }
        path.addLines(between: placed)
        path.closeSubpath()
        context.setShadow(offset: CGSize(width: 0, height: -unit * 0.6), blur: unit * 1.5,
                          color: CGColor(gray: 0, alpha: 0.45))
        context.addPath(path)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(unit * 2)
        context.setLineJoin(.round)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.drawPath(using: .fillStroke)
        context.setShadow(offset: .zero, blur: 0)
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        return context.makeImage()!
    }

    /// Where the tip is, as a fraction of the pointer image (for the layer's anchor point).
    static let pointerTip = CGPoint(x: 3.0 / 18, y: 1 - 3.0 / 25)

    /// A pared-back menu bar: the Apple menu, "Liftoff", a few menus, a couple of status icons
    /// and the classic 9:41. Opaque, so it fully covers the real one in recordings.
    static func menuBar(size: CGSize, scale: CGFloat) -> CGImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(red: 0.075, green: 0.078, blue: 0.086, alpha: 1).setFill()
            rect.fill()
            let font = NSFont.systemFont(ofSize: 13, weight: .regular)
            let bold = NSFont.systemFont(ofSize: 13, weight: .bold)
            let white = NSColor(white: 0.95, alpha: 1)
            let midY = rect.midY

            func text(_ string: String, at x: CGFloat, font: NSFont, alignRight: Bool = false) -> CGFloat {
                let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: white])
                let width = attributed.size().width
                let origin = CGPoint(x: alignRight ? x - width : x, y: midY - attributed.size().height / 2)
                attributed.draw(at: origin)
                return width
            }
            func symbol(_ name: String, at x: CGFloat, pointSize: CGFloat = 14, alignRight: Bool = false) -> CGFloat {
                let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
                    .applying(.init(paletteColors: [white]))
                guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) else { return 0 }
                let width = image.size.width
                image.draw(in: CGRect(x: alignRight ? x - width : x, y: midY - image.size.height / 2,
                                      width: width, height: image.size.height))
                return width
            }

            var x: CGFloat = 20
            x += symbol("apple.logo", at: x, pointSize: 15) + 20
            x += text("Liftoff", at: x, font: bold) + 20
            for menu in ["File", "Edit", "View", "Window", "Help"] { x += text(menu, at: x, font: font) + 20 }

            var right = rect.maxX - 18
            right -= text("Sat Oct 17  9:41 AM", at: right, font: font, alignRight: true) + 18
            for name in ["switch.2", "magnifyingglass", "wifi", "battery.100percent"] {
                right -= symbol(name, at: right, alignRight: true) + 18
            }
            return true
        }
        let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    /// A face for the driver cam: an image file (an exported memoji sticker, say) or an emoji.
    static func face(_ source: String) -> CGImage? {
        if FileManager.default.fileExists(atPath: source) {
            return NSImage(contentsOfFile: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let side: CGFloat = 256
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let text = NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: side * 0.78)])
            let bounds = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin])
            text.draw(at: CGPoint(x: (side - bounds.width) / 2, y: (side - bounds.height) / 2 - bounds.minY))
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
