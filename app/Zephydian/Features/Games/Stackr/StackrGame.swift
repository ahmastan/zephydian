import AppKit
import SwiftUI

/// Stackr: a falling-block puzzle (Tetris-style gameplay, original name).
/// Uses the standard "SRS" rotation system with wall kicks, a 7-bag randomizer,
/// a ghost piece, hold, lock delay and level-based gravity.
@Observable
final class StackrGame: GameSession {
    enum State { case ready, running, paused, over }

    enum Kind: Int, CaseIterable {
        case i, o, t, s, z, j, l
    }

    struct Cell: Hashable { var x: Int, y: Int }

    struct Piece {
        var kind: Kind
        var rotation = 0
        var x: Int
        var y: Int

        var cells: [Cell] {
            StackrGame.shapes[kind]![rotation].map { Cell(x: x + $0.x, y: y + $0.y) }
        }
    }

    static let cols = 10, rows = 20
    static let bestKey = "stackr.best"

    private(set) var state: State = .ready
    private(set) var board: [[Kind?]] = []
    private(set) var current: Piece?
    private(set) var next: Kind = .t
    private(set) var hold: Kind?
    private(set) var canHold = true
    private(set) var score = 0
    private(set) var lines = 0
    private(set) var level = 1
    private(set) var best = BestScore.get(StackrGame.bestKey)
    private(set) var isNewBest = false
    /// Rows flashing just before they're cleared.
    private(set) var clearingRows: Set<Int> = []

    @ObservationIgnored private var bag: [Kind] = []
    @ObservationIgnored private var landedAt: ContinuousClock.Instant?
    @ObservationIgnored private var lockResets = 0
    @ObservationIgnored private var lockTask: Task<Void, Never>?
    @ObservationIgnored private var loop: GameLoop!

    /// How long a piece can sit on the ground before it locks (moving/rotating extends it a little).
    private static let lockDelay: Duration = .milliseconds(300)
    private static let maxLockResets = 15

    init() {
        loop = GameLoop(interval: .seconds(1)) { [weak self] in self?.gravityTick() }
        reset()
    }

    // MARK: GameSession

    var scoreText: String { "\(score.formatted()) · best \(best.formatted())" }
    var hint: String { "←→ move · ↑ rotate · ↓ soft drop · Space drop · C hold · P pause" }
    var showsPauseButton: Bool { true }
    var isRunning: Bool { state == .running }

    func pause() {
        guard state == .running else { return }
        state = .paused
        loop.stop()
        lockTask?.cancel()
    }

    func togglePause() { state == .running ? pause() : start() }

    func handleKey(_ event: NSEvent) -> Bool {
        let letter = Key.letter(event)
        if letter == "p" { togglePause(); return true }
        if letter == "r" { reset(); return true }

        guard state == .running else {
            // Any game key starts (or restarts) the game.
            let startKeys: Set<UInt16> = [Key.space, Key.enter, Key.keypadEnter, Key.left, Key.right, Key.up, Key.down]
            if startKeys.contains(event.keyCode) {
                start()
                return true
            }
            return false
        }
        guard clearingRows.isEmpty else { return true } // brief freeze while lines flash

        switch event.keyCode {
        case Key.left, Key.a: move(dx: -1)
        case Key.right, Key.d: move(dx: 1)
        case Key.down, Key.s: softDrop()
        case Key.up, Key.w: rotate(clockwise: true)
        case Key.space: hardDrop()
        default:
            switch letter {
            case "x": rotate(clockwise: true)
            case "z": rotate(clockwise: false)
            case "c": holdPiece()
            default: return false
            }
        }
        return true
    }

    func makeView() -> AnyView { AnyView(StackrView(game: self)) }

    // MARK: Lifecycle

    func start() {
        guard state != .running else { return }
        if state == .over { reset() }
        if current == nil {
            spawn()
            guard state != .over else { return }
        }
        state = .running
        loop.start()
        if landedAt != nil { scheduleLock() } // resuming with a piece on the ground
    }

    func reset() {
        loop.stop()
        lockTask?.cancel()
        board = Array(repeating: Array(repeating: nil, count: Self.cols), count: Self.rows)
        bag = []
        next = drawFromBag()
        current = nil
        hold = nil
        canHold = true
        score = 0
        lines = 0
        level = 1
        isNewBest = false
        clearingRows = []
        landedAt = nil
        loop.interval = Self.gravity(level: 1)
        state = .ready
    }

    // MARK: Moves

