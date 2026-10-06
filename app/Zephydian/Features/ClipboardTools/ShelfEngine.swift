import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One thing parked on the Shelf.
struct ShelfItem: Identifiable, Equatable {
    enum Content: Equatable {
        case file(URL)
        case link(URL)
        case text(String)
    }
    let id = UUID()
    let content: Content

    var title: String {
        switch content {
        case .file(let url): FileManager.default.displayName(atPath: url.path)
        case .link(let url): url.host() ?? url.absoluteString
        case .text(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? text
        }
    }

    var icon: NSImage? {
        if case .file(let url) = content { return NSWorkspace.shared.icon(forFile: url.path) }
        return nil
    }

    var symbol: String {
        switch content {
        case .file: "doc"
        case .link: "link"
        case .text: "text.alignleft"
        }
    }

    /// What's handed over when it's dragged out.
    var provider: NSItemProvider {
        switch content {
        case .file(let url): NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
        case .link(let url): NSItemProvider(object: url as NSURL)
        case .text(let text): NSItemProvider(object: text as NSString)
        }
    }
}

/// What's on the Shelf, shared by the floating shelf and the corner panel's Shelf screen.
@Observable
final class ShelfStore {
    static let shared = ShelfStore()
    var items: [ShelfItem] = []

    func add(_ content: ShelfItem.Content) {
        guard !items.contains(where: { $0.content == content }) else { return }
        items.append(ShelfItem(content: content))
    }
}

/// The Shelf: start dragging something, give the pointer a quick shake (or drag it into Zephydian's
/// corner), and a small shelf appears. Drop files, links or text on it and drag them out later. It also opens with its
/// shortcut and from the menu bar. While the feature is on, mouse drags are watched (only drags;
/// plain pointer movement isn't), and nothing else runs.
final class ShelfEngine: FeatureEngine {
    static weak var current: ShelfEngine?
    /// Opens the corner panel on its Shelf screen, and closes it again (set by AppDelegate).
    static var showInPanel: () -> Void = {}
    static var closePanel: (_ unlessPointerInside: Bool) -> Void = { _ in }

    private let settings = ClipboardToolsSettings.shared
    private let shelf = ShelfPanel()
    private let hotKey = GlobalHotKey(id: 701)
    private var monitors: [Any] = []
    private var running = false

    // Shake detection during one drag.
    private var dragChange = 0
    private var lastX: CGFloat?
    private var direction: CGFloat = 0
    private var travel: CGFloat = 0
    private var turns: [Date] = []
    /// The corner panel was opened for the drag in progress.
    private var openedPanelForDrag = false

    func start() {
        running = true
        Self.current = self
        hotKey.onPress = { [weak self] in self?.toggle() }
        follow()
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dragBegan() }
        }) { monitors.append(down) }
        if let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dragged() }
        }) { monitors.append(dragged) }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dragEnded() }
        }) { monitors.append(up) }
    }

    func stop() {
        running = false
        if Self.current === self { Self.current = nil }
        hotKey.unregister()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        shelf.close()
    }

    /// Opens or closes the Shelf (the shortcut and the menu bar's Shelf item).
    func toggle() {
        if shelf.isOpen { shelf.close() } else { shelf.show(near: NSEvent.mouseLocation) }
    }

    private func follow() {
        guard running else { return }
        withObservationTracking { _ = settings.shelfShortcut } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        ClipboardToolsStatus.shared.shelfRegistered = hotKey.register(settings.shelfShortcut)
    }

    private func dragBegan() {
        openedPanelForDrag = false
        dragChange = NSPasteboard(name: .drag).changeCount
        lastX = nil
        direction = 0
        travel = 0
        turns = []
    }

    /// Dropped somewhere: a corner panel opened for this drag closes, unless the drop was on it.
    private func dragEnded() {
        guard openedPanelForDrag else { return }
        openedPanelForDrag = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            Self.closePanel(true)
        }
    }

    /// While something is being dragged: the corner panel opens on the Shelf right away, or a shake
    /// (three quick changes of direction) opens the floating shelf.
    private func dragged() {
        guard NSPasteboard(name: .drag).changeCount != dragChange else { return }   // a real drag, not a selection
        if settings.shelfOpening == .corner {
            if !openedPanelForDrag {
                openedPanelForDrag = true
                Self.showInPanel()
            }
            return
        }
        guard !shelf.isOpen else { return }
        let x = NSEvent.mouseLocation.x
        defer { lastX = x }
        guard let lastX else { return }
        let dx = x - lastX
        guard abs(dx) > 1 else { return }
        let sign: CGFloat = dx > 0 ? 1 : -1
        if sign == direction {
            travel += abs(dx)
            return
        }
        if travel > 25 { turns.append(Date()) }
        direction = sign
        travel = abs(dx)
        turns.removeAll { Date().timeIntervalSince($0) > 0.6 }
        if turns.count >= 3 {
            turns = []
            shelf.show(near: NSEvent.mouseLocation)
        }
    }
}

