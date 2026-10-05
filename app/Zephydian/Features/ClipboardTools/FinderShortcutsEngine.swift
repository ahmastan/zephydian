// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zephydian contributors

import AppKit
import ApplicationServices
import SwitcherKit

/// Finder Shortcuts: ⌘X then ⌘V moves files, a rename shortcut (F2), and ⌘V with an image on the
/// clipboard saves it as a file. The work is Vorssaint's Finder cut and paste and rename (in SwitcherKit).
final class FinderShortcutsEngine: FeatureEngine {
    func start() {
        SwitcherKit.setFeature(.finderCutPaste, on: true)
        SwitcherKit.setFeature(.finderRename, on: true)
    }

    func stop() {
        SwitcherKit.setFeature(.finderCutPaste, on: false)
        SwitcherKit.setFeature(.finderRename, on: false)
    }
}

/// Talks to Finder with Apple Events (macOS asks once whether Zephydian may control Finder), off the
/// main thread: waiting on Finder must never hold up the main thread, which also answers keyboard taps.
nonisolated enum FinderEvents {
    /// A new target each time (descriptors aren't safe to share between threads).
    private static var finder: NSAppleEventDescriptor { NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder") }

    /// Asks Finder to empty the Trash (its own sounds and progress), without waiting.
    static func emptyTrash() {
        Task.detached(priority: .userInitiated) {
            let event = NSAppleEventDescriptor(eventClass: fourCharCode("fndr"), eventID: fourCharCode("empt"),
                                               targetDescriptor: finder, returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            // The direct object is the application's "trash" property.
            let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: DescType(typeObjectSpecifier))!
            specifier.setDescriptor(NSAppleEventDescriptor(typeCode: DescType(typeProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
            specifier.setDescriptor(NSAppleEventDescriptor(enumCode: DescType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
            specifier.setDescriptor(NSAppleEventDescriptor(typeCode: fourCharCode("trsh")), forKeyword: AEKeyword(keyAEKeyData))
            specifier.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
            event.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
            _ = try? event.sendEvent(options: [.noReply, .canInteract], timeout: 2)
        }
    }

    private static func fourCharCode(_ text: String) -> DescType {
        text.utf8.reduce(0) { ($0 << 8) | DescType($1) }
    }
}
