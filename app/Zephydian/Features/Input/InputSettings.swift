import AppKit
import Carbon.HIToolbox

/// A text snippet: type its trigger and it becomes its text.
struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var text: String

    /// The text with its placeholders filled in: {clipboard}, {date}, {time}, {weekday}.
    func expanded(now: Date = Date()) -> String {
        var out = text
        if out.contains("{clipboard}") { out = out.replacingOccurrences(of: "{clipboard}", with: NSPasteboard.general.string(forType: .string) ?? "") }
        out = out.replacingOccurrences(of: "{date}", with: now.formatted(date: .abbreviated, time: .omitted))
        out = out.replacingOccurrences(of: "{time}", with: now.formatted(date: .omitted, time: .shortened))
        out = out.replacingOccurrences(of: "{weekday}", with: now.formatted(.dateTime.weekday(.wide)))
        return out
    }
}

/// What a mouse button (or a middle-button drag) does.
enum MouseAction: String, CaseIterable, Identifiable, Codable {
    case none, back, forward, middleClick, missionControl, appExpose, showDesktop, spaceLeft, spaceRight, shortcut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Nothing"
        case .back: "Back"
        case .forward: "Forward"
        case .middleClick: "Middle click"
        case .missionControl: "Mission Control"
        case .appExpose: "App windows (App Exposé)"
        case .showDesktop: "Show desktop"
        case .spaceLeft: "Desktop to the left"
        case .spaceRight: "Desktop to the right"
        case .shortcut: "A keyboard shortcut"
        }
    }
}

/// Settings for the Keyboard and Mouse features, saved as they change. Defaults are 19-D15's.
@Observable
final class InputSettings {
    static let shared = InputSettings()

    enum SuperKey: String, CaseIterable, Identifiable {
        case capsLock, rightCommand, rightOption
        var id: String { rawValue }
        var title: String {
            switch self {
            case .capsLock: "Caps Lock"
            case .rightCommand: "Right ⌘"
            case .rightOption: "Right ⌥"
            }
        }
    }

