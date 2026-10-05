import AppKit
import Foundation

/// The file work behind the Uninstaller, Cleaner and Chat Files utilities (SDK 9). Packs only
/// ever see short ids, labels and sizes; the paths stay here. Everything removed goes to the
/// Trash (never deleted outright), and only after the person reviewed the list in the utility.
/// Scans run off the main thread.
nonisolated enum PackFiles {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var library: URL { home.appending(path: "Library") }

    /// Bytes on disk of a file or folder (folders summed, symbolic links not followed).
    static func size(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let item = enumerator?.nextObject() as? URL {
            guard let v = try? item.resourceValues(forKeys: keys), v.isDirectory != true, v.isSymbolicLink != true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// "~/Library/Caches/com.example.App" for showing.
    static func label(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    /// Moves to the Trash; returns how many made it.
    static func trash(_ urls: [URL]) -> (moved: Int, failed: [String]) {
        var moved = 0, failed: [String] = []
        for url in urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); moved += 1 } catch { failed.append(url.lastPathComponent) }
        }
        return (moved, failed)
    }

    // MARK: Apps

    struct App: Sendable {
        let bundleID: String
        let name: String
        let version: String
        let url: URL
        let isApple: Bool
    }

    /// Apps in /Applications and ~/Applications (one folder deep), newest names first by name.
    static func apps() -> [App] {
        let roots = [URL(filePath: "/Applications"), home.appending(path: "Applications")]
        var out: [App] = [], seen = Set<String>()
        func add(_ url: URL) {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, seen.insert(url.path).inserted else { return }
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            out.append(App(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                           version: version, url: url, isApple: id.hasPrefix("com.apple.")))
        }
        for root in roots {
            for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                if url.pathExtension == "app" { add(url); continue }
                for inner in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                where inner.pathExtension == "app" { add(inner) }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The files an app leaves in the Library: support files, caches, preferences, containers,
    /// saved state, logs, cookies, web data and launch agents, matched by its bundle id (or exact name).
    static func leftovers(of app: App) -> [URL] {
        let id = app.bundleID, name = app.name
        let lib = library
        var out: [URL] = []
        func exact(_ folder: String, _ names: [String]) {
            for n in names {
                let url = lib.appending(path: folder).appending(path: n)
                if FileManager.default.fileExists(atPath: url.path) { out.append(url) }
            }
        }
        func containing(_ folder: String, _ test: (String) -> Bool) {
            let dir = lib.appending(path: folder)
            for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where test(n) { out.append(dir.appending(path: n)) }
        }
        exact("Application Support", [id, name])
        exact("Caches", [id, name])
        exact("Containers", [id])
        exact("Saved Application State", ["\(id).savedState"])
        exact("HTTPStorages", [id, "\(id).binarycookies"])
        exact("WebKit", [id])
        exact("Cookies", ["\(id).binarycookies"])
        exact("Logs", [id, name])
        exact("Application Scripts", [id])
        containing("Preferences") { $0.hasPrefix(id) && $0.hasSuffix(".plist") }
        containing("Preferences/ByHost") { $0.hasPrefix(id) }
        containing("Group Containers") { $0.hasSuffix(id) || $0.hasSuffix(".\(id)") }
        containing("LaunchAgents") { $0.hasPrefix(id) }
        return out
    }

    // MARK: Cleaning

    struct Found: Sendable {
        let url: URL
        let size: Int64
    }

    /// The cleaner's categories, each with what it found.
    static func cleanable(downloadsDays: Int = 90) -> [(id: String, title: String, note: String, selected: Bool, items: [Found])] {
        let lib = library
        func children(_ dir: URL, skip: (String) -> Bool = { _ in false }) -> [Found] {
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])) ?? [])
                .filter { !skip($0.lastPathComponent) }
                .map { Found(url: $0, size: size($0)) }
                .filter { $0.size > 0 }
                .sorted { $0.size > $1.size }
        }
        let caches = children(lib.appending(path: "Caches"), skip: { $0.hasPrefix("com.apple.") || $0 == "CloudKit" || $0.hasPrefix(".") })
        let logs = children(lib.appending(path: "Logs"), skip: { $0.hasPrefix(".") })
        // Leftovers: containers and saved state named after apps that are no longer installed.
        var leftovers: [Found] = []
        for folder in ["Containers", "Saved Application State", "Application Scripts"] {
            for found in children(lib.appending(path: folder)) {
                let id = found.url.lastPathComponent.replacingOccurrences(of: ".savedState", with: "")
                guard id.split(separator: ".").count >= 3, !id.hasPrefix("com.apple."),
                      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil else { continue }
                leftovers.append(found)
            }
        }
        let cutoff = Date().addingTimeInterval(-Double(downloadsDays) * 86400)
        let downloads = ((try? FileManager.default.contentsOfDirectory(at: home.appending(path: "Downloads"), includingPropertiesForKeys: [.contentAccessDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { url in
                let v = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
                return max(v?.contentAccessDate ?? .distantPast, v?.contentModificationDate ?? .distantPast) < cutoff
            }
            .map { Found(url: $0, size: size($0)) }
            .sorted { $0.size > $1.size }
        let derived = children(lib.appending(path: "Developer/Xcode/DerivedData"))
        return [
            ("caches", "App caches", "Apps rebuild these when they need them.", true, caches),
            ("logs", "Logs", "Old diagnostic files.", true, logs),
            ("leftovers", "Leftovers of removed apps", "Data of apps that aren't installed any more.", true, leftovers),
            ("downloads", "Old downloads", "Files in Downloads not opened for \(downloadsDays) days.", false, downloads),
            ("xcode", "Xcode build files", "Xcode rebuilds these; the next build is slower.", false, derived),
        ]
    }

    // MARK: Chat files

    /// Where chat apps keep received files. Some need Full Disk Access (macOS protects Messages).
    static let chatFolders: [(app: String, path: String)] = [
        ("Messages", "Library/Messages/Attachments"),
        ("WhatsApp", "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"),
        ("Telegram", "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/appstore/account-data"),
        ("Telegram", "Downloads/Telegram Desktop"),
        ("Signal", "Library/Application Support/Signal/attachments.noindex"),
        ("Discord", "Library/Application Support/discord/Cache"),
        ("Slack", "Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/Cache"),
        ("Microsoft Teams", "Library/Containers/com.microsoft.teams2/Data/Library/Caches"),
    ]

    /// Per chat app: its files older than `days`, and whether macOS let Zephydian look.
    static func chatFiles(olderThan days: Int) -> [(app: String, files: [Found], blocked: Bool)] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var byApp: [String: (files: [Found], blocked: Bool, exists: Bool)] = [:]
        for folder in chatFolders {
            let dir = home.appending(path: folder.path)
            var entry = byApp[folder.app] ?? ([], false, false)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            entry.exists = true
            guard FileManager.default.isReadableFile(atPath: dir.path),
                  (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) != nil else {
                entry.blocked = true
                byApp[folder.app] = entry
                continue
            }
            let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isDirectoryKey]
            let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, _ in true })
            while let url = enumerator?.nextObject() as? URL {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory != true,
                      (v.contentModificationDate ?? .distantFuture) < cutoff else { continue }
                entry.files.append(Found(url: url, size: Int64(v.totalFileAllocatedSize ?? 0)))
            }
            byApp[folder.app] = entry
        }
        return byApp.filter(\.value.exists).map { ($0.key, $0.value.files, $0.value.blocked) }.sorted { $0.app < $1.app }
    }
}

