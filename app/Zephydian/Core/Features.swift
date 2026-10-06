import SwiftUI

/// The running part of a system feature. `start` only happens while the feature is switched on and
/// has the permissions it requires; `stop` must undo everything (taps, observers, windows), so a
/// feature that's off costs nothing.
protocol FeatureEngine: AnyObject {
    func start()
    func stop()
}

/// Where a feature sits on the Features page and in the Settings sidebar.
enum FeatureGroup: String, CaseIterable, Identifiable {
    case windows, keyboardMouse, clipboardFiles, capture, everyday, system, apps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windows: "Windows & Dock"
        case .keyboardMouse: "Keyboard & Mouse"
        case .clipboardFiles: "Clipboard & Files"
        case .capture: "Capture"
        case .everyday: "Everyday Tools"
        case .system: "System & Sound"
        case .apps: "Apps"
        }
    }
}

/// A system feature: built into the app, switched on and off on the Features page.
struct Feature: Identifiable {
    let id: String
    let name: String
    /// One plain line about what it does.
    let summary: String
    let symbol: String
    let group: FeatureGroup
    /// Without these it can't run at all.
    var requires: [Permission] = []
    /// It works without these, but does more with them (window thumbnails, for example).
    var uses: [Permission] = []
    /// Part of the Essentials preset.
    var essential = false
    /// Its own settings, shown under the status on its page.
    var settings: (() -> AnyView)?
    let makeEngine: () -> FeatureEngine

    var permissions: [Permission] { requires + uses.filter { !requires.contains($0) } }
}

/// A one-click starting point on the Features page and in the welcome tour.
enum FeaturePreset: String, CaseIterable, Identifiable {
    case essentials, everything, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .essentials: "Essentials"
        case .everything: "Everything"
        case .none: "None"
        }
    }
}

/// Every system feature, which ones are switched on, and their engines.
@Observable
final class Features {
    static let shared = Features()

    let all: [Feature]
    private(set) var enabled: Set<String>
    /// The app's settings (panel style, accent, appearance), for features that draw their own windows.
    /// Set by AppDelegate before `start()`.
    @ObservationIgnored var appSettings: SettingsStore?
    /// Switched on and running (it had the permissions it requires).
    private(set) var running: Set<String> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var engines: [String: FeatureEngine] = [:]
    @ObservationIgnored private var started = false

    private static let key = "features.enabled"

    init(catalog: [Feature] = Features.catalog, defaults: UserDefaults = .standard) {
        all = catalog
        self.defaults = defaults
        let ids = Set(catalog.map(\.id))
        enabled = Set(defaults.stringArray(forKey: Self.key) ?? []).intersection(ids)
    }

    func feature(_ id: String) -> Feature? { all.first { $0.id == id } }
    func isOn(_ id: String) -> Bool { enabled.contains(id) }

    /// The permissions a switched-on feature still needs before it can run.
    func missing(_ feature: Feature) -> [Permission] {
        feature.requires.filter { !Permissions.shared.isGranted($0) }
    }

    /// Starts the switched-on features, and keeps them in step with permission changes. Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        observePermissions()
    }

    func set(_ id: String, on: Bool) {
        guard let feature = feature(id) else { return }
        if on { enabled.insert(id) } else { enabled.remove(id) }
        save()
        if on { ask(for: [feature]) }
        sync()
    }

    func apply(_ preset: FeaturePreset) {
        let chosen: [Feature] = switch preset {
        case .essentials: all.filter(\.essential)
        case .everything: all
        case .none: []
        }
        let newlyOn = chosen.filter { !enabled.contains($0.id) }
        enabled = Set(chosen.map(\.id))
        save()
        ask(for: newlyOn)
        sync()
    }

    /// The features and utilities that use a permission right now, by name.
    func users(of permission: Permission) -> [String] {
        let features = all.filter { enabled.contains($0.id) && $0.permissions.contains(permission) }.map(\.name)
        let utilities = PackLibrary.shared.packs
            .filter { ($0.manifest.capabilities ?? []).contains { permission.capabilities.contains($0) } }
            .map(\.manifest.name)
        return features + utilities
    }

    /// Stops everything (at quit, so anything a feature changed is put back).
    func stopAll() {
        for id in running { engines[id]?.stop() }
        running = []
        engines = [:]
    }

    // MARK: Private

    /// Asks once for each permission the given features require and don't have yet.
    private func ask(for features: [Feature]) {
        var asked: Set<Permission> = []
        for feature in features {
            for permission in missing(feature) where asked.insert(permission).inserted {
                Permissions.shared.request(permission)
            }
        }
    }

    /// Starts what should run and stops what shouldn't.
    private func sync() {
        guard started else { return }
        for feature in all {
            let shouldRun = enabled.contains(feature.id) && missing(feature).isEmpty
            if shouldRun, !running.contains(feature.id) {
                let engine = engines[feature.id] ?? feature.makeEngine()
                engines[feature.id] = engine
                engine.start()
                running.insert(feature.id)
            } else if !shouldRun, running.contains(feature.id) {
                engines[feature.id]?.stop()
                engines[feature.id] = nil
                running.remove(feature.id)
            }
        }
    }

    /// Re-syncs whenever a permission is granted or taken away (macOS tells `Permissions`).
    private func observePermissions() {
        withObservationTracking {
            _ = Permissions.shared.granted
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.observePermissions()
            }
        }
        sync()
    }

    private func save() {
        defaults.set(enabled.sorted(), forKey: Self.key)
    }
}

