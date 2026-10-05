import Carbon.HIToolbox
import SwiftUI
import SwitcherKit

struct PlainPasteSettingsView: View {
    @State private var settings = ClipboardToolsSettings.shared
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        @Bindable var settings = settings
        Section {
            LabeledContent("Paste as plain text") {
                ShortcutRecorder(shortcut: settings.plainPasteShortcut) { settings.plainPasteShortcut = $0 }
            }
            ShortcutWarning(text: ShortcutConflicts.warning(for: settings.plainPasteShortcut,
                                                            registered: ClipboardToolsStatus.shared.plainPasteRegistered,
                                                            owner: "plain-paste", panel: appSettings.panelShortcut))
        } footer: {
            Text("Pastes what you copied without its fonts, colors or links, then puts the original back on the clipboard.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct AutoClearSettingsView: View {
    @State private var settings = ClipboardToolsSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Clear the clipboard", selection: $settings.clearAfter) {
                Text("Not after a time").tag(0)
                Text("30 seconds after copying").tag(30)
                Text("1 minute after copying").tag(60)
                Text("2 minutes after copying").tag(120)
                Text("5 minutes after copying").tag(300)
                Text("10 minutes after copying").tag(600)
            }
            Toggle("When the Mac goes to sleep", isOn: $settings.clearOnSleep)
            Toggle("When the screen locks", isOn: $settings.clearOnLock)
        } footer: {
            Text("So a copied password or address doesn't stay on the clipboard. Clipboard's history (if you use it) keeps its items.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct CleanURLSettingsView: View {
    @State private var settings = ClipboardToolsSettings.shared

    var body: some View {
        @Bindable var settings = settings
        Section {
            Text("A link you copy loses its tracking (utm_source, fbclid, gclid and others) right away, so what you paste is clean. Only parameters known to track you are removed; the ones a page needs stay.")
                .foregroundStyle(.secondary)
        }
        AppListSection(title: "Apps left alone", empty: "Links copied in any app are cleaned.", apps: $settings.cleanIgnoredApps)
    }
}

/// Finder Shortcuts' options and wording follow Vorssaint's Finder settings page
/// (github.com/vorssaint/vorssaint-utils, UI/Settings/CutPasteSettings.swift, GPL-3.0-or-later).
struct FinderShortcutsSettingsView: View {
    private typealias K = SwitcherKit.Keys
    @Environment(SettingsStore.self) private var appSettings
    @AppStorage(K.finderCutPasteEnabled) private var cutPaste = true
    @AppStorage(K.finderCutPasteShowHUD) private var showHUD = true
    @AppStorage(K.finderPasteImageAsFile) private var pasteImage = true
    @AppStorage(K.finderRenameEnabled) private var rename = true
    @State private var renameShortcut = SwitcherShortcutStore.read(K.finderRenameShortcut, fallback: Self.renameDefault)

    static let renameDefault = KeyShortcut(keyCode: UInt16(kVK_F2), modifiers: [], key: "F2")

    var body: some View {
        Section {
            Toggle("Cut & paste files in Finder", isOn: $cutPaste)
                .onChange(of: cutPaste) { SwitcherKit.sync(.finderCutPaste) }
            if cutPaste {
                Toggle("Show floating panel", isOn: $showHUD)
                    .onChange(of: showHUD) { SwitcherKit.sync(.finderCutPaste) }
            }
            Toggle("⌘V saves a copied image as a file", isOn: $pasteImage)
                .onChange(of: pasteImage) { SwitcherKit.sync(.finderCutPaste) }
        } header: {
            Text("Cut and paste")
        } footer: {
            Text("Select items in Finder and press ⌘X to cut them. Open the destination folder and press ⌘V to move them there. The floating panel shows the cut files while Finder is active. In text fields (like when renaming), ⌘X and ⌘V keep working as usual. The first time, macOS asks for permission to control Finder.")
                .font(.callout).foregroundStyle(.secondary)
        }

        Section {
            Toggle("Use a shortcut to rename", isOn: $rename)
                .onChange(of: rename) { SwitcherKit.sync(.finderRename) }
            if rename {
                LabeledContent("Rename") {
                    ShortcutRecorder(shortcut: renameShortcut) { new in
                        renameShortcut = new
                        SwitcherShortcutStore.write(new ?? Self.renameDefault, to: K.finderRenameShortcut)
                        SwitcherKit.sync(.finderRename)
                    }
                }
                ShortcutWarning(text: ShortcutConflicts.warning(for: renameShortcut, registered: true, owner: "finder-rename",
                                                                panel: appSettings.panelShortcut))
            }
        } header: {
            Text("Rename shortcut")
        } footer: {
            Text("The shortcut only acts in Finder and leaves text fields alone. F2 works as a regular key; on keyboards where it controls brightness, use Fn-F2 or choose another shortcut.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct DiskImageInstallerSettingsView: View {
    var body: some View {
        Section {
            Text("When you open a disk image (.dmg) with an app in it, a card offers to install it: the app is copied to Applications (Zephydian asks before replacing an older copy), the disk image is ejected and the .dmg moves to the Trash.")
                .foregroundStyle(.secondary)
        }
    }
}

struct ShelfSettingsView: View {
    @State private var settings = ClipboardToolsSettings.shared
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Open the Shelf by", selection: $settings.shelfOpening) {
                ForEach(ClipboardToolsSettings.ShelfOpening.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Open the Shelf") {
                ShortcutRecorder(shortcut: settings.shelfShortcut) { settings.shelfShortcut = $0 }
            }
            ShortcutWarning(text: ShortcutConflicts.warning(for: settings.shelfShortcut, registered: ClipboardToolsStatus.shared.shelfRegistered,
                                                            owner: "shelf", panel: appSettings.panelShortcut))
        } footer: {
            Text("Shaking: start dragging a file, link or text and give the pointer a quick shake, and the Shelf appears beside it. Corner panel: as soon as you start dragging, Zephydian's panel opens on the Shelf in its corner. Drop things on it and drag them out later. While it holds something, the panel shows a Shelf button; it's also in the menu bar menu.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
