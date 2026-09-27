import Foundation

/// A Nines (Sudoku-style) puzzle. Cells are numbered 0–80, row by row, and 0 means empty.
nonisolated struct NinesPuzzle: Codable, Sendable, Equatable {
    var givens: [Int]
    var solution: [Int]
}

/// Makes puzzles with exactly one solution: fill a random complete grid, then remove numbers
/// one at a time, keeping each removal only if the puzzle still has a single solution.
nonisolated enum NinesGenerator {
    /// How many numbers each difficulty starts with (fewer = harder).
    static func clueTarget(_ difficulty: NinesGame.Difficulty) -> Int {
        switch difficulty {
        case .easy: 38
        case .medium: 30
        case .hard: 25
        }
    }

    static func make(_ difficulty: NinesGame.Difficulty) -> NinesPuzzle {
        var solver = Solver()
        var solution = Array(repeating: 0, count: 81)
        _ = solver.fill(&solution)

        var givens = solution
        var clues = 81
        let target = clueTarget(difficulty)
        for cell in (0..<81).shuffled() where clues > target {
            let saved = givens[cell]
            givens[cell] = 0
            var check = givens
            if solver.countSolutions(&check, limit: 2) == 1 {
                clues -= 1
            } else {
                givens[cell] = saved
            }
        }
        return NinesPuzzle(givens: givens, solution: solution)
    }

    static func row(_ cell: Int) -> Int { cell / 9 }
    static func col(_ cell: Int) -> Int { cell % 9 }
    static func box(_ cell: Int) -> Int { (cell / 27) * 3 + (cell % 9) / 3 }

    /// The 20 cells that share a row, column or box with `cell`.
    static let peers: [[Int]] = (0..<81).map { cell in
        (0..<81).filter { $0 != cell && (row($0) == row(cell) || col($0) == col(cell) || box($0) == box(cell)) }
    }

    /// Backtracking solver using bitmasks, always trying the cell with the fewest options first.
    struct Solver {
        private var rows = [Int](repeating: 0, count: 9)
        private var cols = [Int](repeating: 0, count: 9)
        private var boxes = [Int](repeating: 0, count: 9)

        /// Fills an empty grid with a random complete solution.
        mutating func fill(_ grid: inout [Int]) -> Bool {
            load(grid)
            return search(&grid, randomize: true, limit: 1, count: 0) > 0
        }

        /// Counts solutions, stopping once `limit` is reached.
        mutating func countSolutions(_ grid: inout [Int], limit: Int) -> Int {
            guard load(grid) else { return 0 }
            return search(&grid, randomize: false, limit: limit, count: 0)
        }

        /// Returns false if the grid already breaks a rule.
        @discardableResult
        private mutating func load(_ grid: [Int]) -> Bool {
            rows = [Int](repeating: 0, count: 9)
            cols = rows
            boxes = rows
            for cell in 0..<81 where grid[cell] != 0 {
                let bit = 1 << grid[cell]
                let r = NinesGenerator.row(cell), c = NinesGenerator.col(cell), b = NinesGenerator.box(cell)
                if (rows[r] | cols[c] | boxes[b]) & bit != 0 { return false }
                rows[r] |= bit; cols[c] |= bit; boxes[b] |= bit
            }
            return true
        }

        private mutating func search(_ grid: inout [Int], randomize: Bool, limit: Int, count: Int) -> Int {
            // Find the empty cell with the fewest candidates.
            var best = -1, bestMask = 0, bestCount = 10
            for cell in 0..<81 where grid[cell] == 0 {
                let used = rows[NinesGenerator.row(cell)] | cols[NinesGenerator.col(cell)] | boxes[NinesGenerator.box(cell)]
                let mask = ~used & 0b11_1111_1110
                let n = mask.nonzeroBitCount
                if n < bestCount {
                    best = cell; bestMask = mask; bestCount = n
                    if n <= 1 { break }
                }
            }
            if best < 0 { return count + 1 } // no empty cells: solved
            if bestCount == 0 { return count }

            var digits = (1...9).filter { bestMask & (1 << $0) != 0 }
            if randomize { digits.shuffle() }
            let r = NinesGenerator.row(best), c = NinesGenerator.col(best), b = NinesGenerator.box(best)
            var found = count
            for d in digits {
                let bit = 1 << d
                grid[best] = d
                rows[r] |= bit; cols[c] |= bit; boxes[b] |= bit
                found = search(&grid, randomize: randomize, limit: limit, count: found)
                if found >= limit { return found } // keep the grid filled when stopping early
                rows[r] &= ~bit; cols[c] &= ~bit; boxes[b] &= ~bit
                grid[best] = 0
            }
            return found
        }
    }
}
