import AppKit
import SwiftUI

// MARK: - Items

/// What a slice does. Raw values are saved; never rename them.
enum RadialItemKind: String, Codable, CaseIterable {
    case app, file, url, utility, feature, quickToggle, windowLayout, media, keys, shortcut, nowPlaying, snippet, folder
}

/// One slice of a wheel. `payload` says what it points at: an app or file path, a link, a utility's
/// id, a feature or toggle name, a key combination. A folder keeps its slices in `children`.
struct RadialItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: RadialItemKind
    /// Shown in the center; empty means the item's own name.
    var name = ""
    /// An SF Symbol chosen for it; empty means its own icon.
    var symbol = ""
    var payload = ""
    var children: [RadialItem] = []

    init(id: UUID = UUID(), kind: RadialItemKind, name: String = "", symbol: String = "", payload: String = "", children: [RadialItem] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.symbol = symbol
        self.payload = payload
        self.children = children
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, symbol, payload, children }

    /// Missing fields get their defaults, and a slice of an unknown kind (from a newer version) is
    /// dropped on its own instead of losing the whole wheel.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(RadialItemKind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        payload = try c.decodeIfPresent(String.self, forKey: .payload) ?? ""
        children = (try c.decodeIfPresent([Lossy<RadialItem>].self, forKey: .children) ?? []).compactMap(\.value)
    }

    /// A file or app path with `~` expanded.
    var path: String { (payload as NSString).expandingTildeInPath }
}

/// Decodes what it can and keeps nil for the rest.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Zephydian's own actions a slice can run. Raw values are saved.
enum RadialFeatureAction: String, CaseIterable {
    case panel, capture, shelf, cameraMirror, commandBar, quickPanel, cleaningMode

    var title: String {
        switch self {
        case .panel: "Zephydian Panel"
        case .capture: "Capture"
        case .shelf: "Shelf"
        case .cameraMirror: "Camera Mirror"
        case .commandBar: "Command Bar"
        case .quickPanel: "Quick Panel"
        case .cleaningMode: "Cleaning Mode"
        }
    }

    var symbol: String {
        switch self {
        case .panel: "rectangle.inset.topright.filled"
        case .capture: "camera.viewfinder"
        case .shelf: "tray.and.arrow.down"
        case .cameraMirror: "web.camera"
        case .commandBar: "command"
        case .quickPanel: "square.grid.3x3"
        case .cleaningMode: "sparkles"
        }
    }

    /// The feature that must be on for it to work (nil: always works).
    var featureID: String? {
        switch self {
        case .panel, .capture: nil
        case .shelf: "shelf"
        case .cameraMirror: "camera-mirror"
        case .commandBar: "command-bar"
        case .quickPanel: "quick-panel"
        case .cleaningMode: "cleaning-mode"
        }
    }
}

/// The media keys a slice can press. Raw values are saved.
enum RadialMediaKey: String, CaseIterable {
    case playPause, nextTrack, previousTrack

    var title: String {
        switch self {
        case .playPause: "Play/Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        }
    }

    var symbol: String {
        switch self {
        case .playPause: "playpause.fill"
        case .nextTrack: "forward.fill"
        case .previousTrack: "backward.fill"
        }
    }

    /// The code the keyboard's own media key sends (NX_KEYTYPE_PLAY, FAST, REWIND).
    var auxKey: Int {
        switch self {
        case .playPause: 16
        case .nextTrack: 19
        case .previousTrack: 20
        }
    }
}

// MARK: - Wheels

/// A wheel's color: its highlight and the lit slice. `accent` follows Zephydian's accent.
enum RadialColor: String, Codable, CaseIterable, Identifiable {
    case accent, blue, purple, pink, red, orange, yellow, green, mint, cyan, indigo, graphite
    var id: String { rawValue }
    var title: String { self == .accent ? "Accent" : rawValue.capitalized }