    private func move(dx: Int) {
        guard var piece = current else { return }
        piece.x += dx
        if fits(piece) {
            current = piece
            afterMove()
        }
    }

    private func softDrop() {
        guard var piece = current else { return }
        piece.y += 1
        if fits(piece) {
            current = piece
            score += 1
            checkGrounded()
        } else if landedAt != nil {
            lock() // pressing down on a landed piece locks it right away
        } else {
            checkGrounded()
        }
    }

    private func hardDrop() {
        guard var piece = current else { return }
        var distance = 0
        while true {
            piece.y += 1
            guard fits(piece) else { break }
            distance += 1
        }
        piece.y -= 1
        current = piece
        score += distance * 2
        lock()
    }

    private func rotate(clockwise: Bool) {
        guard let piece = current, piece.kind != .o else { return }
        let to = (piece.rotation + (clockwise ? 1 : 3)) % 4
        for kick in Self.kicks(for: piece.kind, from: piece.rotation, to: to) {
            var candidate = piece
            candidate.rotation = to
            candidate.x += kick.x
            candidate.y += kick.y
            if fits(candidate) {
                current = candidate
                afterMove()
                return
            }
        }
    }

    private func holdPiece() {
        guard canHold, let piece = current else { return }
        let stored = hold
        hold = piece.kind
        canHold = false
        landedAt = nil
        lockTask?.cancel()
        if let stored { current = Self.spawnPiece(stored) } else { spawn() }
        if let current, !fits(current) { endGame() }
    }

    // MARK: Gravity & locking

    private func gravityTick() {
        guard state == .running, clearingRows.isEmpty, var piece = current else { return }
        piece.y += 1
        guard fits(piece) else { return } // on the ground: the lock timer handles it
        current = piece
        checkGrounded()
    }

    /// Starts the lock timer the moment a piece touches down (not on the next gravity tick).
    private func checkGrounded() {
        guard var below = current else { return }
        below.y += 1
        if fits(below) {
            // In the air (e.g. slid off a ledge): no lock pending.
            landedAt = nil
            lockTask?.cancel()
        } else if landedAt == nil {
            landedAt = .now
            scheduleLock()
        }
    }

    /// After a move or rotation: a grounded piece gets a little more time (up to a limit).
    private func afterMove() {
        if landedAt != nil, lockResets < Self.maxLockResets {
            lockResets += 1
            landedAt = .now
            scheduleLock()
        }
        checkGrounded()
    }

    private func scheduleLock() {
        lockTask?.cancel()
        lockTask = Task { [weak self] in
            try? await Task.sleep(for: StackrGame.lockDelay)
            guard !Task.isCancelled, let self, self.state == .running, self.clearingRows.isEmpty else { return }
            var below = self.current
            below?.y += 1
            if let below, !self.fits(below) { self.lock() } else { self.landedAt = nil }
        }
    }

