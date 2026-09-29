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
            } else if model.isShowingGame {
                GameScreen()
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            } else if model.isShowingLibrary {
                LibraryView()
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    header
                    SegmentedControl(selection: $model.tab, options: AppModel.Tab.allCases, title: \.title,
                                     height: 34, fontSize: 13, glassTrack: true)
                        .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    Group {
                        switch model.tab {
                        case .games: HomeGrid()
                        case .notes: NotesView()
                        case .settings: SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.15), value: model.tab)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: settings.effectivePanelStyle.cornerRadius, style: .continuous))
        .animation(.easeOut(duration: 0.2), value: model.isShowingGame)
        .animation(.easeOut(duration: 0.2), value: model.isShowingLibrary)
        .tint(settings.accent.color)
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
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
}
