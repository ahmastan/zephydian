import SwiftUI

struct StackrView: View {
    let game: StackrGame

    private static let cell: CGFloat = 19

    var body: some View {
        let cell = Self.cell
        let boardSize = CGSize(width: CGFloat(StackrGame.cols) * cell, height: CGFloat(StackrGame.rows) * cell)
        // Read state here so SwiftUI redraws when it changes.
        let board = game.board
        let current = game.current
        let ghost = game.ghost
        let clearing = game.clearingRows

        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Canvas { context, size in
                    context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Tokens.fill))
                    for (y, row) in board.enumerated() {
                        for (x, kind) in row.enumerated() {
                            if clearing.contains(y) {
                                Self.drawBlock(in: &context, x: x, y: y, cell: cell, color: .white.opacity(0.9))
                            } else if let kind {
                                Self.drawBlock(in: &context, x: x, y: y, cell: cell, color: kind.color)
                            }
                        }
                    }
                    if let ghost, let current {
                        for c in ghost.cells where c.y >= 0 {
                            Self.drawBlock(in: &context, x: c.x, y: c.y, cell: cell, color: current.kind.color.opacity(0.25))
                        }
                    }
                    if let current {
                        for c in current.cells where c.y >= 0 {
                            Self.drawBlock(in: &context, x: c.x, y: c.y, cell: cell, color: current.kind.color)
                        }
                    }
                }
                .frame(width: boardSize.width, height: boardSize.height)
                .accessibilityLabel("Stackr board, score \(game.score)")

                overlay.frame(width: boardSize.width, height: boardSize.height)
            }

            VStack(alignment: .leading, spacing: 14) {
                preview(title: "Next", kind: game.next, dimmed: false)
                preview(title: "Hold", kind: game.hold, dimmed: !game.canHold)
                stat("Score", game.score.formatted())
                stat("Lines", "\(game.lines)")
                stat("Level", "\(game.level)")
            }
            .frame(width: 72)
        }
        .animation(.easeOut(duration: 0.15), value: game.state)
    }

    @ViewBuilder private var overlay: some View {
        switch game.state {
        case .ready:
            GameOverlay(title: "Stackr", subtitle: "Press Space or an arrow key to start") {
                Button("Start") { game.start() }.prominentButtonStyle()
            }
        case .paused:
            GameOverlay(title: "Paused", subtitle: "Score \(game.score.formatted())") {
                Button("Resume") { game.start() }.prominentButtonStyle()
                Button("Restart") { game.reset(); game.start() }
            }
        case .over:
            GameOverlay(title: game.isNewBest ? "New best!" : "Game over",
                        subtitle: "Score \(game.score.formatted()) · \(game.lines) lines") {
                Button("Play again") { game.start() }.prominentButtonStyle()
            }
        case .running:
            EmptyView()
        }
    }

    private func preview(title: String, kind: StackrGame.Kind?, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Canvas { context, size in
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Tokens.fill))
                guard let kind else { return }
                let cells = StackrGame.shapes[kind]![0]
                let mini: CGFloat = 13
                let w = CGFloat((cells.map(\.x).max() ?? 0) + 1) * mini
                let minY = cells.map(\.y).min() ?? 0
                let h = CGFloat((cells.map(\.y).max() ?? 0) - minY + 1) * mini
                let origin = CGPoint(x: (size.width - w) / 2, y: (size.height - h) / 2)
                for c in cells {
                    let rect = CGRect(x: origin.x + CGFloat(c.x) * mini + 1, y: origin.y + CGFloat(c.y - minY) * mini + 1,
                                      width: mini - 2, height: mini - 2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(kind.color.opacity(dimmed ? 0.35 : 1)))
                }
            }
            .frame(width: 72, height: 48)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(kind.map { "\($0)".uppercased() } ?? "empty")")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private static func drawBlock(in context: inout GraphicsContext, x: Int, y: Int, cell: CGFloat, color: Color) {
        let rect = CGRect(x: CGFloat(x) * cell + 1, y: CGFloat(y) * cell + 1, width: cell - 2, height: cell - 2)
        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color))
    }
}

extension StackrGame.Kind {
    /// Piece colors: Apple's system colors.
    var color: Color {
        switch self {
        case .i: .cyan
        case .o: .yellow
        case .t: .purple
        case .s: .green
        case .z: .red
        case .j: .blue
        case .l: .orange
        }
    }
}
