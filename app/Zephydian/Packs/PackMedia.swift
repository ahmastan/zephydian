import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The `media.convert` capability (SDK 7, the Media utility): shrink videos, convert and watermark
/// images, and make GIFs, all on this Mac. Files come in through macOS's open dialog and go out
/// through its save dialog; the pack only ever sees short ids and names, never paths.
@MainActor
final class PackMedia {
    struct Picked { let url: URL; let packID: String }

    /// The files people picked, by id.
    private var picked: [String: Picked] = [:]
    /// What's running now, for the utility's progress line.
    private(set) var job: (label: String, progress: Double)?
    private unowned let services: PackServices

    init(services: PackServices) { self.services = services }

    // MARK: Picking

    /// Shows the open dialog. `kind`: "video" or "images". Returns [{ id, name, size }] (empty if cancelled).
    func pick(kind: String, multiple: Bool, packID: String, done: @escaping ([[String: Any]]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = kind == "video" ? [.movie] : [.image]
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.level = .statusBar + 1
        services.holdPanel()
        NSApp.activate()
        nonisolated(unsafe) let done = done
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                self?.services.releasePanel()
                guard let self, response == .OK else { return done([]) }
                done(panel.urls.map { url in
                    let id = String(UUID().uuidString.prefix(8)).lowercased()
                    self.picked[id] = Picked(url: url, packID: packID)
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return ["id": id, "name": url.lastPathComponent, "size": size]
                })
            }
        }
    }

    func forget(packID: String) {
        picked = picked.filter { $0.value.packID != packID }
    }

    private func files(_ ids: [String], packID: String) -> [URL] {
        ids.compactMap { picked[$0] }.filter { $0.packID == packID }.map(\.url)
    }

    // MARK: Jobs

    /// Shrinks a video: "small" (540p), "medium" (720p) or "large" (1080p). Asks where to save it.
    func shrink(_ id: String, quality: String, packID: String, done: @escaping ([String: Any]) -> Void) {
        guard let source = files([id], packID: packID).first else { return done(["error": "Pick a video first"]) }
        let preset = quality == "small" ? AVAssetExportPreset960x540 : quality == "large" ? AVAssetExportPreset1920x1080 : AVAssetExportPreset1280x720
        guard let destination = askWhere(name: source.deletingPathExtension().lastPathComponent + " (smaller).mp4", type: .mpeg4Movie) else { return done([:]) }
        run("Shrinking the video…", done: done) { progress in
            let asset = AVURLAsset(url: source)
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw RecordingExport.Failed(errorDescription: "This video can't be converted.") }
            try? FileManager.default.removeItem(at: destination)
            session.outputURL = destination
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            nonisolated(unsafe) let exporting = session
            let watcher = Task.detached {
                while !Task.isCancelled { progress(Double(exporting.progress)); try? await Task.sleep(for: .milliseconds(250)) }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                exporting.exportAsynchronously { continuation.resume() }
            }
            watcher.cancel()
            guard session.status == .completed else { throw RecordingExport.Failed(errorDescription: session.error?.localizedDescription ?? "It didn't finish.") }
            let before = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let after = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return ["saved": destination.lastPathComponent, "before": before, "after": after]
        }
    }

    /// A GIF from a video. Asks where to save it.
    func gif(_ id: String, width: Int, fps: Int, packID: String, done: @escaping ([String: Any]) -> Void) {
        guard let source = files([id], packID: packID).first else { return done(["error": "Pick a video first"]) }
        guard let destination = askWhere(name: source.deletingPathExtension().lastPathComponent + ".gif", type: .gif) else { return done([:]) }
        let width = min(max(width, 160), 1600), fps = Double(min(max(fps, 5), 30))
        run("Making the GIF…", done: done) { progress in
            try await RecordingExport.gif(from: source, to: destination, width: width, fps: fps, progress: progress)
            return ["saved": destination.lastPathComponent]
        }
    }

    /// Converts images to "jpeg", "png", "heic" or "tiff". Asks for a folder to put them in.
    func convert(_ ids: [String], format: String, packID: String, done: @escaping ([String: Any]) -> Void) {
        let sources = files(ids, packID: packID)
        guard !sources.isEmpty else { return done(["error": "Pick some images first"]) }
        let type: UTType = format == "png" ? .png : format == "heic" ? .heic : format == "tiff" ? .tiff : .jpeg
        guard let folder = askFolder() else { return done([:]) }
        run("Converting \(sources.count) image\(sources.count == 1 ? "" : "s")…", done: done) { progress in
            var count = 0
            for (i, source) in sources.enumerated() {
                guard let image = Self.load(source) else { continue }
                let destination = Self.unique(folder.appending(path: source.deletingPathExtension().lastPathComponent + "." + (type.preferredFilenameExtension ?? format)))
                if Self.write(image, to: destination, type: type) { count += 1 }
                progress(Double(i + 1) / Double(sources.count))
            }
            return ["count": count]
        }
    }

    /// Adds a line of text to images ("topLeft", "topRight", "bottomLeft", "bottomRight", "center").
    /// Asks for a folder; the originals aren't changed.
    func watermark(_ ids: [String], text: String, position: String, opacity: Double, packID: String, done: @escaping ([String: Any]) -> Void) {
        let sources = files(ids, packID: packID)
        guard !sources.isEmpty else { return done(["error": "Pick some images first"]) }
        guard !text.isEmpty else { return done(["error": "Type the watermark text"]) }
        guard let folder = askFolder() else { return done([:]) }
        let text = String(text.prefix(200)), opacity = min(max(opacity, 0.1), 1)
        run("Adding the watermark…", done: done) { progress in
            var count = 0
            for (i, source) in sources.enumerated() {
                guard let image = Self.load(source), let marked = Self.watermarked(image, text: text, position: position, opacity: opacity) else { continue }
                let type = UTType(filenameExtension: source.pathExtension) ?? .png
                let destination = Self.unique(folder.appending(path: source.deletingPathExtension().lastPathComponent + " (watermark)." + (type.preferredFilenameExtension ?? "png")))
                if Self.write(marked, to: destination, type: type) { count += 1 }
                progress(Double(i + 1) / Double(sources.count))
            }
            return ["count": count]
        }
    }

    /// Runs a job off the main thread, reporting its progress for the utility's view.
    private func run(_ label: String, done: @escaping ([String: Any]) -> Void,
                     work: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> [String: any Sendable]) {
        guard job == nil else { return done(["error": "Wait for the current job to finish"]) }
        job = (label, 0)
        services.changed()
        nonisolated(unsafe) let done = done
        Task { @MainActor [weak self] in
            let result: [String: Any]
            do {
                let output = try await Task.detached {
                    try await work { value in Task { @MainActor in self?.job?.progress = value; self?.services.changed() } }
                }.value
                result = output
            } catch {
                result = ["error": error.localizedDescription]
            }
            self?.job = nil
            self?.services.changed()
            done(result)
        }
    }

    // MARK: Dialogs

    private func askWhere(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.level = .statusBar + 1
        services.holdPanel()
        defer { services.releasePanel() }
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func askFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where the new images go (the originals aren't changed)."
        panel.level = .statusBar + 1
        services.holdPanel()
        defer { services.releasePanel() }
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Images

    private nonisolated static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private nonisolated static func write(_ image: CGImage, to url: URL, type: UTType) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private nonisolated static func unique(_ url: URL) -> URL {
        var candidate = url, n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appending(path: url.deletingPathExtension().lastPathComponent + " \(n)." + url.pathExtension)
            n += 1
        }
        return candidate
    }

    /// The image with white text and a soft shadow, sized to the picture.
    private nonisolated static func watermarked(_ image: CGImage, text: String, position: String, opacity: Double) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let fontSize = max(14, CGFloat(min(width, height)) / 22)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(opacity),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetImageBounds(line, context)
        let margin = fontSize
        let x: CGFloat = position.hasSuffix("Left") ? margin : position == "center" ? (CGFloat(width) - bounds.width) / 2 : CGFloat(width) - bounds.width - margin
        let y: CGFloat = position.hasPrefix("top") ? CGFloat(height) - bounds.height - margin : position == "center" ? (CGFloat(height) - bounds.height) / 2 : margin
        context.setShadow(offset: CGSize(width: 0, height: -fontSize / 12), blur: fontSize / 4, color: NSColor.black.withAlphaComponent(0.5 * opacity).cgColor)
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
