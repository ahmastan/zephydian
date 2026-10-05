import AppKit
import SwiftUI

/// App names and icons from bundle IDs, for the apps lists in Settings.
enum AppNames {
    static func name(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @ViewBuilder static func icon(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "app")
        }
    }

    /// Open apps (with a Dock icon) not in `excluded`, by name.
    static func running(excluding excluded: [String]) -> [String] {
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap(\.bundleIdentifier)
        return Array(Set(ids).subtracting(excluded)).sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }
}
