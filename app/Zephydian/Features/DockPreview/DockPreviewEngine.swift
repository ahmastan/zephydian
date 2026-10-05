import AppKit
import SwiftUI

/// Dock Preview: hover an open app in the Dock and a panel shows its windows.
///
/// Nothing runs while the feature is off. While it's on, the Dock tells us (through Accessibility)
/// which icon the pointer is on, so there's no polling; the mouse is watched only while a preview
/// is open, to close it when the pointer leaves.
final class DockPreviewEngine: FeatureEngine {
    private let settings = DockPreviewSettings.shared
    private let appSettings: SettingsStore
    private let watcher = DockWatcher()
    private let model = DockPreviewModel()
    private let clicks: DockClicks

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var appliedStyle: PanelStyle?
    /// The hovered icon, in AppKit coordinates.
    private var iconFrame: CGRect = .zero
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var followTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var dragging: CGWindowID?
    private let peek = PeekOverlay()
    private let ghost = DragGhost()

    private static let heldKey = "dockPreview.heldAutoHide"
    private var isShown: Bool { panel?.isVisible == true && model.app != nil }

    init(appSettings: SettingsStore) {
        self.appSettings = appSettings
        clicks = DockClicks(watcher: watcher, settings: settings)
    }

    func start() {
        // If Zephydian stopped while it was holding the Dock up, put auto-hide back.
        if UserDefaults.standard.bool(forKey: Self.heldKey) {
            WindowServer.setDockAutoHides(true)
            UserDefaults.standard.removeObject(forKey: Self.heldKey)
        }
        wireModel()
        watcher.onHover = { [weak self] item in self?.hovered(item) }
        watcher.start()
        clicks.start()
    }

    func stop() {
        clicks.stop()
        watcher.stop()
        hide()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        WindowThumbnails.shared.clear()
    }

    // MARK: Hovering the Dock

