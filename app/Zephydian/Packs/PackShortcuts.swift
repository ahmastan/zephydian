import AppKit
import Observation

/// A utility's own global shortcut (the `shortcut` capability), recorded by the person in the
/// utility's shortcut field. Pressing it opens the panel on that utility (a screenshot utility takes
/// an Area shot instead). Observable, so shortcut fields and their warnings update right away.
@Observable
final class PackShortcuts {
    /// Opens the panel on a pack. Set by AppDelegate.
    @ObservationIgnored var onOpen: (String) -> Void = { _ in }
    @ObservationIgnored var defaults: UserDefaults = .standard

    /// Each utility's shortcut, and the ones that couldn't be registered (another app has them).
    private(set) var shortcuts: [String: KeyShortcut] = [:]
    private(set) var failed: Set<String> = []
    @ObservationIgnored private var hotKeys: [String: GlobalHotKey] = [:]
    @ObservationIgnored private var nextID: UInt32 = 100

    func current(packID: String) -> KeyShortcut? {
        if let s = shortcuts[packID] { return s }
        return defaults.data(forKey: key(packID)).flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) }
    }

    /// Sets (or with nil, removes) a utility's shortcut. Returns false if it couldn't be registered.
    @discardableResult
    func set(packID: String, _ shortcut: KeyShortcut?) -> Bool {
        hotKeys.removeValue(forKey: packID)?.unregister()
        failed.remove(packID)
        guard let shortcut else {
            shortcuts[packID] = nil
            defaults.removeObject(forKey: key(packID))
            return true
        }
        shortcuts[packID] = shortcut
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: key(packID))
        return register(packID: packID, shortcut)
    }

    /// At launch: registers the shortcut a utility had.
    func restore(packID: String) {
        guard let shortcut = current(packID: packID) else { return }
        shortcuts[packID] = shortcut
        _ = register(packID: packID, shortcut)
    }

    func remove(packID: String) { _ = set(packID: packID, nil) }

    private func register(packID: String, _ shortcut: KeyShortcut) -> Bool {
        let hotKey = GlobalHotKey(id: nextID)
        nextID += 1
        hotKey.onPress = { [weak self] in self?.onOpen(packID) }
        let ok = hotKey.register(shortcut)
        if ok { hotKeys[packID] = hotKey } else { failed.insert(packID) }
        return ok
    }

    private func key(_ packID: String) -> String { "pack.\(packID).hotkey" }
}
