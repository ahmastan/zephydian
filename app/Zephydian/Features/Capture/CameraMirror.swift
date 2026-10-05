import AVFoundation
import AppKit
import SwiftUI

/// Camera Mirror's settings, saved as they change.
@Observable
final class CameraMirrorSettings {
    static let shared = CameraMirrorSettings()

    enum Shape: String, CaseIterable, Identifiable {
        case circle, rounded
        var id: String { rawValue }
        var title: String { self == .circle ? "Circle" : "Rounded" }
    }

    var shortcut: KeyShortcut? { didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "cameraMirror.shortcut") } }
    var shape: Shape { didSet { defaults.set(shape.rawValue, forKey: "cameraMirror.shape") } }
    /// The mirror's width in points.
    var size: Double { didSet { defaults.set(size, forKey: "cameraMirror.size") } }
    /// Flipped like a mirror (as you see yourself), or as others see you.
    var mirrored: Bool { didSet { defaults.set(mirrored, forKey: "cameraMirror.mirrored") } }

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        shortcut = defaults.data(forKey: "cameraMirror.shortcut").flatMap { try? JSONDecoder().decode(KeyShortcut?.self, from: $0) } ?? nil
        shape = Shape(rawValue: defaults.string(forKey: "cameraMirror.shape") ?? "") ?? .circle
        size = defaults.object(forKey: "cameraMirror.size") as? Double ?? 220
        mirrored = defaults.object(forKey: "cameraMirror.mirrored") as? Bool ?? true
    }
}

/// Camera Mirror: a small floating view of your camera, to check how you look before a call. It
/// opens from its shortcut or the menu bar; the camera runs only while it's open.
final class CameraMirrorEngine: FeatureEngine {
    static weak var current: CameraMirrorEngine?

    private let settings = CameraMirrorSettings.shared
    private let hotKey = GlobalHotKey(id: 702)
    private var mirror: MirrorPanel?
    private var running = false

    func start() {
        running = true
        Self.current = self
        hotKey.onPress = { [weak self] in self?.toggle() }
        follow()
    }

    func stop() {
        running = false
        if Self.current === self { Self.current = nil }
        hotKey.unregister()
        mirror?.close()
        mirror = nil
    }

    private func follow() {
        guard running else { return }
        withObservationTracking { _ = settings.shortcut } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        CameraMirrorStatus.shared.registered = hotKey.register(settings.shortcut)
    }

    /// Opens or closes the mirror (its shortcut and the menu bar item).
    func toggle() {
        if let mirror {
            mirror.close()
            self.mirror = nil
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            mirror = MirrorPanel(settings: settings) { [weak self] in self?.mirror = nil }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    Permissions.shared.refresh()
                    if granted { self?.toggle() }
                }
            }
        default:
            Permissions.shared.openSettings(.camera)
            CaptureToast.show("Allow Zephydian to use the camera", symbol: "camera.fill", detail: "System Settings → Privacy & Security → Camera")
        }
    }
}

@Observable
final class CameraMirrorStatus {
    static let shared = CameraMirrorStatus()
    var registered = true
}

/// The floating mirror: drag to move, double-click (or right-click → Close) to close.
private final class MirrorPanel {
    private let panel: NSPanel
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.ahmastan.zephydian.camera")

    init(settings: CameraMirrorSettings, closed: @escaping () -> Void) {
        let side = settings.size
        let height = settings.shape == .circle ? side : side * 0.75
        let screen = NSScreen.main ?? NSScreen.screens[0]
        panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.maxX - side - 24, y: screen.visibleFrame.minY + 24, width: side, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: side, height: height))
        view.wantsLayer = true
        view.layer?.cornerRadius = settings.shape == .circle ? side / 2 : 18
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = settings.mirrored
        }
        view.layer?.addSublayer(preview)
        view.onClose = { [weak panel] in panel?.orderOut(nil); closed() }
        panel.contentView = view

        // The default camera, started off the main thread (it takes a moment).
        if let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
            session.addInput(input)
        }
        nonisolated(unsafe) let running = session
        queue.async { running.startRunning() }
        panel.orderFrontRegardless()
    }

    func close() {
        nonisolated(unsafe) let running = session
        queue.async { running.stopRunning() }
        panel.orderOut(nil)
    }

    private final class MirrorView: NSView {
        var onClose: () -> Void = {}

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onClose(); return }
            window?.performDrag(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            menu.addItem(withTitle: "Close Camera Mirror", action: #selector(closeMirror), keyEquivalent: "").target = self
            return menu
        }

        @objc private func closeMirror() { onClose() }
    }
}

struct CameraMirrorSettingsView: View {
    @State private var settings = CameraMirrorSettings.shared
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        @Bindable var settings = settings
        Section {
            LabeledContent("Open or close the mirror") {
                ShortcutRecorder(shortcut: settings.shortcut) { settings.shortcut = $0 }
            }
            ShortcutWarning(text: ShortcutConflicts.warning(for: settings.shortcut, registered: CameraMirrorStatus.shared.registered,
                                                            owner: "camera-mirror", panel: appSettings.panelShortcut))
            Picker("Shape", selection: $settings.shape) {
                ForEach(CameraMirrorSettings.Shape.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Size") {
                Slider(value: $settings.size, in: 140...420).frame(maxWidth: 220)
            }
            Toggle("Flip like a mirror", isOn: $settings.mirrored)
        } footer: {
            Text("It also opens from the menu bar menu. Drag it anywhere; double-click to close it. The camera only runs while the mirror is open, and changes apply the next time you open it.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
