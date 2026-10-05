import AppKit
import CoreAudio
import SwiftUI

@Observable
final class SoundSettings {
    static let shared = SoundSettings()

    /// Each app's level (1 = 100%, up to 2), remembered and applied whenever it plays.
    var levels: [String: Double] { didSet { UserDefaults.standard.set(levels, forKey: "sound.levels") } }
    /// Apps sent to an output of their own (bundle id → output UID).
    var outputs: [String: String] { didSet { UserDefaults.standard.set(outputs, forKey: "sound.outputs") } }
    var showInMenuBar: Bool { didSet { UserDefaults.standard.set(showInMenuBar, forKey: "sound.menuBar") } }
    /// Cycles to the next output.
    var cycleShortcut: KeyShortcut? { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(cycleShortcut), forKey: "sound.cycleShortcut") } }
    var cycleRegistered = true

    init() {
        let d = UserDefaults.standard
        levels = d.dictionary(forKey: "sound.levels") as? [String: Double] ?? [:]
        outputs = d.dictionary(forKey: "sound.outputs") as? [String: String] ?? [:]
        showInMenuBar = d.object(forKey: "sound.menuBar") as? Bool ?? true
        cycleShortcut = d.data(forKey: "sound.cycleShortcut").flatMap { try? JSONDecoder().decode(KeyShortcut?.self, from: $0) } ?? nil
    }

    func level(_ bundleID: String) -> Double { levels[bundleID] ?? 1 }
}

/// What the popover shows; refreshed once a second only while it's open.
@Observable
final class SoundModel {
    var outputs: [AudioOutput] = []
    var current: AudioObjectID?
    var volume: Double = 0
    var muted = false
    var apps: [AudioApp] = []
    /// Set when macOS refused the audio tap (the permission is off).
    var needsPermission = false

    func refresh() {
        outputs = AudioSystem.outputs()
        current = AudioSystem.defaultOutput
        if let current {
            volume = Double(AudioSystem.volume(current) ?? 0)
            muted = AudioSystem.isMuted(current)
        }
        let settings = SoundSettings.shared
        // Playing now, plus apps with their own level or output that still have audio processes.
        let all = AudioSystem.apps(playingOnly: false)
        let playing = Set(AudioSystem.apps(playingOnly: true).map(\.bundleID))
        apps = all.filter { playing.contains($0.bundleID) || settings.levels[$0.bundleID] != nil || settings.outputs[$0.bundleID] != nil }
    }
}

/// Sound Mixer: a speaker in the menu bar with the main volume, the output, and a slider (to 200%)
/// and output for each app playing sound. Apps left at 100% on the main output aren't touched; the
/// others get an `AppAudioRoute` while they have audio. Also the shortcut that cycles outputs.
final class SoundMixerEngine: FeatureEngine {
    static weak var current: SoundMixerEngine?

    let model = SoundModel()
    private let settings = SoundSettings.shared
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var refreshTask: Task<Void, Never>?
    private var listeners: [AudioListener] = []
    private var routes: [String: any RouteStopping] = [:]   // bundle id → AppAudioRoute
    private var building: Set<String> = []
    private let hotKey = GlobalHotKey(id: 707)
    private let queue = DispatchQueue(label: "com.ahmastan.zephydian.routes")
    private var running = false

    func start() {
        running = true
        Self.current = self
        hotKey.onPress = { [weak self] in self?.cycleOutput() }
        // Apps starting or stopping sound, and the main output changing, re-apply the levels.
        listeners = [
            AudioListener(AudioSystem.system, AudioSystem.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in self?.sync() },
            AudioListener(AudioSystem.system, AudioSystem.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
                self?.rebuildAll()
            },
            AudioListener(AudioSystem.system, AudioSystem.address(kAudioHardwarePropertyDevices)) { [weak self] in self?.sync() },
        ]
        follow()
        followRoutes()
    }

    func stop() {
        running = false
        if Self.current === self { Self.current = nil }
        hotKey.unregister()
        listeners = []
        refreshTask?.cancel()
        popover?.close()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        let old = routes
        routes = [:]
        queue.async { for route in old.values { route.stopRoute() } }
    }

