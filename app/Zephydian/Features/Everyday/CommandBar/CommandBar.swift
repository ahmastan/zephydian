import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Settings

/// What the Command Bar searches.
enum CommandSource: String, CaseIterable, Identifiable, Codable {
    case apps, windows, files, clipboard, snippets, menus, math, settings, emoji, colors, scripts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: "Apps"
        case .windows: "Open windows"
        case .files: "Files and folders"
        case .clipboard: "Clipboard history"
        case .snippets: "Text snippets"
        case .menus: "The front app's menu commands"
        case .math: "Math, units and dates"
        case .settings: "System Settings and Zephydian"
        case .emoji: "Emoji"
        case .colors: "Colors"
        case .scripts: "Saved scripts and links"
        }
    }
}

/// A named shell command or link the Command Bar runs by its name.
struct SavedScript: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// A shell command, or a link (anything with a scheme, like https:// or shortcuts://).
    var command: String

    var isLink: Bool {
        guard let url = URL(string: command.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme else { return false }
        return !scheme.isEmpty && !command.contains(" ")
    }
}

@Observable
final class CommandBarSettings {
    static let shared = CommandBarSettings()

    var shortcut: KeyShortcut? { didSet { save(shortcut, "commandBar.shortcut") } }
    var sources: Set<CommandSource> { didSet { save(sources, "commandBar.sources") } }
    var scripts: [SavedScript] { didSet { save(scripts, "commandBar.scripts") } }
    var registered = true

    private let defaults = UserDefaults.standard

    init() {
        // ⌥Space to start with (19-D18); a removed shortcut stays removed.
        if defaults.object(forKey: "commandBar.shortcut") == nil {
            shortcut = KeyShortcut(keyCode: UInt16(kVK_Space), modifiers: .option, key: "Space")
        } else {
            shortcut = defaults.data(forKey: "commandBar.shortcut").flatMap { try? JSONDecoder().decode(KeyShortcut?.self, from: $0) } ?? nil
        }
        sources = defaults.data(forKey: "commandBar.sources").flatMap { try? JSONDecoder().decode(Set<CommandSource>.self, from: $0) }
            ?? Set(CommandSource.allCases)
        scripts = defaults.data(forKey: "commandBar.scripts").flatMap { try? JSONDecoder().decode([SavedScript].self, from: $0) } ?? []
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/// How the Command Bar reaches the rest of the app (set by AppDelegate).
enum CommandBarHooks {
    static var openUtility: (String) -> Void = { _ in }
    static var openSettings: (String?) -> Void = { _ in }
}

// MARK: - Searching

@Observable
final class CommandBarModel {
    var query = "" { didSet { if query != oldValue { search() } } }
    private(set) var results: [CommandResult] = []
    var selection = 0
    /// The result waiting for a second ↵.
    var confirming: String?

    /// The app that was in front when the bar opened (its menus, where pastes go).
    @ObservationIgnored private(set) var frontApp: NSRunningApplication?
    @ObservationIgnored private var apps: [AppEntry] = []
    @ObservationIgnored private var appsRead = Date.distantPast
    @ObservationIgnored private var windows: [(window: SystemWindow, app: String)] = []
    @ObservationIgnored private var menus: [MenuEntry] = []
    @ObservationIgnored private var files: [CommandResult] = []
    @ObservationIgnored private var fileQuery: NSMetadataQuery?
    @ObservationIgnored private var fileObserver: NSObjectProtocol?
    @ObservationIgnored private var fileTask: Task<Void, Never>?
    @ObservationIgnored private var loads: [Task<Void, Never>] = []
    @ObservationIgnored var close: () -> Void = {}

    private var settings: CommandBarSettings { .shared }

    /// Starts reading what can take a moment (apps, windows, menus), off the main thread.
    func opened() {
        query = ""
        results = []
        selection = 0
        confirming = nil
        files = []
        frontApp = NSWorkspace.shared.frontmostApplication
        let sources = settings.sources
        if sources.contains(.apps), apps.isEmpty || Date().timeIntervalSince(appsRead) > 120 {
            loads.append(Task { [weak self] in
                let list = await Task.detached(priority: .userInitiated) { CommandSources.apps() }.value
                self?.apps = list
                self?.appsRead = Date()
                self?.search()
            })
        }
        if sources.contains(.windows), Permissions.shared.isGranted(.accessibility) {
            loads.append(Task { [weak self] in
                let list = await Task.detached(priority: .userInitiated) { CommandSources.windows() }.value
                self?.windows = list
                self?.search()
            })
        }
        menus = []
        if sources.contains(.menus), Permissions.shared.isGranted(.accessibility), let pid = frontApp?.processIdentifier,
           frontApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
            loads.append(Task { [weak self] in
                let list = await Task.detached(priority: .userInitiated) { CommandSources.menus(of: pid) }.value
                self?.menus = list
                self?.search()
            })
        }
    }

    func closed() {
        for task in loads { task.cancel() }
        loads = []
        fileTask?.cancel()
        fileQuery?.stop()
        fileQuery = nil
        if let fileObserver { NotificationCenter.default.removeObserver(fileObserver) }
        fileObserver = nil
        windows = []
        menus = []
    }

    // MARK: Running

    func run(alt: Bool) {
        guard results.indices.contains(selection) else { return }
        let result = results[selection]
        if !alt, let confirm = result.confirm, confirming != result.id {
            confirming = result.id
            _ = confirm
            return
        }
        CommandBarUsage.record(result.id)
        close()
        if alt, let other = result.alt { other.run() } else if !alt { result.run() }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
        confirming = nil
    }

    // MARK: Search

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        confirming = nil
        guard !q.isEmpty else {
            results = []
            selection = 0
            return
        }
        var out: [CommandResult] = []
        let sources = settings.sources
        if sources.contains(.math) { out += answers(q) }
        if sources.contains(.colors) { out += colors(q) }
        if sources.contains(.apps) { out += appResults(q) }
        if sources.contains(.windows) { out += windowResults(q) }
        if sources.contains(.menus) { out += menuResults(q) }
        if sources.contains(.settings) { out += settingResults(q) }
        if sources.contains(.scripts) { out += scriptResults(q) }
        if sources.contains(.snippets), Features.shared.isOn("snippets") { out += snippetResults(q) }
        if sources.contains(.clipboard) { out += clipboardResults(q) }
        if sources.contains(.emoji), q.count >= 2 { out += emojiResults(q) }
        if sources.contains(.files) {
            out += files.compactMap { file in
                guard let score = Fuzzy.score(q, file.title) else { return nil }
                var f = file
                f.score = score * 0.7
                return f
            }
            searchFiles(q)
        }
        for i in out.indices { out[i].score += CommandBarUsage.boost(out[i].id) }
        let previous = results.indices.contains(selection) ? results[selection].id : nil
        results = Array(out.sorted { $0.score > $1.score }.prefix(40))
        selection = previous.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
    }

