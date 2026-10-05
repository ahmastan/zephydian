import AppKit
import IOKit

/// A Core Graphics event tap: sees the chosen kinds of input before apps do, and can let each event
/// through, change it, or swallow it. Only runs between `start()` and `stop()`. It turns itself back
/// on if macOS pauses it, and never sees the events Zephydian posts itself (they carry `marker`).
@Observable
final class TapTimeouts {
    var count = 0
}

final class EventTap {
    /// Return the event (changed or not) to let it through, or nil to swallow it.
    typealias Handler = (CGEventType, CGEvent) -> CGEvent?

    /// Marks events Zephydian posts, so its own taps let them pass.
    nonisolated static let marker: Int64 = 0x7A657068   // "zeph"

    /// How often macOS paused one of Zephydian's taps for answering too slowly (shown in Debug builds).
    /// While a tap is paused, key presses go straight to apps, which is when shortcuts beep and fail.
    @MainActor static var timeouts = TapTimeouts()

    static func noteDisabled(_ type: CGEventType) {
        guard type == .tapDisabledByTimeout else { return }
        MainActor.assumeIsolated { timeouts.count += 1 }
    }

    private let types: [CGEventType]
    private let location: CGEventTapLocation
    private let options: CGEventTapOptions
    private let handler: Handler
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(_ types: [CGEventType], location: CGEventTapLocation = .cgSessionEventTap,
         options: CGEventTapOptions = .defaultTap, handler: @escaping Handler) {
        self.types = types
        self.location = location
        self.options = options
        self.handler = handler
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
            // Taps run on the main run loop; the event never leaves this thread.
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var result: Unmanaged<CGEvent>?
            MainActor.assumeIsolated { result = tap.handle(type, event) }
            return result
        }
        guard let tap = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: options,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            EventTap.noteDisabled(type)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        guard let result = handler(type, event) else { return nil }
        return result === event ? Unmanaged.passUnretained(result) : Unmanaged.passRetained(result)
    }

    // MARK: Posting

    /// Presses a key combination, as if typed (marked as Zephydian's own).
    static func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], to pid: pid_t? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            if let pid { event.postToPid(pid) } else { event.post(tap: .cgSessionEventTap) }
        }
    }

    /// The modifier keys of an event, as `NSEvent` flags (⌘ ⌥ ⌃ ⇧ only).
    static func modifiers(_ event: CGEvent) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection(KeyShortcut.relevant)
    }
}

/// System-wide input settings macOS keeps in its HID event system: the keyboard's key remapping
/// (what `hidutil` changes) and the mouse's acceleration. Undocumented functions, looked up at runtime.
enum HIDSystem {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetProperty = @convention(c) (AnyObject, CFString, AnyObject) -> Bool
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private static let handle: UnsafeMutableRawPointer? = {
        _ = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        return dlopen(nil, RTLD_NOW)
    }()
    private static let client: AnyObject? = {
        guard let handle, let pointer = dlsym(handle, "IOHIDEventSystemClientCreateSimpleClient") else { return nil }
        return unsafeBitCast(pointer, to: CreateClient.self)(kCFAllocatorDefault)?.takeRetainedValue()
    }()
    private static let setter: SetProperty? = handle.flatMap { dlsym($0, "IOHIDEventSystemClientSetProperty") }.map { unsafeBitCast($0, to: SetProperty.self) }
    private static let getter: CopyProperty? = handle.flatMap { dlsym($0, "IOHIDEventSystemClientCopyProperty") }.map { unsafeBitCast($0, to: CopyProperty.self) }

    static func get(_ key: String) -> AnyObject? {
        guard let client, let getter else { return nil }
        return getter(client, key as CFString)?.takeRetainedValue()
    }

    @discardableResult
    static func set(_ key: String, _ value: AnyObject) -> Bool {
        guard let client, let setter else { return false }
        return setter(client, key as CFString, value)
    }

    // MARK: Key remapping

    /// HID usage codes (page 7, keyboard) for `UserKeyMapping`.
    enum Usage: UInt64 {
        case capsLock = 0x700000039
        case f18 = 0x70000006D
        case rightCommand = 0x7000000E7
        case rightOption = 0x7000000E6
    }

    /// Adds (or removes) one source → destination mapping, keeping any others already set.
    static func map(_ source: Usage, to destination: Usage?) {
        var mappings = (get("UserKeyMapping") as? [[String: Any]]) ?? []
        mappings.removeAll { ($0["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.uint64Value == source.rawValue }
        if let destination {
            mappings.append(["HIDKeyboardModifierMappingSrc": NSNumber(value: source.rawValue),
                             "HIDKeyboardModifierMappingDst": NSNumber(value: destination.rawValue)])
        }
        set("UserKeyMapping", mappings as NSArray)
    }

    // MARK: Caps Lock

    /// Turns Caps Lock on or off (for ⇧+Caps Lock while Caps Lock is the Super key).
    static func toggleCapsLock() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        var state = false
        IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state)
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), !state)
    }
}
