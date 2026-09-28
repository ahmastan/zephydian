import SwiftUI

/// Draws a game's tile icon inside a fixed square, so every icon is the same size and centered
/// (SF Symbols have different natural widths, e.g. "Abc" is much wider than "airplane").
struct GameIconView: View {
    let icon: GameIcon
    var size: CGFloat = 30

    var body: some View {
        Group {
            switch icon {
            case .symbol(let name):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
            case .snake: SnakeIcon()
            case .fallingBlocks: FallingBlocksIcon()
            case .letterRows: LetterRowsIcon()
            case .wheel: WheelIcon()
            case .ships: ShipsIcon()
            case .jet: JetIcon()
            case .mergeTiles: MergeTilesIcon()
            case .minefield: MinefieldIcon()
            case .numberGrid: NumberGridIcon()
            }
        }
        .foregroundStyle(.tint)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Stackr's icon: a T-piece dropping toward a stack with a gap it's about to fill.
private struct FallingBlocksIcon: View {
    // 4×4 grid, (column, row) with row 0 at the top.
    private static let piece = [(1, 0), (0, 1), (1, 1), (2, 1)]
    private static let stack = [(3, 1), (0, 2), (3, 2), (0, 3), (1, 3), (2, 3), (3, 3)]

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = size.width * 0.06
            let cell = (size.width - gap * 3) / 4
            func block(_ c: (Int, Int)) -> Path {
                let rect = CGRect(x: CGFloat(c.0) * (cell + gap), y: CGFloat(c.1) * (cell + gap), width: cell, height: cell)
                return Path(roundedRect: rect, cornerRadius: cell * 0.22)
            }
            for c in Self.stack { context.fill(block(c), with: .style(.tint.opacity(0.45))) }
            for c in Self.piece { context.fill(block(c), with: .style(.tint)) }
        }
    }
}

/// 2048's icon: four tiles, each a shade stronger, like numbers growing as they merge.
private struct MergeTilesIcon: View {
    private static let opacities: [Double] = [0.3, 0.55, 0.75, 1]

    var body: some View {
        Canvas { context, size in
            let gap = size.width * 0.12
            let cell = (size.width - gap) / 2
            for (i, opacity) in Self.opacities.enumerated() {
                let rect = CGRect(x: CGFloat(i % 2) * (cell + gap), y: CGFloat(i / 2) * (cell + gap), width: cell, height: cell)
                context.fill(Path(roundedRect: rect, cornerRadius: cell * 0.22), with: .style(.tint.opacity(opacity)))
            }
        }
    }
}

// MARK: - Shared grid

/// The rounded cells of a square grid that fills the icon, like Stackr's and 2048's tiles.
private struct IconGrid {
    let size: CGSize
    let columns: Int
    var rows: Int? = nil
    var gapRatio: CGFloat = 0.06

    var gap: CGFloat { size.width * gapRatio }
    var cell: CGFloat { (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns) }
    /// Grids with fewer rows than columns are centered vertically.
    private var top: CGFloat {
        let rows = CGFloat(rows ?? columns)
        return (size.height - (rows * cell + (rows - 1) * gap)) / 2
    }

    func rect(_ column: Int, _ row: Int) -> CGRect {
        CGRect(x: CGFloat(column) * (cell + gap), y: top + CGFloat(row) * (cell + gap), width: cell, height: cell)
    }

    func tile(_ column: Int, _ row: Int) -> Path {
        Path(roundedRect: rect(column, row), cornerRadius: cell * 0.22)
    }
}

// MARK: - Game icons

/// Snake's icon: a snake bending around the grid, fading toward its tail, heading for the food.
private struct SnakeIcon: View {
    // Tail to head, on a 4×4 grid.
    private static let body = [(0, 3), (1, 3), (2, 3), (3, 3), (3, 2), (3, 1), (2, 1)]

    var body: some View {
        Canvas { context, size in
            let grid = IconGrid(size: size, columns: 4)
            for (i, c) in Self.body.enumerated() {
                let opacity = 0.3 + 0.7 * Double(i) / Double(Self.body.count - 1)
                context.fill(grid.tile(c.0, c.1), with: .style(.tint.opacity(opacity)))
            }
            let food = grid.rect(0, 1).insetBy(dx: grid.cell * 0.2, dy: grid.cell * 0.2)
            context.fill(Path(ellipseIn: food), with: .style(.tint))
        }
    }
}

/// Five's icon: four rows of five letter tiles, each guess closer, the last one solved.
private struct LetterRowsIcon: View {
    // 0.3 = not in the word, 0.6 = wrong spot, 1 = right spot.
    private static let rows: [[Double]] = [
        [0.3, 0.6, 0.3, 0.3, 0.6],
        [0.6, 1, 0.3, 1, 0.3],
        [1, 1, 0.6, 1, 1],
        [1, 1, 1, 1, 1],
    ]

    var body: some View {
        Canvas { context, size in
            let grid = IconGrid(size: size, columns: 5, rows: Self.rows.count, gapRatio: 0.07)
            for (r, row) in Self.rows.enumerated() {
                for (c, opacity) in row.enumerated() {
                    context.fill(grid.tile(c, r), with: .style(.tint.opacity(opacity)))
                }
            }
        }
    }
}

/// Spokes' icon: six letters around a wheel, three of them joined by a swipe.
private struct WheelIcon: View {
    private static let path = [5, 0, 2]

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let center = CGPoint(x: w / 2, y: size.height / 2)
            context.fill(Path(ellipseIn: CGRect(x: 0, y: center.y - w / 2, width: w, height: w)),
                         with: .style(.tint.opacity(0.2)))

