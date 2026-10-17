import AppKit
import ServiceManagement
import SwiftUI

/// Live state for the settings and welcome windows: preferences, plus permission status that
/// refreshes every second while a window is open, so granting in System Settings shows up at once.
@MainActor
final class Preferences: ObservableObject {
    @Published var grabKey = Settings.grabKey {
        didSet { Settings.grabKey = grabKey }
    }
    @Published var landsAnywhere = Settings.landsAnywhere {
        didSet { Settings.landsAnywhere = landsAnywhere }
    }
    @Published var soundEnabled = Settings.soundEnabled {
        didSet {
            Settings.soundEnabled = soundEnabled
            onSoundChange(soundEnabled)
        }
    }
    @Published var opensAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard opensAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            try? opensAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            opensAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
    @Published private(set) var accessibility = Permissions.accessibility
    @Published private(set) var screenRecording = Permissions.screenRecording
    /// Set once the user has opened the Screen Recording settings, since macOS only applies that
    /// permission after a relaunch.
    @Published private(set) var askedForScreenRecording = false

    var allGranted: Bool { accessibility && screenRecording }
    var onSoundChange: (Bool) -> Void = { _ in }

    private var timer: Timer?
    private var watchers = 0

    /// Starts polling permissions; balance with `stopWatching()`.
    func startWatching() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        if accessibility != Permissions.accessibility { accessibility.toggle() }
        if screenRecording != Permissions.screenRecording { screenRecording.toggle() }
    }

    func grantAccessibility() {
        Permissions.requestAccessibility()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func grantScreenRecording() {
        Permissions.requestScreenRecording()
        askedForScreenRecording = true
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    /// Quits and reopens Liftoff, which is how a new Screen Recording permission takes effect.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// The Liftoff icon, which can be dragged straight into a privacy list in System Settings.
struct DraggableAppIcon: View {
    var size: CGFloat = 44

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            .help("Drag Liftoff into the list in System Settings")
    }
}

/// One permission: whether it's granted, and how to grant it.
struct PermissionRow: View {
    let title: String
    let granted: Bool
    let grant: () -> Void
    var needsRelaunch = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            DraggableAppIcon(size: 36)
                .opacity(granted ? 0.4 : 1)
            Text(title).font(.headline)
            Spacer(minLength: 12)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else if needsRelaunch {
                Button("Relaunch") { Preferences.relaunch() }
                    .help("macOS applies Screen Recording after Liftoff restarts")
            } else {
                Button("Open Settings", action: grant)
            }
        }
        .animation(.spring(duration: 0.35), value: granted)
    }
}