    private func answers(_ q: String) -> [CommandResult] {
        let answer = CommandAnswers.math(q)?.answer ?? CommandAnswers.units(q) ?? CommandAnswers.dates(q)
        guard let answer else { return [] }
        return [CommandResult(id: "answer", kind: .answer, title: answer, subtitle: q, icon: .symbol("equal.circle"), score: 1000,
                              run: { Self.copy(answer) }, alt: ("Paste", { Self.paste(answer) }))]
    }

    private func colors(_ q: String) -> [CommandResult] {
        guard let color = CommandAnswers.color(q) else { return [] }
        return [color.hex, color.rgb, color.hsl].enumerated().map { i, text in
            CommandResult(id: "color.\(i)", kind: .color, title: text, subtitle: "Copy", icon: .color(color.color), score: 990 - Double(i),
                          run: { Self.copy(text) }, alt: ("Paste", { Self.paste(text) }))
        }
    }

    private func appResults(_ q: String) -> [CommandResult] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return apps.compactMap { app in
            guard let score = Fuzzy.score(q, app.name) else { return nil }
            let path = app.path
            let isRunning = app.bundleID.map(running.contains) ?? false
            return CommandResult(id: "app.\(app.bundleID ?? path)", kind: .app, title: app.name, subtitle: isRunning ? "Open" : nil,
                                 icon: .file(path), score: score + 6,
                                 run: { NSWorkspace.shared.openApplication(at: URL(filePath: path), configuration: NSWorkspace.OpenConfiguration()) },
                                 alt: ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }))
        }
    }

    private func windowResults(_ q: String) -> [CommandResult] {
        windows.compactMap { entry in
            let window = entry.window
            guard let score = Fuzzy.score(q, window.title) ?? Fuzzy.score(q, entry.app).map({ $0 - 20 }) else { return nil }
            return CommandResult(id: "window.\(window.id)", kind: .window, title: window.title, subtitle: entry.app,
                                 icon: .app(window.pid), score: score * 0.9,
                                 run: { Task.detached { SystemWindows.focus(window) } })
        }
    }

    private func menuResults(_ q: String) -> [CommandResult] {
        let appName = frontApp?.localizedName ?? "App"
        return menus.compactMap { entry in
            guard let score = Fuzzy.score(q, entry.title) else { return nil }
            return CommandResult(id: "menu.\(frontApp?.bundleIdentifier ?? "").\(entry.path.joined(separator: ">")).\(entry.title)",
                                 kind: .menu, title: (entry.path + [entry.title]).joined(separator: " › "),
                                 subtitle: entry.shortcut ?? appName, icon: .symbol("filemenu.and.selection"), score: score * 0.88,
                                 run: { CommandSources.press(entry) })
        }
    }

    private func settingResults(_ q: String) -> [CommandResult] {
        var out: [CommandResult] = []
        for pane in SystemSettingsPanes.all {
            guard let score = Fuzzy.score(q, pane.name) ?? (pane.keywords.split(separator: " ").contains { $0.hasPrefix(q.lowercased()) } ? 40 : nil)
            else { continue }
            out.append(CommandResult(id: "pane.\(pane.id)", kind: .setting, title: pane.name, subtitle: "System Settings",
                                     icon: .symbol(pane.symbol), score: score * 0.8, run: { SystemSettingsPanes.open(pane.id) }))
        }
        // Zephydian: its features, Settings pages and utilities.
        for feature in Features.shared.all {
            guard let score = Fuzzy.score(q, feature.name) else { continue }
            out.append(CommandResult(id: "feature.\(feature.id)", kind: .zephydian, title: feature.name,
                                     subtitle: Features.shared.isOn(feature.id) ? "Zephydian feature · On" : "Zephydian feature",
                                     icon: .symbol(feature.symbol), score: score * 0.8,
                                     run: { CommandBarHooks.openSettings("feature:\(feature.id)") }))
        }
        for page in SettingsPage.allCases {
            guard let score = Fuzzy.score(q, page.title) else { continue }
            out.append(CommandResult(id: "page.\(page.rawValue)", kind: .zephydian, title: "\(page.title) Settings", subtitle: "Zephydian",
                                     icon: .symbol(page.symbol), score: score * 0.75,
                                     run: { CommandBarHooks.openSettings(page.rawValue) }))
        }
        for bundle in PackLibrary.shared.packs where bundle.kind == .utility {
            guard let score = Fuzzy.score(q, bundle.manifest.name) else { continue }
            let id = bundle.id
            out.append(CommandResult(id: "utility.\(id)", kind: .zephydian, title: bundle.manifest.name, subtitle: "Zephydian utility",
                                     icon: .symbol(bundle.manifest.symbol ?? "square.grid.2x2"), score: score * 0.85,
                                     run: { CommandBarHooks.openUtility(id) }))
        }
        if Features.shared.isOn("quick-toggles") {
            let toggles = QuickToggles.shared
            toggles.refresh()
            for toggle in QuickToggle.allCases where toggles.isAvailable(toggle) {
                let score = Fuzzy.score(q, toggle.title) ?? (toggle.keywords.contains { $0.hasPrefix(q.lowercased()) } ? 45 : nil)
                guard let score else { continue }
                let state = toggle.isSwitch ? (toggles.isOn(toggle) ? "On" : "Off") : toggle.note
                out.append(CommandResult(id: "toggle.\(toggle.rawValue)", kind: .toggle, title: toggle.title, subtitle: state,
                                         icon: .symbol(toggle.symbol), score: score * 0.9,
                                         run: { toggles.run(toggle, confirmed: true) },
                                         confirm: toggle == .emptyTrash ? "Press ↵ again to empty the Trash for good" : nil))
            }
        }
        if Features.shared.isOn("cleaning-mode"), let score = Fuzzy.score(q, "Cleaning Mode") ?? Fuzzy.score(q, "clean keyboard") {
            out.append(CommandResult(id: "cleaning", kind: .toggle, title: "Cleaning Mode", subtitle: "Lock the keyboard and trackpad",
                                     icon: .symbol("sparkles"), score: score * 0.9,
                                     run: { Task { try? await Task.sleep(for: .milliseconds(300)); CleaningMode.shared.start() } }))
        }
        return out
    }

    private func scriptResults(_ q: String) -> [CommandResult] {
        settings.scripts.compactMap { script in
            guard !script.name.isEmpty, let score = Fuzzy.score(q, script.name) else { return nil }
            return CommandResult(id: "script.\(script.id)", kind: .script, title: script.name, subtitle: script.command,
                                 icon: .symbol(script.isLink ? "link" : "terminal"), score: score * 0.95,
                                 run: { Self.runScript(script) })
        }
    }

    private func snippetResults(_ q: String) -> [CommandResult] {
        InputSettings.shared.snippets.compactMap { snippet in
            let score = Fuzzy.score(q, snippet.trigger) ?? (snippet.text.localizedCaseInsensitiveContains(q) ? 40 : nil)
            guard let score else { return nil }
            return CommandResult(id: "snippet.\(snippet.id)", kind: .snippet, title: snippet.text.firstLine, subtitle: ";" + snippet.trigger,
                                 icon: .symbol("text.badge.plus"), score: score * 0.75,
                                 run: { Self.afterClose { SnippetPaste.insert(snippet.expanded()) } },
                                 alt: ("Copy", { Self.copy(snippet.expanded()) }))
        }
    }

    private func clipboardResults(_ q: String) -> [CommandResult] {
        guard q.count >= 2,
              let pack = PackLibrary.shared.packs.first(where: { ($0.manifest.capabilities ?? []).contains("clipboard.read") }) else { return [] }
        let history = PackServices.shared.clipboard
        let packID = pack.id
        return history.items(packID: packID).prefix(300).compactMap { item in
            let text = item.kind == "file" ? (item.files ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                : item.kind == "image" ? "Image \(item.width ?? 0) × \(item.height ?? 0)" : (item.text ?? "")
            guard text.localizedCaseInsensitiveContains(q) else { return nil }
            let itemID = item.id
            return CommandResult(id: "clip.\(itemID)", kind: .clipboard, title: text.firstLine,
                                 subtitle: item.appName ?? item.at.formatted(date: .omitted, time: .shortened),
                                 icon: .symbol(item.kind == "image" ? "photo" : item.kind == "file" ? "doc" : "doc.on.clipboard"),
                                 score: 38 - Double(min(item.text?.count ?? 0, 400)) / 100,
                                 run: { Self.afterClose { _ = history.paste(packID: packID, id: itemID) } },
                                 alt: ("Copy", { if history.copy(packID: packID, id: itemID) { CaptureToast.show("Copied") } }))
        }
    }

    private func emojiResults(_ q: String) -> [CommandResult] {
        let words = q.lowercased().split(separator: " ")
        return CommandSources.emoji.compactMap { emoji in
            guard words.allSatisfy({ word in emoji.name.split(separator: " ").contains { $0.hasPrefix(word) } }) else { return nil }
            let glyph = emoji.glyph
            return CommandResult(id: "emoji.\(glyph)", kind: .emoji, title: emoji.name.capitalized, subtitle: "Copy",
                                 icon: .glyph(glyph), score: 30 - Double(emoji.name.count) * 0.1,
                                 run: { Self.copy(glyph) }, alt: ("Paste", { Self.paste(glyph) }))
        }.prefix(12).map { $0 }
    }

    /// Spotlight's index, by file name; newest used first. Debounced, and only the latest search counts.
    private func searchFiles(_ q: String) {
        fileTask?.cancel()
        guard q.count >= 2 else { return }
        fileTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.fileQuery?.stop()
            let query = NSMetadataQuery()
            query.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(q)*")
            query.searchScopes = [NSMetadataQueryUserHomeScope]
            query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
            self.fileQuery = query
            nonisolated(unsafe) let gathered = query
            if let old = self.fileObserver { NotificationCenter.default.removeObserver(old) }
            self.fileObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.filesFound(gathered, for: q) }
            }
            query.start()
        }
    }

    private func filesFound(_ query: NSMetadataQuery, for q: String) {
        query.stop()
        if let fileObserver { NotificationCenter.default.removeObserver(fileObserver) }
        fileObserver = nil
        guard query === fileQuery, q == self.query.trimmingCharacters(in: .whitespaces) else { return }
        var found: [CommandResult] = []
        for i in 0..<min(query.resultCount, 15) {
            guard let item = query.result(at: i) as? NSMetadataItem, let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !path.contains("/Library/"), !path.contains("/.") else { continue }
            let url = URL(filePath: path)
            let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            found.append(CommandResult(id: "file.\(path)", kind: .file, title: url.lastPathComponent, subtitle: folder,
                                       icon: .file(path), score: 0,
                                       run: { NSWorkspace.shared.open(url) },
                                       alt: ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([url]) })))
        }
        files = found
        search()
    }

    // MARK: Helpers

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        CaptureToast.show("Copied", symbol: "doc.on.doc.fill")
    }

    static func paste(_ text: String) {
        afterClose { SnippetPaste.insert(text) }
    }

    /// Waits a moment so the app you were in has the keyboard again.
    static func afterClose(_ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            action()
        }
    }

    static func runScript(_ script: SavedScript) {
        let command = script.command.trimmingCharacters(in: .whitespaces)
        if script.isLink, let url = URL(string: command) {
            NSWorkspace.shared.open(url)
            return
        }
        let name = script.name
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var status: Int32 = -1
            var output = ""
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                status = process.terminationStatus
                output = String(data: data, encoding: .utf8) ?? ""
            } catch {
                output = error.localizedDescription
            }
            let line = output.split(separator: "\n").first.map(String.init)
            let ok = status == 0
            await MainActor.run {
                CaptureToast.show(ok ? "\(name) finished" : "\(name) failed", symbol: ok ? "terminal.fill" : "exclamationmark.triangle.fill",
                                  detail: line.map { String($0.prefix(120)) })
            }
        }
    }
}

