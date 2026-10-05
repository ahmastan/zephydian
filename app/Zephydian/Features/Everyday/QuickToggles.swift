import AppKit
import CoreAudio
import SwiftUI

/// One quick toggle: a one-click switch or action for something macOS keeps a few clicks away.
/// They show on the Quick Toggles page, in the Command Bar and on the Quick Panel.
enum QuickToggle: String, CaseIterable, Identifiable {
    case darkMode, desktopIcons, hiddenFiles
    case ejectDisks, emptyTrash
    case lockScreen, displaysOff, screenSaver
    case keyboardLight, micMute

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case look, disks, screen, input
        var id: String { rawValue }
        var title: String {
            switch self {
            case .look: "Look"
            case .disks: "Disks and Trash"
            case .screen: "Screen"
            case .input: "Keyboard and Microphone"
            }
        }
    }

    var group: Group {
        switch self {
        case .darkMode, .desktopIcons, .hiddenFiles: .look
        case .ejectDisks, .emptyTrash: .disks
        case .lockScreen, .displaysOff, .screenSaver: .screen
        case .keyboardLight, .micMute: .input
        }
    }

    var title: String {
        switch self {
        case .darkMode: "Dark Mode"
        case .desktopIcons: "Desktop Icons"
        case .hiddenFiles: "Hidden Files"
        case .ejectDisks: "Eject All Disks"
        case .emptyTrash: "Empty Trash"
        case .lockScreen: "Lock Screen"
        case .displaysOff: "Turn Displays Off"
        case .screenSaver: "Screen Saver"
        case .keyboardLight: "Keyboard Light"
        case .micMute: "Mute Microphone"
        }
    }

    var symbol: String {
        switch self {
        case .darkMode: "circle.lefthalf.filled"
        case .desktopIcons: "menubar.dock.rectangle"
        case .hiddenFiles: "eye"
        case .ejectDisks: "eject"
        case .emptyTrash: "trash"
        case .lockScreen: "lock"
        case .displaysOff: "display"
        case .screenSaver: "sparkles.tv"
        case .keyboardLight: "light.max"
        case .micMute: "mic.slash"
        }
    }

    /// Words the Command Bar also matches.
    var keywords: [String] {
        switch self {
        case .darkMode: ["dark", "light", "appearance", "theme"]
        case .desktopIcons: ["desktop", "icons", "hide", "clean"]
        case .hiddenFiles: ["hidden", "dotfiles", "finder", "show"]
        case .ejectDisks: ["eject", "unmount", "drive", "usb"]
        case .emptyTrash: ["trash", "bin", "delete"]
        case .lockScreen: ["lock", "away"]
        case .displaysOff: ["sleep", "display", "screen", "off"]
        case .screenSaver: ["screensaver", "saver"]
        case .keyboardLight: ["backlight", "keyboard", "light"]
        case .micMute: ["mic", "microphone", "mute", "unmute"]
        }
    }

    /// Switches show On or Off; the others are one-off actions.
    var isSwitch: Bool {
        switch self {
        case .darkMode, .desktopIcons, .hiddenFiles, .keyboardLight, .micMute: true
        default: false
        }
    }

    /// A short line under its name about what happens.
    var note: String? {
        switch self {
        case .desktopIcons, .hiddenFiles: "Restarts Finder"
        case .emptyTrash: "Asks first"
        default: nil
        }
    }
}

/// Runs the quick toggles and knows the state of the switches. Everything that can take a moment
/// (Finder, disks, `pmset`) runs off the main thread.
@Observable
final class QuickToggles {
    static let shared = QuickToggles()

    /// The switches' current state, refreshed when a page shows them (`refresh()`) and after each change.
    private(set) var states: [QuickToggle: Bool] = [:]
    /// Toggles that are working right now (ejecting, emptying the Trash).
    private(set) var busy: Set<QuickToggle> = []

    /// Whether this Mac has the hardware or system function a toggle needs.
    func isAvailable(_ toggle: QuickToggle) -> Bool {
        switch toggle {
        case .darkMode: SystemCalls.appearance != nil
        case .keyboardLight: KeyboardLight.shared.isSupported
        case .micMute: Microphone.hasInput
        default: true
        }
    }

