import AppKit
import Observation

// MARK: - Setting value types

nonisolated enum Corner: String, CaseIterable, Identifiable {
    case topLeft = "tl", topRight = "tr", bottomLeft = "bl", bottomRight = "br"

    var id: Self { self }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }

    var name: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
}

nonisolated enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

nonisolated enum AutoHideMode: String, CaseIterable, Identifiable {
    case smart, always, never
    var id: Self { self }
    var title: String { rawValue.capitalized }

    var explanation: String {
        switch self {
        case .smart: "Hides when the mouse leaves, but never while a game is open or you’re typing a note."
        case .always: "Hides whenever the mouse leaves the panel. Games pause automatically."
        case .never: "Only Esc, a click outside, or the corner closes the panel."
        }
    }
}

nonisolated enum MenuBarIcon: String, CaseIterable, Identifiable {
    case logo, wind, controller, sparkles, grid, note, hidden
    var id: Self { self }

    var title: String {
        switch self {
        case .logo: "Zephydian logo"
        case .wind: "Wind"
        case .controller: "Controller"
        case .sparkles: "Sparkles"
        case .grid: "Grid"
        case .note: "Note"
        case .hidden: "Hidden"
        }
    }

    /// SF Symbol name, or nil for the custom logo asset.
    var symbolName: String? {
        switch self {
        case .logo: nil
        case .wind: "wind"
        case .controller: "gamecontroller"
        case .sparkles: "sparkles"
        case .grid: "square.grid.2x2"
        case .note: "note.text"
        case .hidden: "circle.slash"
        }
    }
}

/// How the panel's background looks.
nonisolated enum PanelStyle: String, CaseIterable, Identifiable {
    case glass, frosted
    var id: Self { self }
    var title: String { self == .glass ? "Liquid Glass" : "Frosted" }

    /// Apple's macOS 26+ glass panels (like Control Center) use rounder, "concentric" corners.
    var cornerRadius: CGFloat { self == .glass ? 24 : 16 }
}

/// Optional system-wide shortcut to open the panel. Presets avoid clashing with common app shortcuts.
// MARK: - Store

/// All user preferences, saved to UserDefaults as soon as they change.
@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    var corner: Corner { didSet { defaults.set(corner.rawValue, forKey: "corner") } }
    var dwellMs: Int { didSet { defaults.set(dwellMs, forKey: "dwellMs") } }
    /// `nil` means the main display (the one with the menu bar).
    var displayName: String? { didSet { defaults.set(displayName, forKey: "displayName") } }
    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var accent: AccentTheme { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    var menuBarIcon: MenuBarIcon { didSet { defaults.set(menuBarIcon.rawValue, forKey: "menuBarIcon") } }
    var autoHide: AutoHideMode { didSet { defaults.set(autoHide.rawValue, forKey: "autoHide") } }
    var hideDelayMs: Int { didSet { defaults.set(hideDelayMs, forKey: "hideDelayMs") } }
    var notesMonospaced: Bool { didSet { defaults.set(notesMonospaced, forKey: "notesMonospaced") } }
    var fiveHighContrast: Bool { didSet { defaults.set(fiveHighContrast, forKey: "fiveHighContrast") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }
    var panelStyle: PanelStyle { didSet { defaults.set(panelStyle.rawValue, forKey: "panelStyle") } }
    /// The panel's global shortcut, recorded by the person (nil = none).
    var panelShortcut: KeyShortcut? { didSet { defaults.set(try? JSONEncoder().encode(panelShortcut), forKey: "panelShortcut") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<E: RawRepresentable>(_ key: String, _ fallback: E) -> E where E.RawValue == String {
            guard let raw = defaults.string(forKey: key), let saved = E(rawValue: raw) else { return fallback }
            return saved
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
        }
        corner = value("corner", .topRight)
        dwellMs = int("dwellMs", 150)
        displayName = defaults.string(forKey: "displayName")
        appearance = value("appearance", .system)
        accent = value("accent", .sky)
        menuBarIcon = value("menuBarIcon", .logo)
        autoHide = value("autoHide", .smart)
        hideDelayMs = int("hideDelayMs", 400)
        notesMonospaced = defaults.bool(forKey: "notesMonospaced")
        fiveHighContrast = defaults.bool(forKey: "fiveHighContrast")
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        panelStyle = value("panelStyle", .glass)
        // Worked out first and assigned once: in an @Observable class even this assignment saves.
        var shortcut = defaults.data(forKey: "panelShortcut").flatMap { try? JSONDecoder().decode(KeyShortcut?.self, from: $0) } ?? nil
        // Before any key could be recorded there were three choices; keep the one picked.
        if defaults.object(forKey: "panelShortcut") == nil {
            switch defaults.string(forKey: "globalShortcut") {
            case "optionSpace": shortcut = KeyShortcut(keyCode: 49, modifiers: .option, key: "Space")
            case "controlOptionSpace": shortcut = KeyShortcut(keyCode: 49, modifiers: [.control, .option], key: "Space")
            case "controlOptionZ": shortcut = KeyShortcut(keyCode: 6, modifiers: [.control, .option], key: "Z")
            default: break
            }
        }
        panelShortcut = shortcut
    }

    /// The style actually in use: Liquid Glass needs macOS 26 or later.
    var effectivePanelStyle: PanelStyle {
        if #available(macOS 26, *) { return panelStyle }
        return .frosted
    }

    /// The display Zephydian lives on. Falls back to the main display if the chosen one is unplugged.
    var targetScreen: NSScreen? {
        let screens = NSScreen.screens
        if let displayName {
            for screen in screens where screen.localizedName == displayName {
                return screen
            }
        }
        return screens.first ?? NSScreen.main
    }
}
