import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation

/// The native services that keep a utility working after the panel closes (keep awake, timers, the
/// clipboard history). A service runs only while its utility is installed and has switched it on,
/// and stops when the utility switches it off, is removed, or Settings stops it. While any service
/// runs, the menu bar jet takes the accent color.
@Observable
final class PackServices {
    static let shared = PackServices()

    /// One running service, as Settings → Packs lists it.
    struct Running: Identifiable, Equatable {
        var id: String { "\(packID).\(kind)" }
        let packID: String
        let packName: String
        let kind: String
        /// "On until 3:00 PM", "On".
        var detail: String
        /// Whether the menu bar jet takes the accent color while this runs. Clipboard recording
        /// doesn't: it's meant to be on all the time, so it would never go back to normal.
        var colorsJet = true
    }

    private(set) var running: [Running] = []
    var isAnyActive: Bool { !running.isEmpty }
    /// The menu bar jet takes the accent color while this is true.
    var colorsJet: Bool { running.contains(where: \.colorsJet) }

    /// Goes up whenever a service's data changes (a timer ended, something was copied), so an open
    /// utility asks for its view again.
    private(set) var revision = 0
    func changed() { revision &+= 1 }

    /// Where services keep their settings and files (tests point these elsewhere).
    @ObservationIgnored var defaults: UserDefaults = .standard
    @ObservationIgnored var dataDirectory: URL = PackStorage.defaultDirectory()

    // The services themselves (each registers in `running` while it's active).
    @ObservationIgnored lazy var timers = PackTimers(services: self)
    @ObservationIgnored lazy var clipboard = ClipboardHistory(services: self)
    @ObservationIgnored lazy var shortcuts = PackShortcuts()
    @ObservationIgnored lazy var system = SystemStats()
    @ObservationIgnored lazy var capture = ScreenCapture(services: self)
    @ObservationIgnored lazy var images = PackImages(services: self)
    @ObservationIgnored lazy var windows = PackWindows(services: self)

    /// Set by AppDelegate: hides the panel (before a screenshot), and the app's settings (for the
    /// look of the screenshot preview card).
    @ObservationIgnored var hidePanel: () -> Void = {}
    @ObservationIgnored var settings: SettingsStore?

    /// The installed image editor (a utility whose manifest `handles` "image"), for a screenshot's
    /// Edit button, and opening a screenshot in it. Set by AppDelegate.
    @ObservationIgnored var imageEditor: () -> String? = { nil }
    @ObservationIgnored var openInEditor: (_ packID: String, _ shotID: String) -> Void = { _, _ in }

    /// Above zero while a utility works outside the panel (the color sampler, a save dialog), so
    /// clicks there don't close the panel.
    @ObservationIgnored private(set) var panelHolds = 0
    var holdsPanel: Bool { panelHolds > 0 }
    func holdPanel() { panelHolds += 1 }
    func releasePanel() { panelHolds = max(0, panelHolds - 1) }

    @ObservationIgnored private var stoppers: [String: () -> Void] = [:]

    /// Adds or updates a service. `stop` undoes whatever the service holds (an assertion, a timer).
    func started(_ service: Running, stop: @escaping () -> Void) {
        stoppers[service.id]?()                       // replacing: release the old one first
        stoppers[service.id] = stop
        running.removeAll { $0.id == service.id }
        running.append(service)
    }

    /// Changes a running service's line (in Settings and on its tile).
    func update(packID: String, kind: String, detail: String) {
        guard let i = running.firstIndex(where: { $0.packID == packID && $0.kind == kind }), running[i].detail != detail else { return }
        running[i].detail = detail
    }

    /// Called by a service that ended by itself (a keep-awake period ran out).
    func ended(packID: String, kind: String) {
        let id = "\(packID).\(kind)"
        stoppers[id] = nil
        running.removeAll { $0.id == id }
    }

    func stop(_ id: String) {
        stoppers.removeValue(forKey: id)?()
        running.removeAll { $0.id == id }
    }

    /// When a pack is removed, everything it started stops.
    func stopAll(for packID: String) {
        for service in running where service.packID == packID { stop(service.id) }
    }

    /// Removing a utility: everything it started stops, and the data its services kept (timers,
    /// clipboard history, its shortcut) is deleted.
    func removeData(for packID: String) {
        stopAll(for: packID)
        windows.closeAll(packID: packID)
        images.removeData(packID: packID)
        timers.removeData(packID: packID)
        clipboard.removeData(packID: packID)
        shortcuts.remove(packID: packID)
        capture.removeData(packID: packID)
        changed()
    }

    /// At launch: brings back what installed utilities had running (timers, clipboard recording,
    /// their shortcuts). Keep awake isn't brought back: it ends when Zephydian quits.
    func restore(_ bundles: [PackBundle]) {
        timers.restore()
        for bundle in bundles {
            let caps = Set(bundle.manifest.capabilities ?? [])
            if caps.contains("clipboard.read") { clipboard.restore(packID: bundle.id, packName: bundle.manifest.name) }
            if caps.contains("shortcut") { shortcuts.restore(packID: bundle.id) }
        }
    }

    /// A live line for the utility's tile ("On until 3:00 PM"), if it has a running service.
    func tileLine(for packID: String) -> String? {
        running.first { $0.packID == packID }?.detail
    }

    // MARK: Keep awake (power.awake)

    @ObservationIgnored private var awake: [String: (assertion: IOPMAssertionID, until: Date?, timer: Task<Void, Never>?)] = [:]

    /// Keeps the Mac (and, if asked, the display) from sleeping, for `minutes` or until stopped.
    func startAwake(packID: String, packName: String, minutes: Double?, display: Bool) -> Bool {
        stop("\(packID).awake")
        var assertion = IOPMAssertionID(0)
        let type = (display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        guard IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "\(packName) (Zephydian) is keeping the Mac awake" as CFString, &assertion) == kIOReturnSuccess else {
            return false
        }
        let until = minutes.flatMap { $0 > 0 ? Date().addingTimeInterval($0 * 60) : nil }
        // A sleeping task costs nothing; it only wakes once, when the time is up.
        let timer = until.map { date in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self else { return }
                self.releaseAwake(packID)
                self.ended(packID: packID, kind: "awake")
            }
        }
        awake[packID] = (assertion, until, timer)
        let detail = until.map { "On until \($0.formatted(date: .omitted, time: .shortened))" } ?? "On"
        started(Running(packID: packID, packName: packName, kind: "awake", detail: detail)) { [weak self] in
            self?.releaseAwake(packID)
        }
        return true
    }

    func stopAwake(packID: String) { stop("\(packID).awake") }

    /// Whether keep-awake is on for the pack, and until when (nil = until switched off).
    func awakeStatus(packID: String) -> (on: Bool, until: Date?) {
        guard let state = awake[packID] else { return (false, nil) }
        return (true, state.until)
    }

    private func releaseAwake(_ packID: String) {
        guard let state = awake.removeValue(forKey: packID) else { return }
        state.timer?.cancel()
        IOPMAssertionRelease(state.assertion)
    }
}