    func isOn(_ toggle: QuickToggle) -> Bool { states[toggle] ?? false }

    func refresh() {
        states[.darkMode] = SystemCalls.appearance?.get() ?? false
        states[.desktopIcons] = FinderFlags.read("CreateDesktop", default: true)
        states[.hiddenFiles] = FinderFlags.read("AppleShowAllFiles", default: false)
        states[.keyboardLight] = (KeyboardLight.shared.level ?? 0) > 0
        states[.micMute] = Microphone.isMuted
    }

    /// Runs a toggle. `confirmed`: the caller already asked (the Command Bar asks inline).
    func run(_ toggle: QuickToggle, confirmed: Bool = false) {
        guard isAvailable(toggle), !busy.contains(toggle) else { return }
        switch toggle {
        case .darkMode:
            guard let appearance = SystemCalls.appearance else { return }
            appearance.set(!appearance.get())
        case .desktopIcons:
            setFinderFlag(toggle, key: "CreateDesktop", to: !isOn(.desktopIcons))
        case .hiddenFiles:
            setFinderFlag(toggle, key: "AppleShowAllFiles", to: !isOn(.hiddenFiles))
        case .ejectDisks:
            ejectAll()
        case .emptyTrash:
            if confirmed || confirmEmptyTrash() { FinderEvents.emptyTrash() }
        case .lockScreen:
            SystemCalls.lockScreen()
        case .displaysOff:
            work(toggle) { _ = Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }
        case .screenSaver:
            NSWorkspace.shared.openApplication(at: URL(filePath: "/System/Library/CoreServices/ScreenSaverEngine.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        case .keyboardLight:
            KeyboardLight.shared.toggle()
        case .micMute:
            let muted = Microphone.setMuted(!Microphone.isMuted)
            CaptureToast.show(muted ? "Microphone muted" : "Microphone on", symbol: muted ? "mic.slash.fill" : "mic.fill")
        }
        refresh()
    }

    // MARK: Private

    private func confirmEmptyTrash() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "Everything in the Trash is deleted for good. This can't be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Finder reads these only when it starts, so it's restarted (macOS brings it straight back).
    private func setFinderFlag(_ toggle: QuickToggle, key: String, to value: Bool) {
        FinderFlags.write(key, value)
        states[toggle] = value
        work(toggle) { _ = Shell.run("/usr/bin/killall", ["Finder"]) }
    }

    private func ejectAll() {
        work(.ejectDisks) {
            let volumes = Disks.ejectable()
            var failed = 0
            for volume in volumes {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) } catch {
                    // A disk with several volumes leaves with the first one, so only count a volume
                    // that's still there.
                    if FileManager.default.fileExists(atPath: volume.path) { failed += 1 }
                }
            }
            let text = volumes.isEmpty ? "No disks to eject" : failed == 0 ? "Disks ejected" : "\(failed) disk\(failed == 1 ? "" : "s") couldn't be ejected"
            Task { @MainActor in CaptureToast.show(text, symbol: failed == 0 ? "eject.fill" : "exclamationmark.triangle.fill",
                                                   detail: failed == 0 ? nil : "An app is still using it.") }
        }
    }

    /// Runs slow work off the main thread, marking the toggle busy meanwhile.
    private func work(_ toggle: QuickToggle, _ body: @escaping @Sendable () -> Void) {
        busy.insert(toggle)
        Task.detached(priority: .userInitiated) {
            body()
            await MainActor.run { [weak self] in
                self?.busy.remove(toggle)
                self?.refresh()
            }
        }
    }
}

