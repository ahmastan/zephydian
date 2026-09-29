import AppKit
import SwiftUI

// MARK: - The game contract

/// One running game. The panel's header, pause button and keyboard all talk
/// to games through this protocol, so adding a game never touches the rest of the app.
protocol GameSession: AnyObject {
    /// Shown at the top right of the game screen, e.g. "12 · best 42".
    var scoreText: String { get }
    /// Controls hint shown under the game.
    var hint: String { get }
    var showsPauseButton: Bool { get }
    /// True while the game is actively running (its timer is ticking).
    var isRunning: Bool { get }

    func pause()
    func togglePause()
    /// Return true if the key was used by the game.
    func handleKey(_ event: NSEvent) -> Bool
    func makeView() -> AnyView
    /// Optional control shown in the header instead of the score text (e.g. Five's mode menu).
    func makeHeaderAccessory() -> AnyView?
    /// Key released. Only real-time games that track held keys need this.
    func handleKeyUp(_ event: NSEvent) -> Bool
    /// ⌘Z. Return true if a move was undone.
    func undo() -> Bool
}

extension GameSession {
    func makeHeaderAccessory() -> AnyView? { nil }
    func handleKeyUp(_ event: NSEvent) -> Bool { false }
    func undo() -> Bool { false }
}

// MARK: - Registry

/// A game's tile icon: a custom drawing in the accent color (see `GameIconView`), or an SF Symbol.
enum GameIcon {
    case symbol(String)
    /// A snake winding toward a piece of food (Snake).
    case snake
    /// A falling T-piece above a stack of blocks (Stackr).
    case fallingBlocks
    /// Rows of letter tiles in three shades, the last row solved (Five).
    case letterRows
    /// Letters around a wheel, three of them joined by a swipe (Spokes).
    case wheel
    /// Two ships on a sea grid, plus a miss (Fleet).
    case ships
    /// A jet firing upward (Airship).
    case jet
    /// A 2×2 grid of number tiles in rising shades (2048).
    case mergeTiles
    /// Covered and revealed tiles with a flag (Mines).
    case minefield
    /// A 3×3 box with a few givens and a 9 (Nines).
    case numberGrid
    /// A pack's own icon.png, drawn as a template in the accent color.
    case image(NSImage)
}

struct GameInfo: Identifiable {
    let id: String
    let name: String
    let icon: GameIcon
    /// nil = not built yet (tile shows "Coming soon").
    let makeSession: (() -> any GameSession)?
    /// Short line under the tile name, e.g. "Best 42".
    let stat: () -> String
    /// One line for the Library.
    var summary = ""
    /// A small label on the tile's corner, e.g. "DEV" for a developer pack.
    var badge: String? = nil
    /// Start a fresh session every time the tile is opened (developer packs, so edits show up).
    var reloadsOnOpen = false
}

/// Every game in Zephydian: the built-in ones, then packs. New games are packs (see docs/PACKS.md).
enum GameRegistry {
    /// The Games grid: installed built-in games, then packs. A pack with a built-in game's id takes
    /// that game's place.
    static var all: [GameInfo] {
        let packs = PackLibrary.shared.games
        let installed = InstalledGames.shared
        return builtIn.compactMap { info in packs.first { $0.id == info.id } ?? (installed.contains(info.id) ? info : nil) }
            + packs.filter { pack in !builtIn.contains { $0.id == pack.id } }
    }

