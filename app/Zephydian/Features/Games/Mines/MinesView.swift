import AppKit
import SwiftUI

struct MinesView: View {
    let game: MinesGame
    @Environment(SettingsStore.self) private var settings
    @State private var hovered: MinesGame.Cell?

    /// Cell size per difficulty, so every board fits the panel.
    private var cell: CGFloat {
        switch game.difficulty {
        case .easy: 34
        case .medium: 26
        case .hard: 23
        }
    }

    var body: some View {
        let cell = cell
        let size = CGSize(width: CGFloat(game.cols) * cell, height: CGFloat(game.rows) * cell)

        VStack(spacing: 8) {
            HStack {
                Label("\(game.minesLeft)", systemImage: "flag.fill")
                    .accessibilityLabel("\(game.minesLeft) mines left")
                Spacer()
                Label(BestTime.format(game.seconds), systemImage: "clock")
                    .accessibilityLabel("Time \(BestTime.format(game.seconds))")
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: size.width)

            ZStack {
                board(cell: cell)
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        MouseCatcher { point, isFlag in
                            guard let c = cellAt(point, cell: cell) else { return }
                            isFlag ? game.toggleFlag(c) : game.reveal(c)
                        } onHover: { point in
                            hovered = point.flatMap { cellAt($0, cell: cell) }
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Mines board, \(game.cols) by \(game.rows). \(game.minesLeft) mines left. Use arrow keys, Space to reveal, F to flag.")

                overlay.frame(width: size.width, height: size.height)
            }
        }
        .animation(.easeOut(duration: 0.2), value: game.state)
    }

    private func cellAt(_ point: CGPoint, cell: CGFloat) -> MinesGame.Cell? {
        let x = Int(point.x / cell), y = Int(point.y / cell)
        guard point.x >= 0, point.y >= 0, x < game.cols, y < game.rows else { return nil }
        return MinesGame.Cell(x: x, y: y)
    }

    private func board(cell: CGFloat) -> some View {
        // Read the state here (not inside Canvas) so SwiftUI redraws when it changes.
        let accent = settings.accent.color
        let revealed = game.revealed
        let flagged = game.flagged
        let mines = game.mines
        let exploded = game.exploded
        let isOver = game.state == .won || game.state == .lost
        let isLost = game.state == .lost
        let active = game.state == .ready || game.state == .playing
        let highlights = active ? Set([game.cursor, hovered].compactMap { $0 }) : []
        let cols = game.cols, rows = game.rows
        let counts = Dictionary(uniqueKeysWithValues: revealed.map { ($0, game.adjacentMines($0)) })

        return Canvas { context, _ in
            for y in 0..<rows {
                for x in 0..<cols {
                    let c = MinesGame.Cell(x: x, y: y)
                    let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).insetBy(dx: 1, dy: 1)
                    let tile = Path(roundedRect: rect, cornerRadius: cell * 0.18)
                    let center = CGPoint(x: rect.midX, y: rect.midY)

                    if revealed.contains(c) {
                        context.fill(tile, with: .color(Tokens.fill))
                        if let n = counts[c], n > 0 {
                            context.draw(Text("\(n)").font(.system(size: cell * 0.55, weight: .bold)).foregroundStyle(MinesColors.number(n)), at: center)
                        }
                    } else if isLost && mines.contains(c) {
                        context.fill(tile, with: .color(c == exploded ? Color.red : Tokens.fillHover))
                        if flagged.contains(c) {
                            Self.drawFlag(&context, at: center, cell: cell, color: .red)
                        } else {
                            Self.drawMine(&context, at: center, cell: cell, color: c == exploded ? .white : .primary)
                        }
                    } else {
                        context.fill(tile, with: .color(accent.opacity(highlights.contains(c) ? 0.42 : 0.26)))
                        if flagged.contains(c) {
                            Self.drawFlag(&context, at: center, cell: cell, color: .red)
                            if isLost { Self.drawCross(&context, at: center, cell: cell) } // a flag that wasn't on a mine
                        }
                    }
                    if !isOver, c == game.cursor {
                        context.stroke(tile, with: .color(accent), lineWidth: 2)
                    }
                }
            }
        }
    }

    private static func drawFlag(_ context: inout GraphicsContext, at center: CGPoint, cell: CGFloat, color: Color) {
        context.draw(Text(Image(systemName: "flag.fill")).font(.system(size: cell * 0.48)).foregroundStyle(color), at: center)
    }