/// Undocumented system functions the toggles use, looked up once; nil where macOS doesn't have them.
nonisolated enum SystemCalls {
    struct Appearance: @unchecked Sendable {
        let get: @convention(c) () -> Bool
        let set: @convention(c) (Bool) -> Void
    }

    /// The light/dark switch System Settings uses (no Automation permission needed).
    static let appearance: Appearance? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let get = dlsym(handle, "SLSGetAppearanceThemeLegacy"),
              let set = dlsym(handle, "SLSSetAppearanceThemeLegacy") else { return nil }
        return Appearance(get: unsafeBitCast(get, to: (@convention(c) () -> Bool).self),
                          set: unsafeBitCast(set, to: (@convention(c) (Bool) -> Void).self))
    }()

    private static let lock: (@convention(c) () -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }()

    /// Locks right away, like ⌃⌘Q; falls back to the screen saver (which locks if a password is set).
    @MainActor static func lockScreen() {
        if let lock { _ = lock(); return }
        NSWorkspace.shared.openApplication(at: URL(filePath: "/System/Library/CoreServices/ScreenSaverEngine.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Finder's own preferences (read and written directly; Zephydian isn't sandboxed).
nonisolated enum FinderFlags {
    private static var app: CFString { "com.apple.finder" as CFString }

    static func read(_ key: String, default value: Bool) -> Bool {
        CFPreferencesAppSynchronize(app)
        switch CFPreferencesCopyAppValue(key as CFString, app) {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String: return ["yes", "true", "1"].contains(text.lowercased())
        default: return value
        }
    }

    static func write(_ key: String, _ value: Bool) {
        CFPreferencesSetAppValue(key as CFString, value as CFBoolean, app)
        CFPreferencesAppSynchronize(app)
    }
}

/// External disks that can be ejected (not the startup disk or other internal volumes).
nonisolated enum Disks {
    static func ejectable() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsRootFileSystem != true else { return false }
            return values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false
        }
    }
}

/// Runs a command-line tool and waits (call it off the main thread).
nonisolated enum Shell {
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// The built-in keyboard's backlight, through CoreBrightness's keyboard client (what Control Center uses).
final class KeyboardLight {
    static let shared = KeyboardLight()

    private let client: NSObject?
    private let keyboard: UInt64?
    /// The last level that wasn't off, to go back to.
    private var lastLevel: Float {
        get { UserDefaults.standard.object(forKey: "quickToggles.keyboardLevel") as? Float ?? 0.5 }
        set { UserDefaults.standard.set(newValue, forKey: "quickToggles.keyboardLevel") }
    }

    private init() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        let client = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
        let ids = Selector(("copyKeyboardBacklightIDs"))
        if let client, client.responds(to: ids), client.responds(to: Selector(("brightnessForKeyboard:"))),
           client.responds(to: Selector(("setBrightness:forKeyboard:"))),
           let list = client.perform(ids)?.takeRetainedValue() as? [NSNumber], let first = list.first {
            self.client = client
            keyboard = first.uint64Value
        } else {
            self.client = nil
            keyboard = nil
        }
    }

    var isSupported: Bool { client != nil }

    var level: Float? {
        guard let client, let keyboard else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
        let selector = Selector(("brightnessForKeyboard:"))
        return unsafeBitCast(client.method(for: selector), to: Get.self)(client, selector, keyboard)
    }

    func set(_ value: Float) {
        guard let client, let keyboard else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        let selector = Selector(("setBrightness:forKeyboard:"))
        _ = unsafeBitCast(client.method(for: selector), to: Set.self)(client, selector, value, keyboard)
    }

    func toggle() {
        let current = level ?? 0
        if current > 0 {
            lastLevel = current
            set(0)
        } else {
            set(max(lastLevel, 0.1))
        }
    }
}

/// Every microphone's mute, through Core Audio. Muting covers all input devices, so switching to
/// another microphone doesn't unmute you; devices without a mute switch get their input volume
/// set to zero (and put back on unmute).
nonisolated enum Microphone {
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Devices with at least one input stream.
    static var inputs: [AudioObjectID] {
        var where_ = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
            var count: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &count) == noErr && count > 0
        }
    }

    static var hasInput: Bool { defaultInput != nil }

    static var defaultInput: AudioObjectID? {
        var where_ = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static var isMuted: Bool {
        guard let id = defaultInput else { return false }
        if let mute = mute(of: id) { return mute }
        return (volume(of: id) ?? 1) == 0
    }

    /// Mutes or unmutes every input; returns the new state.
    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        let saved = UserDefaults.standard.dictionary(forKey: "quickToggles.micVolumes") as? [String: Float] ?? [:]
        var volumes = saved
        for id in inputs {
            var muteAddress = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(id, &muteAddress, &settable) == noErr, settable.boolValue {
                var value: UInt32 = muted ? 1 : 0
                AudioObjectSetPropertyData(id, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            } else if let volume = volume(of: id) {
                let key = String(id)
                if muted {
                    if volume > 0 { volumes[key] = volume }
                    setVolume(0, of: id)
                } else {
                    setVolume(volumes.removeValue(forKey: key) ?? 0.75, of: id)
                }
            }
        }
        UserDefaults.standard.set(volumes, forKey: "quickToggles.micVolumes")
        return isMuted
    }

    private static func mute(of id: AudioObjectID) -> Bool? {
        var where_ = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        guard AudioObjectHasProperty(id, &where_) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func volume(of id: AudioObjectID) -> Float? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var where_ = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, element)
            guard AudioObjectHasProperty(id, &where_) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &where_, 0, nil, &size, &value) == noErr { return value }
        }
        return nil
    }

    private static func setVolume(_ value: Float, of id: AudioObjectID) {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var where_ = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, element)
            guard AudioObjectHasProperty(id, &where_) else { continue }
            var volume = Float32(value)
            AudioObjectSetPropertyData(id, &where_, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        }
    }
}

