import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One tile on the Quick Panel.
struct QuickTile: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// Switches stay open after a click (so you can flip several); actions close the panel.
    var toggle: QuickToggle?
    let run: () -> Void
}

@Observable
final class QuickPanelSettings {
    static let shared = QuickPanelSettings()

    /// The tiles people see first, before they edit the panel.
    static let starters = ["toggle.darkMode", "toggle.ejectDisks", "toggle.lockScreen", "utility.awake",
                           "action.capture", "action.shelf", "action.mirror", "action.cleaning",
                           "utility.calculator", "utility.clipboard", "toggle.micMute", "toggle.emptyTrash"]

    var shortcut: KeyShortcut? { didSet { save(shortcut, "quickPanel.shortcut") } }
    /// Tile order; tiles not listed yet go at the end.
    var order: [String] { didSet { save(order, "quickPanel.order") } }
    /// Tiles shown (everything else is hidden until switched on in Edit).
    var shown: Set<String> { didSet { save(shown, "quickPanel.shown") } }
    var registered = true

    private let defaults = UserDefaults.standard

    init() {
        shortcut = defaults.data(forKey: "quickPanel.shortcut").flatMap { try? JSONDecoder().decode(KeyShortcut?.self, from: $0) } ?? nil
        order = defaults.data(forKey: "quickPanel.order").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? Self.starters
        shown = defaults.data(forKey: "quickPanel.shown").flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? Set(Self.starters)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/// The tiles that exist right now: quick toggles (while that feature is on), Zephydian's actions
/// (for the features that are on and the capture utility) and every installed utility.
enum QuickTiles {
    static func available() -> [QuickTile] {
        var out: [QuickTile] = []
        let features = Features.shared
        if features.isOn("quick-toggles") {
            for toggle in QuickToggle.allCases where QuickToggles.shared.isAvailable(toggle) {
                out.append(QuickTile(id: "toggle.\(toggle.rawValue)", title: toggle.title, symbol: toggle.symbol,
                                     toggle: toggle.isSwitch ? toggle : nil, run: { QuickToggles.shared.run(toggle) }))
            }
        }
        if let capture = PackLibrary.shared.packs.first(where: { ($0.manifest.capabilities ?? []).contains("screen.capture") }) {
            let id = capture.id
            out.append(QuickTile(id: "action.capture", title: "Capture", symbol: "camera.viewfinder",
                                 run: { PackServices.shared.capture.openBar(packID: id) }))
        }
        if features.isOn("shelf") {
            out.append(QuickTile(id: "action.shelf", title: "Shelf", symbol: "tray.and.arrow.down", run: { ShelfEngine.current?.toggle() }))
        }
        if features.isOn("camera-mirror") {
            out.append(QuickTile(id: "action.mirror", title: "Camera Mirror", symbol: "web.camera", run: { CameraMirrorEngine.current?.toggle() }))
        }
        if features.isOn("cleaning-mode") {
            out.append(QuickTile(id: "action.cleaning", title: "Cleaning Mode", symbol: "sparkles", run: { CleaningMode.shared.start() }))
        }
        if features.isOn("command-bar") {
            out.append(QuickTile(id: "action.commandBar", title: "Command Bar", symbol: "command", run: { CommandBarEngine.current?.open() }))
        }
        for bundle in PackLibrary.shared.packs where bundle.kind == .utility {
            let id = bundle.id
            out.append(QuickTile(id: "utility.\(id)", title: bundle.manifest.name, symbol: bundle.manifest.symbol ?? "square.grid.2x2",
                                 run: { CommandBarHooks.openUtility(id) }))
        }
        return out
    }

    /// In the saved order, new ones at the end.
    static func ordered(_ tiles: [QuickTile], order: [String]) -> [QuickTile] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return tiles.enumerated().sorted { a, b in
            (rank[a.element.id] ?? order.count + a.offset) < (rank[b.element.id] ?? order.count + b.offset)
        }.map(\.element)
    }
}

@Observable
final class QuickPanelModel {
    var tiles: [QuickTile] = []
    var editing = false
    var selection = 0
    @ObservationIgnored var close: () -> Void = {}

