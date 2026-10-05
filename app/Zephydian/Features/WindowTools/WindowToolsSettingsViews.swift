import SwiftUI

/// Window Layout's page: every layout's shortcut, the gap, ⌥-drag and left-out apps.
struct WindowLayoutSettingsView: View {
    @State private var settings = WindowToolsSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            WindowLayoutShortcutRows()
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("They act on the front window. Pressing a half's shortcut again makes it two-thirds, then one-third. Restore puts the window back where it was before.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Pressing a half again changes its width", isOn: $settings.cycleSizes)
            LabeledContent("Gap between windows") {
                HStack {
                    Slider(value: Binding(get: { Double(settings.gap) }, set: { settings.gap = Int($0) }), in: 0...24, step: 2)
                        .frame(maxWidth: 200)
                    Text("\(settings.gap) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
            }
            Picker("Drag a window from anywhere with", selection: $settings.dragModifier) {
                ForEach(WindowToolsSettings.DragModifier.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Arranging")
        } footer: {
            Text(edgeNote).font(.callout).foregroundStyle(.secondary)
        }
        AppListSection(title: "Apps left alone", empty: "Every app can be arranged.", apps: $settings.layoutIgnoredApps)
    }

    private var edgeNote: String {
        if #available(macOS 15, *) {
            return "Dragging a window to a screen edge uses macOS's own tiling (System Settings → Desktop & Dock → Windows)."
        }
        return "Drag a window to a screen edge or corner to snap it there: sides for halves, the top to maximize, corners for quarters."
    }
}

/// One row per layout, with any shortcut recorded freely and the usual warning. Also on the Shortcuts page.
struct WindowLayoutShortcutRows: View {
    @State private var settings = WindowToolsSettings.shared
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        ForEach(WindowLayout.allCases) { layout in
            LabeledContent {
                ShortcutRecorder(shortcut: settings.shortcuts[layout]) { settings.shortcuts[layout] = $0 }
            } label: {
                Label(layout.title, systemImage: layout.symbol)
            }
            ShortcutWarning(text: ShortcutConflicts.warning(for: settings.shortcuts[layout],
                                                            registered: !WindowLayoutStatus.shared.failed.contains(layout),
                                                            owner: "layout-\(layout.rawValue)", panel: appSettings.panelShortcut))
        }
    }
}

struct GreenButtonSettingsView: View {
    @State private var settings = WindowToolsSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            Text("Click the green button to fill the screen; click it again to put the window back. ⌥-click it for full screen.")
                .foregroundStyle(.secondary)
        }
        AppListSection(title: "Apps that keep macOS's green button", empty: "Every app's green button maximizes.", apps: $settings.greenIgnoredApps)
    }
}

struct QuitProtectionSettingsView: View {
    @State private var settings = WindowToolsSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("To quit", selection: $settings.protection) {
                ForEach(WindowToolsSettings.Protection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Protect ⌘W (closing a window) too", isOn: $settings.protectClose)
        } footer: {
            Text(explanation).font(.callout).foregroundStyle(.secondary)
        }
        AppListSection(title: "Apps without protection", empty: "Every app is protected (except Finder, which doesn't quit).",
                       apps: $settings.protectionIgnoredApps)
    }

    private var explanation: String {
        switch settings.protection {
        case .twice: "Press ⌘Q twice within a second. The first press shows a note."
        case .hold: "Hold ⌘Q for about half a second; a ring fills while you hold."
        case .extraKey: "Press ⌥⌘Q instead of ⌘Q. Plain ⌘Q shows a note."
        }
    }
}

struct QuitOnCloseSettingsView: View {
    @State private var settings = WindowToolsSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            Text("Apps quit when you close their last window (minimized windows count as open). Finder never quits.")
                .foregroundStyle(.secondary)
        }
        AppListSection(title: "Apps that stay open", empty: "Every app quits with its last window.",
                       apps: $settings.keepOpenApps, addTitle: "Keep an app open")
        if settings.keepOpenApps != WindowToolsSettings.defaultKeepOpenApps {
            Section {
                Button("Restore the starting list (Music, Podcasts, TV)") { settings.keepOpenApps = WindowToolsSettings.defaultKeepOpenApps }
            }
        }
    }
}

struct FocusFollowsMouseSettingsView: View {
    @State private var settings = WindowToolsSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            LabeledContent("Pause before focusing") {
                MillisecondSlider(value: $settings.focusDelay, range: 50...1000, step: 50, label: "Pause before focusing")
                    .frame(maxWidth: 260)
            }
        } footer: {
            Text("The window under the pointer comes forward once the pointer rests there. Nothing happens while a mouse button is held, or over the menu bar, the Dock, menus or the desktop.")
                .font(.callout).foregroundStyle(.secondary)
        }
        AppListSection(title: "Apps left alone", empty: "Every app's windows follow the pointer.", apps: $settings.focusIgnoredApps)
    }
}

/// A list of apps (bundle IDs) with Remove buttons and a menu of open apps to add.
struct AppListSection: View {
    let title: String
    let empty: String
    @Binding var apps: [String]
    var addTitle = "Leave out an app"

    var body: some View {
        Section(title) {
            if apps.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(apps, id: \.self) { id in
                LabeledContent {
                    Button("Remove") { apps.removeAll { $0 == id } }
                } label: {
                    Label { Text(AppNames.name(id)) } icon: { AppNames.icon(id) }
                }
            }
            LabeledContent(addTitle) {
                Menu("Choose…") {
                    ForEach(AppNames.running(excluding: apps), id: \.self) { id in
                        Button(AppNames.name(id)) { apps.append(id) }
                    }
                }
                .fixedSize()
            }
        }
    }
}
