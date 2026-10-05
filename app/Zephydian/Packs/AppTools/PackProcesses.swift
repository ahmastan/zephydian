import AppKit
import Foundation
import UserNotifications

/// Runs a command-line tool off the main thread and collects its output.
nonisolated enum CommandLine2 {
    static func run(_ path: String, _ arguments: [String], environment: [String: String] = [:]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Ports

/// What's listening on TCP ports (the person's own processes; macOS hides other users' without
/// admin rights), from `lsof`, and stopping it.
nonisolated enum PortScanner {
    struct Listener: Sendable {
        let port: Int
        let address: String
        let pid: pid_t
        let command: String
    }

    static func listeners() -> [Listener] {
        let result = CommandLine2.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"])
        var out: [Listener] = [], seen = Set<String>()
        var pid: pid_t = 0, command = ""
        for line in result.output.split(separator: "\n") {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            switch first {
            case "p": pid = pid_t(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                guard seen.insert("\(pid):\(port)").inserted else { continue }   // IPv4 and IPv6 of the same socket
                out.append(Listener(port: port, address: address, pid: pid, command: command))
            default: break
            }
        }
        return out.sorted { $0.port < $1.port }
    }
}

// MARK: - Homebrew

nonisolated enum Homebrew {
    static var path: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// No questions, no hints, no automatic `brew update` before every command.
    static let environment = ["NONINTERACTIVE": "1", "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_COLOR": "0"]

    static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        guard let path else { return (-1, "Homebrew isn't installed") }
        return CommandLine2.run(path, arguments, environment: environment)
    }

    /// Package names are letters, digits, @ . + - _ and /, nothing a shell or brew could read as an option.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 120 && !name.hasPrefix("-")
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "@.+-_/".unicodeScalars.contains($0) }
    }

    /// `brew search`: names under "==> Formulae" and "==> Casks".
    static func search(_ query: String) -> (formulae: [String], casks: [String]) {
        let output = run(["search", query]).output
        var formulae: [String] = [], casks: [String] = [], current = 0
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("==> Formulae") { current = 1; continue }
            if line.hasPrefix("==> Casks") { current = 2; continue }
            let name = line.trimmingCharacters(in: .whitespaces)
            guard isValidName(name) else { continue }
            if current == 2 { casks.append(name) } else { formulae.append(name) }
        }
        return (Array(formulae.prefix(60)), Array(casks.prefix(60)))
    }

    /// Installed packages with versions.
    static func installed() -> [(name: String, version: String, cask: Bool)] {
        func list(_ flag: String, cask: Bool) -> [(String, String, Bool)] {
            run(["list", flag, "--versions"]).output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: " ")
                guard let name = parts.first else { return nil }
                return (String(name), parts.dropFirst().joined(separator: " "), cask)
            }
        }
        return list("--formula", cask: false) + list("--cask", cask: true)
    }

    /// Outdated packages (casks with their own updaters included), from `brew outdated --json=v2 --greedy`.
    static func outdated() -> [(name: String, installed: String, latest: String, cask: Bool)] {
        guard let data = run(["outdated", "--json=v2", "--greedy"]).output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        func read(_ key: String, cask: Bool) -> [(String, String, String, Bool)] {
            (json[key] as? [[String: Any]] ?? []).compactMap { item in
                guard let name = item["name"] as? String else { return nil }
                let installed = (item["installed_versions"] as? [String])?.last ?? ""
                return (name, installed, item["current_version"] as? String ?? "", cask)
            }
        }
        return read("formulae", cask: false) + read("casks", cask: true)
    }
}

/// One long command with its output shown live (Homebrew installs, upgrades, cleanup).
@Observable
final class ToolJob {
    let label: String
    private(set) var lines: [String] = []
    private(set) var running = true
    private(set) var ok = false
    @ObservationIgnored private var process: Process?

    init(label: String) { self.label = label }

    func start(_ path: String, _ arguments: [String], environment: [String: String], onChange: @escaping () -> Void, done: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        nonisolated(unsafe) let onChange = onChange
        nonisolated(unsafe) let done = done
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.lines += text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                if self.lines.count > 300 { self.lines.removeFirst(self.lines.count - 300) }
                onChange()
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.running = false
                self?.ok = status == 0
                onChange()
                done(status == 0)
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            lines = [error.localizedDescription]
            running = false
            done(false)
        }
    }

    func cancel() { process?.terminate() }

    var json: [String: Any] { ["label": label, "lines": lines, "running": running, "ok": ok] }
}

