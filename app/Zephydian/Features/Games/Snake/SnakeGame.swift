import AppKit
import SwiftUI

/// Classic Snake: eat, grow, don't hit the walls or yourself. Speeds up as you score.
@Observable
final class SnakeGame: GameSession {
    enum State { case ready, running, paused, over }
    struct Point: Hashable { var x: Int, y: Int }

    static let cols = 20, rows = 24
    static let bestKey = "snake.best"

    private(set) var state: State = .ready
    private(set) var snake: [Point] = []
    private(set) var food: Point?
    private(set) var score = 0
    private(set) var best = BestScore.get(SnakeGame.bestKey)
    private(set) var isNewBest = false

    @ObservationIgnored private var direction = Point(x: 1, y: 0)
    @ObservationIgnored private var queuedTurns: [Point] = []   // lets quick double-taps register
    @ObservationIgnored private var loop: GameLoop!

    init() {
        loop = GameLoop(interval: .milliseconds(140)) { [weak self] in self?.step() }
        reset()
    }

    // MARK: GameSession

    var scoreText: String { "\(score) · best \(best)" }
    var hint: String { "←↑↓→ or WASD move · Space pause · R restart · Esc back" }
    var showsPauseButton: Bool { true }
    var isRunning: Bool { state == .running }

    func pause() {
        guard state == .running else { return }
        state = .paused
        loop.stop()
    }

    func togglePause() { state == .running ? pause() : start() }

    func handleKey(_ event: NSEvent) -> Bool {
        let turns: [UInt16: Point] = [
            Key.up: Point(x: 0, y: -1), Key.w: Point(x: 0, y: -1),
            Key.down: Point(x: 0, y: 1), Key.s: Point(x: 0, y: 1),
            Key.left: Point(x: -1, y: 0), Key.a: Point(x: -1, y: 0),
            Key.right: Point(x: 1, y: 0), Key.d: Point(x: 1, y: 0),
        ]
        if let turn = turns[event.keyCode] {
            guard state != .over else { return true }
            let last = queuedTurns.last ?? direction
            let reverses = turn.x == -last.x && turn.y == -last.y
            if !reverses, turn != last, queuedTurns.count < 2 { queuedTurns.append(turn) }
            if state != .running { start() }
            return true
        }
        switch event.keyCode {
        case Key.space:
            togglePause()
            return true
        case Key.enter, Key.keypadEnter:
            if state != .running { start() }
            return true
        default:
            break
        }
        if Key.letter(event) == "r" {
            reset()
            return true
        }
        return false
    }

    func makeView() -> AnyView { AnyView(SnakeView(game: self)) }

    // MARK: Game logic

    func start() {
        guard state != .running else { return }
        if state == .over { reset() }
        state = .running
        loop.start()
    }

    func reset() {
        loop.stop()
        snake = [Point(x: 8, y: 12), Point(x: 7, y: 12), Point(x: 6, y: 12)]
        direction = Point(x: 1, y: 0)
        queuedTurns = []
        score = 0
        isNewBest = false
        loop.interval = .milliseconds(140)
        placeFood()
        state = .ready
    }

    private func step() {
        if !queuedTurns.isEmpty { direction = queuedTurns.removeFirst() }
        let head = Point(x: snake[0].x + direction.x, y: snake[0].y + direction.y)
        let eating = head == food
        let body = eating ? snake[...] : snake.dropLast() // the tail moves out of the way unless we grow
        let hitsWall = head.x < 0 || head.y < 0 || head.x >= Self.cols || head.y >= Self.rows
        if hitsWall || body.contains(head) {
            endGame()
            return
        }
        snake.insert(head, at: 0)
        if eating {
            score += 1
            loop.interval = .milliseconds(max(65, 140 - score * 3))
            if score > best {
                best = score
                isNewBest = true
                BestScore.set(best, for: Self.bestKey)
            }
            placeFood()
            if food == nil { endGame() } // filled the whole board!
        } else {
            snake.removeLast()
        }
    }

    private func placeFood() {
        let occupied = Set(snake)
        var free: [Point] = []
        for y in 0..<Self.rows {
            for x in 0..<Self.cols where !occupied.contains(Point(x: x, y: y)) {
                free.append(Point(x: x, y: y))
            }
        }
        food = free.randomElement()
    }

    private func endGame() {
        state = .over
        loop.stop()
    }
}

// MARK: - View

struct SnakeView: View {
    let game: SnakeGame
    @Environment(SettingsStore.self) private var settings

    private static let cell: CGFloat = 17

    var body: some View {
        // Read the state here (not inside Canvas) so SwiftUI redraws when it changes.
        let snake = game.snake
        let food = game.food
        let accent = settings.accent.color
        let cell = Self.cell

        ZStack {
            Canvas { context, size in
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10), with: .color(Tokens.fill))
                // Faint dot grid
                var dots = Path()
                for y in 0..<SnakeGame.rows {
                    for x in 0..<SnakeGame.cols {
                        dots.addRect(CGRect(x: CGFloat(x) * cell + cell / 2 - 1, y: CGFloat(y) * cell + cell / 2 - 1, width: 2, height: 2))
                    }
                }
                context.fill(dots, with: .color(Tokens.fillHover))

                if let food {
                    let rect = CGRect(x: CGFloat(food.x) * cell + 3, y: CGFloat(food.y) * cell + 3, width: cell - 6, height: cell - 6)
                    context.fill(Path(ellipseIn: rect), with: .color(.red))
                }
                for (i, part) in snake.enumerated() {
                    let rect = CGRect(x: CGFloat(part.x) * cell + 1.5, y: CGFloat(part.y) * cell + 1.5, width: cell - 3, height: cell - 3)
                    let fade = i == 0 ? 1 : max(0.55, 1 - Double(i) / Double(snake.count) * 0.45)
                    context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(accent.opacity(fade)))
                }
            }
            .frame(width: CGFloat(SnakeGame.cols) * cell, height: CGFloat(SnakeGame.rows) * cell)
            .accessibilityLabel("Snake board, score \(game.score)")

            overlay
                .frame(width: CGFloat(SnakeGame.cols) * cell, height: CGFloat(SnakeGame.rows) * cell)
        }
        .animation(.easeOut(duration: 0.15), value: game.state)
    }

    @ViewBuilder private var overlay: some View {
        switch game.state {
        case .ready:
            GameOverlay(title: "Snake", subtitle: "Press an arrow key or WASD to start") {
                Button("Start") { game.start() }.prominentButtonStyle()
            }
        case .paused:
            GameOverlay(title: "Paused", subtitle: "Score \(game.score)") {
                Button("Resume") { game.start() }.prominentButtonStyle()
                Button("Restart") { game.reset(); game.start() }
            }
        case .over:
            GameOverlay(title: game.isNewBest ? "New best!" : "Game over", subtitle: "Score \(game.score) · Best \(game.best)") {
                Button("Play again") { game.start() }.prominentButtonStyle()
            }
        case .running:
            EmptyView()
        }
    }
}
