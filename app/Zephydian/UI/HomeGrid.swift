import SwiftUI

/// The Games tab: a 3-column grid of game tiles. Reopening a paused game's tile resumes it where you left off.
struct HomeGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(GameRegistry.all) { info in
                    GameTile(info: info) { model.openGame(info.id) }
                }
            }

        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .contentMargins(.bottom, 16, for: .scrollContent)
    }
}

private struct GameTile: View {
    let info: GameInfo
    let open: () -> Void
    @State private var hovering = false

    private var isPlayable: Bool { info.makeSession != nil }

    var body: some View {
        Button(action: open) {
            VStack(spacing: 3) {
                GameIconView(icon: info.icon)
                    .padding(.bottom, 6)
                Text(info.name).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(info.stat()).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(
                RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous)
                    .fill(hovering && isPlayable ? Tokens.fillHover : Tokens.fill)
            )
            .overlay(alignment: .topTrailing) {
                if !isPlayable {
                    Text("SOON")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Tokens.fillHover))
                        .padding(6)
                }
            }
            .opacity(isPlayable ? 1 : 0.6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isPlayable)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(info.name), \(info.stat())")
    }
}
