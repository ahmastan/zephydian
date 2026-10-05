import AppKit

/// Zephydian is a menu bar app, but while one of its normal windows is open (Settings, a utility's
/// window) it shows in the Dock and ⌘-Tab, and gets a menu bar. Each window says when it opens
/// and closes; the Dock icon stays until the last one is gone.
enum DockPresence {
    private static var reasons: Set<String> = []

    static func add(_ reason: String) {
        let first = reasons.isEmpty
        reasons.insert(reason)
        if first { NSApp.setActivationPolicy(.regular) }
    }

    static func remove(_ reason: String) {
        guard reasons.remove(reason) != nil, reasons.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