    enum TapAction: String, CaseIterable, Identifiable {
        case escape, capsLock, nothing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .escape: "Esc"
            case .capsLock: "Caps Lock"
            case .nothing: "Nothing"
            }
        }
    }

    enum SidewaysKey: String, CaseIterable, Identifiable {
        case shift, option, control
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shift: "⇧ (as macOS does)"
            case .option: "⌥"
            case .control: "⌃"
            }
        }
        var flag: NSEvent.ModifierFlags {
            switch self {
            case .shift: .shift
            case .option: .option
            case .control: .control
            }
        }
    }

    // Snippets
    var snippets: [Snippet] { didSet { saveCodable("snippets", snippets) } }
    var snippetMenuShortcut: KeyShortcut? { didSet { saveCodable("snippetMenuShortcut", snippetMenuShortcut) } }

    // Scrolling (mouse wheels only)
    var smoothScrolling: Bool { didSet { save("smoothScrolling", smoothScrolling) } }
    /// 0.5 (slow) … 2 (fast); 1 is medium.
    var scrollSpeed: Double { didSet { save("scrollSpeed", scrollSpeed) } }
    /// How long a glide lasts: 0.1 (snappy) … 0.5 (long).
    var scrollGlide: Double { didSet { save("scrollGlide", scrollGlide) } }
    /// Every notch scrolls the same distance (when not smooth).
    var linearScrolling: Bool { didSet { save("linearScrolling", linearScrolling) } }
    var linearLines: Int { didSet { save("linearLines", linearLines) } }
    var reverseMouseVertical: Bool { didSet { save("reverseMouseVertical", reverseMouseVertical) } }
    var reverseMouseHorizontal: Bool { didSet { save("reverseMouseHorizontal", reverseMouseHorizontal) } }
    var sidewaysKey: SidewaysKey { didSet { save("sidewaysKey", sidewaysKey.rawValue) } }

    // Mouse buttons
    /// Button number (3 = back side button, 4 = forward, 5…) → action.
    var buttonActions: [Int: MouseAction] { didSet { saveCodable("buttonActions", buttonActions) } }
    var buttonShortcuts: [Int: KeyShortcut] { didSet { saveCodable("buttonShortcuts", buttonShortcuts) } }
    var middleDragEnabled: Bool { didSet { save("middleDragEnabled", middleDragEnabled) } }
    /// Middle-button drag direction ("left", "right", "up", "down") → action.
    var dragActions: [String: MouseAction] { didSet { saveCodable("dragActions", dragActions) } }

    // Shared by the mouse features: apps where they step aside (the app in front).
    var mouseIgnoredApps: [String] { didSet { save("mouseIgnoredApps", mouseIgnoredApps) } }

    // Worn hardware
    /// A click this soon after the previous one ends is ignored (milliseconds).
    var clickFilterMs: Int { didSet { save("clickFilterMs", clickFilterMs) } }
    /// The same key this soon after it was let go is ignored (milliseconds).
    var keyDebounceMs: Int { didSet { save("keyDebounceMs", keyDebounceMs) } }

    // Super key
    var superKey: SuperKey { didSet { save("superKey", superKey.rawValue) } }
    var superTap: TapAction { didSet { save("superTap", superTap.rawValue) } }
    var superIgnoredApps: [String] { didSet { save("superIgnoredApps", superIgnoredApps) } }

    @ObservationIgnored private let defaults: UserDefaults

    /// Every trigger starts with this; the Snippets page shows it fixed in front of the field.
    static let triggerPrefix = ";"

    static let defaultSnippets = [
        Snippet(trigger: ";date", text: "{date}"),
        Snippet(trigger: ";shrug", text: "¯\\_(ツ)_/¯"),
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: "input.\(key)") as? T ?? fallback }
        func codable<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = defaults.data(forKey: "input.\(key)"), let decoded = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return decoded
        }
        snippets = codable("snippets", Self.defaultSnippets).map { snippet in
            var fixed = snippet
            if !fixed.trigger.hasPrefix(Self.triggerPrefix) { fixed.trigger = Self.triggerPrefix + fixed.trigger }
            return fixed
        }
        snippetMenuShortcut = codable("snippetMenuShortcut",
                                      KeyShortcut(keyCode: UInt16(kVK_Space), modifiers: [.control, .option], key: "Space") as KeyShortcut?)
        smoothScrolling = value("smoothScrolling", true)
        scrollSpeed = value("scrollSpeed", 1.0)
        scrollGlide = value("scrollGlide", 0.25)
        linearScrolling = value("linearScrolling", false)
        linearLines = value("linearLines", 3)
        reverseMouseVertical = value("reverseMouseVertical", false)
        reverseMouseHorizontal = value("reverseMouseHorizontal", false)
        sidewaysKey = SidewaysKey(rawValue: value("sidewaysKey", "")) ?? .shift
        buttonActions = codable("buttonActions", [3: MouseAction.back, 4: .forward])
        buttonShortcuts = codable("buttonShortcuts", [Int: KeyShortcut]())
        middleDragEnabled = value("middleDragEnabled", true)
        dragActions = codable("dragActions", ["left": MouseAction.spaceLeft, "right": .spaceRight, "up": .missionControl, "down": .appExpose])
        mouseIgnoredApps = value("mouseIgnoredApps", [String]())
        clickFilterMs = value("clickFilterMs", 60)
        keyDebounceMs = value("keyDebounceMs", 40)
        superKey = SuperKey(rawValue: value("superKey", "")) ?? .capsLock
        superTap = TapAction(rawValue: value("superTap", "")) ?? .escape
        superIgnoredApps = value("superIgnoredApps", [String]())
    }

    /// Whether the app in front is one the mouse features leave alone.
    var frontAppIgnoresMouse: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(mouseIgnoredApps.contains) ?? false
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: "input.\(key)") }

    private func saveCodable<T: Encodable>(_ key: String, _ value: T) {
        defaults.set(try? JSONEncoder().encode(value), forKey: "input.\(key)")
    }
}