            func point(_ i: Int) -> CGPoint {
                let angle = (-90 + Double(i) * 60) * .pi / 180
                return CGPoint(x: center.x + w * 0.31 * cos(angle), y: center.y + w * 0.31 * sin(angle))
            }
            var swipe = Path()
            swipe.addLines(Self.path.map(point))
            context.stroke(swipe, with: .style(.tint),
                           style: StrokeStyle(lineWidth: w * 0.07, lineCap: .round, lineJoin: .round))

            let r = w * 0.085
            for i in 0..<6 {
                let p = point(i)
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .style(.tint.opacity(Self.path.contains(i) ? 1 : 0.55)))
            }
        }
    }
}

/// Fleet's icon: a sea grid with two ships and a missed shot.
private struct ShipsIcon: View {
    var body: some View {
        Canvas { context, size in
            let grid = IconGrid(size: size, columns: 4)
            for r in 0..<4 {
                for c in 0..<4 { context.fill(grid.tile(c, r), with: .style(.tint.opacity(0.18))) }
            }
            // A 3-long ship across and a 2-long ship down, drawn as capsules over their cells.
            let long = grid.rect(0, 1).union(grid.rect(2, 1)).insetBy(dx: grid.cell * 0.08, dy: grid.cell * 0.08)
            context.fill(Path(roundedRect: long, cornerRadius: long.height / 2), with: .style(.tint))
            let short = grid.rect(3, 2).union(grid.rect(3, 3)).insetBy(dx: grid.cell * 0.08, dy: grid.cell * 0.08)
            context.fill(Path(roundedRect: short, cornerRadius: short.width / 2), with: .style(.tint.opacity(0.6)))
            let miss = grid.rect(1, 3).insetBy(dx: grid.cell * 0.32, dy: grid.cell * 0.32)
            context.fill(Path(ellipseIn: miss), with: .style(.tint.opacity(0.6)))
        }
    }
}

/// Airship's icon: a jet flying up with two shots ahead of it.
private struct JetIcon: View {
    // The right half of the jet in a 1×1 box (nose at the top); the left half is mirrored.
    private static let half: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.3), CGPoint(x: 0.57, y: 0.44), CGPoint(x: 0.57, y: 0.6),
        CGPoint(x: 0.92, y: 0.8), CGPoint(x: 0.92, y: 0.9), CGPoint(x: 0.57, y: 0.8),
        CGPoint(x: 0.57, y: 0.9), CGPoint(x: 0.7, y: 0.98), CGPoint(x: 0.7, y: 1),
        CGPoint(x: 0.5, y: 0.97),
    ]

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let right = Self.half.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            let left = right.reversed().dropFirst().dropLast().map { CGPoint(x: w - $0.x, y: $0.y) }
            var jet = Path()
            jet.addLines(right + left)
            jet.closeSubpath()
            context.fill(jet, with: .style(.tint))

            for (y, opacity) in [(0.0, 0.45), (0.14, 0.75)] {
                let shot = CGRect(x: w * 0.45, y: h * y, width: w * 0.1, height: h * 0.11)
                context.fill(Path(roundedRect: shot, cornerRadius: w * 0.05), with: .style(.tint.opacity(opacity)))
            }
        }
    }
}

/// Mines' icon: covered and revealed tiles, with a flag planted on one.
private struct MinefieldIcon: View {
    // true = still covered, on a 3×3 grid.
    private static let covered = [[true, true, false], [false, false, true], [false, false, true]]
    private static let flag = (2, 0)

    var body: some View {
        Canvas { context, size in
            let grid = IconGrid(size: size, columns: 3, gapRatio: 0.08)
            for (r, row) in Self.covered.enumerated() {
                for (c, isCovered) in row.enumerated() where (c, r) != Self.flag {
                    context.fill(grid.tile(c, r), with: .style(.tint.opacity(isCovered ? 0.6 : 0.18)))
                }
            }
            let cell = grid.rect(Self.flag.0, Self.flag.1)
            context.fill(Path(roundedRect: cell, cornerRadius: grid.cell * 0.22), with: .style(.tint.opacity(0.18)))
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: cell.minX + x * cell.width, y: cell.minY + y * cell.height) }
            var pole = Path()
            pole.move(to: p(0.38, 0.2))
            pole.addLine(to: p(0.38, 0.82))
            context.stroke(pole, with: .style(.tint), style: StrokeStyle(lineWidth: cell.width * 0.1, lineCap: .round))
            var banner = Path()
            banner.addLines([p(0.38, 0.18), p(0.8, 0.36), p(0.38, 0.54)])
            banner.closeSubpath()
            context.fill(banner, with: .style(.tint))
        }
    }
}

/// Nines' icon: a 3×3 box with a few given numbers and a 9 in the middle.
private struct NumberGridIcon: View {
    private static let givens = [(1, 0), (0, 1), (2, 1), (1, 2)]

    var body: some View {
        Canvas { context, size in
            let grid = IconGrid(size: size, columns: 3, gapRatio: 0.08)
            for r in 0..<3 {
                for c in 0..<3 {
                    let given = Self.givens.contains { $0 == (c, r) }
                    context.fill(grid.tile(c, r), with: .style(.tint.opacity(given ? 0.55 : 0.18)))
                }
            }
            let nine = Text("9").font(.system(size: grid.cell * 0.85, weight: .bold, design: .rounded)).foregroundStyle(.tint)
            let center = grid.rect(1, 1)
            context.draw(nine, at: CGPoint(x: center.midX, y: center.midY))
        }
    }
}
