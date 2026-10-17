import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
}

/// Finding, reading and moving other apps' windows. All rects are in global top-left coordinates.
enum WindowSystem {
    /// Normal app windows currently on screen, front to back.
    static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = getpid()
        return list.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 80, frame.height >= 50
            else { return nil }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }
            return WindowInfo(id: id, pid: pid, frame: frame)
        }
    }

    static func window(at point: CGPoint) -> WindowInfo? {
        onScreenWindows().first { $0.frame.contains(point) }
    }

    /// The window's Accessibility element, if its position can be changed.
    static func element(for window: WindowInfo) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }

        let byID = windows.first { element in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(element, &id) == .success && id == window.id
        }
        let byFrame = windows.first { element in
            guard let frame = frame(of: element) else { return false }
            return abs(frame.minX - window.frame.minX) < 2 && abs(frame.minY - window.frame.minY) < 2
                && abs(frame.width - window.frame.width) < 2 && abs(frame.height - window.frame.height) < 2
        }
        guard let element = byID ?? byFrame else { return nil }

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable) == .success,
              settable.boolValue
        else { return nil }
        return element
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    static func move(_ element: AXUIElement, pid: pid_t, to origin: CGPoint) {
        // Apps with AXEnhancedUserInterface on animate AX moves; switch it off around the move.
        let app = AXUIElementCreateApplication(pid)
        let enhanced = "AXEnhancedUserInterface" as CFString
        var current: CFTypeRef?
        let wasEnhanced = AXUIElementCopyAttributeValue(app, enhanced, &current) == .success
            && (current as? Bool) == true
        if wasEnhanced { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanFalse) }

        var point = origin
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }

        if wasEnhanced { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanTrue) }
    }

    static func resize(_ element: AXUIElement, to size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }

    /// Accessibility calls are synchronous IPC into the other app and can stall for a while
    /// (busy or Electron apps), so moves that happen mid-flight go through this queue.
    private static let moveQueue = DispatchQueue(label: "run.lil.liftoff.move", qos: .userInteractive)

    /// `raise` also brings it to the front of its app, so a landed window doesn't vanish behind
    /// others as its snapshot goes. It doesn't activate the app: the snapshot was taken inactive,
    /// and switching to active styling the instant it lands would be a visible pop.
    static func moveInBackground(_ element: AXUIElement, pid: pid_t, to origin: CGPoint, raise: Bool = false,
                                 then completion: @escaping @MainActor () -> Void = {}) {
        moveQueue.async {
            AXUIElementSetMessagingTimeout(element, 0.5)
            move(element, pid: pid, to: origin)
            if raise { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion()
                }
            }
        }
    }

    /// Where a window waits while its snapshot flies. macOS keeps a sliver of it on screen,
    /// so tuck it into the bottom-right corner of the main display.
    static var parkingSpot: CGPoint {
        let main = cgFrame(of: NSScreen.screens[0])
        return CGPoint(x: main.maxX - 1, y: main.maxY - 1)
    }

    static func cgFrame(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens[0].frame.height
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    /// Each display's area for flying and landing: below the menu bar, inside a safe margin at the
    /// sides, and with the floor on top of the Dock, or a safe margin above the screen's bottom edge
    /// when the Dock is hidden or elsewhere.
    /// Extra height to raise the floor by, for staging demo recordings.
    @MainActor static var floorLift: CGFloat = 0

    @MainActor static var usableAreas: [CGRect] {
        let primaryHeight = NSScreen.screens[0].frame.height
        let margin: CGFloat = 32
        return NSScreen.screens.map { screen in
            let full = screen.frame, visible = screen.visibleFrame
            let dockBelow = visible.minY > full.minY + 1
            var area = CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
            area = area.insetBy(dx: margin, dy: 0)
            if !dockBelow { area.size.height -= margin }
            area.size.height -= floorLift
            return area
        }
    }

    static var desktopBounds: CGRect {
        NSScreen.screens.map(cgFrame(of:)).reduce(CGRect.null) { $0.union($1) }
    }
}
