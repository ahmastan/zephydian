import AppKit
import ApplicationServices

/// An icon in the Dock.
struct DockItem: Equatable {
    let title: String
    /// The app's bundle, for app icons.
    let url: URL?
    /// Window-server coordinates (top-left origin) when it was hovered. The Dock may still be moving
    /// (sliding in, magnifying), so read `currentFrame` for where it is now.
    let frame: CGRect
    let isApp: Bool
    let element: AXUIElement

    /// The same icon, whatever its size or position right now.
    static func == (a: DockItem, b: DockItem) -> Bool {
        a.title == b.title && a.url == b.url && a.isApp == b.isApp
    }

    /// Where the icon is now (window-server coordinates), or nil if it can't be read.
    var currentFrame: CGRect? { SystemWindows.frame(of: element) }

    /// The running app this icon stands for, if it's running. Matched by its bundle ID first: an app
    /// macOS runs from a temporary copy ("App Translocation", for apps still marked as downloaded)
    /// has a different path than its Dock icon.
    var runningApp: NSRunningApplication? {
        guard isApp else { return nil }
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let url, let id = Bundle(url: url)?.bundleIdentifier,
           let app = regular.first(where: { $0.bundleIdentifier == id }) {
            return app
        }
        if let path = url?.standardizedFileURL, let app = regular.first(where: { $0.bundleURL?.standardizedFileURL == path }) {
            return app
        }
        return regular.first { $0.localizedName == title }
    }
}

/// Tells which Dock icon the pointer is on, without watching the mouse: the Dock itself announces
/// it through Accessibility (its list's selected item changes as you hover). It also notices when the
/// Dock restarts.
final class DockWatcher {
    /// The icon under the pointer, or nil when the pointer leaves the Dock.
    var onHover: (DockItem?) -> Void = { _ in }
    private(set) var hovered: DockItem?

    private var observer: AXObserver?
    private var list: AXUIElement?
    private var relaunchObserver: NSObjectProtocol?
    private var retry: Task<Void, Never>?

    func start() {
        attach()
        // The Dock restarts sometimes (a crash, `killall Dock`, some settings): watch the new one.
        relaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.dock" else { return }
            MainActor.assumeIsolated { self?.reattachSoon() }
        }
    }

    func stop() {
        retry?.cancel()
        detach()
        if let relaunchObserver { NSWorkspace.shared.notificationCenter.removeObserver(relaunchObserver) }
        relaunchObserver = nil
    }

    /// Which side of the screen the Dock is on.
    static var edge: NSRectEdge {
        switch CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String {
        case "left": .minX
        case "right": .maxX
        default: .minY
        }
    }

    // MARK: Private

    private func reattachSoon() {
        detach()
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            // The new Dock needs a moment before its icons can be read.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                if self.attach() { return }
            }
        }
    }

    @discardableResult
    private func attach() -> Bool {
        guard observer == nil,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
        let pid = dock.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        guard let children = SystemWindows.copy(app, kAXChildrenAttribute) as? [AXUIElement],
              let list = children.first(where: { SystemWindows.copy($0, kAXRoleAttribute) as? String == kAXListRole }) else { return false }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<DockWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.selectionChanged() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return false }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created, list, kAXSelectedChildrenChangedNotification as CFString, refcon) == .success else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        self.list = list
        return true
    }

    private func detach() {
        if let observer, let list {
            AXObserverRemoveNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        list = nil
        if hovered != nil {
            hovered = nil
            onHover(nil)
        }
    }

    private func selectionChanged() {
        guard let list else { return }
        let selected = (SystemWindows.copy(list, kAXSelectedChildrenAttribute) as? [AXUIElement])?.first
        let item = selected.flatMap(Self.item)
        guard item != hovered else { return }
        hovered = item
        onHover(item)
    }

    private static func item(_ element: AXUIElement) -> DockItem? {
        guard let frame = SystemWindows.frame(of: element) else { return nil }
        let subrole = SystemWindows.copy(element, kAXSubroleAttribute) as? String
        let url = SystemWindows.copy(element, kAXURLAttribute) as? URL
        return DockItem(title: (SystemWindows.copy(element, kAXTitleAttribute) as? String) ?? "",
                        url: url, frame: frame, isApp: subrole == "AXApplicationDockItem", element: element)
    }
}