// MARK: - App updates

nonisolated enum AppUpdates {
    struct Update: Sendable {
        let id: String           // bundle id, or "brew:<cask>"
        let name: String
        let installed: String
        let latest: String
        let source: String       // "brew", "appstore", "app"
        let storeID: Int?
        let appPath: String?
    }

    /// Compares "1.10.2" and "1.9" by their numbers.
    static func isNewer(_ latest: String, than installed: String) -> Bool {
        func numbers(_ s: String) -> [Int] { s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        let a = numbers(latest), b = numbers(installed)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Every update found: Homebrew casks and formulae, App Store apps (Apple's lookup service) and
    /// apps with a Sparkle update feed. Uses the network.
    static func check() async -> [Update] {
        var out: [Update] = []
        let brewOutdated = Homebrew.path == nil ? [] : await Task.detached { Homebrew.outdated() }.value
        let brewCasks = Set(brewOutdated.filter(\.cask).map(\.name))
        out += brewOutdated.map { Update(id: "brew:\($0.cask ? "cask" : "formula"):\($0.name)", name: $0.name, installed: $0.installed,
                                         latest: $0.latest, source: "brew", storeID: nil, appPath: nil) }
        let apps = await Task.detached { PackFiles.apps().filter { !$0.isApple } }.value
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        await withTaskGroup(of: Update?.self) { group in
            var started = 0
            for app in apps {
                let caskName = app.name.lowercased().replacingOccurrences(of: " ", with: "-")
                if brewCasks.contains(caskName) { continue }
                let info = Bundle(url: app.url)?.infoDictionary ?? [:]
                let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
                let build = info["CFBundleVersion"] as? String ?? ""
                let receipt = app.url.appending(path: "Contents/_MASReceipt/receipt")
                if FileManager.default.fileExists(atPath: receipt.path) {
                    group.addTask { await appStore(app, session: session) }
                } else if let feed {
                    group.addTask { await sparkle(app, feed: feed, build: build, session: session) }
                } else { continue }
                started += 1
                if started % 8 == 0, let next = await group.next(), let update = next { out.append(update) }   // a few at a time
            }
            for await update in group { if let update { out.append(update) } }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func appStore(_ app: PackFiles.App, session: URLSession) async -> Update? {
        guard let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(app.bundleID)"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (json["results"] as? [[String: Any]])?.first,
              let latest = result["version"] as? String, isNewer(latest, than: app.version) else { return nil }
        return Update(id: app.bundleID, name: app.name, installed: app.version, latest: latest, source: "appstore",
                      storeID: result["trackId"] as? Int, appPath: app.url.path)
    }

    /// The newest item in a Sparkle appcast, by its short version (or build).
    private static func sparkle(_ app: PackFiles.App, feed: URL, build: String, session: URLSession) async -> Update? {
        var request = URLRequest(url: feed, timeoutInterval: 10)
        request.setValue("Zephydian", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request), data.count < 5_000_000 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var best: (short: String, build: String)?
        for item in text.components(separatedBy: "<item").dropFirst() {
            let short = value(item, "sparkle:shortVersionString") ?? ""
            let version = value(item, "sparkle:version") ?? ""
            guard !short.isEmpty || !version.isEmpty else { continue }
            if let current = best {
                let newer = !version.isEmpty && !current.build.isEmpty ? isNewer(version, than: current.build) : isNewer(short, than: current.short)
                if newer { best = (short, version) }
            } else {
                best = (short, version)
            }
        }
        guard let best else { return nil }
        let newer = !best.build.isEmpty && !build.isEmpty ? isNewer(best.build, than: build) : isNewer(best.short, than: app.version)
        guard newer else { return nil }
        return Update(id: app.bundleID, name: app.name, installed: app.version, latest: best.short.isEmpty ? best.build : best.short,
                      source: "app", storeID: nil, appPath: app.url.path)
    }

    /// An attribute (sparkle:version="…") or element (<sparkle:version>…</sparkle:version>) in an appcast item.
    private static func value(_ item: String, _ name: String) -> String? {
        if let r = item.range(of: "\(name)=\""), let end = item[r.upperBound...].firstIndex(of: "\"") {
            return String(item[r.upperBound..<end])
        }
        if let r = item.range(of: "<\(name)>"), let end = item.range(of: "</\(name)>", range: r.upperBound..<item.endIndex) {
            return String(item[r.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

// MARK: - The tools packs reach

/// Ports, Homebrew, updates and the cleaner's reminder, for utilities (SDK 9).
@Observable
final class PackProcessTools {
    private unowned let services: PackServices
    /// The running or last Homebrew job, per pack.
    @ObservationIgnored private var jobs: [String: ToolJob] = [:]
    @ObservationIgnored private var updates: [String: [String: AppUpdates.Update]] = [:]

    init(services: PackServices) { self.services = services }

    // MARK: Ports

    func ports(done: @escaping (Any) -> Void) {
        nonisolated(unsafe) let done = done
        Task.detached(priority: .userInitiated) {
            let list = PortScanner.listeners()
            await MainActor.run {
                let own = getuid()
                done(list.map { l -> [String: Any] in
                    let app = NSRunningApplication(processIdentifier: l.pid)
                    var info = proc_bsdinfo()
                    let size = proc_pidinfo(l.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                    let mine = size > 0 && info.pbi_uid == own
                    return ["port": l.port, "address": l.address == "*" ? "all addresses" : l.address, "pid": Int(l.pid),
                            "name": app?.localizedName ?? l.command, "app": app?.bundleIdentifier.map { $0 as Any } ?? NSNull(), "canStop": mine]
                })
            }
        }
    }

    /// Asks the process to quit (or, with `force`, ends it). Only the person's own processes.
    func stop(pid: Int, force: Bool) -> Bool {
        guard pid > 1, pid != Int(getpid()) else { return false }
        return kill(pid_t(pid), force ? SIGKILL : SIGTERM) == 0
    }

    // MARK: Homebrew

    func brewStatus(packID: String) -> [String: Any] {
        ["installed": Homebrew.path != nil, "job": jobs[packID].map { $0.json as Any } ?? NSNull()]
    }

    /// Quick reads, off the main thread: "search" (arg: query), "installed", "outdated".
    func brewRead(_ action: String, _ arg: String, done: @escaping (Any) -> Void) {
        nonisolated(unsafe) let done = done
        Task.detached(priority: .userInitiated) {
            let result: [String: Any]
            switch action {
            case "search":
                let query = String(arg.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
                let found = query.isEmpty ? (formulae: [String](), casks: [String]()) : Homebrew.search(query)
                result = ["formulae": found.formulae, "casks": found.casks]
            case "installed":
                result = ["items": Homebrew.installed().map { ["name": $0.name, "version": $0.version, "cask": $0.cask] }]
            case "outdated":
                result = ["items": Homebrew.outdated().map { ["name": $0.name, "installed": $0.installed, "latest": $0.latest, "cask": $0.cask] }]
            default:
                result = [:]
            }
            nonisolated(unsafe) let r = result
            await MainActor.run { done(r) }
        }
    }

    /// Starts a job: "install", "uninstall", "upgrade" (name, cask), "update", "upgradeAll", "cleanup".
    func brewJob(_ action: String, name: String?, cask: Bool, packID: String, done: @escaping (Any) -> Void) {
        guard let path = Homebrew.path else { return done(["error": "Homebrew isn't installed"]) }
        if jobs[packID]?.running == true { return done(["error": "Wait for the current job to finish"]) }
        var args: [String]
        var label: String
        switch action {
        case "install", "uninstall", "upgrade":
            guard let name, Homebrew.isValidName(name) else { return done(["error": "That isn't a package name"]) }
            args = [action] + (cask ? ["--cask"] : []) + [name]
            label = "\(action.capitalized) \(name)"
        case "update": args = ["update"]; label = "Updating Homebrew"
        case "upgradeAll": args = ["upgrade"]; label = "Upgrading everything"
        case "cleanup": args = ["cleanup", "--prune=all"]; label = "Cleaning up"
        default: return done(["error": "Unknown action"])
        }
        let job = ToolJob(label: label)
        jobs[packID] = job
        nonisolated(unsafe) let done = done
        job.start(path, args, environment: Homebrew.environment, onChange: { [weak self] in self?.services.changed() }) { ok in
            done(["ok": ok])
        }
        services.changed()
    }

    func cancelJob(packID: String) { jobs[packID]?.cancel() }

    // MARK: Updates

    func checkUpdates(packID: String, done: @escaping (Any) -> Void) {
        nonisolated(unsafe) let done = done
        Task { [weak self] in
            let found = await AppUpdates.check()
            self?.updates[packID] = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            done(found.map { ["id": $0.id, "name": $0.name, "installed": $0.installed, "latest": $0.latest, "source": $0.source] as [String: Any] })
        }
    }

    /// Homebrew: upgrade in place (a job); App Store: open its page; others: open the app so its updater runs.
    func update(_ id: String, packID: String, done: @escaping (Any) -> Void) {
        guard let update = updates[packID]?[id] else { return done(["error": "Check again"]) }
        switch update.source {
        case "brew":
            let parts = id.split(separator: ":")
            brewJob("upgrade", name: update.name, cask: parts.count > 1 && parts[1] == "cask", packID: packID, done: done)
        case "appstore":
            if let store = update.storeID, let url = URL(string: "macappstore://apps.apple.com/app/id\(store)") { NSWorkspace.shared.open(url) }
            done(["opened": "App Store"])
        default:
            if let path = update.appPath {
                NSWorkspace.shared.openApplication(at: URL(filePath: path), configuration: NSWorkspace.OpenConfiguration())
            }
            done(["opened": update.name])
        }
    }

    func forget(packID: String) {
        jobs[packID]?.cancel()
        jobs[packID] = nil
        updates[packID] = nil
    }
}

/// The Cleaner's reminder: weekly or monthly, a notification with how much could be cleaned.
/// Nothing is moved; it only scans and tells. Runs as a daily background check while it's set.
final class CleanReminder {
    private var scheduler: NSBackgroundActivityScheduler?
    private var schedules: [String: String] = [:]     // pack id → "weekly" | "monthly"

    func schedule(_ packID: String) -> String { UserDefaults.standard.string(forKey: "clean.reminder.\(packID)") ?? "off" }

    func set(_ value: String, packID: String) {
        let v = ["weekly", "monthly"].contains(value) ? value : "off"
        UserDefaults.standard.set(v, forKey: "clean.reminder.\(packID)")
        if v == "off" { schedules[packID] = nil } else {
            schedules[packID] = v
            if UserDefaults.standard.object(forKey: "clean.reminder.\(packID).last") == nil {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "clean.reminder.\(packID).last")
            }
        }
        arm()
    }

    func restore(packID: String) {
        let v = schedule(packID)
        if v != "off" { schedules[packID] = v }
        arm()
    }

    func remove(packID: String) {
        schedules[packID] = nil
        UserDefaults.standard.removeObject(forKey: "clean.reminder.\(packID)")
        UserDefaults.standard.removeObject(forKey: "clean.reminder.\(packID).last")
        arm()
    }

    private func arm() {
        scheduler?.invalidate()
        scheduler = nil
        guard !schedules.isEmpty else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.ahmastan.zephydian.cleanReminder")
        scheduler.repeats = true
        scheduler.interval = 24 * 3600
        scheduler.tolerance = 3 * 3600
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                self?.check()
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }

    private func check() {
        let now = Date().timeIntervalSince1970
        for (packID, schedule) in schedules {
            let last = UserDefaults.standard.double(forKey: "clean.reminder.\(packID).last")
            guard now - last >= (schedule == "weekly" ? 7 : 30) * 86400 else { continue }
            UserDefaults.standard.set(now, forKey: "clean.reminder.\(packID).last")
            Task.detached(priority: .background) {
                let total = PackFiles.cleanable().filter(\.selected).reduce(Int64(0)) { $0 + $1.items.reduce(0) { $0 + $1.size } }
                guard total > 200_000_000 else { return }   // not worth a notification
                let content = UNMutableNotificationContent()
                content.title = "Time for a clean"
                content.body = "About \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) of caches, logs and leftovers could go. Open Cleaner to review."
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "clean.\(packID)", content: content, trigger: nil))
            }
        }
    }
}
