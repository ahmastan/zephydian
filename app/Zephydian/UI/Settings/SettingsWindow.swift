import SwiftUI

/// A page of the Settings window, as the sidebar lists it.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, panel, shortcuts
    case notes, games, packs
    case features, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .panel: "Panel & Corner"
        case .shortcuts: "Shortcuts"
        case .notes: "Notes"
        case .games: "Games"
        case .packs: "Packs"
        case .features: "Features"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.fill"
        case .panel: "rectangle.inset.topleft.filled"
        case .shortcuts: "keyboard.fill"
        case .notes: "note.text"
        case .games: "gamecontroller.fill"
        case .packs: "shippingbox.fill"
        case .features: "switch.2"
        case .permissions: "hand.raised.fill"
        }
    }

    /// The options on the page, so a search finds the page by what's inside it.
    var keywords: [String] {
        switch self {
        case .general: ["Launch at login", "Welcome tour", "Version", "Quit", "GitHub", "Website", "About"]
        case .appearance: ["Mode", "Light", "Dark", "Panel style", "Liquid Glass", "Frosted", "Accent", "Color", "Menu bar icon"]
        case .panel: ["Corner", "Hot Corners", "Delay", "Display", "Panel size", "Small", "Medium", "Large", "Auto-hide", "Hide delay", "Tabs", "Order", "Hide tabs"]
        case .shortcuts: ["Keyboard shortcut", "Open the panel", "Hotkey", "Clipboard", "Screenshot", "Dictionary"]
        case .notes: ["Monospace font", "Notes window", "On top"]
        case .games: ["High-contrast colors", "Five", "Stats", "Library"]
        case .packs: ["Updates", "Check now", "Running now", "Stop", "Library", "Utilities"]
        case .features: ["Presets", "Essentials", "Everything", "Turn on", "Turn off"]
        case .permissions: ["Accessibility", "Screen Recording", "Repair", "Privacy"]
        }
    }

    /// The sidebar's groups, in order. Feature groups and utilities join them in later stages.
    static let groups: [[SettingsPage]] = [
        [.general, .appearance, .panel, .shortcuts],
        [.notes, .games, .packs],
        [.features, .permissions],
    ]
}

/// What the Settings window shows: one of its pages, or a switched-on feature's page.
enum SettingsSelection: Hashable {
    case page(SettingsPage)
    case feature(String)
    /// An installed utility's settings (SDK 5), by pack id.
    case utility(String)

    /// "permissions", "feature:dock-preview" or "utility:clipboard".
    init?(rawValue: String) {
        if rawValue.hasPrefix("feature:") {
            self = .feature(String(rawValue.dropFirst("feature:".count)))
        } else if rawValue.hasPrefix("utility:") {
            self = .utility(String(rawValue.dropFirst("utility:".count)))
        } else if let page = SettingsPage(rawValue: rawValue) {
            self = .page(page)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .page(let page): page.rawValue
        case .feature(let id): "feature:\(id)"
        case .utility(let id): "utility:\(id)"
        }
    }
}

/// Opens, reuses and closes the Settings window. While it's open Zephydian is in the Dock.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let model: AppModel
    private let notes: NotesStore
    private var window: NSWindow?

    private static let frameName = "ZephydianSettings"

    init(settings: SettingsStore, model: AppModel, notes: NotesStore) {
        self.settings = settings
        self.model = model
        self.notes = notes
    }

    var isOpen: Bool { window != nil }

    /// Shows the window (on `selection` if given) and brings it forward.
    func show(_ selection: SettingsSelection? = nil) {
        if let selection { model.settingsSelection = selection }
        model.closePanel()
        let window = window ?? makeWindow()
        self.window = window
        window.appearance = settings.appearance.nsAppearance
        DockPresence.add("settings")
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Light/Dark follows the app's Mode setting.
    func applyAppearance() {
        window?.appearance = settings.appearance.nsAppearance
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsWindowView()
            .environment(settings).environment(model).environment(notes)
            .environment(PackLibrary.shared).environment(PackManager.shared).environment(PackServices.shared)
        let hosting = NSHostingController(rootView: root)
        // The page title and the sidebar button go into the window's toolbar, like System Settings.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 715, height: 560))
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.remove("settings")
        // Let the window finish closing before its views go away; nothing stays in memory.
        Task { @MainActor [weak self] in
            self?.window?.contentViewController = nil
            self?.window = nil
        }
    }
}

