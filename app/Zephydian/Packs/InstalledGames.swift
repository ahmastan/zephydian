import Foundation
import Observation

/// Which built-in games are "installed" (shown in the Games grid). The others wait in the Library
/// and install instantly, with no download. New users start with Snake, Stackr and Five; people
/// updating from an older version also keep every game they've already played.
@Observable
final class InstalledGames {
    static let shared = InstalledGames()

    /// What a new user starts with.
    static let starterIDs: Set<String> = ["snake", "stackr", "five"]

    /// Every key a built-in game saves starts with its prefix (ids and keys never change;
    /// Spokes is still `wheel`). Used to spot games already played and to delete progress.
    static let keyPrefixes: [String: String] = [
        "snake": "snake.", "stackr": "stackr.", "five": "five.", "wheel": "wheel.", "fleet": "fleet.",
        "airship": "airship.", "2048": "2048.", "mines": "mines.", "nines": "nines.",
    ]

    private(set) var ids: Set<String>
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateIfNeeded(defaults)
        ids = Set(defaults.stringArray(forKey: "packs.installed") ?? [])
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func install(_ id: String) {
        ids.insert(id)
        save()
    }

    /// Hides the game. Its saved games and best scores are kept for a reinstall unless `deleteProgress`.
    func remove(_ id: String, deleteProgress: Bool) {
        ids.remove(id)
        save()
        if deleteProgress, let prefix = Self.keyPrefixes[id] {
            for key in Self.savedKeys(prefix: prefix, in: defaults) { defaults.removeObject(forKey: key) }
        }
    }

    private func save() { defaults.set(ids.sorted(), forKey: "packs.installed") }

    // MARK: First launch of this version

    /// Runs once: the starter games, plus every built-in game with saved data (played, or at least
    /// opened, in an older version). A fresh install has no saved data, so it gets just the starters.
    static func migrateIfNeeded(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: "packs.migrated") else { return }
        var installed = starterIDs
        for (id, prefix) in keyPrefixes where !savedKeys(prefix: prefix, in: defaults).isEmpty {
            installed.insert(id)
        }
        defaults.set(installed.sorted(), forKey: "packs.installed")
        defaults.set(true, forKey: "packs.migrated")
    }

    /// The app's own saved keys that start with `prefix` (not system-wide ones).
    private static func savedKeys(prefix: String, in defaults: UserDefaults) -> [String] {
        let own = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) }
        let keys = own.map { Array($0.keys) } ?? Array(defaults.dictionaryRepresentation().keys)
        return keys.filter { $0.hasPrefix(prefix) }
    }
}
