import AppKit
import Carbon.HIToolbox
import Observation
import UserNotifications
import SwitcherKit

/// Creates and connects the app's pieces: settings, the panel, the menu bar icon and the corner trigger.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings: SettingsStore
    private let model: AppModel
    private let notes: NotesStore
    private let mouse = MouseMonitor()
    private let hotKey = GlobalHotKey()
    private var registeredShortcut: KeyShortcut??
    private var panel: PanelController!
    private var noteWindows: NoteWindows!
    private var notesWindow: NotesWindowController!
    private var settingsWindow: SettingsWindowController!
    private var statusItem: StatusItemController!
    private var cornerTrigger: CornerTrigger!
    private let notificationPresenter = NotificationPresenter()
    /// The result of bringing data over from the old sandbox container (first launch only).
    private let storageMove: StorageMove.Outcome

    override init() {
        // Before anything reads settings or files: they may still be in the old sandbox container.
        storageMove = StorageMove.runIfNeeded()
        settings = SettingsStore()
        model = AppModel()
        notes = NotesStore()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The switcher's settings, and any macOS shortcut a crashed run left switched off, before any feature starts.
        SwitcherKit.launch()
        if case .failed(let message) = storageMove { StorageMove.reportFailure(message) }
        notes.load()
        panel = PanelController(settings: settings, model: model, notes: notes)
        noteWindows = NoteWindows(notes: notes, settings: settings)
        noteWindows.start()   // pinned notes float again where they were left
        notesWindow = NotesWindowController(settings: settings, model: model, notes: notes)
        model.detachNotes = { [weak self] in self?.notesWindow.detach() }
        model.showNotesWindow = { [weak self] in self?.notesWindow.show() }
        model.attachNotes = { [weak self] in self?.notesWindow.attach() }
        notesWindow.restore()   // Notes left in their own window open there again
        noteWindows.onSearch = { [weak self] in
            guard let self, !self.model.isOnboarding else { return }
            if self.settings.notesDetached {
                self.notesWindow.show()
                self.model.isSearchingNotes = true
                return
            }
            if self.model.isShowingGame { self.model.closeGame() }
            self.model.closeLibrary()
            self.model.tab = .notes
            self.model.isSearchingNotes = true
            self.panel.show()
        }
        statusItem = StatusItemController()
        cornerTrigger = CornerTrigger(settings: settings) { [weak self] in
            guard let self, !self.model.isOnboarding else { return }
            self.panel.toggle()
        }
        // The Shelf set to open in the corner panel: it appears as soon as a drag starts.
        ShelfEngine.showInPanel = { [weak self] in
            guard let self, !self.model.isOnboarding else { return }
            self.model.openShelf()
            self.panel.show()
        }
        ShelfEngine.closePanel = { [weak self] unlessInside in
            guard let self, self.model.isShowingShelf else { return }
            if unlessInside, self.panel.containsPointer { return }
            self.panel.hide()
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
        model.showPanel = { [weak self] in self?.panel.show() }
        settingsWindow = SettingsWindowController(settings: settings, model: model, notes: notes)
        model.openSettingsWindow = { [weak self] raw in self?.settingsWindow.show(raw.flatMap(SettingsSelection.init(rawValue:))) }
        model.startOnboarding = { [weak self] in self?.panel.showOnboarding() }
        model.finishOnboarding = { [weak self] in self?.panel.finishOnboarding() }

        mouse.onMove = { [weak self] point in self?.panel.mouseMoved(to: point) }

        // Packs: an update waits while its game is on screen, and installs as soon as you leave it.
        let packs = PackManager.shared
        packs.isInUse = { [weak self] id in self?.model.isShowingGame == true && self?.model.gameID == id }
        packs.didChange = { [weak self] in
            self?.offerCaptureShortcut()
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
            // A capture utility's shortcut opens the capture bar straight away (or stops a recording).
            if PackLibrary.shared.packs.first(where: { $0.id == id })?.manifest.capabilities?.contains("screen.capture") == true {
                services.capture.openBar(packID: id)   // the capture bar (19.10)
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
            (self.model.gameSession as? PackSession)?.shortcutPressed()
        }
        // A screenshot's Edit button opens the installed image editor (Markup) in its own window.
        services.imageEditor = { PackLibrary.shared.packs.first(where: \.isImageEditor)?.id }
        services.openInEditor = { packID, shotID in
            guard let bundle = PackLibrary.shared.packs.first(where: { $0.id == packID && $0.isImageEditor }),
                  let image = services.images.fromScreenshot(shotID, packID: packID) else { return }
            services.windows.open(bundle, input: PackRuntime.jsonString(["image": "image:\(image)"]))
        }
        services.restore(PackLibrary.shared.packs.filter { $0.kind == .utility })
        offerCaptureShortcut()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = notificationPresenter
        }

        hotKey.onPress = { [weak self] in
            guard let self, !self.model.isOnboarding else { return }
            self.panel.toggle()
        }

        applySettings()
        observeSettings()
        // Put back what features changed in macOS, if Zephydian stopped without doing it (a feature
        // that's on sets it again when it starts).
        SystemShortcuts.restore()   // macOS's ⌘Tab
        SuperKeyEngine.restore()    // the Caps Lock remapping
        PointerAccelerationEngine.restore()
        Features.shared.appSettings = settings
        CommandBarHooks.openSettings = { [weak self] page in self?.model.openSettingsWindow(page) }
        RadialActions.showPanel = { [weak self] in self?.panel.show() }
        CommandBarHooks.openUtility = { [weak self] id in
            guard let self, !self.model.isOnboarding else { return }
            self.model.closeLibrary()
            self.model.tab = .utilities
            self.model.openGame(id)
            self.panel.show()
        }
        Features.shared.start()     // only the features switched on, once their permissions are there
        // The System accent follows macOS's accent color as soon as it changes.
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings.systemAccentDidChange() }
        }

        if !settings.hasCompletedOnboarding {
            panel.showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Features.shared.stopAll()   // puts back anything a feature changed (⌘Tab, the Dock…)
        SwitcherKit.terminate()     // every macOS shortcut the switcher held goes back
        notes.flush()
    }

    /// Launching Zephydian again while it's running (e.g. from Finder or Spotlight) opens the Settings window.
    /// This is the way back in if the menu bar icon is hidden. While a utility's window is open (and
    /// Zephydian is in the Dock), clicking the Dock icon brings that window forward instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if PackServices.shared.windows.showAll() { return false }
        openSettings()
        return false
    }

    /// Capture (19.10) starts with ⇧⌘6, once, if the person hasn't chosen a shortcut for it.
    private func offerCaptureShortcut() {
        for pack in PackLibrary.shared.packs where pack.manifest.capabilities?.contains("screen.record") == true {
            PackServices.shared.shortcuts.offerDefault(packID: pack.id,
                                                       KeyShortcut(keyCode: UInt16(kVK_ANSI_6), modifiers: [.shift, .command], key: "6"))
        }
    }

    /// The Settings window (⌘, and the menu bar's Settings…).
    func openSettings() {
        guard !model.isOnboarding else { return }
        settingsWindow.show()
    }

    private func applySettings() {
        UserDefaults.standard.set(settings.usesGlass, forKey: SwitcherKit.Keys.liquidGlassEnabled)   // the cut-files panel's look
        statusItem.apply(icon: settings.menuBarIcon)
        statusItem.setServiceActive(PackServices.shared.colorsJet, color: settings.accentNSColor)
        cornerTrigger.reposition()
        panel.applyAppearance()
        settingsWindow?.applyAppearance()
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
            _ = settings.panelSize
            _ = settings.panelShortcut
            _ = settings.accent
            _ = settings.systemAccentRevision
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
