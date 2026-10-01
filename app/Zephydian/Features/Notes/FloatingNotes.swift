import AppKit
import SwiftUI

/// A pinned note's own window. It floats above other apps on every Space (and over full-screen apps),
/// can be moved by its header and resized from its edges, and stays where it was put, even after a restart.
final class FloatingNoteWindow: NSPanel {
    let noteID: UUID

    init(noteID: UUID, frame: NSRect) {
        self.noteID = noteID
        super.init(contentRect: frame,
                   styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 200, height: 150)
    }

    override var canBecomeKey: Bool { true }
}

/// Keeps one floating window open for each pinned note, and closes it when the note is unpinned or deleted.
@MainActor
final class NoteWindows: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 260, height: 280)
    /// Where the pointer holds a note's window while a tab is dragged out: on its header, near the name.
    static let grabPoint = CGPoint(x: 60, y: 18)
    /// The one in use, so a tab being dragged in the panel can move its note's window.
    private(set) static weak var current: NoteWindows?

    private let notes: NotesStore
    private let settings: SettingsStore
    private var windows: [UUID: FloatingNoteWindow] = [:]
    private var appliedStyle: PanelStyle?
    /// Each note's stored frame as last seen. A window moves only when the stored frame changes
    /// (a tab dragged out somewhere new), never back to an old one while its new place waits to be saved.
    private var seenFrames: [UUID: CGRect] = [:]
    private var saveTasks: [UUID: Task<Void, Never>] = [:]
    /// "Search All Notes…" in a floating note: opens the panel's Notes search.
    var onSearch: () -> Void = {}

    init(notes: NotesStore, settings: SettingsStore) {
        self.notes = notes
        self.settings = settings
        super.init()
    }

    func start() {
        Self.current = self
        sync()
        observe()
    }

    /// Opens or closes windows now (instead of on the next change notification).
    func syncNow() { sync() }

    /// Moves a note's window so the pointer (at `point`, screen coordinates) is on its header.
    func move(_ id: UUID, pointerAt point: NSPoint) {
        guard let window = windows[id] else { return }
        window.setFrameTopLeftPoint(NSPoint(x: point.x - Self.grabPoint.x, y: point.y + Self.grabPoint.y))
        scheduleSave(id)
    }

    /// Saves a window's place right away (at the end of a drag).
    func saveFrame(_ id: UUID) {
        guard let window = windows[id] else { return }
        saveTasks[id]?.cancel()
        notes.setFloatFrame(id, window.frame)
    }

    private func observe() {
        withObservationTracking {
            _ = notes.notes.map { ($0.id, $0.isPinned, $0.floatFrame) }
            _ = settings.effectivePanelStyle
            _ = settings.appearance
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.observe()
            }
        }
    }

    private func sync() {
        let pinned = notes.notes.filter(\.isPinned)
        let pinnedIDs = Set(pinned.map(\.id))
        for (id, window) in windows where !pinnedIDs.contains(id) {
            window.delegate = nil
            window.orderOut(nil)
            windows[id] = nil
            seenFrames[id] = nil
            saveTasks[id]?.cancel()
        }
        let style = settings.effectivePanelStyle
        if style != appliedStyle {
            // The look changed: rebuild every window's background.
            appliedStyle = style
            for window in windows.values { setContent(of: window) }
        }
        for note in pinned {
            if let window = windows[note.id] {
                // Given a new place from the panel (a tab dragged out again): move there.
                if let frame = note.floatFrame, frame != seenFrames[note.id] {
                    seenFrames[note.id] = frame
                    if frame != window.frame { window.setFrame(onScreen(frame), display: true) }
                }
            } else {
                let frame = onScreen(note.floatFrame ?? defaultFrame())
                let window = FloatingNoteWindow(noteID: note.id, frame: frame)
                setContent(of: window)
                window.delegate = self
                windows[note.id] = window
                seenFrames[note.id] = note.floatFrame
                // Appears with a quick fade, like a tab torn out of a browser.
                window.alphaValue = 0
                window.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                    window.animator().alphaValue = 1
                }
                if note.floatFrame != frame { notes.setFloatFrame(note.id, frame) }
            }
        }
        for window in windows.values { window.appearance = settings.appearance.nsAppearance }
    }

    private func setContent(of window: FloatingNoteWindow) {
        let hosting = NSHostingView(rootView: FloatingNoteView(noteID: window.noteID) { [weak self] in self?.onSearch() }
            .environment(notes).environment(settings))
        hosting.sizingOptions = []
        let style = settings.effectivePanelStyle
        let radius: CGFloat = 16
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

    /// A new floating note appears beside the panel (on the side with more room), stepped down
    /// a little for each note already floating so they don't stack exactly.
    private func defaultFrame() -> NSRect {
        let size = Self.defaultSize
        let step = CGFloat(windows.count % 6) * 24
        guard let panel = NSApp.windows.first(where: { $0 is FloatingPanel && $0.isVisible }),
              let screen = panel.screen?.visibleFrame else {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSRect(x: screen.midX - size.width / 2 + step, y: screen.midY - size.height / 2 - step,
                          width: size.width, height: size.height)
        }
        let roomLeft = panel.frame.minX - screen.minX, roomRight = screen.maxX - panel.frame.maxX
        let x = roomLeft >= roomRight ? panel.frame.minX - size.width - 16 - step : panel.frame.maxX + 16 + step
        let y = panel.frame.maxY - size.height - step
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Keeps a saved frame on a screen that's still connected (or moves it onto the main one).
    private func onScreen(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame)
        if screens.contains(where: { $0.intersection(frame).width >= 60 && $0.intersection(frame).height >= 40 }) { return frame }
        let screen = NSScreen.main?.visibleFrame ?? screens.first ?? frame
        return NSRect(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2, width: frame.width, height: frame.height)
    }

    /// Where a tab dropped at `point` (outside the panel) floats: its header under the pointer.
    static func frame(droppedAt point: NSPoint, size: NSSize = defaultSize) -> NSRect {
        NSRect(x: point.x - grabPoint.x, y: point.y + grabPoint.y - size.height, width: size.width, height: size.height)
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) { remember(notification) }
    func windowDidEndLiveResize(_ notification: Notification) { remember(notification) }
    /// Resized in code (not by the person dragging an edge, which is saved once when it ends).
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !window.inLiveResize else { return }
        remember(notification)
    }

    /// Saves a moved or resized window's place, once it has stopped moving for a moment.
    private func remember(_ notification: Notification) {
        guard let window = notification.object as? FloatingNoteWindow else { return }
        scheduleSave(window.noteID)
    }

    private func scheduleSave(_ id: UUID) {
        guard windows[id] != nil else { return }
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let window = self.windows[id] else { return }
            self.notes.setFloatFrame(id, window.frame)
        }
    }
}