    func color(accent: Color) -> Color {
        switch self {
        case .accent: accent
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .cyan: .cyan
        case .indigo: .indigo
        case .graphite: .gray
        }
    }
}

/// One wheel: its slices, its color, and what opens it.
struct RadialWheel: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "General"
    var color = RadialColor.accent
    var shortcut: KeyShortcut?
    /// The Core Graphics button number (2 middle, 3 and 4 the side buttons, 5 and up extra ones), or nil.
    var mouseButton: Int?
    var items: [RadialItem] = []

    init(id: UUID = UUID(), name: String = "General", color: RadialColor = .accent, shortcut: KeyShortcut? = nil,
         mouseButton: Int? = nil, items: [RadialItem] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.shortcut = shortcut
        self.mouseButton = mouseButton
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case id, name, color, shortcut, mouseButton, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "General"
        color = (try? c.decodeIfPresent(RadialColor.self, forKey: .color)) ?? .accent
        shortcut = try? c.decodeIfPresent(KeyShortcut.self, forKey: .shortcut)
        mouseButton = try? c.decodeIfPresent(Int.self, forKey: .mouseButton)
        items = (try c.decodeIfPresent([Lossy<RadialItem>].self, forKey: .items) ?? []).compactMap(\.value)
    }

    /// The wheel people get first: everyday apps and folders, the panel, Capture and Dark Mode.
    static func general() -> RadialWheel {
        RadialWheel(items: [
            RadialItem(kind: .app, payload: "/System/Library/CoreServices/Finder.app"),
            RadialItem(kind: .app, payload: "/Applications/Safari.app"),
            RadialItem(kind: .feature, payload: RadialFeatureAction.capture.rawValue),
            RadialItem(kind: .quickToggle, payload: QuickToggle.darkMode.rawValue),
            RadialItem(kind: .app, payload: "/System/Applications/System Settings.app"),
            RadialItem(kind: .folder, name: "Folders", symbol: "folder", children: [
                RadialItem(kind: .file, payload: "~/Desktop"),
                RadialItem(kind: .file, payload: "~/Documents"),
                RadialItem(kind: .file, payload: "~/Downloads"),
                RadialItem(kind: .file, payload: "/Applications"),
            ]),
            RadialItem(kind: .file, payload: "~/Downloads"),
            RadialItem(kind: .feature, payload: RadialFeatureAction.panel.rawValue),
        ])
    }
}

/// The ready-made sets a new wheel can start from (then edited freely).
enum RadialStarter: String, CaseIterable, Identifiable {
    case general, media, tools, windowLayout, quickToggles, blank

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .media: "Media"
        case .tools: "Tools"
        case .windowLayout: "Window Layout"
        case .quickToggles: "Quick Toggles"
        case .blank: "Blank"
        }
    }

    var color: RadialColor {
        switch self {
        case .general: .accent
        case .media: .purple
        case .tools: .cyan
        case .windowLayout: .orange
        case .quickToggles: .mint
        case .blank: .graphite
        }
    }

    func makeWheel() -> RadialWheel {
        var wheel = self == .general ? RadialWheel.general() : RadialWheel(items: items)
        wheel.name = title
        wheel.color = color
        return wheel
    }

    private var items: [RadialItem] {
        switch self {
        case .general, .blank:
            return []
        case .media:
            return [RadialItem(kind: .media, payload: RadialMediaKey.playPause.rawValue),
                    RadialItem(kind: .media, payload: RadialMediaKey.nextTrack.rawValue),
                    RadialItem(kind: .nowPlaying),
                    RadialItem(kind: .media, payload: RadialMediaKey.previousTrack.rawValue)]
        case .tools:
            return [RadialFeatureAction.capture, .commandBar, .quickPanel, .shelf, .cameraMirror, .cleaningMode]
                .map { RadialItem(kind: .feature, payload: $0.rawValue) }
        case .windowLayout:
            // Each slice sits where its layout puts the window: up is the top half, and so on round.
            return [WindowLayout.topHalf, .topRight, .rightHalf, .bottomRight, .bottomHalf, .bottomLeft, .leftHalf, .topLeft]
                .map { RadialItem(kind: .windowLayout, payload: $0.rawValue) }
        case .quickToggles:
            return [QuickToggle.darkMode, .desktopIcons, .hiddenFiles, .lockScreen, .emptyTrash, .micMute]
                .map { RadialItem(kind: .quickToggle, payload: $0.rawValue) }
        }
    }
}

