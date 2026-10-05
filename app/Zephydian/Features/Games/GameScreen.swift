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
                    }
                    .glassIconButtonStyle()
                    .help("Back to \(model.backDestination) (Esc)")
                    .accessibilityLabel("Back to \(model.backDestination)")

                    Text(info.name).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    // The menu and pause button are both glass controls, so they share one glass group.
                    GlassGroup(spacing: 6) {
                        HStack(spacing: 6) {
                            if let accessory = session.makeHeaderAccessory() {
                                accessory
                            } else {
                                Text(session.scoreText)
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Score: \(session.scoreText)")
                            }

                            // A utility with a settings page (SDK 5): the gear opens it in the Settings window.
                            if let pack = (session as? PackSession)?.bundle, pack.hasSettings {
                                Button { model.openSettingsWindow(SettingsSelection.utility(pack.id).rawValue) } label: {
                                    Image(systemName: "gearshape")
                                }
                                .glassIconButtonStyle()
                                .help("\(pack.manifest.name) settings")
                                .accessibilityLabel("\(pack.manifest.name) settings")
                            }

                            if session.showsPauseButton {
                                Button { session.togglePause() } label: {
                                    Image(systemName: session.isRunning ? "pause.fill" : "play.fill")
                                }
                                .glassIconButtonStyle()
                                .accessibilityLabel(session.isRunning ? "Pause" : "Resume")
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 44)

                session.makeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // A new session for the same game (a reloaded pack, opened again by its shortcut
                    // while still on screen) gets a new view, so it appears and starts.
                    .id(ObjectIdentifier(session))

                if !session.hint.isEmpty {
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
}
