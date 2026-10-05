import AppKit
import ScreenCaptureKit
import SwiftUI

/// The capture modes beyond plain screenshots (19.10): the capture bar, copying text and QR codes,
/// picking a color, scrolling screenshots. Screen recording is in ScreenRecorder.swift.
extension ScreenCapture {
    enum BarMode: Int, CaseIterable, Identifiable {
        case screenshot, record, text, color
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .screenshot: "Screenshot"
            case .record: "Record"
            case .text: "Copy Text"
            case .color: "Color"
            }
        }
        var symbol: String {
            switch self {
            case .screenshot: "camera.viewfinder"
            case .record: "record.circle"
            case .text: "text.viewfinder"
            case .color: "eyedropper"
            }
        }
    }

    /// The capture shortcut: opens the capture bar (or takes a shot at once, if that's the setting),
    /// or stops a recording in progress.
    func openBar(packID: String) {
        if recorder.isRecording { recorder.stop(); return }
        if let bar { bar.dismiss(); return }
        guard !busy else { return }
        let prefs = prefs(packID)
        if prefs.shortcutAction == "instant" {
            let mode = Mode(rawValue: prefs.instantMode) ?? .area
            capture(packID: packID, mode: mode) { _, error in
                if let error, !error.isEmpty { CaptureToast.show(error, symbol: "exclamationmark.triangle.fill") }
            }
            return
        }
        services.hidePanel()
        bar = CaptureBar(capture: self, packID: packID)
    }

    // MARK: Pictures of each screen, for the magnifier

    /// Each screen as it looks now (Zephydian's own windows left out), by its frame.
    func stills(showsCursor: Bool = false) async -> [(NSRect, CGImage)] {
        guard hasPermission, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [] }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var out: [(NSRect, CGImage)] = []
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }) else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = showsCursor
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                out.append((screen.frame, image))
            }
        }
        return out
    }

    /// A picture of an area chosen on screen (nil if cancelled).
    func captureArea(showsCursor: Bool = false) async -> CGImage? {
        guard let rect = await pickArea() else { return nil }
        return await image(of: rect, showsCursor: showsCursor)
    }

    /// A picture of a rectangle of the screen (AppKit coordinates).
    func image(of rect: CGRect, showsCursor: Bool = false) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let (display, screen) = Self.display(at: NSPoint(x: rect.midX, y: rect.midY), in: content) else { return nil }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        var prefs = Prefs()
        prefs.pointer = showsCursor
        if case .success(let image) = await shoot(SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
                                                  rect: local, size: rect.size, scale: screen.backingScaleFactor, prefs: prefs) {
            return image
        }
        return nil
    }

    // MARK: Copy text

    /// Select an area: its text (or a QR code's link) is copied, read on this Mac.
    func copyText() {
        guard checkPermission() else { return }
        Task { @MainActor in
            guard let image = await captureArea() else { return }
            let found = await ScreenText.read(image)
            let board = NSPasteboard.general
            if let code = found.code {
                board.clearContents()
                board.setString(code, forType: .string)
                CaptureToast.show("Copied the code's contents", symbol: "qrcode", detail: String(code.prefix(60)))
            } else if !found.text.isEmpty {
                board.clearContents()
                board.setString(found.text, forType: .string)
                let lines = found.text.components(separatedBy: "\n").count
                CaptureToast.show(lines == 1 ? "Copied the text" : "Copied \(lines) lines", symbol: "text.viewfinder",
                                  detail: String(found.text.prefix(60)))
            } else {
                CaptureToast.show("No text found there", symbol: "text.viewfinder")
            }
        }
    }

    // MARK: Pick a color

    /// Click anywhere: that pixel's color is copied as hex, with a magnifier to aim.
    func pickColor() {
        guard checkPermission() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let stills = await self.stills()
            let result: SelectionOverlay.Result = await withCheckedContinuation { continuation in
                self.overlay = SelectionOverlay(mode: .point, windows: [], accent: self.accent, stills: stills) { [weak self] result in
                    self?.overlay = nil
                    continuation.resume(returning: result)
                }
            }
            guard let color = result.color?.usingColorSpace(.sRGB) else { return }
            let hex = Self.hex(color)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            CaptureToast.show("Copied \(hex)", symbol: "eyedropper",
                              detail: String(format: "rgb(%d, %d, %d)", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255)))
        }
    }

    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "" }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    // MARK: Scrolling screenshots

    /// Select an area: Zephydian scrolls it down step by step and stitches one long picture, until the
    /// end of the page (or Esc / Done). Scrolling for you needs Accessibility.
    func scrollingCapture(packID: String) {
        guard checkPermission() else { return }
        guard Permissions.shared.isGranted(.accessibility) else {
            Permissions.shared.request(.accessibility)
            CaptureToast.show("Allow Accessibility to scroll for you", symbol: "hand.raised.fill")
            return
        }
        Task { @MainActor in
            guard let rect = await pickArea(), let first = await image(of: rect) else { return }
            let stop = ScrollStopper()
            let stitcher = Stitcher(first: first)
            let center = SystemWindows.serverPoint(NSPoint(x: rect.midX, y: rect.midY))
            var still = 0
            for _ in 0..<60 {
                if stop.stopped { break }
                Self.scroll(at: center, by: rect.height * 0.7)
                try? await Task.sleep(for: .milliseconds(380))
                guard let frame = await image(of: rect) else { break }
                let moved = await Task.detached { stitcher.add(frame) }.value
                if moved == 0 { still += 1; if still >= 2 { break } } else { still = 0 }
            }
            stop.close()
            guard let result = stitcher.image else { return }
            if prefs(packID).sound { Self.shutter() }
            let id = keep(result, packID: packID)
            showPreview(id, packID: packID)
        }
    }

    /// Scrolls the page under a point (window-server coordinates) down by about `distance` points.
    private static func scroll(at point: CGPoint, by distance: CGFloat) {
        let steps = 6
        for _ in 0..<steps {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: Int32(-(distance / CGFloat(steps)).rounded()), wheel2: 0, wheel3: 0) else { continue }
            event.location = point
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// Screen Recording is needed for every capture mode.
    func checkPermission() -> Bool {
        guard hasPermission else {
            requestPermission()
            CaptureToast.show("Allow Zephydian under Screen Recording", symbol: "lock.fill", detail: "System Settings → Privacy & Security")
            return false
        }
        return true
    }
}

