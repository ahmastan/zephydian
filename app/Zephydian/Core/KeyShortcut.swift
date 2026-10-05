import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut the person recorded: a key plus modifiers, like ⌥⇧4.
nonisolated struct KeyShortcut: Codable, Hashable {
    var keyCode: UInt16
    /// ⌘ ⌥ ⌃ ⇧ as `NSEvent.ModifierFlags` bits.
    var modifiers: UInt
    /// The key as shown ("4", "V", "Space", "F5"), taken from the keyboard layout when recorded.
    var key: String

    static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }

    /// "⌃⌥⇧⌘4", in Apple's order.
    var label: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    var carbonModifiers: UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevant).rawValue
        self.key = key
    }

    static let functionKeys: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12", UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]

    static let namedKeys: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓", UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘", UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
    ]

    /// A shortcut from a key press, or nil if it can't be one: it needs ⌘, ⌥ or ⌃ (⇧ alone would
    /// swallow capital letters), except for function keys, which work on their own.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.relevant)
        let code = event.keyCode
        let isFunction = Self.functionKeys[code] != nil
        guard isFunction || !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        guard ![UInt16(kVK_Escape), UInt16(kVK_Command), UInt16(kVK_Shift), UInt16(kVK_Option), UInt16(kVK_Control),
                UInt16(kVK_RightCommand), UInt16(kVK_RightShift), UInt16(kVK_RightOption), UInt16(kVK_RightControl),
                UInt16(kVK_CapsLock), UInt16(kVK_Function)].contains(code) else { return nil }
        let name = Self.functionKeys[code] ?? Self.namedKeys[code]
            ?? event.charactersIgnoringModifiers.map { $0.uppercased() }.flatMap { $0.isEmpty ? nil : $0 }
        guard let name else { return nil }
        self.init(keyCode: code, modifiers: flags, key: name)
    }
}

// MARK: - Is it taken?

/// Checks a shortcut against what already uses it on this Mac, for the warning shown under a
/// shortcut field: macOS's own shortcuts (from its settings, where they can be changed or turned
/// off), shortcuts most apps use in their menus, and Zephydian's other shortcuts. Another app's
/// global shortcut is only found when registering fails, so that case is reported separately.
enum ShortcutConflicts {
    struct SystemShortcut {
        let id: Int?          // its number in macOS's keyboard settings, when it has one
        let shortcut: KeyShortcut
        let name: String
    }

    private static func s(_ code: Int, _ flags: NSEvent.ModifierFlags, _ key: String) -> KeyShortcut {
        KeyShortcut(keyCode: UInt16(code), modifiers: flags, key: key)
    }

    /// macOS's standard shortcuts. The ones with an id can be changed in System Settings, so the
    /// person's own settings (read below) take their place.
    static let system: [SystemShortcut] = [
        .init(id: 64, shortcut: s(kVK_Space, .command, "Space"), name: "Spotlight"),
        .init(id: 65, shortcut: s(kVK_Space, [.command, .option], "Space"), name: "Finder search"),
        .init(id: 28, shortcut: s(kVK_ANSI_3, [.command, .shift], "3"), name: "the screenshot of the screen"),
        .init(id: 29, shortcut: s(kVK_ANSI_3, [.command, .shift, .control], "3"), name: "copying a screenshot of the screen"),
        .init(id: 30, shortcut: s(kVK_ANSI_4, [.command, .shift], "4"), name: "the screenshot of an area"),
        .init(id: 31, shortcut: s(kVK_ANSI_4, [.command, .shift, .control], "4"), name: "copying a screenshot of an area"),
        .init(id: 184, shortcut: s(kVK_ANSI_5, [.command, .shift], "5"), name: "Screenshot options"),
        .init(id: 60, shortcut: s(kVK_Space, .control, "Space"), name: "switching input sources"),
        .init(id: 61, shortcut: s(kVK_Space, [.control, .option], "Space"), name: "switching input sources"),
        .init(id: 32, shortcut: s(kVK_UpArrow, .control, "↑"), name: "Mission Control"),
        .init(id: 33, shortcut: s(kVK_DownArrow, .control, "↓"), name: "App Exposé"),
        .init(id: 79, shortcut: s(kVK_LeftArrow, .control, "←"), name: "moving to the space on the left"),
        .init(id: 81, shortcut: s(kVK_RightArrow, .control, "→"), name: "moving to the space on the right"),
        .init(id: 52, shortcut: s(kVK_ANSI_D, [.command, .option], "D"), name: "hiding the Dock"),
        .init(id: nil, shortcut: s(kVK_Tab, .command, "⇥"), name: "switching apps"),
        .init(id: nil, shortcut: s(kVK_ANSI_Q, [.command, .control], "Q"), name: "locking the screen"),
        .init(id: nil, shortcut: s(kVK_Escape, [.command, .option], "⎋"), name: "Force Quit"),
        .init(id: nil, shortcut: s(kVK_Space, [.command, .control], "Space"), name: "Emoji & Symbols"),
        .init(id: nil, shortcut: s(kVK_ANSI_F, [.command, .control], "F"), name: "full screen in most apps"),
        .init(id: nil, shortcut: s(kVK_ANSI_H, [.command, .option], "H"), name: "hiding other apps"),
    ]

