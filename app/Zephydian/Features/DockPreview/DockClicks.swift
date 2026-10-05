import AppKit

/// Clicking the Dock icon of the app you're already in: minimize its windows, hide it, or show its
/// next window (Settings → Dock Preview). A listen-only event tap sees mouse clicks (nothing else),
/// and only while that setting isn't "Nothing".
final class DockClicks {
    private let watcher: DockWatcher
    private let settings: DockPreviewSettings
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var running = false

    init(watcher: DockWatcher, settings: DockPreviewSettings) {
        self.watcher = watcher
        self.settings = settings
    }

    func start() {
        running = true
        follow()
    }

    func stop() {
        running = false
        removeTap()
    }

    /// Installs the tap only while a click action is chosen, and follows the setting as it changes.
    private func follow() {
        guard running else { return }
        withObservationTracking {
            if settings.dockClick == .nothing { removeTap() } else { installTap() }
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let clicks = Unmanaged<DockClicks>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    EventTap.noteDisabled(type)
                    if let tap = clicks.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    clicks.clicked()
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask(1 << CGEventType.leftMouseDown.rawValue),
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// A click somewhere. Acts only on the Dock icon of the app that's already in front.
    private func clicked() {
        let action = settings.dockClick
        guard action != .nothing, let item = watcher.hovered, let app = item.runningApp,
              app == NSWorkspace.shared.frontmostApplication,
              item.frame.contains(SystemWindows.serverPoint(NSEvent.mouseLocation)) else { return }
        // Read the state now, before the Dock reacts to the click (it may restore a window itself).
        let windows = SystemWindows.windows(of: app, allSpaces: false).filter { $0.canBeControlled && !$0.isFullScreen }
        let anyShowing = windows.contains { !$0.isMinimized }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            switch action {
            case .nothing:
                break
            case .minimize:
                for window in windows { SystemWindows.setMinimized(window, anyShowing) }
            case .hide:
                if anyShowing { app.hide() }
            case .cycle:
                // Like ⌘`: the backmost window on this desktop comes to the front.
                let visible = windows.filter { !$0.isMinimized }.sorted { $0.stackOrder < $1.stackOrder }
                if visible.count > 1, let next = visible.last { SystemWindows.focus(next) }
            }
        }
    }
}
