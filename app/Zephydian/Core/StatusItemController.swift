import AppKit

/// The icon in the menu bar. Left-click toggles the panel; right-click shows a small menu.
final class StatusItemController: NSObject {
    var onToggle: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("Zephydian")
    }

    func apply(icon: MenuBarIcon) {
        statusItem.isVisible = icon != .hidden
        statusItem.button?.image = icon.menuBarImage
    }

    func setHighlighted(_ highlighted: Bool) {
        statusItem.button?.highlight(highlighted)
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            onToggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Zephydian", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Zephydian", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // restore left-click behavior
    }

    @objc private func openPanel() { onToggle() }
    @objc private func openSettings() { onOpenSettings() }
}
