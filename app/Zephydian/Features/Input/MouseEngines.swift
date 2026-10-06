import AppKit
import Carbon.HIToolbox
import os

/// Mouse buttons: side buttons for Back/Forward (or anything else), shortcuts on extra buttons, and
/// middle-button drags (left/right switch desktops, up Mission Control, down App Exposé). A plain
/// middle click stays a middle click.
final class MouseButtonsEngine: FeatureEngine {
    private let settings = InputSettings.shared
    private lazy var tap = EventTap([.otherMouseDown, .otherMouseUp, .otherMouseDragged]) { [weak self] type, event in
        self?.handle(type, event) ?? event
    }
    private var middleStart: CGPoint?
    private var middleDragged = false
    /// Buttons whose press was taken, so their release (and drags) are too.
    private var taken: Set<Int64> = []

    func start() { tap.start() }
    func stop() { tap.stop(); middleStart = nil; taken = [] }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        if type != .otherMouseDown, taken.contains(button) {
            if type == .otherMouseUp { taken.remove(button) }
            return button == 2 ? middle(type, event) : nil
        }
        guard type == .otherMouseDown, !settings.frontAppIgnoresMouse else { return event }
        // A Radial Menu wheel opens with this button: its own tap takes it.
        if RadialMenuEngine.claimedButtons.contains(Int(button)) { return event }
        if button == 2 {
            guard settings.middleDragEnabled else { return event }
            taken.insert(2)
            return middle(type, event)
        }
        guard let action = settings.buttonActions[Int(button)], action != .none else { return event }
        taken.insert(button)
        perform(action, shortcut: settings.buttonShortcuts[Int(button)], at: event.location)
        return nil
    }

    /// The middle button: wait to see whether it's a click or a drag.
    private func middle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        switch type {
        case .otherMouseDown:
            middleStart = event.location
            middleDragged = false
        case .otherMouseDragged:
            guard let start = middleStart, !middleDragged else { return nil }
            let dx = event.location.x - start.x, dy = event.location.y - start.y
            guard max(abs(dx), abs(dy)) > 40 else { return nil }
            middleDragged = true
            let direction = abs(dx) > abs(dy) ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down")
            perform(settings.dragActions[direction] ?? MouseAction.none, shortcut: nil, at: event.location)
        case .otherMouseUp:
            if !middleDragged, let start = middleStart { MouseActions.middleClick(at: start) }
            middleStart = nil
        default:
            break
        }
        return nil
    }

    private func perform(_ action: MouseAction, shortcut: KeyShortcut?, at point: CGPoint) {
        Task { @MainActor in MouseActions.perform(action, shortcut: shortcut, at: point) }
    }
}

/// What mouse buttons and gestures can do.
enum MouseActions {
    static func perform(_ action: MouseAction, shortcut: KeyShortcut?, at point: CGPoint) {
        switch action {
        case .none: break
        case .back: EventTap.pressKey(CGKeyCode(kVK_ANSI_LeftBracket), flags: .maskCommand)
        case .forward: EventTap.pressKey(CGKeyCode(kVK_ANSI_RightBracket), flags: .maskCommand)
        case .middleClick: middleClick(at: point)
        case .missionControl:
            NSWorkspace.shared.open(URL(filePath: "/System/Applications/Mission Control.app"))
        case .appExpose: systemShortcut(33)
        case .showDesktop: systemShortcut(36)
        case .spaceLeft: systemShortcut(79)
        case .spaceRight: systemShortcut(81)
        case .shortcut:
            guard let shortcut else { return }
            EventTap.pressKey(CGKeyCode(shortcut.keyCode), flags: CGEventFlags(rawValue: UInt64(shortcut.flags.rawValue)))
        }
    }

    /// Presses the keys of one of macOS's own shortcuts (as set in System Settings → Keyboard).
    private static func systemShortcut(_ id: Int) {
        guard let (shortcut, enabled) = ShortcutConflicts.userSystemShortcuts()[id], enabled else { NSSound.beep(); return }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: down) else { continue }
            event.flags = CGEventFlags(rawValue: UInt64(shortcut.modifiers))
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.marker)
            event.post(tap: .cghidEventTap)   // system shortcuts are matched at the hardware level
        }
    }

    static func middleClick(at point: CGPoint) {
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .center) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

// MARK: - Three-finger middle click

/// How many fingers are on the trackpad, from the multitouch driver's callback thread.
private enum TouchCount {
    static let current = OSAllocatedUnfairLock(initialState: 0)
}

