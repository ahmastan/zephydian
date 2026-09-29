import AppKit
import Foundation
import UserNotifications

/// Countdowns that keep running after the panel closes (the `timers` capability). A single task
/// sleeps until the next timer ends, so waiting costs nothing. When one ends it plays its sound,
/// posts a notification (with the `notifications` capability) and starts the next phase of its
/// chain, if it has one (focus mode). Timers are saved, so they survive quitting Zephydian.
final class PackTimers {
    struct Phase: Codable, Equatable {
        var label: String
        var seconds: Double
    }

    struct Timer: Codable, Equatable {
        var id: String
        var packID: String
        var packName: String
        var label: String
        var seconds: Double
        /// When it ends; nil while paused.
        var endsAt: Date?
        /// Seconds left while paused.
        var remainingWhenPaused: Double?
        var sound: String?
        var notify: Bool
        /// Phases still to come after this one.
        var next: [Phase]
        /// 1-based position in its chain, and the chain's length (1 for a plain timer).
        var phase: Int
        var phases: Int

        var remaining: Double { endsAt.map { max(0, $0.timeIntervalSinceNow) } ?? remainingWhenPaused ?? 0 }
    }

    struct Finished: Codable, Equatable {
        var label: String
        var at: Date
    }

    /// macOS's own alert sounds (in /System/Library/Sounds).
    static let sounds = ["Glass", "Ping", "Hero", "Pop", "Purr", "Submarine", "Tink", "Blow", "Bottle", "Frog", "Funk", "Morse", "Sosumi", "Basso"]

    private unowned let services: PackServices
    private var timers: [Timer] = []
    private var finished: [String: [Finished]] = [:]
    private var wake: Task<Void, Never>?
    private var loaded = false

    init(services: PackServices) { self.services = services }

    private var defaults: UserDefaults { services.defaults }

    // MARK: For packs

    @discardableResult
    func start(packID: String, packName: String, label: String, seconds: Double, sound: String?,
               notify: Bool, chain: [Phase]) -> String {
        load()
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        timers.append(Timer(id: id, packID: packID, packName: packName, label: String(label.prefix(60)),
                            seconds: seconds, endsAt: Date().addingTimeInterval(seconds), remainingWhenPaused: nil,
                            sound: sound.flatMap { Self.sounds.contains($0) ? $0 : nil }, notify: notify,
                            next: Array(chain.prefix(40)), phase: 1, phases: 1 + min(chain.count, 40)))
        if notify { Self.askForNotifications() }
        changed()
        return id
    }

    func list(packID: String) -> [Timer] {
        load()
        return timers.filter { $0.packID == packID }
    }

    func pause(packID: String, id: String) {
        edit(packID, id) { t in
            guard let end = t.endsAt else { return }
            t.remainingWhenPaused = max(0, end.timeIntervalSinceNow)
            t.endsAt = nil
        }
    }

    func resume(packID: String, id: String) {
        edit(packID, id) { t in
            guard t.endsAt == nil else { return }
            t.endsAt = Date().addingTimeInterval(t.remainingWhenPaused ?? t.seconds)
            t.remainingWhenPaused = nil
        }
    }

    func cancel(packID: String, id: String) {
        load()
        timers.removeAll { $0.packID == packID && $0.id == id }
        changed()
    }

    func cancelAll(packID: String) {
        load()
        timers.removeAll { $0.packID == packID }
        changed()
    }

    /// Timers that ended in the last day, newest first (focus mode counts today's sessions from it).
    func finishedLog(packID: String) -> [Finished] {
        load()
        return finished[packID] ?? []
    }

    /// Everything the pack saved here is deleted when it's removed.
    func removeData(packID: String) {
        cancelAll(packID: packID)
        finished[packID] = nil
        save()
    }

    /// Plays a sound so the pack can let people choose one.
    static func preview(_ sound: String) {
        guard sounds.contains(sound) else { return }
        NSSound(named: NSSound.Name(sound))?.stop()
        NSSound(named: NSSound.Name(sound))?.play()
    }

    // MARK: At launch

    /// Brings back saved timers. Ones that ended while Zephydian wasn't running are logged quietly.
    func restore() {
        load()
        fire(quietly: true)
    }

