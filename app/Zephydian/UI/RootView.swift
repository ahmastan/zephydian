import SwiftUI

/// Everything inside the panel.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model

        ZStack {
            if model.isOnboarding {
                OnboardingView()
                    .transition(.opacity)
            } else if model.isShowingShelf {
                ShelfContent(floating: false) { model.closeShelf() }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            } else if model.isShowingGame && !model.isShowingTabGame {
                GameScreen()
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            } else if model.isShowingStats {
                StatsView()
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            } else if model.isShowingLibrary {
                LibraryView()
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    // A game or utility tab puts the tab bar on top, where the header was, so its
                    // own header (name, score, pause) comes right under it.
                    if !model.isShowingTabGame { header }
                    // One tab left: no bar, the page gets the room. A page opened from a hidden tab
                    // (a utility's shortcut, say) highlights no tab. Past 4 tabs, icons replace names.
                    let tabs = settings.visibleTabs
                    if tabs.count > 1 {
                        SegmentedControl(selection: $model.tab, options: tabs, title: PanelTabLabel.title,
                                         height: 34, fontSize: 13, glassTrack: true,
                                         icon: { AnyView(PanelTabLabel.icon($0)) }, iconOnly: tabs.count > 4)
                            .padding(.horizontal, 16)
                            .padding(.top, model.isShowingTabGame ? 10 : 0)
                            .padding(.bottom, 12)
                    }

                    Group {
                        switch model.tab {
                        case .games: HomeGrid()
                        case .utilities: UtilitiesGrid()
                        case .notes: NotesView()
                        case .settings: SettingsView()
                        case .feature(let id): FeatureTabView(id: id)
                        case .item(let id):
                            if model.isShowingTabGame {
                                GameScreen(showsBack: false)
                                    .environment(\.boardScale, tabs.count > 1 ? model.tabBoardScale : model.boardScale)
                            } else {
                                Text("This game or utility isn't installed. Add it again from the Library, or change the tabs in Settings → Panel & Corner.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(24)
                                    .onAppear { model.openGame(id) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.15), value: model.tab)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.boardScale, model.boardScale)
        .clipShape(RoundedRectangle(cornerRadius: settings.effectivePanelStyle.cornerRadius, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: model.isShowingGame)
        .animation(.easeOut(duration: 0.2), value: model.isShowingLibrary)
        .animation(.easeOut(duration: 0.2), value: model.isShowingStats)
        .animation(.easeOut(duration: 0.2), value: model.isShowingShelf)
        .onChange(of: settings.visibleTabs) { _, tabs in
            // The tab on screen was just hidden in Settings: move to the first one left.
            if !tabs.contains(model.tab), let first = tabs.first { model.tab = first }
        }
        .tint(settings.accentColor)
        .panelButtonStyle()
        .overlay {
            // Frosted only: Apple's hairline edge (a faint light rim in dark mode, a soft dark edge in light mode).
            // Liquid Glass draws its own rim, so nothing is added on top of it.
            if settings.effectivePanelStyle == .frosted {
                RoundedRectangle(cornerRadius: PanelStyle.frosted.cornerRadius)
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.1), lineWidth: 0.5)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Zephydian").font(.system(size: 15, weight: .semibold))
            Spacer()
            // Things parked on the Shelf: a way back to them from the panel.
            if Features.shared.isOn("shelf"), !ShelfStore.shared.items.isEmpty {
                Button { model.openShelf() } label: {
                    Label("Shelf · \(ShelfStore.shared.items.count)", systemImage: "tray.full")
                }
                .glassIconButtonStyle()
                .help("What's on the Shelf")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
}

/// A panel tab's name and icon: a built-in tab's own, or its game's or utility's.
enum PanelTabLabel {
    static func title(_ tab: PanelTab) -> String {
        if let id = tab.featureID { return Features.shared.feature(id).map { featureTitle($0) } ?? tab.title }
        return tab.itemID.flatMap { GameRegistry.info(for: $0)?.name } ?? tab.title
    }

    /// Short names for the bar ("Sound", not "Sound Mixer").
    private static func featureTitle(_ feature: Feature) -> String {
        switch feature.id {
        case "sound-mixer": "Sound"
        case "brightness": "Brightness"
        case "snippets": "Snippets"
        default: feature.name
        }
    }

    @ViewBuilder static func icon(_ tab: PanelTab) -> some View {
        if let id = tab.itemID, let info = GameRegistry.info(for: id) {
            GameIconView(icon: info.icon, size: 16)
        } else if let id = tab.featureID, let feature = Features.shared.feature(id) {
            Image(systemName: feature.symbol).font(.system(size: 14, weight: .medium))
        } else {
            Image(systemName: tab.symbol).font(.system(size: 14, weight: .medium))
        }
    }
}
