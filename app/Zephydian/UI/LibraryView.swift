import AppKit
import SwiftUI

/// The Library: every pack you can install, with Install / Open, updates and removal.
/// Opened from the "Get more" tile. The rows are content (no glass); the header, buttons and menus
/// are the control layer and get glass through the shared helpers.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(PackLibrary.self) private var library
    @Environment(PackManager.self) private var packs

    @State private var search = ""
    @State private var selection: String?
    @State private var removing: LibraryItem?
    /// A pack with capabilities waiting for Install to be confirmed.
    @State private var confirming: LibraryItem?
    @State private var showingNews: LibraryItem?
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        let items = self.items
        VStack(spacing: 0) {
            header
            HStack(spacing: 8) {
                SegmentedControl(selection: $model.libraryFilter, options: [PackBundle.Kind.game, .utility],
                                 title: { $0 == .game ? "Games" : "Utilities" })
                    .frame(width: 170)
                searchField
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            content(items)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task { await packs.loadCatalog() }   // online only because the Library was opened
        .onAppear { model.libraryKeyHandler = { handleKey($0) } }
        .onDisappear { model.libraryKeyHandler = nil }
        .onChange(of: model.librarySearchRequest) { searchFocused = true }
        .onChange(of: model.libraryFilter) { selection = nil }
        .alert("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { item in
            Button("Remove") { remove(item, deleteProgress: false) }
            Button("Remove and delete progress", role: .destructive) { remove(item, deleteProgress: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("“Remove” keeps your progress and best scores in case you install it again.")
        }
        .alert("Install \(confirming?.name ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
               presenting: confirming) { item in
            Button("Install") { LibraryActions(item: item, packs: packs, model: model).install() }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(item.name) can:\n" + item.capabilities.map { "• \($0.sentence)" }.joined(separator: "\n"))
        }
        .alert("What’s new in \(showingNews?.name ?? "")", isPresented: Binding(get: { showingNews != nil }, set: { if !$0 { showingNews = nil } }),
               presenting: showingNews) { _ in
            Button("OK", role: .cancel) {}
        } message: { item in
            Text("Version \(item.version): \(item.whatsNew ?? "Improvements and fixes.")")
        }
    }

    private func remove(_ item: LibraryItem, deleteProgress: Bool) {
        if item.isBuiltIn {
            InstalledGames.shared.remove(item.id, deleteProgress: deleteProgress)
            model.discardHiddenSession(for: item.id)
        } else {
            packs.uninstall(item.id, deleteProgress: deleteProgress)
        }
    }

    // MARK: Header and search

    private var header: some View {
        HStack(spacing: 6) {
            Button { model.closeLibrary() } label: { Image(systemName: "chevron.left") }
                .glassIconButtonStyle()
                .help("Back to \(model.backDestination) (Esc)")
                .accessibilityLabel("Back to \(model.backDestination)")
            Text("Library").font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { if let first = items.first { selection = first.id } }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(Tokens.fill))
        .help("Search (⌘F)")
    }

    // MARK: List and states

    @ViewBuilder private func content(_ items: [LibraryItem]) -> some View {
        if items.isEmpty {
            VStack(spacing: 10) {
                switch packs.catalogState {
                case .idle, .loading:
                    ProgressView().controlSize(.small)
                    Text("Loading the Library…").foregroundStyle(.secondary)
                case .offline:
                    message("You’re offline", "Connect to the internet to see what you can install.", retry: true)
                case .failed(let text):
                    message("Can’t load the Library", text, retry: true)
                case .loaded:
                    search.isEmpty
                        ? (model.libraryFilter == .game
                            ? message("Nothing here yet", "New games will show up here.", retry: false)
                            : message("No utilities yet", "More are coming soon.", retry: false))
                        : message("No results", "Nothing matches “\(search)”.", retry: false)
                }
            }
            .font(.system(size: 13))
            .multilineTextAlignment(.center)
            .padding(.top, 60)
            .padding(.horizontal, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        statusBanner
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                LibraryRow(item: item, isSelected: selection == item.id,
                                           remove: { removing = item }, showNews: { showingNews = item },
                                           confirm: { confirming = item })
                                    .id(item.id)
                                if index < items.count - 1 { Divider().padding(.leading, 56) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous).fill(Tokens.fill))
                    }
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .contentMargins(.bottom, 16, for: .scrollContent)
                .onChange(of: selection) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
        }
    }

    /// A small note above the list when the list shown is the saved copy.
    @ViewBuilder private var statusBanner: some View {
        switch packs.catalogState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for more…").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        case .offline:
            banner(packs.catalog == nil ? "You’re offline. Only the games built into Zephydian are shown." : "You’re offline. Showing the Library as it was last time.")
        case .failed(let text):
            banner(text)
        default:
            EmptyView()
        }
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Try again") { Task { await packs.loadCatalog() } }.controlSize(.small)
        }
        .padding(.horizontal, 4)
    }

    private func message(_ title: String, _ detail: String, retry: Bool) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if retry {
                Button("Try again") { Task { await packs.loadCatalog() } }
                    .padding(.top, 6)
            }
        }
    }

    // MARK: Items

    /// The catalog's games, installed packs that are no longer in it (they can still be opened and
    /// removed), and the built-in games (installed instantly). Developer packs aren't listed.
    private var items: [LibraryItem] {
        var result: [String: LibraryItem] = [:]
        let kind = model.libraryFilter
        for entry in packs.catalog?.packs ?? [] where entry.kind == kind.rawValue {
            result[entry.id] = LibraryItem(entry: entry, installedVersion: packs.installed[entry.id])
        }
        for bundle in library.packs where bundle.kind == kind && !bundle.isDev && result[bundle.id] == nil {
            result[bundle.id] = LibraryItem(bundle: bundle)
        }
        for info in GameRegistry.builtIn where kind == .game && result[info.id] == nil {
            result[info.id] = LibraryItem(builtIn: info, installed: InstalledGames.shared.contains(info.id))
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        return result.values
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Keyboard

    /// ↑/↓ move between rows, Enter presses the row's button. Typing in the search field is left alone.
    private func handleKey(_ event: NSEvent) -> Bool {
        let list = items
        guard !list.isEmpty else { return false }
        let index = selection.flatMap { id in list.firstIndex { $0.id == id } }
        switch event.keyCode {
        case Key.down:
            selection = list[min((index ?? -1) + 1, list.count - 1)].id
            searchFocused = false
            return true
        case Key.up:
            selection = list[max((index ?? list.count) - 1, 0)].id
            searchFocused = false
            return true
        case Key.enter, Key.keypadEnter:
            guard !searchFocused, let index else { return false }
            LibraryActions(item: list[index], packs: packs, model: model, confirm: { confirming = $0 }).primary()
            return true
        default:
            return false
        }
    }
}

// MARK: - One row

struct LibraryItem: Identifiable {
    let id: String
    let name: String
    let description: String
    let version: String
    let size: Int?
    let sdkVersion: Int
    let whatsNew: String?
    let installedVersion: String?
    let entry: PackCatalog.Entry?
    /// Set for games built into the app: they install instantly, with no download.
    var builtInIcon: GameIcon?
    /// What the pack may use (clipboard, keep awake…), shown before install.
    var capabilities: [PackCapability] = []
    /// An SF Symbol icon (utilities), so nothing has to be downloaded to show it.
    var symbol: String?

    init(entry: PackCatalog.Entry, installedVersion: String?) {
        id = entry.id; name = entry.name; description = entry.description; version = entry.version
        size = entry.size; sdkVersion = entry.sdkVersion; whatsNew = entry.whatsNew
        self.installedVersion = installedVersion; self.entry = entry; symbol = entry.symbol
        capabilities = PackCapability.list(entry.capabilities)
    }

    init(bundle: PackBundle) {
        id = bundle.id; name = bundle.manifest.name; description = bundle.manifest.description
        version = bundle.manifest.version; size = nil; sdkVersion = bundle.manifest.sdkVersion
        whatsNew = bundle.manifest.whatsNew; installedVersion = bundle.manifest.version; entry = nil
        symbol = bundle.manifest.symbol
        capabilities = PackCapability.list(bundle.manifest.capabilities)
    }

    init(builtIn info: GameInfo, installed: Bool) {
        id = info.id; name = info.name; description = info.summary; version = ""; size = nil
        sdkVersion = 0; whatsNew = nil; installedVersion = installed ? "" : nil; entry = nil
        builtInIcon = info.icon
    }

    var isBuiltIn: Bool { builtInIcon != nil }
    var isInstalled: Bool { installedVersion != nil }
    var needsNewerApp: Bool { sdkVersion > PackBundle.sdkVersion }
}

/// What the row's one button does, shared with the Enter key.
private struct LibraryActions {
    let item: LibraryItem
    let packs: PackManager
    let model: AppModel
    /// Asks before installing a pack that uses capabilities (clipboard, keep awake…).
    var confirm: (LibraryItem) -> Void = { _ in }

    enum Kind { case install, open, update, installing, needsNewerApp }

    var kind: Kind {
        if packs.installing[item.id] != nil { return .installing }
        if item.isInstalled {
            // Updates install on their own; the button appears only if that failed.
            return packs.hasUpdate(item.id) && packs.errors[item.id] != nil ? .update : .open
        }
        return item.needsNewerApp ? .needsNewerApp : .install
    }

    func primary() {
        switch kind {
        case .install where item.isBuiltIn:
            InstalledGames.shared.install(item.id)
        case .install where !item.capabilities.isEmpty:
            confirm(item)
        case .install, .update:
            install()
        case .open:
            model.openGame(item.id)
        case .installing, .needsNewerApp:
            break
        }
    }

    /// Downloads and installs (after any confirmation).
    func install() {
        if let entry = item.entry { Task { await packs.install(entry) } }
    }
}

private struct LibraryRow: View {
    let item: LibraryItem
    let isSelected: Bool
    let remove: () -> Void
    let showNews: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(PackLibrary.self) private var library
    @Environment(PackManager.self) private var packs
    @State private var downloadedIcon: NSImage?

    let confirm: () -> Void

    private var actions: LibraryActions { LibraryActions(item: item, packs: packs, model: model, confirm: { _ in confirm() }) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 32, height: 32)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .semibold))
                Text(item.description)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if !item.capabilities.isEmpty {
                    Text("Uses: " + item.capabilities.map(\.short).joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                detailLine
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                button
                if item.isInstalled { moreMenu }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Tokens.fillHover : .clear)
        .task(id: item.entry?.iconSha256) {
            if item.symbol == nil, library.icon(forPackID: item.id) == nil, let entry = item.entry {
                downloadedIcon = await packs.icon(for: entry)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if let builtIn = item.builtInIcon {
            GameIconView(icon: builtIn, size: 32)
        } else if let symbol = item.symbol {
            GameIconView(icon: .symbol(symbol), size: 32)
        } else if let image = library.icon(forPackID: item.id) ?? downloadedIcon {
            GameIconView(icon: .image(image), size: 32)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tokens.fillHover)
        }
    }

    /// Size · version, "What's new" after an update, or the last error.
    @ViewBuilder private var detailLine: some View {
        if item.isBuiltIn {
            Text("Built in · no download").font(.system(size: 11)).foregroundStyle(.tertiary)
        } else if let error = packs.errors[item.id] {
            Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if item.isInstalled, packs.updatedRecently(item.id), let news = item.whatsNew {
            Text("Updated: \(news)").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        } else if item.needsNewerApp && !item.isInstalled {
            Text("Update Zephydian to install this").font(.system(size: 11)).foregroundStyle(.tertiary)
        } else {
            Text([item.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }, "v\(item.installedVersion ?? item.version)"]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var button: some View {
        switch actions.kind {
        case .installing:
            ProgressView(value: packs.installing[item.id] ?? 0)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(width: 64, height: 24)
                .accessibilityLabel("Installing \(item.name)")
        case .install:
            Button("Install") { actions.primary() }.prominentButtonStyle().controlSize(.small)
        case .update:
            Button("Update") { actions.primary() }.prominentButtonStyle().controlSize(.small)
        case .open:
            Button("Open") { actions.primary() }.controlSize(.small)
        case .needsNewerApp:
            Button("Install") {}.controlSize(.small).disabled(true)
                .help("Update Zephydian to install this")
        }
    }

    private var moreMenu: some View {
        Menu {
            if !item.isBuiltIn {
                Button("What’s New") { showNews() }
                Divider()
            }
            Button("Remove…", role: .destructive) { remove() }
        } label: {
            Image(systemName: "ellipsis")
        }
        .glassIconMenuStyle()
        .help("More")
        .accessibilityLabel("More options for \(item.name)")
    }

    private var accessibilityText: String {
        var parts = [item.name, item.isInstalled ? "installed" : "not installed"]
        parts.append(item.isBuiltIn ? "built in" : "version \(item.installedVersion ?? item.version)")
        if !item.capabilities.isEmpty { parts.append("uses " + item.capabilities.map(\.short).joined(separator: ", ")) }
        if let error = packs.errors[item.id] { parts.append(error) }
        return parts.joined(separator: ", ")
    }
}
