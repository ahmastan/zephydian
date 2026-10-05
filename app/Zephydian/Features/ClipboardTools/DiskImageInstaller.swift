import AppKit
import SwiftUI

/// Disk image installer: when you open a disk image (.dmg) that holds an app, a small card offers to
/// install it. Install copies the app into Applications (asking before replacing an older copy),
/// ejects the disk image and moves the .dmg to the Trash, then offers to open the app.
/// It listens for disks being mounted (a macOS notification); nothing runs in between.
final class DiskImageInstallerEngine: FeatureEngine {
    private var observer: NSObjectProtocol?
    private let card = InstallCard()

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { if let volume { self?.mounted(volume) } }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        card.close()
    }

    private func mounted(_ volume: URL) {
        Task { @MainActor in
            // Only disk images (not USB drives), and only ones with an app at the top.
            guard let image = await Self.diskImage(mountedAt: volume),
                  let app = Self.app(in: volume) else { return }
            card.offer(app: app, volume: volume, image: image)
        }
    }

    /// The .dmg file behind a mounted volume, from `hdiutil info` (nil if it isn't a disk image).
    private static func diskImage(mountedAt volume: URL) async -> URL? {
        let output: Data? = await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/hdiutil")
            process.arguments = ["info", "-plist"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
        guard let output, let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        let target = volume.standardizedFileURL.path
        for image in images {
            let mounts = (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
            if mounts.contains(where: { URL(filePath: $0).standardizedFileURL.path == target }), let path = image["image-path"] as? String {
                return URL(filePath: path)
            }
        }
        return nil
    }

    /// The first app at the top of the volume.
    private static func app(in volume: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.first { url in
            url.pathExtension == "app" && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        }
    }
}

/// The card in the corner of the screen: the offer, progress, then the result.
private final class InstallCard {
    @Observable final class Model {
        enum Stage: Equatable { case offer, installing, done, failed(String) }
        var appName = ""
        var icon: NSImage?
        var stage = Stage.offer
        @ObservationIgnored var install: () -> Void = {}
        @ObservationIgnored var open: () -> Void = {}
        @ObservationIgnored var dismiss: () -> Void = {}
    }

    private let model = Model()
    private var panel: NSPanel?
    private var installed: URL?

    func offer(app: URL, volume: URL, image: URL) {
        model.appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        model.icon = NSWorkspace.shared.icon(forFile: app.path)
        model.stage = .offer
        model.install = { [weak self] in self?.install(app: app, volume: volume, image: image) }
        model.open = { [weak self] in
            if let installed = self?.installed { NSWorkspace.shared.openApplication(at: installed, configuration: .init()) }
            self?.close()
        }
        model.dismiss = { [weak self] in self?.close() }
        show()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func install(app: URL, volume: URL, image: URL) {
        let destination = URL(filePath: "/Applications").appending(path: app.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let alert = NSAlert()
            alert.messageText = "Replace \(model.appName) in Applications?"
            alert.informativeText = "The copy that's there now goes to the Trash."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.stage = .installing
        Task { @MainActor in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try await NSWorkspace.shared.recycle([destination])
                }
                // Copying a large app takes a moment: off the main thread.
                try await Task.detached { try FileManager.default.copyItem(at: app, to: destination) }.value
                installed = destination
                // Eject the disk image, then move the downloaded .dmg to the Trash.
                try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                _ = try? await NSWorkspace.shared.recycle([image])
                model.stage = .done
            } catch {
                model.stage = .failed(error.localizedDescription)
            }
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = CGSize(width: 340, height: 92)
        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrame(CGRect(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let settings = Features.shared.appSettings ?? SettingsStore()
        panel.appearance = settings.appearance.nsAppearance
        panel.contentView = NSHostingView(rootView: CardView(model: model).environment(settings).tint(settings.accentColor))
        return panel
    }

    private struct CardView: View {
        let model: Model

        var body: some View {
            HStack(spacing: 12) {
                if let icon = model.icon {
                    Image(nsImage: icon).resizable().frame(width: 44, height: 44).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    buttons
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), fallback: .regularMaterial)
        }

        private var headline: String {
            switch model.stage {
            case .offer: "Install \(model.appName) in Applications?"
            case .installing: "Installing \(model.appName)…"
            case .done: "\(model.appName) is installed."
            case .failed(let message): "Couldn't install \(model.appName): \(message)"
            }
        }

        @ViewBuilder private var buttons: some View {
            HStack(spacing: 8) {
                switch model.stage {
                case .offer:
                    Button("Install") { model.install() }.prominentButtonStyle()
                    Button("Not Now") { model.dismiss() }.panelButtonStyle()
                case .installing:
                    ProgressView().controlSize(.small)
                case .done:
                    Button("Open") { model.open() }.prominentButtonStyle()
                    Button("Done") { model.dismiss() }.panelButtonStyle()
                case .failed:
                    Button("Close") { model.dismiss() }.panelButtonStyle()
                }
            }
            .controlSize(.small)
        }
    }
}
