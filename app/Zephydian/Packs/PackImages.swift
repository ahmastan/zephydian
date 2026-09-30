import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// Images an image editor works on (the `images.edit` capability, SDK 3): a screenshot handed over
/// by Screenshot, an image file the person opened, or a picture pasted from the clipboard. Packs
/// only see ids ("image:<id>"), which they draw with `g.image`. The pixels never reach JavaScript.
/// Kept in memory for this session; the oldest go when there are too many.
final class PackImages {
    enum Source: Equatable {
        /// A screenshot from this session (its id in `ScreenCapture`).
        case screenshot(String)
        /// A file the person picked. The sandbox lets the app write it back while it's running.
        case file(URL)
        /// Pasted from the clipboard: it has no place of its own yet.
        case clipboard
    }

    struct Entry {
        let id: String
        let packID: String
        let image: CGImage
        let source: Source
        var name: String
        /// The picture as an NSImage for drawing (made once).
        let picture: NSImage
    }

    static let maxEntries = 24

    private unowned let services: PackServices
    private var entries: [Entry] = []

    init(services: PackServices) { self.services = services }

    func entry(_ id: String) -> Entry? {
        let key = id.hasPrefix("image:") ? String(id.dropFirst(6)) : id
        return entries.first { $0.id == key }
    }

    /// Adds an image and returns its id (without the "image:" prefix).
    @discardableResult
    func add(_ image: CGImage, source: Source, name: String, packID: String) -> String {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        entries.append(Entry(id: id, packID: packID, image: image, source: source, name: name, picture: picture))
        // Drop the oldest ones no window is showing.
        while entries.count > Self.maxEntries,
              let old = entries.firstIndex(where: { !services.windows.isShowing(image: $0.id) }) {
            entries.remove(at: old)
        }
        return id
    }

    func forget(_ id: String) {
        entries.removeAll { "image:\($0.id)" == id || $0.id == id }
    }

    func removeData(packID: String) {
        entries.removeAll { $0.packID == packID }
    }

    /// `{ id, name, width, height, source, saved }` for the pack.
    func info(_ entry: Entry) -> [String: Any] {
        let source: String, saved: Any
        switch entry.source {
        case .screenshot(let shot):
            source = "screenshot"
            saved = services.capture.shot(shot)?.savedURL?.lastPathComponent ?? NSNull()
        case .file(let url):
            source = "file"
            saved = url.lastPathComponent
        case .clipboard:
            source = "clipboard"
            saved = NSNull()
        }
        return ["id": "image:\(entry.id)", "name": entry.name, "width": entry.image.width, "height": entry.image.height,
                "source": source, "saved": saved]
    }

    /// A picture a pack may draw: its own "image:<id>", or "screenshot:<id>" for packs that take
    /// screenshots or edit images.
    func picture(_ name: String, packID: String, capabilities: Set<String>) -> NSImage? {
        if name.hasPrefix("image:") {
            guard capabilities.contains("images.edit"), let entry = entry(name), entry.packID == packID else { return nil }
            return entry.picture
        }
        if name.hasPrefix("screenshot:") {
            guard !capabilities.isDisjoint(with: ["screen.capture", "images.edit"]) else { return nil }
            return services.capture.thumbnail(String(name.dropFirst(11)))
        }
        return nil
    }

    // MARK: Getting images in

    /// A screenshot from this session, copied in (the copy stays the same while the shot changes).
    func fromScreenshot(_ shotID: String, packID: String) -> String? {
        guard let shot = services.capture.shot(shotID) else { return nil }
        return add(shot.image, source: .screenshot(shotID), name: "Screenshot \(shot.date.formatted(date: .omitted, time: .standard))", packID: packID)
    }

    static let openTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]

    /// The open dialog for one image. `done` gets the new id, or nil if cancelled or unreadable.
    func open(packID: String, done: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.openTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to mark up."
        panel.level = .statusBar + 1
        services.holdPanel()
        NSApp.activate()
        nonisolated(unsafe) let done = done
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                self?.services.releasePanel()
                guard let self, response == .OK, let url = panel.url,
                      let image = Self.load(url) else { return done(nil) }
                done(self.add(image, source: .file(url), name: url.deletingPathExtension().lastPathComponent, packID: packID))
            }
        }
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// The image on the clipboard, if there is one. Read only when the person clicks Paste.
    func paste(packID: String, pasteboard: NSPasteboard = .general) -> String? {
        guard let picture = NSImage(pasteboard: pasteboard),
              let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // An NSImage's cgImage may be scaled to its point size; take the largest bitmap there is.
        let best = picture.representations.compactMap { ($0 as? NSBitmapImageRep)?.cgImage }
            .max { $0.width * $0.height < $1.width * $1.height } ?? image
        return add(best, source: .clipboard, name: "Pasted image", packID: packID)
    }

    // MARK: Rendering

    /// Largest side of a rendered image, and largest number of pixels.
    nonisolated static let maxSide = 16_384.0
    nonisolated static let maxPixels = 80_000_000.0

    /// A pack drawing ({ width, height, scale, shapes }) as a bitmap, one pixel per unit at scale 1.
    /// `image` resolves the names used in `g.image` (the editor's own pictures).
    static func render(drawingJSON json: String, image: @escaping (String) -> NSImage?) -> CGImage? {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shapes = try? PackRuntime.parseShapes(o["shapes"] as? [Any] ?? []) else { return nil }
        let width = ((o["width"] as? NSNumber)?.doubleValue ?? 0).rounded()
        let height = ((o["height"] as? NSNumber)?.doubleValue ?? 0).rounded()
        let scale = min(max((o["scale"] as? NSNumber)?.doubleValue ?? 1, 0.1), 4)
        guard width >= 1, height >= 1, width * scale <= maxSide, height * scale <= maxSide,
              width * height * scale * scale <= maxPixels else { return nil }
        let view = Canvas { context, size in
            PackView.render(shapes, in: context, size: size, accent: Color(nsColor: .controlAccentColor), image: image)
        }
        .frame(width: width, height: height)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }

    /// PNG, or JPEG for "jpeg" (and .jpg/.jpeg files).
    static func encode(_ image: CGImage, format: String) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        switch format.lowercased() {
        case "jpeg", "jpg": return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        case "tiff", "tif": return rep.representation(using: .tiff, properties: [:])
        default: return rep.representation(using: .png, properties: [:])
        }
    }

    // MARK: Pixelate

    /// The same picture in square blocks `block` pixels wide (CoreImage's CIPixellate), cached per
    /// picture and size, so the editor can redraw every frame.
    /// Holds the source picture too, so a key can't come back for a different picture.
    private static var pixelCache: [(source: NSImage, block: Int, result: NSImage)] = []

    static func pixelated(_ picture: NSImage, block: Double) -> NSImage? {
        let size = Int(block.rounded())
        if let cached = pixelCache.first(where: { $0.source === picture && $0.block == size }) { return cached.result }
        guard let cg = picture.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: "CIPixellate") else { return nil }
        let input = CIImage(cgImage: cg)
        // Clamp first, so the blocks along the edges aren't faded by the transparent outside.
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(2, block), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let result = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: input.extent) else { return nil }
        let image = NSImage(cgImage: result, size: picture.size)
        pixelCache.append((picture, size, image))
        if pixelCache.count > 6 { pixelCache.removeFirst() }
        return image
    }
}
