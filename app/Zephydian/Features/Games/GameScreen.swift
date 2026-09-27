import SwiftUI

/// The shared game chrome: back · name · score · pause, the game, and a hint line.
struct GameScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.gameSession, let info = GameRegistry.info(for: model.gameID) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button { model.closeGame() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Back to games (Esc)")
                    .accessibilityLabel("Back to games")

                    Text(info.name).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if let accessory = session.makeHeaderAccessory() {
                        accessory
                    } else {
                        Text(session.scoreText)
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Score: \(session.scoreText)")
                    }

                    if session.showsPauseButton {
                        Button { session.togglePause() } label: {
                            Image(systemName: session.isRunning ? "pause.fill" : "play.fill")
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(session.isRunning ? "Pause" : "Resume")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 44)

                session.makeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(session.hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
            }
        }
    }
}
