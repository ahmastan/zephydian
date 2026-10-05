import SwiftUI

/// One page of the Settings window, as a grouped form like System Settings.
struct SettingsPageView: View {
    let page: SettingsPage

    var body: some View {
        Group {
            switch page {
            case .general: GeneralPage()
            case .appearance: AppearancePage()
            case .panel: PanelPage()
            case .shortcuts: ShortcutsPage()
            case .notes: NotesPage()
            case .games: GamesPage()
            case .packs: PacksPage()
            case .features: FeaturesPage()
            case .permissions: PermissionsPage()
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}

/// A grey note under a group.
private struct FooterNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

private struct GeneralPage: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginMessage: String?

    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in updateLaunchAtLogin(enabled) }
                if let loginMessage {
                    LabeledContent {
                        Button("Open Login Items") { LaunchAtLogin.openSystemSettings() }
                    } label: {
                        FooterNote(loginMessage)
                    }
                }
            }
            Section {
                LabeledContent("Welcome tour") {
                    Button("Show Again") { model.startOnboarding() }
                }
            }
            Section("About") {
                LabeledContent("Version", value: "\(version) (\(build))")
                LabeledContent("Website") { Link("zephydian.com", destination: URL(string: "https://zephydian.com")!) }
                LabeledContent("Source code") { Link("GitHub", destination: URL(string: "https://github.com/ahmastan/zephydian")!) }
            }
            Section {
                LabeledContent("Quit Zephydian") {
                    Button("Quit", role: .destructive) { NSApp.terminate(nil) }
                }
            }
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            if LaunchAtLogin.needsApproval { loginMessage = "Approve Zephydian in System Settings → General → Login Items." }
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.set(enabled)
            loginMessage = LaunchAtLogin.needsApproval ? "Approve Zephydian in System Settings → General → Login Items." : nil
        } catch {
            loginMessage = "Couldn’t change this: \(error.localizedDescription)"
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}

// MARK: Appearance

private struct AppearancePage: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Mode", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if #available(macOS 26, *) {
                    Picker("Panel style", selection: $settings.panelStyle) {
                        ForEach(PanelStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            } footer: {
                if #available(macOS 26, *) {
                    FooterNote("Liquid Glass lets the desktop show through the panel. Frosted blurs it more, for easier reading.")
                }
            }
            Section {
                LabeledContent("Accent") { AccentSwatches(glass: false) }
                LabeledContent("Menu bar icon") { MenuBarIconPicker(glass: false) }
            }
        }
    }
}

// MARK: Panel & Corner

private struct PanelPage: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent("Corner") {
                    CornerPicker(corner: $settings.corner, glass: false)
                        .padding(.vertical, 4)
                }
                HotCornerWarning(corner: settings.corner)
                LabeledContent("Delay") {
                    MillisecondSlider(value: $settings.dwellMs, range: 0...600, step: 50, label: "Corner delay")
                        .frame(maxWidth: 260)
                }
                LabeledContent("Display") { DisplayPicker() }
            } footer: {
                FooterNote("Delay is how long the pointer rests in the corner before the panel opens.")
            }
            Section {
                Picker("Panel size", selection: $settings.panelSize) {
                    ForEach(PanelSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Picker("Auto-hide", selection: $settings.autoHide) {
                    ForEach(AutoHideMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                LabeledContent("Hide delay") {
                    MillisecondSlider(value: $settings.hideDelayMs, range: 0...1500, step: 100, label: "Hide delay")
                        .frame(maxWidth: 260)
                        .disabled(settings.autoHide == .never)
                }
            } footer: {
                FooterNote(settings.autoHide.explanation)
            }
        }
    }
}

// MARK: Shortcuts

private struct ShortcutsPage: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(PackLibrary.self) private var library

    var body: some View {
        Form {
            Section {
                LabeledContent("Open the panel") {
                    ShortcutRecorder(shortcut: settings.panelShortcut) { settings.panelShortcut = $0 }
                }
                ShortcutWarning(text: ShortcutConflicts.warning(for: settings.panelShortcut, registered: model.shortcutAvailable,
                                                                owner: "panel", panel: settings.panelShortcut))
            } header: {
                Text("Zephydian")
            } footer: {
                FooterNote("Click a field and press any combination. Zephydian tells you when macOS or another app already uses it.")
            }
            if Features.shared.isOn("switcher") {
                Section("App Switcher") {
                    SwitcherShortcutRows()
                }
            }
            if Features.shared.isOn("snippets") {
                @Bindable var input = InputSettings.shared
                Section("Text Snippets") {
                    LabeledContent("Snippet menu") {
                        ShortcutRecorder(shortcut: input.snippetMenuShortcut) { input.snippetMenuShortcut = $0 }
                    }
                    ShortcutWarning(text: ShortcutConflicts.warning(for: input.snippetMenuShortcut,
                                                                    registered: SnippetsStatus.shared.menuShortcutRegistered,
                                                                    owner: "snippet-menu", panel: settings.panelShortcut))
                }
            }
            if Features.shared.isOn("window-layout") {
                Section("Window Layout") { WindowLayoutShortcutRows() }
            }
            if Features.shared.isOn("paste-plain") { Section("Paste as Plain Text") { PlainPasteSettingsView() } }
            if Features.shared.isOn("shelf") {
                @Bindable var clip = ClipboardToolsSettings.shared
                Section("Shelf") {
                    LabeledContent("Open the Shelf") {
                        ShortcutRecorder(shortcut: clip.shelfShortcut) { clip.shelfShortcut = $0 }
                    }
                    ShortcutWarning(text: ShortcutConflicts.warning(for: clip.shelfShortcut, registered: ClipboardToolsStatus.shared.shelfRegistered,
                                                                    owner: "shelf", panel: settings.panelShortcut))
                }
            }
            let utilities = library.packs.filter { ($0.manifest.capabilities ?? []).contains("shortcut") }
            if !utilities.isEmpty {
                Section("Utilities") {
                    ForEach(utilities, id: \.id) { pack in
                        UtilityShortcutRow(name: pack.manifest.name, packID: pack.id)
                    }
                }
            }
        }
    }
}