/// "Scrolling… Esc or Done to stop": the little bar shown during a scrolling capture.
@MainActor
private final class ScrollStopper {
    private(set) var stopped = false
    private let panel: NSPanel
    private var monitor: Any?

    init() {
        let settings = Features.shared.appSettings ?? SettingsStore()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.midX - 140, y: screen.visibleFrame.maxY - 70, width: 280, height: 46),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = settings.appearance.nsAppearance
        weak var weakSelf: ScrollStopper?
        panel.contentView = NSHostingView(rootView: HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Scrolling… Esc to stop").font(.system(size: 13, weight: .medium))
            Spacer()
            Button("Done") { weakSelf?.stopped = true }.prominentButtonStyle().controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(width: 280, height: 46)
        .glassSurface(in: Capsule(), fallback: .regularMaterial)
        .environment(settings)
        .tint(settings.accentColor))
        panel.orderFrontRegardless()
        weakSelf = self
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { MainActor.assumeIsolated { self?.stopped = true } }
        }
    }

    func close() {
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Stitches screen frames of a scrolling page into one tall picture: each new frame is matched
/// against the last one to find how far the page moved, and only the new rows are added.
nonisolated final class Stitcher: @unchecked Sendable {
    private var width = 0
    private var rows: [UInt8] = []          // RGBA, all rows so far
    private var previous: [[Float]] = []    // the last frame, small and gray, row by row
    private static let sampleWidth = 64

    init(first: CGImage) {
        guard let (pixels, w, h) = Self.rgba(first) else { return }
        width = w
        rows = pixels
        previous = Self.gray(pixels, width: w, height: h)
    }

    /// Adds a frame. Returns how many pixel rows the page moved (0: it didn't, or no match was found).
    func add(_ frame: CGImage) -> Int {
        guard let (pixels, w, h) = Self.rgba(frame), w == width, h == previous.count else { return 0 }
        let small = Self.gray(pixels, width: w, height: h)
        // The shift d where the old frame's rows d… line up with the new frame's rows 0…
        var best = (shift: 0, difference: Float.greatestFiniteMagnitude)
        let minOverlap = max(8, h / 5)
        for d in 1...(h - minOverlap) {
            var total: Float = 0
            let overlap = h - d
            let stride = max(1, overlap / 160)          // enough rows to be sure, quickly
            var count = 0
            var row = 0
            while row < overlap {
                let a = previous[row + d], b = small[row]
                for x in 0..<a.count { total += abs(a[x] - b[x]) }
                count += a.count
                row += stride
            }
            let difference = total / Float(max(count, 1))
            if difference < best.difference { best = (d, difference) }
        }
        previous = small
        guard best.difference < 6, best.shift >= 2 else { return 0 }
        // The rows the old frame didn't have: the new frame's last `shift` rows.
        let start = (h - best.shift) * w * 4
        rows.append(contentsOf: pixels[start..<pixels.count])
        return best.shift
    }

    /// The stitched picture so far.
    var image: CGImage? {
        guard width > 0 else { return nil }
        let height = rows.count / (width * 4)
        guard let provider = CGDataProvider(data: Data(rows) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func rgba(_ image: CGImage) -> ([UInt8], Int, Int)? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (pixels, w, h) : nil
    }

    /// Each row shrunk to a few gray samples, top row first.
    private static func gray(_ pixels: [UInt8], width: Int, height: Int) -> [[Float]] {
        let samples = min(sampleWidth, width)
        return (0..<height).map { y in
            (0..<samples).map { i in
                let x = i * width / samples
                let p = (y * width + x) * 4
                return 0.299 * Float(pixels[p]) + 0.587 * Float(pixels[p + 1]) + 0.114 * Float(pixels[p + 2])
            }
        }
    }
}

// MARK: - The capture bar

/// The bar at the top of the screen (⇧⌘6): Screenshot · Record · Copy Text · Color (also keys 1–4),
/// then where to capture. Esc closes it.
@MainActor
final class CaptureBar {
    @Observable final class Model {
        var mode = ScreenCapture.BarMode.screenshot
        var delay = 0
        var systemAudio = true
        var microphone = false
        /// Freeze the screen for this shot (starts from the Freeze setting).
        var freeze = false
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private unowned let capture: ScreenCapture
    private let packID: String
    private let model = Model()
    private let panel: KeyPanel
    private var keyMonitor: Any?
    private var freezing: Task<Void, Never>?

    init(capture: ScreenCapture, packID: String) {
        self.capture = capture
        self.packID = packID
        let prefs = capture.prefs(packID), record = capture.recordPrefs(packID)
        model.delay = prefs.delay
        model.systemAudio = record.systemAudio
        model.microphone = record.microphone
        model.freeze = prefs.freeze
        let settings = Features.shared.appSettings ?? SettingsStore()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 520, height: 104)
        panel = KeyPanel(contentRect: NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12,
                                             width: size.width, height: size.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu   // above a frozen screen
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = settings.appearance.nsAppearance
        panel.contentView = NSHostingView(rootView: BarView(model: model, choose: { [weak self] in self?.choose($0) },
                                                            close: { [weak self] in self?.dismiss() },
                                                            setFreeze: { [weak self] in self?.setFreeze($0) })
            .environment(settings)
            .tint(settings.accentColor))
        panel.makeKeyAndOrderFront(nil)
        if model.freeze { setFreeze(true) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.panel else { return false }
                return self.key(event)
            }
            return handled ? nil : event
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.orderOut(nil)
    }

    /// Closes the bar without capturing (Esc, ×, the shortcut again); a frozen screen moves again.
    func dismiss() {
        freezing?.cancel()
        close()
        capture.bar = nil
        capture.unfreeze()
    }

    /// The bar's Freeze toggle: holds the screen still now (or lets it move again).
    private func setFreeze(_ on: Bool) {
        model.freeze = on
        freezing?.cancel()
        if on {
            let pointer = capture.prefs(packID).pointer
            let capture = capture
            freezing = Task { @MainActor in
                await capture.freeze(showsCursor: pointer)
                // Closed, or switched off again, while the picture was being taken.
                if Task.isCancelled { capture.unfreeze() }
            }
        } else {
            capture.unfreeze()
        }
    }

    private func key(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: dismiss(); return true                                   // Esc
        case 36, 76: choose(model.mode == .record || model.mode == .screenshot ? .area : nil); return true   // Return: area
        default: break
        }
        guard let n = Int(event.charactersIgnoringModifiers ?? ""), (1...4).contains(n), let mode = ScreenCapture.BarMode(rawValue: n - 1) else { return false }
        select(mode)
        return true
    }

    private func select(_ mode: ScreenCapture.BarMode) {
        model.mode = mode
        // Copy Text and Color need no further choice: they start right away.
        if mode == .text || mode == .color { choose(nil) }
    }

    enum Target { case area, window, screen, scrolling }

    private func choose(_ target: Target?) {
        close()
        capture.bar = nil
        // Only screenshots use the frozen screen.
        if model.mode != .screenshot || target == .scrolling { freezing?.cancel(); capture.unfreeze() }
        var prefs = capture.prefs(packID)
        if prefs.delay != model.delay { prefs.delay = model.delay; capture.setPrefs(prefs, packID: packID) }
        var record = capture.recordPrefs(packID)
        record.systemAudio = model.systemAudio
        record.microphone = model.microphone
        capture.setRecordPrefs(record, packID: packID)
        switch (model.mode, target) {
        case (.screenshot, .scrolling): capture.scrollingCapture(packID: packID)
        case (.screenshot, let target):
            let mode: ScreenCapture.Mode = target == .window ? .window : target == .screen ? .screen : .area
            capture.capture(packID: packID, mode: mode, freeze: model.freeze) { _, error in
                if let error, !error.isEmpty { CaptureToast.show(error, symbol: "exclamationmark.triangle.fill") }
            }
        case (.record, let target):
            capture.recorder.start(packID: packID, target: target == .window ? .window : target == .screen ? .screen : .area)
        case (.text, _): capture.copyText()
        case (.color, _): capture.pickColor()
        }
    }

    private struct BarView: View {
        let model: Model
        let choose: (Target?) -> Void
        let close: () -> Void
        let setFreeze: (Bool) -> Void

        var body: some View {
            @Bindable var model = model
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(ScreenCapture.BarMode.allCases) { mode in
                        Button {
                            model.mode = mode
                            if mode == .text || mode == .color { choose(nil) }
                        } label: {
                            Label { Text("\(mode.rawValue + 1)  \(mode.title)") } icon: { Image(systemName: mode.symbol) }
                                .font(.system(size: 12, weight: model.mode == mode ? .semibold : .regular))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background { if model.mode == mode { Capsule().fill(.tint.opacity(0.22)) } }
                        .help(mode == .text ? "Select an area to copy its text" : mode == .color ? "Click anywhere to copy its color" : mode.title)
                    }
                    Spacer(minLength: 4)
                    Button(action: close) { Image(systemName: "xmark") }
                        .glassIconButtonStyle()
                        .help("Close (Esc)")
                        .accessibilityLabel("Close the capture bar")
                }
                HStack(spacing: 8) {
                    switch model.mode {
                    case .screenshot:
                        target("Area", "rectangle.dashed", .area, prominent: true)
                        target("Window", "macwindow", .window)
                        target("Screen", "display", .screen)
                        target("Scrolling", "arrow.up.and.down.text.horizontal", .scrolling)
                        Spacer(minLength: 0)
                        Toggle(isOn: Binding(get: { model.freeze }, set: { setFreeze($0) })) { Image(systemName: "pause.circle") }
                            .toggleStyle(.button).help("Freeze the screen while you pick")
                            .accessibilityLabel("Freeze the screen")
                        Picker("Delay", selection: $model.delay) {
                            Text("No delay").tag(0); Text("3 s").tag(3); Text("5 s").tag(5); Text("10 s").tag(10)
                        }
                        .labelsHidden().fixedSize()
                    case .record:
                        target("Area", "rectangle.dashed", .area, prominent: true)
                        target("Window", "macwindow", .window)
                        target("Screen", "display", .screen)
                        Spacer(minLength: 0)
                        Toggle(isOn: $model.systemAudio) { Image(systemName: "speaker.wave.2") }
                            .toggleStyle(.button).help("Record your Mac's sound")
                            .accessibilityLabel("Record your Mac's sound")
                        Toggle(isOn: $model.microphone) { Image(systemName: "mic") }
                            .toggleStyle(.button).help("Record the microphone")
                            .accessibilityLabel("Record the microphone")
                    case .text, .color:
                        Text(model.mode == .text ? "Select the text on screen…" : "Click a color on screen…")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fallback: .regularMaterial)
        }

        private func target(_ title: String, _ symbol: String, _ target: Target, prominent: Bool = false) -> some View {
            Group {
                if prominent {
                    Button { choose(target) } label: { Label(title, systemImage: symbol) }.prominentButtonStyle()
                } else {
                    Button { choose(target) } label: { Label(title, systemImage: symbol) }.panelButtonStyle()
                }
            }
        }
    }
}

// MARK: - Freeze

/// Every screen covered by a still picture of itself (the Freeze option), so a playing video or an
/// animation holds still while you pick. Above other apps' windows and the menu bar, below the capture
/// bar and the selection overlay; clicks go through to the overlay.
final class FrozenScreens {
    /// Each screen's picture by its frame, at full resolution.
    let stills: [(NSRect, CGImage)]
    private var windows: [NSWindow] = []

    init(_ stills: [(NSRect, CGImage)]) {
        self.stills = stills
        for (frame, image) in stills {
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.animationBehavior = .none
            let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            view.layer?.contents = image
            view.layer?.contentsGravity = .resize
            window.contentView = view
            window.setFrame(frame, display: false)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    /// The part of the frozen picture under a rectangle (AppKit coordinates), from the screen holding its middle.
    func crop(_ rect: NSRect) -> CGImage? {
        let middle = NSPoint(x: rect.midX, y: rect.midY)
        guard let (frame, image) = stills.first(where: { $0.0.contains(middle) }) ?? stills.first else { return nil }
        let part = rect.intersection(frame)
        guard !part.isEmpty else { return nil }
        let scale = CGFloat(image.width) / frame.width
        let pixels = CGRect(x: (part.minX - frame.minX) * scale, y: (frame.maxY - part.maxY) * scale,
                            width: part.width * scale, height: part.height * scale).integral
        return image.cropping(to: pixels)
    }
}
