import AppKit
import Carbon.HIToolbox

// MARK: - Text snippets

/// Text snippets: typing a trigger (";date") replaces it with the snippet's text, and a searchable
/// menu on a shortcut inserts any snippet. It keeps only the last few characters typed, in memory,
/// to spot triggers; nothing typed is stored or sent anywhere.
///
/// macOS hides typing in password fields from every app ("secure input"), so snippets don't work there.
final class SnippetsEngine: FeatureEngine {
    private let settings = InputSettings.shared
    private var typed = ""
    private let hotKey = GlobalHotKey(id: 600)
    private let menu = SnippetMenu()
    private var activationObserver: NSObjectProtocol?
    private var running = false
    private lazy var tap = EventTap([.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] type, event in
        self?.handle(type, event)
        return event   // snippets never hold typing back
    }

    func start() {
        running = true
        tap.start()
        hotKey.onPress = { [weak self] in self?.openMenu() }
        followShortcut()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.typed = "" }
        }
    }

    func stop() {
        running = false
        tap.stop()
        hotKey.unregister()
        menu.close()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        typed = ""
    }

    private func followShortcut() {
        guard running else { return }
        withObservationTracking {
            _ = settings.snippetMenuShortcut
        } onChange: { [weak self] in
            Task { @MainActor in self?.followShortcut() }
        }
        SnippetsStatus.shared.menuShortcutRegistered = hotKey.register(settings.snippetMenuShortcut)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        guard type == .keyDown else { typed = ""; return }
        let flags = EventTap.modifiers(event)
        if flags.contains(.command) || flags.contains(.control) { typed = ""; return }
        switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
        case kVK_Delete:
            if !typed.isEmpty { typed.removeLast() }
            return
        case kVK_Return, kVK_Tab, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_ANSI_KeypadEnter:
            typed = ""
            return
        default:
            break
        }
        guard let characters = NSEvent(cgEvent: event)?.characters, !characters.isEmpty else { return }
        typed = String((typed + characters).suffix(64))
        // A trigger is ";" plus at least one character.
        guard let snippet = settings.snippets.first(where: { $0.trigger.count > InputSettings.triggerPrefix.count && typed.hasSuffix($0.trigger) }) else { return }
        // Only when the trigger starts a word: the character before it is a space, punctuation or nothing.
        let before = typed.dropLast(snippet.trigger.count).last
        guard before == nil || before!.isWhitespace || before!.isPunctuation else { return }
        typed = ""
        let erase = snippet.trigger.count
        // After the trigger's last key has reached the app.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            for _ in 0..<erase { EventTap.pressKey(CGKeyCode(kVK_Delete)) }
            SnippetPaste.insert(snippet.expanded())
        }
    }

    private func openMenu() {
        menu.show(snippets: settings.snippets) { snippet in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))   // the app's window is focused again
                SnippetPaste.insert(snippet.expanded())
            }
        }
    }
}

/// Whether the snippet menu's shortcut could be registered (for its warning).
@Observable
final class SnippetsStatus {
    static let shared = SnippetsStatus()
    var menuShortcutRegistered = true
}

/// Inserts text where the cursor is: through the clipboard (which handles any length and any
/// language), marked as temporary so clipboard histories skip it, then puts the clipboard back.
enum SnippetPaste {
    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        EventTap.pressKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }
}

// MARK: - Key debounce

/// Ignores the doubled letters a worn keyboard sometimes types: the same key pressed again only a
/// few milliseconds after it was let go (much faster than anyone types the same letter twice).
final class KeyDebounceEngine: FeatureEngine {
    private let settings = InputSettings.shared
    private var lastUp: [Int64: UInt64] = [:]
    private var dropped: Set<Int64> = []
    private lazy var tap = EventTap([.keyDown, .keyUp]) { [weak self] type, event in self?.handle(type, event) ?? event }

    func start() { tap.start() }
    func stop() { tap.stop(); lastUp = [:]; dropped = [] }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let now = event.timestamp
        if type == .keyDown {
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return event }
            if let up = lastUp[key], now > up, now - up < UInt64(settings.keyDebounceMs) * 1_000_000 {
                dropped.insert(key)
                return nil
            }
            return event
        }
        if dropped.remove(key) != nil { return nil }
        lastUp[key] = now
        return event
    }
}

// MARK: - Super key

/// The Super key: held, Caps Lock (or right ⌘ / right ⌥) acts as ⌃⌥⇧⌘ together, a combination no
/// app uses, so shortcuts made with it never clash; tapped alone it's Esc (or Caps Lock).
///
/// Caps Lock is turned into F18 with macOS's own key remapping (what `hidutil` sets), only while
/// the feature is on; the remapping is undone when it's off, at quit, and at the next launch if
/// Zephydian stopped unexpectedly. ⇧+Caps Lock still turns Caps Lock on and off.
final class SuperKeyEngine: FeatureEngine {
    private let settings = InputSettings.shared
    private var held = false
    private var usedAsModifier = false
    private var running = false
    private static let mappedKey = "input.superKeyMapped"
    private static let hyper: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    private lazy var tap = EventTap([.keyDown, .keyUp, .flagsChanged], location: .cghidEventTap) { [weak self] type, event in
        self?.handle(type, event) ?? event
    }

    func start() {
        running = true
        follow()
        tap.start()
    }

    func stop() {
        running = false
        tap.stop()
        Self.restore()
        held = false
    }

    /// Undoes the Caps Lock remapping, if Zephydian made it.
    static func restore() {
        guard UserDefaults.standard.bool(forKey: mappedKey) else { return }
        HIDSystem.map(.capsLock, to: nil)
        UserDefaults.standard.removeObject(forKey: mappedKey)
    }

    private func follow() {
        guard running else { return }
        withObservationTracking {
            _ = settings.superKey
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        if settings.superKey == .capsLock {
            HIDSystem.map(.capsLock, to: .f18)
            UserDefaults.standard.set(true, forKey: Self.mappedKey)
        } else {
            Self.restore()
        }
    }

    private var ignoredHere: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(settings.superIgnoredApps.contains) ?? false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch settings.superKey {
        case .capsLock:
            if key == kVK_F18 && (type == .keyDown || type == .keyUp) {
                if type == .keyDown {
                    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
                    if event.flags.contains(.maskShift) {
                        HIDSystem.toggleCapsLock()   // ⇧+Caps Lock: Caps Lock as usual
                        return nil
                    }
                    pressed()
                } else {
                    released()
                }
                return nil
            }
        case .rightCommand, .rightOption:
            let target = settings.superKey == .rightCommand ? kVK_RightCommand : kVK_RightOption
            if type == .flagsChanged && key == target {
                let down = event.flags.contains(settings.superKey == .rightCommand ? .maskCommand : .maskAlternate)
                if down { pressed() } else { released() }
                return event
            }
        }
        guard held, !ignoredHere, type == .keyDown || type == .keyUp else { return event }
        usedAsModifier = true
        event.flags.formUnion(Self.hyper)
        return event
    }

    private func pressed() {
        held = true
        usedAsModifier = false
    }

    private func released() {
        guard held else { return }
        held = false
        guard !usedAsModifier else { return }
        switch settings.superTap {
        case .escape: EventTap.pressKey(CGKeyCode(kVK_Escape))
        case .capsLock: HIDSystem.toggleCapsLock()
        case .nothing: break
        }
    }
}
