import AppKit
import SwiftUI

/// Five: guess the 5-letter word in 6 tries (Wordle-style gameplay, original name).
/// One shared daily word (same for everyone, by date) plus unlimited practice words.
@Observable
final class FiveGame: GameSession {
    enum Mode { case daily, practice }
    enum Mark: Int { case absent = 1, present, correct }

    struct Stats: Codable {
        var played = 0
        var wins = 0
        var streak = 0
        var maxStreak = 0
        var lastPlayed: String?   // day key, e.g. "2026-09-26"
        var lastWin: String?
        var distribution = Array(repeating: 0, count: 6)
    }

    static let maxGuesses = 6
    static let length = 5
    private static let praise = ["Genius!", "Magnificent!", "Impressive!", "Splendid!", "Great!", "Phew!"]

    private(set) var mode: Mode = .daily
    private(set) var answer = ""
    private(set) var guesses: [String] = []
    private(set) var current = ""
    private(set) var isDone = false
    private(set) var showsResult = false
    /// True if the player used "Reveal word" instead of solving it.
    private(set) var gaveUp = false
    /// Positions (0–4) revealed by hints.
    private(set) var hintedPositions: Set<Int> = []
    /// Asks for confirmation before revealing the daily word (it counts as a loss).
    var confirmingReveal = false
    /// How many tiles of the newest guess have flipped so far (0–5).
    private(set) var revealedInLastRow = FiveGame.length
    private(set) var shakeCount = 0
    private(set) var message: String?
    private(set) var stats: Stats

    @ObservationIgnored private let answers: [String]
    @ObservationIgnored private let valid: Set<String>
    @ObservationIgnored private let today: String
    @ObservationIgnored private var messageTask: Task<Void, Never>?


    init(answers: [String] = WordBank.shared.fiveAnswers,
         valid: Set<String> = WordBank.shared.fiveValid,
         date: Date = .now) {
        self.answers = answers
        self.valid = valid
        today = Self.dayKey(date)
        stats = Self.loadStats()
        startDaily()
    }

    // MARK: GameSession