    private func follow() {
        guard running else { return }
        withObservationTracking { _ = settings.showInMenuBar; _ = settings.cycleShortcut } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        settings.cycleRegistered = hotKey.register(settings.cycleShortcut)
        if settings.showInMenuBar, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "ZephydianSound"
            item.button?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Sound")
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            self.item = item
        } else if !settings.showInMenuBar, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// Levels and outputs changed anywhere (the popover, Reset in Settings): bring the routes in line.
    private func followRoutes() {
        guard running else { return }
        withObservationTracking { _ = settings.levels; _ = settings.outputs } onChange: { [weak self] in
            Task { @MainActor in self?.followRoutes() }
        }
        sync()
    }

    // MARK: Popover

    @objc private func togglePopover() {
        if popover?.isShown == true { popover?.close(); return }
        showPopover()
    }

    func showPopover() {
        guard let button = item?.button else { return }
        let popover = self.popover ?? {
            let p = NSPopover()
            p.behavior = .transient
            let settings = Features.shared.appSettings ?? SettingsStore()
            p.contentViewController = NSHostingController(rootView: SoundPopover(engine: self).environment(settings).tint(settings.accentColor))
            return p
        }()
        self.popover = popover
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, self?.popover?.isShown == true {
                try? await Task.sleep(for: .seconds(1))
                self?.model.refresh()
            }
        }
    }

    // MARK: Changes from the popover

    func setVolume(_ value: Double) {
        guard let current = model.current else { return }
        AudioSystem.setVolume(current, Float(value))
        model.volume = value
    }

    func setOutput(_ output: AudioOutput) {
        let id = output.id
        queue.async { AudioSystem.setDefaultOutput(id) }
        model.current = id
    }

    func setLevel(_ app: AudioApp, _ level: Double) {
        let rounded = (level * 20).rounded() / 20
        if abs(rounded - 1) < 0.001 { settings.levels[app.bundleID] = nil } else { settings.levels[app.bundleID] = rounded }
        if #available(macOS 14.2, *), let route = routes[app.bundleID] as? AppAudioRoute {
            route.gain.value = Float(rounded)   // live, no rebuild
        }
    }

    func setAppOutput(_ app: AudioApp, _ uid: String?) {
        settings.outputs[app.bundleID] = uid   // followRoutes rebuilds it on the new output
    }

    // MARK: Routes

    /// Makes sure every app that needs a route has one, and that routes nobody needs are gone.
    private func sync() {
        guard running, #available(macOS 14.2, *) else { return }
        let apps = AudioSystem.apps(playingOnly: false)
        let mainUID = AudioSystem.defaultOutput.flatMap { id in AudioSystem.outputs().first { $0.id == id }?.uid }
        var wanted: Set<String> = []
        for app in apps {
            let level = settings.level(app.bundleID)
            let output = settings.outputs[app.bundleID].flatMap { uid in AudioSystem.output(uid: uid)?.uid } ?? mainUID
            guard let output, abs(level - 1) > 0.001 || settings.outputs[app.bundleID] != nil else { continue }
            wanted.insert(app.bundleID)
            if let route = routes[app.bundleID] as? AppAudioRoute {
                if route.outputUID == output, Set(route.processes) == Set(app.processes) {
                    route.gain.value = Float(level)
                    continue
                }
                remove(app.bundleID)
            }
            build(app, output: output, level: level)
        }
        for id in routes.keys where !wanted.contains(id) { remove(id) }
    }

    private func rebuildAll() {
        for id in Array(routes.keys) { remove(id) }
        sync()
    }

    private func remove(_ bundleID: String) {
        guard let route = routes.removeValue(forKey: bundleID) else { return }
        queue.async { route.stopRoute() }
    }

    @available(macOS 14.2, *)
    private func build(_ app: AudioApp, output: String, level: Double) {
        guard !building.contains(app.bundleID) else { return }
        building.insert(app.bundleID)
        queue.async { [weak self] in
            let result = Result { try AppAudioRoute(bundleID: app.bundleID, name: app.name, processes: app.processes, outputUID: output, gain: Float(level)) }
            Task { @MainActor in
                guard let self else { return }
                self.building.remove(app.bundleID)
                switch result {
                case .success(let route):
                    guard self.running else { self.queue.async { route.stop() }; return }
                    self.routes[app.bundleID] = route
                    self.model.needsPermission = false
                case .failure:
                    self.model.needsPermission = true
                }
            }
        }
    }

    // MARK: Output shortcut

    /// Moves to the next output and says which on screen.
    func cycleOutput() {
        let outputs = AudioSystem.outputs()
        guard !outputs.isEmpty else { return }
        let index = outputs.firstIndex { $0.id == AudioSystem.defaultOutput } ?? -1
        let next = outputs[(index + 1) % outputs.count]
        queue.async { AudioSystem.setDefaultOutput(next.id) }
        CaptureToast.show(next.name, symbol: next.symbol, detail: "Sound now plays here")
    }
}