/// What a floating note shows: its name (click to rename), Preview, the ⋯ menu and Unpin, then the note.
private struct FloatingNoteView: View {
    let noteID: UUID
    let onSearch: () -> Void
    @Environment(NotesStore.self) private var notes
    @Environment(SettingsStore.self) private var settings
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var exported = false

    var body: some View {
        if let note = notes.notes.first(where: { $0.id == noteID }) {
            VStack(spacing: 0) {
                header(note)
                Divider().padding(.horizontal, 12)
                Group {
                    if note.showsPreview {
                        NotePreview(text: note.body, fontSize: NoteHeadings.baseSize, monospaced: settings.notesMonospaced) {
                            notes.toggleCheckbox(line: $0, in: noteID)
                        }
                    } else {
                        // The note takes the cursor, not the name field (AppKit's pick for a new window).
                        NoteEditor(text: note.body, monospaced: settings.notesMonospaced, focusRequest: 1) {
                            notes.updateBody(noteID, $0)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            // The window's title bar is hidden: use its space instead of leaving a gap above the header.
            .ignoresSafeArea()
            .tint(settings.accentColor)
            .panelButtonStyle()
            .onAppear { title = note.title }
            .onChange(of: note.title) { if !titleFocused { title = note.title } }
        }
    }

    private func header(_ note: Note) -> some View {
        HStack(spacing: 6) {
            TextField("Name", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .focused($titleFocused)
                .onSubmit { commitTitle(note) }
                .onExitCommand { title = note.title; titleFocused = false }
                .onChange(of: titleFocused) { if !titleFocused { commitTitle(note) } }
                .fixedSize()
                .frame(maxWidth: 150, alignment: .leading)
                .help("Click to rename")
                .accessibilityLabel("Note name")
            if exported {
                Text("Exported \(Image(systemName: "checkmark"))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
            GlassGroup(spacing: 4) {
                HStack(spacing: 4) {
                    Button { notes.setPreview(noteID, !note.showsPreview) } label: {
                        Image(systemName: note.showsPreview ? "pencil" : "eye")
                    }
                    .glassIconButtonStyle()
                    .help(note.showsPreview ? "Edit" : "Preview")
                    .accessibilityLabel(note.showsPreview ? "Edit note" : "Preview note")

                    menu(note)

                    Button { notes.setPinned(noteID, false) } label: {
                        Image(systemName: "pin.fill")
                    }
                    .glassIconButtonStyle()
                    .foregroundStyle(.tint)
                    .help("Unpin (the note stays in the panel)")
                    .accessibilityLabel("Unpin \(note.title)")
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(WindowDragArea())
    }

    /// The same choices as the panel's ⋯ menu, for this note.
    private func menu(_ note: Note) -> some View {
        @Bindable var settings = settings
        return Menu {
            Toggle("Monospace Font", isOn: $settings.notesMonospaced)
            Divider()
            Button("Search All Notes…") { onSearch() }
            Button(note.showsPreview ? "Edit" : "Preview") { notes.setPreview(noteID, !note.showsPreview) }
            Button("Rename…") { titleFocused = true }
            Button("Unpin from Screen") { notes.setPinned(noteID, false) }
            Divider()
            Button("Export “\(note.title)”…") { notes.export(noteID, done: showExported) }
            Button("Export All Notes…") { notes.exportAll(done: showExported) }
            Button("Reveal in Finder") { notes.revealInFinder(noteID) }
            Divider()
            Button("Delete “\(note.title)”…", role: .destructive) { confirmDelete(note) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .glassIconMenuStyle()
        .accessibilityLabel("More options")
    }

    private func commitTitle(_ note: Note) {
        if title.trimmingCharacters(in: .whitespaces).isEmpty || !notes.rename(noteID, to: title) {
            title = note.title
        } else if let renamed = notes.notes.first(where: { $0.id == noteID }) {
            title = renamed.title   // it may have been cleaned up or numbered
        }
    }

    private func showExported(_ ok: Bool) {
        guard ok else { return }
        exported = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            exported = false
        }
    }

    /// Empty notes go straight away; others ask first, on this window (the panel may be closed).
    private func confirmDelete(_ note: Note) {
        guard !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let window = NSApp.windows.first(where: { ($0 as? FloatingNoteWindow)?.noteID == noteID }) else {
            notes.delete(noteID)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete “\(note.title)”?"
        alert.informativeText = "The note will be moved to the Trash, so you can still recover it from there."
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { notes.delete(noteID) }
            }
        }
    }
}

/// Dragging here moves the window (SwiftUI has no window-drag gesture on macOS 14).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
