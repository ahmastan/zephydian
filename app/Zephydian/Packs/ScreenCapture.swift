import AppKit
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screenshots for the `screen.capture` capability. Area and Window modes show Zephydian's own
/// selection overlay; the picture itself comes from ScreenCaptureKit, with Zephydian's windows
/// (panel, overlay, preview card) left out. macOS asks once for the Screen Recording permission.
/// After a capture a preview card offers Copy, Save, Edit and Close; if it's ignored, the shot is
/// copied. Shots are kept in memory for this session (the utility lists them); saved ones go to
/// Pictures/Screenshots or a folder the person chose.
final class ScreenCapture {
    enum Mode: String { case area, window, screen }

    struct Prefs: Codable, Equatable {
        var delay = 0              // seconds
        var pointer = false
        var sound = true
        var format = "png"         // or "jpeg"
        /// Copy every shot to the clipboard as soon as it's taken.
        var autoCopy = false

        init(delay: Int = 0, pointer: Bool = false, sound: Bool = true, format: String = "png", autoCopy: Bool = false) {
            self.delay = delay; self.pointer = pointer; self.sound = sound; self.format = format; self.autoCopy = autoCopy
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            delay = try c.decodeIfPresent(Int.self, forKey: .delay) ?? 0
            pointer = try c.decodeIfPresent(Bool.self, forKey: .pointer) ?? false
            sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
            format = try c.decodeIfPresent(String.self, forKey: .format) ?? "png"
            autoCopy = try c.decodeIfPresent(Bool.self, forKey: .autoCopy) ?? false
        }
    }

    struct Shot {
        let id: String
        /// Replaced by an edited copy when an image editor hands one back.
        var image: CGImage
        let date: Date
        var savedURL: URL?
        /// The screenshot utility that took it (its folder and format are used to save it).
        var packID: String?
    }

    private unowned let services: PackServices
    private(set) var shots: [Shot] = []
    private var busy = false
    private var overlay: SelectionOverlay?
    private var countdown: NSPanel?
    private var preview: ScreenshotPreview?
    private var thumbnails: [String: NSImage] = [:]

    init(services: PackServices) { self.services = services }

    // MARK: Permission

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows macOS's prompt the first time; after that, opens the Screen Recording settings.
    func requestPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Settings (kept here so the shortcut works without opening the utility)

    func prefs(_ packID: String) -> Prefs {
        services.defaults.data(forKey: "pack.\(packID).screenshot.prefs").flatMap { try? JSONDecoder().decode(Prefs.self, from: $0) } ?? Prefs()
    }

    func setPrefs(_ prefs: Prefs, packID: String) {
        services.defaults.set(try? JSONEncoder().encode(prefs), forKey: "pack.\(packID).screenshot.prefs")
    }

    // MARK: Folder

