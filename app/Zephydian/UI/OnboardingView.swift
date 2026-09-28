import SwiftUI

/// First-launch welcome card: pick a corner, learn about Hot Corners.
struct OnboardingView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = settings

        VStack(spacing: 10) {
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
            Text("Notes and games today, more utilities coming soon.")
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

            Button("Done") { model.finishOnboarding() }
                .prominentButtonStyle()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 12)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
