import AppKit
import SwiftUI
import SwitcherKit

/// One wheel on screen at a time: opens it, follows the pointer and the keys, and runs the slice
/// picked. While no wheel is up, nothing here runs (no timers, no monitors).
final class RadialMenuController {
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    let model = RadialMenuModel()
    private var panel: KeyPanel?
    private var hosting: NSHostingView<AnyView>?
    private let settings = RadialSettings.shared

    /// Wheels from the top level to the folder on screen.
    private var stack: [[RadialSlice]] = []
    /// The wheel's center, in screen coordinates (y up).
    private var center = CGPoint.zero
    /// Highlighting waits until the pointer has moved a little from here (where it was when the
    /// wheel or a folder opened), so whatever direction it already sat in doesn't pick a slice.
    private var anchor = CGPoint.zero
    private var armed = false
    private var lastPointer = CGPoint.zero

    /// The shortcut or button that opened the wheel is still held, and letting go of it picks.
    private var holding = false
    private var heldShortcut: KeyShortcut?
    private var heldButton: Int?
    private var mode = RadialMode.pressOrHold

    private var pointerTimer: Timer?
    private var keyMonitors: [Any] = []
    private var outsideMonitor: Any?
    private var restTask: Task<Void, Never>?

    /// The wheel is fading out (it can be summoned again meanwhile).
    private var closing = false

    var isOpen: Bool { panel?.isVisible == true && !closing }
    var openWheelID: UUID? { isOpen ? model.wheel.id : nil }

    // MARK: Opening and closing

