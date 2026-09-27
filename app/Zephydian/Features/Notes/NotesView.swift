import SwiftUI

/// The Notes tab: pill tabs, a plain-text editor and a status footer.
struct NotesView: View {
    @Environment(NotesStore.self) private var notes
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model

    @FocusState private var editorFocused: Bool
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var hoveredID: UUID?
    @State private var draggingID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            tabBar.padding(.bottom, 8)
            Divider()
            editor
            Divider()
            footer.padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .onAppear { editorFocused = true }
        .onChange(of: model.panelOpenCount) { if renamingID == nil { editorFocused = true } }
        .onChange(of: editorFocused) { model.isTypingNote = editorFocused || renamingID != nil }
        .onChange(of: renamingID) {
            model.isRenamingNote = renamingID != nil
            model.isTypingNote = editorFocused || renamingID != nil
        }
        .onDisappear {
            model.isTypingNote = false
            model.isRenamingNote = false
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
                ForEach(notes.notes) { pill(for: $0) }
            }
            Button { addNote() } label: {
                Image(systemName: "plus").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!notes.canAddNote)
            .help(notes.canAddNote ? "New note (⌘T)" : "Up to \(NotesStore.maxNotes) notes")
            .accessibilityLabel("New note")

            Menu {
                Toggle("Monospace Font", isOn: Binding(get: { settings.notesMonospaced }, set: { settings.notesMonospaced = $0 }))
                Button("Reveal in Finder") { notes.revealInFinder() }
                Divider()
                if let note = notes.activeNote {
                    Button("Rename “\(note.title)”…") { startRename(note) }
                    Button("Delete “\(note.title)”…", role: .destructive) { notes.requestDelete(note.id) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 26)
            .accessibilityLabel("More options")
        }
    }

    @ViewBuilder
    private func pill(for note: Note) -> some View {
        let isActive = note.id == notes.activeID
        let showsClose = (isActive || hoveredID == note.id) && renamingID != note.id

        HStack(spacing: 4) {
            if renamingID == note.id {
                RenameField(text: $renameText, onCommit: commitRename, onCancel: cancelRename)
                    .frame(width: 96, height: 16)
            } else {
                Text(note.title).lineLimit(1)
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
        .padding(.trailing, showsClose ? 6 : 10)
        .frame(height: 24)
        .background(Capsule().fill(isActive ? settings.accent.color.opacity(0.18) : Tokens.fill))
        .contentShape(Capsule())
        .onTapGesture {
            notes.select(note.id)
            editorFocused = true
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(note) })
        .onHover { hoveredID = $0 ? note.id : (hoveredID == note.id ? nil : hoveredID) }
        .onDrag {
            draggingID = note.id
            return .noteTab(note.id)
        }
        .onDrop(of: [.zephydianNoteTab], delegate: NoteTabDropDelegate(targetID: note.id, draggingID: $draggingID, notes: notes))
        .contextMenu {
            Button("Rename…") { startRename(note) }
            Button("Move Left") { notes.move(note.id, by: -1) }
                .disabled(note.id == notes.notes.first?.id)
            Button("Move Right") { notes.move(note.id, by: 1) }
                .disabled(note.id == notes.notes.last?.id)
            Button("Reveal in Finder") {
                notes.select(note.id)
                notes.revealInFinder()
            }
            Divider()
            Button("Delete…", role: .destructive) { notes.requestDelete(note.id) }
        }
        .help("Double-click to rename · drag to reorder")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(note.title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Editor & footer

    private var editor: some View {
        TextEditor(text: Binding(
            get: { notes.activeNote?.body ?? "" },
            set: { notes.updateActiveBody($0) }
        ))
        .font(settings.notesMonospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
        .lineSpacing(2)
        .scrollContentBackground(.hidden)
        .focused($editorFocused)
        .padding(.vertical, 6)
        .accessibilityLabel("Note text")
    }

    private var footer: some View {
        HStack {
            Text(wordCount)
            Spacer()
            switch notes.saveState {
            case .saved: Text("Saved \(Image(systemName: "checkmark"))")
            case .editing: Text("Editing…")
            case .failed: Text("Couldn’t save").foregroundStyle(.red)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }

    private var wordCount: String {
        let count = notes.activeNote?.body.split(whereSeparator: \.isWhitespace).count ?? 0
        return "\(count) word\(count == 1 ? "" : "s")"
    }

    // MARK: Actions

    private func addNote() {
        notes.addNote()
        editorFocused = true
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
        editorFocused = true
    }
}
