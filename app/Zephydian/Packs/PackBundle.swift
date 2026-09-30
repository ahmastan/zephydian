import AppKit
import Foundation

/// A pack's manifest.json (see docs/PACKS.md).
nonisolated struct PackManifest: Codable, Equatable {
    var id: String
    var name: String
    var kind: String
    var version: String
    var sdkVersion: Int
    var description: String
    var hint: String?
    var pauseButton: Bool?
    var tileStat: String?
    var whatsNew: String?
    /// An SF Symbol used as the tile icon (utilities).
    var symbol: String?
    /// What the pack may use beyond drawing and storage (see `PackCapability`).
    var capabilities: [String]?
    /// What the utility opens for others (SDK 3). "image": it's the editor behind a screenshot's Edit.
    var handles: [String]?
}

/// A pack on disk, ready to run: its folder, manifest and script.
struct PackBundle {
    /// The newest SDK version this app can run.
    static let sdkVersion = 4
    /// Utilities arrived in SDK 2.
    static let utilitySDK = 2

    let folder: URL
    let manifest: PackManifest
    let script: String
    /// Loaded unsigned from the developer folder (debug builds only).
    let isDev: Bool

    var id: String { manifest.id }

    enum Kind: String { case game, utility }
    /// Checked by `load`, so it's always one of the two.
    var kind: Kind { Kind(rawValue: manifest.kind) ?? .game }

    enum LoadError: Error, CustomStringConvertible {
        case unreadable(String), invalid(String)
        var description: String {
            switch self { case .unreadable(let s), .invalid(let s): s }
        }
    }

    /// Reads and checks a pack folder. The folder name must match the manifest's id.
    static func load(from folder: URL, isDev: Bool = false) throws -> PackBundle {
        let manifest: PackManifest
        do {
            manifest = try JSONDecoder().decode(PackManifest.self, from: Data(contentsOf: folder.appending(path: "manifest.json")))
        } catch {
            throw LoadError.unreadable("manifest.json can't be read: \(error.localizedDescription)")
        }
        guard manifest.id == folder.lastPathComponent else {
            throw LoadError.invalid("the manifest id \"\(manifest.id)\" doesn't match the folder name")
        }
        guard let kind = Kind(rawValue: manifest.kind) else { throw LoadError.invalid("unknown kind \"\(manifest.kind)\"") }
        guard kind == .game || manifest.sdkVersion >= utilitySDK else { throw LoadError.invalid("utilities need SDK \(utilitySDK) or newer") }
        if let unknown = manifest.capabilities?.first(where: { PackCapability.named($0) == nil }) {
            throw LoadError.invalid("needs a newer Zephydian (capability \(unknown))")
        }
        guard manifest.sdkVersion <= sdkVersion else { throw LoadError.invalid("needs a newer Zephydian (SDK \(manifest.sdkVersion))") }
        guard let script = try? String(contentsOf: folder.appending(path: "main.js"), encoding: .utf8) else {
            throw LoadError.unreadable("main.js can't be read")
        }
        return PackBundle(folder: folder, manifest: manifest, script: script, isDev: isDev)
    }

    /// An image editor: a utility that handles "image" and may open windows and edit images.
    var isImageEditor: Bool {
        kind == .utility && manifest.handles?.contains("image") == true
            && Set(manifest.capabilities ?? []).isSuperset(of: ["windows", "images.edit"])
    }

    /// A file under the pack's assets/ folder, or nil if the name tries to leave it.
    func assetURL(_ name: String) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { return nil }
        let assets = folder.appending(path: "assets", directoryHint: .isDirectory).resolvingSymlinksInPath().standardizedFileURL
        let url = assets.appending(path: name).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(assets.path + "/") else { return nil }
        return url
    }

    /// The tile icon: a template image, drawn in the accent color. A named SF Symbol wins over icon.png.
    func loadIcon() -> NSImage? {
        if let symbol = manifest.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            return image
        }
        guard let image = NSImage(contentsOf: folder.appending(path: "icon.png")) else { return nil }
        image.isTemplate = true
        return image
    }
}

/// A pack's own saved data: a small JSON file per pack, holding each key's value as JSON text.
/// It lives outside the pack's folder, so it survives updates (and removal, unless the player deletes progress).
final class PackStorage {
    static let limit = 1024 * 1024

    private let file: URL
    private var values: [String: String]

    /// Application Support/Zephydian/PackData/<id>.json in the app's sandbox.
    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Zephydian/PackData", directoryHint: .isDirectory)
    }

    init(packID: String, directory: URL = PackStorage.defaultDirectory()) {
        file = directory.appending(path: "\(packID).json")
        values = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func get(_ key: String) -> String? { values[key] }

    /// Returns false (and saves nothing) if the pack would go over its 1 MB.
    func set(_ key: String, json: String) -> Bool {
        var next = values
        next[key] = json
        guard Self.size(of: next) <= Self.limit else { return false }
        values = next
        save()
        return true
    }

    func remove(_ key: String) {
        guard values.removeValue(forKey: key) != nil else { return }
        save()
    }

    func clear() {
        values = [:]
        try? FileManager.default.removeItem(at: file)
    }

    private static func size(of values: [String: String]) -> Int {
        values.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(values).write(to: file, options: .atomic)
        } catch {
            #if DEBUG
            print("PackStorage: couldn't save \(file.lastPathComponent): \(error)")
            #endif
        }
    }
}
