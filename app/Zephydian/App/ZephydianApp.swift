import SwiftUI

@main
struct ZephydianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Zephydian has no regular windows: everything lives in the floating panel,
        // which AppDelegate creates. SwiftUI requires at least one scene, so this is empty.
        Settings { EmptyView() }
            .commands {
                // The menu bar only shows while a utility's window is open (Zephydian is then in the
                // Dock). Settings… opens the panel's Settings tab instead of an empty window.
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openSettings() }
                        .keyboardShortcut(",")
                }
                CommandGroup(replacing: .newItem) {}
            }
    }
}
