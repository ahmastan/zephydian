import AVFoundation
import AVKit
import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// The recording editor windows (one per recording). Zephydian is in the Dock while one is open.
@MainActor
final class RecordingEditors: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]

    func open(_ recording: Recording) {
        if let window = windows[recording.id] {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let settings = Features.shared.appSettings ?? SettingsStore()
        let model = EditorModel(recording: recording)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Recording · " + recording.date.formatted(date: .omitted, time: .shortened)
        window.minSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = settings.appearance.nsAppearance
        window.contentView = NSHostingView(rootView: EditorView(model: model, close: { [weak window] in window?.close() })
            .environment(settings).tint(settings.accentColor))
        window.identifier = NSUserInterfaceItemIdentifier(recording.id)
        window.center()
        windows[recording.id] = window
        DockPresence.add("recording-\(recording.id)")
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        DockPresence.remove("recording-\(id)")
        Task { @MainActor in window.contentView = nil }
    }
}

/// What the editor holds: the trim, the cut-out parts, blur boxes and automatic zoom.
@MainActor
@Observable
final class EditorModel {
    let recording: Recording
    let player: AVPlayer
    var duration: Double = 0
    var trimStart: Double = 0
    var trimEnd: Double = 0
    var cuts: [ClosedRange<Double>] = []
    /// Normalized rectangles (0…1, top-left origin) blurred for the whole recording.
    var blurs: [CGRect] = []
    var drawingBlur = false
    var autoZoom = true
    var markIn: Double?
    var time: Double = 0
    var thumbnails: [NSImage] = []
    var exporting: String?
    var progress: Double = 0
    @ObservationIgnored private var observer: Any?

    init(recording: Recording) {
        self.recording = recording
        player = AVPlayer(url: recording.url)
        autoZoom = !recording.clicks.isEmpty
        Task { await load() }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.time = time.seconds }
        }
    }

    private func load() async {
        let asset = AVURLAsset(url: recording.url)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        duration = seconds
        trimEnd = seconds
        // A strip of small frames along the timeline.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 200, height: 120)
        generator.appliesPreferredTrackTransform = true
        var images: [NSImage] = []
        for i in 0..<12 {
            let t = CMTime(seconds: seconds * (Double(i) + 0.5) / 12, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: t) { images.append(NSImage(cgImage: image, size: .zero)) }
        }
        thumbnails = images
    }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The parts kept: the trimmed span without the cut-out ones.
    var kept: [ClosedRange<Double>] {
        var parts = [trimStart...max(trimStart, trimEnd)]
        for cut in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            parts = parts.flatMap { part -> [ClosedRange<Double>] in
                guard cut.overlaps(part) else { return [part] }
                var out: [ClosedRange<Double>] = []
                if cut.lowerBound > part.lowerBound { out.append(part.lowerBound...cut.lowerBound) }
                if cut.upperBound < part.upperBound { out.append(cut.upperBound...part.upperBound) }
                return out
            }
        }
        return parts.filter { $0.upperBound - $0.lowerBound > 0.05 }
    }

    var keptLength: Double { kept.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }

    func export(gif: Bool, gifWidth: Int = 720) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [gif ? .gif : .mpeg4Movie]
        panel.nameFieldStringValue = "Recording " + recording.date.formatted(.dateTime.year().month().day().hour().minute())
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".") + (gif ? ".gif" : ".mp4")
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = gif ? "Making the GIF…" : "Saving the video…"
        progress = 0
        let job = RecordingExport(source: recording.url, kept: kept, blurs: blurs, clicks: autoZoom ? recording.clicks : [])
        let model = self
        Task { @MainActor in
            do {
                let movie = try await job.movie { value in Task { @MainActor in model.progress = gif ? value * 0.6 : value } }
                if gif {
                    try await RecordingExport.gif(from: movie, to: destination, width: gifWidth) { value in
                        Task { @MainActor in model.progress = 0.6 + value * 0.4 }
                    }
                    try? FileManager.default.removeItem(at: movie)
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: movie, to: destination)
                }
                exporting = nil
                CaptureToast.show(gif ? "GIF saved" : "Video saved", symbol: "checkmark.circle.fill", detail: destination.lastPathComponent)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                exporting = nil
                CaptureToast.show("Couldn't save it", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription)
            }
        }
    }
}

