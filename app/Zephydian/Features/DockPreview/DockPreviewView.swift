import SwiftUI

/// What the preview panel shows. The engine fills it; the view only reads it and reports back.
@Observable
final class DockPreviewModel {
    var app: NSRunningApplication?
    var windows: [SystemWindow] = []
    var pinned = false
    /// Cards run left to right above a bottom Dock, top to bottom beside a side Dock.
    var vertical = false
    /// The card scrolled into view by the arrows.
    var scrollTarget: CGWindowID?
    /// The card under the pointer. Worked out by the engine from the pointer's position, since hover
    /// tracking doesn't reach a window of an app that isn't active (Zephydian rarely is).
    var hoveredID: CGWindowID?
    /// Each card's frame in the panel (top-left origin), reported by the view.
    @ObservationIgnored var cardFrames: [CGWindowID: CGRect] = [:]

    // Wired by the engine.
    @ObservationIgnored var open: (SystemWindow) -> Void = { _ in }
    @ObservationIgnored var close: (SystemWindow) -> Void = { _ in }
    @ObservationIgnored var toggleMinimized: (SystemWindow) -> Void = { _ in }
    @ObservationIgnored var togglePin: () -> Void = {}
    @ObservationIgnored var dismiss: () -> Void = {}
    @ObservationIgnored var dragChanged: (SystemWindow) -> Void = { _ in }
    @ObservationIgnored var dragEnded: (SystemWindow) -> Void = { _ in }
    @ObservationIgnored var arrange: (SystemWindow, WindowLayout) -> Void = { _, _ in }
}

struct DockPreviewView: View {
    let model: DockPreviewModel
    let settings: DockPreviewSettings

    static let padding: CGFloat = 12
    static let spacing: CGFloat = 10
    static let headerHeight: CGFloat = 34
    static func titleHeight(minimal: Bool) -> CGFloat { minimal ? 0 : 26 }
    static func thumbnailHeight(_ width: CGFloat) -> CGFloat { (width * 0.62).rounded() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if model.windows.isEmpty {
                Text("No open windows")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                cards
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let app = model.app {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                }
                Text(app.localizedName ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 8)
            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    if model.windows.count > 1 {
                        Button { step(-1) } label: { Image(systemName: "chevron.left") }
                            .glassIconButtonStyle()
                            .help("Previous window")
                            .accessibilityLabel("Previous window")
                        Button { step(1) } label: { Image(systemName: "chevron.right") }
                            .glassIconButtonStyle()
                            .help("Next window")
                            .accessibilityLabel("Next window")
                    }
                    Button { model.togglePin() } label: { Image(systemName: model.pinned ? "pin.slash" : "pin") }
                        .glassIconButtonStyle()
                        .help(model.pinned ? "Unpin preview" : "Pin preview")
                        .accessibilityLabel(model.pinned ? "Unpin preview" : "Pin preview")
                    if model.pinned {
                        Button { model.dismiss() } label: { Image(systemName: "xmark") }
                            .glassIconButtonStyle()
                            .help("Close preview")
                            .accessibilityLabel("Close preview")
                    }
                }
            }
        }
        .frame(height: Self.headerHeight - 8)
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(model.vertical ? .vertical : .horizontal, showsIndicators: false) {
                let layout = model.vertical
                    ? AnyLayout(VStackLayout(spacing: Self.spacing))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: Self.spacing))
                layout {
                    ForEach(model.windows) { window in
                        WindowCard(window: window, model: model, settings: settings).id(window.id)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: CardFramesKey.self, value: [window.id: proxy.frame(in: .global)])
                            })
                    }
                }
            }
            .onPreferenceChange(CardFramesKey.self) { frames in model.cardFrames = frames }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    /// The arrows move the "current" card one step and scroll it into view.
    private func step(_ delta: Int) {
        let ids = model.windows.map(\.id)
        guard !ids.isEmpty else { return }
        let index = model.scrollTarget.flatMap { ids.firstIndex(of: $0) } ?? 0
        model.scrollTarget = ids[(index + delta + ids.count) % ids.count]
    }
}

/// One window: its picture, then its title with minimize and close buttons (shown on hover).
private struct WindowCard: View {
    let window: SystemWindow
    let model: DockPreviewModel
    let settings: DockPreviewSettings