/// Lets the engine stop routes without naming the 14.2-only type.
nonisolated protocol RouteStopping: AnyObject, Sendable { func stopRoute() }
@available(macOS 14.2, *)
nonisolated extension AppAudioRoute: RouteStopping { func stopRoute() { stop() } }

// MARK: - The popover

private struct SoundPopover: View {
    let engine: SoundMixerEngine
    @State private var settings = SoundSettings.shared

    var body: some View {
        let model = engine.model
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.muted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22)
                Slider(value: Binding(get: { model.volume }, set: { engine.setVolume($0) }), in: 0...1)
                Text("\(Int((model.volume * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
            Picker("Output", selection: Binding(get: { model.current ?? 0 }, set: { id in
                if let output = model.outputs.first(where: { $0.id == id }) { engine.setOutput(output) }
            })) {
                ForEach(model.outputs) { output in
                    Label(output.name, systemImage: output.symbol).tag(output.id)
                }
            }
            Divider()
            if model.apps.isEmpty {
                Text("Apps playing sound appear here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.apps) { app in
                AppRow(app: app, engine: engine, outputs: model.outputs)
            }
            if model.needsPermission {
                Text("macOS didn't allow Zephydian to change an app's volume. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording (System Audio Recording Only).")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

private struct AppRow: View {
    let app: AudioApp
    let engine: SoundMixerEngine
    let outputs: [AudioOutput]
    @State private var settings = SoundSettings.shared

    var body: some View {
        let level = settings.level(app.bundleID)
        let ownOutput = settings.outputs[app.bundleID]
        HStack(spacing: 10) {
            Group {
                if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app")
                }
            }
            .frame(width: 22, height: 22)
            .help(app.name)
            Slider(value: Binding(get: { level }, set: { engine.setLevel(app, $0) }), in: 0...2)
                .accessibilityLabel("\(app.name) volume")
            Text("\(Int((level * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(level > 1 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 44, alignment: .trailing)
            Menu {
                Button { engine.setAppOutput(app, nil) } label: {
                    if ownOutput == nil { Label("Main output", systemImage: "checkmark") } else { Text("Main output") }
                }
                Divider()
                ForEach(outputs) { output in
                    Button { engine.setAppOutput(app, output.uid) } label: {
                        if ownOutput == output.uid { Label(output.name, systemImage: "checkmark") } else { Text(output.name) }
                    }
                }
            } label: {
                Image(systemName: ownOutput == nil ? "chevron.down" : "arrow.triangle.branch")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help(ownOutput.flatMap { uid in outputs.first { $0.uid == uid }?.name } ?? "Plays on the main output")
        }
    }
}

struct SoundMixerSettingsView: View {
    @State private var settings = SoundSettings.shared
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Show the speaker in the menu bar", isOn: $settings.showInMenuBar)
            LabeledContent("Switch to the next output") {
                ShortcutRecorder(shortcut: settings.cycleShortcut) { settings.cycleShortcut = $0 }
            }
            ShortcutWarning(text: ShortcutConflicts.warning(for: settings.cycleShortcut, registered: settings.cycleRegistered,
                                                            owner: "sound-cycle", panel: appSettings.panelShortcut))
        } footer: {
            Text("Click the speaker for the volume, the output, and a slider for each app playing sound (up to 200%). Each app's level and output are remembered. Changing an app's level passes its sound through Zephydian, so macOS asks once for System Audio Recording; nothing is recorded or saved, and apps left at 100% aren't touched. Needs macOS 14.2 or newer.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if !settings.levels.isEmpty || !settings.outputs.isEmpty {
            Section("Remembered") {
                ForEach(Array(Set(settings.levels.keys).union(settings.outputs.keys)).sorted(), id: \.self) { id in
                    LabeledContent(AppNames.name(id)) {
                        HStack {
                            if let level = settings.levels[id] { Text("\(Int((level * 100).rounded()))%").monospacedDigit() }
                            if let uid = settings.outputs[id] { Text(AudioSystem.output(uid: uid)?.name ?? "Another output").foregroundStyle(.secondary) }
                            Button("Reset") {
                                settings.levels[id] = nil
                                settings.outputs[id] = nil
                            }
                        }
                    }
                }
            }
        }
    }
}