private extension String {
    var firstLine: String {
        let line = split(whereSeparator: \.isNewline).first.map(String.init) ?? self
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }
}

// MARK: - The bar

/// The Command Bar's window: a wide glass bar in the upper middle of the screen that takes the
/// keyboard without making Zephydian the active app, so menu commands and pastes reach the app
/// you were in.
final class CommandBarPanel {
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    static let width: CGFloat = 680
    static let fieldHeight: CGFloat = 58
    static let rowHeight: CGFloat = 44
    static let maxRows = 8

    let model = CommandBarModel()
    private var panel: KeyPanel?
    private var outsideMonitor: Any?
    private var top: CGFloat = 0

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() { isOpen ? close() : open() }

    func open() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.close = { [weak self] in self?.close() }
        model.opened()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        top = area.maxY - area.height * 0.2
        resize(animate: false, screen: area)
        panel.makeKeyAndOrderFront(nil)
        follow()
        if outsideMonitor == nil {
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.closed()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
    }

    /// Grows and shrinks with the results, keeping the field where it is.
    private func follow() {
        guard isOpen else { return }
        withObservationTracking { _ = model.results.count } onChange: { [weak self] in
            Task { @MainActor in
                self?.resize(animate: true, screen: nil)
                self?.follow()
            }
        }
    }

