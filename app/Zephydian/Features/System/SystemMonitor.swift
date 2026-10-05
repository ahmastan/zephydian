import AppKit
import SwiftUI
import UserNotifications

/// One reading every few seconds for the menu bar readouts and the alerts, shared so both cost one
/// reading. It only runs while at least one of them is on.
@Observable
final class SystemSampler {
    static let shared = SystemSampler()

    private(set) var latest: [String: Any] = [:]
    @ObservationIgnored private let stats = SystemStats()
    @ObservationIgnored private var clients: [String: TimeInterval] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var listeners: [String: () -> Void] = [:]

    /// Starts (or retimes) the readings for a client; the fastest client sets the pace.
    func add(_ client: String, every interval: TimeInterval, onReading: @escaping () -> Void) {
        clients[client] = interval
        listeners[client] = onReading
        restart()
    }

    func remove(_ client: String) {
        clients[client] = nil
        listeners[client] = nil
        restart()
    }

    private func restart() {
        task?.cancel()
        task = nil
        guard let interval = clients.values.min() else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.latest = self.stats.read(apps: false)
                for listener in self.listeners.values { listener() }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }
}

// MARK: - Menu bar readouts

enum Readout: String, CaseIterable, Identifiable, Codable {
    case cpu, gpu, memory, temperature, network, battery, power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .temperature: "Chip temperature"
        case .network: "Network speed"
        case .battery: "Battery"
        case .power: "Power use"
        }
    }

    /// The small label over the value.
    var label: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "MEM"
        case .temperature: "TEMP"
        case .network: ""
        case .battery: "BAT"
        case .power: "POWER"
        }
    }
}

@Observable
final class ReadoutSettings {
    static let shared = ReadoutSettings()

    var shown: [Readout] { didSet { save(shown, "readouts.shown") } }
    /// Seconds between readings.
    var interval: Double { didSet { UserDefaults.standard.set(interval, forKey: "readouts.interval") } }