extension Permission {
    /// The pack capabilities that make a utility use this permission.
    var capabilities: [String] {
        switch self {
        case .accessibility: ["clipboard.paste"]
        case .screenRecording: ["screen.capture", "screen.record", "screen.text"]
        case .microphone: ["screen.record"]
        case .camera: []
        }
    }
}

// MARK: - The catalog

extension Features {
    /// Every feature the app has. Each stage of Phase 19 adds its features here.
    static var catalog: [Feature] {
        [
            Feature(
                id: "dock-preview", name: "Dock Preview",
                summary: "Hover an open app in the Dock to see its windows, then click the one you want.",
                symbol: "dock.rectangle", group: .windows, requires: [.accessibility], uses: [.screenRecording], essential: true,
                settings: { AnyView(DockPreviewSettingsView()) },
                makeEngine: { DockPreviewEngine(appSettings: Features.shared.appSettings ?? SettingsStore()) }),
            Feature(
                id: "switcher", name: "App Switcher",
                summary: "⌘Tab with a live preview of every window, search, and quick close and quit.",
                symbol: "rectangle.on.rectangle", group: .windows, requires: [.accessibility], uses: [.screenRecording], essential: true,
                settings: { AnyView(SwitcherSettingsView()) },
                makeEngine: { SwitcherFeatureEngine() }),
            Feature(
                id: "window-layout", name: "Window Layout",
                summary: "Snap windows to halves, thirds and quarters with shortcuts, and move them from anywhere with ⌥-drag.",
                symbol: "rectangle.split.2x1", group: .windows, requires: [.accessibility], essential: true,
                settings: { AnyView(WindowLayoutSettingsView()) },
                makeEngine: { WindowLayoutEngine() }),
            Feature(
                id: "green-button", name: "Maximize with the Green Button",
                summary: "The green button fills the screen instead of opening a full-screen space. ⌥-click still goes full screen.",
                symbol: "arrow.up.left.and.arrow.down.right", group: .windows, requires: [.accessibility],
                settings: { AnyView(GreenButtonSettingsView()) },
                makeEngine: { GreenButtonEngine() }),
            Feature(
                id: "quit-protection", name: "Quit Protection",
                summary: "Press ⌘Q twice (or hold it) to quit, so a slip doesn't close an app. ⌘W too, if you like.",
                symbol: "hand.raised.square", group: .windows, requires: [.accessibility], essential: true,
                settings: { AnyView(QuitProtectionSettingsView()) },
                makeEngine: { QuitProtectionEngine() }),
            Feature(
                id: "quit-on-close", name: "Quit on Close",
                summary: "Apps quit when you close their last window, except the ones you keep open.",
                symbol: "xmark.app", group: .windows, requires: [.accessibility],
                settings: { AnyView(QuitOnCloseSettingsView()) },
                makeEngine: { QuitOnCloseEngine() }),
            Feature(
                id: "focus-follows-mouse", name: "Focus Follows Mouse",
                summary: "The window under the pointer comes forward when the pointer rests on it.",
                symbol: "cursorarrow.motionlines", group: .windows, requires: [.accessibility],
                settings: { AnyView(FocusFollowsMouseSettingsView()) },
                makeEngine: { FocusFollowsMouseEngine() }),
            Feature(
                id: "snippets", name: "Text Snippets",
                summary: "Type a short trigger like ;addr and it becomes longer text, or pick a snippet from a menu.",
                symbol: "text.badge.plus", group: .keyboardMouse, requires: [.accessibility],
                settings: { AnyView(SnippetsSettingsView()) },
                makeEngine: { SnippetsEngine() }),
            Feature(
                id: "super-key", name: "Super Key",
                summary: "Caps Lock held becomes ⌃⌥⇧⌘ for clash-free shortcuts; tapped, it's Esc.",
                symbol: "capslock", group: .keyboardMouse, requires: [.accessibility],
                settings: { AnyView(SuperKeySettingsView()) },
                makeEngine: { SuperKeyEngine() }),
            Feature(
                id: "scrolling", name: "Scrolling",
                summary: "Smooth mouse wheel scrolling, its own direction, and sideways with a key. Trackpads aren't touched.",
                symbol: "scroll", group: .keyboardMouse, requires: [.accessibility],
                settings: { AnyView(ScrollingSettingsView()) },
                makeEngine: { ScrollingEngine() }),
            Feature(
                id: "mouse-buttons", name: "Mouse Buttons",
                summary: "Back and Forward on side buttons, shortcuts on extra buttons, and middle-button drags for desktops.",
                symbol: "computermouse", group: .keyboardMouse, requires: [.accessibility],
                settings: { AnyView(MouseButtonsSettingsView()) },
                makeEngine: { MouseButtonsEngine() }),
            Feature(
                id: "middle-click", name: "Three-Finger Middle Click",
                summary: "Press the trackpad with three fingers for a middle click.",
                symbol: "hand.point.up.left", group: .keyboardMouse, requires: [.accessibility],
                settings: { AnyView(MiddleClickSettingsView()) },
                makeEngine: { MiddleClickEngine() }),
            Feature(
                id: "pointer-acceleration", name: "No Mouse Acceleration",
                summary: "The pointer moves the same distance for the same hand movement, however fast.",
                symbol: "cursorarrow", group: .keyboardMouse,
                settings: { AnyView(PointerAccelerationSettingsView()) },
                makeEngine: { PointerAccelerationEngine() }),
            Feature(
                id: "click-filter", name: "Extra Click Filter",
                summary: "Ignores the double clicks a worn mouse button makes by itself.",
                symbol: "cursorarrow.click.2", group: .keyboardMouse, requires: [.accessibility],
                settings: { AnyView(ClickFilterSettingsView()) },
                makeEngine: { ClickFilterEngine() }),
            Feature(
                id: "key-debounce", name: "Key Debounce",
                summary: "Ignores the doubled letters a worn keyboard types by itself.",
                symbol: "keyboard.badge.ellipsis", group: .keyboardMouse, requires: [.accessibility],
                settings: { AnyView(KeyDebounceSettingsView()) },
                makeEngine: { KeyDebounceEngine() }),
            Feature(
                id: "clean-url", name: "Clean URLs",
                summary: "Links you copy lose their tracking (utm_source, fbclid and the like) before you paste them.",
                symbol: "link.badge.plus", group: .clipboardFiles, essential: true,
                settings: { AnyView(CleanURLSettingsView()) },
                makeEngine: { CleanURLEngine() }),
            Feature(
                id: "paste-plain", name: "Paste as Plain Text",
                summary: "⌥⇧⌘V pastes what you copied without its fonts, colors or links.",
                symbol: "doc.plaintext", group: .clipboardFiles, requires: [.accessibility],
                settings: { AnyView(PlainPasteSettingsView()) },
                makeEngine: { PlainPasteEngine() }),
            Feature(
                id: "auto-clear", name: "Auto-Clear Clipboard",
                summary: "Empties the clipboard a while after you copy, and when the Mac sleeps or locks.",
                symbol: "clear", group: .clipboardFiles,
                settings: { AnyView(AutoClearSettingsView()) },
                makeEngine: { AutoClearEngine() }),
            Feature(
                id: "shelf", name: "Shelf",
                summary: "Shake while dragging and a shelf appears: park files, links and text, drag them out later.",
                symbol: "tray.and.arrow.down", group: .clipboardFiles,
                settings: { AnyView(ShelfSettingsView()) },
                makeEngine: { ShelfEngine() }),
            Feature(
                id: "finder-shortcuts", name: "Finder Shortcuts",
                summary: "Cut and paste files with ⌘X and ⌘V, rename with F2, and paste an image as a PNG file.",
                symbol: "folder", group: .clipboardFiles, requires: [.accessibility],
                settings: { AnyView(FinderShortcutsSettingsView()) },
                makeEngine: { FinderShortcutsEngine() }),
            Feature(
                id: "dmg-installer", name: "Disk Image Installer",
                summary: "Opening a .dmg with an app offers to install it, eject it and throw the .dmg away.",
                symbol: "externaldrive.badge.plus", group: .clipboardFiles, essential: true,
                settings: { AnyView(DiskImageInstallerSettingsView()) },
                makeEngine: { DiskImageInstallerEngine() }),
            Feature(
                id: "camera-mirror", name: "Camera Mirror",
                summary: "A small floating view of your camera, to check how you look before a call.",
                symbol: "web.camera", group: .capture, requires: [.camera],
                settings: { AnyView(CameraMirrorSettingsView()) },
                makeEngine: { CameraMirrorEngine() }),
            Feature(
                id: "command-bar", name: "Command Bar",
                summary: "⌥Space opens one search for apps, windows, files, menus, clipboard and snippets, with math, units and settings.",
                symbol: "command", group: .everyday, uses: [.accessibility], essential: true,
                settings: { AnyView(CommandBarSettingsView()) },
                makeEngine: { CommandBarEngine() }),
            Feature(
                id: "quick-panel", name: "Quick Panel",
                summary: "A grid of your favorite tools and toggles in the middle of the screen, from a shortcut or the menu bar.",
                symbol: "square.grid.3x3", group: .everyday,
                settings: { AnyView(QuickPanelSettingsView()) },
                makeEngine: { QuickPanelEngine() }),
            Feature(
                id: "radial-menu", name: "Radial Menu",
                summary: "A wheel of apps, folders, utilities and actions around the pointer, from a shortcut or a mouse button.",
                symbol: "circle.circle", group: .everyday, uses: [.accessibility],
                settings: { AnyView(RadialMenuSettingsView()) },
                makeEngine: { RadialMenuEngine() }),
            Feature(
                id: "quick-toggles", name: "Quick Toggles",
                summary: "Dark mode, desktop icons, hidden files, eject disks, empty the Trash, lock, keyboard light and mute the mic, in one click.",
                symbol: "switch.2", group: .everyday, essential: true,
                settings: { AnyView(QuickTogglesSettingsView()) },
                makeEngine: { QuickTogglesEngine() }),
            Feature(
                id: "cleaning-mode", name: "Cleaning Mode",
                summary: "Locks the keyboard and trackpad while you wipe them. Press Esc five times to unlock.",
                symbol: "sparkles", group: .everyday, requires: [.accessibility],
                settings: { AnyView(CleaningModeSettingsView()) },
                makeEngine: { CleaningModeEngine() }),
            Feature(
                id: "sound-mixer", name: "Sound Mixer",
                summary: "A speaker in the menu bar with the volume, the output, and each app's own volume (up to 200%) and output.",
                symbol: "slider.vertical.3", group: .system,
                settings: { AnyView(SoundMixerSettingsView()) },
                makeEngine: { SoundMixerEngine() }),
            Feature(
                id: "headphones-safety", name: "Headphones Safety",
                summary: "Mutes the speakers when headphones disconnect, so music doesn't suddenly play out loud.",
                symbol: "headphones", group: .system,
                settings: { AnyView(HeadphonesSafetySettingsView()) },
                makeEngine: { HeadphonesSafetyEngine() }),
            Feature(
                id: "music-blocker", name: "Music Blocker",
                summary: "Stops the Music app from opening by itself. Hold ⌥ to open it on purpose.",
                symbol: "music.note.house", group: .system,
                settings: { AnyView(MusicBlockerSettingsView()) },
                makeEngine: { MusicBlockerEngine() }),
            Feature(
                id: "brightness", name: "Display Brightness",
                summary: "A sun in the menu bar with a brightness slider for every display, dimmer than the usual minimum too.",
                symbol: "sun.max", group: .system,
                settings: { AnyView(BrightnessSettingsView()) },
                makeEngine: { BrightnessEngine() }),
            Feature(
                id: "bluetooth-sleep", name: "Bluetooth Off in Sleep",
                summary: "Turns Bluetooth off while the Mac sleeps, so your headphones stay with your phone.",
                symbol: "antenna.radiowaves.left.and.right.slash", group: .system,
                settings: { AnyView(BluetoothSleepSettingsView()) },
                makeEngine: { BluetoothSleepEngine() }),
            Feature(
                id: "menu-bar-stats", name: "Menu Bar Stats",
                summary: "CPU, memory, network and more as small live figures beside the menu bar jet.",
                symbol: "menubar.rectangle", group: .system,
                settings: { AnyView(MenuBarStatsSettingsView()) },
                makeEngine: { MenuBarStatsEngine() }),
            Feature(
                id: "system-alerts", name: "System Alerts",
                summary: "A notification when the CPU stays busy, the Mac runs hot, memory is tight, the disk fills or the battery runs low.",
                symbol: "exclamationmark.triangle", group: .system,
                settings: { AnyView(SystemAlertsSettingsView()) },
                makeEngine: { SystemAlertsEngine() }),
        ]
    }
}