    private func resize(animate: Bool, screen: CGRect?) {
        guard let panel else { return }
        let rows = min(model.results.count, Self.maxRows)
        let empty = model.query.trimmingCharacters(in: .whitespaces).isEmpty
        let body: CGFloat = rows > 0 ? CGFloat(rows) * Self.rowHeight + 13 : (empty ? 34 : 34)
        let height = Self.fieldHeight + body
        let midX = screen?.midX ?? panel.frame.midX
        let frame = CGRect(x: midX - Self.width / 2, y: top - height, width: Self.width, height: height)
        panel.setFrame(frame, display: true, animate: false)
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let settings = Features.shared.appSettings ?? SettingsStore()
        panel.appearance = settings.appearance.nsAppearance
        let hosting = NSHostingView(rootView: CommandBarView(model: model).environment(settings).tint(settings.accentColor))
        let radius: CGFloat = 22
        if #available(macOS 26, *), settings.usesGlass {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            hosting.autoresizingMask = [.width, .height]
            glass.contentView = hosting
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = .roundedMask(radius: radius)
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
            panel.contentView = effect
        }
        return panel
    }
}

private struct CommandBarView: View {
    let model: CommandBarModel
    @FocusState private var focused: Bool
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search apps, files, menus, clipboard, or type 12*7", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
                    .onSubmit { model.run(alt: false) }
                    .onKeyPress(keys: [.return]) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        model.run(alt: true)
                        return .handled
                    }
                if let label = CommandBarSettings.shared.shortcut?.label {
                    Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: CommandBarPanel.fieldHeight)
            if !model.results.isEmpty {
                Divider().padding(.horizontal, 12)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                                CommandRow(result: result, selected: index == model.selection,
                                           confirming: model.confirming == result.id)
                                    .id(result.id)
                                    .onTapGesture {
                                        model.selection = index
                                        model.run(alt: false)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: model.selection) { _, index in
                        if model.results.indices.contains(index) { proxy.scrollTo(model.results[index].id) }
                    }
                }
            } else {
                Divider().padding(.horizontal, 12)
                Text(model.query.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Try an app, a file, a menu command, 5 km in miles, #3a7 or a setting"
                     : "No results")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .frame(height: 33)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true }
        .onChange(of: model.results.count) { focused = true }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.escape) { model.close(); return .handled }
    }
}

