import AppKit
import SwiftUI
import SwitcherKit

/// While a shortcut field is recording, the panel's own key handling stands aside.
enum ShortcutRecording {
    static var isActive = false {
        didSet { SwitcherKit.setRecordingShortcut(isActive) }   // the switcher lets every key through meanwhile
    }
}

/// A field for recording a keyboard shortcut: click it, press the keys (at least ⌘, ⌥ or ⌃, or a
/// function key). Esc cancels, ⌫ clears. Every global shortcut in Zephydian is set this way, and a
/// `ShortcutWarning` under it says when something else on the Mac already uses the combination.
struct ShortcutRecorder: View {
    let shortcut: KeyShortcut?
    let onChange: (KeyShortcut?) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(recording ? "Type a shortcut…" : shortcut?.label ?? "Record Shortcut")
                    .font(.system(size: 12, weight: shortcut == nil || recording ? .regular : .medium).monospacedDigit())
                    .frame(minWidth: 96)
            }
            .controlSize(.small)
            .help(recording ? "Press the keys. Esc cancels, ⌫ clears." : "Click, then press the keys you want")
            .accessibilityLabel("Keyboard shortcut")
            .accessibilityValue(recording ? "Recording" : shortcut?.label ?? "None")
            if shortcut != nil && !recording {
                Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove the shortcut")
                    .accessibilityLabel("Remove the shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        ShortcutRecording.isActive = true
        GlobalHotKey.pauseAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                switch Int(event.keyCode) {
                case 53:                                       // Esc: cancel
                    stop()
                case 51, 117:                                  // ⌫: clear
                    stop()
                    onChange(nil)
                default:
                    guard let recorded = KeyShortcut(event: event) else { NSSound.beep(); return }
                    stop()                                     // hot keys come back first, so the new one can register
                    onChange(recorded)
                }
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        ShortcutRecording.isActive = false
        GlobalHotKey.resumeAll()
    }
}

/// The note under a shortcut field when the combination is already taken. Text on the panel, not a
/// pop-up, so the person can just pick another.
struct ShortcutWarning: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Warning: \(text)")
        }
    }
}

extension ShortcutConflicts {
    /// Zephydian's own global shortcuts by name (the panel's and each utility's), except `excluding`.
    @MainActor static func zephydianShortcuts(panel: KeyShortcut?, excluding: String) -> [String: KeyShortcut] {
        var out: [String: KeyShortcut] = [:]
        if excluding != "panel", let panel { out["The panel shortcut"] = panel }
        if Features.shared.isOn("switcher") {
            if excluding != "switcher-apps", let s = SwitcherShortcutStore.apps { out["The app switcher"] = s }
            if excluding != "switcher-windows", let s = SwitcherShortcutStore.windows { out["The app switcher (windows)"] = s }
        }
        if Features.shared.isOn("finder-shortcuts"), excluding != "finder-rename",
           UserDefaults.standard.object(forKey: SwitcherKit.Keys.finderRenameEnabled) as? Bool ?? true,
           let s = SwitcherShortcutStore.read(SwitcherKit.Keys.finderRenameShortcut, fallback: FinderShortcutsSettingsView.renameDefault) {
            out["Finder's rename shortcut"] = s
        }
        if Features.shared.isOn("snippets"), excluding != "snippet-menu", let s = InputSettings.shared.snippetMenuShortcut {
            out["The snippet menu"] = s
        }
        let clip = ClipboardToolsSettings.shared
        if Features.shared.isOn("paste-plain"), excluding != "plain-paste", let s = clip.plainPasteShortcut { out["Paste as plain text"] = s }
        if Features.shared.isOn("shelf"), excluding != "shelf", let s = clip.shelfShortcut { out["The Shelf"] = s }
        if Features.shared.isOn("camera-mirror"), excluding != "camera-mirror", let s = CameraMirrorSettings.shared.shortcut { out["Camera Mirror"] = s }
        if Features.shared.isOn("quick-toggles"), excluding != "mic-mute", let s = QuickTogglesSettings.shared.micShortcut { out["Mute the microphone"] = s }
        if Features.shared.isOn("cleaning-mode"), excluding != "cleaning", let s = CleaningModeSettings.shared.shortcut { out["Cleaning mode"] = s }
        if Features.shared.isOn("command-bar"), excluding != "command-bar", let s = CommandBarSettings.shared.shortcut { out["The Command Bar"] = s }
        if Features.shared.isOn("quick-panel"), excluding != "quick-panel", let s = QuickPanelSettings.shared.shortcut { out["The Quick Panel"] = s }
        if Features.shared.isOn("sound-mixer"), excluding != "sound-cycle", let s = SoundSettings.shared.cycleShortcut { out["Switch the sound output"] = s }
        if Features.shared.isOn("window-layout") {
            for (layout, shortcut) in WindowToolsSettings.shared.shortcuts where excluding != "layout-\(layout.rawValue)" {
                out["Window Layout (\(layout.title.lowercased()))"] = shortcut
            }
        }
        let shortcuts = PackServices.shared.shortcuts
        for bundle in PackLibrary.shared.packs where bundle.id != excluding {
            if let s = shortcuts.current(packID: bundle.id) { out[bundle.manifest.name] = s }
        }
        return out
    }

    /// The warning for a shortcut field: registration failed (another app has it), or a known use.
    @MainActor static func warning(for shortcut: KeyShortcut?, registered: Bool, owner: String, panel: KeyShortcut?) -> String? {
        guard let shortcut else { return nil }
        if let known = check(shortcut, others: zephydianShortcuts(panel: panel, excluding: owner)) { return known }
        if !registered { return "Another app on this Mac already uses \(shortcut.label), so it won't work here. Pick another." }
        return nil
    }
}
