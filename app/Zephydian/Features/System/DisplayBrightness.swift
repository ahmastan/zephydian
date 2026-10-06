import AppKit
import CoreGraphics
import IOKit
import SwiftUI

/// One display's brightness control.
nonisolated struct BrightnessDisplay: Identifiable, Sendable {
    enum Control: Sendable {
        /// The Mac's own screen (DisplayServices).
        case builtIn
        /// An external monitor that answers DDC/CI over its cable (Apple silicon).
        case ddc(maximum: Int)
        /// Neither: the picture is dimmed by Zephydian (the monitor's own brightness doesn't change).
        case software
    }

    let id: CGDirectDisplayID
    let name: String
    let control: Control
    /// For remembering its level across reconnects.
    let key: String
}

/// Reads and sets display brightness. The slider runs 0…1; the lowest 15% goes below the
/// display's own minimum by dimming the picture. Hardware calls (DDC) take tens of milliseconds,
/// so they run off the main thread.
nonisolated enum DisplayBrightness {
    /// Below this, the picture is dimmed further in software.
    static let extraDim = 0.15
    /// The darkest the software dimming goes (as a fraction of full).
    static let floor = 0.2

    // MARK: Lookups

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias I2C = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private struct Calls: @unchecked Sendable {
        let get: GetBrightness?
        let set: SetBrightness?
        let avCreate: AVCreate?
        let read: I2C?
        let write: I2C?
    }

    private static let calls: Calls = {
        let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        let io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        return Calls(get: dlsym(ds, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) },
                     set: dlsym(ds, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) },
                     avCreate: dlsym(io, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: AVCreate.self) },
                     read: dlsym(io, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: I2C.self) },
                     write: dlsym(io, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: I2C.self) })
    }()

    /// Every display, with how it can be controlled. Probes DDC, so call it off the main thread.
    static func displays() -> [BrightnessDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let services = avServices()
        return ids.prefix(Int(count)).compactMap { id in
            guard CGDisplayIsInMirrorSet(id) == 0 || CGDisplayIsMain(id) != 0 else { return nil }
            let key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?
                .localizedName ?? "Display"
            if CGDisplayIsBuiltin(id) != 0, calls.get != nil {
                return BrightnessDisplay(id: id, name: name, control: .builtIn, key: key)
            }
            let match = services.first { $0.vendor == CGDisplayVendorNumber(id) && $0.product == CGDisplayModelNumber(id) }
            if let service = match?.service, let current = ddcRead(service) {
                ddcServices[id] = ServiceBox(service)
                return BrightnessDisplay(id: id, name: name, control: .ddc(maximum: max(current.maximum, 1)), key: key)
            }
            return BrightnessDisplay(id: id, name: name, control: .software, key: key)
        }
    }

    /// The hardware level 0…1 (built-in or DDC), or nil.
    static func hardwareLevel(_ display: BrightnessDisplay) -> Double? {
        switch display.control {
        case .builtIn:
            var value: Float = 0
            guard let get = calls.get, get(display.id, &value) == 0 else { return nil }
            return Double(value)
        case .ddc(let maximum):
            guard let service = ddcServices[display.id]?.service, let reading = ddcRead(service) else { return nil }
            return Double(reading.current) / Double(maximum)
        case .software:
            return nil
        }
    }

    /// Applies a slider level: the hardware part, then the software dimming below the minimum.
    static func apply(_ level: Double, to display: BrightnessDisplay) {
        let level = min(max(level, 0), 1)
        switch display.control {
        case .builtIn, .ddc:
            let hardware = max(0, (level - extraDim) / (1 - extraDim))
            setHardware(hardware, display)
            dim(display.id, level >= extraDim ? 1 : floor + (1 - floor) * level / extraDim)
        case .software:
            dim(display.id, floor + (1 - floor) * level)
        }
    }

    /// The slider position for a hardware level (when nothing was saved yet).
    static func sliderLevel(hardware: Double) -> Double { extraDim + hardware * (1 - extraDim) }

    private static func setHardware(_ value: Double, _ display: BrightnessDisplay) {
        switch display.control {
        case .builtIn:
            _ = calls.set?(display.id, Float(value))
        case .ddc(let maximum):
            guard let service = ddcServices[display.id]?.service else { return }
            ddcWrite(service, Int((value * Double(maximum)).rounded()))
        case .software:
            break
        }
    }

    /// Scales the display's colors down (1 = normal). Undone by `restore()`.
    private static func dim(_ id: CGDirectDisplayID, _ factor: Double) {
        let f = CGGammaValue(min(max(factor, floor), 1))
        CGSetDisplayTransferByFormula(id, 0, f, 1, 0, f, 1, 0, f, 1)
    }

    /// Puts every display's colors back (at stop and quit).
    static func restore() { CGDisplayRestoreColorSyncSettings() }

    // MARK: DDC/CI

    private final class ServiceBox: @unchecked Sendable {
        let service: AnyObject
        init(_ service: AnyObject) { self.service = service }
    }
    nonisolated(unsafe) private static var ddcServices: [CGDirectDisplayID: ServiceBox] = [:]

    /// Each external display port's AV service, with the vendor and product of the monitor on it.
    /// Ports and framebuffers pair up by their index (dcpext0 ↔ dispext0).
    private static func avServices() -> [(service: AnyObject, vendor: UInt32, product: UInt32)] {
        guard let create = calls.avCreate else { return [] }
        var products: [String: (UInt32, UInt32)] = [:]
        let framebuffers = registry("IOMobileFramebufferShim"), ports = registry("DCPAVServiceProxy")
        defer { for (_, entry) in framebuffers + ports { IOObjectRelease(entry) } }
        for (path, entry) in framebuffers {
            guard let index = path.range(of: #"dispext\d+"#, options: .regularExpression).map({ String(path[$0].dropFirst(4)) }),
                  let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let product = attributes["ProductAttributes"] as? [String: Any],
                  let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                  let model = (product["ProductID"] as? NSNumber)?.uint32Value else { continue }
            products[index] = (vendor, model)
        }
        var out: [(AnyObject, UInt32, UInt32)] = []
        for (path, entry) in ports {
            guard IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String == "External",
                  let index = path.range(of: #"dcpext\d+"#, options: .regularExpression).map({ String(path[$0].dropFirst(3)) }),
                  let product = products[index], let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            out.append((service, product.0, product.1))
        }
        return out
    }

    private static func registry(_ className: String) -> [(String, io_service_t)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [(String, io_service_t)] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var path = [CChar](repeating: 0, count: 1024)
            IORegistryEntryGetPath(entry, kIOServicePlane, &path)
            out.append((SystemSensors.text(path), entry))
            entry = IOIteratorNext(iterator)
        }
        return out
    }

    /// Asks the monitor for its brightness (VCP 0x10). Nil when it doesn't answer.
    private static func ddcRead(_ service: AnyObject) -> (current: Int, maximum: Int)? {
        guard let read = calls.read, let write = calls.write else { return nil }
        var request: [UInt8] = [0x82, 0x01, 0x10, 0]
        request[3] = 0x6E ^ request[0] ^ request[1] ^ request[2]
        for _ in 0..<3 {
            usleep(10_000)
            _ = request.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, 4) }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            let status = reply.withUnsafeMutableBytes { read(service, 0x37, 0x51, $0.baseAddress!, 11) }
            // [source, length, 0x02 (VCP reply), result, code, type, max hi, max lo, current hi, current lo, checksum]
            if status == kIOReturnSuccess, reply[2] == 0x02, reply[3] == 0, reply[4] == 0x10 {
                return (Int(reply[8]) << 8 | Int(reply[9]), Int(reply[6]) << 8 | Int(reply[7]))
            }
        }
        return nil
    }

    private static func ddcWrite(_ service: AnyObject, _ value: Int) {
        guard let write = calls.write else { return }
        var packet: [UInt8] = [0x84, 0x03, 0x10, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(0x6E ^ 0x51) { $0 ^ $1 }
        for _ in 0..<2 {
            usleep(10_000)
            _ = packet.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, 6) }
        }
    }
}

