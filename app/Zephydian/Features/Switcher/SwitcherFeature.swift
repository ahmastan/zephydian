// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zephydian contributors
// The switcher's options and their wording follow Vorssaint's switcher settings page
// (github.com/vorssaint/vorssaint-utils, UI/Settings/SwitcherSettings.swift, GPL-3.0-or-later),
// drawn here as Zephydian Settings rows.

import AppKit
import Carbon.HIToolbox
import SwiftUI
import SwitcherKit

/// The App Switcher: Vorssaint's switcher (in SwitcherKit), switched on and off from the Features page.
final class SwitcherFeatureEngine: FeatureEngine {
    func start() { SwitcherKit.setFeature(.switcher, on: true) }
    func stop() { SwitcherKit.setFeature(.switcher, on: false) }
}

/// SwitcherKit keeps shortcuts as text ("command:48"); Zephydian's recorder uses `KeyShortcut`.
/// The key's name is kept beside it so the field can show it.
enum SwitcherShortcutStore {
    static func read(_ key: String, fallback: KeyShortcut) -> KeyShortcut? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return fallback }
        guard let colon = raw.lastIndex(of: ":"), let code = UInt16(raw[raw.index(after: colon)...]) else { return fallback }
        var flags: NSEvent.ModifierFlags = []
        for token in raw[..<colon].split(separator: "+") {
            switch token {
            case "control": flags.insert(.control)
            case "option": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "command": flags.insert(.command)
            default: break
            }
        }
        let name = UserDefaults.standard.string(forKey: key + ".label") ?? KeyShortcut.functionKeys[code]
            ?? KeyShortcut.namedKeys[code] ?? (code == UInt16(kVK_ANSI_Grave) ? "`" : "Key \(code)")
        return KeyShortcut(keyCode: code, modifiers: flags, key: name)
    }

    static func write(_ shortcut: KeyShortcut?, to key: String) {
        guard let shortcut else {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key + ".label")
            return
        }
        var tokens: [String] = []
        if shortcut.flags.contains(.control) { tokens.append("control") }
        if shortcut.flags.contains(.option) { tokens.append("option") }
        if shortcut.flags.contains(.shift) { tokens.append("shift") }
        if shortcut.flags.contains(.command) { tokens.append("command") }
        UserDefaults.standard.set("\(tokens.joined(separator: "+")):\(shortcut.keyCode)", forKey: key)
        UserDefaults.standard.set(shortcut.key, forKey: key + ".label")
    }

    static let appsDefault = KeyShortcut(keyCode: UInt16(kVK_Tab), modifiers: .command, key: "⇥")
    static let windowsDefault = KeyShortcut(keyCode: UInt16(kVK_ANSI_Grave), modifiers: .command, key: "`")

    static var apps: KeyShortcut? { read(SwitcherKit.Keys.switcherShortcut, fallback: appsDefault) }
    static var windows: KeyShortcut? { read(SwitcherKit.Keys.switcherWindowShortcut, fallback: windowsDefault) }
}

/// The switcher's settings, under its status on its page in the Settings window.
struct SwitcherSettingsView: View {
    private typealias K = SwitcherKit.Keys
    @Environment(SettingsStore.self) private var appSettings
    @AppStorage(K.switcherTakeOverSystemShortcuts) private var takeOver = true
    @AppStorage(K.switcherIconRowMode) private var iconRow = false
    @AppStorage(K.switcherSimpleMode) private var simple = false
    @AppStorage(K.switcherMergeTabs) private var mergeTabs = false
    @AppStorage(K.switcherWindowlessApps) private var windowless = "finder"
    @AppStorage(K.switcherMinimizedPlacement) private var minimized = "normal"
    @AppStorage(K.switcherTreatHiddenAppsLikeMinimized) private var hiddenLikeMinimized = true
    @AppStorage(K.switcherShowFullscreenWindows) private var fullscreen = true
    @AppStorage(K.switcherScreenPlacement) private var placement = "pointer"
    @AppStorage(K.switcherCurrentDisplayOnly) private var currentDisplay = false
    @AppStorage(K.switcherCurrentSpaceOnly) private var currentSpace = false
    @AppStorage(K.switcherSearchPinEnabled) private var searchPin = false
    @AppStorage(K.switcherShowShortcutHints) private var hints = true
    @AppStorage(K.switcherAppearanceDelay) private var delay = 100
    @AppStorage(K.switcherInstantSelection) private var instant = false
    @AppStorage(K.switcherPreviewSize) private var previewSize = "normal"
    @AppStorage(K.minimalWindowPreviews) private var minimal = false
    @State private var rules: [String: String] = UserDefaults.standard.dictionary(forKey: K.switcherAppRules) as? [String: String] ?? [:]
    @State private var paused: [String] = UserDefaults.standard.stringArray(forKey: K.switcherPreviewExcludedApps) ?? []

