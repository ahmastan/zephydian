import SwiftUI

struct FleetView: View {
    let game: FleetGame
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if game.phase == .placing {
                    placement
                } else {
                    battle
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let message = game.message, game.phase == .battle {
                GameToast(text: message)
            }

            if game.phase == .won || game.phase == .lost {
                GameOverlay(title: game.phase == .won ? "Victory!" : "Your fleet was sunk",
                            subtitle: game.phase == .won ? "You sank all 5 enemy ships." : "Better luck next time.") {
                    Button("New game") { game.newGame() }.prominentButtonStyle()
                }
                .padding(.horizontal, 16)
            }
        }
        .animation(.easeOut(duration: 0.15), value: game.message)
        .animation(.easeOut(duration: 0.2), value: game.phase)
    }

    // MARK: Placement

    private var placement: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("Place your fleet").font(.system(size: 15, weight: .semibold))
                Text("Drag a ship to move it · click it to rotate").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            PlacementBoard(game: game, accent: settings.accent.color)
            HStack(spacing: 8) {
                Button { game.shufflePlayerFleet() } label: { Label("Shuffle", systemImage: "shuffle") }
                Button("Start battle") { game.startBattle() }.prominentButtonStyle()
            }
        }
    }

    // MARK: Battle

    private var battle: some View {
        VStack(spacing: 10) {
            HStack {
                Text("ENEMY WATERS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(game.isPlayerTurn ? "Your turn" : "Enemy is aiming…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(game.isPlayerTurn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .frame(width: 260)

            TargetBoard(game: game, accent: settings.accent.color)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("YOUR FLEET").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    OwnBoard(game: game, accent: settings.accent.color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("ENEMY SHIPS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                    ForEach(game.enemyShips) { ship in
                        let sunk = FleetGame.isSunk(ship, shots: game.playerShots)
                        HStack(spacing: 6) {
                            Text(ship.name).font(.system(size: 11)).strikethrough(sunk)
                            Spacer(minLength: 4)
                            HStack(spacing: 2) {
                                ForEach(0..<ship.length, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 1.5).frame(width: 6, height: 6)
                                }
                            }
                        }
                        .foregroundStyle(sunk ? .tertiary : .secondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(ship.name), \(sunk ? "sunk" : "afloat")")
                    }
                }
                .frame(width: 124)
            }
            .frame(width: 260)
        }
    }
}

// MARK: - Boards

private enum BoardDrawing {
    static func water(_ context: inout GraphicsContext, size: CGSize, accent: Color) {
        context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(accent.opacity(0.12)))
        var grid = Path()
        let cell = size.width / CGFloat(FleetGame.size)
        for i in 1..<FleetGame.size {
            let p = CGFloat(i) * cell
            grid.move(to: CGPoint(x: p, y: 0)); grid.addLine(to: CGPoint(x: p, y: size.height))
            grid.move(to: CGPoint(x: 0, y: p)); grid.addLine(to: CGPoint(x: size.width, y: p))
        }
        context.stroke(grid, with: .color(accent.opacity(0.15)), lineWidth: 0.5)
    }

    static func ship(_ context: inout GraphicsContext, _ ship: FleetGame.Ship, cell: CGFloat, color: Color, offset: CGSize = .zero) {
        let cells = ship.cells
        let minX = CGFloat(cells.map(\.x).min()!), minY = CGFloat(cells.map(\.y).min()!)
        let w = ship.horizontal ? CGFloat(ship.length) : 1, h = ship.horizontal ? 1 : CGFloat(ship.length)
        let rect = CGRect(x: minX * cell + 3 + offset.width, y: minY * cell + 3 + offset.height,
                          width: w * cell - 6, height: h * cell - 6)
        context.fill(Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2), with: .color(color))
    }

    static func marker(_ context: inout GraphicsContext, _ shot: FleetGame.Shot, at c: FleetGame.Cell, cell: CGFloat) {
        let center = CGPoint(x: (CGFloat(c.x) + 0.5) * cell, y: (CGFloat(c.y) + 0.5) * cell)
        switch shot {
        case .miss:
            let r = max(2, cell * 0.12)
            context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(.secondary))
        case .hit:
            let r = cell * 0.32
            context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(.red))
            var x = Path()
            let k = r * 0.5
            x.move(to: CGPoint(x: center.x - k, y: center.y - k)); x.addLine(to: CGPoint(x: center.x + k, y: center.y + k))
            x.move(to: CGPoint(x: center.x + k, y: center.y - k)); x.addLine(to: CGPoint(x: center.x - k, y: center.y + k))
            context.stroke(x, with: .color(.white), style: StrokeStyle(lineWidth: max(1.2, cell * 0.07), lineCap: .round))
        }
    }

    static func cell(at point: CGPoint, cellSize: CGFloat) -> FleetGame.Cell? {
        let x = Int(point.x / cellSize), y = Int(point.y / cellSize)
        guard point.x >= 0, point.y >= 0, x < FleetGame.size, y < FleetGame.size else { return nil }
        return FleetGame.Cell(x: x, y: y)
    }
}

