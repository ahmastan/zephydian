import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Recording settings, kept per capture utility.
struct RecordPrefs: Codable, Equatable {
    var systemAudio = true
    var microphone = false
    var fps = 60
    var showsPointer = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        systemAudio = try c.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? true
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? false
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        showsPointer = try c.decodeIfPresent(Bool.self, forKey: .showsPointer) ?? true
    }
}

extension ScreenCapture {
    func recordPrefs(_ packID: String) -> RecordPrefs {
        services.defaults.data(forKey: "pack.\(packID).screenshot.recordPrefs").flatMap { try? JSONDecoder().decode(RecordPrefs.self, from: $0) } ?? RecordPrefs()
    }

    func setRecordPrefs(_ prefs: RecordPrefs, packID: String) {
        services.defaults.set(try? JSONEncoder().encode(prefs), forKey: "pack.\(packID).screenshot.recordPrefs")
    }
}

/// A finished recording: the movie file, what was recorded, and where the clicks were (for automatic zoom).
struct Recording: Identifiable {
    let id: String
    let url: URL
    let date: Date
    /// Seconds from the start, and the click's position in the picture (0…1, top-left origin).
    var clicks: [(time: Double, point: CGPoint)]
}

/// Records an area, a window or a display with ScreenCaptureKit, with the Mac's sound and the
/// microphone as separate tracks. A small pill shows the time and a Stop button (the capture
/// shortcut stops it too). When it ends, the recording opens in the editor.
@MainActor
final class ScreenRecorder {
    enum Target { case area, window, screen }

    private unowned let capture: ScreenCapture
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var pill: RecordingPill?
    private var clickMonitors: [Any] = []
    private var clicks: [(time: Double, point: CGPoint)] = []
    private var started = Date()
    /// The recorded rectangle in AppKit coordinates (for placing clicks).
    private var area: CGRect = .zero
    private(set) var recordings: [Recording] = []
    let editors = RecordingEditors()

    var isRecording: Bool { stream != nil }

    init(capture: ScreenCapture) { self.capture = capture }

    func start(packID: String, target: Target) {
        guard !isRecording, capture.checkPermission() else { return }
        let prefs = capture.recordPrefs(packID)
        if prefs.microphone, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        Task { @MainActor in
            do {
                try await begin(target: target, prefs: prefs, packID: packID)
            } catch {
                CaptureToast.show("Couldn't start recording", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription)
                cleanUp()
            }
        }
    }

    private func begin(target: Target, prefs: RecordPrefs, packID: String) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        var scale: CGFloat = 2
        switch target {
        case .area:
            guard let rect = await capture.pickArea(),
                  let (display, screen) = ScreenCapture.display(at: NSPoint(x: rect.midX, y: rect.midY), in: content) else { return }
            scale = screen.backingScaleFactor
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            area = rect
        case .window:
            let windows = content.windows.filter { $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width > 40 && $0.frame.height > 30
                && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
            guard let window = await capture.pickWindow(windows) else { return }
            filter = SCContentFilter(desktopIndependentWindow: window)
            area = ScreenCapture.cocoaRect(window.frame)
            scale = NSScreen.screens.first { $0.frame.intersects(area) }?.backingScaleFactor ?? 2
        case .screen:
            guard let (display, screen) = ScreenCapture.display(at: NSEvent.mouseLocation, in: content) else { return }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            area = screen.frame
            scale = screen.backingScaleFactor
        }
        // Even sizes (video encoders need them), at most 4K wide.
        var width = Int(area.width * scale), height = Int(area.height * scale)
        if width > 3840 { height = height * 3840 / width; width = 3840 }
        width -= width % 2
        height -= height % 2
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(prefs.fps))
        config.queueDepth = 6
        config.showsCursor = prefs.showsPointer
        config.capturesAudio = prefs.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        let microphone: Bool
        if #available(macOS 15, *), prefs.microphone {
            config.captureMicrophone = true
            microphone = true
        } else {
            microphone = false
        }

        let url = FileManager.default.temporaryDirectory.appending(path: "Zephydian Recording \(UUID().uuidString.prefix(6)).mov")
        let writer = try RecordingWriter(url: url, width: width, height: height, systemAudio: prefs.systemAudio, microphone: microphone)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        if prefs.systemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
        if #available(macOS 15, *), microphone { try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue) }
        await capture.wait(capture.prefs(packID).delay, on: NSScreen.screens.first { $0.frame.intersects(area) } ?? NSScreen.main!)
        try await stream.startCapture()
        self.stream = stream
        self.writer = writer
        started = Date()
        clicks = []
        watchClicks()
        pill = RecordingPill(started: started, stop: { [weak self] in self?.stop() }, discard: { [weak self] in self?.stop(keep: false) })
    }

    /// Stops; the recording opens in the editor (or is thrown away).
    func stop(keep: Bool = true) {
        guard let stream, let writer else { return }
        let clicks = self.clicks
        cleanUp()
        Task { @MainActor in
            try? await stream.stopCapture()
            let url = await writer.finish()
            guard keep, let url else {
                if let url { try? FileManager.default.removeItem(at: url) }
                return
            }
            let recording = Recording(id: String(UUID().uuidString.prefix(8)).lowercased(), url: url, date: Date(), clicks: clicks)
            recordings.insert(recording, at: 0)
            capture.services.changed()
            editors.open(recording)
        }
    }

    func recording(_ id: String) -> Recording? { recordings.first { $0.id == id } }

    private func cleanUp() {
        stream = nil
        writer = nil
        pill?.close()
        pill = nil
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
    }

    /// Clicks inside the recorded area, for automatic zoom in the editor.
    private func watchClicks() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let point = NSEvent.mouseLocation
                guard self.area.contains(point) else { return }
                let normalized = CGPoint(x: (point.x - self.area.minX) / self.area.width, y: (self.area.maxY - point.y) / self.area.height)
                self.clicks.append((Date().timeIntervalSince(self.started), normalized))
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: handler) { clickMonitors.append(global) }
    }
}

