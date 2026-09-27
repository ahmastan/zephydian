import SwiftUI

@main
struct ZephydianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Zephydian has no regular windows: everything lives in the floating panel,
        // which AppDelegate creates. SwiftUI requires at least one scene, so this is empty.
        Settings { EmptyView() }
    }
}
