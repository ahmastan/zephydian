import SwiftUI

/// The Games tab: a row with Stats and Get more, then a 3-column grid of game tiles.
/// Reopening a paused game's tile resumes it where you left off.
struct HomeGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(PackLibrary.self) private var packs

    var body: some View {
        let games = GameRegistry.all
        VStack(spacing: 10) {
            GridToolbar(count: games.count, noun: "game") {
                GridToolbarButton(title: "Stats", symbol: "chart.bar.fill", help: "Games played, wins, best scores and streaks") {
                    model.openStats()
                }
                GridToolbarButton(title: "Get more", symbol: "plus", help: "Get more games from the Library") {
                    model.openLibrary(.game)
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(games) { info in
                        GameTile(info: info) { model.openGame(info.id) }
                    }
                }
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .contentMargins(.bottom, 16, for: .scrollContent)
        }
        .onAppear { packs.refresh() }
        .onChange(of: model.panelOpenCount) { packs.refresh() }
    }
}
