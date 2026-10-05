import AppKit
import Carbon.HIToolbox

/// A place a window can be put.
enum WindowLayout: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case maximize, center, restore
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case topLeft, topRight, bottomLeft, bottomRight
    case nextDisplay, previousDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: "Left half"
        case .rightHalf: "Right half"
        case .topHalf: "Top half"
        case .bottomHalf: "Bottom half"
        case .maximize: "Maximize"
        case .center: "Center"
        case .restore: "Restore"
        case .firstThird: "First third"
        case .centerThird: "Center third"
        case .lastThird: "Last third"
        case .firstTwoThirds: "First two-thirds"
        case .lastTwoThirds: "Last two-thirds"
        case .topLeft: "Top-left quarter"
        case .topRight: "Top-right quarter"
        case .bottomLeft: "Bottom-left quarter"
        case .bottomRight: "Bottom-right quarter"
        case .nextDisplay: "Next display"
        case .previousDisplay: "Previous display"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .maximize: "rectangle.fill"
        case .center: "rectangle.center.inset.filled"
        case .restore: "arrow.uturn.backward"
        case .firstThird: "rectangle.leftthird.inset.filled"
        case .centerThird: "rectangle.center.inset.filled"
        case .lastThird: "rectangle.rightthird.inset.filled"
        case .firstTwoThirds, .lastTwoThirds: "rectangle.split.3x1"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .nextDisplay: "arrow.right.to.line"
        case .previousDisplay: "arrow.left.to.line"
        }
    }

    /// The ⌃⌥ set (19-D14).
    var defaultShortcut: KeyShortcut {
        let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]
        switch self {
        case .leftHalf: return KeyShortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: ctrlOpt, key: "←")
        case .rightHalf: return KeyShortcut(keyCode: UInt16(kVK_RightArrow), modifiers: ctrlOpt, key: "→")
        case .topHalf: return KeyShortcut(keyCode: UInt16(kVK_UpArrow), modifiers: ctrlOpt, key: "↑")
        case .bottomHalf: return KeyShortcut(keyCode: UInt16(kVK_DownArrow), modifiers: ctrlOpt, key: "↓")
        case .maximize: return KeyShortcut(keyCode: UInt16(kVK_Return), modifiers: ctrlOpt, key: "↩")
        case .center: return KeyShortcut(keyCode: UInt16(kVK_ANSI_C), modifiers: ctrlOpt, key: "C")
        case .restore: return KeyShortcut(keyCode: UInt16(kVK_Delete), modifiers: ctrlOpt, key: "⌫")
        case .firstThird: return KeyShortcut(keyCode: UInt16(kVK_ANSI_D), modifiers: ctrlOpt, key: "D")
        case .centerThird: return KeyShortcut(keyCode: UInt16(kVK_ANSI_F), modifiers: ctrlOpt, key: "F")
        case .lastThird: return KeyShortcut(keyCode: UInt16(kVK_ANSI_G), modifiers: ctrlOpt, key: "G")
        case .firstTwoThirds: return KeyShortcut(keyCode: UInt16(kVK_ANSI_E), modifiers: ctrlOpt, key: "E")
        case .lastTwoThirds: return KeyShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: ctrlOpt, key: "T")
        case .topLeft: return KeyShortcut(keyCode: UInt16(kVK_ANSI_U), modifiers: ctrlOpt, key: "U")
        case .topRight: return KeyShortcut(keyCode: UInt16(kVK_ANSI_I), modifiers: ctrlOpt, key: "I")
        case .bottomLeft: return KeyShortcut(keyCode: UInt16(kVK_ANSI_J), modifiers: ctrlOpt, key: "J")
        case .bottomRight: return KeyShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: ctrlOpt, key: "K")
        case .nextDisplay: return KeyShortcut(keyCode: UInt16(kVK_RightArrow), modifiers: [.control, .option, .command], key: "→")
        case .previousDisplay: return KeyShortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: [.control, .option, .command], key: "←")
        }
    }
}

/// Settings for the Windows features (Window Layout, the green button, quit and close protection,
/// quit on close, focus follows mouse), saved as they change.
@Observable
final class WindowToolsSettings {
    static let shared = WindowToolsSettings()