// MARK: - Settings

/// How the shortcut or mouse button behaves. Raw values are saved.
enum RadialMode: String, CaseIterable, Identifiable {
    /// Hold, point and release to run; release at the center (or a quick tap) leaves it open for clicking.
    case pressOrHold
    /// Opens and stays open; letting go does nothing.
    case press
    /// Only open while held; letting go over nothing closes it.
    case hold

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pressOrHold: "Press or hold"
        case .press: "Press"
        case .hold: "Hold"
        }
    }
    var explanation: String {
        switch self {
        case .pressOrHold: "Hold the shortcut or button, point at a slice and let go to run it. A quick press (or letting go at the center) keeps the wheel open, so you can click."
        case .press: "The wheel opens and stays open until you pick a slice, press Esc or click outside it."
        case .hold: "The wheel shows only while you hold the shortcut or button. Let go over a slice to run it, anywhere else to close."
        }
    }
}

enum RadialPosition: String, CaseIterable, Identifiable {
    case pointer, center
    var id: String { rawValue }
    var title: String { self == .pointer ? "At the pointer" : "Center of the screen" }
}

enum RadialSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scale: CGFloat {
        switch self {
        case .small: 0.83
        case .medium: 1
        case .large: 1.2
        }
    }
}

/// Every wheel and the options shared by all of them.
@Observable
final class RadialSettings {
    static let shared = RadialSettings()

    static let defaultHighlight = 0.42

    var wheels: [RadialWheel] { didSet { save(wheels, "radial.wheels") } }
    var size: RadialSize { didSet { defaults.set(size.rawValue, forKey: "radial.size") } }
    /// How strong the highlight is at the wheel's edge (it fades toward the center).
    var highlightOpacity: Double { didSet { defaults.set(highlightOpacity, forKey: "radial.highlight") } }
    var mode: RadialMode { didSet { defaults.set(mode.rawValue, forKey: "radial.mode") } }
    var position: RadialPosition { didSet { defaults.set(position.rawValue, forKey: "radial.position") } }
    /// Wheels whose shortcut macOS refused (another app has it).
    var refused: Set<UUID> = []

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: "radial.wheels").flatMap { try? JSONDecoder().decode([Lossy<RadialWheel>].self, from: $0) }
        let wheels = saved?.compactMap(\.value) ?? []
        self.wheels = wheels.isEmpty ? [.general()] : wheels
        size = defaults.string(forKey: "radial.size").flatMap(RadialSize.init(rawValue:)) ?? .medium
        let highlight = defaults.object(forKey: "radial.highlight") as? Double ?? Self.defaultHighlight
        highlightOpacity = min(max(highlight, 0.1), 0.8)
        mode = defaults.string(forKey: "radial.mode").flatMap(RadialMode.init(rawValue:)) ?? .pressOrHold
        position = defaults.string(forKey: "radial.position").flatMap(RadialPosition.init(rawValue:)) ?? .pointer
    }

    /// The wheel a mouse button opens, if any.
    func wheel(forButton button: Int) -> RadialWheel? { wheels.first { $0.mouseButton == button } }

    /// Mouse buttons some wheel uses.
    var claimedButtons: Set<Int> { Set(wheels.compactMap(\.mouseButton)) }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    /// A mouse button's name in menus.
    static func buttonTitle(_ number: Int) -> String {
        switch number {
        case 2: "Middle button"
        case 3: "Back side button (4)"
        case 4: "Forward side button (5)"
        default: "Button \(number + 1)"
        }
    }
}