/// The sidebar (search, app card, pages, switched-on features) and the selected page.
struct SettingsWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(PackLibrary.self) private var library
    @State private var query = ""

    var body: some View {
        let features = Features.shared
        NavigationSplitView {
            List(selection: Binding(get: { Optional(model.settingsSelection) }, set: { if let s = $0 { model.settingsSelection = s } })) {
                if query.isEmpty {
                    Section { AppCard { model.settingsSelection = .page(.general) } }
                }
                ForEach(Array(pageGroups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group, id: \.self) { page in
                            SidebarRow(title: page.title, symbol: page.symbol, match: match(for: page))
                                .tag(SettingsSelection.page(page))
                        }
                    }
                }
                ForEach(featureGroups, id: \.group) { entry in
                    Section(entry.group.title) {
                        ForEach(entry.features) { feature in
                            SidebarRow(title: feature.name, symbol: feature.symbol, match: nil)
                                .tag(SettingsSelection.feature(feature.id))
                        }
                    }
                }
                if !utilities.isEmpty {
                    Section("Utilities") {
                        ForEach(utilities, id: \.id) { pack in
                            SidebarRow(title: pack.manifest.name, symbol: pack.manifest.symbol ?? "wrench.and.screwdriver.fill", match: nil)
                                .tag(SettingsSelection.utility(pack.id))
                        }
                    }
                }
                if pageGroups.isEmpty && featureGroups.isEmpty && utilities.isEmpty {
                    Text("No results").foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            detail
        }
        .frame(minWidth: 640, minHeight: 440)
        // A feature switched off leaves the sidebar; its page goes back to Features.
        .onChange(of: features.enabled) {
            if case .feature(let id) = model.settingsSelection, !features.isOn(id) {
                model.settingsSelection = .page(.features)
            }
        }
        // A removed utility's page goes back to Packs.
        .onChange(of: library.packs.map(\.id)) {
            if case .utility(let id) = model.settingsSelection, !library.packs.contains(where: { $0.id == id && $0.hasSettings }) {
                model.settingsSelection = .page(.packs)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.settingsSelection {
        case .page(let page):
            SettingsPageView(page: page).navigationTitle(page.title)
        case .feature(let id):
            if let feature = Features.shared.feature(id) {
                FeaturePage(feature: feature).navigationTitle(feature.name)
            } else {
                SettingsPageView(page: .features).navigationTitle(SettingsPage.features.title)
            }
        case .utility(let id):
            if let pack = library.packs.first(where: { $0.id == id && $0.hasSettings }) {
                UtilitySettingsPage(bundle: pack).id(pack.id).navigationTitle(pack.manifest.name)
            } else {
                SettingsPageView(page: .packs).navigationTitle(SettingsPage.packs.title)
            }
        }
    }

    /// Installed utilities with a settings page, matching the search.
    private var utilities: [PackBundle] {
        library.packs.filter { pack in
            pack.hasSettings && (query.isEmpty || pack.manifest.name.localizedCaseInsensitiveContains(query))
        }
    }

    /// The groups with only the pages matching the search (all of them with no search).
    private var pageGroups: [[SettingsPage]] {
        guard !query.isEmpty else { return SettingsPage.groups }
        return SettingsPage.groups.map { $0.filter { page in
            page.title.localizedCaseInsensitiveContains(query) || match(for: page) != nil
        } }.filter { !$0.isEmpty }
    }

    /// The switched-on features, by group, matching the search.
    private var featureGroups: [(group: FeatureGroup, features: [Feature])] {
        let features = Features.shared
        return FeatureGroup.allCases.compactMap { group in
            let list = features.all.filter { feature in
                feature.group == group && features.isOn(feature.id)
                    && (query.isEmpty || feature.name.localizedCaseInsensitiveContains(query)
                        || feature.summary.localizedCaseInsensitiveContains(query))
            }
            return list.isEmpty ? nil : (group, list)
        }
    }

    /// The option a search found on a page (shown under its name), unless its name matched.
    private func match(for page: SettingsPage) -> String? {
        guard !query.isEmpty, !page.title.localizedCaseInsensitiveContains(query) else { return nil }
        return page.keywords.first { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// A sidebar row: the symbol on a rounded square in the accent color, then its name.
private struct SidebarRow: View {
    let title: String
    let symbol: String
    let match: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let match {
                    Text(match).font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            SettingsIcon(symbol: symbol)
        }
    }
}

/// White symbol on a small rounded square in the accent color, like System Settings' icons.
struct SettingsIcon: View {
    let symbol: String
    var size: CGFloat = 20
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(settings.accentColor.gradient)
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// The app's icon, name and version at the top of the sidebar. Opens General.
private struct AppCard: View {
    let action: () -> Void
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Zephydian").font(.headline)
                    Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zephydian, version \(version)")
        .accessibilityHint("Opens General")
    }
}
