import Foundation

/// macOS's own app and window switching shortcuts (⌘Tab, ⇧⌘Tab, ⌘`, ⇧⌘`), switched off while
/// Zephydian's switcher takes them over. The ids come from the window server's table of system
/// shortcuts (the same one `com.apple.symbolichotkeys` lists). Switching one off lasts only for
/// the login session, and Zephydian notes what it switched off so the next launch can put it back
/// if it ever stops without doing so.
enum SystemShortcuts {
    enum Kind: Int32, CaseIterable {
        case appSwitcher = 1
        case appSwitcherBack = 2
        case nextWindow = 27
        case previousWindow = 220
    }

    private static let savedKey = "switcher.disabledSystemShortcuts"

    private typealias IsEnabled = @convention(c) (Int32) -> Bool
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private static let handle: UnsafeMutableRawPointer? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        return dlopen(nil, RTLD_NOW)
    }()
    private static let isEnabled: IsEnabled? = handle.flatMap { dlsym($0, "CGSIsSymbolicHotKeyEnabled") }.map { unsafeBitCast($0, to: IsEnabled.self) }
    private static let setEnabled: SetEnabled? = handle.flatMap { dlsym($0, "CGSSetSymbolicHotKeyEnabled") }.map { unsafeBitCast($0, to: SetEnabled.self) }

    /// Whether these can be switched off on this macOS.
    static var isAvailable: Bool { isEnabled != nil && setEnabled != nil }

    /// Switches off exactly `kinds` (and puts back any others Zephydian had switched off).
    static func disable(_ kinds: Set<Kind>) {
        guard let isEnabled, let setEnabled else { return }
        var off = Set(saved)
        for kind in Kind.allCases {
            if kinds.contains(kind) {
                if isEnabled(kind.rawValue) {
                    _ = setEnabled(kind.rawValue, false)
                    off.insert(kind)
                }
            } else if off.contains(kind) {
                _ = setEnabled(kind.rawValue, true)
                off.remove(kind)
            }
        }
        saved = off
    }

    /// Puts back everything Zephydian switched off (the switcher stopped, the app quits, or at
    /// launch after Zephydian stopped unexpectedly).
    static func restore() {
        guard let setEnabled else { return }
        for kind in saved { _ = setEnabled(kind.rawValue, true) }
        saved = []
    }

    private static var saved: Set<Kind> {
        get { Set((UserDefaults.standard.array(forKey: savedKey) as? [Int] ?? []).compactMap { Kind(rawValue: Int32($0)) }) }
        set {
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: savedKey) }
            else { UserDefaults.standard.set(newValue.map { Int($0.rawValue) }, forKey: savedKey) }
        }
    }
}
