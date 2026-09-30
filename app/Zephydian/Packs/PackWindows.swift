import AppKit
import SwiftUI

/// Windows opened by utilities with the `windows` capability (SDK 3), such as an image editor.
/// Each window runs its own copy of the pack (a separate JavaScript context started with the
/// window's input), so closing it stops everything it was doing. While any is open, Zephydian shows
/// in the Dock and ⌘-Tab like a normal app, and goes back to being a menu bar app after the last one.
final class PackWindows: NSObject, NSWindowDelegate {
    private final class Entry {
        let packID: String
        let window: NSWindow
        let session: PackSession
        let host: Host
        let input: [String: Any]

        init(packID: String, window: NSWindow, session: PackSession, host: Host, input: [String: Any]) {
            self.packID = packID; self.window = window; self.session = session; self.host = host; self.input = input
        }
    }

    /// Carries out what the pack asks of its window.
    private final class Host: PackWindowHost {
        weak var window: NSWindow?

        func packWindowTitle(_ title: String) { if !title.isEmpty { window?.title = title } }
        func packWindowEdited(_ edited: Bool) { window?.isDocumentEdited = edited }
        func packWindowClose() { window?.close() }            // no second ask: the pack decided

        func packWindowConfirm(title: String, message: String?, button: String, destructive: Bool, done: @escaping (Bool) -> Void) {
            guard let window else { return done(false) }
            let alert = NSAlert()
            alert.messageText = title
            if let message { alert.informativeText = message }
            let confirm = alert.addButton(withTitle: button)
            confirm.hasDestructiveAction = destructive
            alert.addButton(withTitle: "Cancel")
            nonisolated(unsafe) let done = done
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { done(response == .alertFirstButtonReturn) }
            }
        }

        func packWindowChoose(title: String, message: String?, buttons: [(label: String, destructive: Bool)], done: @escaping (Int) -> Void) {
            guard let window, !buttons.isEmpty else { return done(-1) }
            let alert = NSAlert()
            alert.messageText = title
            if let message { alert.informativeText = message }
            for b in buttons { alert.addButton(withTitle: b.label).hasDestructiveAction = b.destructive }
            let cancel = alert.addButton(withTitle: "Cancel")
            cancel.keyEquivalent = "\u{1b}"
            let count = buttons.count
            nonisolated(unsafe) let done = done
            alert.beginSheetModal(for: window) { response in
                let i = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                MainActor.assumeIsolated { done(i >= 0 && i < count ? i : -1) }
            }
        }

        /// The editor keeps its dark artboard in light mode too, like a photo editor.
        func packWindowAppearance(_ mode: String) {
            guard let window else { return }
            let dark = mode == "dark"
            window.appearance = dark ? NSAppearance(named: .darkAqua) : nil
            window.backgroundColor = dark ? NSColor(white: 0.115, alpha: 1) : .windowBackgroundColor
            window.titlebarAppearsTransparent = dark
            forcedDark = dark
        }

        var forcedDark = false
    }

    private unowned let services: PackServices
    private var entries: [Entry] = []
    private var keyMonitor: Any?

    init(services: PackServices) { self.services = services }

    var count: Int { entries.count }

    /// Whether an open window is working on this image ("image:<id>" or its bare id).
    func isShowing(image id: String) -> Bool {
        entries.contains { ($0.input["image"] as? String).map { $0 == id || $0 == "image:\(id)" } ?? false }
    }

    /// Opens a new window running `bundle`, which gets `input` (JSON) in its window's `start`.
    func open(_ bundle: PackBundle, input json: String) {
        guard bundle.manifest.capabilities?.contains("windows") == true else { return }
        let input = PackRuntime.jsonObject(json) ?? [:]
        let session = PackSession(bundle: bundle, mode: .window(input: json))
        let host = Host()
        session.windowHost = host

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize(for: input)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        host.window = window
        window.title = bundle.manifest.name
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 780, height: 500)
        window.delegate = self
        window.appearance = services.settings?.appearance.nsAppearance
        let settings = services.settings ?? SettingsStore()
        window.contentView = NSHostingView(rootView: PackWindowView(session: session, close: { [weak window] in window?.close() })
            .environment(settings)
            .environment(services))
        // Each new window a little lower and to the right of the last one.
        if let last = entries.last?.window {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        } else {
            window.center()
        }

        let first = entries.isEmpty
        entries.append(Entry(packID: bundle.id, window: window, session: session, host: host, input: input))
        if first {
            NSApp.setActivationPolicy(.regular)                // Dock icon and ⌘-Tab while it's open
            startKeyMonitor()
        }
        services.hidePanel()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Brings the open windows forward (clicking the Dock icon). False if there are none.
    func showAll() -> Bool {
        guard !entries.isEmpty else { return false }
        NSApp.activate()
        entries.forEach { $0.window.makeKeyAndOrderFront(nil) }
        return true
    }

    /// The pack was removed: its windows close without asking.
    func closeAll(packID: String) {
        for entry in entries where entry.packID == packID { entry.window.close() }
    }

    /// The window's appearance follows the app's Appearance setting.
    func applyAppearance(_ appearance: NSAppearance?) {
        entries.filter { !$0.host.forcedDark }.forEach { $0.window.appearance = appearance }
    }

    private func initialSize(for input: [String: Any]) -> NSSize {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let scale = screen?.backingScaleFactor ?? 2
        var size = NSSize(width: 900, height: 640)
        if let image = (input["image"] as? String).flatMap({ services.images.entry($0) }) {
            // The picture at its size on this screen, plus room for the tool rail and the bars.
            size = NSSize(width: CGFloat(image.image.width) / scale + 110, height: CGFloat(image.image.height) / scale + 140)
        }
        return NSSize(width: min(max(size.width, 900), visible.width * 0.85),
                      height: min(max(size.height, 600), visible.height * 0.85))
    }

    // MARK: Keys

    /// ⌘Z / ⇧⌘Z undo and redo, ⌘W closes, and other keys (⌘C, ⌘S, Esc, letters) go to the pack.
    /// While a text field has the cursor, it gets its keys as usual.
    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let entry = self.entries.first(where: { $0.window === event.window }) else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) {
                switch key {
                case "z": return (flags.contains(.shift) ? entry.session.redo() : entry.session.undo()) ? nil : event
                case "w": entry.window.performClose(nil); return nil
                case "q", "h", "m", ",", "`": return event            // the app's own menu
                default: break
                }
            }
            return entry.session.windowKey(event) ? nil : event
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        entries.first { $0.window === sender }?.session.shouldClose() ?? true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let i = entries.firstIndex(where: { $0.window === window }) else { return }
        let entry = entries.remove(at: i)
        entry.session.pause()
        // Let the window finish closing before its view (and the pack with it) goes away.
        Task { @MainActor in window.contentView = nil }
        if let image = entry.input["image"] as? String, !isShowing(image: image) {
            services.images.forget(image)
        }
        if entries.isEmpty {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            NSApp.setActivationPolicy(.accessory)             // back to a menu bar app
        }
    }
}