    private var settings: QuickPanelSettings { .shared }

    /// What's on the panel now: every tile while editing, otherwise the shown ones.
    var visible: [QuickTile] { editing ? tiles : tiles.filter { settings.shown.contains($0.id) } }

    func reload() {
        QuickToggles.shared.refresh()
        tiles = QuickTiles.ordered(QuickTiles.available(), order: settings.order)
        selection = min(selection, max(0, visible.count - 1))
    }

    func run(_ tile: QuickTile) {
        guard !editing else { return toggleShown(tile.id) }
        if tile.toggle != nil {
            tile.run()
        } else {
            close()
            // Let the panel go before an action that takes the screen or the keyboard.
            Task { try? await Task.sleep(for: .milliseconds(120)); tile.run() }
        }
    }

    func toggleShown(_ id: String) {
        if settings.shown.contains(id) { settings.shown.remove(id) } else { settings.shown.insert(id) }
    }

    /// Drag-to-reorder: puts `id` where `target` is.
    func move(_ id: String, before target: String) {
        guard id != target else { return }
        var ids = tiles.map(\.id)
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        let to = ids.firstIndex(of: target) ?? ids.count
        ids.insert(id, at: to)
        // Keep the positions of tiles that aren't available right now.
        settings.order = ids + settings.order.filter { !ids.contains($0) }
        tiles = QuickTiles.ordered(tiles, order: settings.order)
    }

    func moveSelection(_ delta: Int) {
        let count = visible.count
        guard count > 0 else { return }
        selection = min(max(0, selection + delta), count - 1)
    }
}

/// The Quick Panel: a small glass grid of favorite tools at the center of the screen, from a
/// shortcut. It takes the keyboard without activating Zephydian.
final class QuickPanel {
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    static let columns = 4
    static let tile = CGSize(width: 96, height: 84)
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 16
    static let header: CGFloat = 40

    let model = QuickPanelModel()
    private var panel: KeyPanel?
    private var outsideMonitor: Any?
    private var center = CGPoint.zero

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() { isOpen ? close() : open() }

    func open() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.close = { [weak self] in self?.close() }
        model.editing = false
        model.selection = 0
        model.reload()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        center = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY + screen.visibleFrame.height * 0.08)
        resize()
        panel.makeKeyAndOrderFront(nil)
        follow()
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
    }

    private func follow() {
        guard isOpen else { return }
        withObservationTracking { _ = model.visible.count } onChange: { [weak self] in
            Task { @MainActor in
                self?.resize()
                self?.follow()
            }
        }
    }

    private func resize() {
        guard let panel else { return }
        let count = max(model.visible.count, 1)
        let rows = (count + Self.columns - 1) / Self.columns
        let width = CGFloat(Self.columns) * Self.tile.width + CGFloat(Self.columns - 1) * Self.spacing + Self.padding * 2
        let height = Self.header + CGFloat(rows) * Self.tile.height + CGFloat(rows - 1) * Self.spacing + Self.padding * 1.5
        panel.setFrame(CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height), display: true)
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let settings = Features.shared.appSettings ?? SettingsStore()
        panel.appearance = settings.appearance.nsAppearance
        let hosting = NSHostingView(rootView: QuickPanelView(model: model).environment(settings).tint(settings.accentColor))
        let radius: CGFloat = 24
        if #available(macOS 26, *), settings.usesGlass {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            hosting.autoresizingMask = [.width, .height]
            glass.contentView = hosting
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = .roundedMask(radius: radius)
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
            panel.contentView = effect
        }
        return panel
    }
}

