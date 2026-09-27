import Foundation

/// Word lists for the word games, built by scripts/build-wordlists.py from SCOWL
/// (see Resources/Words/SCOWL-LICENSE.txt). Each list is loaded the first time it's needed.
final class WordBank {
    static let shared = WordBank()

    /// Common 5-letter words, in daily order.
    lazy var fiveAnswers: [String] = load("five-answers")
    /// Every 5-letter word accepted as a guess.
    lazy var fiveValid: Set<String> = Set(load("five-valid")).union(fiveAnswers)
    /// Common 3–6 letter words used to build Spokes puzzles.
    lazy var wheelWords: [String] = load("wheel-words")
    /// Every 3–6 letter word accepted in Spokes (extra finds are bonus words).
    lazy var wheelValid: Set<String> = Set(load("wheel-valid")).union(wheelWords)

    private func load(_ name: String) -> [String] {
        let url = Bundle.main.url(forResource: name, withExtension: "txt")
            ?? Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Words")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Missing word list \(name).txt")
            return []
        }
        return text.split(separator: "\n").map { $0.uppercased() }
    }
}

/// A small, fast random generator that always produces the same sequence for the same seed,
/// so e.g. Spokes level 12 is the same puzzle for everyone.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 { // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
