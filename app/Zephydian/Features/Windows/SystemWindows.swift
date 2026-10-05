import AppKit
import ApplicationServices

/// One of another app's windows, as Dock Preview and the app switcher show it. Safe to pass between
/// threads: Accessibility elements are thread-safe.
nonisolated struct SystemWindow: Identifiable, @unchecked Sendable {
    let id: CGWindowID
    let pid: pid_t
    var title: String
    /// Window-server coordinates: top-left origin, in points.
    var frame: CGRect
    var isMinimized: Bool
    var isFullScreen: Bool
    /// It lives only on desktops the person isn't looking at.
    var isOnOtherSpace: Bool
    /// Its app is hidden (⌘H).
    var isAppHidden: Bool
    /// Front-to-back position among all windows (0 is frontmost), for "most recently used" order.
    var stackOrder: Int
    /// The Accessibility handle, for closing, minimizing and moving. nil for a window on another
    /// desktop, which Accessibility can't see.
    let element: AXUIElement?

    var canBeControlled: Bool { element != nil }
}

/// A window as the window server lists it.
nonisolated struct ServerWindow: Sendable {
    let title: String
    let frame: CGRect
    /// Front-to-back position among all windows.
    let order: Int
}

/// Reads and arranges other apps' windows through Accessibility and the window server. Reading works
/// on any thread (the switcher reads off the main thread, so slow apps never hold up the keyboard).
nonisolated enum SystemWindows {
    /// The app's real windows: Accessibility's list (this desktop, plus minimized ones), plus,
    /// when `allSpaces`, the ones the window server knows on other desktops. Pass `server` (from
    /// `serverWindows()`) when reading many apps at once, so the system's list is read only once.
    static func windows(of app: NSRunningApplication, allSpaces: Bool, server: [CGWindowID: ServerWindow]? = nil) -> [SystemWindow] {
        let pid = app.processIdentifier
        let server = server ?? serverWindows()[pid] ?? [:]
        var result: [SystemWindow] = []
        var seen: Set<CGWindowID> = []

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.15)   // a slow or frozen app mustn't hold Zephydian up
        for element in (copy(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            guard let id = WindowServer.windowID(of: element), seen.insert(id).inserted,
                  isStandard(element) else { continue }
            let info = server[id]
            result.append(SystemWindow(
                id: id, pid: pid,
                title: (copy(element, kAXTitleAttribute) as? String) ?? info?.title ?? "",
                frame: frame(of: element) ?? info?.frame ?? .zero,
                isMinimized: (copy(element, kAXMinimizedAttribute) as? Bool) ?? false,
                isFullScreen: (copy(element, "AXFullScreen") as? Bool) ?? false,
                isOnOtherSpace: false,
                isAppHidden: app.isHidden,
                stackOrder: info?.order ?? Int.max,
                element: element))
        }

        if allSpaces, let active = WindowServer.activeSpace {
            for (id, info) in server where !seen.contains(id) {
                // Real windows belong to at least one desktop; leftovers belong to none.
                guard let spaces = WindowServer.spaces(of: id), !spaces.isEmpty, !spaces.contains(active) else { continue }
                result.append(SystemWindow(
                    id: id, pid: pid, title: info.title, frame: info.frame,
                    isMinimized: false, isFullScreen: false, isOnOtherSpace: true, isAppHidden: app.isHidden,
                    stackOrder: info.order, element: nil))
            }
        }
        return result
    }

    /// Every process's normal-layer windows, by process and id, with their front-to-back order.
    static func serverWindows() -> [pid_t: [CGWindowID: ServerWindow]] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var out: [pid_t: [CGWindowID: ServerWindow]] = [:]
        for (order, info) in list.enumerated() {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 60, rect.height >= 40 else { continue }
            out[pid, default: [:]][id] = ServerWindow(title: (info[kCGWindowName as String] as? String) ?? "", frame: rect, order: order)
        }
        return out
    }

    private static func isStandard(_ element: AXUIElement) -> Bool {
        let role = copy(element, kAXRoleAttribute) as? String
        let subrole = copy(element, kAXSubroleAttribute) as? String
        return role == kAXWindowRole && (subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole)
    }

    // MARK: Actions

    /// Brings the window forward and its app with it: restoring it if minimized, unhiding the app,
    /// and travelling to its desktop if it's on another one.
    static func focus(_ window: SystemWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        if app.isHidden { app.unhide() }
        if !bringForward(window) { app.activate() }
    }

    /// Restores the window if minimized, makes it its app's main and focused window and raises it
    /// (Accessibility), then brings it and its app to the front through the window server.
    /// False if the window server part isn't available.
    static func bringForward(_ window: SystemWindow) -> Bool {
        if let element = window.element {
            AXUIElementSetMessagingTimeout(element, 0.35)
            if (copy(element, kAXMinimizedAttribute) as? Bool) == true {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let app = AXUIElementCreateApplication(window.pid)
            AXUIElementSetMessagingTimeout(app, 0.35)
            AXUIElementSetAttributeValue(app, kAXMainWindowAttribute as CFString, element)
            AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        return WindowServer.bringForward(pid: window.pid, window: window.id)
    }

    /// Presses the window's close button (the app may ask to save first).
    static func close(_ window: SystemWindow) {
        guard let element = window.element,
              let button = copy(element, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    static func setMinimized(_ window: SystemWindow, _ minimized: Bool) {
        guard let element = window.element else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Moves the window's top-left corner to a point in window-server coordinates (top-left origin).
    static func move(_ window: SystemWindow, topLeft: CGPoint) {
        guard let element = window.element else { return }
        var point = topLeft
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    // MARK: Helpers

    static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = copy(element, kAXPositionAttribute), let size = copy(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Converts a window-server rectangle (top-left origin) to AppKit's (bottom-left origin).
    static func appKitRect(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts an AppKit rectangle (bottom-left origin) to window-server coordinates (top-left origin).
    static func serverRect(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts an AppKit point (bottom-left origin) to window-server coordinates (top-left origin).
    static func serverPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    }
}
