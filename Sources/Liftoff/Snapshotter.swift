import CoreGraphics
import ImageIO
import ScreenCaptureKit

/// Captures a single window (without its shadow) so the snapshot can fly while the real window is parked.
@MainActor
enum Snapshotter {
    private static var content: SCShareableContent?

    /// Called when the grab key goes down, so the window list is ready by the time the mouse is.
    static func prefetch() {
        Task { @MainActor in content = try? await fetchContent() }
    }

    static func capture(_ windowID: CGWindowID) async -> CGImage? {
        var window = content?.windows.first { $0.windowID == windowID }
        if window == nil {
            content = try? await fetchContent()
            window = content?.windows.first { $0.windowID == windowID }
        }
        guard let window else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Debug aid: screenshots of the main display, overlay included, saved as numbered PNGs.
    static func filmstrip(to directory: URL, count: Int, interval: Double) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first
        else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<count {
            let start = Date()
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
               let destination = CGImageDestinationCreateWithURL(
                   directory.appendingPathComponent(String(format: "%03d.png", index)) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
            let remaining = interval - Date().timeIntervalSince(start)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
        }
    }

    private static func fetchContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }
}
