import SwiftUI

/// First-launch welcome: pick a corner (and learn about Hot Corners), then pick which features to switch on.
struct OnboardingView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model
    @State private var step = 0

    var body: some View {
        Group {
            if step == 0 { cornerStep } else { featuresStep }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasFeatures: Bool { !Features.shared.all.isEmpty }

    private var cornerStep: some View {
        @Bindable var settings = settings
        return VStack(spacing: 10) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Welcome to Zephydian")
                .font(.system(size: 20, weight: .bold))
            Text("Utility and gaming corner.")
                .foregroundStyle(.secondary)
            Text("Utilities, notes and games, with more utilities coming soon.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            Text("Pick the corner that opens me:")
                .font(.system(size: 13, weight: .medium))
                .padding(.top, 14)
            CornerPicker(corner: $settings.corner, width: 200, height: 128, dot: 26)
            Text(settings.corner.name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("**Tip:** if you use macOS Hot Corners (System Settings → Desktop & Dock → Hot Corners…), pick a different corner so they don’t clash.")
                    .foregroundStyle(.secondary)
                HotCornerWarning(corner: settings.corner)
            }
            .font(.system(size: 11.5))
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tokens.fill))
            .padding(.top, 10)

            Button(hasFeatures ? "Next" : "Done") {
                if hasFeatures { step = 1 } else { model.finishOnboarding() }
            }
            .prominentButtonStyle()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 12)
        }
    }

    private var featuresStep: some View {
        VStack(spacing: 10) {
            Image(systemName: "switch.2")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Make your Mac better")
                .font(.system(size: 20, weight: .bold))
            Text("Zephydian can also add features to macOS, like a preview of your windows when you hover the Dock and a better ⌘Tab. Pick a starting point; you can change anything later in Settings → Features.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)

            choice(.essentials, title: "Essentials", detail: "The most popular features.", prominent: true)
            choice(.everything, title: "Everything", detail: "Every feature, switched on.", prominent: false)
            choice(.none, title: "Not now", detail: "Keep Zephydian to its panel.", prominent: false)

            Button("Choose one by one in Settings") {
                model.finishOnboarding()
                model.openSettingsWindow(SettingsPage.features.rawValue)
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .padding(.top, 6)

            Button("Back") { step = 0 }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func choice(_ preset: FeaturePreset, title: String, detail: String, prominent: Bool) -> some View {
        Button {
            model.finishOnboarding()
            // After the panel closes, so macOS's permission prompts don't land on top of it.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                Features.shared.apply(preset)
            }
        } label: {
            VStack(spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).opacity(0.8)
            }
            .frame(maxWidth: 220)
        }
        .modifier(ChoiceStyle(prominent: prominent))
        .controlSize(.large)
    }
}

/// The main choice in the accent; the others as ordinary panel buttons.
private struct ChoiceStyle: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent { content.prominentButtonStyle() } else { content.panelButtonStyle() }
    }
}