    private func hovered(_ item: DockItem?) {
        openTask?.cancel()
        guard let item, let app = item.runningApp, eligible(app) else {
            // Off the Dock, or on something that isn't an open app: close unless the pointer is on its way to the panel.
            if isShown { checkPointer() }
            return
        }
        if isShown {
            // Already showing: move straight to this app (a pinned preview follows too).
            show(app, item: item)
            return
        }
        let delay = settings.openDelay
        openTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled, let self, self.watcher.hovered == item else { return }
            self.show(app, item: item)
        }
    }

    private func eligible(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && !(app.bundleIdentifier.map(settings.excludedApps.contains) ?? false)
    }

    // MARK: Showing

    private func show(_ app: NSRunningApplication, item: DockItem) {
        closeTask?.cancel()
        closeTask = nil
        let switching = model.app?.processIdentifier != app.processIdentifier
        model.app = app
        if switching { model.scrollTarget = nil }
        iconFrame = SystemWindows.appKitRect(item.currentFrame ?? item.frame)
        model.vertical = DockWatcher.edge != .minY
        reload()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        applyMaterial()
        panel.appearance = appSettings.appearance.nsAppearance
        panel.setFrame(frame(for: panel), display: true)
        panel.orderFrontRegardless()
        holdDock()
        startWatchingPointer()
        startRefreshing()
        followIcon(item)
    }

    /// The Dock may still be sliding in (auto-hide) or magnifying when the icon is first reported,
    /// so the panel follows the icon until it stops moving.
    private func followIcon(_ item: DockItem) {
        followTask?.cancel()
        followTask = Task { @MainActor [weak self] in
            var still = 0
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled, self.isShown, let panel = self.panel,
                      let frame = item.currentFrame.map(SystemWindows.appKitRect) else { return }
                if frame == self.iconFrame {
                    still += 1
                    if still >= 4 { return }   // settled for 200 ms
                    continue
                }
                still = 0
                self.iconFrame = frame
                panel.setFrame(self.frame(for: panel), display: true)
            }
        }
    }

    private func hide() {
        openTask?.cancel()
        closeTask?.cancel()
        closeTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        followTask?.cancel()
        peekTask?.cancel()
        peek.end()
        ghost.end()
        dragging = nil
        stopWatchingPointer()
        panel?.orderOut(nil)
        model.app = nil
        model.windows = []
        model.pinned = false
        model.hoveredID = nil
        hoveredWindow = nil
        releaseDock()
    }

    /// Reads the app's windows again, in the chosen order.
    private func reload() {
        guard let app = model.app else { return }
        if app.isTerminated { hide(); return }
        var windows = SystemWindows.windows(of: app, allSpaces: !settings.currentSpaceOnly)
        switch settings.order {
        case .recent: windows.sort { ($0.stackOrder, $0.id) < ($1.stackOrder, $1.id) }
        case .creation: windows.sort { $0.id < $1.id }
        }
        model.windows = windows
        WindowThumbnails.shared.refresh(windows.map(\.id), maxSide: settings.size.cardWidth)
        if let panel, isShown { panel.setFrame(frame(for: panel), display: true) }
    }

    /// Keeps the list and pictures current while the preview is open.
    private func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, !Task.isCancelled, self.isShown, self.dragging == nil else { continue }
                self.reload()
            }
        }
    }

    // MARK: The panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        let root = AnyView(DockPreviewView(model: model, settings: settings)
            .environment(appSettings)
            .tint(appSettings.accentColor))
        hosting = NSHostingView(rootView: root)
        return panel
    }

    /// Liquid Glass or Frosted, like Zephydian's corner panel.
    private func applyMaterial() {
        guard let panel, let hosting else { return }
        let style = appSettings.effectivePanelStyle
        guard style != appliedStyle else { return }
        appliedStyle = style
        hosting.removeFromSuperview()
        let radius: CGFloat = 20
        if #available(macOS 26, *), style == .glass {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = radius
            hosting.translatesAutoresizingMaskIntoConstraints = true
            hosting.autoresizingMask = [.width, .height]
            glass.contentView = hosting
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = .roundedMask(radius: radius)
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
            panel.contentView = effect
        }
        panel.invalidateShadow()
    }

    /// The panel's size for its cards, placed next to the hovered icon on the Dock's side.
    private func frame(for panel: NSPanel) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(iconFrame) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let pad = DockPreviewView.padding, gap = DockPreviewView.spacing
        let cardWidth = settings.size.cardWidth
        let cardHeight = DockPreviewView.thumbnailHeight(cardWidth) + 4 + DockPreviewView.titleHeight(minimal: settings.minimal)
        let count = max(model.windows.count, 1)
        let header = DockPreviewView.headerHeight
        var size: CGSize
        if model.windows.isEmpty {
            size = CGSize(width: 240, height: pad * 2 + header + 32)
        } else if model.vertical {
            let fit = max(1, Int((visible.height - pad * 2 - header + gap) / (cardHeight + gap)))
            let shown = CGFloat(min(count, fit))
            size = CGSize(width: max(cardWidth + pad * 2, 240), height: pad * 2 + header + shown * cardHeight + (shown - 1) * gap)
        } else {
            let fit = max(1, Int((visible.width - pad * 2 + gap) / (cardWidth + gap)))
            let shown = CGFloat(min(count, fit))
            size = CGSize(width: max(pad * 2 + shown * cardWidth + (shown - 1) * gap, 240), height: pad * 2 + header + cardHeight)
        }
        size.width = min(size.width, visible.width)
        size.height = min(size.height, visible.height)

        let spacing: CGFloat = 8
        var origin: CGPoint
        switch DockWatcher.edge {
        case .minX: origin = CGPoint(x: iconFrame.maxX + spacing, y: iconFrame.midY - size.height / 2)
        case .maxX: origin = CGPoint(x: iconFrame.minX - spacing - size.width, y: iconFrame.midY - size.height / 2)
        default: origin = CGPoint(x: iconFrame.midX - size.width / 2, y: iconFrame.maxY + spacing)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, screen.frame.minY + 4), visible.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    // MARK: Closing when the pointer leaves

    private func startWatchingPointer() {
        guard monitors.isEmpty else { return }
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.checkPointer() }
            return event
        }) { monitors.append(local) }
        // A middle click on a card closes that window.
        if let middle = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { [weak self] event in
            let onPanel = event.window
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, onPanel === self.panel, let window = self.hoveredWindow else { return false }
                self.close(window)
                return true
            }
            return handled ? nil : event
        }) { monitors.append(middle) }
        // A click anywhere else closes a pinned preview too.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !panel.frame.contains(NSEvent.mouseLocation),
                      !self.iconFrame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }) { monitors.append(outside) }
    }

    private func stopWatchingPointer() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// The icon, the panel, and a narrow bridge between them: wide enough to travel from icon to
    /// panel, narrow enough that the neighbouring icons stay outside.
    private func keepsOpen(_ point: CGPoint) -> Bool {
        guard let panel else { return false }
        if panel.frame.insetBy(dx: -6, dy: -6).contains(point) || iconFrame.insetBy(dx: -2, dy: -2).contains(point) { return true }
        let bridge: CGRect
        switch DockWatcher.edge {
        case .minX, .maxX:
            let x0 = min(iconFrame.maxX, panel.frame.maxX), x1 = max(iconFrame.minX, panel.frame.minX)
            bridge = CGRect(x: min(x0, x1), y: iconFrame.midY - iconFrame.height / 2 - 8, width: abs(x1 - x0), height: iconFrame.height + 16)
        default:
            bridge = CGRect(x: iconFrame.midX - iconFrame.width / 2 - 8, y: iconFrame.maxY - 2,
                            width: iconFrame.width + 16, height: max(0, panel.frame.minY - iconFrame.maxY) + 4)
        }
        return bridge.contains(point)
    }

    private func checkPointer() {
        updateHoveredCard()
        guard isShown, !model.pinned, dragging == nil else { return }
        if keepsOpen(NSEvent.mouseLocation) {
            closeTask?.cancel()
            closeTask = nil
            return
        }
        guard closeTask == nil else { return }
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            self.closeTask = nil
            if !self.keepsOpen(NSEvent.mouseLocation), !self.model.pinned, self.dragging == nil { self.hide() }
        }
    }

    /// Which card the pointer is on, from the cards' frames in the panel.
    private func updateHoveredCard() {
        guard isShown, dragging == nil, let panel else { return }
        let point = NSEvent.mouseLocation
        var id: CGWindowID?
        if panel.frame.contains(point) {
            // The card frames are in the panel's coordinates, top-left origin.
            let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
            id = model.cardFrames.first { $0.value.contains(local) }?.key
        }
        guard id != model.hoveredID else { return }
        model.hoveredID = id
        hoverCard(id.flatMap { id in model.windows.first { $0.id == id } })
    }

    // MARK: Card actions

    private var hoveredWindow: SystemWindow?

    private func wireModel() {
        model.open = { [weak self] window in
            self?.hide()
            SystemWindows.focus(window)
        }
        model.close = { [weak self] window in self?.close(window) }
        model.toggleMinimized = { [weak self] window in
            SystemWindows.setMinimized(window, !window.isMinimized)
            self?.reloadSoon()
        }
        model.togglePin = { [weak self] in
            guard let self else { return }
            self.model.pinned.toggle()
            if !self.model.pinned { self.checkPointer() }
        }
        model.dismiss = { [weak self] in self?.hide() }
        model.dragChanged = { [weak self] window in self?.dragChanged(window) }
        model.dragEnded = { [weak self] window in self?.dragEnded(window) }
        model.arrange = { [weak self] window, layout in
            guard let element = window.element else { return }
            WindowArranger.apply(layout, to: element)
            self?.reloadSoon()
        }
    }

    private func close(_ window: SystemWindow) {
        peek.end()
        if settings.closeQuitsApp, let app = NSRunningApplication(processIdentifier: window.pid) {
            app.terminate()
            hide()
            return
        }
        SystemWindows.close(window)
        reloadSoon()
    }

    private func reloadSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.reload()
        }
    }

    // MARK: Peek

    /// Resting on a card shows that window full size where it is, with everything else dimmed.
    private func hoverCard(_ window: SystemWindow?) {
        hoveredWindow = window
        peekTask?.cancel()
        peek.end()
        guard let window, settings.peek, dragging == nil, !window.isMinimized, !window.isOnOtherSpace,
              !window.isAppHidden, window.frame.width > 0 else { return }
        peekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.hoveredWindow?.id == window.id else { return }
            let image = await WindowThumbnails.shared.capture(window.id, maxSide: max(window.frame.width, window.frame.height))
                ?? WindowThumbnails.shared.image(for: window.id)
            guard !Task.isCancelled, self.hoveredWindow?.id == window.id, let image, let panel = self.panel else { return }
            self.peek.show(image, frame: SystemWindows.appKitRect(window.frame), below: panel)
        }
    }

    // MARK: Drag to move

    private func dragChanged(_ window: SystemWindow) {
        if dragging == nil {
            dragging = window.id
            peekTask?.cancel()
            peek.end()
        }
        let inside = panel?.frame.contains(NSEvent.mouseLocation) ?? true
        if inside {
            ghost.end()
        } else {
            ghost.show(WindowThumbnails.shared.image(for: window.id) ?? model.app?.icon, size: window.frame.size,
                       topLeft: NSEvent.mouseLocation)
        }
    }

    private func dragEnded(_ window: SystemWindow) {
        defer {
            dragging = nil
            ghost.end()
        }
        let point = NSEvent.mouseLocation
        guard let panel, !panel.frame.contains(point) else { return }
        // The window's top-left corner lands where the pointer let go, as the ghost showed.
        SystemWindows.move(window, topLeft: SystemWindows.serverPoint(point))
        reloadSoon()
        if !model.pinned { checkPointer() }
    }

    // MARK: Keeping an auto-hiding Dock up

    private var holdingDock = false

    private func holdDock() {
        guard settings.keepDockVisible, !holdingDock, WindowServer.dockAutoHides == true else { return }
        if WindowServer.setDockAutoHides(false) {
            holdingDock = true
            UserDefaults.standard.set(true, forKey: Self.heldKey)
        }
    }

    private func releaseDock() {
        guard holdingDock else { return }
        holdingDock = false
        WindowServer.setDockAutoHides(true)
        UserDefaults.standard.removeObject(forKey: Self.heldKey)
    }
}

