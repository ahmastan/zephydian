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

    private var icon: MenuBarIcon?
    private var serviceColor: NSColor?

    /// While a utility's background service runs (keep awake…), the jet takes the accent color.
    /// The menu bar always draws template images in its own color (tints are ignored), so the jet
    /// is swapped for a colored copy, and the template comes back when the last service stops.
    func setServiceActive(_ active: Bool, color: NSColor) {
        serviceColor = active ? color : nil
        statusItem.button?.setAccessibilityLabel(active ? "Zephydian, a utility is running" : "Zephydian")
        updateImage()
    }

    func apply(icon: MenuBarIcon) {
        self.icon = icon
        statusItem.isVisible = icon != .hidden
        updateImage()
    }

    private func updateImage() {
        guard let template = icon?.menuBarImage else { statusItem.button?.image = nil; return }
        guard let color = serviceColor else { statusItem.button?.image = template; return }
        // Drawn when shown, so the accent's light or dark shade follows the menu bar's look.
        let colored = NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        colored.isTemplate = false
        colored.accessibilityDescription = template.accessibilityDescription
        statusItem.button?.image = colored
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