    /// The shortcuts in the person's macOS keyboard settings: id → (shortcut, enabled).
    static func userSystemShortcuts() -> [Int: (KeyShortcut, Bool)] {
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] else { return [:] }
        var out: [Int: (KeyShortcut, Bool)] = [:]
        for (key, value) in all {
            guard let id = Int(key), let entry = value as? [String: Any] else { continue }
            let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1)
            guard let v = entry["value"] as? [String: Any], let p = v["parameters"] as? [Int], p.count == 3, p[1] != 65535 else {
                out[id] = (KeyShortcut(keyCode: 0, modifiers: [], key: ""), false)
                continue
            }
            out[id] = (KeyShortcut(keyCode: UInt16(p[1]), modifiers: NSEvent.ModifierFlags(rawValue: UInt(p[2])), key: ""), enabled)
        }
        return out
    }

    /// A warning for this shortcut, or nil if nothing known uses it. `others` are Zephydian's other
    /// shortcuts (name → shortcut), not counting the one being set.
    static func check(_ shortcut: KeyShortcut, others: [String: KeyShortcut], userSystem: [Int: (KeyShortcut, Bool)] = userSystemShortcuts()) -> String? {
        func same(_ a: KeyShortcut, _ b: KeyShortcut) -> Bool { a.keyCode == b.keyCode && a.flags == b.flags }
        for (name, other) in others.sorted(by: { $0.key < $1.key }) where same(other, shortcut) {
            return "\(name) in Zephydian already uses \(shortcut.label). Pick another."
        }
        for item in system {
            let current = item.id.flatMap { userSystem[$0] }
            let active = current.map { $0.1 && same($0.0, shortcut) } ?? same(item.shortcut, shortcut)
            if active { return "macOS uses \(shortcut.label) for \(item.name). Pick another, or change it in System Settings → Keyboard → Keyboard Shortcuts." }
        }
        // Customised or extra macOS shortcuts we don't have a name for.
        for (id, value) in userSystem where value.1 && same(value.0, shortcut) && !system.contains(where: { $0.id == id }) {
            return "macOS already uses \(shortcut.label) for one of its keyboard shortcuts. Pick another, or change it in System Settings → Keyboard → Keyboard Shortcuts."
        }
        // ⌘ or ⇧⌘ with a letter, or ⌘ with a digit or sign: most apps have a menu item on it.
        let isLetter = shortcut.key.count == 1 && shortcut.key.first!.isLetter
        if shortcut.key.count == 1, shortcut.flags == .command || (isLetter && shortcut.flags == [.command, .shift]) {
            return "Most apps use \(shortcut.label) in their menus, so it would stop working there. Add ⌥ or ⌃ to it."
        }
        return nil
    }
}
