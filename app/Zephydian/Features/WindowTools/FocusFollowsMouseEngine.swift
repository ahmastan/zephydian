import AppKit
import ApplicationServices

/// Focus follows mouse: the window under the pointer comes forward once the pointer rests on it.
///
/// It checks where the pointer is ten times a second (like Zephydian's corner trigger), which costs
/// far less than receiving every mouse movement (that measured 2–5% CPU while the mouse moved). It
/// does nothing while a mouse button is held, over the menu bar, the Dock, menus or the desktop.
final class FocusFollowsMouseEngine: FeatureEngine {
    private let settings = WindowToolsSettings.shared
    private var timer: Timer?
    private var lastPoint: CGPoint = .zero
    private var restingSince = Date()
    private var handledPoint: CGPoint?

    func start() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        if point != lastPoint {
            lastPoint = point
            restingSince = Date()
            handledPoint = nil
            return
        }
        guard handledPoint != point, NSEvent.pressedMouseButtons == 0,
              Date().timeIntervalSince(restingSince) * 1000 >= Double(settings.focusDelay) else { return }
        handledPoint = point
        let target = SystemWindows.serverPoint(point)
        let ignored = settings.focusIgnoredApps
        // Off the main thread: asking an app about its windows can take a moment.
        Task.detached(priority: .userInitiated) {
            guard let window = Self.windowToFocus(at: target, ignored: ignored) else { return }
            await MainActor.run { SystemWindows.focus(window) }
        }
    }

    /// The ordinary app window under the point, if it isn't already the front window.
    private nonisolated static func windowToFocus(at point: CGPoint, ignored: [String]) -> SystemWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        // The frontmost window under the pointer, whatever its kind.
        guard let top = list.first(where: { info in
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return false }
            return rect.contains(point)
        }) else { return nil }
        // Only ordinary app windows (not the menu bar, Dock, menus or Zephydian's own panels).
        guard (top[kCGWindowLayer as String] as? Int) == 0,
              let pid = top[kCGWindowOwnerPID as String] as? pid_t, pid != ProcessInfo.processInfo.processIdentifier,
              let id = top[kCGWindowNumber as String] as? CGWindowID,
              let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
              !(app.bundleIdentifier.map(ignored.contains) ?? false) else { return nil }
        // Already the front window of the front app: nothing to do.
        if app == NSWorkspace.shared.frontmostApplication {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.15)
            if let focused = SystemWindows.copy(element, kAXFocusedWindowAttribute),
               WindowServer.windowID(of: focused as! AXUIElement) == id { return nil }
        }
        return SystemWindows.windows(of: app, allSpaces: false).first { $0.id == id }
    }
}