/// Writes the stream's video and audio into a movie file, on its own queue.
nonisolated final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.ahmastan.zephydian.recording")
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let mic: AVAssetWriterInput?
    private var startedSession = false
    private let url: URL

    init(url: URL, width: Int, height: Int, systemAudio: Bool, microphone: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(4_000_000, width * height * 6)],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000]
        if systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audio = input
        } else { audio = nil }
        if microphone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            mic = input
        } else { mic = nil }
        super.init()
        writer.startWriting()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid, writer.status == .writing else { return }
        switch type {
        case .screen:
            // Only frames with new content (idle frames carry no picture).
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if !startedSession {
                writer.startSession(atSourceTime: buffer.presentationTimeStamp)
                startedSession = true
            }
            if video.isReadyForMoreMediaData { video.append(buffer) }
        case .audio:
            if startedSession, let audio, audio.isReadyForMoreMediaData { audio.append(buffer) }
        default:
            if startedSession, let mic, mic.isReadyForMoreMediaData { mic.append(buffer) }
        }
    }

    /// Closes the file. nil if nothing was recorded.
    func finish() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard startedSession else {
                    writer.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                video.markAsFinished()
                audio?.markAsFinished()
                mic?.markAsFinished()
                writer.finishWriting { [self] in
                    continuation.resume(returning: writer.status == .completed ? url : nil)
                }
            }
        }
    }
}

/// The pill at the top of the screen while recording: a red dot, the time, Stop and discard.
/// Left out of the recording itself, like all of Zephydian's windows.
@MainActor
private final class RecordingPill {
    @Observable final class Model { var elapsed = 0 }
    private let panel: NSPanel
    private let model = Model()
    private var timer: Timer?

    init(started: Date, stop: @escaping () -> Void, discard: @escaping () -> Void) {
        let settings = Features.shared.appSettings ?? SettingsStore()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.midX - 110, y: screen.visibleFrame.maxY - 56, width: 220, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = settings.appearance.nsAppearance
        panel.contentView = NSHostingView(rootView: PillView(model: model, stop: stop, discard: discard).environment(settings).tint(settings.accentColor))
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.elapsed = Int(Date().timeIntervalSince(started)) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func close() {
        timer?.invalidate()
        panel.orderOut(nil)
    }

    private struct PillView: View {
        let model: Model
        let stop: () -> Void
        let discard: () -> Void

        var body: some View {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10).accessibilityHidden(true)
                Text(String(format: "%d:%02d", model.elapsed / 60, model.elapsed % 60))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .accessibilityLabel("Recording, \(model.elapsed) seconds")
                Spacer()
                Button(action: discard) { Image(systemName: "trash") }
                    .glassIconButtonStyle()
                    .help("Stop and throw it away")
                    .accessibilityLabel("Discard the recording")
                Button("Stop", action: stop).prominentButtonStyle().controlSize(.small)
                    .help("Stop and edit (or press the capture shortcut)")
            }
            .padding(.horizontal, 14)
            .frame(width: 220, height: 44)
            .glassSurface(in: Capsule(), fallback: .regularMaterial)
        }
    }
}
