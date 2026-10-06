import SwiftUI
import SwitcherKit
import UniformTypeIdentifiers

/// A wheel's slices in Settings: a live preview (click a slice to select it), the list below it
/// (drag to reorder), Add by kind, and Edit for a slice's name, icon and target. Folders open
/// their own list. Shown for one wheel; give it `.id(wheel.id)` so another wheel starts fresh.
struct RadialSlicesEditor: View {
    @Binding var wheel: RadialWheel

    /// The folders opened, from the top level.
    @State private var path: [UUID] = []
    @State private var selection: UUID?
    /// The slice being dragged to a new place in the list.
    @State private var dragging: UUID?
    @State private var editing: RadialEditTarget?
    @State private var preview = RadialMenuModel()
    @State private var shortcutNames: [String] = []
    @State private var radial = RadialSettings.shared
    @Environment(SettingsStore.self) private var settings

    private var items: [RadialItem] { wheel.items(at: path) }
    private var isFull: Bool { items.count >= RadialWheel.maxSlices }

    var body: some View {
        Section {
            HStack {
                Spacer()
                RadialMenuView(model: preview, onClick: clickPreview, preview: true)
                    .accessibilityHint("Click a slice to select it in the list")
                Spacer()
            }
            .padding(.vertical, 6)
            if !path.isEmpty {
                HStack {
                    Button { leaveFolder() } label: { Label("Back", systemImage: "chevron.left") }
                        .controlSize(.small)
                    Text(trail.joined(separator: " › ")).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if items.isEmpty {
                Text(path.isEmpty ? "No slices yet. Click Add to choose the first one." : "This folder is empty. Click Add to fill it.")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                row(item)
                    .reorderable(item.id, dragging: $dragging) { dragged, target in
                        wheel.update(at: path) { level in
                            guard let from = level.firstIndex(where: { $0.id == dragged }),
                                  let to = level.firstIndex(where: { $0.id == target }) else { return }
                            level.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                        }
                    }
            }
        } header: {
            HStack {
                Text(path.isEmpty ? "Slices" : "Slices in \(trail.last ?? "the folder")")
                Spacer()
                addMenu
            }
        } footer: {
            Text("Up to \(RadialWheel.maxSlices) slices; the first sits at the top and the rest follow clockwise. Drag rows to reorder them. A slice that can't run right now (shown in orange) is left off the wheel until it can.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { refreshPreview(); loadShortcutNames() }
        .onChange(of: wheel) { refreshPreview() }
        .onChange(of: path) { refreshPreview() }
        .onChange(of: selection) { refreshPreview() }
        .onChange(of: radial.size) { refreshPreview() }
        .sheet(item: $editing) { target in
            RadialItemEditor(item: target.item, isNew: target.isNew, shortcutNames: shortcutNames) { saved in
                wheel.update(at: path) { level in
                    if let index = level.firstIndex(where: { $0.id == saved.id }) { level[index] = saved } else { level.append(saved) }
                }
                selection = saved.id
            }
        }
    }

    /// The opened folders' names, for the breadcrumb and the preview's Back.
    private var trail: [String] {
        var names: [String] = []
        var level = wheel.items
        for id in path {
            guard let folder = level.first(where: { $0.id == id }) else { break }
            names.append(RadialActions.editorInfo(folder).slice.title)
            level = folder.children
        }
        return names
    }

    // MARK: Rows

    private func row(_ item: RadialItem) -> some View {
        let info = RadialActions.editorInfo(item)
        let selected = selection == item.id
        return HStack(spacing: 10) {
            icon(info.slice.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.slice.title).lineLimit(1)
                Text(info.problem ?? info.slice.detail)
                    .font(.caption)
                    .foregroundStyle(info.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .lineLimit(1)
            }
            Spacer()
            if item.kind == .folder {
                Button("Open") { openFolder(item) }.controlSize(.small)
            }
            Button("Edit…") { editing = RadialEditTarget(item: item, isNew: false) }.controlSize(.small)
            Button { remove(item) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove this slice")
                .accessibilityLabel("Remove \(info.slice.title)")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? settings.accentColor.opacity(0.15) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selection = item.id }
        .contextMenu {
            Button("Edit…") { editing = RadialEditTarget(item: item, isNew: false) }
            if item.kind == .folder { Button("Open Folder") { openFolder(item) } }
            Divider()
            Button("Move Up") { move(item, by: -1) }.disabled(items.first?.id == item.id)
            Button("Move Down") { move(item, by: 1) }.disabled(items.last?.id == item.id)
            Divider()
            Button("Remove", role: .destructive) { remove(item) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Move Up") { move(item, by: -1) }
        .accessibilityAction(named: "Move Down") { move(item, by: 1) }
    }

    @ViewBuilder private func icon(_ icon: RadialIcon) -> some View {
        switch icon {
        case .image(let image):
            Image(nsImage: image).resizable().frame(width: 24, height: 24)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 15)).frame(width: 24, height: 24)
        }
    }

    // MARK: Adding

    private var addMenu: some View {
        Menu {
            Button("App…") { pick(apps: true) }
            Button("File or Folder…") { pick(apps: false) }
            Button("Link…") { startNew(RadialItem(kind: .url)) }
            Divider()
            let utilities = PackLibrary.shared.packs.filter { $0.kind == .utility }
            Menu("Utility") {
                ForEach(utilities, id: \.id) { bundle in
                    Button(bundle.manifest.name) { add(RadialItem(kind: .utility, payload: bundle.id)) }
                }
            }
            .disabled(utilities.isEmpty)
            Menu("Zephydian") {
                ForEach(RadialFeatureAction.allCases, id: \.self) { action in
                    Button(action.title) { add(RadialItem(kind: .feature, payload: action.rawValue)) }
                }
            }
            Menu("Quick Toggle") {
                ForEach(QuickToggle.allCases) { toggle in
                    Button(toggle.title) { add(RadialItem(kind: .quickToggle, payload: toggle.rawValue)) }
                }
            }
            Menu("Window Layout") {
                ForEach(WindowLayout.allCases) { layout in
                    Button(layout.title) { add(RadialItem(kind: .windowLayout, payload: layout.rawValue)) }
                }
            }
            Menu("Media") {
                ForEach(RadialMediaKey.allCases, id: \.self) { key in
                    Button(key.title) { add(RadialItem(kind: .media, payload: key.rawValue)) }
                }
                Button("Now Playing") { add(RadialItem(kind: .nowPlaying)) }
            }
            Divider()
            Button("Keys…") { startNew(RadialItem(kind: .keys)) }
            Menu("Shortcut") {
                if shortcutNames.isEmpty { Text("No shortcuts in the Shortcuts app") }
                ForEach(shortcutNames, id: \.self) { name in
                    Button(name) { add(RadialItem(kind: .shortcut, payload: name)) }
                }
            }
            Menu("Snippet") {
                let snippets = InputSettings.shared.snippets
                if snippets.isEmpty { Text("No snippets yet") }
                ForEach(snippets) { snippet in
                    Button("\(snippet.trigger) · \(String(snippet.text.prefix(30)))") {
                        add(RadialItem(kind: .snippet, payload: snippet.id.uuidString))
                    }
                }
            }
            Divider()
            Button("Folder") { addFolder() }
                .disabled(path.count >= RadialWheel.maxFolderDepth)
        } label: {
            Label("Add", systemImage: "plus")
        }
        .fixedSize()
        .disabled(isFull)
        .help(isFull ? "A wheel holds up to \(RadialWheel.maxSlices) slices" : "Add a slice")
    }

    private func add(_ item: RadialItem) {
        guard !isFull else { return }
        wheel.update(at: path) { $0.append(item) }
        selection = item.id
    }

    /// Kinds that need something typed or recorded first open the editor, and are added on Save.
    private func startNew(_ item: RadialItem) {
        guard !isFull else { return }
        editing = RadialEditTarget(item: item, isNew: true)
    }

    private func addFolder() {
        let folder = RadialItem(kind: .folder, name: "Folder")
        add(folder)
        openFolder(folder)
    }

    private func pick(apps: Bool) {
        guard let path = RadialItemEditor.choosePath(apps: apps) else { return }
        add(RadialItem(kind: apps ? .app : .file, payload: path))
    }

    private func remove(_ item: RadialItem) {
        wheel.update(at: path) { $0.removeAll { $0.id == item.id } }
        if selection == item.id { selection = nil }
    }

    private func move(_ item: RadialItem, by step: Int) {
        wheel.update(at: path) { level in
            guard let index = level.firstIndex(where: { $0.id == item.id }), level.indices.contains(index + step) else { return }
            level.swapAt(index, index + step)
        }
    }

    // MARK: Folders and the preview

    private func openFolder(_ item: RadialItem) {
        path.append(item.id)
        selection = nil
    }

    private func leaveFolder() {
        guard let last = path.popLast() else { return }
        selection = last
    }

    private func clickPreview(dx: CGFloat, dyUp: CGFloat) {
        let dead = RadialLayout.deadZoneRadius * preview.scale
        if (dx * dx + dyUp * dyUp).squareRoot() < dead {
            leaveFolder()
            return
        }
        guard let index = RadialGeometry.highlightedIndex(dx: dx, dyUp: dyUp, deadZoneRadius: dead, itemCount: preview.slices.count) else { return }
        let id = preview.slices[index].id
        // A second click on a selected folder opens it, as on the real wheel.
        if selection == id, let item = items.first(where: { $0.id == id }), item.kind == .folder {
            openFolder(item)
        } else {
            selection = id
        }
    }

    /// The preview shows what the wheel would show now (slices that can't run are left off).
    private func refreshPreview() {
        // Keep only the folders on the path that still exist (one may have been removed).
        var level = wheel.items, valid: [UUID] = []
        for id in path {
            guard let folder = level.first(where: { $0.id == id && $0.kind == .folder }) else { break }
            valid.append(id)
            level = folder.children
        }
        if valid != path { path = valid }
        preview.wheel = wheel
        preview.scale = radial.size.scale * 0.8
        preview.slices = RadialActions.slices(items)
        preview.trail = trail
        preview.discShown = true
        preview.revealed = true
        preview.setLit(preview.slices.firstIndex { $0.id == selection })
    }

    /// The Shortcuts app's shortcuts, for the Add menu (read once, in the background).
    private func loadShortcutNames() {
        guard shortcutNames.isEmpty else { return }
        Task {
            let names = await RadialItemEditor.shortcutNames()
            shortcutNames = names
        }
    }
}

/// A slice being edited (or a new one waiting for its details).
struct RadialEditTarget: Identifiable {
    let id = UUID()
    let item: RadialItem
    let isNew: Bool
}

/// The sheet for one slice: its name, its icon, and what it opens or presses.
struct RadialItemEditor: View {
    @State var item: RadialItem
    let isNew: Bool
    let shortcutNames: [String]
    let save: (RadialItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings

    init(item: RadialItem, isNew: Bool, shortcutNames: [String], save: @escaping (RadialItem) -> Void) {
        _item = State(initialValue: item)
        self.isNew = isNew
        self.shortcutNames = shortcutNames
        self.save = save
    }

    /// Symbols to choose from (or none, for the slice's own icon).
    static let symbols = [
        "star.fill", "heart.fill", "bolt.fill", "flame.fill", "leaf.fill", "sparkles", "moon.fill", "sun.max.fill",
        "globe", "link", "folder.fill", "doc.fill", "book.fill", "terminal.fill", "hammer.fill", "paintbrush.fill",
        "camera.fill", "music.note", "play.fill", "mic.fill", "message.fill", "envelope.fill", "phone.fill", "calendar",
        "clock.fill", "bell.fill", "gearshape.fill", "house.fill", "cart.fill", "gamecontroller.fill", "lock.fill", "magnifyingglass",
    ]

    var body: some View {
        let info = RadialActions.editorInfo(RadialItem(id: item.id, kind: item.kind, payload: item.payload, children: item.children))
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $item.name, prompt: Text(item.kind == .nowPlaying ? "The song's title" : info.slice.title))
                    target
                } footer: {
                    Text("Leave the name empty to use its own.").font(.callout).foregroundStyle(.secondary)
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 9), spacing: 6) {
                        symbolButton(nil, preview: info.slice.icon)
                        ForEach(Self.symbols, id: \.self) { symbolButton($0, preview: nil) }
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if item.kind == .url { item.payload = Self.normalizedURL(item.payload) ?? item.payload }
                    save(item)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 440)
        .frame(minHeight: 420)
    }

    /// What the slice points at, for the kinds where that can be changed here.
    @ViewBuilder private var target: some View {
        switch item.kind {
        case .url:
            TextField("Web address", text: $item.payload, prompt: Text("https://example.com"))
        case .keys:
            LabeledContent("Keys to press") {
                ShortcutRecorder(shortcut: RadialActions.keyShortcut(item.payload)) { keys in
                    item.payload = keys.map(RadialActions.keysPayload) ?? ""
                }
            }
        case .shortcut:
            Picker("Shortcut", selection: $item.payload) {
                if item.payload.isEmpty { Text("Choose…").tag("") }
                if !item.payload.isEmpty && !shortcutNames.contains(item.payload) { Text(item.payload).tag(item.payload) }
                ForEach(shortcutNames, id: \.self) { Text($0).tag($0) }
            }
        case .app, .file:
            LabeledContent(item.kind == .app ? "App" : "File or folder") {
                HStack {
                    Text(item.payload).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") {
                        if let path = Self.choosePath(apps: item.kind == .app) { item.payload = path }
                    }
                }
            }
        default:
            LabeledContent("Does", value: RadialActions.editorInfo(item).slice.detail)
        }
    }

    private func symbolButton(_ symbol: String?, preview: RadialIcon?) -> some View {
        let selected = (symbol ?? "") == item.symbol
        return Button { item.symbol = symbol ?? "" } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                } else if case .image(let image)? = preview {
                    Image(nsImage: image).resizable().frame(width: 18, height: 18)
                } else if case .symbol(let name)? = preview {
                    Image(systemName: name)
                }
            }
            .font(.system(size: 14))
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? settings.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? settings.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(symbol == nil ? "Its own icon" : symbol!)
        .accessibilityLabel(symbol ?? "Its own icon")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var isValid: Bool {
        switch item.kind {
        case .url: Self.normalizedURL(item.payload) != nil
        case .keys: RadialActions.keyShortcut(item.payload) != nil
        case .shortcut, .app, .file: !item.payload.isEmpty
        default: true
        }
    }

    // MARK: Helpers

    /// A web address as typed, with https:// added when it has no scheme. Nil if it isn't one.
    static func normalizedURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let full = trimmed.contains("://") || trimmed.hasPrefix("mailto:") ? trimmed : "https://" + trimmed
        guard let url = URL(string: full), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        if scheme == "http" || scheme == "https" { guard let host = url.host(), host.contains(".") || host == "localhost" else { return nil } }
        return full
    }

    /// Asks for an app (in Applications) or any file or folder. Saved with ~ for the home folder.
    static func choosePath(apps: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = !apps
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if apps {
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(filePath: "/Applications")
            panel.message = "Choose an app for the wheel"
        } else {
            panel.message = "Choose a file or folder for the wheel"
        }
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// The names of the shortcuts in the Shortcuts app (`shortcuts list`), sorted.
    static func shortcutNames() async -> [String] {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return [String]() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            return names.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }.value
    }
}
