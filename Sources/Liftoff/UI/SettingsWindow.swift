import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let showWelcome: () -> Void

    var body: some View {
        Form {
            Section {
                Picker("Grab key", selection: $preferences.grabKey) {
                    ForEach(GrabKey.allCases, id: \.self) { Text($0.symbols).tag($0) }
                }
                Picker("Land", selection: $preferences.landsAnywhere) {
                    Text("Wherever there's room").tag(true)
                    Text("Back where it started").tag(false)
                }
                Toggle("Thruster sound", isOn: $preferences.soundEnabled)
                Toggle("Open at login", isOn: $preferences.opensAtLogin)
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility",
                    granted: preferences.accessibility,
                    grant: preferences.grantAccessibility
                )
                PermissionRow(
                    title: "Screen Recording",
                    granted: preferences.screenRecording,
                    grant: preferences.grantScreenRecording,
                    needsRelaunch: preferences.askedForScreenRecording
                )
            }

            Section {
                HStack {
                    Text("Liftoff \(Bundle.main.version)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Welcome", action: showWelcome)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .onAppear { preferences.startWatching() }
        .onDisappear { preferences.stopWatching() }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let preferences: Preferences
    private let showWelcome: () -> Void

    init(preferences: Preferences, showWelcome: @escaping () -> Void) {
        self.preferences = preferences
        self.showWelcome = showWelcome
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Liftoff Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, showWelcome: showWelcome))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension Bundle {
    var version: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
