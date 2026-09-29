import SwiftUI

/// The Games tab: a 3-column grid of game tiles. Reopening a paused game's tile resumes it where you left off.
struct HomeGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(PackLibrary.self) private var packs

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(GameRegistry.all) { info in
                    GameTile(info: info) { model.openGame(info.id) }
                }
                GetMoreTile(accessibilityLabel: "Get more games from the Library") { model.openLibrary(.game) }
            }

        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .contentMargins(.bottom, 16, for: .scrollContent)
        .onAppear { packs.refresh() }
        .onChange(of: model.panelOpenCount) { packs.refresh() }
    }
}