/// Builds the edited movie (kept parts, blur boxes, zoom on clicks) and GIFs, off the main thread.
nonisolated struct RecordingExport: Sendable {
    let source: URL
    let kept: [ClosedRange<Double>]
    let blurs: [CGRect]
    let clicks: [(time: Double, point: CGPoint)]

    struct Failed: LocalizedError { var errorDescription: String? }

    /// The edited movie in a temporary .mp4.
    func movie(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        let tracks = try await asset.load(.tracks)
        var pairs: [(AVAssetTrack, AVMutableCompositionTrack)] = []
        for track in tracks where track.mediaType == .video || track.mediaType == .audio {
            if let target = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) {
                pairs.append((track, target))
            }
        }
        // Each kept part, one after another; `segments` maps the edited timeline back to the recording.
        var segments: [(start: Double, source: Double, length: Double)] = []
        for part in kept {
            let range = CMTimeRange(start: CMTime(seconds: part.lowerBound, preferredTimescale: 600),
                                    end: CMTime(seconds: part.upperBound, preferredTimescale: 600))
            for (track, target) in pairs { try? target.insertTimeRange(range, of: track, at: cursor) }
            segments.append((cursor.seconds, part.lowerBound, part.upperBound - part.lowerBound))
            cursor = cursor + range.duration
        }
        guard cursor.seconds > 0 else { throw Failed(errorDescription: "Nothing is left after trimming and cutting.") }

        let blurs = self.blurs, clicks = self.clicks, timeline = segments
        let video = AVMutableVideoComposition(asset: composition) { request in
            var image = request.sourceImage
            let extent = image.extent
            // Blur boxes, in the picture's own coordinates (Core Image's origin is at the bottom).
            for box in blurs {
                let rect = CGRect(x: extent.minX + box.minX * extent.width, y: extent.minY + (1 - box.maxY) * extent.height,
                                  width: box.width * extent.width, height: box.height * extent.height)
                let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 24).cropped(to: rect)
                image = blurred.composited(over: image)
            }
            // Zoom toward a click: in over 0.4 s before it, held, out by 1.2 s after.
            let t = request.compositionTime.seconds
            if !clicks.isEmpty, let segment = timeline.last(where: { $0.start <= t + 0.0001 }) {
                let sourceTime = segment.source + (t - segment.start)
                var strength: Double = 0
                var focus = CGPoint(x: 0.5, y: 0.5)
                for click in clicks {
                    let d = sourceTime - click.time
                    let s: Double = d < -0.4 ? 0 : d < 0 ? (d + 0.4) / 0.4 : d < 0.8 ? 1 : d < 1.2 ? 1 - (d - 0.8) / 0.4 : 0
                    if s > strength { strength = s; focus = click.point }
                }
                if strength > 0 {
                    let eased = strength * strength * (3 - 2 * strength)
                    let scale = 1 + 0.6 * eased
                    let fx = extent.minX + focus.x * extent.width, fy = extent.minY + (1 - focus.y) * extent.height
                    // Keep the zoomed picture covering the frame.
                    let cropW = extent.width / scale, cropH = extent.height / scale
                    let x = min(max(fx - cropW / 2, extent.minX), extent.maxX - cropW)
                    let y = min(max(fy - cropH / 2, extent.minY), extent.maxY - cropH)
                    image = image.cropped(to: CGRect(x: x, y: y, width: cropW, height: cropH))
                        .transformed(by: CGAffineTransform(translationX: -x, y: -y).concatenating(CGAffineTransform(scaleX: scale, y: scale)))
                        .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                }
            }
            request.finish(with: image.cropped(to: extent), context: nil)
        }

        let output = FileManager.default.temporaryDirectory.appending(path: "Zephydian Export \(UUID().uuidString.prefix(6)).mp4")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failed(errorDescription: "The video couldn't be prepared.")
        }
        session.videoComposition = video
        session.outputURL = output
        session.outputFileType = .mp4
        nonisolated(unsafe) let exporting = session
        let watcher = Task.detached {
            while !Task.isCancelled {
                progress(Double(exporting.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporting.exportAsynchronously { continuation.resume() }
        }
        watcher.cancel()
        guard session.status == .completed else {
            throw Failed(errorDescription: session.error?.localizedDescription ?? "The export didn't finish.")
        }
        progress(1)
        return output
    }

    /// A GIF from a movie, at `fps` frames a second and at most `width` pixels wide.
    static func gif(from movie: URL, to destination: URL, width: Int, fps: Double = 12, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: movie)
        let seconds = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: width, height: width * 4)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        let count = max(1, Int(seconds * fps))
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw Failed(errorDescription: "The GIF couldn't be created there.")
        }
        CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            if let (image, _) = try? await generator.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600)) {
                CGImageDestinationAddImage(output, image, frame)
            }
            if i % 6 == 0 { progress(Double(i) / Double(count)) }
        }
        guard CGImageDestinationFinalize(output) else { throw Failed(errorDescription: "The GIF couldn't be written.") }
    }
}

// MARK: - The editor's window