private struct QuickPanelView: View {
    let model: QuickPanelModel
    @State private var toggles = QuickToggles.shared
    @State private var settings = QuickPanelSettings.shared
    @FocusState private var focused: Bool
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        let tiles = model.visible
        VStack(spacing: 0) {
            HStack {
                Text(model.editing ? "Show, hide and drag tiles" : "Quick Panel")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.editing ? "Done" : "Edit") {
                    model.editing.toggle()
                    model.selection = 0
                }
                .panelButtonStyle()
                .controlSize(.small)
            }
            .padding(.horizontal, QuickPanel.padding)
            .frame(height: QuickPanel.header)
            if tiles.isEmpty {
                Text("Nothing here yet. Click Edit to choose tiles, or switch on Quick Toggles and other features in Settings.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, QuickPanel.padding)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(QuickPanel.tile.width), spacing: QuickPanel.spacing), count: QuickPanel.columns),
                          spacing: QuickPanel.spacing) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        tileView(tile, selected: index == model.selection)
                    }
                }
                .padding(.horizontal, QuickPanel.padding)
                Spacer(minLength: 0)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { model.moveSelection(-1); return .handled }
        .onKeyPress(.rightArrow) { model.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-QuickPanel.columns); return .handled }
        .onKeyPress(.downArrow) { model.moveSelection(QuickPanel.columns); return .handled }
        .onKeyPress(.return) {
            if model.visible.indices.contains(model.selection) { model.run(model.visible[model.selection]) }
            return .handled
        }
        .onKeyPress(.escape) {
            if model.editing { model.editing = false } else { model.close() }
            return .handled
        }
    }

    private func tileView(_ tile: QuickTile, selected: Bool) -> some View {
        let on = tile.toggle.map { toggles.isOn($0) } ?? false
        let shown = settings.shown.contains(tile.id)
        return Button { model.run(tile) } label: {
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(on ? AnyShapeStyle(appSettings.accentColor) : AnyShapeStyle(.quaternary))
                    if let toggle = tile.toggle, toggles.busy.contains(toggle) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: tile.symbol)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(on ? .white : .primary)
                    }
                }
                .frame(width: 42, height: 42)
                .overlay(alignment: .topTrailing) {
                    if model.editing {
                        Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(shown ? appSettings.accentColor : .secondary)
                            .background(Circle().fill(.background).padding(1))
                            .offset(x: 6, y: -6)
                    }
                }
                Text(tile.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: QuickPanel.tile.width, height: QuickPanel.tile.height)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(selected ? AnyShapeStyle(appSettings.accentColor.opacity(0.18)) : AnyShapeStyle(.clear)))
            .opacity(model.editing && !shown ? 0.45 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tile.title)
        .accessibilityValue(tile.toggle == nil ? "" : (on ? "On" : "Off"))
        .onDrag { NSItemProvider(object: tile.id as NSString) }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            guard model.editing, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let dragged = object as? String else { return }
                Task { @MainActor in model.move(dragged, before: tile.id) }
            }
            return true
        }
    }
}

final class QuickPanelEngine: FeatureEngine {
    static weak var current: QuickPanelEngine?

    private let settings = QuickPanelSettings.shared
    private let hotKey = GlobalHotKey(id: 706)
    private let panel = QuickPanel()
    private var running = false

    func start() {
        running = true
        Self.current = self
        hotKey.onPress = { [weak self] in self?.panel.toggle() }
        follow()
    }

    func stop() {
        running = false
        if Self.current === self { Self.current = nil }
        hotKey.unregister()
        panel.close()
    }

    func open() { panel.open() }

    private func follow() {
        guard running else { return }
        withObservationTracking { _ = settings.shortcut } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        settings.registered = hotKey.register(settings.shortcut)
    }
}

struct QuickPanelSettingsView: View {
    @State private var settings = QuickPanelSettings.shared
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        Section {
            LabeledContent("Open the Quick Panel") {
                ShortcutRecorder(shortcut: settings.shortcut) { settings.shortcut = $0 }
            }
            ShortcutWarning(text: ShortcutConflicts.warning(for: settings.shortcut, registered: settings.registered,
                                                            owner: "quick-panel", panel: appSettings.panelShortcut))
        } footer: {
            Text("A grid of your favorite tools in the middle of the screen. Click Edit on it to show or hide tiles and drag them into your order. Tiles come from Quick Toggles, Capture, Shelf, Camera Mirror, Cleaning Mode and your installed utilities. Arrow keys and ↵ work too; Esc closes it.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