    /// Opens `wheel`. `shortcut` or `button` is what was pressed (nil for a preview from Settings).
    func summon(_ wheel: RadialWheel, shortcut: KeyShortcut? = nil, button: Int? = nil) {
        if isOpen {
            // The same summoner again while the wheel stays open closes it; anything else is ignored
            // (a held shortcut's key repeats, or a second wheel's trigger mid-pick).
            if !holding, model.wheel.id == wheel.id { close() }
            return
        }
        let slices = RadialActions.slices(wheel.items)
        guard !slices.isEmpty else { NSSound.beep(); return }

        mode = shortcut == nil && button == nil ? .press : settings.mode
        heldShortcut = shortcut
        heldButton = button
        // A shortcut can only be "held" through its modifier keys (a plain F-key's release isn't seen).
        let holdable = button != nil || (shortcut.map { !$0.flags.isEmpty } ?? false)
        holding = mode != .press && holdable

        model.wheel = wheel
        model.scale = settings.size.scale
        model.trail = []
        model.lit = nil
        model.showNumbers = false
        stack = [slices]
        show(slices)

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main ?? NSScreen.screens[0]
        center = position(for: pointer, on: screen)
        anchor = pointer
        lastPointer = pointer
        armed = false

        let panel = self.panel ?? makePanel()
        self.panel = panel
        closing = false
        let side = model.side
        panel.setFrame(CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side), display: false)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        // Grow the disc and throw the slices out on the next pass, once the panel is on screen.
        DispatchQueue.main.async { [model] in
            model.discShown = true
            model.revealed = true
        }
        startMonitors()
        if Self.contains(.nowPlaying, in: wheel.items) {
            RadialActions.refreshNowPlaying { [weak self] playing in self?.showNowPlaying(playing) }
        }
    }

    private static func contains(_ kind: RadialItemKind, in items: [RadialItem]) -> Bool {
        items.contains { $0.kind == kind || contains(kind, in: $0.children) }
    }

    /// A fresh Now Playing read arrived: update the now-playing slices without redrawing the wheel.
    private func showNowPlaying(_ playing: NowPlaying?) {
        guard isOpen else { return }
        stack = stack.map { level in
            level.map { slice in
                var slice = slice
                RadialActions.fill(&slice, with: playing)
                return slice
            }
        }
        if let level = stack.last { model.slices = level }
    }

    /// Opens a wheel in the middle of the screen without a shortcut, from Settings → Try It.
    func preview(_ wheel: RadialWheel) {
        if isOpen { close() }
        summon(wheel)
    }

    func close() {
        guard let panel, isOpen else { return }
        closing = true
        stopMonitors()
        holding = false
        model.discShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Summoned again while fading: that wheel stays.
                guard let self, self.closing else { return }
                self.closing = false
                panel.orderOut(nil)
                self.reset()
            }
        })
    }

    private func reset() {
        withTransaction(Transaction(animation: nil)) {
            model.revealed = false
            model.discShown = false
            model.lit = nil
        }
    }

    /// The summoner was let go (its modifier keys, or its mouse button).
    func released() {
        guard holding else { return }
        holding = false
        if let lit = model.lit {
            activate(lit)
        } else if mode == .hold {
            close()
        }
        // Press or hold with nothing picked: the wheel stays open for clicking.
    }

    /// The mouse button that opened the wheel came back up.
    func buttonReleased(_ button: Int) {
        if heldButton == button { released() }
    }

    // MARK: Picking

    private func activate(_ index: Int) {
        guard stack.last?.indices.contains(index) == true, let slice = stack.last?[index] else { return }
        if slice.isFolder {
            enter(slice)
            return
        }
        close()
        // Let the wheel go first, so whatever the slice opens (or the keys it sends) gets the focus.
        let item = slice.item
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            RadialActions.run(item)
        }
    }

    private func enter(_ folder: RadialSlice) {
        let children = RadialActions.slices(folder.item.children)
        guard !children.isEmpty else { NSSound.beep(); return }
        holding = false   // a folder opened on release stays open for clicking
        stack.append(children)
        model.trail.append(folder.title)
        show(children)
        anchor = NSEvent.mouseLocation
        armed = false
        DispatchQueue.main.async { [model] in model.revealed = true }
    }

    private func back() {
        guard stack.count > 1 else { return close() }
        stack.removeLast()
        model.trail.removeLast()
        show(stack[stack.count - 1])
        anchor = NSEvent.mouseLocation
        armed = false
        DispatchQueue.main.async { [model] in model.revealed = true }
    }

    /// Puts a level's slices on the wheel, folded into the center until `revealed` is set.
    private func show(_ slices: [RadialSlice]) {
        restTask?.cancel()
        withTransaction(Transaction(animation: nil)) {
            model.revealed = false
            model.lit = nil
            model.slices = slices
        }
    }

    private func highlight(_ index: Int?) {
        guard index != model.lit else { return }
        model.setLit(index)
        restTask?.cancel()
        guard let index else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        // Resting on a folder opens it.
        if model.slices.indices.contains(index), model.slices[index].isFolder {
            restTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, self.model.lit == index else { return }
                self.activate(index)
            }
        }
    }

    /// A click on the wheel's panel, in points from the center (y up).
    func click(dx: CGFloat, dyUp: CGFloat) {
        let dead = RadialLayout.deadZoneRadius * model.scale
        if (dx * dx + dyUp * dyUp).squareRoot() < dead {
            back()   // the center: Back in a folder, otherwise close
            return
        }
        if let index = RadialGeometry.highlightedIndex(dx: dx, dyUp: dyUp, deadZoneRadius: dead, itemCount: model.slices.count) {
            activate(index)
        }
    }

    // MARK: Following the pointer and keys

    private func startMonitors() {
        stopMonitors()
        // Only while the wheel is up: the pointer, 60 times a second (mouse-moved events don't arrive
        // while a mouse button is held, and the pointer can be anywhere on screen).
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.key(event) ?? false } ? nil : event
        }) { keyMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.model.showNumbers = false }
            return event
        }) { keyMonitors.append(monitor) }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func stopMonitors() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors = []
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        restTask?.cancel()
    }

    private func tick() {
        // A held shortcut is let go when its modifier keys are.
        if holding, let shortcut = heldShortcut, heldButton == nil {
            let down = NSEvent.modifierFlags.intersection(KeyShortcut.relevant)
            if !down.isSuperset(of: shortcut.flags) { released() }
        }
        let pointer = NSEvent.mouseLocation
        guard pointer != lastPointer else { return }   // a still pointer leaves the keys' choice alone
        lastPointer = pointer
        if !armed {
            guard hypot(pointer.x - anchor.x, pointer.y - anchor.y) >= RadialLayout.moveActivationDistance else { return }
            armed = true
        }
        highlight(RadialGeometry.highlightedIndex(dx: pointer.x - center.x, dyUp: pointer.y - center.y,
                                                  deadZoneRadius: RadialLayout.deadZoneRadius * model.scale,
                                                  itemCount: model.slices.count))
    }

    /// Returns true when the key was the wheel's.
    private func key(_ event: NSEvent) -> Bool {
        let count = model.slices.count
        let code = Int(event.keyCode)
        // The summoning key repeating while it's held.
        if holding, let shortcut = heldShortcut, code == Int(shortcut.keyCode) { return true }
        switch code {
        case 123, 126:                        // ← ↑
            highlight(model.lit.map { ($0 - 1 + count) % count } ?? count - 1)
        case 124, 125:                        // → ↓
            highlight(model.lit.map { ($0 + 1) % count } ?? 0)
        case 36, 76:                          // ↵, Enter
            if let lit = model.lit { activate(lit) }
        case 53:                              // Esc: up out of a folder, or close
            back()
        case 51, 117:                         // ⌫: up out of a folder
            if stack.count > 1 { back() }
        default:
            // 1–9, 0, -, = run slices 1–12 (by key position, so ⌥ held for the shortcut doesn't matter).
            let digits = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]
            guard let index = digits.firstIndex(of: code) else { return true }   // other keys do nothing
            model.showNumbers = true
            guard index < count else { NSSound.beep(); return true }
            highlight(index)
            activate(index)
        }
        return true
    }

    // MARK: The panel

    /// The wheel's center: at the pointer (moved in from the screen's edges so the disc fits), or
    /// the middle of the pointer's screen.
    private func position(for pointer: CGPoint, on screen: NSScreen) -> CGPoint {
        let frame = screen.visibleFrame
        if settings.position == .center { return CGPoint(x: frame.midX, y: frame.midY) }
        let margin = RadialLayout.wheelDiameter * model.scale / 2 + 8
        return CGPoint(x: min(max(pointer.x, frame.minX + margin), frame.maxX - margin),
                       y: min(max(pointer.y, frame.minY + margin), frame.maxY - margin))
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the disc draws its own
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        let settings = Features.shared.appSettings ?? SettingsStore()
        panel.appearance = settings.appearance.nsAppearance
        let view = RadialMenuView(model: model) { [weak self] dx, dyUp in self?.click(dx: dx, dyUp: dyUp) }
            .environment(settings)
            .tint(settings.accentColor)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.hosting = hosting
        return panel
    }

    /// Drops the panel (when the feature stops), so a stopped feature holds nothing.
    func tearDown() {
        stopMonitors()
        closing = false
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }
}

