import AppKit
import Carbon.HIToolbox

/// Settings for the Clipboard, files and links features, saved as they change.
@Observable
final class ClipboardToolsSettings {
    static let shared = ClipboardToolsSettings()

    // Paste as plain text
    var plainPasteShortcut: KeyShortcut? { didSet { saveShortcut("plainPasteShortcut", plainPasteShortcut) } }

    // Auto-clear: seconds after the last copy (0 = not after a time), and on sleep and lock.
    var clearAfter: Int { didSet { save("clearAfter", clearAfter) } }
    var clearOnSleep: Bool { didSet { save("clearOnSleep", clearOnSleep) } }
    var clearOnLock: Bool { didSet { save("clearOnLock", clearOnLock) } }

    // Clean URLs
    var cleanIgnoredApps: [String] { didSet { save("cleanIgnoredApps", cleanIgnoredApps) } }

    // Finder shortcuts

    // Shelf
    enum ShelfOpening: String, CaseIterable, Identifiable {
        case shake, corner
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shake: "Shaking while dragging"
            case .corner: "Opening the corner panel as you drag"
            }
        }
    }
    var shelfOpening: ShelfOpening { didSet { save("shelfOpening", shelfOpening.rawValue) } }
    var shelfShortcut: KeyShortcut? { didSet { saveShortcut("shelfShortcut", shelfShortcut) } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: "clipTools.\(key)") as? T ?? fallback }
        func shortcut(_ key: String, _ fallback: KeyShortcut?) -> KeyShortcut? {
            guard let data = defaults.data(forKey: "clipTools.\(key)") else { return fallback }
            return try? JSONDecoder().decode(KeyShortcut?.self, from: data)
        }
        plainPasteShortcut = shortcut("plainPasteShortcut", KeyShortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.option, .shift, .command], key: "V"))
        clearAfter = value("clearAfter", 120)
        clearOnSleep = value("clearOnSleep", true)
        clearOnLock = value("clearOnLock", true)
        cleanIgnoredApps = value("cleanIgnoredApps", [String]())
        // "both" existed briefly; the corner is what it was used for.
        let opening: String = value("shelfOpening", "")
        shelfOpening = opening == "both" ? .corner : ShelfOpening(rawValue: opening) ?? .shake
        shelfShortcut = shortcut("shelfShortcut", nil)
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: "clipTools.\(key)") }
    private func saveShortcut(_ key: String, _ shortcut: KeyShortcut?) {
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: "clipTools.\(key)")
    }
}

/// Notices when the clipboard changes. macOS has no notification for it, so this compares the
/// clipboard's change count twice a second, the cheapest check there is, and only while at least
/// one feature is listening.
final class PasteboardWatcher {
    static let shared = PasteboardWatcher()

    private var listeners: [ObjectIdentifier: (Int) -> Void] = [:]
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    /// Changes Zephydian makes itself, which listeners don't hear about.
    private var own: Set<Int> = []

    func listen(_ owner: AnyObject, _ changed: @escaping (Int) -> Void) {
        listeners[ObjectIdentifier(owner)] = changed
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopListening(_ owner: AnyObject) {
        listeners[ObjectIdentifier(owner)] = nil
        if listeners.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Call right after Zephydian writes to the clipboard itself.
    func markOwnChange() {
        own.insert(NSPasteboard.general.changeCount)
        lastChange = NSPasteboard.general.changeCount
    }

    private func check() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChange else { return }
        lastChange = count
        if own.remove(count) != nil { return }
        listeners.values.forEach { $0(count) }
    }
}
