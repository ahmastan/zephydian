import AppKit
import Foundation
import Observation

/// The packs this Mac can run (installed ones, plus developer packs in debug builds), turned into
/// Games-grid entries.
@Observable
final class PackLibrary {
    static let shared = PackLibrary()

    private(set) var packs: [PackBundle] = []
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var fingerprint = ""

    /// ~/Library/Application Support/Zephydian/Packs.
    static var packsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Zephydian/Packs", directoryHint: .isDirectory)
    }

    /// Unsigned packs for contributors to test. Only debug builds ever read this folder.
    static var devDirectory: URL { packsDirectory.appending(path: "dev", directoryHint: .isDirectory) }

    /// Looks for added, changed or removed packs. Cheap: it reads a few small files.
    func refresh() {
        // Installed packs (verified when they were installed), then, in debug builds, developer packs.
        // A developer pack with an installed pack's id replaces it, so a new version can be tried out.
        let installed = Self.load(Self.subfolders(of: Self.packsDirectory).filter { !["dev", "dev-library"].contains($0.lastPathComponent) }, isDev: false)
        #if DEBUG
        try? FileManager.default.createDirectory(at: Self.devDirectory, withIntermediateDirectories: true)
        let dev = Self.load(Self.subfolders(of: Self.devDirectory), isDev: true)
        let loaded = installed.filter { pack in !dev.contains { $0.id == pack.id } } + dev
        #else
        let loaded = installed
        #endif
        // Only publish a change when something really changed, so the grid doesn't redraw for nothing.
        let print = loaded.map { "\($0.id)@\($0.manifest.version)#\($0.manifest.name)#\($0.isDev)" }.joined(separator: ",")
        guard print != fingerprint else { return }
        fingerprint = print
        icons = [:]
        packs = loaded
    }

    private static func subfolders(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func load(_ folders: [URL], isDev: Bool) -> [PackBundle] {
        folders.compactMap { folder in
            do { return try PackBundle.load(from: folder, isDev: isDev) } catch {
                #if DEBUG
                print("Pack \(folder.lastPathComponent) skipped: \(error)")
                #endif
                return nil
            }
        }
    }

    /// Games-grid entries for the game packs. A pack with a built-in game's id takes that game's place.
    var games: [GameInfo] { tiles(.game) }

    /// Utilities-tab entries.
    var utilities: [GameInfo] { tiles(.utility) }

    private func tiles(_ kind: PackBundle.Kind) -> [GameInfo] {
        packs.filter { $0.kind == kind }.map { bundle in
            let manifest = bundle.manifest
            let bestScoreKey = "pack.\(bundle.id).best", bestTimeKey = "pack.\(bundle.id).bestTime"
            let icon: GameIcon = manifest.symbol.map(GameIcon.symbol)
                ?? icon(for: bundle).map(GameIcon.image) ?? .symbol("puzzlepiece.extension")
            return GameInfo(
                id: bundle.id, name: manifest.name, icon: icon,
                makeSession: {
                    // Developer packs are read again from disk each time, so edits show up right away.
                    let fresh = bundle.isDev ? (try? PackBundle.load(from: bundle.folder, isDev: true)) ?? bundle : bundle
                    return PackSession(bundle: fresh)
                },
                stat: {
                    if kind == .utility {
                        // A running service's live line ("On until 3:00 PM"), else the pack's own z.tile().
                        return PackServices.shared.tileLine(for: bundle.id)
                            ?? UserDefaults.standard.string(forKey: PackRuntime.tileKey(bundle.id)) ?? ""
                    }
                    return switch manifest.tileStat {
                    case "bestScore": BestScore.label(for: bestScoreKey)
                    case "bestTime": BestTime.get(bestTimeKey) > 0 ? "Best \(BestTime.format(BestTime.get(bestTimeKey)))" : "Not played"
                    default: ""
                    }
                },
                badge: bundle.isDev ? "DEV" : nil,
                reloadsOnOpen: bundle.isDev)
        }
    }

    /// An installed pack's icon, for the Library.
    func icon(forPackID id: String) -> NSImage? {
        packs.first { $0.id == id && !$0.isDev }.flatMap(icon(for:))
    }

    private func icon(for bundle: PackBundle) -> NSImage? {
        if let icon = icons[bundle.id] { return icon }
        let icon = bundle.loadIcon()
        icons[bundle.id] = icon
        return icon
    }
}
