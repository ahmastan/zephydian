import AppKit
import SwiftUI

/// The snippet menu: a small floating search over your snippets. It takes the keyboard without
/// making Zephydian the active app, so the snippet goes back into the app you were typing in.
final class SnippetMenu {
    @Observable final class Model {
        var snippets: [Snippet] = []
        var query = ""
        var selection = 0
        var visible: [Snippet] {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return snippets }
            return snippets.filter { $0.trigger.localizedCaseInsensitiveContains(q) || $0.text.localizedCaseInsensitiveContains(q) }
        }
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let model = Model()
    private var panel: KeyPanel?
    private var choose: (Snippet) -> Void = { _ in }
    private var outsideMonitor: Any?

    func show(snippets: [Snippet], choose: @escaping (Snippet) -> Void) {
        self.choose = choose
        model.snippets = snippets
        model.query = ""
        model.selection = 0
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = CGSize(width: 420, height: 320)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        panel.setFrame(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + area.height * 0.12,
                              width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    func close() {
        panel?.orderOut(nil)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
    }

    private func pick(_ snippet: Snippet) {
        close()
        choose(snippet)
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
        let hosting = NSHostingView(rootView: MenuView(model: model, pick: { [weak self] in self?.pick($0) }, close: { [weak self] in self?.close() })
            .environment(settings)
            .tint(settings.accentColor))
        let radius: CGFloat = 18
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

    private struct MenuView: View {
        let model: Model
        let pick: (Snippet) -> Void
        let close: () -> Void
        @FocusState private var focused: Bool

        var body: some View {
            @Bindable var model = model
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "text.badge.plus").foregroundStyle(.tint)
                    TextField("Search snippets", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { choose() }
                        .onChange(of: model.query) { model.selection = 0 }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(model.visible.enumerated()), id: \.element.id) { index, snippet in
                                row(snippet, selected: index == model.selection)
                                    .id(snippet.id)
                                    .onTapGesture { pick(snippet) }
                            }
                            if model.visible.isEmpty {
                                Text(model.snippets.isEmpty ? "No snippets yet. Add them in Settings → Text Snippets." : "No matches")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 20)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .onChange(of: model.selection) { _, index in
                        if model.visible.indices.contains(index) { proxy.scrollTo(model.visible[index].id) }
                    }
                }
            }
            .padding(.vertical, 8)
            .onAppear { focused = true }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.escape) { close(); return .handled }
        }

        private func row(_ snippet: Snippet, selected: Bool) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.trigger).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(snippet.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }

        private func move(_ delta: Int) {
            let count = model.visible.count
            guard count > 0 else { return }
            model.selection = (model.selection + delta + count) % count
        }

        private func choose() {
            let list = model.visible
            if list.indices.contains(model.selection) { pick(list[model.selection]) }
        }
    }
}
