import AppKit
import CryptoKit
import Foundation
import Observation

// MARK: - Catalog

/// catalog.json from the "packs" release (written by scripts/packs.swift). Trusted only after its
/// Ed25519 signature matches the public key built into the app.
nonisolated struct PackCatalog: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id, name, kind, version: String
        var sdkVersion: Int
        var description: String
        var whatsNew: String?
        var size: Int
        var url: String
        var sha256: String
        var iconURL: String
        var iconSha256: String
        var sourceHash: String
        /// An SF Symbol icon (utilities), shown before install without downloading icon.png.
        var symbol: String?
        /// What the pack may use; shown before install.
        var capabilities: [String]?
    }

    var format: Int
    /// Seconds since 1970 when it was published. An older catalog than one already seen is refused,
    /// so nobody can replay an old catalog to bring back an old pack.
    var sequence: Int
    var generated: String
    var packs: [Entry]
}

nonisolated enum PackTrust {
    /// The public half of the owner's pack signing key (the private half is a GitHub secret).
    static let publicKey = "tYzAvPxlmfX0one21hxC4otZ5EZGGi/IArl2oyNAzqU="

    struct Failure: Error, CustomStringConvertible { let description: String }

    static func verifyCatalog(_ data: Data, signature: String, publicKey: String = publicKey) throws -> PackCatalog {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(sig, for: data) else {
            throw Failure(description: "The Library's list isn't signed correctly, so it was ignored.")
        }
        guard let catalog = try? JSONDecoder().decode(PackCatalog.self, from: data), catalog.format == 1 else {
            throw Failure(description: "The Library's list is in a newer format. Update Zephydian to see it.")
        }
        return catalog
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// "1.2.3" → [1, 2, 3]
    static func version(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
    static func isNewer(_ a: String, than b: String) -> Bool { version(b).lexicographicallyPrecedes(version(a)) }
}

// MARK: - Manager

/// Downloads, verifies, installs, updates and removes packs, and runs the daily update check.
/// Zephydian goes online only here: when the Library is opened, when you install or update, and
/// at most once a day to check installed packs (which you can turn off in Settings).
@Observable
final class PackManager {
    static let shared: PackManager = {
        #if DEBUG
        // Debug builds only: a local test Library in Packs/dev-library/ (catalog.json, catalog.json.sig,
        // public-key.txt), signed with a throwaway key, for trying the Library before packs are published.
        let testLibrary = PackLibrary.packsDirectory.appending(path: "dev-library", directoryHint: .isDirectory)
        if let key = try? String(contentsOf: testLibrary.appending(path: "public-key.txt"), encoding: .utf8) {
            print("Using the test Library in \(testLibrary.path)")
            return PackManager(baseURL: testLibrary, publicKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        #endif
        return PackManager()
    }()
    static let releaseURL = URL(string: "https://github.com/ahmastan/zephydian/releases/download/packs/")!

    enum CatalogState: Equatable { case idle, loading, loaded, offline, failed(String) }

    private(set) var catalog: PackCatalog?
    private(set) var catalogState: CatalogState = .idle
    /// Packs being downloaded, with progress from 0 to 1.
    private(set) var installing: [String: Double] = [:]
    /// The last install or update error per pack, shown on its Library row.
    private(set) var errors: [String: String] = [:]
    private(set) var lastChecked: Date?
    /// Installed versions, read from each pack's manifest.
    private(set) var installed: [String: String] = [:]
    /// The daily update check (the Settings switch). On by default.
    var autoUpdate: Bool {
        didSet {
            defaults.set(autoUpdate, forKey: "packs.autoUpdate")
            scheduleDailyCheck()
        }
    }

    /// Is this pack's game on screen (or paused in the background)? Updates wait until it isn't.
    @ObservationIgnored var isInUse: (String) -> Bool = { _ in false }
    /// Called after anything is installed, updated or removed.
    @ObservationIgnored var didChange: () -> Void = {}

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let dataDirectory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private let publicKey: String
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var pendingUpdates: Set<String> = []
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?

    init(directory: URL = PackLibrary.packsDirectory, dataDirectory: URL = PackStorage.defaultDirectory(),
         defaults: UserDefaults = .standard, baseURL: URL = PackManager.releaseURL, publicKey: String = PackTrust.publicKey) {
        self.directory = directory
        self.dataDirectory = dataDirectory
        self.defaults = defaults
        self.baseURL = baseURL
        self.publicKey = publicKey
        // No cookies, no cache, nothing that identifies the Mac beyond a plain app name.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "Zephydian"]
        session = URLSession(configuration: config)
        lastChecked = defaults.object(forKey: "packs.lastChecked") as? Date
        autoUpdate = defaults.object(forKey: "packs.autoUpdate") as? Bool ?? true
        loadCachedCatalog()
        reloadInstalled()
    }

    private var cacheFolder: URL { directory.appending(path: ".catalog", directoryHint: .isDirectory) }

    // MARK: Catalog

    /// Fetches and verifies the catalog. Offline, the last verified copy stays in use.
    func loadCatalog() async {
        catalogState = .loading
        do {
            async let body = fetch(baseURL.appending(path: "catalog.json"))
            async let signature = fetch(baseURL.appending(path: "catalog.json.sig"))
            let (data, sigData) = try await (body, signature)
            let fresh = try PackTrust.verifyCatalog(data, signature: String(decoding: sigData, as: UTF8.self), publicKey: publicKey)
            let seen = defaults.integer(forKey: "packs.catalogSequence")
            guard fresh.sequence >= seen else {
                throw PackTrust.Failure(description: "The Library's list is older than the one you already have, so it was ignored.")
            }
            defaults.set(fresh.sequence, forKey: "packs.catalogSequence")
            try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
            try? data.write(to: cacheFolder.appending(path: "catalog.json"), options: .atomic)
            try? sigData.write(to: cacheFolder.appending(path: "catalog.json.sig"), options: .atomic)
            catalog = fresh
            catalogState = .loaded
        } catch let error as URLError where Self.isOffline(error) {
            catalogState = .offline
        } catch {
            catalogState = .failed(Self.message(for: error))
        }
    }

    private func loadCachedCatalog() {
        guard let data = try? Data(contentsOf: cacheFolder.appending(path: "catalog.json")),
              let sig = try? String(contentsOf: cacheFolder.appending(path: "catalog.json.sig"), encoding: .utf8) else { return }
        catalog = try? PackTrust.verifyCatalog(data, signature: sig, publicKey: publicKey)
    }

    func entry(for id: String) -> PackCatalog.Entry? { catalog?.packs.first { $0.id == id } }

    /// True if the catalog has a newer version this app can run.
    func hasUpdate(_ id: String) -> Bool {
        guard let current = installed[id], let entry = entry(for: id) else { return false }
        return entry.sdkVersion <= PackBundle.sdkVersion && PackTrust.isNewer(entry.version, than: current)
    }

    /// The pack's icon for the Library, downloaded once and checked against the catalog.
    func icon(for entry: PackCatalog.Entry) async -> NSImage? {
        let file = cacheFolder.appending(path: "\(entry.id)-\(entry.iconSha256.prefix(16)).png")
        if let data = try? Data(contentsOf: file), PackTrust.sha256(data) == entry.iconSha256 { return Self.templateImage(data) }
        guard let url = URL(string: entry.iconURL), let data = try? await fetch(url), PackTrust.sha256(data) == entry.iconSha256 else { return nil }
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return Self.templateImage(data)
    }

    // MARK: Install, update, remove

    /// Downloads, verifies and installs a pack, replacing an older version. If anything fails,
    /// the previous version stays exactly as it was.
    func install(_ entry: PackCatalog.Entry) async {
        guard installing[entry.id] == nil, PackManifest.isValidID(entry.id) else { return }
        guard entry.sdkVersion <= PackBundle.sdkVersion else {
            errors[entry.id] = "Update Zephydian to install this."
            return
        }
        installing[entry.id] = 0
        errors[entry.id] = nil
        defer { installing[entry.id] = nil }
        let fm = FileManager.default
        let staging = directory.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        do {
            guard let url = URL(string: entry.url), url.scheme == "https" || url.isFileURL else {
                throw PackTrust.Failure(description: "The pack's address isn't allowed.")
            }
            let data = try await download(url, expectedSize: entry.size) { [weak self] progress in
                self?.installing[entry.id] = progress
            }
            guard data.count == entry.size, PackTrust.sha256(data) == entry.sha256 else {
                throw PackTrust.Failure(description: "The download doesn't match the Library's fingerprint, so it wasn't installed.")
            }
            let unpacked = staging.appending(path: entry.id, directoryHint: .isDirectory)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try PackArchive.extract(data, to: unpacked)
            let bundle = try PackBundle.load(from: unpacked)
            guard bundle.manifest.version == entry.version else {
                throw PackTrust.Failure(description: "The pack's version doesn't match the Library.")
            }

            // Swap it in: keep the old version aside until the new one is in place.
            let target = directory.appending(path: entry.id, directoryHint: .isDirectory)
            let backup = staging.appending(path: "previous", directoryHint: .isDirectory)
            let wasInstalled = fm.fileExists(atPath: target.path)
            if wasInstalled { try fm.moveItem(at: target, to: backup) }
            do {
                try fm.moveItem(at: unpacked, to: target)
            } catch {
                if wasInstalled { try? fm.moveItem(at: backup, to: target) }
                throw error
            }
            if wasInstalled { defaults.set(Date(), forKey: "packs.updated.\(entry.id)") }
            reloadInstalled()
            didChange()
            scheduleDailyCheck()
        } catch let error as URLError where Self.isOffline(error) {
            errors[entry.id] = "You're offline."
        } catch {
            errors[entry.id] = Self.message(for: error)
        }
    }

    /// Removes a pack. Its saved games and best scores stay for a reinstall unless `deleteProgress`.
    func uninstall(_ id: String, deleteProgress: Bool) {
        guard PackManifest.isValidID(id) else { return }
        PackServices.shared.removeData(for: id)
        try? FileManager.default.removeItem(at: directory.appending(path: id, directoryHint: .isDirectory))
        if deleteProgress {
            try? FileManager.default.removeItem(at: dataDirectory.appending(path: "\(id).json"))
            PackStorage.forget(packID: id)
            defaults.removeObject(forKey: "pack.\(id).best")
            defaults.removeObject(forKey: "pack.\(id).bestTime")
        }
        defaults.removeObject(forKey: PackRuntime.tileKey(id))
        defaults.removeObject(forKey: "packs.updated.\(id)")
        errors[id] = nil
        pendingUpdates.remove(id)
        reloadInstalled()
        didChange()
        scheduleDailyCheck()
    }

    /// When the pack was last updated, for a few days of "What's new" on its Library row.
    func updatedRecently(_ id: String, within days: Double = 7) -> Bool {
        guard let date = defaults.object(forKey: "packs.updated.\(id)") as? Date else { return false }
        return Date().timeIntervalSince(date) < days * 86_400
    }

    private func reloadInstalled() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var found: [String: String] = [:]
        for folder in folders where !folder.lastPathComponent.hasPrefix(".") && !["dev", "dev-library"].contains(folder.lastPathComponent) {
            if let data = try? Data(contentsOf: folder.appending(path: "manifest.json")),
               let manifest = try? JSONDecoder().decode(PackManifest.self, from: data), manifest.id == folder.lastPathComponent {
                found[manifest.id] = manifest.version
            }
        }
        if found != installed { installed = found }
    }

    // MARK: Updates

    /// Refreshes the catalog and installs every available update, except for a pack that's in use
    /// (that one updates as soon as it's closed).
    func checkForUpdates() async {
        guard !installed.isEmpty else { return }
        await loadCatalog()
        guard catalogState == .loaded else { return }
        await installUpdates()
    }

    /// Installs every update in the loaded catalog (a pack that's in use waits until it's closed).
    /// Also run when the Library opens, since it has just fetched the list anyway.
    func installUpdates() async {
        guard catalogState == .loaded, !installed.isEmpty else { return }
        lastChecked = Date()
        defaults.set(lastChecked, forKey: "packs.lastChecked")
        for id in installed.keys.sorted() where hasUpdate(id) {
            if isInUse(id) { pendingUpdates.insert(id); continue }
            if let entry = entry(for: id) { await install(entry) }
        }
    }

    /// Call when a game is closed, so an update that was waiting for it can install.
    func packClosed(_ id: String) {
        guard pendingUpdates.remove(id) != nil, let entry = entry(for: id), hasUpdate(id) else { return }
        Task { await install(entry) }
    }


    /// Asks macOS to run the check about once a day at a quiet moment. It's only scheduled while the
    /// switch is on and at least one pack is installed; otherwise Zephydian never goes online on its own.
    func scheduleDailyCheck() {
        let wanted = autoUpdate && !installed.isEmpty
        if !wanted {
            scheduler?.invalidate()
            scheduler = nil
            return
        }
        guard scheduler == nil else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.ahmastan.zephydian.packs.update")
        scheduler.repeats = true
        scheduler.interval = 24 * 60 * 60
        scheduler.tolerance = 2 * 60 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                // Never more than once a day, even if macOS runs the activity early.
                if let self, self.lastChecked.map({ Date().timeIntervalSince($0) > 20 * 60 * 60 }) ?? true {
                    await self.checkForUpdates()
                }
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }

    // MARK: Networking

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return data
    }

    private func download(_ url: URL, expectedSize: Int, progress: @escaping (Double) -> Void) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (stream, response) = try await session.bytes(for: request)
        try Self.check(response)
        var data = Data()
        data.reserveCapacity(expectedSize)
        var lastReported = 0
        for try await byte in stream {
            data.append(byte)
            if data.count > expectedSize {
                throw PackTrust.Failure(description: "The download is bigger than the Library says, so it was stopped.")
            }
            if data.count - lastReported >= 16_384 {
                lastReported = data.count
                progress(Double(data.count) / Double(max(expectedSize, 1)))
            }
        }
        progress(1)
        return data
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }   // file:// in tests
        if http.statusCode == 404 { throw PackTrust.Failure(description: "The Library isn't available right now. Try again later.") }
        guard (200..<300).contains(http.statusCode) else {
            throw PackTrust.Failure(description: "The server answered with an error (\(http.statusCode)). Try again later.")
        }
    }

    private static func isOffline(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
         .timedOut, .internationalRoamingOff, .dataNotAllowed].contains(error.code)
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? PackTrust.Failure { return failure.description }
        if let failure = error as? PackArchive.Failure { return "The pack is damaged: \(failure.description)." }
        if let failure = error as? PackBundle.LoadError { return "The pack can't be used: \(failure.description)." }
        return error.localizedDescription
    }

    private static func templateImage(_ data: Data) -> NSImage? {
        let image = NSImage(data: data)
        image?.isTemplate = true
        return image
    }
}
