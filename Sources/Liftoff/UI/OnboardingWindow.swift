import AppKit
import SwiftUI

@MainActor
final class OnboardingModel: ObservableObject {
    /// Flips once the window has touched down, which brings in the rest of the content.
    @Published var landed = false
}

struct OnboardingView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var model: OnboardingModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                Text("Liftoff")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Give your windows thrusters.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 34)

            if model.landed {
                VStack(alignment: .leading, spacing: 16) {
                    PermissionRow(
                        title: "Accessibility",
                        granted: preferences.accessibility,
                        grant: preferences.grantAccessibility
                    )
                    Divider()
                    PermissionRow(
                        title: "Screen Recording",
                        granted: preferences.screenRecording,
                        grant: preferences.grantScreenRecording,
                        needsRelaunch: preferences.askedForScreenRecording
                    )
                }
                .padding(18)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                .transition(.move(edge: .bottom).combined(with: .opacity))

                HStack(spacing: 8) {
                    Text("Hold")
                    Picker("Grab key", selection: $preferences.grabKey) {
                        ForEach(GrabKey.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("and fling a window.")
                }
                .foregroundStyle(.secondary)
                .transition(.opacity)

                Button(preferences.allGranted ? "Done" : "Later", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
        .animation(.spring(duration: 0.6, bounce: 0.25), value: model.landed)
        .animation(.spring(duration: 0.5), value: preferences.allGranted)
        .onAppear { preferences.startWatching() }
        .onDisappear { preferences.stopWatching() }
    }
}

/// The welcome window. It arrives the way Liftoff windows do: dropping in from above the screen
/// on its thrusters, hanging in a hover, then setting down in a puff of smoke.
@MainActor
final class OnboardingWindowController: NSObject {
    private var window: NSWindow?
    private let preferences: Preferences
    private let renderer: Renderer
    private let hiss: Hiss
    private let model = OnboardingModel()
    static let size = CGSize(width: 460, height: 500)
    private var flight: (start: CFTimeInterval, from: CGPoint, to: CGPoint)?
    private var displayLink: CADisplayLink?
    var onFinish: () -> Void = {}

    init(preferences: Preferences, renderer: Renderer, hiss: Hiss) {
        self.preferences = preferences
        self.renderer = renderer
        self.hiss = hiss
    }

    func show() {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        model.landed = Settings.welcomeHasFlown
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(
            preferences: preferences, model: model, done: { [weak self] in self?.finish() }))
        self.window = window

        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let landing = CGPoint(x: area.midX - Self.size.width / 2, y: area.midY - Self.size.height / 2)
        if Settings.welcomeHasFlown {
            window.setFrameOrigin(landing)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        Settings.welcomeHasFlown = true

        let start = CGPoint(x: landing.x + 140, y: screen.frame.maxY + 40)
        window.setFrameOrigin(start)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        flight = (CACurrentMediaTime(), start, landing)
        let link = window.contentView!.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    // Flight plan, in seconds: brake down from above the screen, hang in a hover, set down.
    private let approach = 1.1, hover = 0.7, settle = 0.45
    private let hoverHeight: CGFloat = 46

    @objc private func step(_ link: CADisplayLink) {
        guard let flight, let window else { return }
        let t = link.timestamp - flight.start
        let hoverPoint = CGPoint(x: flight.to.x, y: flight.to.y + hoverHeight)
        var origin: CGPoint
        var throttle: Double

        if t < approach {
            let s = t / approach, eased = 1 - pow(1 - s, 3)
            origin = CGPoint(x: flight.from.x + (hoverPoint.x - flight.from.x) * eased,
                             y: flight.from.y + (hoverPoint.y - flight.from.y) * eased)
            throttle = 0.6 + 0.9 * s  // braking harder as it arrives
        } else if t < approach + hover {
            let h = t - approach
            origin = CGPoint(x: hoverPoint.x + 4 * sin(h * 7), y: hoverPoint.y + 3 * sin(h * 9.5))
            throttle = 0.9
        } else if t < approach + hover + settle {
            let s = (t - approach - hover) / settle, eased = s * s * (3 - 2 * s)
            origin = CGPoint(x: flight.to.x, y: hoverPoint.y - hoverHeight * eased)
            throttle = 0.9 - 0.4 * s
        } else {
            land()
            return
        }

        window.setFrameOrigin(origin)
        renderer.showFreeJets(ports: jetPorts(for: window.frame), throttle: throttle)
        hiss.set(throttle * 0.8)
    }

    private func land() {
        guard let window, let flight else { return }
        window.setFrameOrigin(flight.to)
        displayLink?.invalidate()
        displayLink = nil
        self.flight = nil
        renderer.hideFreeJets()
        hiss.puff()
        let frame = global(window.frame)
        renderer.burst(at: Vec(Double(frame.midX), Double(frame.maxY)), width: Double(frame.width))
        model.landed = true
    }

    private func finish() {
        Settings.hasOnboarded = true
        window?.close()
        onFinish()
    }

    /// Nozzles along the bottom edge, in global top-left coordinates.
    private func jetPorts(for frame: NSRect) -> [Vec] {
        let g = global(frame)
        let y = Double(g.maxY) - 10
        return [Vec(Double(g.minX) + 30, y), Vec(Double(g.minX) + 90, y),
                Vec(Double(g.maxX) - 90, y), Vec(Double(g.maxX) - 30, y)]
    }

    private func global(_ frame: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens[0].frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
