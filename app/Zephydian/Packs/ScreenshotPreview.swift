import AppKit
import SwiftUI

/// The small card that appears in the screen's bottom-right corner after a screenshot: a thumbnail
/// (click it to open the shot in the image editor, when one is installed) with Copy, Save, Delete
/// and Close. Left alone for a few
/// seconds (and not hovered), it copies the shot and goes away. It's a floating control, so it's
/// glass (the shared helpers; Frosted on older macOS).
final class ScreenshotPreview {
    enum Action { case copy, save, edit, delete, close, timeout }

    let shotID: String
    private let panel: NSPanel
    private let finish: (Action) -> Void
    private var timer: Task<Void, Never>?
    private var hovering = false
    private var done = false

    init(shotID: String, image: NSImage, canEdit: Bool, settings: SettingsStore?, finish: @escaping (Action) -> Void) {
        self.shotID = shotID
        self.finish = finish
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let size = NSSize(width: 290, height: 216)
        let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 16, y: screen.visibleFrame.minY + 16, width: size.width, height: size.height)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let card = PreviewCard(image: image, canEdit: canEdit, act: { [weak self] in self?.end($0) },
                               hover: { [weak self] in self?.hovering = $0; if !$0 { self?.startTimer() } })
            .environment(settings ?? SettingsStore())
        panel.contentView = NSHostingView(rootView: card)
        panel.orderFrontRegardless()
        startTimer()
    }

    private func startTimer() {
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, !self.hovering else { return }
            self.end(.timeout)
        }
    }

    private func end(_ action: Action) {
        guard !done else { return }
        done = true
        timer?.cancel()
        panel.orderOut(nil)
        finish(action)
    }

    /// Closed from outside (the shot was deleted, or a new one replaces it).
    func close() { end(.close) }
}

private struct PreviewCard: View {
    let image: NSImage
    let canEdit: Bool
    let act: (ScreenshotPreview.Action) -> Void
    let hover: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
            Button { if canEdit { act(.edit) } } label: {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 262, maxHeight: 124)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .overlay {
                        // A hint that the picture opens the editor.
                        if canEdit && hovering {
                            Image(systemName: "pencil.tip.crop.circle")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(6)
                                .glassSurface(in: Circle())
                                .transition(.opacity)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(!canEdit)
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
            .help(canEdit ? "Edit in Markup" : "")
            .accessibilityLabel(canEdit ? "Edit the screenshot" : "Screenshot")
            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    Button("Copy") { act(.copy) }
                    Button("Save") { act(.save) }
                    Button { act(.delete) } label: { Image(systemName: "trash") }
                        .glassIconButtonStyle()
                        .help("Delete the screenshot")
                        .accessibilityLabel("Delete")
                    Button { act(.close) } label: { Image(systemName: "xmark") }
                        .glassIconButtonStyle()
                        .help("Close (the screenshot is copied)")
                        .accessibilityLabel("Close")
                }
            }
            .controlSize(.small)
            .panelButtonStyle()
        }
        .padding(14)
        .frame(width: 290, height: 216)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onHover(perform: hover)
    }
}