    /// Pictures/Screenshots in the person's home (the Pictures entitlement makes it reachable).
    static var defaultFolder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(filePath: home, directoryHint: .isDirectory).appending(path: "Pictures/Screenshots", directoryHint: .isDirectory)
    }

    /// The chosen folder (from its bookmark), or the default. `custom` is false for the default.
    func folder(_ packID: String) -> (url: URL, custom: Bool) {
        var stale = false
        if let data = services.defaults.data(forKey: "pack.\(packID).screenshot.folder"),
           let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                services.defaults.set(fresh, forKey: "pack.\(packID).screenshot.folder")
            }
            return (url, true)
        }
        return (Self.defaultFolder, false)
    }

    /// "Pictures/Screenshots" or "Documents/work-proof": the folder's path from the home folder.
    func folderLabel(_ packID: String) -> String {
        let url = folder(packID).url.standardizedFileURL.path
        let home = (Self.defaultFolder.deletingLastPathComponent().deletingLastPathComponent().path as NSString).standardizingPath
        return url.hasPrefix(home + "/") ? String(url.dropFirst(home.count + 1)) : url
    }

    func chooseFolder(packID: String, done: @escaping (Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where Screenshot saves your screenshots."
        panel.directoryURL = folder(packID).url
        panel.level = .statusBar + 1
        services.holdPanel()
        NSApp.activate()
        nonisolated(unsafe) let done = done
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                self?.services.releasePanel()
                guard response == .OK, let url = panel.url,
                      let data = try? url.bookmarkData(options: .withSecurityScope) else { return done(false) }
                self?.services.defaults.set(data, forKey: "pack.\(packID).screenshot.folder")
                done(true)
            }
        }
    }

    func resetFolder(packID: String) {
        services.defaults.removeObject(forKey: "pack.\(packID).screenshot.folder")
    }

    func openFolder(packID: String) {
        let (url, custom) = folder(packID)
        let scoped = custom && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: Capturing

    /// Hides the panel, lets the person pick (area or window), waits the delay, then captures.
    /// `done` gets the new shot's id, or nil if it was cancelled or failed (with a reason).
    func capture(packID: String, mode: Mode, done: @escaping (String?, String?) -> Void) {
        guard !busy else { return done(nil, "A screenshot is already in progress") }
        guard hasPermission else {
            requestPermission()
            return done(nil, "Allow Zephydian under Screen Recording in System Settings, then try again")
        }
        busy = true
        let prefs = prefs(packID)
        services.hidePanel()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))           // the panel's closing animation
            guard let self else { return }
            let result = await self.run(mode: mode, prefs: prefs)
            self.busy = false
            switch result {
            case .success(let image):
                if prefs.sound { Self.shutter() }
                let shot = Shot(id: String(UUID().uuidString.prefix(8)).lowercased(), image: image, date: Date(), packID: packID)
                self.shots.insert(shot, at: 0)
                if self.shots.count > 20 { self.forget(self.shots.removeLast().id) }
                self.services.changed()
                if prefs.autoCopy { _ = self.copy(shot.id) }
                self.showPreview(shot.id, packID: packID)
                done(shot.id, nil)
            case .failure(let error):
                done(nil, error.description)
            }
        }
    }

    struct Failure: Error { let description: String }

    private func run(mode: Mode, prefs: Prefs) async -> Result<CGImage, Failure> {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) } catch {
            return .failure(Failure(description: "Screen Recording isn't allowed for Zephydian"))
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        switch mode {
        case .screen:
            guard let (display, screen) = Self.display(at: NSEvent.mouseLocation, in: content) else { return .failure(Failure(description: "No display found")) }
            await wait(prefs.delay, on: screen)
            return await shoot(SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
                               rect: nil, size: screen.frame.size, scale: screen.backingScaleFactor, prefs: prefs)
        case .area:
            guard let rect = await pickArea() else { return .failure(Failure(description: "")) }
            guard let (display, screen) = Self.display(at: NSPoint(x: rect.midX, y: rect.midY), in: content) else { return .failure(Failure(description: "No display found")) }
            await wait(prefs.delay, on: screen)
            // The selection in the display's own top-left coordinates, in points.
            let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            return await shoot(SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
                               rect: local, size: rect.size, scale: screen.backingScaleFactor, prefs: prefs)
        case .window:
            // Front-most first, in the order macOS stacks them, so the highlighted window is the one you see.
            let order = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [])
                .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let windows = content.windows.filter { $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width > 40 && $0.frame.height > 30
                && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }
                .sorted { (rank[$0.windowID] ?? .max) < (rank[$1.windowID] ?? .max) }
            guard let window = await pickWindow(windows) else { return .failure(Failure(description: "")) }
            let screen = NSScreen.screens.first { $0.frame.contains(Self.cocoaPoint(CGPoint(x: window.frame.midX, y: window.frame.midY))) } ?? NSScreen.main!
            await wait(prefs.delay, on: screen)
            return await shoot(SCContentFilter(desktopIndependentWindow: window), rect: nil, size: window.frame.size,
                               scale: screen.backingScaleFactor, prefs: prefs)
        }
    }

    private func shoot(_ filter: SCContentFilter, rect: CGRect?, size: CGSize, scale: CGFloat, prefs: Prefs) async -> Result<CGImage, Failure> {
        let config = SCStreamConfiguration()
        if let rect { config.sourceRect = rect }
        config.width = max(1, Int(size.width * scale))
        config.height = max(1, Int(size.height * scale))
        config.showsCursor = prefs.pointer
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false
        do {
            return .success(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config))
        } catch {
            return .failure(Failure(description: "The screenshot failed: \(error.localizedDescription)"))
        }
    }

    // MARK: Picking

    /// The person's accent color (the crosshair, the selection and window highlight use it).
    private var accent: NSColor { services.settings?.accent.nsColor ?? .controlAccentColor }

    private func pickArea() async -> CGRect? {
        await withCheckedContinuation { continuation in
            overlay = SelectionOverlay(mode: .area, windows: [], accent: accent) { [weak self] result in
                self?.overlay = nil
                continuation.resume(returning: result.area)
            }
        }
    }

    private func pickWindow(_ windows: [SCWindow]) async -> SCWindow? {
        let targets = windows.map { ($0.windowID, Self.cocoaRect($0.frame)) }
        let picked: CGWindowID? = await withCheckedContinuation { continuation in
            overlay = SelectionOverlay(mode: .window, windows: targets, accent: accent) { [weak self] result in
                self?.overlay = nil
                continuation.resume(returning: result.windowID)
            }
        }
        return picked.flatMap { id in windows.first { $0.windowID == id } }
    }

    /// A small countdown in the middle of the screen (left out of the picture like every Zephydian window).
    private func wait(_ seconds: Int, on screen: NSScreen) async {
        guard seconds > 0 else { return }
        let size = NSSize(width: 96, height: 96)
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: screen.frame.midX - 48, y: screen.frame.midY - 48), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 48, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        box.layer?.cornerRadius = 22
        label.frame = NSRect(x: 0, y: 18, width: 96, height: 60)
        box.addSubview(label)
        panel.contentView = box
        panel.orderFrontRegardless()
        countdown = panel
        for n in stride(from: seconds, to: 0, by: -1) {
            label.stringValue = "\(n)"
            try? await Task.sleep(for: .seconds(1))
        }
        panel.orderOut(nil)
        countdown = nil
        try? await Task.sleep(for: .milliseconds(80))
    }

    // MARK: Shots

    func shot(_ id: String) -> Shot? { shots.first { $0.id == id } }

    /// Adds an image to this session's shots without capturing (tests). Returns its id.
    @discardableResult
    func keep(_ image: CGImage, packID: String? = nil) -> String {
        let shot = Shot(id: String(UUID().uuidString.prefix(8)).lowercased(), image: image, date: Date(), packID: packID)
        shots.insert(shot, at: 0)
        if shots.count > 20 { forget(shots.removeLast().id) }
        services.changed()
        return shot.id
    }

    /// An image editor hands back the edited picture: copying, saving and the list use it from now on.
    func replace(_ id: String, with image: CGImage) {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return }
        shots[i].image = image
        thumbnails[id] = nil
        services.changed()
    }

    func thumbnail(_ id: String) -> NSImage? {
        if let cached = thumbnails[id] { return cached }
        guard let shot = shot(id) else { return nil }
        let image = NSImage(cgImage: shot.image, size: NSSize(width: shot.image.width, height: shot.image.height))
        thumbnails[id] = image
        return image
    }

    func data(_ id: String, format: String) -> Data? {
        guard let shot = shot(id) else { return nil }
        let rep = NSBitmapImageRep(cgImage: shot.image)
        return format == "jpeg" ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                                : rep.representation(using: .png, properties: [:])
    }

    func copy(_ id: String) -> Bool {
        guard let png = data(id, format: "png") else { return false }
        PackNative.copyImage(png)
        return true
    }

    /// Saves into the folder, as "Screenshot 2026-09-29 at 14.05.12.png", and returns the file's name.
    /// A shot that was saved before (and edited since) replaces its file instead.
    func save(_ id: String, packID: String) -> String? {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return nil }
        let (folder, custom) = folder(packID)
        let scoped = custom && folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        if let existing = shots[i].savedURL, FileManager.default.fileExists(atPath: existing.path) {
            let format = ["jpg", "jpeg"].contains(existing.pathExtension.lowercased()) ? "jpeg" : "png"
            let scopedFile = !scoped && existing.startAccessingSecurityScopedResource()
            defer { if scopedFile { existing.stopAccessingSecurityScopedResource() } }
            guard let data = data(id, format: format), (try? data.write(to: existing, options: .atomic)) != nil else { return nil }
            services.changed()
            return existing.lastPathComponent
        }
        let format = prefs(packID).format
        guard let data = data(id, format: format) else { return nil }
        let stamp = shots[i].date.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + " at "
            + shots[i].date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)).replacingOccurrences(of: ":", with: ".")
        var url = folder.appending(path: "Screenshot \(stamp).\(format == "jpeg" ? "jpg" : "png")")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "Screenshot \(stamp) (\(n)).\(format == "jpeg" ? "jpg" : "png")")
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        shots[i].savedURL = url
        services.changed()
        return url.lastPathComponent
    }

    /// Save as…: asks where, in the chosen format.
    func saveAs(_ id: String, packID: String, done: @escaping (Bool) -> Void) {
        let format = prefs(packID).format
        guard let data = data(id, format: format) else { return done(false) }
        PackNative.save(name: "Screenshot.\(format == "jpeg" ? "jpg" : "png")", data: data, done: done)
    }

    /// Forgets a shot; if it was saved, its file goes to the Trash.
    func delete(_ id: String) {
        if let url = shot(id)?.savedURL { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        forget(id)
        services.changed()
    }

    private func forget(_ id: String) {
        shots.removeAll { $0.id == id }
        thumbnails[id] = nil
        if preview?.shotID == id { preview?.close() }
    }

    // MARK: Preview card

    private func showPreview(_ id: String, packID: String) {
        preview?.close()
        guard let image = thumbnail(id) else { return }
        let editor = services.imageEditor()
        preview = ScreenshotPreview(shotID: id, image: image, canEdit: editor != nil, settings: services.settings) { [weak self] action in
            guard let self else { return }
            switch action {
            case .copy, .timeout: _ = self.copy(id)
            case .save: _ = self.save(id, packID: packID)
            case .edit: if let editor { self.services.openInEditor(editor, id) }
            case .delete:
                self.preview = nil                              // already closing; don't close it twice
                self.delete(id)
                return
            case .close: break
            }
            self.preview = nil
        }
    }

    func removeData(packID: String) {
        services.defaults.removeObject(forKey: "pack.\(packID).screenshot.prefs")
        services.defaults.removeObject(forKey: "pack.\(packID).screenshot.folder")
        // Only the shots this utility took (removing any other utility leaves them alone).
        for shot in shots where shot.packID == packID { forget(shot.id) }
    }

    // MARK: Helpers

    private static func shutter() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        (NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink"))?.play()
    }

    /// The display under a point (Cocoa coordinates), with its NSScreen.
    private static func display(at point: NSPoint, in content: SCShareableContent) -> (SCDisplay, NSScreen)? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { return nil }
        return (display, screen)
    }

    /// ScreenCaptureKit's window frames are top-left based; Cocoa's are bottom-left.
    static func cocoaRect(_ r: CGRect) -> NSRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }

    static func cocoaPoint(_ p: CGPoint) -> NSPoint {
        NSPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
    }
}