private struct CommandRow: View {
    let result: CommandResult
    let selected: Bool
    let confirming: Bool
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        HStack(spacing: 10) {
            Text(result.kind.label)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            icon.frame(width: 24, height: 24)
            Text(result.title)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if confirming, let confirm = result.confirm {
                Text(confirm).font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
            } else if let subtitle = result.subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            if selected {
                Text(result.alt.map { "↵   ⌘↵ \($0.label)" } ?? "↵")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CommandBarPanel.rowHeight)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selected ? AnyShapeStyle(settings.accentColor.opacity(0.22)) : AnyShapeStyle(.clear)))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.kind.label.lowercased()), \(result.title)")
    }

    @ViewBuilder private var icon: some View {
        switch result.icon {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 15)).foregroundStyle(settings.accentColor)
        case .file(let path):
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit()
        case .app(let pid):
            if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "macwindow")
            }
        case .color(let color):
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: color))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.2)))
                .frame(width: 20, height: 20)
        case .glyph(let text):
            Text(text).font(.system(size: 18))
        }
    }
}

// MARK: - The feature

final class CommandBarEngine: FeatureEngine {
    static weak var current: CommandBarEngine?

    private let settings = CommandBarSettings.shared
    private let hotKey = GlobalHotKey(id: 705)
    private let bar = CommandBarPanel()
    private var running = false