    private enum Layout: String, CaseIterable, Identifiable {
        case windows, icons, simple
        var id: String { rawValue }
        var title: String {
            switch self {
            case .windows: "Window previews"
            case .icons: "Large icons"
            case .simple: "Simple list"
            }
        }
        var caption: String {
            switch self {
            case .windows: "One preview per window, minimized ones included."
            case .icons: "Shows one icon per app with that app’s window previews above it."
            case .simple: "Shows app icons and window titles, without previews or screen capture by the switcher."
            }
        }
    }

    private var layout: Binding<Layout> {
        Binding(get: { simple ? .simple : iconRow ? .icons : .windows }, set: { value in
            simple = value == .simple
            iconRow = value == .icons
            SwitcherKit.sync(.switcher)
        })
    }

    var body: some View {
        Section {
            Picker("Layout", selection: layout) {
                ForEach(Layout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Look")
        } footer: {
            Text(layout.wrappedValue.caption).font(.callout).foregroundStyle(.secondary)
        }

        Section {
            SwitcherShortcutRows()
            Toggle("Replace macOS ⌘Tab and ⌘`", isOn: $takeOver)
                .onChange(of: takeOver) { SwitcherKit.sync(.switcher) }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("Hold \(SwitcherShortcutStore.apps?.label ?? "the shortcut") to navigate; release to activate the window. Shift or ← goes back; W closes the window; Q quits the app; Esc cancels. The Windows shortcut opens a switcher for the frontmost app’s windows; while the switcher is open, it jumps between the selected app’s windows. Replacing macOS’s shortcuts disables them only while Zephydian’s switcher is active.")
                .font(.callout).foregroundStyle(.secondary)
        }

        Section("Options") {
            LabeledContent("Appearance delay") {
                MillisecondSlider(value: $delay, range: 0...500, step: 25, label: "Appearance delay")
                    .frame(maxWidth: 260)
            }
            Toggle("Instant selection", isOn: $instant)
            Toggle("Pin search with S", isOn: $searchPin)
            if layout.wrappedValue != .windows {
                Toggle("Show shortcut hints", isOn: $hints)
            }
            Toggle("Show one entry per app", isOn: $mergeTabs)
            Toggle("Show fullscreen windows", isOn: $fullscreen)
                .onChange(of: fullscreen) { SwitcherKit.sync(.switcher) }
            Picker("Minimized windows", selection: $minimized) {
                Text("Normal ordering").tag("normal")
                Text("Place at end").tag("end")
                Text("Hide").tag("hidden")
            }
            .onChange(of: minimized) { SwitcherKit.sync(.switcher) }
            if minimized != "normal" {
                Toggle("Treat hidden apps like minimized windows", isOn: $hiddenLikeMinimized)
                    .onChange(of: hiddenLikeMinimized) { SwitcherKit.sync(.switcher) }
            }
            Picker("Show on", selection: $placement) {
                Text("Display with the pointer").tag("pointer")
                Text("Display with the menu bar").tag("menuBar")
                Text("Display with the active window").tag("activeWindow")
            }
            Toggle("Show only the current display", isOn: $currentDisplay)
            Toggle("Show only the current desktop", isOn: $currentSpace)
            Picker("Apps with no open window", selection: $windowless) {
                Text("Do not show").tag("off")
                Text("Finder only").tag("finder")
                Text("All apps").tag("all")
            }
            .disabled(takeOver)
        }

        Section {
            if rules.isEmpty {
                Text("Every app follows the settings above.").foregroundStyle(.secondary)
            }
            ForEach(rules.keys.sorted { AppNames.name($0) < AppNames.name($1) }, id: \.self) { id in
                LabeledContent {
                    HStack {
                        Picker(AppNames.name(id), selection: Binding(get: { rules[id] ?? "windowsOnly" }, set: { setRule(id, $0) })) {
                            Text("Show without windows").tag("showWithoutWindows")
                            Text("Windows only").tag("windowsOnly")
                            Text("Never show").tag("hidden")
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Remove") { setRule(id, nil) }
                    }
                } label: {
                    Label { Text(AppNames.name(id)) } icon: { AppNames.icon(id) }
                }
            }
            LabeledContent("Add an app") {
                Menu("Choose…") {
                    ForEach(AppNames.running(excluding: Array(rules.keys)), id: \.self) { id in
                        Button(AppNames.name(id)) { setRule(id, "showWithoutWindows") }
                    }
                }
                .fixedSize()
            }
        } header: {
            Text("Rules by app")
        } footer: {
            Text("Choose how each app appears. Apps without a rule use the choice above.")
                .font(.callout).foregroundStyle(.secondary)
        }

        Section {
            Picker("Preview size", selection: $previewSize) {
                Text("Small").tag("small")
                Text("Normal").tag("normal")
                Text("Large").tag("large")
                Text("Extra large").tag("xlarge")
            }
            .pickerStyle(.segmented)
            .onChange(of: previewSize) { SwitcherKit.sync(.switcher) }
            Toggle("Minimal previews", isOn: $minimal)
            ForEach(paused, id: \.self) { id in
                LabeledContent {
                    Button("Remove") { setPaused(paused.filter { $0 != id }) }
                } label: {
                    Label { Text(AppNames.name(id)) } icon: { AppNames.icon(id) }
                }
            }
            LabeledContent("Pause in these apps") {
                Menu("Add an app…") {
                    ForEach(AppNames.running(excluding: paused), id: \.self) { id in
                        Button(AppNames.name(id)) { setPaused(paused + [id]) }
                    }
                }
                .fixedSize()
            }
        } header: {
            Text("Window thumbnails")
        } footer: {
            Text("Minimal previews hide titles, buttons and decorative details; the selection stays visible. Window thumbnails stop while one of the paused apps is in front.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func setRule(_ id: String, _ rule: String?) {
        rules[id] = rule
        UserDefaults.standard.set(rules, forKey: K.switcherAppRules)
        SwitcherKit.sync(.switcher)
    }

    private func setPaused(_ ids: [String]) {
        paused = ids
        UserDefaults.standard.set(ids, forKey: K.switcherPreviewExcludedApps)
    }
}

/// The switcher's two shortcut fields (its page and the Shortcuts page).
struct SwitcherShortcutRows: View {
    private typealias K = SwitcherKit.Keys
    @Environment(SettingsStore.self) private var appSettings
    @AppStorage(K.switcherTakeOverSystemShortcuts) private var takeOver = true
    @State private var appsShortcut = SwitcherShortcutStore.apps
    @State private var windowsShortcut = SwitcherShortcutStore.windows

    var body: some View {
        shortcutRow("Apps", shortcut: $appsShortcut, key: K.switcherShortcut, owner: "switcher-apps",
                    system: SwitcherShortcutStore.appsDefault)
        shortcutRow("Windows", shortcut: $windowsShortcut, key: K.switcherWindowShortcut, owner: "switcher-windows",
                    system: SwitcherShortcutStore.windowsDefault)
    }

    /// A switcher shortcut: any combination (the shortcut rule). Replacing macOS's own is expected
    /// while "Replace macOS ⌘Tab and ⌘`" is on, so no warning is shown for it then.
    @ViewBuilder
    private func shortcutRow(_ label: String, shortcut: Binding<KeyShortcut?>, key: String, owner: String,
                             system: KeyShortcut) -> some View {
        LabeledContent(label) {
            ShortcutRecorder(shortcut: shortcut.wrappedValue) { new in
                shortcut.wrappedValue = new
                SwitcherShortcutStore.write(new, to: key)
                SwitcherKit.sync(.switcher)
            }
        }
        if takeOver, shortcut.wrappedValue == system {
            Text("Replaces macOS’s own \(system.label) while the switcher is on.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ShortcutWarning(text: ShortcutConflicts.warning(for: shortcut.wrappedValue, registered: true, owner: owner,
                                                            panel: appSettings.panelShortcut))
        }
    }

}
