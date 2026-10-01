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

/// The row above the Games and Utilities grids: how many there are, and glass buttons on the right
/// (Stats, Get more). The buttons are the control layer; the tiles below stay content.
struct GridToolbar<Buttons: View>: View {
    let count: Int
    let noun: String
    var plural: String?
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        HStack(spacing: 8) {
            Text(count == 1 ? "1 \(noun)" : "\(count) \(plural ?? noun + "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            GlassGroup(spacing: 6) {
                HStack(spacing: 6) { buttons() }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// A small capsule button with an icon and a word, for `GridToolbar`.
struct GridToolbarButton: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .labelStyle(.titleAndIcon)
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .help(help)
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
