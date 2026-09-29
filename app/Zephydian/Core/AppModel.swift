import AppKit
import Foundation
import Observation

/// UI state shared between the panel's views and the controllers that drive it.
@Observable
final class AppModel {
    enum Tab: String, CaseIterable, Identifiable {
        case games, utilities, notes, settings
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

    /// True while the Library (the pack catalog) is showing. A game opened from it returns to it.
    private(set) var isShowingLibrary = false
    /// Bumped by ⌘F so the Library's search field takes the cursor.
    var librarySearchRequest = 0
    /// Arrow keys and Enter for the Library's rows (set by the Library while it's showing).
    @ObservationIgnored var libraryKeyHandler: ((NSEvent) -> Bool)?

    /// Which kind of pack the Library lists. Set by the tab that opened it.
    var libraryFilter: PackBundle.Kind = .game

    func openLibrary(_ filter: PackBundle.Kind = .game) {
        libraryFilter = filter
        isShowingLibrary = true
    }

    /// Where the back button of a game, utility or the Library goes, for its help text.
    var backDestination: String {
        if isShowingGame && isShowingLibrary { return "the Library" }
        return tab == .utilities ? "utilities" : "games"
    }
    func closeLibrary() { isShowingLibrary = false }

    /// Stops Smart auto-hide while a game is open.
    var isPlayingGame: Bool { isShowingGame }

    func openGame(_ id: String) {
        guard let info = GameRegistry.info(for: id), let make = info.makeSession else { return }
        let failedPack = (gameSession as? PackSession)?.hasFailed == true
        if gameID != id || gameSession == nil || info.reloadsOnOpen || failedPack {
            gameSession?.pause()
            if let old = gameID, old != id { gameDidClose(old) }
            gameSession = make()
            gameID = id
        }
        isShowingGame = true
    }

    func closeGame() {
        gameSession?.pause()
        isShowingGame = false
        if let gameID { gameDidClose(gameID) }
    }

    /// After a pack is installed, updated or removed, a paused pack game kept in the background is
    /// dropped, so reopening it loads the new files. Its progress is in its own storage.
    func discardHiddenPackSession() {
        guard !isShowingGame, gameSession is PackSession else { return }
        gameSession = nil
        gameID = nil
    }

    /// Drops the paused game kept in the background if it's the one being removed.
    func discardHiddenSession(for id: String) {
        guard !isShowingGame, gameID == id else { return }
        gameSession = nil
        gameID = nil
    }

    // Actions the views can trigger. Wired up by AppDelegate.
    @ObservationIgnored var closePanel: () -> Void = {}
    @ObservationIgnored var startOnboarding: () -> Void = {}
    @ObservationIgnored var finishOnboarding: () -> Void = {}
    /// A game was closed or replaced by another one (lets a waiting pack update install).
    @ObservationIgnored var gameDidClose: (String) -> Void = { _ in }

    init() {
        tab = UserDefaults.standard.string(forKey: "lastTab").flatMap(Tab.init(rawValue:)) ?? .games
    }
}