/// The state behind those utilities: the ids handed to packs, and the jobs running.
@Observable
final class PackFileTools {
    /// id → file, for the current scan of each pack.
    @ObservationIgnored private var found: [String: [String: URL]] = [:]
    @ObservationIgnored private var appsByID: [String: PackFiles.App] = [:]
    @ObservationIgnored private var sizeCache: [String: Int64] = [:]
    private(set) var busy: Set<String> = []          // pack ids scanning
    private unowned let services: PackServices

    init(services: PackServices) { self.services = services }

    private func remember(_ urls: [URL], packID: String) -> [String] {
        var map = found[packID] ?? [:]
        let ids = urls.map { url -> String in
            let id = String(url.path.hashValue, radix: 36).replacingOccurrences(of: "-", with: "n")
            map[id] = url
            return id
        }
        found[packID] = map
        return ids
    }

    private func run(_ packID: String, _ work: @escaping @Sendable () -> Any, done: @escaping (Any) -> Void) {
        busy.insert(packID)
        services.changed()
        nonisolated(unsafe) let done = done
        Task.detached(priority: .userInitiated) {
            nonisolated(unsafe) let result = work()
            await MainActor.run { [weak self] in
                self?.busy.remove(packID)
                self?.services.changed()
                done(result)
            }
        }
    }

    // MARK: Uninstaller

    /// [{ id, name, version, apple, running, size }] (size: bytes, or null until measured).
    func apps(packID: String, done: @escaping ([[String: Any]]) -> Void) {
        let cache = sizeCache
        run(packID, { PackFiles.apps() as Any }) { [weak self] result in
            guard let self, let apps = result as? [PackFiles.App] else { return done([]) }
            for app in apps { self.appsByID[app.bundleID] = app }
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            done(apps.map { app in
                ["id": app.bundleID, "name": app.name, "version": app.version, "apple": app.isApple,
                 "running": running.contains(app.bundleID), "size": cache[app.url.path].map { $0 as Any } ?? NSNull()]
            })
            // Measure sizes in the background; the utility asks again to show them.
            let missing = apps.filter { cache[$0.url.path] == nil }.map(\.url)
            guard !missing.isEmpty else { return }
            Task.detached(priority: .utility) {
                let sizes = missing.map { ($0.path, PackFiles.size($0)) }
                await MainActor.run { [weak self] in
                    for (path, size) in sizes { self?.sizeCache[path] = size }
                    self?.services.changed()
                }
            }
        }
    }

