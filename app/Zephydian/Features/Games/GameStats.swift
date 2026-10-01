import Foundation

/// Stats for the built-in games, saved in UserDefaults (`stats.<id>`): games played, games won,
/// scores for averages, and each game's streak of days in a row it was played.
/// Best scores and times stay where the games keep them (`BestScore`, `BestTime`).
enum GameStats {
    struct Record: Codable, Equatable {
        var played = 0
        var won = 0
        /// Scores of finished games, for the average (Snake, Stackr, Airship).
        var totalScore = 0
        var scoredGames = 0
        /// The last day a game was started ("yyyy-MM-dd", local time) and the streak up to it.
        var lastDay: String?
        var streak = 0
        var longestStreak = 0

        var average: Int? { scoredGames > 0 ? Int((Double(totalScore) / Double(scoredGames)).rounded()) : nil }
        var winRate: Int? { played > 0 ? Int((Double(won) / Double(played) * 100).rounded()) : nil }

        /// The streak still counts if the game was played today or yesterday.
        func currentStreak(today: String = GameStats.dayKey(.now), yesterday: String = GameStats.dayKey(.now, offset: -1)) -> Int {
            lastDay == today || lastDay == yesterday ? streak : 0
        }
    }

    /// The games that keep stats, in the order the Stats screen lists them.
    static let gameIDs = ["snake", "stackr", "five", "wheel", "fleet", "airship", "2048", "mines", "nines"]

    static var defaults: UserDefaults = .standard

    // MARK: Recording

    /// A game was started (a new game, round or level).
    static func started(_ id: String, on date: Date = .now) {
        update(id) { record in
            record.played += 1
            let today = dayKey(date)
            guard record.lastDay != today else { return }
            record.streak = record.lastDay == dayKey(date, offset: -1) ? record.streak + 1 : 1
            record.longestStreak = max(record.longestStreak, record.streak)
            record.lastDay = today
        }
    }

    static func won(_ id: String) {
        update(id) { $0.won += 1 }
    }

    /// A scored game ended (for the average score).
    static func finished(_ id: String, score: Int) {
        update(id) {
            $0.totalScore += score
            $0.scoredGames += 1
        }
    }

    // MARK: Reading

    static func record(_ id: String) -> Record {
        migrateIfNeeded()
        guard let data = defaults.data(forKey: key(id)), let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return Record()
        }
        return record
    }

    // MARK: Reset

    /// Clears a game's stats, best scores and best times. Saved games in progress and Spokes' level stay.
    static func reset(_ id: String) {
        migrateIfNeeded()
        defaults.removeObject(forKey: key(id))
        for extra in extraKeys(id) { defaults.removeObject(forKey: extra) }
    }

    static func resetAll() {
        for id in gameIDs { reset(id) }
    }

    /// The other saved figures a game's Reset clears.
    static func extraKeys(_ id: String) -> [String] {
        switch id {
        case "snake": [SnakeGame.bestKey]
        case "stackr": [StackrGame.bestKey]
        case "airship": [AirshipGame.bestKey]
        case "2048": [Game2048.bestKey]
        case "mines": MinesGame.Difficulty.allCases.map(\.bestKey)
        case "nines": NinesGame.Difficulty.allCases.map(\.bestKey)
        case "five": ["five.stats"]
        case "fleet": ["fleet.wins"]
        default: []
        }
    }

    // MARK: Helpers

    static func dayKey(_ date: Date, offset: Int = 0) -> String {
        let day = Calendar.current.date(byAdding: .day, value: offset, to: date) ?? date
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func key(_ id: String) -> String { "stats.\(id)" }

    private static func update(_ id: String, _ change: (inout Record) -> Void) {
        var record = record(id)
        change(&record)
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: key(id)) }
    }

    /// Once: start Five and Fleet from what they already counted before Stats existed.
    private static func migrateIfNeeded() {
        guard !defaults.bool(forKey: "stats.migrated") else { return }
        defaults.set(true, forKey: "stats.migrated")
        if defaults.data(forKey: key("five")) == nil, let data = defaults.data(forKey: "five.stats"),
           let five = try? JSONDecoder().decode(FiveGame.Stats.self, from: data), five.played > 0 {
            let record = Record(played: five.played, won: five.wins)
            if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: key("five")) }
        }
        let fleetWins = defaults.integer(forKey: "fleet.wins")
        if defaults.data(forKey: key("fleet")) == nil, fleetWins > 0 {
            // Losses weren't counted before, so played starts at the wins.
            let record = Record(played: fleetWins, won: fleetWins)
            if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: key("fleet")) }
        }
    }
}
