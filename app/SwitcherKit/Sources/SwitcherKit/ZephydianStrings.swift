// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 Zephydian contributors
// Written for Zephydian on 2026-10-05; contains parts copied from vorssaint/vorssaint-utils, commit 04abae3, marked where they appear.

// Zephydian: the English text the copied switcher and Finder cut and paste use, taken from
// Vorssaint's Strings.enUS table (Core/Localization.swift). Zephydian is English only.

import Foundation

enum AppLanguage: String { case enUS }

final class L10n: ObservableObject {
    static let shared = L10n()
    let language: AppLanguage = .enUS
    var s: Strings { Strings.enUS }
}

struct Strings {
    var cutCancel = "Cancel cut"
    var cutDoneTitle = "Moved!"
    var cutMovedPluralFormat = "%d items moved"
    var cutMovedSingular = "1 item moved"
    var cutMovingCountFormat = "%d of %d"
    var cutMovingTitle = "Moving…"
    var cutPasteActiveNow = "Ready to cut in Finder"
    var cutPasteAutomationNote = "The first time, macOS asks for permission to control Finder."
    var cutPasteEnable = "Cut & paste files in Finder"
    var cutPasteEnableCaption = "Use ⌘X to cut and ⌘V to move files and folders in Finder."
    var cutPasteHowTitle = "How to use"
    var cutPasteShowHUD = "Show floating panel"
    var cutPasteShowHUDCaption = "Display a floating indicator with the cut files while Finder is active."
    var cutPasteTextNote = "In text fields (like when renaming), ⌘X and ⌘V keep working as usual."
    var cutReadyHint = "in the destination folder to move"
    var cutReadyTitle = "Cut"
    var cutSomeFailed = "Some items couldn’t be moved"
    var dockPreviewCloseWindow = "Close window"
    var keepAwakeOptions = "Options"
    var minimalWindowPreviews = "Minimal previews"
    var minimalWindowPreviewsCaption = "Hide titles, buttons and decorative details in Dock and switcher previews. The selection stays visible."
    var panelHiddenItem = "Hidden"
    var permissionRequired = "Permission required"
    var previewSizeLabel = "Preview size"
    var previewSizeLarge = "Large"
    var previewSizeNormal = "Normal"
    var previewSizeSmall = "Small"
    var previewSizeXLarge = "Extra large"
    var shortcutConflictFormat = "This shortcut is already used by %@."
    var shortcutInvalid = "Use at least Control, Option or Command with a key."
    var shortcutNotCaptured = "Nothing was captured. macOS or another app already uses that combination. Try another one."
    var shortcutPressKeys = "Press keys"
    var shortcutReset = "Reset"
    var switcherAppearanceDelay = "Appearance delay"
    var switcherAppearanceDelayCaption = "How long the shortcut must be held before the switcher appears."
    var switcherCurrentDisplayOnly = "Show only the current display"
    var switcherCurrentDisplayOnlyCaption = "Lists only windows on the display under the pointer. If that display has no windows, the switcher does not open."
    var switcherCurrentSpaceOnly = "Show only the current desktop"
    var switcherCurrentSpaceOnlyCaption = "Lists only windows from the desktop you are on. Picking a window never moves you to another desktop."
    var switcherEnable = "Use the Zephydian switcher"
    var switcherEnableCaption = "Switch between apps and windows, including minimized windows and multiple windows from the same app."
    var switcherIconRowModeCaption = "Shows one icon per app with that app’s window previews above it."
    var switcherInstantSelection = "Instant selection"
    var switcherInstantSelectionCaption = "Moves the highlight and scroll position immediately as you browse apps and windows."
    var switcherMergeTabs = "Show one entry per app"
    var switcherMergeTabsCaption = "Collapses all of an app’s windows into one entry in the switcher, instead of one entry per window."
    var switcherMinimizedPlacementEnd = "Place at end"
    var switcherMinimizedPlacementHidden = "Hide"
    var switcherMinimizedPlacementLabel = "Minimized windows"
    var switcherMinimizedPlacementNormal = "Normal ordering"
    var switcherNoOpenWindow = "No open window"
    var switcherNoWindows = "No open windows"
    var switcherOtherDesktop = "Other desktop"
    var switcherScreenPlacementActiveWindow = "Display with the active window"
    var switcherScreenPlacementCaption = "Which display the switcher opens on when more than one is connected."
    var switcherScreenPlacementLabel = "Show on"
    var switcherScreenPlacementMenuBar = "Display with the menu bar"
    var switcherScreenPlacementPointer = "Display with the pointer"
    var switcherSearchPin = "Pin search with S"
    var switcherSearchPinCaption = "S starts a search and pins the switcher open, so typing no longer produces special characters when your shortcut uses ⌥, and a search starting with Q or W no longer closes the window or quits the app by mistake."
    var switcherSection = "Window switcher"
    var switcherShortcutHintApps = "Apps"
    var switcherShortcutHintWindows = "Windows"
    var switcherShowFullscreenWindows = "Show fullscreen windows"
    var switcherShowShortcutHints = "Show shortcut hints"
    var switcherShowShortcutHintsCaption = "Shows the app and window shortcuts below the icons."
    var switcherSimpleModeCaption = "Shows app icons and window titles, without previews or screen capture by the switcher."
    var switcherTakeOverSystemShortcuts = "Replace macOS ⌘Tab and ⌘`"
    var switcherTakeOverSystemShortcutsCaption = "Disables the matching macOS app and window shortcuts only while Zephydian’s switcher is active. All running apps stay reachable."
    var switcherTreatHiddenAppsLikeMinimized = "Treat hidden apps like minimized windows"
    var switcherUsageHintFormat = "Hold %@ to navigate; release to activate the window. Shift or ← goes back; W closes the window; Q quits the app; Esc cancels."
    var switcherWindowlessApps = "Apps with no open window"
    var switcherWindowlessAppsAll = "All apps"
    var switcherWindowlessAppsCaption = "Chooses which running apps with no window at all show up in the switcher."
    var switcherWindowlessAppsFinder = "Finder only"
    var switcherWindowlessAppsOff = "Do not show"
    var switcherWindowShortcutCaption = "Opens a switcher for the frontmost app’s windows. While the switcher is open, jumps between the selected app’s windows."
    var tabSwitcher = "Switcher"

    static let enUS = Strings()
}