/// A utility's own global shortcut, the same one its screen in the panel shows.
struct UtilityShortcutRow: View {
    let name: String
    let packID: String
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let shortcuts = PackServices.shared.shortcuts
        let current = shortcuts.current(packID: packID)
        LabeledContent(name) {
            ShortcutRecorder(shortcut: current) { new in
                shortcuts.set(packID: packID, new)
                PackServices.shared.changed()
            }
        }
        ShortcutWarning(text: ShortcutConflicts.warning(for: current, registered: !shortcuts.failed.contains(packID),
                                                        owner: packID, panel: settings.panelShortcut))
    }
}

// MARK: Notes

private struct NotesPage: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Monospace font", isOn: $settings.notesMonospaced)
                Toggle("Notes window stays on top", isOn: $settings.notesWindowOnTop)
            } footer: {
                FooterNote("Notes are plain Markdown files in ~/Library/Application Support/Zephydian/Notes.")
            }
        }
    }
}

// MARK: Games

private struct GamesPage: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Five: high-contrast colors", isOn: $settings.fiveHighContrast)
            }
            Section {
                LabeledContent("Stats") {
                    Button("Show Stats") { showInPanel { model.openStats() } }
                }
                LabeledContent("More games") {
                    Button("Open the Library") { showInPanel { model.openLibrary(.game) } }
                }
            }
        }
    }

    /// Opens the panel on the Games tab, then a screen in it.
    private func showInPanel(_ open: () -> Void) {
        model.tab = .games
        open()
        model.showPanel()
    }
}

// MARK: Packs

private struct PacksPage: View {
    @Environment(PackManager.self) private var packs
    @Environment(PackServices.self) private var services
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates daily", isOn: Binding(get: { packs.autoUpdate }, set: { packs.autoUpdate = $0 }))
                LabeledContent(packs.statusLine) {
                    Button("Check Now") { Task { await packs.checkForUpdates() } }
                        .disabled(packs.installed.isEmpty || packs.catalogState == .loading)
                }
            } footer: {
                FooterNote("Zephydian goes online only to install packs you choose and, while this is on, about once a day to update them. Nothing about you is sent.")
            }
            Section("Running now") {
                if services.running.isEmpty {
                    Text("Nothing is running in the background.").foregroundStyle(.secondary)
                }
                ForEach(services.running) { service in
                    LabeledContent("\(service.packName) · \(service.detail)") {
                        Button("Stop") { services.stop(service.id) }
                    }
                }
            }
            Section {
                LabeledContent("Library") {
                    HStack {
                        Button("Games") { showLibrary(.game, tab: .games) }
                        Button("Utilities") { showLibrary(.utility, tab: .utilities) }
                    }
                }
            }
        }
    }

    private func showLibrary(_ kind: PackBundle.Kind, tab: AppModel.Tab) {
        model.tab = tab
        model.openLibrary(kind)
        model.showPanel()
    }
}

// MARK: Permissions

/// A permission: what it allows, what uses it, and its button.
private struct PermissionRow: View {
    let permission: Permission

