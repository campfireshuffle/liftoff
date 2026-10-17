import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var liftoff: Liftoff!
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private let preferences = Preferences()
    private lazy var settings = SettingsWindowController(
        preferences: preferences, showWelcome: { [weak self] in self?.onboarding.show() })
    private lazy var onboarding = OnboardingWindowController(
        preferences: preferences, renderer: liftoff.renderer, hiss: liftoff.hiss)

    func applicationDidFinishLaunching(_ notification: Notification) {
        liftoff = Liftoff()
        preferences.onSoundChange = { [weak self] enabled in self?.liftoff.hiss.isEnabled = enabled }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: "Liftoff")
        image?.isTemplate = true
        image?.accessibilityDescription = "Liftoff"
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !Permissions.allGranted || !Settings.hasOnboarded {
            // Give the menu bar and overlay a moment to settle before the welcome window flies in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.onboarding.show() }
        }
        startInputWhenTrusted()
    }

    func applicationWillTerminate(_ notification: Notification) {
        liftoff.landEverythingNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }

    private func startInputWhenTrusted() {
        if Permissions.accessibility && liftoff.input.start() { return }
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, Permissions.accessibility, self.liftoff.input.start() else { return }
                timer.invalidate()
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !Permissions.allGranted {
            menu.addItem(item("Finish Setting Up…", #selector(showWelcome)))
            menu.addItem(.separator())
        }
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Land All Windows Now", #selector(landNow)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Liftoff", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showSettings() { settings.show() }
    @objc private func showWelcome() { onboarding.show() }
    @objc private func landNow() { liftoff.landEverythingNow() }
    @objc private func quit() { NSApp.terminate(nil) }
}
