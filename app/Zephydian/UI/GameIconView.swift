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
            case .fallingBlocks:
                FallingBlocksIcon()
            case .mergeTiles:
                MergeTilesIcon()
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
