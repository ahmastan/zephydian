import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (works in any app, no special permissions needed).
/// Uses the long-standing Carbon hot-key API, which is still the standard way to do this on macOS.
/// Several can exist at once (the panel's shortcut, a utility's own); each only answers to its own id.
final class GlobalHotKey {
    var onPress: () -> Void = {}
    private let id: UInt32
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// What's registered, kept while paused so it can come back.
    private(set) var shortcut: KeyShortcut?

    /// Every hot key, so they can all step aside while a new shortcut is being recorded.
    private static var all: [WeakBox] = []
    private struct WeakBox { weak var hotKey: GlobalHotKey? }
    private static var paused = false

    init(id: UInt32 = 1) {
        self.id = id
        Self.all.removeAll { $0.hotKey == nil }
        Self.all.append(WeakBox(hotKey: self))
    }

    /// Registers the shortcut (nil turns it off). Returns false if another app already owns it.
    @discardableResult
    func register(_ shortcut: KeyShortcut?) -> Bool {
        unregister()
        self.shortcut = shortcut
        guard let shortcut, !Self.paused else { return true }
        return attach(shortcut)
    }

    func unregister() {
        detach()
        shortcut = nil
    }

    /// While a shortcut field is recording, no hot key may catch the keys typed into it.
    static func pauseAll() {
        guard !paused else { return }
        paused = true
        all.compactMap(\.hotKey).forEach { $0.detach() }
    }

    static func resumeAll() {
        guard paused else { return }
        paused = false
        for hotKey in all.compactMap(\.hotKey) {
            if let shortcut = hotKey.shortcut { _ = hotKey.attach(shortcut) }
        }
    }

    private func attach(_ shortcut: KeyShortcut) -> Bool {
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5A45_5048), id: id) // 'ZEPH'
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { hotKey = nil }
        return status == noErr
    }

    private func detach() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            let pressedID = pressed.id
            // Carbon delivers hot keys on the main thread. Not ours: let the next handler take it.
            return MainActor.assumeIsolated {
                guard pressedID == hotKey.id else { return OSStatus(eventNotHandledErr) }
                hotKey.onPress()
                return noErr
            }
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
