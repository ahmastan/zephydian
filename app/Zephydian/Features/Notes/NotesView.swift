import SwiftUI

/// The Notes tab: pill tabs, a plain-text editor (or its Markdown preview) and a status footer.
/// ⌘F swaps the tabs and editor for a search across every note.
/// The same view fills the Notes window when Notes are detached from the panel (`isDetached`).
struct NotesView: View {
    /// In the Notes window rather than the panel. Only there can a tab be dragged out to float on its own.
    var isDetached = false

    @Environment(NotesStore.self) private var notes
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model

    @State private var editorFocused = false
    @State private var focusRequest = 0
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var exported = false
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var hoveredID: UUID?
    /// The tab being dragged: along the strip to reorder, or out of the panel to float it.
    @State private var tabDrag: TabDrag?
    @State private var tabFrames: [UUID: CGRect] = [:]

    private struct TabDrag {
        let id: UUID
        let from: Int
        var translation: CGFloat = 0
        var target: Int
        var outside = false
    }

    var body: some View {
        if settings.notesDetached && !isDetached {
            detachedMessage
        } else {
            page
        }
    }

    /// The panel's Notes tab while Notes are in their own window.
    private var detachedMessage: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("Notes are open in their own window")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Button("Show Window") { model.showNotesWindow() }
                Button("Put Back in Panel") { model.attachNotes() }
                    .prominentButtonStyle()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    private var page: some View {
        VStack(spacing: 0) {
            Group {
                if model.isSearchingNotes { searchBar } else { tabBar }
            }
            .padding(.bottom, 8)
            Divider()
            content
            Divider()
            footer.padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .onAppear {
            // Opened by a floating note's "Search All Notes…".
            if model.isSearchingNotes { query = ""; searchFocused = true } else { focusEditor() }
        }
        .onChange(of: model.panelOpenCount) { if model.isSearchingNotes { searchFocused = true } else { focusEditor() } }
        .onChange(of: model.isSearchingNotes) {
            if model.isSearchingNotes {
                if renamingID != nil { commitRename() }
                query = ""
                searchFocused = true
            } else {
                focusEditor()
            }
        }
        .onChange(of: notes.activeNote?.showsPreview) { focusEditor() }
        .onChange(of: editorFocused) { updateTyping() }
        .onChange(of: searchFocused) { updateTyping() }
        .onChange(of: renamingID) {
            if !isDetached { model.isRenamingNote = renamingID != nil }
            updateTyping()
        }
        .onDisappear {
            guard !isDetached else { return }
            model.isTypingNote = false
            model.isRenamingNote = false
            model.isSearchingNotes = false
        }
        .alert(
            "Delete “\(notes.pendingDeletion?.title ?? "")”?",
            isPresented: Binding(get: { notes.pendingDeletion != nil }, set: { if !$0 { notes.pendingDeletion = nil } }),
            presenting: notes.pendingDeletion
        ) { note in
            Button("Move to Trash", role: .destructive) { notes.delete(note.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The note will be moved to the Trash, so you can still recover it from there.")
        }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            NoteTabStrip(activeID: notes.activeID) {
                ForEach(Array(notes.notes.enumerated()), id: \.element.id) { index, note in
                    pill(for: note)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: NoteTabFramesKey.self, value: [note.id: geometry.frame(in: .named(noteTabSpace))])
                        })
                        .offset(x: tabOffset(note.id, index: index))
                        .opacity(tabDrag?.id == note.id && tabDrag?.outside == true ? 0 : 1)
                        .zIndex(tabDrag?.id == note.id ? 1 : 0)
                        // The other tabs slide aside; the held tab follows the pointer exactly.
                        .animation(tabDrag?.id == note.id ? nil : .easeOut(duration: 0.15), value: tabDrag?.target)
                        .gesture(tabDragGesture(note, index: index))
                }
            }
            .onPreferenceChange(NoteTabFramesKey.self) { tabFrames = $0 }
            // Both buttons are glass controls, so they share one glass group.
            GlassGroup(spacing: 4) {
                HStack(spacing: 4) {
                    previewButton
                    addButton
                    if !isDetached { detachButton }
                    moreMenu
                }
            }
        }
    }

    private var addButton: some View {
        Button { addNote() } label: {
            Image(systemName: "plus")
        }
        .glassIconButtonStyle()
        .disabled(!notes.canAddNote)
        .help(notes.canAddNote ? "New note (⌘T)" : "Up to \(NotesStore.maxNotes) notes")
        .accessibilityLabel("New note")
    }

    private var detachButton: some View {
        Button { model.detachNotes() } label: {
            Image(systemName: "pip.exit")
        }
        .glassIconButtonStyle()
        .help("Open Notes in a separate window")
        .accessibilityLabel("Open Notes in a separate window")
    }

    private var previewButton: some View {
        let previewing = notes.activeNote?.showsPreview == true
        return Button { togglePreview() } label: {
            Image(systemName: previewing ? "pencil" : "eye")
        }
        .glassIconButtonStyle()
        .help(previewing ? "Edit (⌘E)" : "Preview (⌘E)")
        .accessibilityLabel(previewing ? "Edit note" : "Preview note")
    }

    private var moreMenu: some View {
        @Bindable var settings = settings
        return Menu {
            Toggle("Monospace Font", isOn: $settings.notesMonospaced)
            Divider()
            Button("Search All Notes…") { model.isSearchingNotes = true }
            if let note = notes.activeNote {
                Button(note.showsPreview ? "Edit" : "Preview") { togglePreview() }
                Button("Rename “\(note.title)”…") { startRename(note) }
                Divider()
                Button("Export “\(note.title)”…") { export(note.id) }
            }
            Button("Export All Notes…") { export(nil) }
            Button("Reveal in Finder") { notes.revealInFinder() }
            if let note = notes.activeNote {
                Divider()
                Button("Delete “\(note.title)”…", role: .destructive) { notes.requestDelete(note.id) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .glassIconMenuStyle()
        .accessibilityLabel("More options")
    }

    @ViewBuilder
    private func pill(for note: Note) -> some View {
        let isActive = note.id == notes.activeID
        let hovered = (isActive || hoveredID == note.id) && renamingID != note.id
        // Pinned (floating) notes can't be closed from their tab (Delete is still in the menus).
        let showsClose = !note.isPinned && hovered
        // A note is pinned by dragging its tab out of the panel; then its tab shows a pin to unpin it.
        let showsPin = note.isPinned

        HStack(spacing: 4) {
            if renamingID == note.id {
                RenameField(text: $renameText, onCommit: commitRename, onCancel: cancelRename)
                    .frame(width: 96, height: 16)
            } else {
                Text(note.title).lineLimit(1)
            }
            if showsPin {
                Button { notes.setPinned(note.id, false) } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Unpin from the screen")
                .accessibilityLabel("Unpin \(note.title) from the screen")
            }
            if showsClose {
                Button { notes.requestDelete(note.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close \(note.title)")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isActive ? .primary : .secondary)
        .padding(.leading, 10)
        .padding(.trailing, showsClose || showsPin ? 6 : 10)
        .frame(height: 24)
        .background {
            // The active tab is a glass capsule, like the selected top tab. Not interactive glass,
            // so clicks, double-click to rename, drags and right-clicks all reach the tab.
            if !isActive { Capsule().fill(hoveredID == note.id ? Tokens.fillHover : Tokens.fill) }
        }
        .modifier(ActiveTabGlass(isActive: isActive, accent: settings.accentColor))
        .contentShape(Capsule())
        .onTapGesture {
            notes.select(note.id)
            focusEditor()
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(note) })
        .onHover { hoveredID = $0 ? note.id : (hoveredID == note.id ? nil : hoveredID) }
        .contextMenu {
            if note.isPinned { Button("Unpin from Screen") { notes.setPinned(note.id, false) } }
            Button("Rename…") { startRename(note) }
            Button("Move Left") { notes.move(note.id, by: -1) }
                .disabled(note.id == notes.notes.first?.id)
            Button("Move Right") { notes.move(note.id, by: 1) }
                .disabled(note.id == notes.notes.last?.id)
            Divider()
            Button("Export…") { export(note.id) }
            Button("Reveal in Finder") {
                notes.select(note.id)
                notes.revealInFinder()
            }
            Divider()
            Button("Delete…", role: .destructive) { notes.requestDelete(note.id) }
        }
        .help(note.isPinned ? "Double-click to rename · drag to reorder · drag out of the panel to move its window"
                            : "Double-click to rename · drag to reorder · drag out of the panel to pin it to the screen")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(note.isPinned ? "\(note.title), pinned" : note.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        // Dragging can't be done with VoiceOver or the keyboard, so pinning is also an action here.
        .accessibilityAction(named: note.isPinned ? "Unpin from Screen" : "Pin to Screen") { notes.setPinned(note.id, !note.isPinned) }
    }

    // MARK: Editor, preview & footer

    @ViewBuilder private var content: some View {
        if model.isSearchingNotes {
            results
        } else if let note = notes.activeNote, note.showsPreview {
            NotePreview(text: note.body, fontSize: NoteHeadings.baseSize, monospaced: settings.notesMonospaced) {
                notes.toggleCheckbox(line: $0)
            }
        } else {
            editor
        }
    }

    private var editor: some View {
        NoteEditor(text: notes.activeNote?.body ?? "", monospaced: settings.notesMonospaced, focusRequest: focusRequest,
                   onChange: { notes.updateActiveBody($0) }, onFocus: { editorFocused = $0 })
            .padding(.vertical, 6)
            // A new note gets a fresh editor (and its own undo history).
            .id(notes.activeID)
    }

    private var footer: some View {
        HStack {
            if model.isSearchingNotes {
                Text(matchSummary)
                Spacer()
            } else {
                Text(wordCount)
                Spacer()
                saveStatus
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }

    @ViewBuilder private var saveStatus: some View {
        if exported {
            Text("Exported \(Image(systemName: "checkmark"))")
        } else {
            switch notes.saveState {
            case .saved: Text("Saved \(Image(systemName: "checkmark"))")
            case .editing: Text("Editing…")
            case .failed: Text("Couldn’t save").foregroundStyle(.red)
            }
        }
    }

    private var wordCount: String {
        let count = notes.activeNote?.body.split(whereSeparator: \.isWhitespace).count ?? 0
        return "\(count) word\(count == 1 ? "" : "s")"
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all notes", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = notes.search(query).first { open(first) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Tokens.fill))

            Button("Done") { model.isSearchingNotes = false }
                .help("Close search (Esc)")
        }
    }

    private var results: some View {
        let matches = notes.search(query)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(matches.enumerated()), id: \.element.id) { i, match in
                    if i == 0 || matches[i - 1].noteID != match.noteID {
                        Text(match.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, i == 0 ? 0 : 8)
                            .padding(.horizontal, 8)
                            .accessibilityAddTraits(.isHeader)
                    }
                    NoteMatchRow(match: match) { open(match) }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var matchSummary: String {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return "Type to search every note" }
        let matches = notes.search(query)
        guard !matches.isEmpty else { return "No matches" }
        let count = matches.count, inNotes = Set(matches.map(\.noteID)).count
        let more = count >= 100 ? "+" : ""
        return "\(count)\(more) match\(count == 1 ? "" : "es") in \(inNotes) note\(inNotes == 1 ? "" : "s")"
    }

    /// Opens the note with the match selected in the editor (a note in preview switches to editing).
    private func open(_ match: NoteMatch) {
        model.isSearchingNotes = false
        notes.select(match.noteID)
        notes.setPreview(match.noteID, false)
        focusRequest += 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard let window = NSApp.windows.first(where: \.isKeyWindow),
                  let textView = window.firstResponder as? NSTextView, !textView.isFieldEditor,
                  NSMaxRange(match.rangeInNote) <= (textView.string as NSString).length else { return }
            textView.setSelectedRange(match.rangeInNote)
            textView.scrollRangeToVisible(match.rangeInNote)
        }
    }

    // MARK: Actions

    private func focusEditor() {
        guard renamingID == nil, !model.isSearchingNotes, notes.activeNote?.showsPreview != true else { return }
        focusRequest += 1
    }

    // MARK: Dragging tabs

    /// Like a browser tab: dragging along the strip reorders (the other tabs slide aside). In the Notes
    /// window, once the pointer leaves the window the note becomes a floating window under the pointer
    /// and follows it, and dragging back in makes it a tab again. Letting go outside leaves it floating there.
    /// In the panel, tabs only reorder.
    private func tabDragGesture(_ note: Note, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(noteTabSpace))
            .onChanged { value in dragChanged(note, index: index, translation: value.translation.width) }
            .onEnded { _ in dragEnded() }
    }

    private func dragChanged(_ note: Note, index: Int, translation: CGFloat) {
        if tabDrag == nil {
            if renamingID != nil { commitRename() }
            notes.select(note.id)
            tabDrag = TabDrag(id: note.id, from: index, target: index)
            if !isDetached { PackServices.shared.holdPanel() }   // the panel stays open during the drag
        }
        guard var drag = tabDrag, drag.id == note.id else { return }
        let point = NSEvent.mouseLocation
        let windowFrame = NSApp.windows.first { $0 is NotesWindow }?.frame ?? .zero
        if isDetached, !windowFrame.contains(point) {
            if !drag.outside {
                drag.outside = true
                drag.target = drag.from
                notes.setPinned(note.id, true, frame: NoteWindows.frame(droppedAt: point, size: note.floatFrame?.size ?? NoteWindows.defaultSize))
                NoteWindows.current?.syncNow()
            }
            NoteWindows.current?.move(note.id, pointerAt: point)
        } else {
            if drag.outside {
                // Back in the window: it's a tab again.
                drag.outside = false
                notes.setPinned(note.id, false)
                NoteWindows.current?.syncNow()
            }
            drag.translation = translation
            drag.target = targetIndex(for: drag)
        }
        tabDrag = drag
    }

    private func dragEnded() {
        guard let drag = tabDrag else { return }
        if !isDetached { PackServices.shared.releasePanel() }
        if drag.outside {
            NoteWindows.current?.saveFrame(drag.id)
            tabDrag = nil
            return
        }
        withAnimation(.easeOut(duration: 0.15)) {
            if drag.target != drag.from, notes.notes.indices.contains(drag.target) {
                notes.move(drag.id, to: notes.notes[drag.target].id)
            }
            tabDrag = nil
        }
    }

    /// Where the dragged tab would land: after every other tab whose middle it has passed.
    private func targetIndex(for drag: TabDrag) -> Int {
        guard let frame = tabFrames[drag.id] else { return drag.from }
        let center = frame.midX + drag.translation
        return notes.notes.filter { $0.id != drag.id && (tabFrames[$0.id]?.midX ?? .infinity) < center }.count
    }

    /// The dragged tab follows the pointer; the tabs it passes move over by its width.
    private func tabOffset(_ id: UUID, index: Int) -> CGFloat {
        guard let drag = tabDrag else { return 0 }
        if id == drag.id { return drag.outside ? 0 : drag.translation }
        let width = (tabFrames[drag.id]?.width ?? 0) + noteTabSpacing
        if index > drag.from && index <= drag.target { return -width }
        if index < drag.from && index >= drag.target { return width }
        return 0
    }

    /// Typing in the panel keeps Smart auto-hide from closing it (the Notes window isn't the panel).
    private func updateTyping() {
        guard !isDetached else { return }
        model.isTypingNote = editorFocused || searchFocused || renamingID != nil
    }

    private func togglePreview() {
        guard let note = notes.activeNote else { return }
        notes.setPreview(note.id, !note.showsPreview)
    }

    /// One note (`id`) or all of them (nil), through a save dialog.
    private func export(_ id: UUID?) {
        let done: (Bool) -> Void = { ok in
            guard ok else { return }   // cancelled (or it couldn't be written)
            exported = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                exported = false
            }
        }
        if let id { notes.export(id, done: done) } else { notes.exportAll(done: done) }
    }

    private func addNote() {
        notes.addNote()
        focusEditor()
    }

    private func startRename(_ note: Note) {
        if renamingID != nil { commitRename() }
        notes.select(note.id)
        renameText = note.title
        renamingID = note.id // RenameField takes the cursor itself once it appears
    }

    private func commitRename() {
        guard let id = renamingID else { return }
        renamingID = nil
        notes.rename(id, to: renameText)
    }

    private func cancelRename() {
        renamingID = nil
        focusEditor()
    }
}

/// Puts the active note tab on accent-tinted glass (a tinted fill in Frosted mode).
private struct ActiveTabGlass: ViewModifier {
    let isActive: Bool
    let accent: Color

    func body(content: Content) -> some View {
        if isActive {
            content.glassSurface(in: Capsule(), tint: accent.opacity(0.3), fallback: accent.opacity(0.18))
        } else {
            content
        }
    }
}

/// A search result: the line, with the match in the accent color. Long lines are cut around the match.
private struct NoteMatchRow: View {
    let match: NoteMatch
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let line = match.line
        let before = line[line.startIndex..<match.rangeInLine.lowerBound]
        let found = line[match.rangeInLine]
        let after = line[match.rangeInLine.upperBound...]
        let lead = before.count > 36 ? "…" + before.suffix(34).drop { $0 != " " }.trimmingCharacters(in: .whitespaces) + " "
                                     : before.drop { $0 == " " || $0 == "\t" }
        Button(action: action) {
            (Text(String(lead)) + Text(String(found)).fontWeight(.semibold).foregroundStyle(.tint) + Text(String(after)))
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? Tokens.fillHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(match.title): \(line)")
        .accessibilityHint("Opens the note")
    }
}
