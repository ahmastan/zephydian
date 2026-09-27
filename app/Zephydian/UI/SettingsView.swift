import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginMessage: String?

    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(title: "Trigger") {
                    SettingsRow(label: "Corner") {
                        CornerPicker(corner: $settings.corner)
                    }
                    .padding(.vertical, 6)
                    HotCornerWarning(corner: settings.corner)
                        .padding(.bottom, 8)
                    SettingsRow(label: "Delay") {
                        MillisecondSlider(value: $settings.dwellMs, range: 0...600, step: 50, label: "Corner delay")
                    }
                    SettingsRow(label: "Keyboard shortcut") {
                        Picker("Keyboard shortcut", selection: $settings.globalShortcut) {
                            ForEach(GlobalShortcut.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize().controlSize(.small)
                    }
                    if !model.shortcutAvailable {
                        Label("Another app already uses this shortcut. Pick a different one.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 8)
                    }
                    SettingsRow(label: "Display", isLast: true) {
                        displayPicker
                    }
                }

                SettingsSection(title: "Appearance") {
                    SettingsRow(label: "Mode") {
                        SegmentedControl(selection: $settings.appearance, options: AppearanceMode.allCases, title: \.title)
                            .frame(width: 176)
                    }
                    if #available(macOS 26, *) {
                        SettingsRow(label: "Panel style") {
                            SegmentedControl(selection: $settings.panelStyle, options: PanelStyle.allCases, title: \.title)
                                .frame(width: 176)
                        }
                    }
                    SettingsRow(label: "Accent") {
                        accentSwatches
                    }
                    SettingsRow(label: "Menu bar icon", isLast: true) {
                        menuBarIcons
                    }
                }

                SettingsSection(title: "Behavior") {
                    SettingsRow(label: "Launch at login") {
                        Toggle("Launch at login", isOn: $launchAtLogin)
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            .onChange(of: launchAtLogin) { _, enabled in updateLaunchAtLogin(enabled) }
                    }
                    if let loginMessage {
                        loginNote(loginMessage)
                    }
                    SettingsRow(label: "Auto-hide") {
                        SegmentedControl(selection: $settings.autoHide, options: AutoHideMode.allCases, title: \.title)
                            .frame(width: 176)
                    }
                    SettingsRow(label: "Hide delay", isLast: true) {
                        MillisecondSlider(value: $settings.hideDelayMs, range: 0...1500, step: 100, label: "Hide delay")
                            .disabled(settings.autoHide == .never)
                    }
                    Text(settings.autoHide.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
                }

                SettingsSection(title: "Notes & games") {
                    SettingsRow(label: "Monospace notes font") {
                        Toggle("Monospace notes font", isOn: $settings.notesMonospaced)
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    SettingsRow(label: "Five high-contrast colors", isLast: true) {
                        Toggle("Five high-contrast colors", isOn: $settings.fiveHighContrast)
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }

                SettingsSection(title: "About") {
                    SettingsRow(label: "Zephydian") {
                        Text("Version \(version) (\(build))").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Replay welcome") { model.startOnboarding() }
                        Link("GitHub", destination: URL(string: "https://github.com/ahmastan/zephydian")!)
                        Spacer()
                        Button("Quit", role: .destructive) { NSApp.terminate(nil) }
                    }
                    .controlSize(.small)
                    .frame(minHeight: 38)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            if LaunchAtLogin.needsApproval { loginMessage = "Approve Zephydian in System Settings → General → Login Items." }
        }
    }

    // MARK: Pieces

    @ViewBuilder private var displayPicker: some View {
        @Bindable var settings = settings
        let others = NSScreen.screens.dropFirst().map(\.localizedName)
        if others.isEmpty {
            Text("Main display").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            Picker("Display", selection: $settings.displayName) {
                Text("Main display").tag(String?.none)
                ForEach(others, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .labelsHidden().fixedSize().controlSize(.small)
        }
    }

    private var accentSwatches: some View {
        HStack(spacing: 6) {
            ForEach(AccentTheme.allCases) { theme in
                Button { settings.accent = theme } label: {
                    Circle()
                        .fill(theme.color)
                        .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay(Circle().strokeBorder(settings.accent == theme ? theme.color : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(theme.name)
                .accessibilityLabel(theme.name)
                .accessibilityAddTraits(settings.accent == theme ? .isSelected : [])
            }
        }
    }

    private var menuBarIcons: some View {
        HStack(spacing: 2) {
            ForEach(MenuBarIcon.allCases) { icon in
                let selected = settings.menuBarIcon == icon
                Button { settings.menuBarIcon = icon } label: {
                    icon.swiftUIImage
                        .frame(width: 15, height: 15)
                        .font(.system(size: 13))
                        .frame(width: 26, height: 24)
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(icon.title)
                .accessibilityLabel(icon.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func loginNote(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open") { LaunchAtLogin.openSystemSettings() }.controlSize(.small)
        }
        .padding(.bottom, 8)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.set(enabled)
            loginMessage = LaunchAtLogin.needsApproval
                ? "Approve Zephydian in System Settings → General → Login Items."
                : nil
        } catch {
            loginMessage = "Couldn’t change this: \(error.localizedDescription)"
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}
