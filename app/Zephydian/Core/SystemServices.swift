import Foundation
import ServiceManagement

/// Start Zephydian automatically when you log in (uses macOS's built-in login item service).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Reads macOS's own Hot Corners setting so we can warn about clashes.
enum HotCorners {
    static func hasSystemAction(at corner: Corner) -> Bool {
        let key = "wvous-\(corner.rawValue)-corner" as CFString
        guard let action = CFPreferencesCopyAppValue(key, "com.apple.dock" as CFString) as? Int else { return false }
        return action > 1 // 0 and 1 both mean "no action"
    }
}
