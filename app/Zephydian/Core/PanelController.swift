import AppKit
import SwiftUI

/// A borderless floating panel that can take keyboard input without activating
/// Zephydian (so the app you were using stays in front, like Spotlight).
final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel: showing/hiding, positioning at the chosen corner, auto-hide,
/// click-outside-to-close and keyboard shortcuts.
final class PanelController: NSObject {
    var onVisibilityChange: (Bool) -> Void = { _ in }
    private(set) var isOpen = false

    private let panel: FloatingPanel
    private let settings: SettingsStore
    private let model: AppModel
    private let notes: NotesStore
    private let hosting: NSView
    /// Holds the glass/frosted background. The open/close animation scales this view.
    private let container = NSView()
    private var appliedStyle: PanelStyle?
    /// Ignores completion callbacks from animations that were interrupted (e.g. reopened mid-close).
    private var animationGeneration = 0
    private var armed = false            // auto-hide arms once the mouse has been inside the panel
    private var hideTask: Task<Void, Never>?
    private var clickMonitor: Any?
    /// True while any menu (a dropdown, the ⋯ menu, a picker) is open. Auto-hide waits for it to close.
    private var menuIsOpen = false
    private var keyMonitor: Any?
    private var keyUpMonitor: Any?

    /// A "leave" only counts once the mouse is this far outside the panel.
    private static let leaveMargin: CGFloat = 24