    private func lock() {
        guard let piece = current else { return }
        for cell in piece.cells {
            guard cell.y >= 0 else { endGame(); return } // locked above the top
            board[cell.y][cell.x] = piece.kind
        }
        current = nil
        landedAt = nil
        lockTask?.cancel()
        lockResets = 0
        canHold = true

        let full = Set((0..<Self.rows).filter { row in board[row].allSatisfy { $0 != nil } })
        guard !full.isEmpty else {
            spawn()
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clearRows(full)
            return
        }
        clearingRows = full
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            self?.clearRows(full)
        }
    }

    private func clearRows(_ rows: Set<Int>) {
        board = board.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        board.insert(contentsOf: Array(repeating: Array(repeating: nil, count: Self.cols), count: rows.count), at: 0)
        clearingRows = []

        let points = [0, 100, 300, 500, 800][min(rows.count, 4)]
        score += points * level
        lines += rows.count
        level = lines / 10 + 1
        loop.interval = Self.gravity(level: level)
        updateBest()
        if state != .over { spawn() }
    }

    private func spawn() {
        let piece = Self.spawnPiece(next)
        next = drawFromBag()
        current = piece
        if !fits(piece) { endGame() }
    }

    private func endGame() {
        state = .over
        loop.stop()
        updateBest()
    }

    private func updateBest() {
        guard score > best else { return }
        best = score
        isNewBest = true
        BestScore.set(best, for: Self.bestKey)
    }

    // MARK: Helpers

    func fits(_ piece: Piece) -> Bool {
        piece.cells.allSatisfy { c in
            c.x >= 0 && c.x < Self.cols && c.y < Self.rows && (c.y < 0 || board[c.y][c.x] == nil)
        }
    }

    /// Where the current piece would land (drawn faintly as a guide).
    var ghost: Piece? {
        guard var piece = current else { return nil }
        while true {
            piece.y += 1
            if !fits(piece) { piece.y -= 1; return piece }
        }
    }

    /// Every piece appears once per "bag" of 7, so droughts can't happen.
    private func drawFromBag() -> Kind {
        if bag.isEmpty { bag = Kind.allCases.shuffled() }
        return bag.removeLast()
    }

    private static func spawnPiece(_ kind: Kind) -> Piece {
        switch kind {
        case .i: Piece(kind: kind, x: 3, y: -1)
        case .o: Piece(kind: kind, x: 4, y: 0)
        default: Piece(kind: kind, x: 3, y: 0)
        }
    }

    /// Seconds per row, speeding up each level (the classic guideline curve, shifted one level
    /// faster so level 1 starts at ~0.8 s per row instead of 1 s).
    private static func gravity(level: Int) -> Duration {
        let curve = level // guideline "level + 1"
        let seconds = pow(0.8 - Double(curve - 1) * 0.007, Double(curve))
        return .milliseconds(max(50, Int(seconds * 1000)))
    }

    // MARK: Shapes & rotation tables

    /// Cells for each piece in each of its 4 rotations (x right, y down).
    static let shapes: [Kind: [[Cell]]] = {
        func rotations(_ base: [(Int, Int)], box: Int) -> [[Cell]] {
            var result = [base.map { Cell(x: $0.0, y: $0.1) }]
            for _ in 1..<4 {
                result.append(result.last!.map { Cell(x: box - 1 - $0.y, y: $0.x) }) // rotate 90° clockwise
            }
            return result
        }
        return [
            .i: rotations([(0, 1), (1, 1), (2, 1), (3, 1)], box: 4),
            .o: Array(repeating: [Cell(x: 0, y: 0), Cell(x: 1, y: 0), Cell(x: 0, y: 1), Cell(x: 1, y: 1)], count: 4),
            .t: rotations([(1, 0), (0, 1), (1, 1), (2, 1)], box: 3),
            .s: rotations([(1, 0), (2, 0), (0, 1), (1, 1)], box: 3),
            .z: rotations([(0, 0), (1, 0), (1, 1), (2, 1)], box: 3),
            .j: rotations([(0, 0), (0, 1), (1, 1), (2, 1)], box: 3),
            .l: rotations([(2, 0), (0, 1), (1, 1), (2, 1)], box: 3),
        ]
    }()

    /// SRS wall-kick offsets to try, in order. The tables use y-up, so y is flipped for our y-down board.
    static func kicks(for kind: Kind, from: Int, to: Int) -> [Cell] {
        let jlstz: [String: [(Int, Int)]] = [
            "01": [(0, 0), (-1, 0), (-1, 1), (0, -2), (-1, -2)],
            "10": [(0, 0), (1, 0), (1, -1), (0, 2), (1, 2)],
            "12": [(0, 0), (1, 0), (1, -1), (0, 2), (1, 2)],
            "21": [(0, 0), (-1, 0), (-1, 1), (0, -2), (-1, -2)],
            "23": [(0, 0), (1, 0), (1, 1), (0, -2), (1, -2)],
            "32": [(0, 0), (-1, 0), (-1, -1), (0, 2), (-1, 2)],
            "30": [(0, 0), (-1, 0), (-1, -1), (0, 2), (-1, 2)],
            "03": [(0, 0), (1, 0), (1, 1), (0, -2), (1, -2)],
        ]
        let iPiece: [String: [(Int, Int)]] = [
            "01": [(0, 0), (-2, 0), (1, 0), (-2, -1), (1, 2)],
            "10": [(0, 0), (2, 0), (-1, 0), (2, 1), (-1, -2)],
            "12": [(0, 0), (-1, 0), (2, 0), (-1, 2), (2, -1)],
            "21": [(0, 0), (1, 0), (-2, 0), (1, -2), (-2, 1)],
            "23": [(0, 0), (2, 0), (-1, 0), (2, 1), (-1, -2)],
            "32": [(0, 0), (-2, 0), (1, 0), (-2, -1), (1, 2)],
            "30": [(0, 0), (1, 0), (-2, 0), (1, -2), (-2, 1)],
            "03": [(0, 0), (-1, 0), (2, 0), (-1, 2), (2, -1)],
        ]
        let table = kind == .i ? iPiece : jlstz
        return (table["\(from)\(to)"] ?? [(0, 0)]).map { Cell(x: $0.0, y: -$0.1) }
    }
}
