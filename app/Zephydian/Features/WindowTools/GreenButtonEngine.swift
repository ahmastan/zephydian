import AppKit
import ApplicationServices

/// Maximize with the green button: clicking a window's green button fills the screen (the Dock and
/// menu bar stay) instead of opening a full-screen Space; clicking it again puts the window back.
/// ⌥-click still goes full screen. A mouse-down tap asks Accessibility what's under the pointer,
/// and only a click on a green button is taken.
final class GreenButtonEngine: FeatureEngine {
    private let settings = WindowToolsSettings.shared
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// The mouse-down was taken, so its mouse-up is too.
    private var swallowUp = false

    func start() {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<GreenButtonEngine>.fromOpaque(refcon).takeUnretainedValue()
            let swallow = MainActor.assumeIsolated { engine.handle(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            EventTap.noteDisabled(type)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .leftMouseUp:
            if swallowUp { swallowUp = false; return true }
            return false
        case .leftMouseDown:
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection(KeyShortcut.relevant)
            guard flags.isEmpty || flags == .option, Self.nearTitleButtons(event.location) else { return false }
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, 0.1)
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(event.location.x), Float(event.location.y), &element) == .success,
                  let element, SystemWindows.copy(element, kAXSubroleAttribute) as? String == kAXFullScreenButtonSubrole,
                  let windowValue = SystemWindows.copy(element, kAXWindowAttribute) else { return false }
            let window = windowValue as! AXUIElement
            var pid: pid_t = 0
            AXUIElementGetPid(window, &pid)
            guard !WindowArranger.isIgnored(pid, settings.greenIgnoredApps) else { return false }
            swallowUp = true
            Task { @MainActor in
                if flags == .option {
                    AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
                } else {
                    Self.toggleMaximized(window)
                }
            }
            return true
        default:
            return false
        }
    }

    /// Whether a click is in the top-left corner of a normal window (where its buttons are). A cheap
    /// check, so Accessibility is only asked about clicks that could be on the green button.
    private static func nearTitleButtons(_ point: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let top = list.first(where: { info in
                  guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                        let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
                  return rect.contains(point)
              }),
              (top[kCGWindowLayer as String] as? Int) == 0,
              let bounds = top[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
        return point.x - rect.minX < 110 && point.y - rect.minY < 60
    }

    /// Fills the screen, or puts back the frame it had before if it already fills it.
    private static func toggleMaximized(_ window: AXUIElement) {
        guard let current = SystemWindows.frame(of: window),
              let full = WindowArranger.frame(for: .maximize, current: current, gap: CGFloat(WindowToolsSettings.shared.gap), cycle: false) else { return }
        let filled = abs(current.minX - full.minX) < 4 && abs(current.minY - full.minY) < 4
            && abs(current.width - full.width) < 4 && abs(current.height - full.height) < 4
        WindowArranger.apply(filled ? .restore : .maximize, to: window)
    }
}
