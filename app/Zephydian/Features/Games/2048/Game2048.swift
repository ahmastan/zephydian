import AppKit
import SwiftUI

/// 2048: slide the tiles, merge equal numbers, reach 2048 (and keep going).
/// A fresh implementation of Gabriele Cirulli's open-source game. The board is saved, so a game survives relaunches.
@Observable
final class Game2048: GameSession {
    enum State { case playing, won, over }
    enum Direction { case left, right, up, down }

    struct Tile: Identifiable, Equatable, Codable {
        let id: Int
        var value: Int
        var row: Int
        var col: Int
        /// Merged into another tile this move: it slides onto that tile, then disappears.
        var isMerging = false
    }

    static let size = 4
    static let goal = 2048
    static let bestKey = "2048.best"
    private static let saveKey = "2048.saved"

    private(set) var tiles: [Tile] = []
    private(set) var score = 0
    private(set) var best = BestScore.get(Game2048.bestKey)
    private(set) var state: State = .playing
    /// Already reached 2048 and chose to keep going, so the card doesn't show again.
    private(set) var hasWon = false

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?

    init() {
        if !restore() { newGame() }
    }

    // MARK: GameSession

    var scoreText: String { "\(score.formatted()) · best \(best.formatted())" }
    var hint: String { state == .over ? "Enter: new game · Esc back" : "←↑↓→ or WASD slide · or drag the board · Esc back" }
    var showsPauseButton: Bool { false }
    var isRunning: Bool { false }
    func pause() {}
    func togglePause() {}

    func handleKey(_ event: NSEvent) -> Bool {
        let directions: [UInt16: Direction] = [
            Key.left: .left, Key.a: .left, Key.right: .right, Key.d: .right,
            Key.up: .up, Key.w: .up, Key.down: .down, Key.s: .down,
        ]
        if let direction = directions[event.keyCode] {
            move(direction)
            return true
        }
        if event.keyCode == Key.enter || event.keyCode == Key.keypadEnter {
            switch state {
            case .over: newGame()
            case .won: keepGoing()
            case .playing: break
            }
            return true
        }
        return false
    }

    func makeView() -> AnyView { AnyView(Game2048View(game: self)) }
    func makeHeaderAccessory() -> AnyView? { AnyView(Game2048HeaderMenu(game: self)) }

    // MARK: Game logic

    func newGame() {
        cleanupTask?.cancel()
        tiles = []
        score = 0
        hasWon = false
        state = .playing
        spawnTile()
        spawnTile()
        save()
    }

    func keepGoing() {
        guard state == .won else { return }
        state = .playing
    }

    func move(_ direction: Direction) {
        guard state == .playing else { return }
        removeMergedTiles()

        var grid: [[Int?]] = Array(repeating: Array(repeating: nil, count: Self.size), count: Self.size) // tile indices
        for (i, tile) in tiles.enumerated() { grid[tile.row][tile.col] = i }

        var moved = false
        for line in 0..<Self.size {
            // The line's cells, starting from the edge the tiles slide toward.
            let cells: [(row: Int, col: Int)] = (0..<Self.size).map { k in
                switch direction {
                case .left: (line, k)
                case .right: (line, Self.size - 1 - k)
                case .up: (k, line)
                case .down: (Self.size - 1 - k, line)
                }
            }
            var next = 0                 // next free cell in `cells`
            var lastIndex: Int?          // last tile placed in this line
            var lastMerged = false       // a tile only merges once per move
            for cell in cells {
                guard let i = grid[cell.row][cell.col] else { continue }
                if let last = lastIndex, !lastMerged, tiles[last].value == tiles[i].value {
                    tiles[last].value *= 2
                    score += tiles[last].value
                    tiles[i].row = tiles[last].row
                    tiles[i].col = tiles[last].col
                    tiles[i].isMerging = true
                    lastMerged = true
                    moved = true
                } else {
                    let target = cells[next]
                    if (tiles[i].row, tiles[i].col) != target { moved = true }
                    tiles[i].row = target.row
                    tiles[i].col = target.col
                    lastIndex = i
                    lastMerged = false
                    next += 1
                }
            }
        }
        guard moved else { return }

        if score > best {
            best = score
            BestScore.set(best, for: Self.bestKey)
        }
        spawnTile()
        if !hasWon, tiles.contains(where: { $0.value >= Self.goal && !$0.isMerging }) {
            hasWon = true
            state = .won
        } else if !canMove() {
            state = .over
        }
        save()

        // Merged tiles disappear once they've slid into place.
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(130))
            guard !Task.isCancelled else { return }
            self?.removeMergedTiles()
        }
    }

    private func removeMergedTiles() {
        if tiles.contains(where: \.isMerging) { tiles.removeAll(where: \.isMerging) }
    }

    private func spawnTile() {
        let occupied = Set(tiles.filter { !$0.isMerging }.map { $0.row * Self.size + $0.col })
        guard let spot = (0..<Self.size * Self.size).filter({ !occupied.contains($0) }).randomElement() else { return }
        tiles.append(Tile(id: nextID, value: Int.random(in: 0..<10) == 0 ? 4 : 2, row: spot / Self.size, col: spot % Self.size))
        nextID += 1
    }

    private func canMove() -> Bool {
        var grid = Array(repeating: Array(repeating: 0, count: Self.size), count: Self.size)
        for tile in tiles where !tile.isMerging { grid[tile.row][tile.col] = tile.value }
        for r in 0..<Self.size {
            for c in 0..<Self.size {
                let v = grid[r][c]
                if v == 0 { return true }
                if c + 1 < Self.size, grid[r][c + 1] == v { return true }
                if r + 1 < Self.size, grid[r + 1][c] == v { return true }
            }
        }
        return false
    }

    // MARK: Saving

    private struct Saved: Codable {
        var tiles: [Tile]
        var score: Int
        var hasWon: Bool
    }

    private func save() {
        let saved = Saved(tiles: tiles.filter { !$0.isMerging }, score: score, hasWon: hasWon)
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.saveKey)
    }

    private func restore() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.saveKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), !saved.tiles.isEmpty else { return false }
        tiles = saved.tiles
        score = saved.score
        hasWon = saved.hasWon
        nextID = (tiles.map(\.id).max() ?? 0) + 1
        state = canMove() ? .playing : .over
        return true
    }
}

