import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum GrabKey: String, CaseIterable {
    case hyper, controlOption, optionCommand, controlCommand

    var flags: CGEventFlags {
        switch self {
        case .hyper: [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        case .controlOption: [.maskControl, .maskAlternate]
        case .optionCommand: [.maskAlternate, .maskCommand]
        case .controlCommand: [.maskControl, .maskCommand]
        }
    }

    var symbols: String {
        switch self {
        case .hyper: "Hyper (⌃⌥⇧⌘)"
        case .controlOption: "⌃⌥"
        case .optionCommand: "⌥⌘"
        case .controlCommand: "⌃⌘"
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    static var grabKey: GrabKey {
        get { defaults.string(forKey: "grabKey").flatMap(GrabKey.init) ?? .hyper }
        set { defaults.set(newValue.rawValue, forKey: "grabKey") }
    }

    static var soundEnabled: Bool {
        get { defaults.object(forKey: "soundEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "soundEnabled") }
    }

    static var landsAnywhere: Bool {
        get { defaults.object(forKey: "landsAnywhere") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "landsAnywhere") }
    }

    static var hasOnboarded: Bool {
        get { defaults.bool(forKey: "hasOnboarded") }
        set { defaults.set(newValue, forKey: "hasOnboarded") }
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var allGranted: Bool { accessibility && screenRecording }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Asking ScreenCaptureKit for content is what reliably lists the app in System Settings on recent macOS.
    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        Task { _ = try? await SCShareableContent.current }
    }
}
