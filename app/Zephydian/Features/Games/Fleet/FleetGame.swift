import AppKit
import SwiftUI

/// Fleet: sink the computer's ships before it sinks yours (Battleship-style gameplay, original name).
@Observable
final class FleetGame: GameSession {
    enum Phase { case placing, battle, won, lost }
    enum Shot { case miss, hit }

    enum Difficulty: String, CaseIterable, Identifiable {
        case easy, normal
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    struct Cell: Hashable { var x: Int, y: Int }

    struct Ship: Identifiable {
        let id: Int
        let name: String
        let length: Int
        var origin: Cell
        var horizontal: Bool

        var cells: [Cell] {
            (0..<length).map { horizontal ? Cell(x: origin.x + $0, y: origin.y) : Cell(x: origin.x, y: origin.y + $0) }
        }
    }

    static let size = 10
    static let fleet: [(name: String, length: Int)] = [
        ("Carrier", 5), ("Battleship", 4), ("Cruiser", 3), ("Submarine", 3), ("Destroyer", 2),
    ]

    private(set) var phase: Phase = .placing
    private(set) var playerShips: [Ship] = []
    private(set) var enemyShips: [Ship] = []
    /// Your shots at the enemy's board.
    private(set) var playerShots: [Cell: Shot] = [:]
    /// The computer's shots at your board.
    private(set) var enemyShots: [Cell: Shot] = [:]
    private(set) var lastEnemyShot: Cell?
    private(set) var cursor = Cell(x: 4, y: 4)
    private(set) var isPlayerTurn = true
    private(set) var message: String?
    private(set) var wins = UserDefaults.standard.integer(forKey: "fleet.wins")
    var difficulty: Difficulty {
        didSet { UserDefaults.standard.set(difficulty.rawValue, forKey: "fleet.difficulty") }
    }

    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var enemyTurnTask: Task<Void, Never>?

    init() {
        difficulty = Difficulty(rawValue: UserDefaults.standard.string(forKey: "fleet.difficulty") ?? "") ?? .normal
        newGame()
    }

    // MARK: GameSession

    var scoreText: String { "\(wins) win\(wins == 1 ? "" : "s")" }
    var hint: String {
        switch phase {
        case .placing: "Drag ships to move · click to rotate · Space shuffle · Enter start"
        case .battle: "Click or use arrows + Space to fire · Esc back"
        case .won, .lost: "Enter: new game · Esc back"
        }
    }
    var showsPauseButton: Bool { false }
    var isRunning: Bool { false }
    func pause() {}
    func togglePause() {}

    func handleKey(_ event: NSEvent) -> Bool {
        switch phase {
        case .placing:
            if event.keyCode == Key.space { shufflePlayerFleet(); return true }
            if event.keyCode == Key.enter || event.keyCode == Key.keypadEnter { startBattle(); return true }
        case .battle:
            let moves: [UInt16: (Int, Int)] = [
                Key.left: (-1, 0), Key.a: (-1, 0), Key.right: (1, 0), Key.d: (1, 0),
                Key.up: (0, -1), Key.w: (0, -1), Key.down: (0, 1), Key.s: (0, 1),
            ]
            if let (dx, dy) = moves[event.keyCode] {
                cursor = Cell(x: min(max(cursor.x + dx, 0), Self.size - 1), y: min(max(cursor.y + dy, 0), Self.size - 1))
                return true
            }
            if [Key.space, Key.enter, Key.keypadEnter].contains(event.keyCode) { fire(at: cursor); return true }
        case .won, .lost:
            if event.keyCode == Key.enter || event.keyCode == Key.keypadEnter { newGame(); return true }
        }
        return false
    }

    func makeView() -> AnyView { AnyView(FleetView(game: self)) }
    func makeHeaderAccessory() -> AnyView? { AnyView(FleetHeaderMenu(game: self)) }

    // MARK: Setup

    func newGame() {
        enemyTurnTask?.cancel()
        playerShips = Self.randomFleet()
        enemyShips = Self.randomFleet()
        playerShots = [:]
        enemyShots = [:]
        lastEnemyShot = nil
        isPlayerTurn = true
        message = nil
        phase = .placing
    }

    func shufflePlayerFleet() {
        guard phase == .placing else { return }
        playerShips = Self.randomFleet()
    }

    /// Rotates a ship during placement (if it still fits).
    func rotateShip(at cell: Cell) {
        guard phase == .placing, let index = playerShips.firstIndex(where: { $0.cells.contains(cell) }) else { return }
        var ship = playerShips[index]
        ship.horizontal.toggle()
        if Self.canPlace(ship, among: playerShips) { playerShips[index] = ship }
    }

    /// Moves a ship during placement. Returns false (and leaves it) if the spot isn't free.
    @discardableResult
    func moveShip(_ id: Int, to origin: Cell) -> Bool {
        guard phase == .placing, let index = playerShips.firstIndex(where: { $0.id == id }) else { return false }
        var ship = playerShips[index]
        ship.origin = origin
        guard Self.canPlace(ship, among: playerShips) else { return false }
        playerShips[index] = ship
        return true
    }

    func startBattle() {
        guard phase == .placing else { return }
        phase = .battle
        show("Your turn: fire at the enemy's waters")
    }

    // MARK: Battle

    func fire(at cell: Cell) {
        guard phase == .battle, isPlayerTurn, playerShots[cell] == nil else { return }
        cursor = cell
        let hitShip = enemyShips.first { $0.cells.contains(cell) }
        playerShots[cell] = hitShip == nil ? .miss : .hit

        if let hitShip, Self.isSunk(hitShip, shots: playerShots) {
            show("You sank their \(hitShip.name)!")
        } else {
            show(hitShip == nil ? "Miss" : "Hit!")
        }
        if enemyShips.allSatisfy({ Self.isSunk($0, shots: playerShots) }) {
            finish(won: true)
            return
        }
        isPlayerTurn = false
        enemyTurnTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.enemyTurn()
        }
    }

