import AppKit
import SwiftUI

/// Spokes: connect letters on a wheel to fill a small crossword (Wordscapes-style gameplay, original name).
/// Words that aren't in the crossword but are real count as bonus words.
@Observable
final class SpokesGame: GameSession {
    private(set) var level: Int
    private(set) var puzzle: SpokesPuzzle
    /// The wheel's letters in their current (shuffleable) order.
    private(set) var letters: [Character]
    /// Indices into `letters`, in the order they were picked.
    private(set) var selection: [Int] = []
    private(set) var found: Set<String> = []
    private(set) var bonus: Set<String> = []
    private(set) var revealed: Set<SpokesPuzzle.Cell> = []
    private(set) var hints: Int
    private(set) var message: String?
    private(set) var shakeCount = 0
    /// The word just found, briefly highlighted in the grid.
    private(set) var justFound: String?

    @ObservationIgnored private let words: [String]
    @ObservationIgnored private let valid: Set<String>
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    static let startingHints = 3

    init(words: [String] = WordBank.shared.wheelWords, valid: Set<String> = WordBank.shared.wheelValid) {
        self.words = words
        self.valid = valid
        let defaults = UserDefaults.standard
        let savedLevel = max(1, defaults.integer(forKey: "wheel.level"))
        let firstPuzzle = SpokesGenerator.puzzle(level: savedLevel, words: words)
        level = savedLevel
        hints = defaults.object(forKey: "wheel.hints") == nil ? Self.startingHints : defaults.integer(forKey: "wheel.hints")
        puzzle = firstPuzzle
        letters = firstPuzzle.letters
        restoreProgress()
    }

    // MARK: GameSession

    var scoreText: String { "Level \(level)" }
    var hint: String {
        isComplete ? "Enter: next level · Esc back" : "Type or drag letters · Enter submit · Space shuffle · ? hint"
    }
    var showsPauseButton: Bool { false }
    var isRunning: Bool { false }
    func pause() {}
    func togglePause() {}

    func handleKey(_ event: NSEvent) -> Bool {
        if isComplete {
            if event.keyCode == Key.enter || event.keyCode == Key.keypadEnter { nextLevel(); return true }
            return false
        }
        switch event.keyCode {
        case Key.enter, Key.keypadEnter: submit(); return true
        case Key.space: shuffle(); return true
        case 51, 117: if !selection.isEmpty { selection.removeLast() }; return true
        default: break
        }
        guard let typed = event.charactersIgnoringModifiers else { return false }
        if typed == "?" || typed == "/" { useHint(); return true }
        guard typed.count == 1, let c = typed.uppercased().first, c.isLetter, c.isASCII else { return false }
        // Use the next unused wheel letter that matches.
        if let index = letters.indices.first(where: { letters[$0] == c && !selection.contains($0) }) {
            selection.append(index)
        } else {
            shakeCount += 1
        }
        return true
    }

    func makeView() -> AnyView { AnyView(SpokesView(game: self)) }

    // MARK: State

    var isComplete: Bool { found.count == puzzle.entries.count && !puzzle.entries.isEmpty }
    var currentWord: String { String(selection.map { letters[$0] }) }

    /// Letters currently visible in the crossword (found words + hints).
    var visibleCells: Set<SpokesPuzzle.Cell> {
        var cells = revealed
        for entry in puzzle.entries where found.contains(entry.word) { cells.formUnion(entry.cells) }
        return cells
    }

    // MARK: Selecting letters

    /// Dragging over a letter: adds it, or steps back if you return to the previous letter.
    func dragOver(_ index: Int) {
        if selection.last == index { return }
        if selection.count >= 2, selection[selection.count - 2] == index {
            selection.removeLast()
        } else if !selection.contains(index) {
            selection.append(index)
        }
    }

    /// Clicking a letter: adds it, or removes it if it was the last one picked.
    func tap(_ index: Int) {
        if selection.last == index { selection.removeLast() } else if !selection.contains(index) { selection.append(index) }
    }

    func clearSelection() { selection = [] }

    func shuffle() {
        guard letters.count > 1 else { return }
        let old = letters
        while letters == old { letters.shuffle() }
        selection = []
    }

    // MARK: Submitting

    func submit() {
        let word = currentWord
        selection = []
        guard !word.isEmpty, !isComplete else { return }
        guard word.count >= 3 else { reject("Too short"); return }

        if puzzle.entries.contains(where: { $0.word == word }) {
            guard !found.contains(word) else { show("Already found"); return }
            found.insert(word)
            highlight(word)
            if isComplete {
                hints += 1
                show("Level complete!")
            }
        } else if valid.contains(word) {
            guard !bonus.contains(word) else { show("Already found"); return }
            bonus.insert(word)
            show("Bonus word!")
        } else {
            reject("Not a word")
        }
        save()
    }

    func useHint() {
        guard hints > 0, !isComplete else {
            if hints == 0 { show("No hints left. Finish a level to earn one") }
            return
        }
        let hidden = puzzle.entries
            .filter { !found.contains($0.word) }
            .flatMap(\.cells)
            .filter { !visibleCells.contains($0) }
        guard let cell = hidden.randomElement() else { return }
        revealed.insert(cell)
        hints -= 1
        // A word whose letters are all revealed counts as found.
        for entry in puzzle.entries where !found.contains(entry.word) && entry.cells.allSatisfy(visibleCells.contains) {
            found.insert(entry.word)
        }
        if isComplete { hints += 1 }
        save()
    }

    func nextLevel() {
        level += 1
        puzzle = SpokesGenerator.puzzle(level: level, words: words)
        letters = puzzle.letters
        selection = []
        found = []
        bonus = []
        revealed = []
        justFound = nil
        message = nil
        save()
    }

    // MARK: Feedback

    private func reject(_ text: String) {
        shakeCount += 1
        show(text)
    }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    private func highlight(_ word: String) {
        justFound = word
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            if self?.justFound == word { self?.justFound = nil }
        }
    }

    // MARK: Saving

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(level, forKey: "wheel.level")
        defaults.set(hints, forKey: "wheel.hints")
        defaults.set([
            "level": level,
            "found": Array(found),
            "bonus": Array(bonus),
            "revealed": revealed.map { "\($0.x),\($0.y)" },
        ] as [String: Any], forKey: "wheel.progress")
    }

    private func restoreProgress() {
        guard let saved = UserDefaults.standard.dictionary(forKey: "wheel.progress"),
              saved["level"] as? Int == level else { return }
        let words = Set(puzzle.entries.map(\.word))
        found = Set(saved["found"] as? [String] ?? []).intersection(words)
        bonus = Set(saved["bonus"] as? [String] ?? [])
        revealed = Set((saved["revealed"] as? [String] ?? []).compactMap { text in
            let parts = text.split(separator: ",").compactMap { Int($0) }
            return parts.count == 2 ? SpokesPuzzle.Cell(x: parts[0], y: parts[1]) : nil
        })
    }

    static var savedLevel: Int { max(1, UserDefaults.standard.integer(forKey: "wheel.level")) }
}
