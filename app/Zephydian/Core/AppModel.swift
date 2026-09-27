import Foundation
import Observation

/// UI state shared between the panel's views and the controllers that drive it.
@Observable
final class AppModel {
    enum Tab: String, CaseIterable, Identifiable {
        case games, notes, settings
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    /// The selected tab, remembered between launches.
    var tab: Tab { didSet { UserDefaults.standard.set(tab.rawValue, forKey: "lastTab") } }

    /// True while the first-launch welcome card is showing.
    var isOnboarding = false

    /// False if the chosen global shortcut is already taken by another app.
    var shortcutAvailable = true

    /// True while the notes editor (or a note's name) has the cursor. Stops Smart auto-hide.
    var isTypingNote = false

    /// True while a note tab's name is being edited (Esc cancels the rename instead of closing the panel).
    var isRenamingNote = false

    /// Increases every time the panel opens, so views can react (e.g. focus the notes editor).
    var panelOpenCount = 0

    // MARK: Games

    /// The live game. Kept when you go back to the grid, so a paused game can be continued.
    private(set) var gameSession: (any GameSession)?
    private(set) var gameID: String?
    /// True while the game screen is showing (instead of the tabs).
    private(set) var isShowingGame = false

    /// Stops Smart auto-hide while a game is open.
    var isPlayingGame: Bool { isShowingGame }

    func openGame(_ id: String) {
        guard let info = GameRegistry.info(for: id), let make = info.makeSession else { return }
        if gameID != id || gameSession == nil {
            gameSession?.pause()
            gameSession = make()
            gameID = id
        }
        isShowingGame = true
    }

    func closeGame() {
        gameSession?.pause()
        isShowingGame = false
    }

    // Actions the views can trigger. Wired up by AppDelegate.
    @ObservationIgnored var closePanel: () -> Void = {}
    @ObservationIgnored var startOnboarding: () -> Void = {}
    @ObservationIgnored var finishOnboarding: () -> Void = {}

    init() {
        tab = UserDefaults.standard.string(forKey: "lastTab").flatMap(Tab.init(rawValue:)) ?? .games
    }
}
