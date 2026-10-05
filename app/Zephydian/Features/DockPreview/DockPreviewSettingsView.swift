import SwiftUI

/// Dock Preview's settings, under its status on its page in the Settings window.
struct DockPreviewSettingsView: View {
    @State private var settings = DockPreviewSettings.shared

    var body: some View {
        @Bindable var settings = settings

        Section("Previews") {
            Picker("Show windows from", selection: $settings.currentSpaceOnly) {
                Text("All desktops").tag(false)
                Text("This desktop only").tag(true)
            }
            Picker("Order", selection: $settings.order) {
                ForEach(DockPreviewSettings.Order.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Open delay") {
                MillisecondSlider(value: $settings.openDelay, range: 0...1000, step: 50, label: "Open delay")
                    .frame(maxWidth: 260)
            }
            Picker("Size", selection: $settings.size) {
                ForEach(DockPreviewSettings.PreviewSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Minimal previews", isOn: $settings.minimal)
        }

        Section {
            Toggle("Peek at a window while hovering it", isOn: $settings.peek)
            Toggle("Drag a window out of the preview to move it", isOn: $settings.dragToMove)
            Toggle("× quits the app instead of closing a window", isOn: $settings.closeQuitsApp)
        } header: {
            Text("Windows")
        } footer: {
            Text("Click a window to switch to it, even on another desktop. A middle click closes it. Minimal previews hide the titles and buttons.")
                .font(.callout).foregroundStyle(.secondary)
        }

        Section {
            Picker("Clicking the active app's Dock icon", selection: $settings.dockClick) {
                ForEach(DockPreviewSettings.DockClick.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Keep the Dock visible while previewing", isOn: $settings.keepDockVisible)
        } header: {
            Text("Dock")
        } footer: {
            Text("Keeping the Dock visible is experimental: while a preview is open, Zephydian switches the Dock's auto-hide off and puts it back afterwards. Windows may resize while it's off.")
                .font(.callout).foregroundStyle(.secondary)
        }

        Section {
            if settings.excludedApps.isEmpty {
                Text("Every app gets a preview.").foregroundStyle(.secondary)
            }
            ForEach(settings.excludedApps, id: \.self) { id in
                LabeledContent {
                    Button("Remove") { settings.excludedApps.removeAll { $0 == id } }
                } label: {
                    Label { Text(AppNames.name(id)) } icon: { AppNames.icon(id) }
                }
            }
            LabeledContent("Leave out an app") {
                Menu("Choose…") {
                    ForEach(AppNames.running(excluding: settings.excludedApps), id: \.self) { id in
                        Button(AppNames.name(id)) { settings.excludedApps.append(id) }
                    }
                }
                .fixedSize()
            }
        } header: {
            Text("Apps without a preview")
        }
    }
}
