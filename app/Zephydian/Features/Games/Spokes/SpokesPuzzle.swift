import Foundation

/// One Spokes level: a wheel of letters and a small crossword of words made from them.
struct SpokesPuzzle {
    struct Cell: Hashable, Codable { var x: Int, y: Int }

    struct Entry {
        let word: String
        let start: Cell
        let horizontal: Bool

        var cells: [Cell] {
            (0..<word.count).map { horizontal ? Cell(x: start.x + $0, y: start.y) : Cell(x: start.x, y: start.y + $0) }
        }
    }

    let letters: [Character]
    let entries: [Entry]
    let width: Int
    let height: Int

    /// The letter at each crossword cell.
    var solution: [Cell: Character] {
        var grid: [Cell: Character] = [:]
        for entry in entries {
            for (cell, letter) in zip(entry.cells, entry.word) { grid[cell] = letter }
        }
        return grid
    }
}

/// Builds puzzles deterministically from the level number, so level N is always the same puzzle.
enum SpokesGenerator {
    static let maxWidth = 11
    static let maxHeight = 9

    static func letterCount(for level: Int) -> Int {
        level <= 5 ? 4 : level <= 25 ? 5 : 6
    }

    static func puzzle(level: Int, words: [String]) -> SpokesPuzzle {
        var rng = SeededGenerator(seed: UInt64(max(level, 1)) &* 7919)
        let n = letterCount(for: level)
        let target = n == 4 ? 4 : n + 1          // how many words to place
        let minimum = n == 4 ? 3 : n - 1         // fewest words we'll accept

        let pool = words.filter { (3...n).contains($0.count) }.map { ($0, counts($0)) }
        let bases = pool.filter { $0.0.count == n }.shuffled(using: &rng)
        var best: [SpokesPuzzle.Entry] = []
        var bestLetters: [Character] = []

        for (base, baseCounts) in bases.prefix(120) {
            let others = pool
                .filter { $0.0 != base && fits($0.1, in: baseCounts) }
                .map(\.0)
                .shuffled(using: &rng)
                .sorted { $0.count > $1.count }      // prefer longer words (stable after the shuffle)
            guard others.count >= minimum - 1 else { continue }

            let entries = arrange([base] + others, target: target, rng: &rng)
            if entries.count > best.count {
                best = entries
                bestLetters = Array(base)
            }
            if entries.count >= minimum { break }
        }
        return normalized(best, letters: bestLetters.shuffled(using: &rng))
    }

    // MARK: Crossword layout

    private static func arrange(_ words: [String], target: Int, rng: inout SeededGenerator) -> [SpokesPuzzle.Entry] {
        var placed = [SpokesPuzzle.Entry(word: words[0], start: .init(x: 0, y: 0), horizontal: true)]
        var grid: [SpokesPuzzle.Cell: (letter: Character, horizontal: Bool, vertical: Bool)] = [:]
        func add(_ entry: SpokesPuzzle.Entry) {
            for (cell, letter) in zip(entry.cells, entry.word) {
                var slot = grid[cell] ?? (letter, false, false)
                if entry.horizontal { slot.horizontal = true } else { slot.vertical = true }
                grid[cell] = slot
            }
        }
        add(placed[0])

        for word in words.dropFirst() where placed.count < target {
            var options: [(entry: SpokesPuzzle.Entry, score: Int)] = []
            for other in placed {
                for (i, a) in other.word.enumerated() {
                    for (j, b) in word.enumerated() where a == b {
                        let crossing = other.cells[i]
                        let horizontal = !other.horizontal
                        let start = horizontal ? SpokesPuzzle.Cell(x: crossing.x - j, y: crossing.y)
                                               : SpokesPuzzle.Cell(x: crossing.x, y: crossing.y - j)
                        let entry = SpokesPuzzle.Entry(word: word, start: start, horizontal: horizontal)
                        if let crossings = validCrossings(entry, grid: grid), fitsBounds(entry, placed: placed) {
                            options.append((entry, crossings * 10 + Int.random(in: 0..<5, using: &rng)))
                        }
                    }
                }
            }
            if let choice = options.max(by: { $0.score < $1.score }) {
                placed.append(choice.entry)
                add(choice.entry)
            }
        }
        return placed
    }

    /// Number of crossings if the word can be placed here without clashing or touching other words; nil if not.
    private static func validCrossings(_ entry: SpokesPuzzle.Entry,
                                       grid: [SpokesPuzzle.Cell: (letter: Character, horizontal: Bool, vertical: Bool)]) -> Int? {
        let cells = entry.cells
        let before = entry.horizontal ? SpokesPuzzle.Cell(x: entry.start.x - 1, y: entry.start.y) : SpokesPuzzle.Cell(x: entry.start.x, y: entry.start.y - 1)
        let last = cells.last!
        let after = entry.horizontal ? SpokesPuzzle.Cell(x: last.x + 1, y: last.y) : SpokesPuzzle.Cell(x: last.x, y: last.y + 1)
        guard grid[before] == nil, grid[after] == nil else { return nil }

        var crossings = 0
        for (cell, letter) in zip(cells, entry.word) {
            if let existing = grid[cell] {
                // Must be the same letter, crossing a word that runs the other way.
                guard existing.letter == letter, entry.horizontal ? !existing.horizontal : !existing.vertical else { return nil }
                crossings += 1
            } else {
                // Empty cell: its side neighbours must be empty, or we'd form accidental words.
                let sides = entry.horizontal
                    ? [SpokesPuzzle.Cell(x: cell.x, y: cell.y - 1), SpokesPuzzle.Cell(x: cell.x, y: cell.y + 1)]
                    : [SpokesPuzzle.Cell(x: cell.x - 1, y: cell.y), SpokesPuzzle.Cell(x: cell.x + 1, y: cell.y)]
                guard sides.allSatisfy({ grid[$0] == nil }) else { return nil }
            }
        }
        return crossings > 0 ? crossings : nil
    }

    private static func fitsBounds(_ entry: SpokesPuzzle.Entry, placed: [SpokesPuzzle.Entry]) -> Bool {
        let cells = (placed + [entry]).flatMap(\.cells)
        let xs = cells.map(\.x), ys = cells.map(\.y)
        return xs.max()! - xs.min()! < maxWidth && ys.max()! - ys.min()! < maxHeight
    }

    /// Shifts the layout so it starts at (0, 0).
    private static func normalized(_ entries: [SpokesPuzzle.Entry], letters: [Character]) -> SpokesPuzzle {
        let cells = entries.flatMap(\.cells)
        let minX = cells.map(\.x).min() ?? 0, minY = cells.map(\.y).min() ?? 0
        let shifted = entries.map {
            SpokesPuzzle.Entry(word: $0.word, start: .init(x: $0.start.x - minX, y: $0.start.y - minY), horizontal: $0.horizontal)
        }
        let all = shifted.flatMap(\.cells)
        return SpokesPuzzle(letters: letters, entries: shifted,
                           width: (all.map(\.x).max() ?? 0) + 1, height: (all.map(\.y).max() ?? 0) + 1)
    }

    // MARK: Letter counting

    static func counts(_ word: String) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 26)
        for scalar in word.unicodeScalars where scalar.value >= 65 && scalar.value <= 90 { c[Int(scalar.value - 65)] += 1 }
        return c
    }

    /// True if `word` can be spelled using only the letters in `base`.
    static func fits(_ word: [UInt8], in base: [UInt8]) -> Bool {
        for i in 0..<26 where word[i] > base[i] { return false }
        return true
    }
}
