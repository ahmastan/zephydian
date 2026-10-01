import SwiftUI

/// Stats for the built-in games, opened from the Games grid's Stats tile. The cards are content
/// (no glass); only the header's back button is a glass control.
struct StatsView: View {
    @Environment(AppModel.self) private var model

    /// Bumped after a reset, so the figures are read again.
    @State private var revision = 0
    @State private var resetting: ResetTarget?

    private enum ResetTarget: Identifiable {
        case game(GameInfo)
        case all
        var id: String { if case .game(let info) = self { info.id } else { "all" } }
        var title: String { if case .game(let info) = self { "Reset \(info.name) stats?" } else { "Reset all stats?" } }
    }

    var body: some View {
        let games = shownGames
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    summary(games)
                    ForEach(games) { card(for: $0) }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .id(revision)
            }
        }
        .alert(resetting?.title ?? "", isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }),
               presenting: resetting) { target in
            Button("Reset", role: .destructive) { reset(target) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Games played, wins, streaks, best scores and best times go back to zero. Games in progress are kept.")
        }
    }

    /// The built-in games you have, plus any you removed that still have stats.
    private var shownGames: [GameInfo] {
        let installed = Set(GameRegistry.all.map(\.id))
        return GameStats.gameIDs.compactMap { id in
            guard let info = GameRegistry.builtIn.first(where: { $0.id == id }) else { return nil }
            return installed.contains(id) || GameStats.record(id).played > 0 ? info : nil
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { model.closeStats() } label: { Image(systemName: "chevron.left") }
                .glassIconButtonStyle()
                .help("Back to games (Esc)")
                .accessibilityLabel("Back to games")
            Text("Stats").font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    // MARK: Cards

    private func summary(_ games: [GameInfo]) -> some View {
        let records = games.map { GameStats.record($0.id) }
        let played = records.map(\.played).reduce(0, +)
        let won = records.map(\.won).reduce(0, +)
        let longest = records.map(\.longestStreak).max() ?? 0
        return card {
            figures([
                ("Games played", played.formatted()),
                ("Wins", won.formatted()),
                ("Longest streak", days(longest)),
            ])
        }
        .accessibilityElement(children: .combine)
    }

    private func card(for info: GameInfo) -> some View {
        let record = GameStats.record(info.id)
        return card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    GameIconView(icon: info.icon)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                    Text(info.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Reset…") { resetting = .game(info) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .disabled(record == GameStats.Record() && !hasBest(info.id))
                        .accessibilityLabel("Reset \(info.name) stats")
                }
                figures(Self.figures(for: info.id, record: record))
                if let extra = Self.extraLine(for: info.id, record: record) {
                    Text(extra)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button("Reset All Stats…", role: .destructive) { resetting = .all }
            Text("Each game counts from this version on. Five and Fleet include the wins they had counted before.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 6)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous).fill(Tokens.fill))
    }

    /// Labels over values, side by side.
    private func figures(_ items: [(String, String)]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(items, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(value)
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Figures per game

    /// What each game shows: played and wins where a game has a win, scores for the endless ones.
    static func figures(for id: String, record: GameStats.Record) -> [(String, String)] {
        let streak = ("Streak", days(record.currentStreak()))
        let played = ("Played", record.played.formatted())
        switch id {
        case "snake", "stackr", "airship":
            let best = BestScore.get(bestKey(id) ?? "")
            return [played, ("Best", best > 0 ? best.formatted() : "–"), ("Average", record.average?.formatted() ?? "–"), streak]
        case "2048":
            let best = BestScore.get(Game2048.bestKey)
            return [played, ("Reached 2048", record.won.formatted()), ("Best", best > 0 ? best.formatted() : "–"), streak]
        case "wheel":
            return [("Levels played", record.played.formatted()), ("Finished", record.won.formatted()),
                    ("Level", "\(SpokesGame.savedLevel)"), streak]
        default: // five, fleet, mines, nines
            return [played, ("Won", record.won.formatted()), ("Win rate", record.winRate.map { "\($0)%" } ?? "–"), streak]
        }
    }

    /// A line under the figures: best times, and the longest streak.
    static func extraLine(for id: String, record: GameStats.Record) -> String? {
        var parts: [String] = []
        let times: [(String, String)] = switch id {
        case "mines": MinesGame.Difficulty.allCases.map { ($0.title, $0.bestKey) }
        case "nines": NinesGame.Difficulty.allCases.map { ($0.title, $0.bestKey) }
        default: []
        }
        if !times.isEmpty {
            let shown = times.map { title, key in
                let best = BestTime.get(key)
                return "\(title) \(best > 0 ? BestTime.format(best) : "–")"
            }
            parts.append("Best times: " + shown.joined(separator: " · "))
        }
        if record.longestStreak > 1 { parts.append("Longest streak: \(days(record.longestStreak))") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func bestKey(_ id: String) -> String? {
        switch id {
        case "snake": SnakeGame.bestKey
        case "stackr": StackrGame.bestKey
        case "airship": AirshipGame.bestKey
        case "2048": Game2048.bestKey
        default: nil
        }
    }

    private static func days(_ count: Int) -> String {
        count == 0 ? "–" : "\(count) day\(count == 1 ? "" : "s")"
    }

    private func days(_ count: Int) -> String { Self.days(count) }

    private func hasBest(_ id: String) -> Bool {
        GameStats.extraKeys(id).contains { UserDefaults.standard.object(forKey: $0) != nil }
    }

    // MARK: Reset

    private func reset(_ target: ResetTarget) {
        switch target {
        case .game(let info):
            GameStats.reset(info.id)
            model.discardHiddenSession(for: info.id)   // a paused game would keep its old best score
        case .all:
            GameStats.resetAll()
            for id in GameStats.gameIDs { model.discardHiddenSession(for: id) }
        }
        resetting = nil
        revision += 1
    }
}