private struct EditorView: View {
    let model: EditorModel
    let close: () -> Void
    @State private var gifWidth = 720
    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 12) {
            videoArea
            timeline
            controls
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
        .overlay {
            if let exporting = model.exporting {
                VStack(spacing: 10) {
                    Text(exporting).font(.headline)
                    ProgressView(value: model.progress).frame(width: 220)
                }
                .padding(24)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), fallback: .regularMaterial)
            }
        }
    }

    /// The video, with the blur boxes over it (drawn by dragging while "Blur" is on).
    private var videoArea: some View {
        VideoPlayer(player: model.player)
            .overlay {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(model.blurs.enumerated()), id: \.offset) { index, box in
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .overlay(Rectangle().strokeBorder(.tint, lineWidth: 1.5))
                                .frame(width: box.width * proxy.size.width, height: box.height * proxy.size.height)
                                .overlay(alignment: .topTrailing) {
                                    Button { model.blurs.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain).padding(3)
                                        .accessibilityLabel("Remove this blur")
                                }
                                .offset(x: box.minX * proxy.size.width, y: box.minY * proxy.size.height)
                        }
                        if let start = dragStart, let now = dragNow {
                            Rectangle().strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                                .frame(width: abs(now.x - start.x), height: abs(now.y - start.y))
                                .offset(x: min(start.x, now.x), y: min(start.y, now.y))
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .allowsHitTesting(model.drawingBlur || !model.blurs.isEmpty)
                    .gesture(model.drawingBlur ? DragGesture(minimumDistance: 4)
                        .onChanged { value in dragStart = value.startLocation; dragNow = value.location }
                        .onEnded { value in
                            let a = value.startLocation, b = value.location
                            let rect = CGRect(x: min(a.x, b.x) / proxy.size.width, y: min(a.y, b.y) / proxy.size.height,
                                              width: abs(b.x - a.x) / proxy.size.width, height: abs(b.y - a.y) / proxy.size.height)
                            if rect.width > 0.01, rect.height > 0.01 { model.blurs.append(rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))) }
                            dragStart = nil; dragNow = nil
                        } : nil)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .aspectRatio(16 / 10, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The frames strip with the trim handles, the cut-out parts and the playhead.
    private var timeline: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let x: (Double) -> CGFloat = { model.duration > 0 ? CGFloat($0 / model.duration) * width : 0 }
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(max(model.thumbnails.count, 1)), height: 56).clipped()
                    }
                }
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                // Outside the trim, and cut-out parts: dimmed.
                Rectangle().fill(.black.opacity(0.55)).frame(width: x(model.trimStart), height: 56)
                Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, width - x(model.trimEnd)), height: 56).offset(x: x(model.trimEnd))
                ForEach(Array(model.cuts.enumerated()), id: \.offset) { _, cut in
                    Rectangle().fill(.red.opacity(0.45)).frame(width: max(2, x(cut.upperBound) - x(cut.lowerBound)), height: 56)
                        .offset(x: x(cut.lowerBound))
                }
                if let markIn = model.markIn {
                    Rectangle().fill(.tint).frame(width: 2, height: 64).offset(x: x(markIn))
                }
                Rectangle().fill(.white).frame(width: 2, height: 64).offset(x: x(model.time)).shadow(radius: 1)
                handle(at: x(model.trimStart)) { value in
                    model.trimStart = min(max(0, Double(value / width) * model.duration), model.trimEnd - 0.2)
                    model.seek(model.trimStart)
                }
                handle(at: x(model.trimEnd) - 10) { value in
                    model.trimEnd = max(min(model.duration, Double((value + 10) / width) * model.duration), model.trimStart + 0.2)
                    model.seek(model.trimEnd)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in model.seek(Double(location.x / width) * model.duration) }
            .coordinateSpace(name: "timeline")
        }
        .frame(height: 64)
    }

    private func handle(at x: CGFloat, moved: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(.tint)
            .frame(width: 10, height: 64)
            .overlay(Capsule().fill(.white).frame(width: 2, height: 22))
            .offset(x: x)
            .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { moved($0.location.x) })
            .accessibilityLabel("Trim handle")
    }

    private var controls: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Text("\(format(model.keptLength)) of \(format(model.duration))")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            Divider().frame(height: 18)
            if let markIn = model.markIn {
                Button("Cut Out \(format(markIn))–\(format(model.time))") {
                    let range = min(markIn, model.time)...max(markIn, model.time)
                    if range.upperBound - range.lowerBound > 0.05 { model.cuts.append(range) }
                    model.markIn = nil
                }
                Button("Cancel") { model.markIn = nil }
            } else {
                Button { model.markIn = model.time } label: { Label("Cut a Part", systemImage: "scissors") }
                    .help("Marks the start here; move the playhead to the end, then Cut Out")
            }
            if !model.cuts.isEmpty {
                Button("Undo Cut") { model.cuts.removeLast() }
            }
            Toggle(isOn: $model.drawingBlur) { Label("Blur", systemImage: "eye.slash") }
                .toggleStyle(.button)
                .help("Drag over the video to blur that area for the whole recording")
            Toggle("Zoom on clicks", isOn: $model.autoZoom)
                .disabled(model.recording.clicks.isEmpty)
                .help(model.recording.clicks.isEmpty ? "No clicks were recorded" : "Zoom in where you clicked")
            Spacer()
            Picker("GIF width", selection: $gifWidth) {
                Text("480 px").tag(480); Text("720 px").tag(720); Text("1080 px").tag(1080)
            }
            .labelsHidden().fixedSize()
            Button("Save GIF…") { model.export(gif: true, gifWidth: gifWidth) }
            Button("Save Video…") { model.export(gif: false) }.keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .disabled(model.exporting != nil)
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
