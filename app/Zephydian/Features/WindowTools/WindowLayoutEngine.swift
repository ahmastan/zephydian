import AppKit
import ApplicationServices

/// Moving and sizing a window into a layout. Shared by the shortcuts, Dock Preview's menu and the
/// green button.
enum WindowArranger {
    /// Frames windows had before Zephydian first arranged them, for Restore. Keyed by window id.
    private static var original: [CGWindowID: CGRect] = [:]

    /// The front app's focused window.
    static func focusedWindow() -> (AXUIElement, pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let window = SystemWindows.copy(element, kAXFocusedWindowAttribute) else { return nil }
        return (window as! AXUIElement, app.processIdentifier)
    }

    /// Puts the window into `layout` on its screen (or the next/previous one).
    static func apply(_ layout: WindowLayout, to window: AXUIElement, settings: WindowToolsSettings = .shared) {
        guard let current = SystemWindows.frame(of: window) else { return }
        let id = WindowServer.windowID(of: window)
        if layout == .restore {
            if let id, let frame = original.removeValue(forKey: id) { setFrame(window, frame) }
            return
        }
        if let id, original[id] == nil { original[id] = current }
        guard let target = frame(for: layout, current: current, gap: CGFloat(settings.gap), cycle: settings.cycleSizes) else { return }
        setFrame(window, target)
    }

    /// The frame (window-server coordinates) for a layout, given where the window is now.
    static func frame(for layout: WindowLayout, current: CGRect, gap: CGFloat, cycle: Bool) -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let index = screenIndex(for: current)
        var screen = screens[index]
        if layout == .nextDisplay || layout == .previousDisplay {
            guard screens.count > 1 else { return nil }
            let next = (index + (layout == .nextDisplay ? 1 : -1) + screens.count) % screens.count
            let from = SystemWindows.serverRect(screen.visibleFrame), to = SystemWindows.serverRect(screens[next].visibleFrame)
            // Same place and size relative to the screen, fitted to the new one.
            let width = min(current.width / from.width * to.width, to.width)
            let height = min(current.height / from.height * to.height, to.height)
            let x = to.minX + (current.minX - from.minX) / from.width * to.width
            let y = to.minY + (current.minY - from.minY) / from.height * to.height
            return CGRect(x: min(max(x, to.minX), to.maxX - width), y: min(max(y, to.minY), to.maxY - height), width: width, height: height)
        }
        screen = screens[index]
        let area = SystemWindows.serverRect(screen.visibleFrame).insetBy(dx: gap, dy: gap)
        let half = gap / 2
        func columns(_ start: CGFloat, _ span: CGFloat, of parts: CGFloat) -> CGRect {
            let unit = area.width / parts
            let x = area.minX + unit * start + (start > 0 ? half : 0)
            let end = area.minX + unit * (start + span) - (start + span < parts ? half : 0)
            return CGRect(x: x, y: area.minY, width: end - x, height: area.height)
        }
        func rows(_ top: Bool) -> CGRect {
            CGRect(x: area.minX, y: top ? area.minY : area.midY + half, width: area.width, height: area.height / 2 - half)
        }
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4 && abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4
        }
        switch layout {
        case .leftHalf, .rightHalf:
            let left = layout == .leftHalf
            let halfRect = left ? columns(0, 1, of: 2) : columns(1, 1, of: 2)
            guard cycle else { return halfRect }
            // Again: ½ → ⅔ → ⅓ → ½.
            let twoThirds = left ? columns(0, 2, of: 3) : columns(1, 2, of: 3)
            let oneThird = left ? columns(0, 1, of: 3) : columns(2, 1, of: 3)
            if near(current, halfRect) { return twoThirds }
            if near(current, twoThirds) { return oneThird }
            return halfRect
        case .topHalf: return rows(true)
        case .bottomHalf: return rows(false)
        case .maximize: return area
        case .center:
            let width = min(current.width, area.width), height = min(current.height, area.height)
            return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        case .firstThird: return columns(0, 1, of: 3)
        case .centerThird: return columns(1, 1, of: 3)
        case .lastThird: return columns(2, 1, of: 3)
        case .firstTwoThirds: return columns(0, 2, of: 3)
        case .lastTwoThirds: return columns(1, 2, of: 3)
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let column = columns(layout == .topLeft || layout == .bottomLeft ? 0 : 1, 1, of: 2)
            let row = rows(layout == .topLeft || layout == .topRight)
            return CGRect(x: column.minX, y: row.minY, width: column.width, height: row.height)
        case .restore, .nextDisplay, .previousDisplay:
            return nil
        }
    }

    /// The screen holding most of the window.
    private static func screenIndex(for frame: CGRect) -> Int {
        let rect = SystemWindows.appKitRect(frame)
        let areas = NSScreen.screens.map { screen -> CGFloat in
            let overlap = screen.frame.intersection(rect)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        return areas.indices.max { areas[$0] < areas[$1] } ?? 0
    }

    /// Position, then size, then position again: some apps refuse a size that doesn't fit where
    /// the window still is, especially when it changes displays.
    static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
        var origin = frame.origin, size = frame.size
        if let position = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) }
        if let extent = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent) }
        if let position = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) }
    }

    /// Whether the app is left out of Window Layout.
    static func isIgnored(_ pid: pid_t, _ list: [String]) -> Bool {
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return list.contains(id)
    }
}

