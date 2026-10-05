import AppKit
import ScreenCaptureKit

/// Pictures of other apps' windows, taken with ScreenCaptureKit (Screen Recording permission).
/// They live only in memory: the last picture of each window shows instantly the next time,
/// while a fresh one is taken. Without the permission nothing is captured, and callers show the
/// app's icon instead.
@Observable
final class WindowThumbnails {
    static let shared = WindowThumbnails()

    private(set) var images: [CGWindowID: NSImage] = [:]

    @ObservationIgnored private var order: [CGWindowID] = []
    @ObservationIgnored private var content: (windows: [CGWindowID: SCWindow], at: Date)?
    @ObservationIgnored private var capturing: Set<CGWindowID> = []

    /// The pictures kept take at most this much memory (the oldest go first).
    private let byteLimit = 16 * 1024 * 1024
    @ObservationIgnored private var bytes: [CGWindowID: Int] = [:]

    func image(for id: CGWindowID) -> NSImage? { images[id] }

    /// Takes fresh pictures of these windows, `maxSide` points on their longest side (doubled for Retina).
    func refresh(_ ids: [CGWindowID], maxSide: CGFloat) {
        guard Permissions.shared.isGranted(.screenRecording) else { return }
        let wanted = ids.filter { !capturing.contains($0) }
        guard !wanted.isEmpty else { return }
        capturing.formUnion(wanted)
        Task { @MainActor in
            defer { capturing.subtract(wanted) }
            guard let windows = await shareableWindows() else { return }
            for id in wanted {
                guard let window = windows[id] else { continue }
                if let image = await Self.capture(window, maxSide: maxSide) { store(image, for: id) }
            }
        }
    }

    /// A full-size picture of one window (for peeking at it).
    func capture(_ id: CGWindowID, maxSide: CGFloat) async -> NSImage? {
        guard Permissions.shared.isGranted(.screenRecording), let window = await shareableWindows()?[id] else { return nil }
        return await Self.capture(window, maxSide: maxSide)
    }

    /// Forgets everything (the feature was switched off).
    func clear() {
        images = [:]
        order = []
        bytes = [:]
        content = nil
    }

    // MARK: Private

    /// ScreenCaptureKit's window list, reused for a moment since asking costs a little.
    private func shareableWindows() async -> [CGWindowID: SCWindow]? {
        if let content, Date().timeIntervalSince(content.at) < 1.5 { return content.windows }
        guard let shareable = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return nil }
        let windows = Dictionary(shareable.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        content = (windows, Date())
        return windows
    }

    private static func capture(_ window: SCWindow, maxSide: CGFloat) async -> NSImage? {
        let size = window.frame.size
        guard size.width > 1, size.height > 1 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height)) * 2
        let config = SCStreamConfiguration()
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
    }

    private func store(_ image: NSImage, for id: CGWindowID) {
        images[id] = image
        let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? Int(image.size.width * image.size.height * 4)
        bytes[id] = pixels * 4
        order.removeAll { $0 == id }
        order.append(id)
        while bytes.values.reduce(0, +) > byteLimit, order.count > 1 {
            let oldest = order.removeFirst()
            images[oldest] = nil
            bytes[oldest] = nil
        }
    }
}
