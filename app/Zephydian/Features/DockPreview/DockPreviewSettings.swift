import Foundation

/// Dock Preview's settings, saved as they change. Defaults are 19-D12's "Quick" choice.
@Observable
final class DockPreviewSettings {
    static let shared = DockPreviewSettings()

    enum PreviewSize: String, CaseIterable, Identifiable {
        case small, normal, large, extraLarge
        var id: String { rawValue }
        var title: String {
            switch self {
            case .small: "Small"
            case .normal: "Normal"
            case .large: "Large"
            case .extraLarge: "Extra large"
            }
        }
        /// The width of one window card, in points.
        var cardWidth: CGFloat {
            switch self {
            case .small: 150
            case .normal: 200
            case .large: 250
            case .extraLarge: 310
            }
        }
    }

    enum Order: String, CaseIterable, Identifiable {
        case recent, creation
        var id: String { rawValue }
        var title: String { self == .recent ? "Most recently used first" : "Oldest first" }
    }

    /// What clicking the Dock icon of the app you're already in does.
    enum DockClick: String, CaseIterable, Identifiable {
        case nothing, minimize, hide, cycle
        var id: String { rawValue }
        var title: String {
            switch self {
            case .nothing: "Nothing (as macOS does)"
            case .minimize: "Minimize its windows"
            case .hide: "Hide the app"
            case .cycle: "Show its next window"
            }
        }
    }

    var currentSpaceOnly: Bool { didSet { save("currentSpaceOnly", currentSpaceOnly) } }
    /// Milliseconds the pointer rests on an icon before the preview opens.
    var openDelay: Int { didSet { save("openDelay", openDelay) } }
    var size: PreviewSize { didSet { save("size", size.rawValue) } }
    /// No titles or buttons on the cards, just the pictures.
    var minimal: Bool { didSet { save("minimal", minimal) } }
    var order: Order { didSet { save("order", order.rawValue) } }
    var peek: Bool { didSet { save("peek", peek) } }
    var dragToMove: Bool { didSet { save("dragToMove", dragToMove) } }
    /// × quits the whole app instead of closing one window.
    var closeQuitsApp: Bool { didSet { save("closeQuitsApp", closeQuitsApp) } }
    /// While a preview is open, an auto-hiding Dock stays up (experimental).
    var keepDockVisible: Bool { didSet { save("keepDockVisible", keepDockVisible) } }
    var dockClick: DockClick { didSet { save("dockClick", dockClick.rawValue) } }
    /// Bundle IDs of apps that never get a preview.
    var excludedApps: [String] { didSet { save("excludedApps", excludedApps) } }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: "dockPreview.\(key)") as? T ?? fallback }
        currentSpaceOnly = value("currentSpaceOnly", false)
        openDelay = value("openDelay", 300)
        size = PreviewSize(rawValue: value("size", "")) ?? .normal
        minimal = value("minimal", false)
        order = Order(rawValue: value("order", "")) ?? .recent
        peek = value("peek", true)
        dragToMove = value("dragToMove", true)
        closeQuitsApp = value("closeQuitsApp", false)
        keepDockVisible = value("keepDockVisible", false)
        dockClick = DockClick(rawValue: value("dockClick", "")) ?? .nothing
        excludedApps = value("excludedApps", [String]())
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: "dockPreview.\(key)")
    }
}