/// Which layout shortcuts couldn't be registered (another app owns them), for the warnings.
@Observable
final class WindowLayoutStatus {
    static let shared = WindowLayoutStatus()
    var failed: Set<WindowLayout> = []
}

/// Window Layout: shortcuts for every layout, ⌥-drag to move (⌥⌘ to resize) a window from
/// anywhere in it, and, on macOS 14 (which has no tiling of its own), snapping to screen edges.
final class WindowLayoutEngine: FeatureEngine {
    private let settings = WindowToolsSettings.shared
    private var hotKeys: [WindowLayout: GlobalHotKey] = [:]
    private var running = false
    private var dragTap: CFMachPort?
    private var dragSource: CFRunLoopSource?
    private var drag: (window: AXUIElement, start: CGPoint, frame: CGRect, resize: Bool)?
    private var edgeSnap: EdgeSnap?

    func start() {
        running = true
        followSettings()
        if #unavailable(macOS 15) {
            edgeSnap = EdgeSnap(settings: settings)
            edgeSnap?.start()
        }
    }

    func stop() {
        running = false
        hotKeys.values.forEach { $0.unregister() }
        hotKeys = [:]
        WindowLayoutStatus.shared.failed = []
        removeDragTap()
        edgeSnap?.stop()
        edgeSnap = nil
    }

    private func followSettings() {
        guard running else { return }
        withObservationTracking {
            _ = settings.shortcuts
            _ = settings.dragModifier
        } onChange: { [weak self] in
            Task { @MainActor in self?.followSettings() }
        }
        registerShortcuts()
        if settings.dragModifier == .off { removeDragTap() } else { installDragTap() }
    }

    // MARK: Shortcuts

    private func registerShortcuts() {
        var failed: Set<WindowLayout> = []
        for (index, layout) in WindowLayout.allCases.enumerated() {
            let hotKey = hotKeys[layout] ?? GlobalHotKey(id: 500 + UInt32(index))
            hotKey.onPress = { [weak self] in self?.arrangeFront(layout) }
            hotKeys[layout] = hotKey
            if !hotKey.register(settings.shortcuts[layout]) { failed.insert(layout) }
        }
        WindowLayoutStatus.shared.failed = failed
    }

    private func arrangeFront(_ layout: WindowLayout) {
        guard let (window, pid) = WindowArranger.focusedWindow(),
              !WindowArranger.isIgnored(pid, settings.layoutIgnoredApps) else { NSSound.beep(); return }
        WindowArranger.apply(layout, to: window, settings: settings)
    }

    // MARK: Modifier-drag

    private func installDragTap() {
        guard dragTap == nil else { return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<WindowLayoutEngine>.fromOpaque(refcon).takeUnretainedValue()
            let swallow = MainActor.assumeIsolated { engine.handleDrag(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        dragTap = tap
        dragSource = source
    }

    private func removeDragTap() {
        if let dragTap { CGEvent.tapEnable(tap: dragTap, enable: false) }
        if let dragSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), dragSource, .commonModes) }
        dragTap = nil
        dragSource = nil
        drag = nil
    }

    /// Returns true to swallow the event (only clicks that start a modifier-drag, and that drag).
    private func handleDrag(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            EventTap.noteDisabled(type)
            if let dragTap { CGEvent.tapEnable(tap: dragTap, enable: true) }
            return false
        case .leftMouseDown:
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection(KeyShortcut.relevant)
            let modifier = settings.dragModifier
            let resize = flags == modifier.resize
            guard flags == modifier.move || resize,
                  let window = Self.window(at: event.location),
                  let frame = SystemWindows.frame(of: window) else { return false }
            var pid: pid_t = 0
            AXUIElementGetPid(window, &pid)
            guard pid != ProcessInfo.processInfo.processIdentifier,
                  !WindowArranger.isIgnored(pid, settings.layoutIgnoredApps) else { return false }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            drag = (window, event.location, frame, resize)
            return true
        case .leftMouseDragged:
            guard let drag else { return false }
            let dx = event.location.x - drag.start.x, dy = event.location.y - drag.start.y
            if drag.resize {
                var size = CGSize(width: max(120, drag.frame.width + dx), height: max(80, drag.frame.height + dy))
                if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(drag.window, kAXSizeAttribute as CFString, value) }
            } else {
                var origin = CGPoint(x: drag.frame.minX + dx, y: drag.frame.minY + dy)
                if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(drag.window, kAXPositionAttribute as CFString, value) }
            }
            return true
        case .leftMouseUp:
            guard drag != nil else { return false }
            drag = nil
            return true
        default:
            return false
        }
    }

    /// The window under a point (window-server coordinates).
    static func window(at point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        if SystemWindows.copy(element, kAXRoleAttribute) as? String == kAXWindowRole { return element }
        guard let window = SystemWindows.copy(element, kAXWindowAttribute) else { return nil }
        return (window as! AXUIElement)
    }
}

