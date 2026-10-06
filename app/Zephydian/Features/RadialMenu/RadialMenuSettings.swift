import SwiftUI

/// Radial Menu's settings: the options shared by every wheel, then each wheel's triggers.
/// (Editing a wheel's slices and adding wheels comes with the wheel editor.)
struct RadialMenuSettingsView: View {
    @State private var settings = RadialSettings.shared
    @State private var input = InputSettings.shared
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Wheel size", selection: $settings.size) {
                ForEach(RadialSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            LabeledContent("Highlight opacity") {
                HStack {
                    // No `step:` (macOS would draw a tick for every step, which reads as a line); the value snaps to 1%.
                    Slider(value: Binding(get: { settings.highlightOpacity },
                                          set: { settings.highlightOpacity = ($0 * 100).rounded() / 100 }),
                           in: 0.1...0.8)
                        .frame(maxWidth: 200)
                        .accessibilityLabel("Highlight opacity")
                        .accessibilityValue("\(Int((settings.highlightOpacity * 100).rounded())) percent")
                    Text("\(Int((settings.highlightOpacity * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                    Button("Reset") { settings.highlightOpacity = RadialSettings.defaultHighlight }
                        .controlSize(.small)
                        .disabled(abs(settings.highlightOpacity - RadialSettings.defaultHighlight) < 0.005)
                }
            }
            Picker("Position", selection: $settings.position) {
                ForEach(RadialPosition.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Every wheel")
        } footer: {
            Text("The highlight is the colored slice that follows the pointer. A wheel at the pointer moves in from the screen's edges so it always fits.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section {
            Picker("Shortcut and button", selection: $settings.mode) {
                ForEach(RadialMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        } footer: {
            Text(settings.mode.explanation + " Holding works with shortcuts that use ⌘, ⌥, ⌃ or ⇧, and with mouse buttons.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach($settings.wheels) { $wheel in
            wheelSection($wheel)
        }
        Section {
            LabeledContent("Add a wheel") {
                Menu("New Wheel") {
                    ForEach(RadialStarter.allCases.filter { $0 != .blank }) { starter in
                        Button(starter.title) { add(starter) }
                    }
                }
                .fixedSize()
                .disabled(settings.wheels.count >= 12)
            }
        } footer: {
            Text("Each wheel has its own shortcut and mouse button. A new wheel starts from a ready-made set; choosing its slices yourself comes next.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("While a wheel is open") {
                Text("Point and click, or ← → and ↵. 1–9, 0, - and = pick slices 1 to 12. Esc closes; ⌫ or Esc leaves a folder.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A new wheel from a starter set, named so it doesn't repeat another's name.
    private func add(_ starter: RadialStarter) {
        var wheel = starter.makeWheel()
        let names = Set(settings.wheels.map(\.name))
        var name = wheel.name, number = 2
        while names.contains(name) { name = "\(wheel.name) \(number)"; number += 1 }
        wheel.name = name
        settings.wheels.append(wheel)
    }

    private func wheelSection(_ wheel: Binding<RadialWheel>) -> some View {
        let value = wheel.wrappedValue
        return Section {
            LabeledContent("Color") {
                RadialColorSwatches(color: wheel.color)
            }
            LabeledContent("Shortcut") {
                ShortcutRecorder(shortcut: value.shortcut) { wheel.wrappedValue.shortcut = $0 }
            }
            ShortcutWarning(text: ShortcutConflicts.warning(for: value.shortcut, registered: !settings.refused.contains(value.id),
                                                            owner: "radial-\(value.id.uuidString)", panel: appSettings.panelShortcut))
            Picker("Mouse button", selection: wheel.mouseButton) {
                Text("None").tag(Int?.none)
                ForEach(2...7, id: \.self) { button in
                    Text(RadialSettings.buttonTitle(button)).tag(Int?.some(button))
                        .disabled(settings.wheels.contains { $0.id != value.id && $0.mouseButton == button })
                }
            }
            if let button = value.mouseButton {
                if !Permissions.shared.isGranted(.accessibility) {
                    ShortcutWarning(text: "A mouse button needs Accessibility. Allow it in Settings → Permissions.")
                } else if Features.shared.isOn("mouse-buttons"), button == 2 ? input.middleDragEnabled : (input.buttonActions[button] ?? .none) != .none {
                    ShortcutWarning(text: "Mouse Buttons also uses this button. The wheel takes it while it's set here.")
                }
            }
            LabeledContent("Try it") {
                HStack {
                    Button("Open \(value.name)") { RadialMenuEngine.current?.preview(value) }
                        .disabled(RadialMenuEngine.current == nil)
                    if settings.wheels.count > 1 {
                        Button("Delete Wheel", role: .destructive) { settings.wheels.removeAll { $0.id == value.id } }
                    }
                }
            }
        } header: {
            Text("\(value.name) wheel")
        } footer: {
            if value.shortcut == nil && value.mouseButton == nil {
                Text("Set a shortcut or a mouse button to open this wheel.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// A wheel's color: its highlight and the lit slice. Accent follows Zephydian's accent color.
private struct RadialColorSwatches: View {
    @Binding var color: RadialColor
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RadialColor.allCases) { option in
                let swatch = option.color(accent: settings.accentColor)
                let selected = option == color
                Button { color = option } label: {
                    Circle()
                        .fill(swatch)
                        .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                        .overlay {
                            // Accent is marked, since it changes with the app's accent color.
                            if option == .accent {
                                Image(systemName: "a.circle.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? swatch : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(option == .accent ? "Accent (follows Zephydian's accent color)" : option.title)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
