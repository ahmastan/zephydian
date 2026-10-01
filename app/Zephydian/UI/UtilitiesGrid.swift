import SwiftUI

/// The Utilities tab: a row with Get more, then installed utility packs in the same 3-column grid as Games.
/// Nothing comes preinstalled, so a short line explains where utilities come from until one is added.
struct UtilitiesGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(PackLibrary.self) private var packs

    var body: some View {
        let utilities = UtilityRegistry.all
        VStack(spacing: 10) {
            GridToolbar(count: utilities.count, noun: "utility", plural: "utilities") {
                GridToolbarButton(title: "Get more", symbol: "plus", help: "Get utilities from the Library") {
                    model.openLibrary(.utility)
                }
            }
            ScrollView {
            if utilities.isEmpty {
                Text("Utilities you add from the Library appear here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 10)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(utilities) { info in
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