/// macOS 14 only: drag a window to a screen edge or corner and it snaps there when you let go
/// (left/right edge: halves, top: maximize, corners: quarters), with a preview of where it goes.
private final class EdgeSnap {
    private let settings: WindowToolsSettings
    private var monitors: [Any] = []
    private var dragStart: (window: AXUIElement, frame: CGRect)?
    private var pending: WindowLayout?
    private let preview = SnapPreview()

    init(settings: WindowToolsSettings) { self.settings = settings }

    func start() {
        let events: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.leftMouseDown, { [weak self] _ in MainActor.assumeIsolated { self?.down() } }),
            (.leftMouseDragged, { [weak self] _ in MainActor.assumeIsolated { self?.dragged() } }),
            (.leftMouseUp, { [weak self] _ in MainActor.assumeIsolated { self?.up() } }),
        ]
        for (mask, handler) in events {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(monitor) }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        preview.hide()
    }

    private func down() {
        pending = nil
        dragStart = WindowArranger.focusedWindow().flatMap { window, pid in
            WindowArranger.isIgnored(pid, settings.layoutIgnoredApps) ? nil : SystemWindows.frame(of: window).map { (window, $0) }
        }
    }

    private func dragged() {
        guard let start = dragStart, let frame = SystemWindows.frame(of: start.window), frame.origin != start.frame.origin else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let f = screen.frame, edge: CGFloat = 3, corner: CGFloat = 40
        let left = point.x <= f.minX + edge, right = point.x >= f.maxX - edge - 1
        let top = point.y >= f.maxY - edge - 1, bottom = point.y <= f.minY + edge
        var layout: WindowLayout?
        if (left || point.x <= f.minX + corner) && top { layout = .topLeft }
        else if (right || point.x >= f.maxX - corner) && top { layout = .topRight }
        else if left && point.y <= f.minY + corner { layout = .bottomLeft }
        else if right && point.y <= f.minY + corner { layout = .bottomRight }
        else if left { layout = .leftHalf }
        else if right { layout = .rightHalf }
        else if top { layout = .maximize }
        else if bottom { layout = nil }
        guard layout != pending else { return }
        pending = layout
        if let layout, let target = WindowArranger.frame(for: layout, current: frame, gap: CGFloat(settings.gap), cycle: false) {
            preview.show(SystemWindows.appKitRect(target))
        } else {
            preview.hide()
        }
    }

    private func up() {
        preview.hide()
        defer { dragStart = nil; pending = nil }
        guard let layout = pending, let window = dragStart?.window else { return }
        // Let the app finish its own move first.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            if let target = WindowArranger.frame(for: layout, current: SystemWindows.frame(of: window) ?? .zero,
                                                 gap: CGFloat(self.settings.gap), cycle: false) {
                WindowArranger.setFrame(window, target)
            }
        }
    }
}

/// Where a snapped window will go: a rounded, accent-tinted area.
private final class SnapPreview {
    private var window: NSWindow?

    func show(_ frame: CGRect) {
        let window = self.window ?? {
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = NSView()
            view.wantsLayer = true
            view.layer?.cornerRadius = 12
            view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
            view.layer?.borderWidth = 2
            window.contentView = view
            return window
        }()
        self.window = window
        window.setFrame(frame.insetBy(dx: 4, dy: 4), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }
}
