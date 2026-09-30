import AppKit
import Observation
import UserNotifications

/// Creates and connects the app's pieces: settings, the panel, the menu bar icon and the corner trigger.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let model = AppModel()
    private let notes = NotesStore()
    private let mouse = MouseMonitor()
    private let hotKey = GlobalHotKey()
    private var registeredShortcut: KeyShortcut??
    private var panel: PanelController!
    private var statusItem: StatusItemController!
    private var cornerTrigger: CornerTrigger!
    private let notificationPresenter = NotificationPresenter()

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

        // Utilities' background services come back as they were: timers, clipboard recording, shortcuts.
        let services = PackServices.shared
        services.settings = settings
        services.hidePanel = { [weak self] in self?.panel.hide() }
        services.shortcuts.onOpen = { [weak self] id in
            guard let self, !self.model.isOnboarding else { return }
            // A screenshot utility's shortcut takes an Area screenshot straight away.
            if PackLibrary.shared.packs.first(where: { $0.id == id })?.manifest.capabilities?.contains("screen.capture") == true {
                services.capture.capture(packID: id, mode: .area) { _, _ in }
                return
            }
            // Pressed again while that utility is showing: close the panel, like the main shortcut.
            if self.panel.isOpen && self.model.isShowingGame && self.model.gameID == id {
                self.panel.hide()
                return
            }
            self.model.closeLibrary()
            self.model.tab = .utilities
            self.model.openGame(id)
            self.panel.show()
        }
        // A screenshot's Edit button opens the installed image editor (Markup) in its own window.
        services.imageEditor = { PackLibrary.shared.packs.first(where: \.isImageEditor)?.id }
        services.openInEditor = { packID, shotID in
            guard let bundle = PackLibrary.shared.packs.first(where: { $0.id == packID && $0.isImageEditor }),
                  let image = services.images.fromScreenshot(shotID, packID: packID) else { return }
            services.windows.open(bundle, input: PackRuntime.jsonString(["image": "image:\(image)"]))
        }
        services.restore(PackLibrary.shared.packs.filter { $0.kind == .utility })
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = notificationPresenter
        }

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
    /// This is the way back in if the menu bar icon is hidden. While a utility's window is open (and
    /// Zephydian is in the Dock), clicking the Dock icon brings that window forward instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if PackServices.shared.windows.showAll() { return false }
        openSettings()
        return false
    }

    func openSettings() {
        guard !model.isOnboarding else { return }
        model.tab = .settings
        panel.show()
    }

    private func applySettings() {
        statusItem.apply(icon: settings.menuBarIcon)
        statusItem.setServiceActive(PackServices.shared.colorsJet, color: settings.accent.nsColor)
        cornerTrigger.reposition()
        panel.applyAppearance()
        PackServices.shared.windows.applyAppearance(settings.appearance.nsAppearance)
        panel.applyMaterial()
        panel.reposition()
        if registeredShortcut == nil || registeredShortcut! != settings.panelShortcut {
            registeredShortcut = .some(settings.panelShortcut)
            model.shortcutAvailable = hotKey.register(settings.panelShortcut)
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
            _ = settings.panelShortcut
            _ = settings.accent
            _ = PackServices.shared.colorsJet
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applySettings()
                self?.observeSettings()
            }
        }
    }
}

/// Shows timer notifications even while Zephydian is the active app (macOS hides them otherwise).
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
