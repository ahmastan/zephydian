import Carbon.HIToolbox
import SwiftUI

struct SnippetsSettingsView: View {
    @State private var settings = InputSettings.shared
    @State private var secureInput = IsSecureEventInputEnabled()
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        @Bindable var settings = settings
        if secureInput {
            Section {
                Label("A password field is being typed in somewhere, so macOS is hiding typing from every app. Snippets work again once it's left.",
                      systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            ForEach(settings.snippets) { snippet in
                SnippetRow(snippet: snippet)
            }
            Button {
                settings.snippets.append(Snippet(trigger: InputSettings.triggerPrefix, text: ""))
            } label: { Label("Add Snippet", systemImage: "plus") }
        } header: {
            Text("Snippets")
        } footer: {
            Text("Type ; and the trigger in any app and it becomes its text. In the text, {clipboard}, {date}, {time} and {weekday} are filled in when it's inserted.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Snippet menu") {
                ShortcutRecorder(shortcut: settings.snippetMenuShortcut) { settings.snippetMenuShortcut = $0 }
            }
            ShortcutWarning(text: ShortcutConflicts.warning(for: settings.snippetMenuShortcut,
                                                            registered: SnippetsStatus.shared.menuShortcutRegistered,
                                                            owner: "snippet-menu", panel: appSettings.panelShortcut))
        } footer: {
            Text("Opens a search over your snippets; Return inserts the chosen one where you're typing.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { secureInput = IsSecureEventInputEnabled() }
    }
}

/// One snippet: the trigger after its fixed ";", the text, and Remove. It finds its snippet by id
/// every time, so removing one never leaves a field pointing at a snippet that's gone.
private struct SnippetRow: View {
    let snippet: Snippet
    @State private var settings = InputSettings.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(InputSettings.triggerPrefix)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Trigger", text: trigger, prompt: Text("trigger"))
                .labelsHidden()
                .font(.body.monospaced())
                .frame(width: 100)
            TextField("Text", text: text, prompt: Text("The text it becomes"), axis: .vertical)
                .labelsHidden()
                .lineLimit(1...4)
            Button(role: .destructive) {
                settings.snippets.removeAll { $0.id == snippet.id }
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .help("Remove this snippet")
            .accessibilityLabel("Remove \(snippet.trigger)")
        }
    }

    private var index: Int? { settings.snippets.firstIndex { $0.id == snippet.id } }

    /// What comes after the ";" (spaces aren't allowed in a trigger).
    private var trigger: Binding<String> {
        Binding(get: { String(snippet.trigger.dropFirst(InputSettings.triggerPrefix.count)) },
                set: { new in
                    guard let index else { return }
                    let cleaned = new.filter { !$0.isWhitespace && String($0) != InputSettings.triggerPrefix }
                    settings.snippets[index].trigger = InputSettings.triggerPrefix + cleaned
                })
    }

    private var text: Binding<String> {
        Binding(get: { snippet.text }, set: { new in
            guard let index else { return }
            settings.snippets[index].text = new
        })
    }
}

struct ScrollingSettingsView: View {
    @State private var settings = InputSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Smooth scrolling", isOn: $settings.smoothScrolling)
            if settings.smoothScrolling {
                LabeledContent("Speed") {
                    Slider(value: $settings.scrollSpeed, in: 0.5...2) { Text("Speed") } minimumValueLabel: { Text("Slow") } maximumValueLabel: { Text("Fast") }
                        .frame(maxWidth: 260)
                }
                LabeledContent("Glide") {
                    Slider(value: $settings.scrollGlide, in: 0.1...0.5) { Text("Glide") } minimumValueLabel: { Text("Short") } maximumValueLabel: { Text("Long") }
                        .frame(maxWidth: 260)
                }
            } else {
                Toggle("Every notch scrolls the same distance", isOn: $settings.linearScrolling)
                if settings.linearScrolling {
                    Stepper("\(settings.linearLines) lines per notch", value: $settings.linearLines, in: 1...10)
                }
            }
        } header: {
            Text("Mouse wheel")
        } footer: {
            Text("Only mouse wheels change. Trackpads and the Magic Mouse keep scrolling as macOS does.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section("Direction") {
            Toggle("Reverse vertical scrolling for the mouse", isOn: $settings.reverseMouseVertical)
            Toggle("Reverse horizontal scrolling for the mouse", isOn: $settings.reverseMouseHorizontal)
            Picker("Scroll sideways while holding", selection: $settings.sidewaysKey) {
                ForEach(InputSettings.SidewaysKey.allCases) { Text($0.title).tag($0) }
            }
        }
        AppListSection(title: "Apps left alone", empty: "Every app gets these mouse changes.", apps: $settings.mouseIgnoredApps)
    }
}

struct MouseButtonsSettingsView: View {
    @State private var settings = InputSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            ForEach(3...7, id: \.self) { button in
                buttonRow(button)
            }
        } header: {
            Text("Buttons")
        } footer: {
            Text("Button 4 and 5 are usually the side buttons (back and forward); 6 and up are extra buttons some mice have. Back and Forward press ⌘[ and ⌘], which Finder, browsers and most apps understand.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Drag with the middle button", isOn: $settings.middleDragEnabled)
            if settings.middleDragEnabled {
                ForEach([("left", "Drag left"), ("right", "Drag right"), ("up", "Drag up"), ("down", "Drag down")], id: \.0) { direction, label in
                    Picker(label, selection: Binding(get: { settings.dragActions[direction] ?? MouseAction.none }, set: { settings.dragActions[direction] = $0 })) {
                        ForEach(MouseAction.allCases.filter { $0 != .shortcut }) { Text($0.title).tag($0) }
                    }
                }
            }
        } header: {
            Text("Gestures")
        } footer: {
            Text("Hold the middle button (press the wheel) and drag. A plain middle click stays a middle click. Desktop and App Exposé use your keyboard shortcuts for them in System Settings → Keyboard.")
                .font(.callout).foregroundStyle(.secondary)
        }
        AppListSection(title: "Apps left alone", empty: "Every app gets these mouse changes.", apps: $settings.mouseIgnoredApps)
    }

    @ViewBuilder private func buttonRow(_ number: Int) -> some View {
        @Bindable var settings = settings
        let action = Binding(get: { settings.buttonActions[number] ?? MouseAction.none }, set: { settings.buttonActions[number] = $0 })
        Picker("Button \(number + 1)", selection: action) {
            ForEach(MouseAction.allCases) { Text($0.title).tag($0) }
        }
        if action.wrappedValue == .shortcut {
            LabeledContent("Button \(number + 1) presses") {
                ShortcutRecorder(shortcut: settings.buttonShortcuts[number]) { settings.buttonShortcuts[number] = $0 }
            }
        }
    }
}