    private static func drawMine(_ context: inout GraphicsContext, at center: CGPoint, cell: CGFloat, color: Color) {
        let r = cell * 0.2
        var spikes = Path()
        for i in 0..<4 {
            let angle = Double(i) * .pi / 4
            let dx = cos(angle) * r * 1.6, dy = sin(angle) * r * 1.6
            spikes.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
            spikes.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
        }
        context.stroke(spikes, with: .color(color), style: StrokeStyle(lineWidth: max(1.5, cell * 0.07), lineCap: .round))
        context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(color))
    }

    private static func drawCross(_ context: inout GraphicsContext, at center: CGPoint, cell: CGFloat) {
        let k = cell * 0.3
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - k, y: center.y - k)); cross.addLine(to: CGPoint(x: center.x + k, y: center.y + k))
        cross.move(to: CGPoint(x: center.x + k, y: center.y - k)); cross.addLine(to: CGPoint(x: center.x - k, y: center.y + k))
        context.stroke(cross, with: .color(.primary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    @ViewBuilder private var overlay: some View {
        switch game.state {
        case .paused:
            GameOverlay(title: "Paused", subtitle: "Time \(BestTime.format(game.seconds))") {
                Button("Resume") { game.togglePause() }.prominentButtonStyle()
            }
        case .won:
            GameOverlay(title: game.isNewBest ? "New best time!" : "Field cleared!",
                        subtitle: "\(game.difficulty.title) in \(BestTime.format(game.seconds))") {
                Button("New game") { game.newGame() }.prominentButtonStyle()
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: 150)
        case .lost:
            GameOverlay(title: "Boom", subtitle: "You hit a mine.") {
                Button("Try again") { game.newGame() }.prominentButtonStyle()
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: 150)
        case .ready, .playing:
            EmptyView()
        }
    }
}

/// The classic number colors, adjusted so each one reads well in light and dark mode.
private enum MinesColors {
    static func number(_ n: Int) -> Color {
        switch n {
        case 1: .dynamic(light: 0x1A6FD6, dark: 0x5AA9FF)
        case 2: .dynamic(light: 0x1E8E3E, dark: 0x4CD964)
        case 3: .dynamic(light: 0xD93025, dark: 0xFF6B6B)
        case 4: .dynamic(light: 0x6A1B9A, dark: 0xC792FF)
        case 5: .dynamic(light: 0xA0522D, dark: 0xFFA26B)
        case 6: .dynamic(light: 0x00838F, dark: 0x4DD0E1)
        case 7: .primary
        default: .secondary
        }
    }
}

/// Catches left clicks, right clicks (to flag) and hover over the board.
/// SwiftUI has no right-click gesture on macOS, so this is a small AppKit view.
/// Control-click and Option-click also flag, for trackpads without a secondary click.
private struct MouseCatcher: NSViewRepresentable {
    let onClick: (CGPoint, _ isFlag: Bool) -> Void
    let onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onClick = onClick
        view.onHover = onHover
    }

    final class CatcherView: NSView {
        var onClick: (CGPoint, Bool) -> Void = { _, _ in }
        var onHover: (CGPoint?) -> Void = { _ in }

        override var isFlipped: Bool { true } // top-left origin, like SwiftUI
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            onClick(convert(event.locationInWindow, from: nil), flags.contains(.control) || flags.contains(.option))
        }

        override func rightMouseDown(with event: NSEvent) {
            onClick(convert(event.locationInWindow, from: nil), true)
        }

        override func mouseMoved(with event: NSEvent) { onHover(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { onHover(nil) }
    }
}

/// Header dropdown: difficulty and new game.
struct MinesHeaderMenu: View {
    let game: MinesGame

    var body: some View {
        Menu {
            Picker("Difficulty", selection: Binding(get: { game.difficulty }, set: { game.difficulty = $0 })) {
                ForEach(MinesGame.Difficulty.allCases) { d in
                    Text("\(d.title) (\(d.cols)×\(d.rows), \(d.mines) mines)").tag(d)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("New game") { game.newGame() }
        } label: {
            Text(bestLabel)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .headerMenuStyle()
        .foregroundStyle(.secondary)
        .help("Difficulty and new game")
        .accessibilityLabel("Difficulty: \(game.difficulty.title)")
    }

    private var bestLabel: String {
        // Read `isNewBest` so the label refreshes after a win.
        _ = game.isNewBest
        let best = BestTime.get(game.difficulty.bestKey)
        return best > 0 ? "\(game.difficulty.title) · best \(BestTime.format(best))" : game.difficulty.title
    }
}
