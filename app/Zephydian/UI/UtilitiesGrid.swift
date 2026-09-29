import SwiftUI

/// The Utilities tab: installed utility packs in the same 3-column grid as Games, then Get more.
/// Nothing comes preinstalled, so a short line explains where utilities come from until one is added.
struct UtilitiesGrid: View {
    @Environment(AppModel.self) private var model
    @Environment(PackLibrary.self) private var packs

    var body: some View {
        let utilities = UtilityRegistry.all
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
                GetMoreTile(accessibilityLabel: "Get utilities from the Library") { model.openLibrary(.utility) }
            }
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .contentMargins(.bottom, 16, for: .scrollContent)
        .onAppear { packs.refresh() }
        .onChange(of: model.panelOpenCount) { packs.refresh() }
    }
}
