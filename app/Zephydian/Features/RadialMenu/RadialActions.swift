import AppKit

/// What a slice looks like on the wheel.
enum RadialIcon {
    /// A real app or file icon, drawn in full color.
    case image(NSImage)
    case symbol(String)
}

/// A slice ready to draw: the item plus its name, a short kind line and its icon.
struct RadialSlice: Identifiable {
    let item: RadialItem
    var title: String
    var detail: String
    var icon: RadialIcon
    var id: UUID { item.id }
    var isFolder: Bool { item.kind == .folder }
}

/// Turns saved items into slices, and runs them.
enum RadialActions {
    /// Wired by AppDelegate.
    static var showPanel: () -> Void = {}

    /// The slices that can run right now (an uninstalled utility or a feature that's off is left out).
    static func slices(_ items: [RadialItem]) -> [RadialSlice] {
        items.compactMap(slice)
    }

    static func slice(_ item: RadialItem) -> RadialSlice? {
        let custom = item.symbol.isEmpty ? nil : RadialIcon.symbol(item.symbol)
        func make(_ title: String, _ detail: String, _ icon: RadialIcon) -> RadialSlice {
            RadialSlice(item: item, title: item.name.isEmpty ? title : item.name, detail: detail, icon: custom ?? icon)
        }
        switch item.kind {
        case .app:
            guard FileManager.default.fileExists(atPath: item.path) else { return nil }
            return make(FileManager.default.displayName(atPath: item.path).replacingOccurrences(of: ".app", with: ""), "App", .image(icon(item.path)))
        case .file:
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isFolder) else { return nil }
            return make(FileManager.default.displayName(atPath: item.path), isFolder.boolValue ? "Folder" : "File", .image(icon(item.path)))
        case .url:
            guard let url = URL(string: item.payload), url.scheme != nil else { return nil }
            return make(url.host() ?? item.payload, "Link", .symbol("link"))
        case .utility:
            guard let bundle = PackLibrary.shared.packs.first(where: { $0.id == item.payload && $0.kind == .utility }) else { return nil }
            return make(bundle.manifest.name, "Utility", .symbol(bundle.manifest.symbol ?? "square.grid.2x2"))
        case .feature:
            guard let action = RadialFeatureAction(rawValue: item.payload), isAvailable(action) else { return nil }
            return make(action.title, "Zephydian", .symbol(action.symbol))
        case .quickToggle:
            guard let toggle = QuickToggle(rawValue: item.payload), QuickToggles.shared.isAvailable(toggle) else { return nil }
            return make(toggle.title, "Quick toggle", .symbol(toggle.symbol))
        case .folder:
            let count = slices(item.children).count
            guard count > 0 else { return nil }
            return make("Folder", "Folder · \(count) item\(count == 1 ? "" : "s")", .symbol("folder"))
        case .windowLayout:
            guard let layout = WindowLayout(rawValue: item.payload) else { return nil }
            return make(layout.title, "Window layout", .symbol(layout.symbol))
        case .media:
            guard let key = RadialMediaKey(rawValue: item.payload) else { return nil }
            return make(key.title, "Media", .symbol(key.symbol))
        case .keys:
            guard let keys = keyShortcut(item.payload) else { return nil }
            return make(keys.label, "Keys", .symbol("keyboard"))
        case .shortcut:
            guard !item.payload.isEmpty else { return nil }
            let app = "/System/Applications/Shortcuts.app"
            return make(item.payload, "Shortcut", FileManager.default.fileExists(atPath: app) ? .image(icon(app)) : .symbol("square.2.layers.3d"))
        case .snippet:
            guard let snippet = InputSettings.shared.snippets.first(where: { $0.id.uuidString == item.payload }) else { return nil }
            let line = snippet.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? snippet.trigger
            return make(String(line.prefix(40)), "Snippet · \(snippet.trigger)", .symbol("text.badge.plus"))
        case .nowPlaying:
            var slice = make("Nothing playing", "Now playing", .symbol("music.note"))
            if let playing = nowPlaying { fill(&slice, with: playing) }
            return slice
        }
    }

    /// The key combination a Keys slice presses, saved as JSON.
    static func keyShortcut(_ payload: String) -> KeyShortcut? {
        try? JSONDecoder().decode(KeyShortcut.self, from: Data(payload.utf8))
    }

    static func keysPayload(_ shortcut: KeyShortcut) -> String {
        (try? JSONEncoder().encode(shortcut)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    // MARK: Now playing

    /// The last song read, so a wheel shows it at once while a fresh read runs.
    private(set) static var nowPlaying: NowPlaying?

    /// Reads Now Playing again; `done` gets the new value (nil: nothing playing).
    static func refreshNowPlaying(_ done: @escaping (NowPlaying?) -> Void) {
        Task { @MainActor in
            let playing = await NowPlayingReader.read()
            nowPlaying = playing
            done(playing)
        }
    }

    /// Shows a song on a now-playing slice (a custom name or symbol stays).
    static func fill(_ slice: inout RadialSlice, with playing: NowPlaying?) {
        guard slice.item.kind == .nowPlaying else { return }
        let custom = !slice.item.symbol.isEmpty
        if let playing {
            if slice.item.name.isEmpty { slice.title = playing.title }
            slice.detail = playing.artist.isEmpty ? (playing.isPlaying ? "Playing" : "Paused") : playing.artist
            if !custom { slice.icon = playing.artwork.map(RadialIcon.image) ?? .symbol(playing.isPlaying ? "pause.fill" : "play.fill") }
        } else {
            if slice.item.name.isEmpty { slice.title = "Nothing playing" }
            slice.detail = "Now playing"
            if !custom { slice.icon = .symbol("music.note") }
        }
    }

    static func isAvailable(_ action: RadialFeatureAction) -> Bool {
        if action == .capture { return capturePack != nil }
        guard let id = action.featureID else { return true }
        return Features.shared.isOn(id)
    }

    /// Runs a slice (folders are opened by the wheel itself).
    static func run(_ item: RadialItem) {
        switch item.kind {
        case .app:
            NSWorkspace.shared.openApplication(at: URL(filePath: item.path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { Task { @MainActor in NSSound.beep() } }
            }
        case .file:
            if !NSWorkspace.shared.open(URL(filePath: item.path)) { NSSound.beep() }
        case .url:
            if let url = URL(string: item.payload) { NSWorkspace.shared.open(url) }
        case .utility:
            CommandBarHooks.openUtility(item.payload)
        case .feature:
            guard let action = RadialFeatureAction(rawValue: item.payload) else { return }
            run(action)
        case .quickToggle:
            guard let toggle = QuickToggle(rawValue: item.payload) else { return }
            QuickToggles.shared.refresh()   // switches flip from their real state
            QuickToggles.shared.run(toggle)
        case .windowLayout:
            guard let layout = WindowLayout(rawValue: item.payload), allowed("move windows") else { return }
            guard let (window, _) = WindowArranger.focusedWindow() else { NSSound.beep(); return }
            WindowArranger.apply(layout, to: window)
        case .media:
            guard let key = RadialMediaKey(rawValue: item.payload), allowed("press media keys") else { return }
            pressMediaKey(key.auxKey)
        case .nowPlaying:
            guard allowed("play and pause") else { return }
            pressMediaKey(RadialMediaKey.playPause.auxKey)
        case .keys:
            guard let keys = keyShortcut(item.payload), allowed("press keys") else { return }
            EventTap.pressKey(CGKeyCode(keys.keyCode), flags: CGEventFlags(rawValue: UInt64(keys.flags.rawValue)))
        case .snippet:
            guard let snippet = InputSettings.shared.snippets.first(where: { $0.id.uuidString == item.payload }),
                  allowed("paste snippets") else { return }
            SnippetPaste.insert(snippet.expanded())
        case .shortcut:
            runShortcut(item.payload)
        case .folder:
            break
        }
    }

    /// Slices that press keys or move windows need Accessibility.
    static func needsAccessibility(_ kind: RadialItemKind) -> Bool {
        [.windowLayout, .media, .nowPlaying, .keys, .snippet].contains(kind)
    }

    /// Without Accessibility, says so instead of doing nothing.
    private static func allowed(_ what: String) -> Bool {
        if Permissions.shared.isGranted(.accessibility) { return true }
        NSSound.beep()
        CaptureToast.show("Radial Menu needs Accessibility to \(what). Allow it in Settings → Permissions.", symbol: "hand.raised.fill")
        return false
    }

    /// The pair of events the keyboard's media keys send, so whatever is playing reacts as to F8.
    private static func pressMediaKey(_ key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (key << 16) | ((down ? 0xA : 0xB) << 8)
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                 context: nil, subtype: 8, data1: data1, data2: -1) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Runs a shortcut from Apple's Shortcuts app by name (in the background; it can take a while).
    private static func runShortcut(_ name: String) {
        Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {}
            let failed = process.terminationStatus != 0
            if failed {
                await MainActor.run {
                    NSSound.beep()
                    CaptureToast.show("The shortcut “\(name)” didn't run. Check its name in the Shortcuts app.", symbol: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    private static func run(_ action: RadialFeatureAction) {
        switch action {
        case .panel: showPanel()
        case .capture: if let id = capturePack?.id { PackServices.shared.capture.openBar(packID: id) }
        case .shelf: ShelfEngine.current?.toggle()
        case .cameraMirror: CameraMirrorEngine.current?.toggle()
        case .commandBar: CommandBarEngine.current?.open()
        case .quickPanel: QuickPanelEngine.current?.open()
        case .cleaningMode: CleaningMode.shared.start()
        }
    }

    private static var capturePack: PackBundle? {
        PackLibrary.shared.packs.first { ($0.manifest.capabilities ?? []).contains("screen.capture") }
    }

    // MARK: Icons

    /// File and app icons, cached so the wheel never reads the disk while the pointer moves.
    private static var icons: [String: NSImage] = [:]

    private static func icon(_ path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 64, height: 64)
        icons[path] = image
        return image
    }
}
