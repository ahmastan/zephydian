import AppKit
import SwiftUI
import Vision

// MARK: - Text and QR codes from the screen

/// Reads text (and QR codes) in a picture with Apple's Vision framework, entirely on this Mac.
nonisolated enum ScreenText {
    struct Found: Sendable {
        var text: String
        /// The link or text in a QR code (or other barcode), if there was one.
        var code: String?
    }

    static func read(_ image: CGImage) async -> Found {
        await Task.detached(priority: .userInitiated) { () -> Found in
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = true
            let codes = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([text, codes])
            // Lines top to bottom, as they appear.
            let lines = (text.results ?? [])
                .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                .compactMap { $0.topCandidates(1).first?.string }
            let code = (codes.results ?? []).compactMap(\.payloadStringValue).first
            return Found(text: lines.joined(separator: "\n"), code: code)
        }.value
    }
}

// MARK: - A short note on screen

/// "Copied 12 lines": a small glass note near the bottom of the screen for a moment.
@MainActor
enum CaptureToast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", detail: String? = nil) {
        hideTask?.cancel()
        panel?.orderOut(nil)
        let settings = Features.shared.appSettings ?? SettingsStore()
        let view = HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(settings.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: detail == nil ? 44 : 52)
        .glassSurface(in: Capsule(), fallback: .regularMaterial)
        .environment(settings)
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let new = NSPanel(contentRect: NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 90,
                                              width: size.width, height: size.height),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        new.level = .statusBar
        new.isOpaque = false
        new.backgroundColor = .clear
        new.ignoresMouseEvents = true
        new.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        new.appearance = settings.appearance.nsAppearance
        new.contentView = hosting
        new.orderFrontRegardless()
        panel = new
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
            panel = nil
        }
    }
}

// MARK: - Pinned screenshots

/// A screenshot floating above everything while you work: drag it to move, scroll (or pinch) to
/// resize, double-click (or its ×) to close, ⌘C copies it.
@MainActor
final class PinnedShots {
    private var windows: [NSPanel] = []

    func pin(_ image: CGImage, near point: NSPoint) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
        let limit = screen.visibleFrame.size
        let fit = min(1, limit.width * 0.6 / size.width, limit.height * 0.6 / size.height)
        size = NSSize(width: size.width * fit, height: size.height * fit)
        let panel = PinPanel(contentRect: NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                                                 width: size.width, height: size.height),
                             styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = size
        panel.isReleasedWhenClosed = false
        panel.image = image
        panel.onClose = { [weak self, weak panel] in
            guard let panel else { return }
            panel.orderOut(nil)
            self?.windows.removeAll { $0 === panel }
        }
        panel.contentView = NSHostingView(rootView: PinView(image: NSImage(cgImage: image, size: size), close: { [weak panel] in panel?.onClose() }))
        panel.orderFrontRegardless()
        windows.append(panel)
    }

    private final class PinPanel: NSPanel {
        var image: CGImage?
        var onClose: () -> Void = {}
        override var canBecomeKey: Bool { true }

        override func scrollWheel(with event: NSEvent) {
            let factor = 1 - event.scrollingDeltaY / 300
            var frame = self.frame
            let newWidth = min(max(frame.width * factor, 80), 4000)
            let newHeight = newWidth / (frame.width / frame.height)
            frame.origin.x += (frame.width - newWidth) / 2
            frame.origin.y += (frame.height - newHeight) / 2
            frame.size = NSSize(width: newWidth, height: newHeight)
            setFrame(frame, display: true)
        }

        override func magnify(with event: NSEvent) {
            var frame = self.frame
            let factor = 1 + event.magnification
            let newWidth = min(max(frame.width * factor, 80), 4000)
            let newHeight = newWidth / (frame.width / frame.height)
            frame.origin.x += (frame.width - newWidth) / 2
            frame.origin.y += (frame.height - newHeight) / 2
            frame.size = NSSize(width: newWidth, height: newHeight)
            setFrame(frame, display: true)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onClose(); return }
            super.mouseDown(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c", let image {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
                CaptureToast.show("Copied")
            } else if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w") {
                onClose()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private struct PinView: View {
        let image: NSImage
        let close: () -> Void
        @State private var hovering = false

        var body: some View {
            Image(nsImage: image)
                .resizable()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .overlay(alignment: .topLeading) {
                    if hovering {
                        Button(action: close) { Image(systemName: "xmark") }
                            .glassIconButtonStyle()
                            .padding(6)
                            .help("Close (or double-click)")
                            .accessibilityLabel("Close the pinned screenshot")
                    }
                }
                .onHover { hovering = $0 }
                .accessibilityLabel("Pinned screenshot")
        }
    }
}