    static let builtIn: [GameInfo] = [
        GameInfo(id: "snake", name: "Snake", icon: .snake,
                 makeSession: { SnakeGame() }, stat: { BestScore.label(for: SnakeGame.bestKey) }, summary: "Eat, grow, and don't run into yourself."),
        GameInfo(id: "stackr", name: "Stackr", icon: .fallingBlocks,
                 makeSession: { StackrGame() }, stat: { BestScore.label(for: StackrGame.bestKey) }, summary: "Stack falling blocks and clear full rows."),
        GameInfo(id: "five", name: "Five", icon: .letterRows,
                 makeSession: { FiveGame() }, stat: { FiveGame.tileStat() }, summary: "Guess the five-letter word in six tries."),
        GameInfo(id: "wheel", name: "Spokes", icon: .wheel,
                 makeSession: { SpokesGame() }, stat: { "Level \(SpokesGame.savedLevel)" }, summary: "Make words from the letters around a wheel."),
        GameInfo(id: "fleet", name: "Fleet", icon: .ships,
                 makeSession: { FleetGame() }, stat: { FleetGame.tileStat }, summary: "Find and sink the computer's hidden ships."),
        GameInfo(id: "airship", name: "Airship", icon: .jet,
                 makeSession: { AirshipGame() }, stat: { BestScore.label(for: AirshipGame.bestKey) }, summary: "Fly, dodge and shoot through an endless sky."),
        GameInfo(id: "2048", name: "2048", icon: .mergeTiles,
                 makeSession: { Game2048() }, stat: { BestScore.label(for: Game2048.bestKey) }, summary: "Slide and merge tiles to reach 2048."),
        GameInfo(id: "mines", name: "Mines", icon: .minefield,
                 makeSession: { MinesGame() }, stat: { MinesGame.tileStat }, summary: "Clear the board without setting off a mine."),
        GameInfo(id: "nines", name: "Nines", icon: .numberGrid,
                 makeSession: { NinesGame() }, stat: { NinesGame.tileStat }, summary: "Fill the grid with 1 to 9, no repeats."),
    ]

    /// Any tile the panel can open: a game, or a utility.
    static func info(for id: String?) -> GameInfo? { (all + UtilityRegistry.all).first { $0.id == id } }
}

/// Every installed utility (all of them are packs; none come preinstalled).
enum UtilityRegistry {
    static var all: [GameInfo] { PackLibrary.shared.utilities }
}

// MARK: - Shared helpers

/// A repeating timer that only exists while a game is running. Stopped = zero CPU.
final class GameLoop {
    var interval: Duration
    var isRunning: Bool { task != nil }
    private let tick: () -> Void
    private var task: Task<Void, Never>?

    init(interval: Duration, tick: @escaping () -> Void) {
        self.interval = interval
        self.tick = tick
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// High scores, saved in UserDefaults.
enum BestScore {
    static func get(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }
    static func set(_ value: Int, for key: String) { UserDefaults.standard.set(value, forKey: key) }
    static func label(for key: String) -> String {
        let best = get(key)
        return best > 0 ? "Best \(best.formatted())" : "Not played"
    }
}

/// Best (lowest) times in seconds, saved in UserDefaults. 0 = no time yet.
enum BestTime {
    static func get(_ key: String) -> Int { UserDefaults.standard.integer(forKey: key) }

    /// Saves `seconds` if it beats the stored time. Returns true if it's a new best.
    static func record(_ seconds: Int, for key: String) -> Bool {
        let best = get(key)
        guard best == 0 || seconds < best else { return false }
        UserDefaults.standard.set(seconds, forKey: key)
        return true
    }

    /// "1:05", or "1:02:05" past an hour.
    static func format(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Key codes for keys that games use (layout-independent).
enum Key {
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    static let space: UInt16 = 49, enter: UInt16 = 36, keypadEnter: UInt16 = 76
    static let w: UInt16 = 13, a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
    static let delete: UInt16 = 51, forwardDelete: UInt16 = 117

    /// The typed letter, lowercased (for letter shortcuts like R, P, C).
    static func letter(_ event: NSEvent) -> String? { event.charactersIgnoringModifiers?.lowercased() }
}

/// The card shown over a game when it's ready, paused or over: a floating glass card over a light
/// dim in Liquid Glass mode, a frosted cover over the whole board in Frosted mode.
struct GameOverlay<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions

    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if #available(macOS 26, *), settings.usesGlass {
            card
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: 300)
                .glassSurface(in: RoundedRectangle(cornerRadius: Tokens.overlayRadius, style: .continuous))
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.18)))
                .transition(.opacity)
        } else {
            card
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
        }
    }

    private var card: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 20, weight: .bold))
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 10) { actions }
                .controlSize(.large)
                .padding(.top, 8)
        }
        .padding(16)
    }
}

/// A short message bubble at the top of a game ("Not in word list", "Bonus word!"…).
/// A glass capsule in Liquid Glass mode. In Frosted mode, a dark bubble with light text in light
/// mode, and the reverse in dark mode.
struct GameToast: View {
    let text: String

    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(settings.usesGlass ? Color.primary : Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassSurface(in: Capsule(), fallback: Color(nsColor: .labelColor))
            .padding(.top, 4)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            .accessibilityAddTraits(.isStaticText)
            .onAppear { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]) }
    }
}