/// Three-finger middle click: pressing the trackpad with three fingers is a middle click (opening
/// links in new tabs, closing tabs). It reads the finger count through Apple's undocumented
/// multitouch framework, looked up at runtime, only while the feature is on.
final class MiddleClickEngine: FeatureEngine {
    private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    private typealias StartStop = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let callback: ContactCallback = { _, _, count, _, _ in
        TouchCount.current.withLock { $0 = Int(count) }
        return 0
    }

    private var devices: [UnsafeMutableRawPointer] = []
    /// Keeps the device objects alive while their callbacks are registered.
    private var deviceList: [AnyObject] = []
    private var converting = false
    private lazy var tap = EventTap([.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] type, event in
        self?.handle(type, event) ?? event
    }

    func start() {
        guard let create = Self.symbol("MTDeviceCreateList", CreateList.self),
              let register = Self.symbol("MTRegisterContactFrameCallback", Register.self),
              let startDevice = Self.symbol("MTDeviceStart", StartStop.self),
              let list = create()?.takeRetainedValue() as? [AnyObject] else { return }
        deviceList = list
        for device in list {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            register(pointer, Self.callback)
            _ = startDevice(pointer, 0)
            devices.append(pointer)
        }
        tap.start()
    }

    func stop() {
        tap.stop()
        if let unregister = Self.symbol("MTUnregisterContactFrameCallback", Register.self),
           let stopDevice = Self.symbol("MTDeviceStop", Stop.self) {
            for device in devices {
                unregister(device, Self.callback)
                _ = stopDevice(device)
            }
        }
        devices = []
        deviceList = []
        TouchCount.current.withLock { $0 = 0 }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        switch type {
        case .leftMouseDown:
            guard TouchCount.current.withLock({ $0 }) == 3 else { return event }
            converting = true
            return Self.middle(.otherMouseDown, like: event)
        case .leftMouseDragged:
            return converting ? Self.middle(.otherMouseDragged, like: event) : event
        case .leftMouseUp:
            guard converting else { return event }
            converting = false
            return Self.middle(.otherMouseUp, like: event)
        default:
            return event
        }
    }

    /// The same click, as the middle button.
    private static func middle(_ type: CGEventType, like event: CGEvent) -> CGEvent? {
        guard let middle = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: event.location, mouseButton: .center) else { return event }
        middle.flags = event.flags
        middle.setIntegerValueField(.mouseEventClickState, value: event.getIntegerValueField(.mouseEventClickState))
        return middle
    }
}

// MARK: - Mouse acceleration

/// No mouse acceleration: the pointer moves the same distance for the same hand movement, however
/// fast. Mice only (trackpads keep theirs). The previous setting is kept and put back when it's
/// switched off, at quit, and at the next launch if Zephydian stopped unexpectedly.
final class PointerAccelerationEngine: FeatureEngine {
    private static let savedKey = "input.savedMouseAcceleration"

    func start() {
        if UserDefaults.standard.object(forKey: Self.savedKey) == nil,
           let current = (HIDSystem.get("HIDMouseAcceleration") as? NSNumber)?.intValue {
            UserDefaults.standard.set(current, forKey: Self.savedKey)
        }
        HIDSystem.set("HIDMouseAcceleration", NSNumber(value: -1))
    }

    func stop() { Self.restore() }

    /// Puts the saved acceleration back, if Zephydian changed it.
    static func restore() {
        guard let saved = UserDefaults.standard.object(forKey: savedKey) as? Int else { return }
        HIDSystem.set("HIDMouseAcceleration", NSNumber(value: saved))
        UserDefaults.standard.removeObject(forKey: savedKey)
    }
}

// MARK: - Extra-click filter

/// Ignores the extra click a worn mouse button sometimes adds: a press that comes only a few
/// milliseconds after the same button was let go (far quicker than any real double click).
final class ClickFilterEngine: FeatureEngine {
    private let settings = InputSettings.shared
    private var lastUp: [Int64: UInt64] = [:]
    private var dropped: Set<Int64> = []
    private lazy var tap = EventTap([.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { [weak self] type, event in
        self?.handle(type, event) ?? event
    }

    func start() { tap.start() }
    func stop() { tap.stop(); lastUp = [:]; dropped = [] }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        let button: Int64 = (type == .leftMouseDown || type == .leftMouseUp) ? 0 : 1
        let now = event.timestamp   // nanoseconds
        if type == .leftMouseDown || type == .rightMouseDown {
            if let up = lastUp[button], now > up, now - up < UInt64(settings.clickFilterMs) * 1_000_000 {
                dropped.insert(button)
                return nil
            }
            return event
        }
        if dropped.remove(button) != nil { return nil }
        lastUp[button] = now
        return event
    }
}