    init(settings: SettingsStore, model: AppModel, notes: NotesStore) {
        self.settings = settings
        self.model = model
        self.notes = notes
        panel = FloatingPanel(size: Tokens.panelSize)
        let hostingView = NSHostingView(rootView: RootView().environment(settings).environment(model).environment(notes))
        hostingView.sizingOptions = []
        hosting = hostingView
        super.init()
        container.wantsLayer = true
        panel.contentView = container
        applyMaterial()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, self.panel.isKeyWindow else { return event }
            return self.handleKey(event) ? nil : event
        }
        // Real-time games (Airship) need to know when a held key is released.
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, self.isOpen, self.model.isShowingGame, let game = self.model.gameSession else { return event }
            return game.handleKeyUp(event) ? nil : event
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        applyAppearance()
    }

    // MARK: Show / hide

    func toggle() { isOpen ? hide() : show() }

    func show() {
        guard !isOpen else { return }
        isOpen = true
        armed = false
        if !model.isOnboarding {
            notes.reloadChangedFiles()
            model.panelOpenCount += 1
        }
        panel.setFrame(targetFrame(), display: false)
        animateCorner(opening: true)
        panel.makeKeyAndOrderFront(nil)
        startClickMonitor()
        onVisibilityChange(true)
    }

    func hide() {
        guard isOpen else { return }
        isOpen = false
        cancelAutoHide()
        stopClickMonitor()
        notes.flush()
        model.gameSession?.pause()
        animateCorner(opening: false) { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.orderOut(nil)
        }
        onVisibilityChange(false)
    }

    // MARK: Open/close animation

    /// Opening: the panel grows smoothly out of its corner (and fades in).
    /// Closing: it shrinks back into the corner (and fades out).
    /// It scales the already-drawn panel on the GPU, so nothing re-lays out mid-animation.
    /// With Reduce Motion on, it simply fades.
    private func animateCorner(opening: Bool, completion: @escaping () -> Void = {}) {
        guard let layer = container.layer else { completion(); return }
        animationGeneration += 1
        let generation = animationGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let collapsed = reduceMotion ? CATransform3DIdentity : collapsedTransform(for: layer)
        let wasVisible = panel.isVisible
        // Start from wherever an interrupted animation left off, so reversing mid-way stays smooth.
        let presentation = layer.presentation()
        let startTransform = opening && !wasVisible ? collapsed : (presentation?.transform ?? layer.transform)
        let startOpacity: Float = opening && !wasVisible ? 0 : (presentation?.opacity ?? layer.opacity)
        let endTransform = opening ? CATransform3DIdentity : collapsed
        let endOpacity: Float = opening ? 1 : 0

        layer.removeAnimation(forKey: "zephydian.corner")
        panel.hasShadow = false // the window shadow can't follow a scaling panel; restore it afterwards
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = endTransform
        layer.opacity = endOpacity
        CATransaction.commit()

        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: startTransform)
        scale.toValue = NSValue(caTransform3D: endTransform)

        let fade: CAAnimation
        if opening {
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = startOpacity
            fadeIn.toValue = endOpacity
            fadeIn.duration = reduceMotion ? 0.18 : 0.2
            fade = fadeIn
        } else {
            let fadeOut = CAKeyframeAnimation(keyPath: "opacity")
            fadeOut.values = [startOpacity, startOpacity * 0.9, 0]
            fadeOut.keyTimes = [0, 0.45, 1] // stays visible while shrinking, then fades as it reaches the corner
            fadeOut.duration = reduceMotion ? 0.15 : 0.24
            fade = fadeOut
        }

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        if opening {
            group.duration = reduceMotion ? 0.18 : 0.34
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1) // quick start, soft landing
        } else {
            group.duration = reduceMotion ? 0.15 : 0.24
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.9, 0.55) // gentle start, speeds into the corner
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.animationGeneration else { return }
                if opening {
                    self.panel.hasShadow = true
                    self.panel.invalidateShadow()
                }
                completion()
            }
        }
        layer.add(group, forKey: "zephydian.corner")
        CATransaction.commit()
    }

    /// A tiny version of the panel, sitting at the panel's corner nearest the screen corner.
    private func collapsedTransform(for layer: CALayer) -> CATransform3D {
        let size = container.bounds.size
        let scale: CGFloat = model.isOnboarding ? 0.92 : 0.06
        // The point everything shrinks toward, in the view's coordinates (origin bottom-left).
        let pivot: CGPoint
        if model.isOnboarding {
            pivot = CGPoint(x: size.width / 2, y: size.height / 2)
        } else {
            let corner = settings.corner
            pivot = CGPoint(x: corner.isLeft ? 0 : size.width, y: corner.isTop ? size.height : 0)
        }
        // Layer transforms act around the layer's anchor point, so scale around the pivot instead.
        let anchor = CGPoint(x: layer.anchorPoint.x * size.width, y: layer.anchorPoint.y * size.height)
        let offset = CGPoint(x: (pivot.x - anchor.x) * (1 - scale), y: (pivot.y - anchor.y) * (1 - scale))
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(offset.x, offset.y, 0))
    }

    /// Shows the first-launch welcome card, centered on screen.
    func showOnboarding() {
        if isOpen {
            hide()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(160))
                self?.model.isOnboarding = true
                self?.show()
            }
        } else {
            model.isOnboarding = true
            show()
        }
    }

    func finishOnboarding() {
        settings.hasCompletedOnboarding = true
        hide()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            self?.model.isOnboarding = false
        }
    }

    // MARK: Appearance & position

    func applyAppearance() {
        panel.appearance = settings.appearance.nsAppearance
    }

    /// Builds the panel's background: Liquid Glass on macOS 26+ (if chosen), otherwise the frosted blur.
    func applyMaterial() {
        let style = settings.effectivePanelStyle
        guard style != appliedStyle else { return }
        appliedStyle = style
        hosting.removeFromSuperview()
        container.subviews.forEach { $0.removeFromSuperview() }
        let background: NSView

        if #available(macOS 26, *), style == .glass {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = style.cornerRadius // nothing is drawn over the glass: Apple's own rim and shadow do the edges
            // The glass view sizes its content itself, so undo any constraints from the frosted layout.
            hosting.translatesAutoresizingMaskIntoConstraints = true
            hosting.autoresizingMask = [.width, .height]
            glass.contentView = hosting
            background = glass
        } else {
            let effect = NSVisualEffectView()
            // .menu is Apple's classic frosted material (menus, Control Center before macOS 26).
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = .roundedMask(radius: style.cornerRadius)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            background = effect
        }
        background.frame = container.bounds
        background.autoresizingMask = [.width, .height]
        container.addSubview(background)
        panel.invalidateShadow()
    }

    /// Moves the panel to the current corner/display (e.g. after changing the corner in Settings).
    func reposition() {
        guard isOpen else { return }
        panel.setFrame(targetFrame(), display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    @objc private func screensChanged() { reposition() }

    private func targetFrame() -> NSRect {
        guard let visible = settings.targetScreen?.visibleFrame else { return panel.frame }
        let inset = Tokens.edgeInset
        let size = NSSize(width: Tokens.panelSize.width,
                          height: min(Tokens.panelSize.height, visible.height - inset * 2))
        if model.isOnboarding {
            return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        let corner = settings.corner
        let x = corner.isLeft ? visible.minX + inset : visible.maxX - inset - size.width
        let y = corner.isTop ? visible.maxY - inset - size.height : visible.minY + inset
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Auto-hide

    @objc private func menuBegan() {
        menuIsOpen = true
        cancelAutoHide()
    }

    @objc private func menuEnded() { menuIsOpen = false }

    /// The pointer counts as "inside" over the panel, any other Zephydian window (menus, dialogs),
    /// or the strip between the panel and its corner (you're usually heading there to close it).
    private func pointerIsInside(_ p: NSPoint) -> Bool {
        let frame = panel.frame
        if frame.contains(p) { return true }
        for window in NSApp.windows where window !== panel && window.isVisible && window.frame.width > 4 && window.frame.contains(p) {
            return true
        }
        if !model.isOnboarding, let screen = settings.targetScreen?.frame {
            let corner = settings.corner
            let cornerPoint = NSPoint(x: corner.isLeft ? screen.minX : screen.maxX, y: corner.isTop ? screen.maxY : screen.minY)
            let path = frame.union(NSRect(x: cornerPoint.x, y: cornerPoint.y, width: 0, height: 0))
            if path.contains(p) { return true }
        }
        return false
    }

    private var autoHideAllowed: Bool {
        if menuIsOpen { return false }
        return switch settings.autoHide {
        case .never: false
        case .always: true
        case .smart: !model.isPlayingGame && !model.isTypingNote
        }
    }

    func mouseMoved(to p: NSPoint) {
        guard isOpen, !model.isOnboarding else { return }
        let f = panel.frame
        if pointerIsInside(p) {
            if f.contains(p) { armed = true }
            cancelAutoHide()
            return
        }
        let dx = max(f.minX - p.x, 0, p.x - f.maxX)
        let dy = max(f.minY - p.y, 0, p.y - f.maxY)
        if hypot(dx, dy) <= Self.leaveMargin {
            cancelAutoHide()
            return
        }
        guard armed, hideTask == nil, autoHideAllowed else { return }
        let delay = settings.hideDelayMs
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.hideTask = nil
            // Last check with the real pointer position: never hide while it's on the panel or a menu.
            guard self.autoHideAllowed, !self.pointerIsInside(NSEvent.mouseLocation) else { return }
            self.hide()
        }
    }

    private func cancelAutoHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    // MARK: Click outside

    private func startClickMonitor() {
        guard clickMonitor == nil else { return }
        // Global monitors only see clicks in *other* apps, which is exactly "outside".
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, !self.model.isOnboarding else { return }
            self.hide()
        }
    }

    private func stopClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: Keyboard

    /// Returns true if the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { // Esc
            if model.isRenamingNote { return false } // let the rename field cancel itself
            if model.isOnboarding {
                finishOnboarding()
            } else if model.isShowingGame {
                model.closeGame()
            } else {
                hide()
            }
            return true
        }
        // Games get plain keys (arrows, Space, letters) before anything else.
        if model.isShowingGame, !flags.contains(.command), let game = model.gameSession, game.handleKey(event) {
            return true
        }
        if model.tab == .notes, !model.isShowingGame, !model.isOnboarding, handleNotesKey(event, flags: flags) {
            return true
        }
        guard flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if key == "q" {
            NSApp.terminate(nil)
            return true
        }
        guard !model.isOnboarding else { return false }
        switch key {
        case "1", "2", "3", ",":
            if model.isShowingGame { model.closeGame() }
            model.tab = key == "1" ? .games : key == "2" ? .notes : .settings
        case "w": hide()
        default: return false
        }
        return true
    }

    /// Notes-tab shortcuts: ⌘T new note, ⌘W close note, ⌃Tab / ⌃⇧Tab switch notes.
    private func handleNotesKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 48, flags.contains(.control) { // Tab
            notes.selectNext(offset: flags.contains(.shift) ? -1 : 1)
            return true
        }
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "t":
            notes.addNote()
            return true
        case "w" where notes.notes.count > 1:
            if let id = notes.activeID { notes.requestDelete(id) }
            return true
        default:
            return false
        }
    }
}

private extension NSImage {
    /// A stretchable rounded-rectangle mask, used to round the blurred background's corners.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