    enum DragModifier: String, CaseIterable, Identifiable {
        case option, controlOption, commandOption, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .option: "⌥ (⌥⌘ resizes)"
            case .controlOption: "⌃⌥ (⌃⌥⌘ resizes)"
            case .commandOption: "⌥⌘ (⌃⌥⌘ resizes)"
            case .off: "Off"
            }
        }
        /// Held to move; `resize` held to resize.
        var move: NSEvent.ModifierFlags? {
            switch self {
            case .option: [.option]
            case .controlOption: [.control, .option]
            case .commandOption: [.option, .command]
            case .off: nil
            }
        }
        var resize: NSEvent.ModifierFlags? {
            switch self {
            case .option: [.option, .command]
            case .controlOption, .commandOption: [.control, .option, .command]
            case .off: nil
            }
        }
    }

    enum Protection: String, CaseIterable, Identifiable {
        case twice, hold, extraKey
        var id: String { rawValue }
        var title: String {
            switch self {
            case .twice: "Press twice"
            case .hold: "Hold"
            case .extraKey: "Add ⌥"
            }
        }
    }

    // Window Layout
    var shortcuts: [WindowLayout: KeyShortcut] { didSet { saveShortcuts() } }
    var gap: Int { didSet { save("gap", gap) } }
    var dragModifier: DragModifier { didSet { save("dragModifier", dragModifier.rawValue) } }
    /// Pressing a half's shortcut again cycles ½ → ⅔ → ⅓.
    var cycleSizes: Bool { didSet { save("cycleSizes", cycleSizes) } }
    var layoutIgnoredApps: [String] { didSet { save("layoutIgnoredApps", layoutIgnoredApps) } }

    // Maximize with the green button
    var greenIgnoredApps: [String] { didSet { save("greenIgnoredApps", greenIgnoredApps) } }

    // Quit and close protection
    var protection: Protection { didSet { save("protection", protection.rawValue) } }
    var protectClose: Bool { didSet { save("protectClose", protectClose) } }
    var protectionIgnoredApps: [String] { didSet { save("protectionIgnoredApps", protectionIgnoredApps) } }

    // Quit on close: every app quits with its last window, except these.
    var keepOpenApps: [String] { didSet { save("keepOpenApps", keepOpenApps) } }
    /// Media apps keep playing with no window, so they start in the list.
    static let defaultKeepOpenApps = ["com.apple.Music", "com.apple.podcasts", "com.apple.TV"]

    // Focus follows mouse
    var focusDelay: Int { didSet { save("focusDelay", focusDelay) } }
    var focusIgnoredApps: [String] { didSet { save("focusIgnoredApps", focusIgnoredApps) } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: "windowTools.\(key)") as? T ?? fallback }
        if let data = defaults.data(forKey: "windowTools.shortcuts"),
           let saved = try? JSONDecoder().decode([String: KeyShortcut?].self, from: data) {
            var map: [WindowLayout: KeyShortcut] = [:]
            for layout in WindowLayout.allCases {
                if let entry = saved[layout.rawValue] { if let entry { map[layout] = entry } }
                else { map[layout] = layout.defaultShortcut }   // a layout added in a later version
            }
            shortcuts = map
        } else {
            shortcuts = Dictionary(uniqueKeysWithValues: WindowLayout.allCases.map { ($0, $0.defaultShortcut) })
        }
        gap = value("gap", 0)
        dragModifier = DragModifier(rawValue: value("dragModifier", "")) ?? .option
        cycleSizes = value("cycleSizes", true)
        layoutIgnoredApps = value("layoutIgnoredApps", [String]())
        greenIgnoredApps = value("greenIgnoredApps", [String]())
        protection = Protection(rawValue: value("protection", "")) ?? .twice
        protectClose = value("protectClose", false)
        protectionIgnoredApps = value("protectionIgnoredApps", [String]())
        keepOpenApps = value("keepOpenApps", Self.defaultKeepOpenApps)
        focusDelay = value("focusDelay", 250)
        focusIgnoredApps = value("focusIgnoredApps", [String]())
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: "windowTools.\(key)") }

    /// Saved with an explicit "none" for cleared shortcuts, so a cleared one doesn't come back.
    private func saveShortcuts() {
        var out: [String: KeyShortcut?] = [:]
        for layout in WindowLayout.allCases { out[layout.rawValue] = shortcuts[layout] }
        defaults.set(try? JSONEncoder().encode(out), forKey: "windowTools.shortcuts")
    }
}
