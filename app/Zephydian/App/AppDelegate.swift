import AppKit
import Observation

/// Creates and connects the app's pieces: settings, the panel, the menu bar icon and the corner trigger.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let model = AppModel()
    private let notes = NotesStore()
    private let mouse = MouseMonitor()
    private let hotKey = GlobalHotKey()
    private var registeredShortcut: GlobalShortcut?
    private var panel: PanelController!
    private var statusItem: StatusItemController!
    private var cornerTrigger: CornerTrigger!

    func applicationDidFinishLaunching(_ notification: Notification) {
        notes.load()
        panel = PanelController(settings: settings, model: model, notes: notes)
        statusItem = StatusItemController()
        cornerTrigger = CornerTrigger(settings: settings) { [weak self] in
            guard let self, !self.model.isOnboarding else { return }
            self.panel.toggle()
        }

        statusItem.onToggle = { [weak self] in
            guard let self, !self.model.isOnboarding else { return }
            self.panel.toggle()
        }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        panel.onVisibilityChange = { [weak self] open in
            self?.statusItem.setHighlighted(open)
            // Only watch the mouse while the panel is open (for auto-hide). Closed = zero mouse work.
            if open { self?.mouse.start() } else { self?.mouse.stop() }
        }

        model.closePanel = { [weak self] in self?.panel.hide() }
        model.startOnboarding = { [weak self] in self?.panel.showOnboarding() }
        model.finishOnboarding = { [weak self] in self?.panel.finishOnboarding() }

        mouse.onMove = { [weak self] point in self?.panel.mouseMoved(to: point) }

        // Packs: an update waits while its game is on screen, and installs as soon as you leave it.
        let packs = PackManager.shared
        packs.isInUse = { [weak self] id in self?.model.isShowingGame == true && self?.model.gameID == id }
        packs.didChange = { [weak self] in
            self?.model.discardHiddenPackSession()
            PackLibrary.shared.refresh()
        }
        model.gameDidClose = { id in packs.packClosed(id) }
        PackLibrary.shared.refresh()
        packs.scheduleDailyCheck()

        hotKey.onPress = { [weak self] in
            guard let self, !self.model.isOnboarding else { return }
            self.panel.toggle()
        }

        applySettings()
        observeSettings()

        if !settings.hasCompletedOnboarding {
            panel.showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        notes.flush()
    }

    /// Launching Zephydian again while it's running (e.g. from Finder or Spotlight) opens Settings.
    /// This is the way back in if the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func openSettings() {
        guard !model.isOnboarding else { return }
        model.tab = .settings
        panel.show()
    }

    private func applySettings() {
        statusItem.apply(icon: settings.menuBarIcon)
        cornerTrigger.reposition()
        panel.applyAppearance()
        panel.applyMaterial()
        panel.reposition()
        if settings.globalShortcut != registeredShortcut {
            registeredShortcut = settings.globalShortcut
            model.shortcutAvailable = hotKey.register(settings.globalShortcut)
        }
    }

    /// Re-applies settings that affect AppKit objects whenever they change.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.menuBarIcon
            _ = settings.appearance
            _ = settings.corner
            _ = settings.displayName
            _ = settings.panelStyle
            _ = settings.globalShortcut
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applySettings()
                self?.observeSettings()
            }
        }
    }
}