    // MARK: Running them

    private func edit(_ packID: String, _ id: String, _ change: (inout Timer) -> Void) {
        load()
        guard let i = timers.firstIndex(where: { $0.packID == packID && $0.id == id }) else { return }
        change(&timers[i])
        changed()
    }

    /// Saves, updates the running-services list, and sleeps until the next timer ends.
    private func changed() {
        save()
        updateServices()
        schedule()
        services.changed()
    }

    private func schedule() {
        wake?.cancel()
        guard let next = timers.compactMap(\.endsAt).min() else { wake = nil; return }
        wake = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.fire(quietly: false)
        }
    }

    /// Ends every timer that's due: alert, log, then the next phase or removal.
    private func fire(quietly: Bool) {
        let now = Date().addingTimeInterval(0.05)
        var anyEnded = false
        for i in timers.indices.reversed() {
            guard let end = timers[i].endsAt, end <= now else { continue }
            anyEnded = true
            let t = timers[i]
            log(t.packID, Finished(label: t.label, at: end))
            if !quietly { alert(t) }
            if !quietly, let phase = t.next.first {
                timers[i].label = phase.label
                timers[i].seconds = phase.seconds
                timers[i].endsAt = Date().addingTimeInterval(phase.seconds)
                timers[i].next.removeFirst()
                timers[i].phase += 1
            } else {
                timers.remove(at: i)
            }
        }
        if anyEnded || quietly { changed() }
    }

    private func log(_ packID: String, _ entry: Finished) {
        let dayAgo = Date().addingTimeInterval(-86_400)
        finished[packID] = ([entry] + (finished[packID] ?? []).filter { $0.at > dayAgo }).prefix(500).map { $0 }
    }

    private func alert(_ t: Timer) {
        if let sound = t.sound { NSSound(named: NSSound.Name(sound))?.play() }
        guard t.notify, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = t.label.isEmpty ? "Time's up" : "\(t.label) is done"
        content.body = t.next.first.map { "\($0.label) starts now (\(Self.duration($0.seconds)))." } ?? "From \(t.packName)."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(t.packID).\(t.id).\(t.phase)", content: content, trigger: nil))
    }

    private static func askForNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // test harnesses have no bundle
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m >= 60 ? "\(m / 60) h\(m % 60 > 0 ? " \(m % 60) min" : "")" : "\(m) min"
    }

    /// One Settings row per pack with running timers: "Tea ends 3:15 PM" or "3 timers · next 3:15 PM".
    private func updateServices() {
        let packs = Set(timers.map(\.packID))
        for packID in packs {
            let active = timers.filter { $0.packID == packID && $0.endsAt != nil }.sorted { $0.endsAt! < $1.endsAt! }
            guard let first = active.first else { services.ended(packID: packID, kind: "timers"); continue }
            let time = first.endsAt!.formatted(date: .omitted, time: .shortened)
            let detail = active.count == 1 ? "\(first.label.isEmpty ? "Timer" : first.label) ends \(time)" : "\(active.count) timers · next \(time)"
            if services.running.contains(where: { $0.packID == packID && $0.kind == "timers" }) {
                services.update(packID: packID, kind: "timers", detail: detail)
            } else {
                services.started(.init(packID: packID, packName: first.packName, kind: "timers", detail: detail)) { [weak self] in
                    self?.timers.removeAll { $0.packID == packID }
                    self?.save()
                    self?.schedule()
                    self?.services.changed()
                }
            }
        }
        for service in services.running where service.kind == "timers" && !packs.contains(service.packID) {
            services.ended(packID: service.packID, kind: "timers")
        }
    }

    // MARK: Saving

    private func load() {
        guard !loaded else { return }
        loaded = true
        let decoder = JSONDecoder()
        timers = defaults.data(forKey: "packs.timers").flatMap { try? decoder.decode([Timer].self, from: $0) } ?? []
        finished = defaults.data(forKey: "packs.timers.finished").flatMap { try? decoder.decode([String: [Finished]].self, from: $0) } ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(timers), forKey: "packs.timers")
        defaults.set(try? encoder.encode(finished), forKey: "packs.timers.finished")
    }
}