/// The Shelf's floating panel.
private final class ShelfPanel {
    private var panel: NSPanel?
    var isOpen: Bool { panel?.isVisible == true }

    func show(near point: CGPoint) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = CGSize(width: 240, height: 220)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        // Beside the pointer, not under it, so the drop lands where you aim.
        var origin = CGPoint(x: point.x + 40, y: point.y - size.height / 2)
        if origin.x + size.width > area.maxX { origin.x = point.x - 40 - size.width }
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let settings = Features.shared.appSettings ?? SettingsStore()
        panel.appearance = settings.appearance.nsAppearance
        panel.contentView = NSHostingView(rootView: ShelfContent(floating: true, close: { [weak self] in self?.close() })
            .environment(settings).tint(settings.accentColor))
        return panel
    }
}

/// The Shelf's items with their drop area: on its own floating glass card, or as a screen in the corner panel.
struct ShelfContent: View {
    /// The floating shelf draws its own glass card; in the panel, the panel's material is around it.
    let floating: Bool
    let close: () -> Void
    /// False in the panel's Shelf tab, which has nothing to close or go back to.
    var showsClose = true
    @State private var targeted = false
    private var model: ShelfStore { ShelfStore.shared }

        var body: some View {
            VStack(spacing: 8) {
                HStack {
                    Text("Shelf").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !model.items.isEmpty {
                        Button { model.items.removeAll() } label: { Image(systemName: "trash") }
                            .glassIconButtonStyle()
                            .help("Clear the shelf")
                            .accessibilityLabel("Clear the shelf")
                    }
                    if showsClose {
                        Button(action: close) { Image(systemName: floating ? "xmark" : "chevron.down") }
                            .glassIconButtonStyle()
                            .help(floating ? "Close (what's on it stays)" : "Back")
                            .accessibilityLabel(floating ? "Close the shelf" : "Back")
                    }
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                        ForEach(model.items) { item in
                            VStack(spacing: 4) {
                                Group {
                                    if let icon = item.icon { Image(nsImage: icon).resizable() }
                                    else { Image(systemName: item.symbol).resizable().scaledToFit().padding(8).foregroundStyle(.secondary) }
                                }
                                .frame(width: 40, height: 40)
                                Text(item.title).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .frame(width: 64)
                            .contentShape(Rectangle())
                            .onDrag { item.provider }
                            .contextMenu {
                                if case .file(let url) = item.content {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                                Button("Remove from Shelf", role: .destructive) { model.items.removeAll { $0.id == item.id } }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityHint("Drag it to where you want it")
                        }
                    }
                }
                .overlay {
                    if model.items.isEmpty {
                        Text("Drop files, links or text here")
                            .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
            }
            .padding(floating ? 12 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { if floating { Color.clear.glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fallback: .regularMaterial) } }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            }
            .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $targeted) { providers in
                for provider in providers { receive(provider) }
                return true
            }
    }

    private func receive(_ provider: NSItemProvider) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add(.file(url)) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add(.link(url)) }
                }
            } else {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, !text.isEmpty else { return }
                    Task { @MainActor in add(.text(text)) }
                }
            }
        }

    private func add(_ content: ShelfItem.Content) { model.add(content) }
}