// MARK: - The feature

@Observable
final class QuickTogglesSettings {
    static let shared = QuickTogglesSettings()

    /// Mutes or unmutes the microphone from anywhere.
    var micShortcut: KeyShortcut? { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(micShortcut), forKey: "quickToggles.micShortcut") } }
    var micRegistered = true

    init() {
        micShortcut = UserDefaults.standard.data(forKey: "quickToggles.micShortcut")
            .flatMap { try? JSONDecoder().decode(KeyShortcut?.self, from: $0) } ?? nil
    }
}

/// While on, the toggles show in the Command Bar and on the Quick Panel, and the microphone
/// shortcut works. Nothing runs in the background.
final class QuickTogglesEngine: FeatureEngine {
    private let settings = QuickTogglesSettings.shared
    private let hotKey = GlobalHotKey(id: 703)
    private var running = false

    func start() {
        running = true
        hotKey.onPress = { QuickToggles.shared.run(.micMute) }
        follow()
    }

    func stop() {
        running = false
        hotKey.unregister()
    }

    private func follow() {
        guard running else { return }
        withObservationTracking { _ = settings.micShortcut } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        settings.micRegistered = hotKey.register(settings.micShortcut)
    }
}

/// A Control Center-style tile for one toggle (the Settings page and the Quick Panel).
struct QuickToggleTile: View {
    let toggle: QuickToggle
    var compact = false
    @State private var toggles = QuickToggles.shared
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        let on = toggle.isSwitch && toggles.isOn(toggle)
        let available = toggles.isAvailable(toggle)
        Button { toggles.run(toggle) } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(on ? AnyShapeStyle(appSettings.accentColor) : AnyShapeStyle(.quaternary))
                    if toggles.busy.contains(toggle) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: toggle.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(on ? .white : .primary)
                    }
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(toggle.title).font(.callout.weight(.medium)).lineLimit(1)
                    if !compact, let line = available ? (toggle.isSwitch ? (on ? "On" : "Off") : toggle.note) : "Not on this Mac" {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.5)
        .accessibilityValue(toggle.isSwitch ? (on ? "On" : "Off") : "")
    }
}

struct QuickTogglesSettingsView: View {
    @State private var settings = QuickTogglesSettings.shared
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        ForEach(QuickToggle.Group.allCases) { group in
            Section(group.title) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    ForEach(QuickToggle.allCases.filter { $0.group == group }) { QuickToggleTile(toggle: $0) }
                }
                .padding(.vertical, 4)
            }
        }
        Section {
            LabeledContent("Mute or unmute the microphone") {
                ShortcutRecorder(shortcut: settings.micShortcut) { settings.micShortcut = $0 }
            }
            ShortcutWarning(text: ShortcutConflicts.warning(for: settings.micShortcut, registered: settings.micRegistered,
                                                            owner: "mic-mute", panel: appSettings.panelShortcut))
        } footer: {
            Text("The toggles are also in the Command Bar and on the Quick Panel. Muting covers every microphone, so switching to another one doesn't unmute you.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { QuickToggles.shared.refresh() }
    }
}