/// Your board during setup: drag ships to move them, click to rotate.
private struct PlacementBoard: View {
    let game: FleetGame
    let accent: Color
    @State private var dragging: (id: Int, offset: CGSize, grabCell: FleetGame.Cell)?

    private let cell: CGFloat = 28

    var body: some View {
        let ships = game.playerShips
        let side = cell * CGFloat(FleetGame.size)
        let drag = dragging

        Canvas { context, size in
            BoardDrawing.water(&context, size: size, accent: accent)
            for ship in ships {
                let isDragged = drag?.id == ship.id
                BoardDrawing.ship(&context, ship, cell: cell,
                                  color: isDragged ? accent.opacity(0.7) : Color.secondary.opacity(0.8),
                                  offset: isDragged ? drag!.offset : .zero)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .onTapGesture { location in
            if let c = BoardDrawing.cell(at: location, cellSize: cell) { game.rotateShip(at: c) }
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if dragging == nil {
                        guard let c = BoardDrawing.cell(at: value.startLocation, cellSize: cell),
                              let ship = game.playerShips.first(where: { $0.cells.contains(c) }) else { return }
                        dragging = (ship.id, .zero, c)
                    }
                    dragging?.offset = value.translation
                }
                .onEnded { value in
                    defer { dragging = nil }
                    guard let drag = dragging, let ship = game.playerShips.first(where: { $0.id == drag.id }) else { return }
                    let dx = Int((value.translation.width / cell).rounded()), dy = Int((value.translation.height / cell).rounded())
                    game.moveShip(drag.id, to: FleetGame.Cell(x: ship.origin.x + dx, y: ship.origin.y + dy))
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Your fleet placement. Use Shuffle to rearrange.")
    }
}

/// The enemy's board: click (or arrows + Space) to fire.
private struct TargetBoard: View {
    let game: FleetGame
    let accent: Color
    @State private var hovered: FleetGame.Cell?

    private let cell: CGFloat = 26

    var body: some View {
        let shots = game.playerShots
        let sunkShips = game.enemyShips.filter { FleetGame.isSunk($0, shots: shots) }
        let cursor = game.cursor
        let hovered = hovered
        let canFire = game.isPlayerTurn && game.phase == .battle
        let revealAll = game.phase == .lost
        let enemyShips = game.enemyShips
        let side = cell * CGFloat(FleetGame.size)

        Canvas { context, size in
            BoardDrawing.water(&context, size: size, accent: accent)
            for ship in (revealAll ? enemyShips : sunkShips) {
                BoardDrawing.ship(&context, ship, cell: cell, color: Color.secondary.opacity(0.55))
            }
            for (c, shot) in shots { BoardDrawing.marker(&context, shot, at: c, cell: cell) }
            if canFire {
                for target in Set([cursor, hovered].compactMap { $0 }) where shots[target] == nil {
                    let rect = CGRect(x: CGFloat(target.x) * cell + 1.5, y: CGFloat(target.y) * cell + 1.5, width: cell - 3, height: cell - 3)
                    context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(accent), lineWidth: 2)
                }
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let point) = phase { self.hovered = BoardDrawing.cell(at: point, cellSize: cell) } else { self.hovered = nil }
        }
        .onTapGesture { location in
            if let c = BoardDrawing.cell(at: location, cellSize: cell) { game.fire(at: c) }
        }
        .accessibilityElement()
        .accessibilityLabel("Enemy waters. \(shots.values.filter { $0 == .hit }.count) hits. Use arrow keys and Space to fire.")
    }
}

/// A small map of your own fleet and where the computer has fired.
private struct OwnBoard: View {
    let game: FleetGame
    let accent: Color

    private let cell: CGFloat = 12

    var body: some View {
        let ships = game.playerShips
        let shots = game.enemyShots
        let last = game.lastEnemyShot
        let side = cell * CGFloat(FleetGame.size)

        Canvas { context, size in
            BoardDrawing.water(&context, size: size, accent: accent)
            for ship in ships {
                let sunk = FleetGame.isSunk(ship, shots: shots)
                BoardDrawing.ship(&context, ship, cell: cell, color: Color.secondary.opacity(sunk ? 0.3 : 0.8))
            }
            for (c, shot) in shots { BoardDrawing.marker(&context, shot, at: c, cell: cell) }
            if let last {
                let rect = CGRect(x: CGFloat(last.x) * cell, y: CGFloat(last.y) * cell, width: cell, height: cell)
                context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(accent), lineWidth: 1.5)
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel("Your fleet. \(ships.filter { !FleetGame.isSunk($0, shots: shots) }.count) of 5 ships afloat.")
    }
}

/// Header dropdown: difficulty and new game.
struct FleetHeaderMenu: View {
    let game: FleetGame

    var body: some View {
        Menu {
            Picker("Computer", selection: Binding(get: { game.difficulty }, set: { game.difficulty = $0 })) {
                ForEach(FleetGame.Difficulty.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("New game") { game.newGame() }
        } label: {
            Text("\(game.difficulty.title) · \(game.scoreText)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Computer difficulty and new game")
    }
}