    private var hovering: Bool { model.hoveredID == window.id }
    private var width: CGFloat { settings.size.cardWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            thumbnail
            if !settings.minimal { titleRow }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture { model.open(window) }
        .gesture(settings.dragToMove && window.canBeControlled && !window.isFullScreen && !window.isMinimized
                 ? DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { _ in model.dragChanged(window) }
                    .onEnded { _ in model.dragEnded(window) }
                 : nil)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.open(window) }
    }

    private var thumbnail: some View {
        let height = DockPreviewView.thumbnailHeight(width)
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06))
            if let image = WindowThumbnails.shared.image(for: window.id) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(4)
                    .opacity(window.isMinimized ? 0.55 : 1)
            } else if let icon = model.app?.icon {
                Image(nsImage: icon).resizable().frame(width: height * 0.45, height: height * 0.45).opacity(0.85)
            }
            if let badge {
                Image(systemName: badge)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(5)
                    .background(.regularMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: width, height: height)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
        }
    }

    private var titleRow: some View {
        HStack(spacing: 4) {
            ScrollingTitle(text: window.title.isEmpty ? (model.app?.localizedName ?? "Window") : window.title, scrolls: hovering)
            // The buttons' room is kept even when they're hidden, so the title doesn't jump.
            HStack(spacing: 2) {
                if !window.isFullScreen {
                    Button { model.toggleMinimized(window) } label: {
                        Image(systemName: window.isMinimized ? "plus.circle.fill" : "minus.circle.fill")
                    }
                    .help(window.isMinimized ? "Restore window" : "Minimize window")
                    .accessibilityLabel(window.isMinimized ? "Restore window" : "Minimize window")
                }
                Button { model.close(window) } label: { Image(systemName: "xmark.circle.fill") }
                    .help(settings.closeQuitsApp ? "Quit app" : "Close window")
                    .accessibilityLabel(settings.closeQuitsApp ? "Quit app" : "Close window")
            }
            .buttonStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .opacity(hovering && window.canBeControlled ? 1 : 0)
            .disabled(!hovering || !window.canBeControlled)
        }
        .frame(height: DockPreviewView.titleHeight(minimal: false))
    }

    @ViewBuilder private var menu: some View {
        Button { model.open(window) } label: { Label("Open Window", systemImage: "macwindow") }
        if window.canBeControlled && !window.isFullScreen {
            Button { model.toggleMinimized(window) } label: {
                Label(window.isMinimized ? "Restore Window" : "Minimize Window",
                      systemImage: window.isMinimized ? "plus.rectangle" : "minus.rectangle")
            }
        }
        if window.canBeControlled && !window.isFullScreen && !window.isMinimized && Features.shared.isOn("window-layout") {
            Menu("Move & Resize") {
                ForEach([WindowLayout.leftHalf, .rightHalf, .maximize, .center, .topLeft, .topRight, .bottomLeft, .bottomRight,
                         .nextDisplay]) { layout in
                    Button { model.arrange(window, layout) } label: { Label(layout.title, systemImage: layout.symbol) }
                }
            }
        }
        Divider()
        Button { model.togglePin() } label: {
            Label(model.pinned ? "Unpin Preview" : "Pin Preview", systemImage: model.pinned ? "pin.slash" : "pin")
        }
        if window.canBeControlled {
            Divider()
            Button(role: .destructive) { model.close(window) } label: {
                Label(settings.closeQuitsApp ? "Quit App" : "Close Window", systemImage: "xmark.circle")
            }
        }
    }

    private var badge: String? {
        if window.isOnOtherSpace { return "rectangle.on.rectangle" }
        if window.isFullScreen { return "arrow.up.left.and.arrow.down.right" }
        if window.isMinimized || window.isAppHidden { return "minus" }
        return nil
    }

    private var spokenLabel: String {
        var parts = [window.title.isEmpty ? "Window" : window.title]
        if window.isMinimized { parts.append("minimized") }
        if window.isAppHidden { parts.append("hidden") }
        if window.isOnOtherSpace { parts.append("on another desktop") }
        return parts.joined(separator: ", ")
    }
}

/// A window's name: cut short with "…" at rest, and slowly scrolling while the pointer is on its
/// card, so two windows of one app can be told apart.
private struct ScrollingTitle: View {
    let text: String
    let scrolls: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let overflow = textWidth - proxy.size.width
            let label = Text(text).font(.system(size: 11.5, weight: scrolls ? .semibold : .regular)).lineLimit(1)
            ZStack(alignment: .leading) {
                if scrolls && overflow > 0 && !reduceMotion {
                    label.fixedSize()
                        .offset(x: offset)
                        .onAppear {
                            offset = 0
                            withAnimation(.linear(duration: Double(overflow) / 30).delay(0.6).repeatForever(autoreverses: true)) {
                                offset = -overflow
                            }
                        }
                } else {
                    label.truncationMode(.middle)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .clipped()
            .background(Text(text).font(.system(size: 11.5, weight: .semibold)).fixedSize().hidden()
                .background(GeometryReader { Color.clear.preference(key: TitleWidthKey.self, value: $0.size.width) }))
            .onPreferenceChange(TitleWidthKey.self) { textWidth = $0 }
        }
        .accessibilityLabel(text)
    }
}

private struct CardFramesKey: PreferenceKey {
    static let defaultValue: [CGWindowID: CGRect] = [:]
    static func reduce(value: inout [CGWindowID: CGRect], nextValue: () -> [CGWindowID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct TitleWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