// MARK: - The selection overlay

/// A dimmed layer over every screen: drag out an area, or click a highlighted window. Esc cancels.
final class SelectionOverlay {
    enum Mode { case area, window }
    struct Result { var area: CGRect?; var windowID: CGWindowID? }

    private var windows: [NSWindow] = []
    private let finish: (Result) -> Void
    private var keyMonitor: Any?

    /// Selecting an area shows a crosshair in the accent color; picking a window keeps the arrow.
    private let cursor: NSCursor

    init(mode: Mode, windows targets: [(CGWindowID, NSRect)], accent: NSColor, finish: @escaping (Result) -> Void) {
        self.finish = finish
        cursor = mode == .area ? Self.crosshair(accent) : .arrow
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), mode: mode, screenOrigin: screen.frame.origin,
                                     targets: targets, accent: accent, cursor: cursor)
            view.onDone = { [weak self] result in self?.end(result) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate()
        windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.end(Result()) ; return nil }      // Esc
            return event
        }
        cursor.set()
        // Zephydian becomes the active app a moment later; set it again once it has.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, !self.windows.isEmpty else { return }
            self.windows.forEach { $0.invalidateCursorRects(for: $0.contentView!) }
            self.cursor.set()
        }
    }

    /// A thin crosshair in the accent color.
    private static func crosshair(_ accent: NSColor) -> NSCursor {
        let size = NSSize(width: 23, height: 23)
        let image = NSImage(size: size, flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY), gap: CGFloat = 3
            accent.setStroke()
            for (a, b) in [(NSPoint(x: 1, y: c.y), NSPoint(x: c.x - gap, y: c.y)), (NSPoint(x: c.x + gap, y: c.y), NSPoint(x: rect.maxX - 1, y: c.y)),
                           (NSPoint(x: c.x, y: 1), NSPoint(x: c.x, y: c.y - gap)), (NSPoint(x: c.x, y: c.y + gap), NSPoint(x: c.x, y: rect.maxY - 1))] {
                let path = NSBezierPath()
                path.move(to: a)
                path.line(to: b)
                path.lineWidth = 1
                path.stroke()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 11.5, y: 11.5))
    }

    private func end(_ result: Result) {
        guard !windows.isEmpty else { return }
        NSCursor.arrow.set()                                   // the crosshair goes as soon as you've picked
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        // Let the overlay leave the screen before the picture is taken.
        Task { @MainActor [finish] in
            try? await Task.sleep(for: .milliseconds(120))
            finish(result)
        }
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onDone: (SelectionOverlay.Result) -> Void = { _ in }
    private let mode: SelectionOverlay.Mode
    private let screenOrigin: NSPoint
    private let targets: [(CGWindowID, NSRect)]
    private var start: NSPoint?
    private var current: NSPoint?
    private var hovered: (CGWindowID, NSRect)?
    private let accent: NSColor
    private let cursor: NSCursor

    init(frame: NSRect, mode: SelectionOverlay.Mode, screenOrigin: NSPoint, targets: [(CGWindowID, NSRect)], accent: NSColor, cursor: NSCursor) {
        self.mode = mode
        self.screenOrigin = screenOrigin
        self.targets = targets
        self.accent = accent
        self.cursor = cursor
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func mouseMoved(with event: NSEvent) {
        // Set on every move: until Zephydian is the active app, macOS doesn't apply cursor rects,
        // so the plus sign would otherwise only show once the button is pressed.
        cursor.set()
        guard mode == .window else { return }
        let global = NSEvent.mouseLocation
        let hit = targets.first { $0.1.contains(global) }       // front-most first (ScreenCaptureKit's order)
        if hit?.0 != hovered?.0 { hovered = hit; needsDisplay = true }
        cursor.set()
    }

    override func mouseEntered(with event: NSEvent) { cursor.set() }

    override func mouseDown(with event: NSEvent) {
        cursor.set()
        if mode == .window {
            let global = NSEvent.mouseLocation
            onDone(.init(windowID: targets.first { $0.1.contains(global) }?.0))
            return
        }
        start = convert(event.locationInWindow, from: nil)
        current = start
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
        cursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area, let rect = selection else { return }
        if rect.width < 4 || rect.height < 4 { start = nil; current = nil; needsDisplay = true; return }
        onDone(.init(area: rect.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // The screen is dimmed except for the selection (or the window under the pointer), which
        // is cut out with rounded corners.
        context.setFillColor(NSColor.black.withAlphaComponent(0.32).cgColor)
        if mode == .area, let rect = selection, rect.width > 0, rect.height > 0 {
            context.addRect(bounds)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.fillPath(using: .evenOdd)
            drawSelection(context, rect)
        } else if mode == .window, let hovered {
            let rect = hovered.1.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
            context.addRect(bounds)
            context.addRect(rect)
            context.fillPath(using: .evenOdd)
            let path = CGPath(roundedRect: rect.insetBy(dx: 1.25, dy: 1.25), cornerWidth: 9, cornerHeight: 9, transform: nil)
            context.addPath(path)
            context.setFillColor(accent.withAlphaComponent(0.14).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(accent.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(2.5)
            context.strokePath()
        } else {
            context.fill(bounds)
        }
    }

    /// A glowing border in the accent color with a thin white line inside it, and the size in
    /// pixels on a dark badge centered under the selection.
    private func drawSelection(_ context: CGContext, _ rect: NSRect) {
        context.saveGState()
        context.setShadow(offset: .zero, blur: 9, color: accent.withAlphaComponent(0.55).cgColor)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerWidth: 9, cornerHeight: 9, transform: nil))
        context.setStrokeColor(accent.withAlphaComponent(0.98).cgColor)
        context.setLineWidth(3)
        context.strokePath()
        context.restoreGState()
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(1)
        context.strokePath()

        let scale = window?.backingScaleFactor ?? 2
        let text = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                                          .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        var badge = NSRect(x: rect.midX - size.width / 2 - 7, y: rect.minY - 10 - size.height - 6, width: size.width + 14, height: size.height + 6)
        // Kept on screen: above the selection's bottom edge when there's no room under it.
        badge.origin.x = max(6, min(badge.origin.x, bounds.maxX - badge.width - 6))
        if badge.minY < 6 { badge.origin.y = rect.minY + 10 }
        NSColor(white: 0, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        text.draw(at: NSPoint(x: badge.minX + 7, y: badge.minY + 3), withAttributes: attributes)
    }
}