    var body: some View {
        let users = Features.shared.users(of: permission)
        let unused = users.isEmpty && Permissions.shared.isGranted(permission)
        LabeledContent {
            PermissionControl(permission: permission)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title)
                    Text(permission.explanation).font(.callout).foregroundStyle(.secondary)
                    Text(users.isEmpty ? "Not used by anything right now." : "Used by \(users.formatted(.list(type: .and))).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                SettingsIcon(symbol: permission.symbol)
            }
        }
        if unused {
            LabeledContent {
                Button("Open System Settings") { Permissions.shared.openSettings(permission) }
            } label: {
                FooterNote("Nothing uses this now. You can turn it off in System Settings.")
            }
        }
    }
}

private struct PermissionsPage: View {
    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission)
                }
            } footer: {
                FooterNote(note)
            }
        }
        .onAppear { Permissions.shared.refresh() }
    }

    private var note: String {
        if Permission.allCases.contains(where: Permissions.shared.looksStuck) {
            return "A permission that was allowed before stopped working, which happens after an update. Repair clears the old entry; then allow Zephydian again. Screen Recording may ask you to reopen Zephydian."
        }
        return "Zephydian asks only when a feature needs it, and everything stays on your Mac."
    }
}

// MARK: Features

private struct FeaturesPage: View {
    var body: some View {
        let features = Features.shared
        let on = features.enabled.count
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Switch on what you use. A feature that's off doesn't run at all, and it keeps its settings for when you switch it back on.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        ForEach(FeaturePreset.allCases) { preset in
                            Button(preset.title) { features.apply(preset) }
                        }
                    }
                    HStack(spacing: 10) {
                        ProgressView(value: Double(on), total: Double(max(features.all.count, 1)))
                        Text("\(on) of \(features.all.count) on")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .accessibilityElement(children: .combine)
                }
                .padding(.vertical, 4)
            }
            if features.all.isEmpty {
                Section { Text("No features yet.").foregroundStyle(.secondary) }
            }
            #if DEBUG
            Section {
                Text("Debug: input listeners paused \(EventTap.timeouts.count) times since launch (0 is right).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
            ForEach(FeatureGroup.allCases) { group in
                let list = features.all.filter { $0.group == group }
                if !list.isEmpty {
                    Section(group.title) {
                        ForEach(list) { FeatureRow(feature: $0) }
                    }
                }
            }
        }
    }
}

/// A feature on the Features page: icon, name, one line, its permissions, and the switch.
/// When it's on, clicking the row opens its page.
private struct FeatureRow: View {
    let feature: Feature
    @Environment(AppModel.self) private var model

    var body: some View {
        let features = Features.shared
        let on = features.isOn(feature.id)
        let missing = on ? features.missing(feature) : []
        HStack(alignment: .top, spacing: 10) {
            SettingsIcon(symbol: feature.symbol, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.name)
                Text(feature.summary).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !feature.permissions.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(feature.permissions) { permission in
                            Label(permission.title, systemImage: permission.symbol)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !missing.isEmpty {
                    Label("Waiting for \(missing.map(\.title).formatted(.list(type: .and)))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if on {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }
            Toggle(feature.name, isOn: Binding(get: { on }, set: { features.set(feature.id, on: $0) }))
                .labelsHidden()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if on { model.settingsSelection = .feature(feature.id) } }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open settings") { if on { model.settingsSelection = .feature(feature.id) } }
    }
}

/// A switched-on feature's own page: what it is, whether it's running, then its settings.
struct FeaturePage: View {
    let feature: Feature

    var body: some View {
        let features = Features.shared
        let missing = features.missing(feature)
        Form {
            Section {
                HStack(spacing: 12) {
                    SettingsIcon(symbol: feature.symbol, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.name).font(.headline)
                        Text(feature.summary).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle(feature.name, isOn: Binding(get: { features.isOn(feature.id) }, set: { features.set(feature.id, on: $0) }))
                        .labelsHidden()
                }
                .padding(.vertical, 4)
                if missing.isEmpty {
                    LabeledContent("Status") {
                        Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                ForEach(missing) { permission in
                    LabeledContent {
                        PermissionControl(permission: permission)
                    } label: {
                        Text("Needs \(permission.title) to run")
                    }
                }
                ForEach(feature.uses.filter { !feature.requires.contains($0) && !Permissions.shared.isGranted($0) }) { permission in
                    LabeledContent {
                        PermissionControl(permission: permission)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Works better with \(permission.title)")
                            Text(permission.explanation).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let settings = feature.settings {
                settings()
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}
