// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 Zephydian contributors
// Written for Zephydian on 2026-10-05; contains parts copied from vorssaint/vorssaint-utils, commit 04abae3, marked where they appear.

// Zephydian: the small pieces of Vorssaint's app that the copied switcher and Finder cut and paste
// expect (its permission cache and feature switches), backed by Zephydian instead, plus the public
// entry points Zephydian calls. Written for Zephydian; GPL-3.0-or-later like the rest of SwitcherKit.

import AppKit

/// Which of these features Zephydian has switched on (its Features page).
enum AppFeature: Hashable {
    case switcher, finderCutPaste, finderRename, windowLayout

    var isAvailable: Bool { SwitcherKit.enabledFeatures.contains(self) }
}

/// Zephydian's permission state, cached (a live check per key press would be too slow).
final class Permissions: ObservableObject {
    static let shared = Permissions()
    @Published var accessibility = AXIsProcessTrusted()
    @Published var screenRecording = CGPreflightScreenCaptureAccess()
}

public enum SwitcherKit {
    static var enabledFeatures: Set<AppFeature> = []

    /// Call once at launch, before anything reads the settings.
    public static func registerDefaults() {
        UserDefaults.standard.register(defaults: DefaultsKey.registeredDefaults)
    }

    /// Zephydian's permissions changed (or were re-read).
    public static func setPermissions(accessibility: Bool, screenRecording: Bool) {
        if Permissions.shared.accessibility != accessibility { Permissions.shared.accessibility = accessibility }
        if Permissions.shared.screenRecording != screenRecording { Permissions.shared.screenRecording = screenRecording }
    }
}

/// Vorssaint tells its Quit on Close feature when the switcher closes a window; Zephydian's own
/// Quit on Close can listen here.
final class AutoQuitService {
    static let shared = AutoQuitService()
    func recordProgrammaticCloseRequest(pid: pid_t) { SwitcherKit.onProgrammaticClose?(pid) }
}

extension SwitcherKit {
    /// Called when the switcher closes another app's window (W, or a middle click).
    nonisolated(unsafe) public static var onProgrammaticClose: ((pid_t) -> Void)?
}

/// The app's name, where the copied code shows Zephydian's own windows.
enum AppInfo {
    static let name = "Zephydian"
}

// From Vorssaint's Services/ShellSupport.swift (only AppleScriptRunner).
/// Sends Apple Events to another app IN-PROCESS (via NSAppleScript) instead of
/// spawning `osascript`. The Automation consent is then attributed to THIS app —
/// so it stays granted across updates, is re-requested if it was lost, and the
/// first-run consent prompt is never killed by a watchdog. It is the same
/// per-target Automation permission the features already required; nothing new is
/// requested. Call these OFF the main thread, so a slow target never blocks the
/// UI or the event taps (the calls block their thread until the target replies).
enum AppleScriptRunner {
    /// True when this app may script `bundleID`. Undetermined → shows the system
    /// prompt (attributed to this app); granted → returns at once; denied →
    /// false without nagging.
    @discardableResult
    static func consentToAutomate(bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let created = bundleID.withCString { ptr in
            AECreateDesc(typeApplicationBundleID, ptr, bundleID.utf8.count, &target)
        }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true) == noErr
    }

    /// Runs the AppleScript in this process. Returns whether it succeeded and the
    /// result string (or the error message on failure). Sending the event in
    /// process itself triggers the Automation prompt when consent is undetermined.
    @discardableResult
    static func run(_ source: String) -> (ok: Bool, output: String) {
        let result = runDetailed(source)
        return (result.ok, result.ok ? result.output : result.message)
    }

    /// Same as `run`, keeping the AppleScript error number so callers can tell
    /// a declined Automation consent (-1743/-1744) apart from a real failure.
    @discardableResult
    static func runDetailed(_ source: String) -> (ok: Bool, errorNumber: Int?, message: String, output: String) {
        guard let script = NSAppleScript(source: source) else { return (false, nil, "", "") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            return (false,
                    error[NSAppleScript.errorNumber] as? Int,
                    (error[NSAppleScript.errorMessage] as? String) ?? "",
                    "")
        }
        return (true, nil, "", result.stringValue ?? "")
    }

    /// Escapes a value for embedding inside an AppleScript double-quoted string.
    static func literal(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// From Vorssaint's Core/Permissions.swift (only the Automation check).
extension Permissions {
    enum AutomationTarget: String, CaseIterable {
        case finder = "com.apple.finder"
        case terminal = "com.apple.Terminal"
    }

    enum AutomationStatus {
        case granted, denied, undetermined, notDeterminable
    }

    /// Never prompts (askUserIfNeeded false). A target that is not running
    /// cannot be checked and reads as notDeterminable. Call off the main
    /// thread; the check can block briefly.
    static func automationStatus(for target: AutomationTarget) -> AutomationStatus {
        var descriptor = AEAddressDesc()
        let bundleID = target.rawValue
        let created = bundleID.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, bundleID.utf8.count, &descriptor)
        }
        guard created == noErr else { return .notDeterminable }
        defer { AEDisposeDesc(&descriptor) }
        switch AEDeterminePermissionToAutomateTarget(&descriptor, typeWildCard, typeWildCard, false) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .undetermined
        default: return .notDeterminable
        }
    }
}

/// Vorssaint's switcher asks its Quit Protection before W closes or Q quits from the switcher.
/// Zephydian's own Quit Protection is separate, so these never ask (W and Q act at once).
enum QuitProtectionShortcut { case quit, close }

