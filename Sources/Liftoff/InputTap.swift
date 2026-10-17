import CoreGraphics
import os

let logger = Logger(subsystem: "run.lil.liftoff", category: "input")

/// Watches mouse and modifier events system-wide. A left-drag that starts with the grab key held
/// is swallowed and reported through the callbacks; everything else passes through untouched.
final class InputTap {
    var modifier: () -> CGEventFlags = { [.maskControl, .maskAlternate, .maskShift, .maskCommand] }
    var onModifierPressed: () -> Void = {}
    var onDown: (CGPoint) -> Bool = { _ in false }
    var onDrag: (CGPoint) -> Void = { _ in }
    var onUp: (CGPoint) -> Void = { _ in }

    private var tap: CFMachPort?
    private var consuming = false
    private var modifierWasDown = false
    /// Modifiers from the latest flagsChanged event. Tools that synthesize modifiers (Raycast's Hyper key)
    /// announce them this way but don't stamp them onto the mouse events that follow.
    private var announcedFlags: CGEventFlags = []

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // Last in the session chain, so modifiers that other tools add in software
        // (e.g. Raycast turning Caps Lock into Hyper) are already on the event.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let input = Unmanaged<InputTap>.fromOpaque(refcon!).takeUnretainedValue()
                return input.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Could not create event tap")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        logger.notice("Event tap running")
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            announcedFlags = event.flags
            let down = isGrabKeyDown(event)
            if down && !modifierWasDown { onModifierPressed() }
            modifierWasDown = down
        case .leftMouseDown:
            if isGrabKeyDown(event) {
                let grabbed = onDown(event.location)
                logger.notice("Grab key click at \(event.location.debugDescription, privacy: .public): \(grabbed ? "grabbed" : "nothing to grab", privacy: .public)")
                guard grabbed else { break }
                consuming = true
                return nil
            }
        case .leftMouseDragged where consuming:
            onDrag(event.location)
            return nil
        case .leftMouseUp where consuming:
            consuming = false
            onUp(event.location)
            return nil
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func isGrabKeyDown(_ event: CGEvent) -> Bool {
        event.flags
            .union(announcedFlags)
            .union(CGEventSource.flagsState(.combinedSessionState))
            .contains(modifier())
    }
}