    private func enemyTurn() {
        guard phase == .battle else { return }
        let cell = difficulty == .easy ? randomTarget() : smartTarget()
        let hitShip = playerShips.first { $0.cells.contains(cell) }
        enemyShots[cell] = hitShip == nil ? .miss : .hit
        lastEnemyShot = cell

        if let hitShip, Self.isSunk(hitShip, shots: enemyShots) {
            show("They sank your \(hitShip.name)!")
        } else if hitShip != nil {
            show("They hit your \(hitShip!.name)")
        }
        if playerShips.allSatisfy({ Self.isSunk($0, shots: enemyShots) }) {
            finish(won: false)
            return
        }
        isPlayerTurn = true
    }

    private func finish(won: Bool) {
        phase = won ? .won : .lost
        isPlayerTurn = false
        if won {
            wins += 1
            UserDefaults.standard.set(wins, forKey: "fleet.wins")
        }
    }

    // MARK: Computer opponent

    private var unshot: [Cell] {
        (0..<Self.size).flatMap { y in (0..<Self.size).map { Cell(x: $0, y: y) } }.filter { enemyShots[$0] == nil }
    }

    private func randomTarget() -> Cell { unshot.randomElement()! }

    /// Normal difficulty: "hunt" on a checkerboard until something is hit, then "target" around it,
    /// following the line once two hits line up. Only uses information a human player would have.
    private func smartTarget() -> Cell {
        let sunkCells = Set(playerShips.filter { Self.isSunk($0, shots: enemyShots) }.flatMap(\.cells))
        let openHits = enemyShots.filter { $0.value == .hit && !sunkCells.contains($0.key) }.map(\.key)
        func free(_ c: Cell) -> Bool { c.x >= 0 && c.y >= 0 && c.x < Self.size && c.y < Self.size && enemyShots[c] == nil }

        if !openHits.isEmpty {
            // Two or more hits in a line: keep extending that line.
            for a in openHits {
                for (dx, dy) in [(1, 0), (0, 1)] {
                    let b = Cell(x: a.x + dx, y: a.y + dy)
                    guard openHits.contains(b) else { continue }
                    var step = a // walk back to the start of the line of hits
                    while openHits.contains(Cell(x: step.x - dx, y: step.y - dy)) { step = Cell(x: step.x - dx, y: step.y - dy) }
                    var line = [step]
                    while openHits.contains(Cell(x: line.last!.x + dx, y: line.last!.y + dy)) {
                        line.append(Cell(x: line.last!.x + dx, y: line.last!.y + dy))
                    }
                    let ends = [Cell(x: line.first!.x - dx, y: line.first!.y - dy), Cell(x: line.last!.x + dx, y: line.last!.y + dy)]
                    if let next = ends.filter(free).randomElement() { return next }
                }
            }
            // A lone hit: try its neighbours.
            let neighbours = openHits.flatMap { h in
                [Cell(x: h.x + 1, y: h.y), Cell(x: h.x - 1, y: h.y), Cell(x: h.x, y: h.y + 1), Cell(x: h.x, y: h.y - 1)]
            }.filter(free)
            if let next = neighbours.randomElement() { return next }
        }
        // Hunt: every ship is at least 2 long, so a checkerboard pattern is enough to find them all.
        let pattern = unshot.filter { ($0.x + $0.y) % 2 == 0 }
        return (pattern.isEmpty ? unshot : pattern).randomElement()!
    }

    // MARK: Helpers

    static func isSunk(_ ship: Ship, shots: [Cell: Shot]) -> Bool {
        ship.cells.allSatisfy { shots[$0] == .hit }
    }

    static func canPlace(_ ship: Ship, among ships: [Ship], allowTouching: Bool = true) -> Bool {
        let cells = ship.cells
        guard cells.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x < size && $0.y < size }) else { return false }
        let others = ships.filter { $0.id != ship.id }.flatMap(\.cells)
        let blocked: Set<Cell> = allowTouching
            ? Set(others)
            : Set(others.flatMap { c in (-1...1).flatMap { dx in (-1...1).map { dy in Cell(x: c.x + dx, y: c.y + dy) } } })
        return cells.allSatisfy { !blocked.contains($0) }
    }

    /// A random fleet where ships don't touch (falls back to touching if it gets stuck).
    static func randomFleet() -> [Ship] {
        for attempt in 0..<200 {
            var ships: [Ship] = []
            var failed = false
            for (id, spec) in fleet.enumerated() {
                var placed = false
                for _ in 0..<100 {
                    let ship = Ship(id: id, name: spec.name, length: spec.length,
                                    origin: Cell(x: Int.random(in: 0..<size), y: Int.random(in: 0..<size)),
                                    horizontal: Bool.random())
                    if canPlace(ship, among: ships, allowTouching: attempt > 150) {
                        ships.append(ship)
                        placed = true
                        break
                    }
                }
                if !placed { failed = true; break }
            }
            if !failed { return ships }
        }
        return fleet.enumerated().map { Ship(id: $0.offset, name: $0.element.name, length: $0.element.length,
                                             origin: Cell(x: 0, y: $0.offset * 2), horizontal: true) }
    }

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    static var tileStat: String {
        let wins = UserDefaults.standard.integer(forKey: "fleet.wins")
        return wins > 0 ? "\(wins) win\(wins == 1 ? "" : "s")" : "Not played"
    }
}
