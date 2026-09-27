import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (works in any app, no special permissions needed).
/// Uses the long-standing Carbon hot-key API, which is still the standard way to do this on macOS.
final class GlobalHotKey {
    var onPress: () -> Void = {}
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Registers the shortcut. Returns false if another app already owns it.
    @discardableResult
    func register(_ shortcut: GlobalShortcut) -> Bool {
        unregister()
        guard let (keyCode, modifiers) = Self.keys(for: shortcut) else { return true }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x5A45_5048), id: 1) // 'ZEPH'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        return status == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.onPress() } // Carbon delivers hot keys on the main thread
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private static func keys(for shortcut: GlobalShortcut) -> (UInt32, UInt32)? {
        switch shortcut {
        case .off: nil
        case .optionSpace: (UInt32(kVK_Space), UInt32(optionKey))
        case .controlOptionSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .controlOptionZ: (UInt32(kVK_ANSI_Z), UInt32(controlKey | optionKey))
        }
    }
}