// MARK: - View

struct Game2048View: View {
    let game: Game2048
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cell: CGFloat = 70
    private static let gap: CGFloat = 8
    private static var side: CGFloat { CGFloat(Game2048.size) * cell + CGFloat(Game2048.size + 1) * gap }

    var body: some View {
        let accent = settings.accent.color
        // Merging tiles go underneath the tile they merge into.
        let tiles = game.tiles.sorted { $0.isMerging && !$1.isMerging }

        ZStack {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Tokens.fill)
                ForEach(0..<Game2048.size * Game2048.size, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Tokens.fillHover)
                        .frame(width: Self.cell, height: Self.cell)
                        .position(Self.center(row: i / Game2048.size, col: i % Game2048.size))
                }
                ForEach(tiles) { tile in
                    TileView(value: tile.value, accent: accent, size: Self.cell, pops: !reduceMotion)
                        .position(Self.center(row: tile.row, col: tile.col))
                        .transition(.asymmetric(
                            insertion: reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity)
                                .animation(.easeOut(duration: 0.12).delay(0.09)),
                            removal: .identity))
                }
            }
            .frame(width: Self.side, height: Self.side)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.11), value: game.tiles)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                if abs(dx) > abs(dy) { game.move(dx > 0 ? .right : .left) } else { game.move(dy > 0 ? .down : .up) }
            })
            .accessibilityElement()
            .accessibilityLabel(accessibilityDescription)

            overlay.frame(width: Self.side, height: Self.side)
        }
        .animation(.easeOut(duration: 0.2), value: game.state)
    }

    private static func center(row: Int, col: Int) -> CGPoint {
        CGPoint(x: gap + CGFloat(col) * (cell + gap) + cell / 2, y: gap + CGFloat(row) * (cell + gap) + cell / 2)
    }

    private var accessibilityDescription: String {
        let rows = (0..<Game2048.size).map { r in
            (0..<Game2048.size).map { c in
                game.tiles.first { $0.row == r && $0.col == c && !$0.isMerging }.map { "\($0.value)" } ?? "empty"
            }.joined(separator: ", ")
        }
        return "2048 board. " + rows.enumerated().map { "Row \($0.offset + 1): \($0.element)" }.joined(separator: ". ")
    }

    @ViewBuilder private var overlay: some View {
        switch game.state {
        case .won:
            GameOverlay(title: "2048!", subtitle: "You made the 2048 tile. Keep going for a higher score?") {
                Button("Keep going") { game.keepGoing() }.prominentButtonStyle()
                Button("New game") { game.newGame() }
            }
        case .over:
            GameOverlay(title: "No moves left", subtitle: "Score \(game.score.formatted()) · Best \(game.best.formatted())") {
                Button("New game") { game.newGame() }.prominentButtonStyle()
            }
        case .playing:
            EmptyView()
        }
    }
}

private struct TileView: View {
    let value: Int
    let accent: Color
    let size: CGFloat
    let pops: Bool

    var body: some View {
        // Tiles get a stronger shade of the accent color as they grow: 2 is faint, 2048 is solid.
        let level = Double(Int(log2(Double(value))))
        let isHuge = value > Game2048.goal
        let digits = String(value).count

        Text(verbatim: String(value))
            .font(.system(size: digits <= 2 ? 30 : digits == 3 ? 26 : digits == 4 ? 22 : 18, weight: .bold).monospacedDigit())
            .foregroundStyle(isHuge ? Color(nsColor: .windowBackgroundColor) : level <= 5 ? Color.primary : Color.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHuge ? Color(nsColor: .labelColor) : accent.opacity(0.18 + 0.82 * (level - 1) / 10))
            )
            .keyframeAnimator(initialValue: 1.0, trigger: value) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                // Wait for the slide to finish, then pop (no pop with Reduce Motion).
                LinearKeyframe(1.0, duration: 0.1)
                CubicKeyframe(pops ? 1.12 : 1.0, duration: 0.07)
                CubicKeyframe(1.0, duration: 0.09)
            }
    }
}

/// Header dropdown: the score, plus New game.
struct Game2048HeaderMenu: View {
    let game: Game2048

    var body: some View {
        Menu {
            Button("New game") { game.newGame() }
        } label: {
            Text(game.scoreText)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Score and new game")
        .accessibilityLabel("Score \(game.score), best \(game.best)")
    }
}