struct QuitProtectionSelectionConfirmation {
    let showsFeedback: Bool
    let intervalMilliseconds: Double
}

final class QuitProtectionService {
    static let shared = QuitProtectionService()
    func selectionConfirmation(for shortcut: QuitProtectionShortcut,
                               bundleIdentifier: String?) -> QuitProtectionSelectionConfirmation? { nil }
    func showSelectionHUD(for shortcut: QuitProtectionShortcut, on screen: NSScreen?) {}
    func hideSelectionHUD() {}
}

// From Vorssaint's Services/QuickTools/ScreenshotCaptureEngine.swift.
extension NSScreen {
    /// The CoreGraphics display id behind this screen; 0 when missing, which
    /// callers treat as not capturable.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - What Zephydian calls

public extension SwitcherKit {
    enum Feature: Sendable { case switcher, finderCutPaste, finderRename }

    /// At launch, before any feature starts: gives back macOS shortcuts a crashed earlier run may
    /// still hold (keeping the ones the switcher is about to take again).
    static func launch() {
        registerDefaults()
        SystemShortcutTakeover.recoverIfNeeded(keeping: AppSwitcher.launchTakeoverIDs())
    }

    /// Zephydian's Features page switched one on or off (or its permissions changed).
    static func setFeature(_ feature: Feature, on: Bool) {
        let mapped: AppFeature = switch feature {
        case .switcher: .switcher
        case .finderCutPaste: .finderCutPaste
        case .finderRename: .finderRename
        }
        if on { enabledFeatures.insert(mapped) } else { enabledFeatures.remove(mapped) }
        sync(feature)
    }

    /// A setting of the feature changed: apply it.
    static func sync(_ feature: Feature) {
        switch feature {
        case .switcher:
            WindowUseTracker.shared.syncWithFeatures()
            AppSwitcher.shared.syncWithPreferences()
        case .finderCutPaste:
            FinderCutPaste.shared.syncWithPreferences()
        case .finderRename:
            FinderRenameService.shared.syncWithPreferences()
        }
    }

    /// A shortcut field started or stopped recording: every key must reach it meanwhile.
    static func setRecordingShortcut(_ recording: Bool) {
        AppSwitcher.shared.setCapturingShortcut(recording)
    }

    /// At quit: stops the listeners and gives every macOS shortcut back.
    static func terminate() {
        AppSwitcher.shared.suspend()
        FinderCutPaste.shared.suspend()
        FinderRenameService.shared.suspend()
        SystemShortcutTakeover.restoreAll()
    }

    /// Whether the switcher has taken over one of macOS's shortcuts (for the Settings page).
    static func isTakenOver(_ storageKey: String) -> Bool { SystemShortcutTakeover.isTakenOver(storageKey) }
    static func setTakeOver(_ storageKey: String, _ on: Bool) { SystemShortcutTakeover.setTakeOver(storageKey, on) }

    /// The settings keys, for Zephydian's Settings pages.
    enum Keys {
        public static let switcherEnabled = DefaultsKey.switcherEnabled
        public static let switcherShortcut = DefaultsKey.switcherShortcut
        public static let switcherWindowShortcut = DefaultsKey.switcherWindowShortcut
        public static let switcherTakeOverSystemShortcuts = DefaultsKey.switcherTakeOverSystemShortcuts
        public static let switcherAppearanceDelay = DefaultsKey.switcherAppearanceDelay
        public static let switcherAppRules = DefaultsKey.switcherAppRules
        public static let switcherCurrentDisplayOnly = DefaultsKey.switcherCurrentDisplayOnly
        public static let switcherCurrentSpaceOnly = DefaultsKey.switcherCurrentSpaceOnly
        public static let switcherIconRowMode = DefaultsKey.switcherIconRowMode
        public static let switcherInstantSelection = DefaultsKey.switcherInstantSelection
        public static let switcherMergeTabs = DefaultsKey.switcherMergeTabs
        public static let switcherMinimizedPlacement = DefaultsKey.switcherMinimizedPlacement
        public static let switcherPreviewExcludedApps = DefaultsKey.switcherPreviewExcludedApps
        public static let switcherPreviewSize = DefaultsKey.switcherPreviewSize
        public static let switcherScreenPlacement = DefaultsKey.switcherScreenPlacement
        public static let switcherSearchPinEnabled = DefaultsKey.switcherSearchPinEnabled
        public static let switcherShowFullscreenWindows = DefaultsKey.switcherShowFullscreenWindows
        public static let switcherShowShortcutHints = DefaultsKey.switcherShowShortcutHints
        public static let switcherSimpleMode = DefaultsKey.switcherSimpleMode
        public static let switcherTreatHiddenAppsLikeMinimized = DefaultsKey.switcherTreatHiddenAppsLikeMinimized
        public static let switcherWindowlessApps = DefaultsKey.switcherWindowlessApps
        public static let minimalWindowPreviews = DefaultsKey.minimalWindowPreviews
        public static let finderCutPasteEnabled = DefaultsKey.finderCutPasteEnabled
        public static let finderCutPasteShowHUD = DefaultsKey.finderCutPasteShowHUD
        public static let finderPasteImageAsFile = DefaultsKey.finderPasteImageAsFile
        public static let finderRenameEnabled = DefaultsKey.finderRenameEnabled
        public static let finderRenameShortcut = DefaultsKey.finderRenameShortcut
        public static let liquidGlassEnabled = DefaultsKey.liquidGlassEnabled
    }
}
