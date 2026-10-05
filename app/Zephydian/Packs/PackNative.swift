import AppKit
import CoreImage
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// Native helpers behind SDK 2 calls that JavaScriptCore can't do itself: QR codes, text encoding
/// and hashing, turning a drawing into a PNG, the save dialog and the screen color sampler.
/// Packs reach these only through the SDK, and only with the matching capability where one is needed.
enum PackNative {
    // MARK: Text

    nonisolated static func base64Encode(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    /// nil if it isn't Base64 of UTF-8 text.
    nonisolated static func base64Decode(_ s: String) -> String? {
        let cleaned = s.filter { !$0.isWhitespace }
        let padded = cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        return Data(base64Encoded: padded).flatMap { String(data: $0, encoding: .utf8) }
    }

    nonisolated static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: QR codes

    /// The QR code's modules as rows of "0"/"1" (no quiet zone). `level` is L, M, Q or H.
    static func qr(_ text: String, level: String) -> [String]? {
        guard !text.isEmpty, text.utf8.count <= 2000,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue(["L", "M", "Q", "H"].contains(level) ? level : "M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage,
              let cg = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: image.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        // CoreImage adds a 1-module quiet zone on each side; the pack draws its own.
        let n = rep.pixelsWide
        guard n > 2 else { return nil }
        return (1..<(n - 1)).map { y in
            String((1..<(n - 1)).map { x in (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5 ? "1" : "0" })
        }
    }

    // MARK: Drawings as images

    /// A pack drawing ({ width, height, scale, shapes }) as PNG data. Theme colors use the system's
    /// light look and accent, so exported images should use fixed colors.
    static func png(fromDrawingJSON json: String) -> Data? {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shapes = try? PackRuntime.parseShapes(o["shapes"] as? [Any] ?? []) else { return nil }
        let width = min(max((o["width"] as? NSNumber)?.doubleValue ?? 0, 1), 4096)
        let height = min(max((o["height"] as? NSNumber)?.doubleValue ?? 0, 1), 4096)
        let scale = min(max((o["scale"] as? NSNumber)?.doubleValue ?? 2, 1), 4)
        let view = Canvas { context, size in
            PackView.render(shapes, in: context, size: size, accent: Color(nsColor: .controlAccentColor), image: { _ in nil })
        }
        .frame(width: width, height: height)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    static func copyImage(_ png: Data) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { board.setData(tiff, forType: .tiff) }
    }

    // MARK: Save dialog (files.save)

    /// Asks where to save, then writes the file. The pack never sees the location, only whether it
    /// was saved, and the app writes only where the person picked.
    static func save(name: String, data: Data, done: @escaping (Bool) -> Void) {
        let panel = NSSavePanel()
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = safeName.isEmpty ? "Untitled" : String(safeName.prefix(100))
        if let type = UTType(filenameExtension: (safeName as NSString).pathExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        panel.level = .statusBar + 1        // above the panel
        PackServices.shared.holdPanel()
        NSApp.activate()
        nonisolated(unsafe) let done = done
        panel.begin { response in
            MainActor.assumeIsolated {
                PackServices.shared.releasePanel()
                guard response == .OK, let url = panel.url else { return done(false) }
                done((try? data.write(to: url, options: .atomic)) != nil)
            }
        }
    }

    // MARK: Color sampler (color.sample)

    /// Apple's screen color loupe. No permission is needed; the person clicks the color they want.
    static func sampleColor(done: @escaping (NSColor?) -> Void) {
        PackServices.shared.holdPanel()
        // The sampler calls back on the main thread; this closure never leaves it.
        nonisolated(unsafe) let done = done
        NSColorSampler().show { color in
            MainActor.assumeIsolated {
                // Release a moment later, so the click that picked the color doesn't count as "outside".
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    PackServices.shared.releasePanel()
                }
                done(color)
            }
        }
    }

    /// { hex, r, g, b, a } in sRGB (0–255 for r, g, b; 0–1 for a), for packs.
    static func colorObject(_ color: NSColor) -> [String: Any] {
        let c = color.usingColorSpace(.sRGB) ?? color
        let v = [c.redComponent, c.greenComponent, c.blueComponent].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return ["hex": String(format: "#%02x%02x%02x", v[0], v[1], v[2]), "r": v[0], "g": v[1], "b": v[2],
                "a": Double(c.alphaComponent)]
    }
}