// MARK: - The feature

@Observable
final class BrightnessModel {
    var displays: [BrightnessDisplay] = []
    var levels: [CGDirectDisplayID: Double] = [:]
    var loading = false
}

/// Display Brightness: a sun in the menu bar with a slider for every display: the Mac's screen,
/// monitors that accept brightness over their cable, and software dimming for the rest. The lowest
/// part of each slider dims below the display's own minimum. Levels are remembered per display.
final class BrightnessEngine: FeatureEngine {
    static weak var current: BrightnessEngine?

    let model = BrightnessModel()
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "com.ahmastan.zephydian.brightness")
    private var saved: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "brightness.levels") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "brightness.levels") }
    }

    func start() {
        Self.current = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "ZephydianBrightness"
        item.button?.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Brightness")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        self.item = item
        // Reconnecting a display or waking resets its colors: apply the saved levels again.
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load(apply: true) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load(apply: true) }
        }
        load(apply: true)
    }

    func stop() {
        if Self.current === self { Self.current = nil }
        popover?.close()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        for observer in [screenObserver, wakeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        screenObserver = nil
        wakeObserver = nil
        DisplayBrightness.restore()
    }

    /// Finds the displays (off the main thread) and, if `apply`, sets their saved levels.
    private func load(apply: Bool) {
        model.loading = true
        let saved = self.saved
        queue.async { [weak self] in
            let displays = DisplayBrightness.displays()
            var levels: [CGDirectDisplayID: Double] = [:]
            for display in displays {
                if let level = saved[display.key] {
                    levels[display.id] = level
                    if apply { DisplayBrightness.apply(level, to: display) }
                } else {
                    levels[display.id] = DisplayBrightness.hardwareLevel(display).map(DisplayBrightness.sliderLevel(hardware:)) ?? 1
                }
            }
            Task { @MainActor in
                self?.model.displays = displays
                self?.model.levels = levels
                self?.model.loading = false
            }
        }
    }

    func set(_ level: Double, for display: BrightnessDisplay) {
        model.levels[display.id] = level
        saved[display.key] = level
        queue.async { DisplayBrightness.apply(level, to: display) }
    }

    @objc private func togglePopover() {
        if popover?.isShown == true { popover?.close(); return }
        guard let button = item?.button else { return }
        let popover = self.popover ?? {
            let p = NSPopover()
            p.behavior = .transient
            let settings = Features.shared.appSettings ?? SettingsStore()
            p.contentViewController = NSHostingController(rootView: BrightnessPopover(engine: self).environment(settings).tint(settings.accentColor))
            return p
        }()
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

/// A slider per display: the menu bar popover, and the panel's Brightness tab.
struct BrightnessPopover: View {
    let engine: BrightnessEngine
    /// The popover's fixed width; nil fills the panel's tab.
    var width: CGFloat? = 320

    var body: some View {
        let model = engine.model
        VStack(alignment: .leading, spacing: 14) {
            if model.displays.isEmpty {
                Text(model.loading ? "Finding displays…" : "No displays found.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.displays) { display in
                let level = model.levels[display.id] ?? 1
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(display.name).font(.headline)
                        Spacer()
                        Text(note(display, level)).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "sun.min").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { level }, set: { engine.set($0, for: display) }), in: 0...1)
                            .accessibilityLabel("\(display.name) brightness")
                        Image(systemName: "sun.max").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: width)
    }

    private func note(_ display: BrightnessDisplay, _ level: Double) -> String {
        switch display.control {
        case .software: return "Dimmed by Zephydian · \(Int((level * 100).rounded()))%"
        default:
            return level < DisplayBrightness.extraDim ? "Below the minimum" : "\(Int(((level - DisplayBrightness.extraDim) / (1 - DisplayBrightness.extraDim) * 100).rounded()))%"
        }
    }
}

struct BrightnessSettingsView: View {
    var body: some View {
        Section {
            Text("Click the sun in the menu bar for a brightness slider for each display. The Mac's own screen and monitors that accept brightness over their cable (DDC/CI, on Apple silicon) change their real backlight; the lowest part of each slider dims further than the display normally goes. Other monitors (and monitors behind some docks and hubs) are dimmed by Zephydian instead. If a monitor should support it, turn on DDC/CI in its own on-screen menu.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