    /// Asks macOS's open dialog for an app anywhere; done({ id, name } | null).
    func chooseApp(done: @escaping (Any) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.level = .statusBar + 1
        services.holdPanel()
        NSApp.activate()
        nonisolated(unsafe) let done = done
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                self?.services.releasePanel()
                guard response == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return done(NSNull()) }
                let app = PackFiles.App(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
                                        version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                        url: url, isApple: id.hasPrefix("com.apple."))
                self?.appsByID[id] = app
                done(["id": id, "name": app.name])
            }
        }
    }

    /// The app itself and its leftovers: [{ id, label, size, kind: "app" | "data" }].
    func leftovers(appID: String, packID: String, done: @escaping (Any) -> Void) {
        guard let app = appsByID[appID] else { return done(["error": "Choose the app again"]) }
        run(packID, { ([app.url] + PackFiles.leftovers(of: app)).map { PackFiles.Found(url: $0, size: PackFiles.size($0)) } as Any }) { [weak self] result in
            guard let self, let found = result as? [PackFiles.Found] else { return done([]) }
            let urls = found.map(\.url), sizes = found.map(\.size)
            let ids = self.remember(urls, packID: packID)
            done(zip(ids, urls.indices).map { id, i in
                ["id": id, "label": i == 0 ? app.name + ".app" : PackFiles.label(urls[i]), "size": sizes[i], "kind": i == 0 ? "app" : "data"] as [String: Any]
            })
        }
    }

    /// Quits the app if it's open, then moves the chosen items to the Trash.
    func uninstall(appID: String, ids: [String], packID: String, done: @escaping (Any) -> Void) {
        guard let app = appsByID[appID] else { return done(["error": "Choose the app again"]) }
        guard !app.isApple, appID != Bundle.main.bundleIdentifier else { return done(["error": "macOS's own apps and Zephydian can't be removed here"]) }
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: appID) { running.terminate() }
        trash(ids: ids, packID: packID, delay: 1.0, done: done)
    }

    // MARK: Cleaner and chat files

    /// [{ id, title, note, selected, size, items: [{ id, label, size }] }] (items: the 50 biggest).
    func scanClean(packID: String, done: @escaping (Any) -> Void) {
        run(packID, { PackFiles.cleanable() as Any }) { [weak self] result in
            guard let self, let categories = result as? [(id: String, title: String, note: String, selected: Bool, items: [PackFiles.Found])] else { return done([]) }
            done(categories.map { c in
                let ids = self.remember(c.items.map(\.url), packID: packID)
                return ["id": c.id, "title": c.title, "note": c.note, "selected": c.selected,
                        "size": c.items.reduce(0) { $0 + $1.size }, "count": c.items.count,
                        "items": zip(ids, c.items).map { ["id": $0, "label": PackFiles.label($1.url), "size": $1.size] as [String: Any] }] as [String: Any]
            })
        }
    }

    /// [{ app, size, count, blocked, ids }]: files older than `days` per chat app.
    func scanChats(days: Int, packID: String, done: @escaping (Any) -> Void) {
        let days = min(max(days, 1), 3650)
        run(packID, { PackFiles.chatFiles(olderThan: days) as Any }) { [weak self] result in
            guard let self, let apps = result as? [(app: String, files: [PackFiles.Found], blocked: Bool)] else { return done([]) }
            done(apps.map { a in
                ["app": a.app, "size": a.files.reduce(0) { $0 + $1.size }, "count": a.files.count, "blocked": a.blocked,
                 "ids": self.remember(a.files.map(\.url), packID: packID)] as [String: Any]
            })
        }
    }

    /// Moves the items with these ids (from this pack's last scan) to the Trash: done({ moved, failed }).
    func trash(ids: [String], packID: String, delay: TimeInterval = 0, done: @escaping (Any) -> Void) {
        let urls = ids.compactMap { found[packID]?[$0] }
        guard !urls.isEmpty else { return done(["moved": 0, "failed": [String]()]) }
        run(packID, {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }   // let a quitting app finish
            let result = PackFiles.trash(urls)
            return ["moved": result.moved, "failed": result.failed] as [String: Any]
        }) { [weak self] result in
            for id in ids { self?.found[packID]?[id] = nil }
            done(result)
        }
    }

    func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func forget(packID: String) { found[packID] = nil }
}