    var scoreText: String { mode == .daily ? "Daily · Streak \(Self.currentStreak(stats))" : "Practice" }
    var hint: String {
        isDone ? "Enter: \(showsResult ? "next practice word" : "show results") · Esc back"
               : "Type letters · Enter guess · ⌫ delete · ? hint · Esc back"
    }
    var showsPauseButton: Bool { false }
    var isRunning: Bool { false }
    func pause() {}
    func togglePause() {}

    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case Key.enter, Key.keypadEnter:
            if isDone { showsResult ? startPractice() : (showsResult = true) } else { submit() }
            return true
        case 51, 117: // delete, forward delete
            deleteLetter()
            return true
        default:
            if event.charactersIgnoringModifiers == "?" || event.charactersIgnoringModifiers == "/" {
                useHint()
                return true
            }
            guard let letter = Key.letter(event), letter.count == 1, let c = letter.first, c.isLetter, c.isASCII else { return false }
            type(letter.uppercased())
            return true
        }
    }

    func makeView() -> AnyView { AnyView(FiveView(game: self)) }
    func makeHeaderAccessory() -> AnyView? { AnyView(FiveModeMenu(game: self)) }

    // MARK: Modes

    func startDaily() {
        mode = .daily
        answer = Self.dailyAnswer(for: today, from: answers)
        let saved = UserDefaults.standard.dictionary(forKey: "five.daily")
        let isToday = saved?["date"] as? String == today
        guesses = isToday ? (saved?["guesses"] as? [String] ?? []) : []
        resetRound()
        hintedPositions = isToday ? Set(saved?["hints"] as? [Int] ?? []) : []
        gaveUp = isToday && saved?["gaveUp"] as? Bool == true
        isDone = gaveUp || guesses.contains(answer) || guesses.count >= Self.maxGuesses
        showsResult = isDone
    }

    func startPractice() {
        mode = .practice
        var word = answer
        while word == answer, answers.count > 1 { word = answers.randomElement() ?? answer }
        answer = word
        guesses = []
        resetRound()
    }

    func closeResult() { showsResult = false }

    private func resetRound() {
        current = ""
        isDone = false
        showsResult = false
        gaveUp = false
        hintedPositions = []
        confirmingReveal = false
        revealedInLastRow = Self.length
        message = nil
    }

    // MARK: Input

    func type(_ letter: String) {
        guard !isDone, revealedInLastRow == Self.length, current.count < Self.length else { return }
        current += letter
    }

    func deleteLetter() {
        guard !isDone, revealedInLastRow == Self.length, !current.isEmpty else { return }
        current.removeLast()
    }

    func submit() {
        guard !isDone, revealedInLastRow == Self.length else { return }
        guard current.count == Self.length else { reject("Not enough letters"); return }
        guard valid.contains(current) else { reject("Not in word list"); return }

        let guess = current
        guesses.append(guess)
        current = ""
        saveDaily()
        Task { await reveal(guess) }
    }

    // MARK: Hints & giving up

    /// Letters whose position is known: greens from earlier guesses, plus hints.
    /// Shown as faint "ghost" letters in the row being typed.
    var knownPositions: [Int: Character] {
        let answerLetters = Array(answer)
        var known: [Int: Character] = [:]
        let finished = revealedInLastRow == Self.length ? guesses : Array(guesses.dropLast())
        for guess in finished {
            for (i, letter) in guess.enumerated() where letter == answerLetters[i] { known[i] = letter }
        }
        for i in hintedPositions where i < answerLetters.count { known[i] = answerLetters[i] }
        return known
    }

    /// Hints can reveal letters until only one is left unknown.
    var canUseHint: Bool { !isDone && knownPositions.count < Self.length - 1 }

    /// Reveals one letter in its correct position.
    func useHint() {
        guard !isDone else { return }
        let unknown = (0..<Self.length).filter { knownPositions[$0] == nil }
        guard unknown.count > 1, let position = unknown.randomElement() else {
            show("No more hints for this word")
            return
        }
        hintedPositions.insert(position)
        saveDaily()
    }

    /// "Reveal word": asks first for the daily word, since it counts as a loss.
    func requestReveal() {
        guard !isDone else { return }
        if mode == .daily { confirmingReveal = true } else { revealAnswer() }
    }

    func revealAnswer() {
        guard !isDone else { return }
        confirmingReveal = false
        current = ""
        gaveUp = true
        isDone = true
        record(won: false)
        saveDaily()
        showsResult = true
    }

    private func saveDaily() {
        guard mode == .daily else { return }
        UserDefaults.standard.set(
            ["date": today, "guesses": guesses, "hints": Array(hintedPositions), "gaveUp": gaveUp] as [String: Any],
            forKey: "five.daily"
        )
    }

    private func reveal(_ guess: String) async {
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        revealedInLastRow = 0
        for i in 1...Self.length {
            if animate { try? await Task.sleep(for: .milliseconds(i == 1 ? 0 : 90)) }
            revealedInLastRow = i
        }
        if animate { try? await Task.sleep(for: .milliseconds(250)) }

        let won = guess == answer
        guard won || guesses.count == Self.maxGuesses else { return }
        isDone = true
        record(won: won)
        show(won ? Self.praise[guesses.count - 1] : answer)
        try? await Task.sleep(for: .milliseconds(900))
        if isDone, guesses.last == guess { showsResult = true }
    }

    private func reject(_ text: String) {
        shakeCount += 1
        show(text)
    }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    // MARK: Marks

    /// Colors for one guess. Handles repeated letters the standard way.
    static func marks(for guess: String, answer: String) -> [Mark] {
        let g = Array(guess), a = Array(answer)
        var result = Array(repeating: Mark.absent, count: g.count)
        var remaining: [Character: Int] = [:]
        for i in g.indices {
            if g[i] == a[i] { result[i] = .correct } else { remaining[a[i], default: 0] += 1 }
        }
        for i in g.indices where result[i] != .correct {
            if let n = remaining[g[i]], n > 0 {
                result[i] = .present
                remaining[g[i]] = n - 1
            }
        }
        return result
    }

    /// The best-known state of each letter, for coloring the on-screen keyboard.
    var keyboardMarks: [Character: Mark] {
        var best: [Character: Mark] = [:]
        let finished = revealedInLastRow == Self.length ? guesses : Array(guesses.dropLast())
        for guess in finished {
            for (letter, mark) in zip(guess, Self.marks(for: guess, answer: answer)) where mark.rawValue > (best[letter]?.rawValue ?? 0) {
                best[letter] = mark
            }
        }
        for (_, letter) in knownPositions { best[letter] = .correct } // hinted letters light up green
        return best
    }

    // MARK: Daily & stats

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func dailyAnswer(for key: String, from answers: [String]) -> String {
        guard !answers.isEmpty else { return "ERROR" }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        var comps = DateComponents()
        (comps.year, comps.month, comps.day) = (parts[0], parts[1], parts[2])
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let day = calendar.dateComponents([.day], from: start, to: calendar.date(from: comps)!).day ?? 0
        let n = answers.count
        return answers[((day % n) + n) % n] // the list is pre-shuffled, so consecutive days differ
    }

    static func currentStreak(_ stats: Stats) -> Int {
        let yesterday = dayKey(Calendar.current.date(byAdding: .day, value: -1, to: .now)!)
        return stats.lastWin == dayKey(.now) || stats.lastWin == yesterday ? stats.streak : 0
    }

    private func record(won: Bool) {
        guard mode == .daily, stats.lastPlayed != today else { return }
        let yesterday = Self.dayKey(Calendar.current.date(byAdding: .day, value: -1, to: .now)!)
        stats.played += 1
        if won {
            stats.wins += 1
            stats.streak = stats.lastWin == yesterday ? stats.streak + 1 : 1
            stats.maxStreak = max(stats.maxStreak, stats.streak)
            stats.lastWin = today
            stats.distribution[guesses.count - 1] += 1
        } else {
            stats.streak = 0
        }
        stats.lastPlayed = today
        if let data = try? JSONEncoder().encode(stats) { UserDefaults.standard.set(data, forKey: "five.stats") }
    }

    static func loadStats() -> Stats {
        guard let data = UserDefaults.standard.data(forKey: "five.stats"),
              let stats = try? JSONDecoder().decode(Stats.self, from: data) else { return Stats() }
        return stats
    }

    /// The line under the Five tile on the games grid.
    static func tileStat() -> String {
        let stats = loadStats()
        let streak = currentStreak(stats)
        if streak > 0 { return "\(streak)-day streak" }
        return stats.lastPlayed == dayKey(.now) ? "Done today" : "Daily word"
    }
}