// MARK: - The feature

/// Radial Menu: wheels of apps, files, links, utilities and actions, opened by a shortcut or a
/// mouse button. While it's on, it holds only the wheels' hot keys, plus a mouse-button tap when a
/// wheel uses a button (that needs Accessibility). Everything else exists only while a wheel is up.
final class RadialMenuEngine: FeatureEngine {
    static weak var current: RadialMenuEngine?

    /// Mouse buttons a wheel uses right now; Mouse Buttons leaves these alone.
    static var claimedButtons: Set<Int> {
        current == nil ? [] : RadialSettings.shared.claimedButtons
    }

    private let settings = RadialSettings.shared
    private let controller = RadialMenuController()
    private var hotKeys: [GlobalHotKey] = []
    private var running = false
    private lazy var tap = EventTap([.otherMouseDown, .otherMouseUp]) { [weak self] type, event in
        self?.handle(type, event) ?? event
    }

    func start() {
        running = true
        Self.current = self
        follow()
    }

    func stop() {
        running = false
        if Self.current === self { Self.current = nil }
        hotKeys.forEach { $0.unregister() }
        hotKeys = []
        tap.stop()
        controller.tearDown()
        settings.refused = []
    }

    func preview(_ wheel: RadialWheel) { controller.preview(wheel) }

    /// Re-registers the shortcuts and the button tap whenever the wheels or Accessibility change.
    private func follow() {
        guard running else { return }
        withObservationTracking {
            _ = settings.wheels
            _ = Permissions.shared.granted
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        register()
    }

    private func register() {
        var refused: Set<UUID> = []
        for (index, wheel) in settings.wheels.enumerated() {
            if hotKeys.count <= index { hotKeys.append(GlobalHotKey(id: 800 + UInt32(index))) }
            let id = wheel.id
            hotKeys[index].onPress = { [weak self] in self?.pressed(id) }
            if hotKeys[index].shortcut != wheel.shortcut || wheel.shortcut == nil {
                if !hotKeys[index].register(wheel.shortcut) { refused.insert(id) }
            } else if settings.refused.contains(id) {
                refused.insert(id)
            }
        }
        while hotKeys.count > settings.wheels.count { hotKeys.removeLast().unregister() }
        if settings.refused != refused { settings.refused = refused }

        if !settings.claimedButtons.isEmpty, Permissions.shared.isGranted(.accessibility) {
            tap.start()
        } else {
            tap.stop()
        }
    }

    private func pressed(_ id: UUID) {
        guard let wheel = settings.wheels.first(where: { $0.id == id }) else { return }
        controller.summon(wheel, shortcut: wheel.shortcut)
    }

    /// The wheel's mouse buttons: their presses open it, their releases pick, and neither reaches apps.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard let wheel = settings.wheel(forButton: button) else { return event }
        // Showing a window from inside the tap would hold up every click on the Mac; do it next.
        DispatchQueue.main.async { [controller] in
            MainActor.assumeIsolated {
                if type == .otherMouseDown {
                    controller.summon(wheel, button: button)
                } else {
                    controller.buttonReleased(button)
                }
            }
        }
        return nil
    }
}
