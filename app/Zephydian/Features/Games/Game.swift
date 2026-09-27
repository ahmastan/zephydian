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

/// A game's tile icon: an SF Symbol, or a custom drawing when no symbol fits the game.
enum GameIcon {
    case symbol(String)
    /// A falling T-piece above a stack of blocks (Stackr).
    case fallingBlocks
    /// A 2×2 grid of number tiles in rising shades (2048).
    case mergeTiles
}

struct GameInfo: Identifiable {
    let id: String
    let name: String
    let icon: GameIcon
    /// nil = not built yet (tile shows "Coming soon").
    let makeSession: (() -> any GameSession)?
    /// Short line under the tile name, e.g. "Best 42".
    let stat: () -> String
}

/// Every game in Zephydian. Adding a game = one folder under Features/Games + one line here.
enum GameRegistry {
    static let all: [GameInfo] = [
        GameInfo(id: "snake", name: "Snake", icon: .symbol("point.bottomleft.forward.to.point.topright.scurvepath"),
                 makeSession: { SnakeGame() }, stat: { BestScore.label(for: SnakeGame.bestKey) }),
        GameInfo(id: "stackr", name: "Stackr", icon: .fallingBlocks,
                 makeSession: { StackrGame() }, stat: { BestScore.label(for: StackrGame.bestKey) }),
        GameInfo(id: "five", name: "Five", icon: .symbol("textformat.abc"),
                 makeSession: { FiveGame() }, stat: { FiveGame.tileStat() }),
        GameInfo(id: "wheel", name: "Spokes", icon: .symbol("circle.hexagongrid.fill"),
                 makeSession: { SpokesGame() }, stat: { "Level \(SpokesGame.savedLevel)" }),
        GameInfo(id: "fleet", name: "Fleet", icon: .symbol("sailboat.fill"),
                 makeSession: { FleetGame() }, stat: { FleetGame.tileStat }),
        GameInfo(id: "airship", name: "Airship", icon: .symbol("airplane"),
                 makeSession: { AirshipGame() }, stat: { BestScore.label(for: AirshipGame.bestKey) }),
        GameInfo(id: "2048", name: "2048", icon: .mergeTiles,
                 makeSession: { Game2048() }, stat: { BestScore.label(for: Game2048.bestKey) }),
        GameInfo(id: "mines", name: "Mines", icon: .symbol("flag.fill"),
                 makeSession: { MinesGame() }, stat: { MinesGame.tileStat }),
        GameInfo(id: "nines", name: "Nines", icon: .symbol("9.square.fill"),
                 makeSession: { NinesGame() }, stat: { NinesGame.tileStat }),
    ]

    static func info(for id: String?) -> GameInfo? { all.first { $0.id == id } }
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

/// The dimmed card shown over a game when it's ready, paused or over.
struct GameOverlay<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.opacity)
    }
}

/// A short message bubble at the top of a game ("Not in word list", "Bonus word!"…).
/// Dark bubble with light text in light mode, and the reverse in dark mode.
struct GameToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color(nsColor: .labelColor)))
            .padding(.top, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityAddTraits(.isStaticText)
            .onAppear { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]) }
    }
}