// MARK: - Peek and drag windows

/// A full-size picture of the hovered window at its real place, with the rest of the screen dimmed.
private final class PeekOverlay {
    private var dim: NSWindow?
    private var picture: NSWindow?

    func show(_ image: NSImage, frame: CGRect, below panel: NSPanel) {
        end()
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let screen else { return }
        let dim = Self.overlay(frame: screen.frame, level: NSWindow.Level(rawValue: panel.level.rawValue - 2))
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        let picture = Self.overlay(frame: frame, level: NSWindow.Level(rawValue: panel.level.rawValue - 1))
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.frame = CGRect(origin: .zero, size: frame.size)
        picture.contentView = view
        picture.hasShadow = true
        for window in [dim, picture] {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            dim.animator().alphaValue = 1
            picture.animator().alphaValue = 1
        }
        self.dim = dim
        self.picture = picture
    }

    func end() {
        dim?.orderOut(nil)
        picture?.orderOut(nil)
        dim = nil
        picture = nil
    }

    private static func overlay(frame: CGRect, level: NSWindow.Level) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = level
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return window
    }
}

/// The see-through picture that follows the pointer while a card is dragged out of the panel.
/// The real window only moves when the pointer lets go.
private final class DragGhost {
    private var window: NSWindow?

    func show(_ image: NSImage?, size: CGSize, topLeft: CGPoint) {
        let scale = min(1, 320 / max(size.width, size.height, 1))
        let ghostSize = CGSize(width: max(size.width * scale, 80), height: max(size.height * scale, 50))
        let frame = CGRect(x: topLeft.x, y: topLeft.y - ghostSize.height, width: ghostSize.width, height: ghostSize.height)
        if window == nil {
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .popUpMenu
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.alphaValue = 0.7
            window.hasShadow = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = NSImageView(image: image ?? NSImage())
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.cornerRadius = 8
            view.layer?.masksToBounds = true
            window.contentView = view
            window.orderFrontRegardless()
            self.window = window
        }
        window?.setFrame(frame, display: true)
    }

    func end() {
        window?.orderOut(nil)
        window = nil
    }
}