struct ClickFilterSettingsView: View {
    @State private var settings = InputSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            LabeledContent("Ignore clicks within") {
                MillisecondSlider(value: $settings.clickFilterMs, range: 20...150, step: 10, label: "Ignore clicks within").frame(maxWidth: 260)
            }
        } footer: {
            Text("A worn button can click twice when pressed once. A second click this soon after the first ends is ignored; real double clicks are much slower, so they still work.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct KeyDebounceSettingsView: View {
    @State private var settings = InputSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            LabeledContent("Ignore repeats within") {
                MillisecondSlider(value: $settings.keyDebounceMs, range: 10...120, step: 10, label: "Ignore repeats within").frame(maxWidth: 260)
            }
        } footer: {
            Text("A worn key can type a letter twice. The same key pressed again this soon after it was let go is ignored. Holding a key to repeat it still works.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct SuperKeySettingsView: View {
    @State private var settings = InputSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Super key", selection: $settings.superKey) {
                ForEach(InputSettings.SuperKey.allCases) { Text($0.title).tag($0) }
            }
            Picker("Tapped alone", selection: $settings.superTap) {
                ForEach(InputSettings.TapAction.allCases) { Text($0.title).tag($0) }
            }
        } footer: {
            Text("Held, the Super key acts as ⌃⌥⇧⌘ together, a combination no app uses, so shortcuts you make with it (in Zephydian, macOS or other apps) never clash. With Caps Lock as the Super key, ⇧+Caps Lock turns Caps Lock on and off.")
                .font(.callout).foregroundStyle(.secondary)
        }
        AppListSection(title: "Apps where it's a plain key", empty: "It's the Super key in every app.", apps: $settings.superIgnoredApps)
    }
}

struct PointerAccelerationSettingsView: View {
    var body: some View {
        Section {
            Text("While this is on, the mouse pointer moves the same distance for the same hand movement, however fast you move. Trackpads keep their acceleration. Switching it off puts your previous setting back.")
                .foregroundStyle(.secondary)
        }
    }
}

struct MiddleClickSettingsView: View {
    var body: some View {
        Section {
            Text("Press the trackpad with three fingers for a middle click: open a link in a new tab, close a tab, or paste in Terminal.")
                .foregroundStyle(.secondary)
        }
    }
}
