import AVFoundation
import SwiftUI

/// A Mac feature's controls as a panel tab (Sound, Brightness, Quick Toggles…). A feature that's
/// off offers to switch it on; one missing a permission says which. Live parts (the camera, Sound's
/// app list) run only while the panel is on screen and this tab is showing.
struct FeatureTabView: View {
    let id: String

    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let features = Features.shared
        if let feature = features.feature(id) {
            if !features.isOn(id) {
                note(feature, text: feature.summary) {
                    Button("Switch On") { features.set(id, on: true) }
                        .prominentButtonStyle()
                }
            } else if !features.running.contains(id) {
                let missing = features.missing(feature).map(\.title).joined(separator: " and ")
                note(feature, text: "\(feature.name) needs \(missing.isEmpty ? "a permission" : missing) to work.") {
                    Button("Open Permissions") { model.openSettingsWindow(SettingsPage.permissions.rawValue) }
                        .panelButtonStyle()
                }
            } else {
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch id {
        case "sound-mixer":
            if let engine = SoundMixerEngine.current {
                ScrollView { SoundPopover(engine: engine, width: nil) }
                    // The app list and levels follow what's playing, once a second while showing.
                    .task(id: model.isPanelVisible) {
                        while model.isPanelVisible, !Task.isCancelled {
                            engine.model.refresh()
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
            }
        case "brightness":
            if let engine = BrightnessEngine.current {
                ScrollView { BrightnessPopover(engine: engine, width: nil) }
            }
        case "quick-toggles": QuickTogglesTab()
        case "quick-panel": QuickPanelTab()
        case "window-layout": WindowLayoutTab()
        case "snippets": SnippetsTab()
        case "shelf":
            ShelfContent(floating: false, close: {}, showsClose: false)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        case "camera-mirror": CameraTab()
        default: EmptyView()
        }
    }

    private func note(_ feature: Feature, text: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(spacing: 12) {
            Image(systemName: feature.symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text(feature.name).font(.system(size: 15, weight: .semibold))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Quick Toggles

/// Every quick toggle as a tile: switches light up while on, actions just run.
private struct QuickTogglesTab: View {
    @State private var toggles = QuickToggles.shared
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
                ForEach(QuickToggle.allCases.filter(toggles.isAvailable)) { toggle in
                    FeatureTile(title: toggle.title, symbol: toggle.symbol, on: toggle.isSwitch && toggles.isOn(toggle),
                                busy: toggles.busy.contains(toggle)) {
                        toggles.run(toggle)
                    }
                    .accessibilityValue(toggle.isSwitch ? (toggles.isOn(toggle) ? "On" : "Off") : "")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .onAppear { toggles.refresh() }
    }
}

/// A round icon over a name, like the Quick Panel's tiles. Content, so no glass.
private struct FeatureTile: View {
    let title: String
    let symbol: String
    var on = false
    var busy = false
    let action: () -> Void
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(on ? AnyShapeStyle(settings.accentColor) : AnyShapeStyle(.quaternary))
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(on ? .white : .primary)
                    }
                }
                .frame(width: 40, height: 40)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 78)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Quick Panel

/// The Quick Panel's grid in three columns; its actions close the corner panel first.
private struct QuickPanelTab: View {
    @Environment(AppModel.self) private var app
    @State private var model = QuickPanelModel()

    var body: some View {
        ScrollView {
            QuickPanelView(model: model, columns: 3)
                .frame(maxWidth: .infinity)
        }
        .onAppear {
            model.close = { [app] in app.closePanel() }
            model.reload()
        }
    }
}

// MARK: - Window Layout

/// A tile per layout: it arranges the front app's window (the panel doesn't take the focus from it).
private struct WindowLayoutTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Arranges the front window\(frontApp.map { " (\($0))" } ?? "").")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
                    ForEach(WindowLayout.allCases) { layout in
                        FeatureTile(title: layout.title, symbol: layout.symbol) {
                            guard let (window, _) = WindowArranger.focusedWindow() else { NSSound.beep(); return }
                            WindowArranger.apply(layout, to: window)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var frontApp: String? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app?.localizedName
    }
}

// MARK: - Snippets

/// Every snippet: clicking one closes the panel and pastes it where the cursor was.
private struct SnippetsTab: View {
    @Environment(AppModel.self) private var model
    @State private var input = InputSettings.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                if input.snippets.isEmpty {
                    Text("No snippets yet. Add them in Settings → Text Snippets.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.top, 20)
                }
                ForEach(input.snippets) { snippet in
                    Button { paste(snippet) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(snippet.trigger)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                                .lineLimit(1)
                            Text(snippet.text)
                                .font(.system(size: 12))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tokens.fill))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Paste where the cursor is")
                    .accessibilityLabel("Paste \(snippet.trigger)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func paste(_ snippet: Snippet) {
        model.closePanel()
        // Once the panel is gone, the paste goes to the app that was in front.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            SnippetPaste.insert(snippet.expanded())
        }
    }
}

// MARK: - Camera

/// The camera, mirrored, while the panel and this tab are on screen (the camera light goes off
/// as soon as either goes away).
private struct CameraTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        CameraPreview(running: model.isPanelVisible)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .accessibilityLabel("Camera preview")
    }
}

private struct CameraPreview: NSViewRepresentable {
    let running: Bool

    func makeNSView(context: Context) -> CameraPreviewView { CameraPreviewView() }

    func updateNSView(_ view: CameraPreviewView, context: Context) { view.setRunning(running) }

    static func dismantleNSView(_ view: CameraPreviewView, coordinator: ()) { view.setRunning(false) }
}

private final class CameraPreviewView: NSView {
    private let session = AVCaptureSession()
    private let preview: AVCaptureVideoPreviewLayer
    private var configured = false
    private var running = false

    init() {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        preview.frame = bounds
    }

    func setRunning(_ on: Bool) {
        guard on != running else { return }
        running = on
        if on, !configured {
            configured = true
            if let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
                session.addInput(input)
            }
            if let connection = preview.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
        // Starting and stopping the camera can take a moment, so off the main thread.
        nonisolated(unsafe) let session = session
        DispatchQueue.global(qos: .userInitiated).async {
            if on { session.startRunning() } else { session.stopRunning() }
        }
    }
}