    func start() {
        running = true
        Self.current = self
        hotKey.onPress = { [weak self] in self?.bar.toggle() }
        follow()
    }

    func stop() {
        running = false
        if Self.current === self { Self.current = nil }
        hotKey.unregister()
        bar.close()
    }

    func open() { bar.open() }

    private func follow() {
        guard running else { return }
        withObservationTracking { _ = settings.shortcut } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        settings.registered = hotKey.register(settings.shortcut)
    }
}

struct CommandBarSettingsView: View {
    @State private var settings = CommandBarSettings.shared
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        @Bindable var settings = settings
        Section {
            LabeledContent("Open the Command Bar") {
                ShortcutRecorder(shortcut: settings.shortcut) { settings.shortcut = $0 }
            }
            ShortcutWarning(text: ShortcutConflicts.warning(for: settings.shortcut, registered: settings.registered,
                                                            owner: "command-bar", panel: appSettings.panelShortcut))
        } footer: {
            Text("↑ ↓ to pick, ↵ to open or run, ⌘↵ for the second action (Show in Finder, Copy, Paste), Esc to close. Window and menu searches need Accessibility.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section("Search") {
            ForEach(CommandSource.allCases) { source in
                Toggle(source.title, isOn: Binding(
                    get: { settings.sources.contains(source) },
                    set: { on in if on { settings.sources.insert(source) } else { settings.sources.remove(source) } }))
            }
        }
        Section {
            ForEach(settings.scripts) { script in
                ScriptRow(id: script.id)
            }
            Button("Add a Script or Link", systemImage: "plus") {
                settings.scripts.append(SavedScript(name: "", command: ""))
            }
        } header: {
            Text("Saved scripts and links")
        } footer: {
            Text("Type a script's name in the Command Bar to run it. A link (https://…, shortcuts://run-shortcut?name=…) opens; anything else runs in your login shell (zsh) and shows its first line of output.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Finds its script by id, so removing a row never leaves a field pointing past the end.
    private struct ScriptRow: View {
        let id: UUID
        @State private var settings = CommandBarSettings.shared

        var body: some View {
            if let index = settings.scripts.firstIndex(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    TextField("Name", text: Binding(get: { settings.scripts[safe: index]?.name ?? "" },
                                                    set: { if settings.scripts.indices.contains(index) { settings.scripts[index].name = $0 } }),
                              prompt: Text("Name"))
                        .labelsHidden()
                        .frame(width: 150)
                    TextField("Command or link", text: Binding(get: { settings.scripts[safe: index]?.command ?? "" },
                                                              set: { if settings.scripts.indices.contains(index) { settings.scripts[index].command = $0 } }),
                              prompt: Text("open -a Safari  or  https://…"))
                        .labelsHidden()
                        .font(.system(.body, design: .monospaced))
                    Button {
                        settings.scripts.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove")
                }
            }
        }
    }
}
