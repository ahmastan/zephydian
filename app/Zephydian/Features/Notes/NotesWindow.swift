import AppKit
import SwiftUI

/// The whole Notes page in its own window, opened from the panel's Notes tab. It can be moved and
/// resized anywhere, and pinned on top of other apps (on every Space). Its tabs can be dragged out
/// to float as separate notes.
final class NotesWindow: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 300, height: 320)
        setAccessibilityTitle("Notes")
    }

    override var canBecomeKey: Bool { true }
}

/// Opens, restores and closes the Notes window.
@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let model: AppModel
    private let notes: NotesStore
    private var window: NotesWindow?
    private var keyMonitor: Any?
    private var appliedStyle: PanelStyle?

    init(settings: SettingsStore, model: AppModel, notes: NotesStore) {
        self.settings = settings
        self.model = model
        self.notes = notes
        super.init()
        observe()
    }

    /// At launch: Notes that were in their own window open there again.
    func restore() {
        if settings.notesDetached { open(at: savedFrame()) }
    }

    /// From the panel: the Notes page moves into its own window, where the panel was.
    func detach() {
        let panelFrame = NSApp.windows.first { $0 is FloatingPanel && $0.isVisible }?.frame
        settings.notesDetached = true
        model.isSearchingNotes = false
        open(at: panelFrame ?? savedFrame())
        model.closePanel()
        window?.makeKey()
    }

    /// Notes go back into the panel's Notes tab.
    func attach() {
        settings.notesDetached = false
        model.isSearchingNotes = false
        close()
    }

    func show() {
        guard let window else { return }
        window.orderFrontRegardless()
        window.makeKey()
    }

    private func open(at frame: NSRect?) {
        guard window == nil else { return show() }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = PanelSize.medium.size
        let frame = frame.map(onScreen) ?? NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                                   width: size.width, height: size.height)
        let window = NotesWindow(frame: frame)
        self.window = window
        appliedStyle = nil
        apply()
        window.delegate = self
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            window.animator().alphaValue = 1
        }
        startKeyMonitor()
        settings.notesWindowFrame = NSStringFromRect(frame)
    }

    private func close() {
        guard let window else { return }
        window.delegate = nil
        window.orderOut(nil)
        self.window = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: Look and level

    private func observe() {
        withObservationTracking {
            _ = settings.notesWindowOnTop
            _ = settings.effectivePanelStyle
            _ = settings.appearance
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply()
                self?.observe()
            }
        }
    }

    private func apply() {
        guard let window else { return }
        // Pinned: above other apps and on every Space. Unpinned: an ordinary window.
        window.level = settings.notesWindowOnTop ? .floating : .normal
        window.collectionBehavior = settings.notesWindowOnTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed]
        window.appearance = settings.appearance.nsAppearance
        let style = settings.effectivePanelStyle
        guard style != appliedStyle else { return }
        appliedStyle = style
        let hosting = NSHostingView(rootView: DetachedNotesView()
            .environment(settings).environment(model).environment(notes))
        hosting.sizingOptions = []
        let radius: CGFloat = 20
        if #available(macOS 26, *), style == .glass {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = radius
            hosting.translatesAutoresizingMaskIntoConstraints = true
            hosting.autoresizingMask = [.width, .height]
            glass.contentView = hosting
            window.contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = radius
            effect.layer?.masksToBounds = true
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
            window.contentView = effect
        }
        window.invalidateShadow()
    }

    // MARK: Keys

    /// The Notes shortcuts while this window has the keyboard; Esc closes the search.
    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow, !ShortcutRecording.isActive else { return event }
            if event.keyCode == 53 { // Esc
                guard self.model.isSearchingNotes else { return event }
                self.model.isSearchingNotes = false
                return nil
            }
            return NotesKeys.handle(event, notes: self.notes, model: self.model) ? nil : event
        }
    }

    // MARK: Place

    private func savedFrame() -> NSRect? {
        settings.notesWindowFrame.map(NSRectFromString).flatMap { $0.width > 0 ? $0 : nil }
    }

    /// Keeps the window on a screen that's still connected (or moves it onto the main one).
    private func onScreen(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        if screens.contains(where: { $0.intersection(frame).width >= 80 && $0.intersection(frame).height >= 60 }) { return frame }
        let screen = NSScreen.main?.visibleFrame ?? screens.first ?? frame
        return NSRect(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2, width: frame.width, height: frame.height)
    }

    func windowDidMove(_ notification: Notification) { remember() }
    func windowDidEndLiveResize(_ notification: Notification) { remember() }

    private func remember() {
        guard let window else { return }
        settings.notesWindowFrame = NSStringFromRect(window.frame)
    }
}

/// The Notes window: a header (drag it to move the window) with a pin to keep the window on top and a
/// button to put Notes back in the panel, then the Notes page itself.
private struct DetachedNotesView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Notes")
                    .font(.system(size: 15, weight: .semibold))
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                GlassGroup(spacing: 4) {
                    HStack(spacing: 4) {
                        Button { settings.notesWindowOnTop.toggle() } label: {
                            Image(systemName: settings.notesWindowOnTop ? "pin.fill" : "pin")
                        }
                        .glassIconButtonStyle()
                        .foregroundStyle(settings.notesWindowOnTop ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .help(settings.notesWindowOnTop ? "Pinned on top of other apps (click to unpin)" : "Pin on top of other apps")
                        .accessibilityLabel(settings.notesWindowOnTop ? "Unpin window" : "Pin window on top")

                        Button { model.attachNotes() } label: {
                            Image(systemName: "pip.enter")
                        }
                        .glassIconButtonStyle()
                        .help("Put Notes back in the panel")
                        .accessibilityLabel("Put Notes back in the panel")
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 44)
            .background(WindowDragArea())

            NotesView(isDetached: true)
        }
        // The window's title bar is hidden: use its space instead of leaving a gap above the header.
        .ignoresSafeArea()
        .tint(settings.accentColor)
        .panelButtonStyle()
    }
}
