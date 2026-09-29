import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginMessage: String?
    @Environment(PackManager.self) private var packs
    @Environment(PackServices.self) private var services

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
                        ShortcutRecorder(shortcut: settings.panelShortcut) { settings.panelShortcut = $0 }
                    }
                    ShortcutWarning(text: ShortcutConflicts.warning(for: settings.panelShortcut, registered: model.shortcutAvailable,
                                                                    owner: "panel", panel: settings.panelShortcut))
                        .padding(.bottom, 8)
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

                SettingsSection(title: "Packs") {
                    // Background services of utilities (keep awake…), each with a Stop button.
                    ForEach(services.running) { service in
                        SettingsRow(label: "\(service.packName) · \(service.detail)") {
                            Button("Stop") { services.stop(service.id) }.controlSize(.small)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    SettingsRow(label: "Check for updates daily") {
                        Toggle("Check for updates daily", isOn: Binding(get: { packs.autoUpdate }, set: { packs.autoUpdate = $0 }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    SettingsRow(label: packsStatus, isLast: true) {
                        Button("Check now") { Task { await packs.checkForUpdates() } }
                            .controlSize(.small)
                            .disabled(packs.installed.isEmpty || packs.catalogState == .loading)
                    }
                    Text("Zephydian goes online only to install packs you choose and, while this is on, about once a day to update them. Nothing about you is sent.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)
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

    /// Springy slide for the glass selection bubbles (a quick fade with Reduce Motion).
    private var selectionAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.32, dampingFraction: 0.78)
    }

    private var accentSwatches: some View {
        HStack(spacing: 6) {
            ForEach(AccentTheme.allCases) { theme in
                let selected = settings.accent == theme
                Button { settings.accent = theme } label: {
                    Circle()
                        .fill(theme.color)
                        .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay {
                            // Frosted: a ring in the swatch's color. Liquid Glass: a glass bubble behind it.
                            if !settings.usesGlass {
                                Circle().strokeBorder(selected ? theme.color : .clear, lineWidth: 2)
                            }
                        }
                        .background { if selected { selectionBubble(Circle()) } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(theme.name)
                .accessibilityLabel(theme.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(selectionAnimation, value: settings.accent)
    }

    /// The glass bubble behind the selected accent swatch or menu bar icon (Liquid Glass only).
    /// It's a background, so it slides between options and never covers them.
    @ViewBuilder private func selectionBubble<S: InsettableShape>(_ shape: S) -> some View {
        if settings.usesGlass {
            shape.fill(.clear)
                .glassSurface(in: shape, interactive: true)
                .matchedGeometryEffect(id: "bubble-\(S.self)", in: selection)
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
                        .foregroundStyle(iconStyle(selected: selected))
                        .background {
                            if settings.usesGlass {
                                if selected { selectionBubble(Capsule()) }
                            } else {
                                RoundedRectangle(cornerRadius: 6).fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(icon.title)
                .accessibilityLabel(icon.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(selectionAnimation, value: settings.menuBarIcon)
    }

    private func iconStyle(selected: Bool) -> AnyShapeStyle {
        guard selected else { return AnyShapeStyle(.secondary) }
        return settings.usesGlass ? AnyShapeStyle(.tint) : AnyShapeStyle(.white)
    }

    /// "Last checked: today, 14:02", or what went wrong with the last check.
    private var packsStatus: String {
        if packs.installed.isEmpty { return "No packs installed yet" }
        switch packs.catalogState {
        case .loading: return "Checking…"
        case .offline: return "You're offline"
        case .failed: return "Couldn't check. Try again later."
        default:
            guard let date = packs.lastChecked else { return "Not checked yet" }
            return "Last checked: \(date.formatted(.relative(presentation: .named)))"
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
