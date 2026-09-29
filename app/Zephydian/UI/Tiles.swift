import SwiftUI

/// A game or utility tile: its icon, name and a short stat line (a best score, "On · 1h left").
struct GameTile: View {
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

/// The last tile of the Games and Utilities tabs: opens the Library, where more are installed.
struct GetMoreTile: View {
    let accessibilityLabel: String
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
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Game tiles are content, not controls, so they stay solid cards (no glass). They brighten and
/// lift slightly on hover, and press in when clicked.
struct TileButtonStyle: ButtonStyle {
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
