// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 Zephydian contributors
// Written for Zephydian on 2026-10-05; contains parts copied from vorssaint/vorssaint-utils, commit 04abae3, marked where they appear.

// Zephydian: the settings keys (and their starting values) the copied switcher and Finder cut and
// paste read, taken from Vorssaint's Core/Defaults.swift. Stored in Zephydian's own preferences.

import AppKit

enum DefaultsKey {
    static let liquidGlassEnabled = "liquidGlassEnabled"
    static let systemShortcutsSuppressed = "systemShortcutsSuppressed"
    static let systemShortcutTakeOverKeys = "systemShortcutTakeOverKeys"
    static let switcherNativeHotkeysSuppressed = "switcherNativeHotkeysSuppressed"
    static let dockPreviewCurrentSpaceOnly = "dockPreviewCurrentSpaceOnly"
    static let finderCutPasteEnabled = "finderCutPasteEnabled"
    static let finderCutPasteShowHUD = "finderCutPasteShowHUD"
    static let finderPasteImageAsFile = "finderPasteImageAsFile"
    static let finderRenameEnabled = "finderRenameEnabled"
    static let finderRenameShortcut = "finderRenameShortcut"
    static let minimalWindowPreviews = "minimalWindowPreviews"
    static let switcherAppearanceDelay = "switcherAppearanceDelay"
    static let switcherAppRules = "switcherAppRules"
    static let switcherCurrentDisplayOnly = "switcherCurrentDisplayOnly"
    static let switcherCurrentSpaceOnly = "switcherCurrentSpaceOnly"
    static let switcherEnabled = "switcherEnabled"
    static let switcherIconRowMode = "switcherIconRowMode"
    static let switcherInstantSelection = "switcherInstantSelection"
    static let switcherMergeTabs = "switcherMergeTabs"
    static let switcherMinimizedPlacement = "switcherMinimizedPlacement"
    static let switcherPreviewExcludedApps = "switcherPreviewExcludedApps"
    static let switcherPreviewSize = "switcherPreviewSize"
    static let switcherScreenPlacement = "switcherScreenPlacement"
    static let switcherSearchPinEnabled = "switcherSearchPinEnabled"
    static let switcherShortcut = "switcherShortcut"
    static let switcherShowFullscreenWindows = "switcherShowFullscreenWindows"
    static let switcherShowShortcutHints = "switcherShowShortcutHints"
    static let switcherSimpleMode = "switcherSimpleMode"
    static let switcherTakeOverSystemShortcuts = "switcherTakeOverSystemShortcuts"
    static let switcherTreatHiddenAppsLikeMinimized = "switcherTreatHiddenAppsLikeMinimized"
    static let switcherWindowlessApps = "switcherWindowlessApps"
    static let switcherWindowShortcut = "switcherWindowShortcut"

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.finderCutPasteEnabled: true,   // Zephydian: on (the Features page switch turns Finder Shortcuts on or off)
        DefaultsKey.liquidGlassEnabled: false,
        DefaultsKey.dockPreviewCurrentSpaceOnly: false,
        DefaultsKey.finderCutPasteShowHUD: true,
        DefaultsKey.finderPasteImageAsFile: true,   // Zephydian: on (the Features page switch turns Finder Shortcuts on or off)
        DefaultsKey.finderRenameEnabled: true,   // Zephydian: on (the Features page switch turns Finder Shortcuts on or off)
        DefaultsKey.finderRenameShortcut: GlobalShortcut.finderRenameDefault.storageValue,
        DefaultsKey.minimalWindowPreviews: false,
        DefaultsKey.switcherAppearanceDelay: SwitcherSupport.defaultAppearanceDelayMilliseconds,
        DefaultsKey.switcherAppRules: [String: String](),
        DefaultsKey.switcherCurrentDisplayOnly: false,
        DefaultsKey.switcherCurrentSpaceOnly: false,
        DefaultsKey.switcherEnabled: true,
        DefaultsKey.switcherIconRowMode: false,
        DefaultsKey.switcherInstantSelection: false,
        DefaultsKey.switcherMergeTabs: false,
        DefaultsKey.switcherMinimizedPlacement: WindowSwitchMinimizedPlacement.normal.rawValue,
        DefaultsKey.switcherPreviewExcludedApps: [String](),
        DefaultsKey.switcherPreviewSize: "normal",
        DefaultsKey.switcherScreenPlacement: SwitcherScreenPlacement.fallback.rawValue,
        DefaultsKey.switcherSearchPinEnabled: false,
        DefaultsKey.switcherShortcut: "command:48",
        DefaultsKey.switcherShowFullscreenWindows: true,
        DefaultsKey.switcherShowShortcutHints: true,
        DefaultsKey.switcherSimpleMode: false,
        DefaultsKey.switcherTakeOverSystemShortcuts: true,   // Zephydian: on by default (its switcher replaces ⌘Tab out of the box)
        DefaultsKey.switcherTreatHiddenAppsLikeMinimized: true,
        DefaultsKey.switcherWindowlessApps: SwitcherWindowlessApps.fallback.rawValue,
        DefaultsKey.switcherWindowShortcut: GlobalShortcut.switcherWindowDefault.storageValue,
    ]
}

// From Vorssaint's Core/Defaults.swift (only the parts used here).
enum PreviewSizing {
    static func sanitized(_ value: String) -> String {
        Defaults.allowedPreviewSizes.contains(value) ? value : "normal"
    }

    static func scale(for value: String) -> CGFloat {
        switch sanitized(value) {
        case "small": return 0.75
        case "large": return 1.4
        case "xlarge": return 1.8
        default: return 1.0
        }
    }

    /// Dock previews' size (the copied Dock preview geometry helpers read it; Zephydian's own Dock
    /// Preview has its own setting, so this stays at its default).
    static var scale: CGFloat { scale(for: "normal") }

    static var switcherScale: CGFloat {
        scale(for: UserDefaults.standard.string(forKey: DefaultsKey.switcherPreviewSize) ?? "normal")
    }
}

enum Defaults {
    static let finderBundleIdentifier = "com.apple.finder"
    static let allowedPreviewSizes = ["small", "normal", "large", "xlarge"]

    static func sanitizedBundleIdentifierList(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in bundleIDs {
            // A mouse exception list also carries the path of a program that
            // has no bundle identifier (issue #1009), and a file name may
            // legally end in a space. Trimming one would store a spelling the
            // running program never reports, so only an identifier is trimmed.
            let bundleID = MouseAppExceptionSupport.isExecutablePathIdentity(raw)
                ? raw
                : raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty, !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            result.append(bundleID)
        }
        return result
    }
}

