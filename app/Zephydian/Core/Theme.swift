import AppKit
import SwiftUI

/// Accent color themes. Each has a light-mode and a dark-mode variant.
nonisolated enum AccentTheme: String, CaseIterable, Identifiable {
    /// Follows System Settings → Appearance → Accent color, live. With macOS's "Multicolor"
    /// (each app uses its own color) it shows Sky, Zephydian's own color.
    case system
    case sky, mint, sunset, grape, rose, graphite

    var id: Self { self }
    var name: String { self == .system ? "System (follows your Mac)" : rawValue.capitalized }

    private var hex: (light: UInt32, dark: UInt32) {
        switch self {
        case .system: (0x1EA1F2, 0x1673D9)    // not used: System is drawn from macOS's accent
        case .sky: (0x1EA1F2, 0x1673D9)       // custom: bright sky blue in light, deeper blue in dark
        case .mint: (0x00C7BE, 0x63E6E2)
        case .sunset: (0xFF9500, 0xFF9F0A)
        case .grape: (0xAF52DE, 0xBF5AF2)
        case .rose: (0xFF2D55, 0xFF375F)
        case .graphite: (0x8E8E93, 0x98989D)
        }
    }

    /// Resolves to the light or dark variant automatically.
    var nsColor: NSColor {
        if self == .system {
            // A new name each time macOS's accent changes, so views see a different color and redraw.
            return NSColor(name: "Zephydian.system.\(SystemAccent.revision)") { appearance in
                if SystemAccent.isMulticolor { return AccentTheme.sky.nsColor }
                var color = NSColor.controlAccentColor
                appearance.performAsCurrentDrawingAppearance {
                    color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
                }
                return color
            }
        }
        let (light, dark) = hex
        return NSColor(name: "Zephydian.\(rawValue)") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// macOS's accent color, for the System accent theme.
nonisolated enum SystemAccent {
    /// Bumped (on the main thread) when macOS's accent color changes.
    nonisolated(unsafe) static var revision = 0

    /// "Multicolor" in System Settings: no accent color is saved.
    static var isMulticolor: Bool { UserDefaults.standard.object(forKey: "AppleAccentColor") == nil }
}

extension SettingsStore {
    /// The accent color in use. Read this (not `accent.color`) so views also redraw when the
    /// accent is System and macOS's accent color changes.
    var accentNSColor: NSColor {
        _ = systemAccentRevision
        return accent.nsColor
    }

    var accentColor: Color { Color(nsColor: accentNSColor) }
}

nonisolated extension Color {
    /// A color with separate light-mode and dark-mode values.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

nonisolated extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension AppearanceMode {
    /// `nil` follows the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension MenuBarIcon {
    /// Template image for the menu bar (macOS tints it to match the menu bar).
    var menuBarImage: NSImage? {
        let image: NSImage?
        if let symbolName {
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Zephydian")?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        } else {
            image = (NSImage(named: "MenuBarIcon")?.copy() as? NSImage).map {
                // The app's copy of the logo SVG is cropped tight to the jet, so it fills the standard size.
                $0.size = NSSize(width: 18, height: 18)
                return $0
            }
        }
        image?.isTemplate = true
        return image
    }

    /// The same icon for use inside SwiftUI views.
    @ViewBuilder var swiftUIImage: some View {
        if let symbolName {
            Image(systemName: symbolName)
        } else {
            Image("MenuBarIcon").renderingMode(.template).resizable().scaledToFit()
        }
    }
}

/// Shared design tokens.
enum Tokens {
    /// The Medium panel, which every screen was designed at. Game boards scale from it (`boardScale`).
    static let basePanelSize = PanelSize.medium.size
    /// A game screen's header (44) and hint line (30), which don't scale.
    static let gameChromeHeight: CGFloat = 74
    static let cardRadius: CGFloat = 12
    static let edgeInset: CGFloat = 8
    static let fill = Color(nsColor: .quaternarySystemFill)
    static let fillHover = Color(nsColor: .tertiarySystemFill)
    /// Round header buttons (back, pause, add). Fits the 44 pt header rows.
    static let iconButtonSize: CGFloat = 28
    /// Glass cards floating over a game (pause, win, lose).
    static let overlayRadius: CGFloat = 18
}

private struct BoardScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// How much bigger (or smaller) game boards are drawn than at the Medium panel size.
    /// Follows the panel's real size, so it also shrinks when a short screen makes the panel shorter.
    var boardScale: CGFloat {
        get { self[BoardScaleKey.self] }
        set { self[BoardScaleKey.self] = newValue }
    }
}
