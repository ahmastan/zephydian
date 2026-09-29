import SwiftUI

/// The Games tab: a 3-column grid of game tiles. Reopening a paused game's tile resumes it where you left off.
struct HomeGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(PackLibrary.self) private var packs

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(GameRegistry.all) { info in
                    GameTile(info: info) { model.openGame(info.id) }
                }
                GetMoreTile { model.openLibrary() }
            }

        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .contentMargins(.bottom, 16, for: .scrollContent)
        .onAppear { packs.refresh() }
        .onChange(of: model.panelOpenCount) { packs.refresh() }
    }
}

private struct GameTile: View {
    let info: GameInfo
    let open: () -> Void

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
            .overlay(alignment: .topTrailing) {
                if let badge = info.badge ?? (isPlayable ? nil : "SOON") {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Tokens.fillHover))
                        .padding(6)
                }
            }
            .opacity(isPlayable ? 1 : 0.6)
        }
        .buttonStyle(TileButtonStyle())
        .disabled(!isPlayable)
        .accessibilityLabel("\(info.name), \(info.stat())")
    }
}

/// The last tile: opens the Library, where more games are installed.
private struct GetMoreTile: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(spacing: 3) {
                GameIconView(icon: .symbol("plus"))
                    .padding(.bottom, 6)
                Text("Get more").font(.system(size: 12, weight: .medium))
                Text("Library").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(TileButtonStyle())
        .accessibilityLabel("Get more games from the Library")
    }
}

/// Game tiles are content, not controls, so they stay solid cards (no glass). They brighten and
/// lift slightly on hover, and press in when clicked.
private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration)
    }

    private struct Tile: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var scale: CGFloat {
            guard isEnabled, !reduceMotion else { return 1 }
            return configuration.isPressed ? 0.96 : hovering ? 1.03 : 1
        }

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous)
                        .fill(isEnabled && (hovering || configuration.isPressed) ? Tokens.fillHover : Tokens.fill)
                )
                .contentShape(RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
                .scaleEffect(scale)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: scale)
                .onHover { hovering = $0 }
        }
    }
}
