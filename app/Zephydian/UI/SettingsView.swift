import SwiftUI

/// The panel's short Settings tab: what people change most, and a way into the Settings window.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: "Quick settings") {
                    SettingsRow(label: "Corner") {
                        CornerPicker(corner: $settings.corner)
                    }
                    .padding(.vertical, 6)
                    HotCornerWarning(corner: settings.corner)
                        .padding(.bottom, 8)
                    SettingsRow(label: "Mode") {
                        SegmentedControl(selection: $settings.appearance, options: AppearanceMode.allCases, title: \.title)
                            .frame(width: 176)
                    }
                    SettingsRow(label: "Panel size") {
                        SegmentedControl(selection: $settings.panelSize, options: PanelSize.allCases, title: \.title)
                            .frame(width: 176)
                    }
                    SettingsRow(label: "Accent", isLast: true) {
                        AccentSwatches(glass: settings.usesGlass)
                    }
                }

                if Permission.allCases.contains(where: Permissions.shared.looksStuck) {
                    Button { model.openSettingsWindow(SettingsPage.permissions.rawValue) } label: {
                        Label("A permission stopped working. Repair it in Settings → Permissions.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                }

                HStack {
                    Spacer()
                    Button { model.openSettingsWindow(nil) } label: {
                        Label("All Settings…", systemImage: "gearshape")
                    }
                    .panelButtonStyle()
                    .help("Every setting, in its own window (⌘,)")
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .onAppear { Permissions.shared.refresh() }
    }
}