    init() {
        shown = UserDefaults.standard.data(forKey: "readouts.shown").flatMap { try? JSONDecoder().decode([Readout].self, from: $0) }
            ?? [.cpu, .memory, .network]
        interval = UserDefaults.standard.object(forKey: "readouts.interval") as? Double ?? 2
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/// The readouts: one menu bar item beside the jet, each stat a small label over its value, in the
/// menu bar's own text color. Clicking it opens the System utility (or this feature's settings).
final class MenuBarStatsEngine: FeatureEngine {
    private var item: NSStatusItem?
    private var hosting: NSHostingView<ReadoutsView>?
    private let model = ReadoutsModel()
    private var running = false

    func start() {
        running = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "ZephydianReadouts"
        let hosting = NSHostingView(rootView: ReadoutsView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        if let button = item.button {
            button.addSubview(hosting)
            button.target = self
            button.action = #selector(clicked)
            button.setAccessibilityLabel("System readouts")
        }
        self.item = item
        self.hosting = hosting
        follow()
    }

    func stop() {
        running = false
        SystemSampler.shared.remove("readouts")
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        hosting = nil
    }

    private func follow() {
        guard running else { return }
        let settings = ReadoutSettings.shared
        withObservationTracking { _ = settings.interval; _ = settings.shown } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        model.shown = settings.shown
        SystemSampler.shared.add("readouts", every: max(1, settings.interval)) { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        model.reading = SystemSampler.shared.latest
        guard let hosting, let item else { return }
        let size = hosting.fittingSize
        let width = ceil(max(size.width, 8))
        item.length = width
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: NSStatusBar.system.thickness)
    }

    @objc private func clicked() {
        if PackLibrary.shared.packs.contains(where: { $0.id == "system" }) {
            CommandBarHooks.openUtility("system")
        } else {
            CommandBarHooks.openSettings("feature:menu-bar-stats")
        }
    }
}

@Observable
final class ReadoutsModel {
    var shown: [Readout] = []
    var reading: [String: Any] = [:]
}

struct ReadoutsView: View {
    let model: ReadoutsModel

    var body: some View {
        HStack(spacing: 9) {
            ForEach(model.shown) { readout in
                if let lines = Self.lines(readout, model.reading) {
                    VStack(alignment: .leading, spacing: -1) {
                        Text(lines.0).font(.system(size: 8, weight: .semibold)).opacity(0.75)
                        Text(lines.1).font(.system(size: 10, weight: .medium).monospacedDigit())
                    }
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, 5)
        .frame(maxHeight: .infinity)
        .foregroundStyle(.primary)
    }

    /// The two lines of one readout ("CPU" over "12%"; network is ↑ over ↓), or nil when there's no reading.
    static func lines(_ readout: Readout, _ r: [String: Any]) -> (String, String)? {
        switch readout {
        case .cpu:
            guard let cpu = r["cpu"] as? [String: Any] else { return nil }
            return (readout.label, percent((cpu["user"] as? Double ?? 0) + (cpu["system"] as? Double ?? 0)))
        case .gpu:
            return (r["gpu"] as? Double).map { (readout.label, percent($0)) }
        case .memory:
            guard let m = r["memory"] as? [String: Any], let used = m["used"] as? Double, let total = m["total"] as? Double, total > 0 else { return nil }
            return (readout.label, percent(used / total * 100))
        case .temperature:
            return ((r["temperatures"] as? [String: Double])?["cpu"]).map { (readout.label, "\(Int($0.rounded()))°") }
        case .network:
            guard let n = r["network"] as? [String: Any] else { return nil }
            return ("↑ " + speed(n["out"] as? Double ?? 0), "↓ " + speed(n["in"] as? Double ?? 0))
        case .battery:
            guard let b = r["battery"] as? [String: Any], b["present"] as? Bool == true, let level = b["level"] as? Double else { return nil }
            return (b["charging"] as? Bool == true ? "CHG" : readout.label, percent(level))
        case .power:
            return (r["watts"] as? Double).map { (readout.label, String(format: $0 >= 10 ? "%.0f W" : "%.1f W", $0)) }
        }
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    static func speed(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = bytes, i = 0
        while value >= 1000, i < units.count - 1 { value /= 1000; i += 1 }
        return (value >= 100 || i == 0 ? String(Int(value)) : String(format: "%.1f", value)) + " " + units[i] + "/s"
    }
}

struct MenuBarStatsSettingsView: View {
    @State private var settings = ReadoutSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            ForEach(Readout.allCases) { readout in
                Toggle(readout.title, isOn: Binding(
                    get: { settings.shown.contains(readout) },
                    set: { on in
                        if on { settings.shown = Readout.allCases.filter { settings.shown.contains($0) || $0 == readout } }
                        else { settings.shown.removeAll { $0 == readout } }
                    }))
            }
            Picker("Update every", selection: $settings.interval) {
                Text("Second").tag(1.0)
                Text("2 seconds").tag(2.0)
                Text("5 seconds").tag(5.0)
            }
        } footer: {
            Text("The readings shown beside the menu bar jet. Click them to open the System utility. Updating every 5 seconds uses the least power; GPU and temperature aren't on every Mac. ⌘-drag to move them in the menu bar.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Alerts

@Observable
final class AlertSettings {
    static let shared = AlertSettings()

    var cpu: Bool { didSet { set(cpu, "cpu") } }
    var cpuPercent: Double { didSet { set(cpuPercent, "cpuPercent") } }
    var cpuMinutes: Double { didSet { set(cpuMinutes, "cpuMinutes") } }
    var heat: Bool { didSet { set(heat, "heat") } }
    var heatDegrees: Double { didSet { set(heatDegrees, "heatDegrees") } }
    var memory: Bool { didSet { set(memory, "memory") } }
    var disk: Bool { didSet { set(disk, "disk") } }
    var diskGB: Double { didSet { set(diskGB, "diskGB") } }
    var battery: Bool { didSet { set(battery, "battery") } }
    var batteryPercent: Double { didSet { set(batteryPercent, "batteryPercent") } }

    private static func get<T>(_ key: String, _ fallback: T) -> T { UserDefaults.standard.object(forKey: "alerts.\(key)") as? T ?? fallback }
    private func set(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: "alerts.\(key)") }

    init() {
        cpu = Self.get("cpu", true)
        cpuPercent = Self.get("cpuPercent", 90)
        cpuMinutes = Self.get("cpuMinutes", 2)
        heat = Self.get("heat", true)
        heatDegrees = Self.get("heatDegrees", 95)
        memory = Self.get("memory", true)
        disk = Self.get("disk", true)
        diskGB = Self.get("diskGB", 10)
        battery = Self.get("battery", true)
        batteryPercent = Self.get("batteryPercent", 15)
    }
}

/// Watches for problems every 10 seconds and sends a macOS notification, at most once an hour
/// for each kind. A problem must last a while (CPU: the minutes chosen; heat and memory: a minute)
/// so a short spike doesn't count.
final class SystemAlertsEngine: FeatureEngine {
    enum Problem: String { case cpu, heat, memory, disk, battery }

    private var since: [Problem: Date] = [:]
    private var lastSent: [Problem: Date] = [:]

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        SystemSampler.shared.add("alerts", every: 10) { [weak self] in self?.check() }
    }

    func stop() {
        SystemSampler.shared.remove("alerts")
        since = [:]
    }

    private func check() {
        let r = SystemSampler.shared.latest
        let s = AlertSettings.shared
        let cpu = (r["cpu"] as? [String: Any]).map { ($0["user"] as? Double ?? 0) + ($0["system"] as? Double ?? 0) } ?? 0
        let chip = (r["temperatures"] as? [String: Double])?["cpu"]
        let memory = (r["memory"] as? [String: Any])?["pressure"] as? String
        let free = (r["disk"] as? [String: Any])?["free"] as? Double
        let battery = r["battery"] as? [String: Any] ?? [:]

        track(.cpu, s.cpu && cpu >= s.cpuPercent, lasting: s.cpuMinutes * 60,
              "The CPU has been busy for a while", "It's been above \(Int(s.cpuPercent))% for \(Int(s.cpuMinutes)) minutes. The System utility shows which apps.")
        track(.heat, s.heat && (chip ?? 0) >= s.heatDegrees, lasting: 60,
              "Your Mac is running hot", "The chip is at \(Int((chip ?? 0).rounded()))°C.")
        track(.memory, s.memory && memory == "high", lasting: 60,
              "Memory is tight", "macOS reports high memory pressure. Quitting apps you don't need will help.")
        track(.disk, s.disk && free.map { $0 < s.diskGB * 1e9 } == true, lasting: 0,
              "The disk is nearly full", "Less than \(Int(s.diskGB)) GB is left.")
        let low = battery["present"] as? Bool == true && battery["pluggedIn"] as? Bool == false
            && (battery["level"] as? Double ?? 100) <= s.batteryPercent
        track(.battery, s.battery && low, lasting: 0,
              "The battery is low", "\(Int((battery["level"] as? Double ?? 0).rounded()))% left. Plug in soon.")
    }

    private func track(_ problem: Problem, _ happening: Bool, lasting: TimeInterval, _ title: String, _ body: String) {
        guard happening else { since[problem] = nil; return }
        let start = since[problem] ?? Date()
        since[problem] = start
        guard Date().timeIntervalSince(start) >= lasting,
              Date().timeIntervalSince(lastSent[problem] ?? .distantPast) >= 3600 else { return }
        lastSent[problem] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "alert.\(problem.rawValue)", content: content, trigger: nil))
    }
}

struct SystemAlertsSettingsView: View {
    @State private var settings = AlertSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("CPU stays busy", isOn: $settings.cpu)
            if settings.cpu {
                Stepper("Above \(Int(settings.cpuPercent))%", value: $settings.cpuPercent, in: 50...100, step: 5)
                Stepper("For \(Int(settings.cpuMinutes)) minute\(settings.cpuMinutes == 1 ? "" : "s")", value: $settings.cpuMinutes, in: 1...30)
            }
            Toggle("The Mac runs hot", isOn: $settings.heat)
            if settings.heat {
                Stepper("Chip above \(Int(settings.heatDegrees))°C", value: $settings.heatDegrees, in: 70...110, step: 5)
            }
            Toggle("Memory is tight", isOn: $settings.memory)
            Toggle("The disk is nearly full", isOn: $settings.disk)
            if settings.disk {
                Stepper("Less than \(Int(settings.diskGB)) GB free", value: $settings.diskGB, in: 1...200, step: settings.diskGB < 20 ? 1 : 10)
            }
            Toggle("The battery is low", isOn: $settings.battery)
            if settings.battery {
                Stepper("At \(Int(settings.batteryPercent))% or less", value: $settings.batteryPercent, in: 5...50, step: 5)
            }
        } footer: {
            Text("Checked every 10 seconds. Each alert comes as a macOS notification, at most once an hour. If none arrive, allow Zephydian in System Settings → Notifications.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
