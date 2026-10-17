import AVFoundation
import ScreenCaptureKit

/// Debug aid for shooting demos: records the main display to a movie, overlay and thruster hiss
/// included, leaving out every app with windows on screen except the ones it's told to keep.
@available(macOS 15, *)
@MainActor
final class Recorder: NSObject, SCRecordingOutputDelegate {
    private var stream: SCStream?
    private var finished: CheckedContinuation<Void, Never>?

    /// `keep` holds app names or bundle identifiers whose windows stay in the shot.
    func record(to url: URL, seconds: Double, keep: [String]) async {
        guard stream == nil,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first
        else { return }

        let kept = Set(keep.map { $0.lowercased() })
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let appsWithWindows = Set(content.windows.filter { $0.windowLayer == 0 && $0.isOnScreen }
            .compactMap { $0.owningApplication?.processID })
        // Desktop widgets can show your location and calendar, and the Dock pops up if the pointer
        // strays to the bottom edge, so they stay out too.
        let alwaysOut: Set<String> = ["com.apple.notificationcenterui", "com.apple.chrono", "com.apple.dock"]
        let excluded = content.applications.filter { app in
            alwaysOut.contains(app.bundleIdentifier)
                || (appsWithWindows.contains(app.processID) && app.processID != ownPID
                    && !kept.contains(app.applicationName.lowercased())
                    && !kept.contains(app.bundleIdentifier.lowercased()))
        }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = 3840
        config.height = 2160
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false  // scripted takes draw their own big pointer
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false  // the thruster hiss is ours

        let output = SCRecordingOutputConfiguration()
        output.outputURL = url
        output.outputFileType = .mov
        output.videoCodecType = .hevc
        try? FileManager.default.removeItem(at: url)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let recording = SCRecordingOutput(configuration: output, delegate: self)
        do {
            try stream.addRecordingOutput(recording)
            try await stream.startCapture()
        } catch {
            logger.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.stream = stream
        logger.notice("Recording to \(url.path, privacy: .public)")

        try? await Task.sleep(for: .seconds(seconds))
        await withCheckedContinuation { continuation in
            finished = continuation
            Task { try? await stream.stopCapture() }
        }
        self.stream = nil
        logger.notice("Recording saved")
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            finished?.resume()
            finished = nil
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in
            logger.error("Recording failed: \(error.localizedDescription, privacy: .public)")
            finished?.resume()
            finished = nil
        }
    }
}
