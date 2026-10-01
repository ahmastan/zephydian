import AppKit

/// Notes shortcuts, the same in the panel's Notes tab and the Notes window:
/// ⌘T new note, ⌘W close note (not a pinned one), ⌃Tab / ⌃⇧Tab switch notes, ⌘F search, ⌘E preview.
/// (⌘+ / ⌘− / ⌘0 belong to the editor: they resize the current line.)
enum NotesKeys {
    static func handle(_ event: NSEvent, notes: NotesStore, model: AppModel) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, flags.contains(.control) { // Tab
            notes.selectNext(offset: flags.contains(.shift) ? -1 : 1)
            return true
        }
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "t":
            notes.addNote()
        case "w" where notes.notes.count > 1 && notes.activeNote?.isPinned == false:
            if let id = notes.activeID { notes.requestDelete(id) }
        case "f":
            model.isSearchingNotes = true
        case "e" where !model.isSearchingNotes:
            if let note = notes.activeNote { notes.setPreview(note.id, !note.showsPreview) }
        default:
            return false
        }
        return true
    }
}
