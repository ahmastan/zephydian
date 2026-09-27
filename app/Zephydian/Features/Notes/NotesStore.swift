import AppKit
import Observation

struct Note: Identifiable, Equatable {
    let id: UUID
    var title: String
    var body: String
}

/// Quick Notes storage. Each tab is a plain Markdown file you can open in any editor:
///
///     ~/Library/Containers/com.ahmastan.zephydian/Data/Library/Application Support/Zephydian/Notes/
///         Scratch.md
///         Todo.md
///         notes.json        ← tab order + which tab is active
///
/// Typing autosaves 0.5 s after you stop, and everything is flushed when the panel hides
/// or the app quits. Deleted notes go to the Trash, never straight to oblivion.
@Observable
final class NotesStore {
    enum SaveState { case saved, editing, failed }

    static let maxNotes = 5

    private(set) var notes: [Note] = []
    private(set) var activeID: UUID?
    private(set) var saveState: SaveState = .saved
    /// A non-empty note waiting for the user to confirm deletion.
    var pendingDeletion: Note?

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var dirty: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// What we last read from / wrote to each file, to spot edits made in other apps.
    @ObservationIgnored private var onDisk: [UUID: String] = [:]

    var activeNote: Note? { notes.first { $0.id == activeID } }
    var canAddNote: Bool { notes.count < Self.maxNotes }

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Zephydian/Notes", directoryHint: .isDirectory)
    }

    // MARK: Loading

    private struct Index: Codable {
        struct Entry: Codable { let id: UUID; let title: String }
        var notes: [Entry]
        var active: UUID?
    }

    func load() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var loaded: [Note] = []
        var active: UUID?
        if let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data) {
            loaded = index.notes.map { Note(id: $0.id, title: $0.title, body: read($0.title) ?? "") }
            active = index.active
        }

        // Adopt .md files that were added to the folder by hand.
        let known = Set(loaded.map { $0.title.lowercased() })
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "md" && !known.contains(file.deletingPathExtension().lastPathComponent.lowercased()) {
            guard loaded.count < Self.maxNotes else { break }
            let title = file.deletingPathExtension().lastPathComponent
            loaded.append(Note(id: UUID(), title: title, body: read(title) ?? ""))
        }

        if loaded.isEmpty { loaded = [Note(id: UUID(), title: "Scratch", body: "")] }
        notes = loaded
        activeID = loaded.contains { $0.id == active } ? active : loaded.first?.id
        onDisk = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.body) })
        writeIndex()
    }

    /// Picks up changes made to the files in another editor (called when the panel opens).
    func reloadChangedFiles() {
        for i in notes.indices where !dirty.contains(notes[i].id) {
            guard let current = read(notes[i].title), current != onDisk[notes[i].id] else { continue }
            notes[i].body = current
            onDisk[notes[i].id] = current
        }
    }

    // MARK: Editing

    func select(_ id: UUID) {
        guard id != activeID, notes.contains(where: { $0.id == id }) else { return }
        flush()
        activeID = id
        writeIndex()
    }

    func selectNext(offset: Int) {
        guard let i = notes.firstIndex(where: { $0.id == activeID }), notes.count > 1 else { return }
        select(notes[(i + offset + notes.count) % notes.count].id)
    }

    /// Moves a tab to where another tab is (used by drag-to-reorder).
    func move(_ id: UUID, to targetID: UUID) {
        guard let from = notes.firstIndex(where: { $0.id == id }),
              let to = notes.firstIndex(where: { $0.id == targetID }), from != to else { return }
        notes.insert(notes.remove(at: from), at: to)
        writeIndex()
    }

    /// Moves a tab one place left (-1) or right (+1).
    func move(_ id: UUID, by offset: Int) {
        guard let from = notes.firstIndex(where: { $0.id == id }), notes.indices.contains(from + offset) else { return }
        move(id, to: notes[from + offset].id)
    }

    func updateActiveBody(_ text: String) {
        guard let i = notes.firstIndex(where: { $0.id == activeID }), notes[i].body != text else { return }
        notes[i].body = text
        dirty.insert(notes[i].id)
        saveState = .editing
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func addNote() {
        guard canAddNote else { return }
        flush()
        let note = Note(id: UUID(), title: nextDefaultTitle(), body: "")
        notes.append(note)
        activeID = note.id
        write(note)
        writeIndex()
    }

    /// Renames a note (and its file). Returns false if the new name is unusable.
    @discardableResult
    func rename(_ id: UUID, to rawTitle: String) -> Bool {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return false }
        let cleaned = Self.sanitize(rawTitle)
        guard !cleaned.isEmpty else { return false }
        guard cleaned != notes[i].title else { return true }
        flush()
        let title = uniqueTitle(cleaned, ignoring: id)
        let from = url(for: notes[i].title), to = url(for: title)
        do {
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.moveItem(at: from, to: to)
            }
        } catch {
            saveState = .failed
            return false
        }
        notes[i].title = title
        writeIndex()
        return true
    }

    /// Deletes right away if the note is empty; otherwise asks for confirmation first.
    func requestDelete(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            delete(id)
        } else {
            pendingDeletion = note
        }
    }

    /// Moves the note's file to the Trash and removes the tab.
    /// Deleting the only note replaces it with a fresh, empty one.
    func delete(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let file = url(for: notes[i].title)
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        dirty.remove(id)
        onDisk[id] = nil
        notes.remove(at: i)
        if notes.isEmpty {
            let fresh = Note(id: UUID(), title: nextDefaultTitle(), body: "")
            notes = [fresh]
            write(fresh)
        }
        if activeID == id || !notes.contains(where: { $0.id == activeID }) {
            activeID = notes[max(0, min(i, notes.count) - 1)].id
        }
        pendingDeletion = nil
        writeIndex()
    }

    func revealInFinder() {
        flush()
        guard let note = activeNote else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url(for: note.title)])
    }

    // MARK: Saving

    /// Writes every unsaved note to disk now.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard !dirty.isEmpty else { return }
        var failed = false
        for note in notes where dirty.contains(note.id) {
            if write(note) { dirty.remove(note.id) } else { failed = true }
        }
        saveState = failed ? .failed : .saved
    }

    @discardableResult
    private func write(_ note: Note) -> Bool {
        do {
            try note.body.write(to: url(for: note.title), atomically: true, encoding: .utf8)
            onDisk[note.id] = note.body
            return true
        } catch {
            return false
        }
    }

    private func writeIndex() {
        let index = Index(notes: notes.map { .init(id: $0.id, title: $0.title) }, active: activeID)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: Files & names

    private var indexURL: URL { folder.appending(path: "notes.json") }
    private func url(for title: String) -> URL { folder.appending(path: "\(title).md") }
    private func read(_ title: String) -> String? { try? String(contentsOf: url(for: title), encoding: .utf8) }

    /// Makes a title safe to use as a file name.
    static func sanitize(_ title: String) -> String {
        let replaced = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(replaced.drop { $0 == "." })   // no hidden files
        return String(trimmed.prefix(40))
    }

    /// "Note 1", "Note 2"…: the lowest number that isn't already used.
    private func nextDefaultTitle() -> String {
        var n = 1
        while !isTitleFree("Note \(n)", ignoring: nil) { n += 1 }
        return "Note \(n)"
    }

    private func isTitleFree(_ title: String, ignoring id: UUID?) -> Bool {
        if let id, notes.first(where: { $0.id == id })?.title.lowercased() == title.lowercased() {
            return true // renaming a note to a different capitalization of itself
        }
        let taken = notes.contains { $0.id != id && $0.title.lowercased() == title.lowercased() }
        return !taken && !FileManager.default.fileExists(atPath: url(for: title).path)
    }

    /// Appends " 2", " 3"… if another note (or file) already uses the title.
    private func uniqueTitle(_ base: String, ignoring id: UUID? = nil) -> String {
        if isTitleFree(base, ignoring: id) { return base }
        var n = 2
        while !isTitleFree("\(base) \(n)", ignoring: id) { n += 1 }
        return "\(base) \(n)"
    }
}
