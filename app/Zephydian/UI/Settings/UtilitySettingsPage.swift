import SwiftUI

/// A utility's page in the Settings window (SDK 5). It runs the pack in its settings mode (a runtime
/// of its own, sharing the pack's saved data with the panel) and draws `settings.view()` as a grouped
/// form with native controls.
struct UtilitySettingsPage: View {
    let bundle: PackBundle
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @State private var session: PackSession?

    var body: some View {
        Group {
            if let session, let failure = session.failure {
                Form {
                    Section {
                        Label("These settings couldn't open", systemImage: "exclamationmark.triangle.fill")
                        Text(bundle.isDev ? failure : "Try again later. If it keeps happening, remove \(bundle.manifest.name) and install it again from the Library.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else if let session, let root = session.ui {
                PackSettingsForm(root: root, session: session)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .onAppear(perform: start)
        .onDisappear { session = nil }   // the runtime and anything it scheduled go with it
        .onChange(of: colorScheme) { _, scheme in session?.updateTheme(dark: scheme == .dark, accent: settings.accentNSColor) }
    }

    private func start() {
        guard session == nil else { return }
        let session = PackSession(bundle: bundle, mode: .settings)
        session.updateTheme(dark: colorScheme == .dark, accent: settings.accentNSColor)
        session.setSize(CGSize(width: 480, height: 400))   // starts it
        self.session = session
    }
}

/// A pack's settings view as Form sections: each `z.ui.section` (or each run of controls between
/// dividers) becomes a group, captions at the end of a group become its footer, and controls
/// become native rows.
struct PackSettingsForm: View {
    let root: PackUINode
    let session: PackSession

    struct Group: Identifiable {
        var id: String
        var title: String?
        var rows: [PackUINode] = []
        var footer: [String] = []
    }

    var body: some View {
        Form {
            ForEach(Self.groups(root)) { group in
                Section {
                    ForEach(group.rows) { PackFormRow(node: $0, session: session) }
                } header: {
                    if let title = group.title { Text(title) }
                } footer: {
                    if !group.footer.isEmpty {
                        Text(group.footer.joined(separator: "\n"))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    static func groups(_ root: PackUINode) -> [Group] {
        var groups: [Group] = []
        var current = Group(id: "start")
        func flush() {
            if !current.rows.isEmpty { groups.append(current) }
            current = Group(id: "after-\(groups.count)-\(current.id)")
        }
        func visit(_ node: PackUINode) {
            switch node.kind {
            case let .section(title):
                flush()
                current = Group(id: node.id, title: title)
                node.children.forEach(visit)
                flush()
            case .stack(true, _, _, _):
                node.children.forEach(visit)
            case .divider:
                flush()
            case .spacer:
                break
            default:
                current.rows.append(node)
            }
        }
        visit(root)
        flush()
        for i in groups.indices {
            while let last = groups[i].rows.last, case let .text(text, .caption, _, _, _, _) = last.kind, groups[i].rows.count > 1 {
                groups[i].footer.insert(text, at: 0)
                groups[i].rows.removeLast()
            }
        }
        return groups
    }
}

/// One control of a pack's settings as a Form row.
private struct PackFormRow: View {
    let node: PackUINode
    let session: PackSession

    private func send(_ event: String, _ value: Any) { session.uiEvent(node.id, event, value) }

    var body: some View {
        switch node.kind {
        case let .toggle(label, value):
            Toggle(label, isOn: Binding(get: { value }, set: { send("onChange", $0) }))
        case let .picker(label, options, selected):
            Picker(label, selection: Binding(get: { selected }, set: { send("onChange", $0) })) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            }
        case .shortcut(let label):
            UtilityShortcutRow(name: label, packID: session.bundle.id)
        case let .text(text, style, _, selectable, _, _):
            PackFormText(text: text, style: style, selectable: selectable)
        case .stack(false, _, _, _):
            row
        default:
            PackFormInline(node: node, session: session)
        }
    }

    /// A row: "Label  [control]" when it starts with text, otherwise its controls side by side.
    @ViewBuilder private var row: some View {
        let parts = node.children.filter { if case .spacer = $0.kind { false } else { true } }
        if let first = parts.first, case let .text(label, _, _, _, _, _) = first.kind, parts.count > 1 {
            LabeledContent(label) {
                HStack(spacing: 8) {
                    ForEach(parts.dropFirst()) { PackFormInline(node: $0, session: session) }
                }
            }
        } else {
            HStack(spacing: 8) {
                ForEach(parts) { PackFormInline(node: $0, session: session) }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A control inside a row, with native styling where there's a native match.
private struct PackFormInline: View {
    let node: PackUINode
    let session: PackSession

    private func send(_ event: String, _ value: Any = NSNull()) { session.uiEvent(node.id, event, value) }

    var body: some View {
        switch node.kind {
        case let .segmented(options, selected):
            Picker(node.label ?? "", selection: Binding(get: { selected }, set: { send("onChange", $0) })) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        case let .button(label, symbol, style, disabled, _, _, _):
            Button(role: style == "destructive" ? .destructive : nil) { send("onPress") } label: {
                if let symbol, !label.isEmpty { Label(label, systemImage: symbol) }
                else if let symbol { Image(systemName: symbol).accessibilityLabel(label) }
                else { Text(label) }
            }
            .disabled(disabled)
        case let .toggle(label, value):
            Toggle(label, isOn: Binding(get: { value }, set: { send("onChange", $0) })).labelsHidden()
        case let .text(text, style, _, selectable, _, _):
            PackFormText(text: text, style: style, selectable: selectable)
        default:
            // Anything else is drawn the way the panel draws it.
            PackNodeView(node: node, session: session)
        }
    }
}

private struct PackFormText: View {
    let text: String
    let style: PackUINode.TextStyle
    let selectable: Bool

    var body: some View {
        let base = Text(text)
            .font(style == .mono ? .body.monospaced() : style == .caption || style == .secondary ? .callout : .body)
            .foregroundStyle(style == .caption || style == .secondary ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
        if selectable { base.textSelection(.enabled) } else { base }
    }
}
