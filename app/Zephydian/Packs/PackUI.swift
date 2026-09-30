import AppKit
import SwiftUI

// MARK: - The view tree a utility returns from view()

/// One control or container from a utility's `view()` (SDK 2), already checked. The app draws it
/// with native SwiftUI controls, so utilities type, select, copy and read out like any Mac app.
nonisolated struct PackUINode: Equatable, Identifiable {
    enum TextStyle: String { case body, title, large, secondary, caption, mono }

    struct ListItem: Equatable, Identifiable {
        struct Action: Equatable { var symbol: String; var label: String }
        var id: String
        var title: String
        var subtitle: String?
        var detail: String?
        var symbol: String?
        /// A small picture instead of the symbol ("clipboard:<id>" or an asset name).
        var image: String?
        var actions: [Action]
    }

    enum Kind: Equatable {
        case text(String, style: TextStyle, align: PackShape.Align, selectable: Bool, color: PackColor?)
        case field(value: String, placeholder: String, multiline: Bool, lines: Int, mono: Bool)
        /// `badge`: a small letter in a toolbar button's corner (its key). `bar`: a line-weight glyph
        /// of that thickness instead of a symbol.
        case button(label: String, symbol: String?, style: String, disabled: Bool, selected: Bool, badge: String?, bar: Double)
        /// A button with a menu of choices (SDK 3). With `onPress` the button itself does that, and
        /// the arrow next to it opens the menu.
        case menu(label: String, symbol: String?, items: [String], selected: Int, primary: Bool, prominent: Bool)
        /// Three slots in a row, the middle one centered on the row whatever the sides hold (SDK 3).
        case band
        /// Zephydian's jet logo, `size` points tall (SDK 3).
        case logo(size: Double)
        case toggle(label: String, value: Bool)
        case slider(value: Double, min: Double, max: Double, step: Double)
        case segmented(options: [String], selected: Int)
        case picker(label: String, options: [String], selected: Int)
        case copy(text: String, label: String, concealed: Bool)
        /// `fill`: a row that takes the height it's given (a tool rail beside a fit canvas), aligned to the top.
        case stack(vertical: Bool, spacing: Double, align: PackShape.Align, fill: Bool)
        case section(title: String?)
        case list(items: [ListItem], selected: String?, empty: String?)
        case canvas(PackCanvas)
        /// A floating bar of controls (a window's tools), on glass. Vertical for a tool rail.
        case toolbar(vertical: Bool)
        case swatch(PackColor, size: Double, selected: Bool, pressable: Bool, round: Bool)
        case disclosure(label: String, expanded: Bool)
        /// The utility's own global shortcut (the `shortcut` capability), recorded natively.
        case shortcut(label: String)
        case divider, spacer
    }

    /// The node's place in the tree ("0.2.1", or the pack's own `id`). Events come back with it.
    var id: String
    var kind: Kind
    var children: [PackUINode] = []
    /// What VoiceOver reads for controls that have no text of their own (a color swatch).
    var label: String?

    static let maxNodes = 2000
    static let maxDepth = 16

    struct ParseError: Error, CustomStringConvertible { let description: String }

    /// Reads the prelude's JSON. Anything unexpected is an error, so a broken view shows clearly.
    static func parse(json: String) throws -> PackUINode {
        guard let data = json.data(using: .utf8), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError(description: "view() must return a z.ui control")
        }
        var count = 0
        return try parse(root, depth: 0, count: &count)
    }

    private static func parse(_ o: [String: Any], depth: Int, count: inout Int) throws -> PackUINode {
        count += 1
        guard count <= maxNodes else { throw ParseError(description: "the view has more than \(maxNodes) controls") }
        guard depth <= maxDepth else { throw ParseError(description: "the view is nested more than \(maxDepth) deep") }
        func s(_ k: String) -> String? { o[k] as? String }
        func d(_ k: String, _ fallback: Double = 0) -> Double {
            guard let v = (o[k] as? NSNumber)?.doubleValue, v.isFinite else { return fallback }
            return v
        }
        func b(_ k: String) -> Bool { (o[k] as? NSNumber)?.boolValue ?? false }
        func strings(_ k: String) -> [String] { Array((o[k] as? [Any] ?? []).prefix(50).map { "\($0)" }) }
        let align = PackShape.Align(rawValue: s("align") ?? "") ?? .left
        let key = s("k") ?? ""

        let kind: Kind
        switch s("t") {
        case "text":
            kind = .text(s("text") ?? "", style: TextStyle(rawValue: s("style") ?? "") ?? .body, align: align,
                         selectable: b("selectable"), color: s("color").flatMap(PackColor.init))
        case "field":
            kind = .field(value: s("value") ?? "", placeholder: s("placeholder") ?? "", multiline: b("multiline"),
                          lines: Int(min(max(d("lines", 4), 1), 30)), mono: b("mono"))
        case "button":
            kind = .button(label: s("label") ?? "", symbol: s("symbol"), style: s("style") ?? "plain", disabled: b("disabled"), selected: b("selected"),
                           badge: s("badge").map { String($0.prefix(2)) }, bar: min(max(d("bar"), 0), 12))
        case "menu":
            let on = Set(o["on"] as? [String] ?? [])
            kind = .menu(label: s("label") ?? "", symbol: s("symbol"), items: strings("items"), selected: Int(d("selected", -1)),
                         primary: on.contains("onPress"), prominent: s("style") == "prominent")
        case "band":
            kind = .band
        case "logo":
            kind = .logo(size: min(max(d("size", 28), 12), 96))
        case "toggle":
            kind = .toggle(label: s("label") ?? "", value: b("value"))
        case "slider":
            let lo = d("min"), hi = max(d("max", 1), lo)
            kind = .slider(value: min(max(d("value"), lo), hi), min: lo, max: hi, step: max(0, d("step")))
        case "segmented":
            kind = .segmented(options: strings("options"), selected: Int(d("selected", -1)))
        case "picker":
            kind = .picker(label: s("label") ?? "", options: strings("options"), selected: Int(d("selected", -1)))
        case "copy":
            kind = .copy(text: s("text") ?? "", label: s("label") ?? "Copy", concealed: b("concealed"))
        case "row", "column":
            kind = .stack(vertical: s("t") == "column", spacing: min(max(d("spacing", 8), 0), 64), align: align, fill: b("fill"))
        case "section":
            kind = .section(title: s("title"))
        case "list":
            let items = (o["items"] as? [[String: Any]] ?? []).prefix(500).map { item in
                ListItem(id: "\(item["id"] ?? "")", title: item["title"] as? String ?? "", subtitle: item["subtitle"] as? String,
                         detail: item["detail"] as? String, symbol: item["symbol"] as? String, image: item["image"] as? String,
                         actions: (item["actions"] as? [[String: Any]] ?? []).prefix(3).map {
                             ListItem.Action(symbol: $0["symbol"] as? String ?? "circle", label: $0["label"] as? String ?? "")
                         })
            }
            kind = .list(items: Array(items), selected: s("selected"), empty: s("empty"))
        case "canvas":
            let shapes = try PackRuntime.parseShapes(o["shapes"] as? [Any] ?? [])
            let handlers = Set(o["on"] as? [String] ?? [])
            func size(_ v: Any?) -> CGSize? {
                guard let f = v as? [String: Any], let w = (f["width"] as? NSNumber)?.doubleValue, let h = (f["height"] as? NSNumber)?.doubleValue,
                      w.isFinite, h.isFinite, w >= 1, h >= 1 else { return nil }
                return CGSize(width: min(w, PackImages.maxSide), height: min(h, PackImages.maxSide))
            }
            var ink: PackCanvas.Ink?
            if let i = o["ink"] as? [String: Any] {
                ink = .init(color: (i["color"] as? String).flatMap(PackColor.init) ?? .theme("accent"),
                            width: min(max((i["width"] as? NSNumber)?.doubleValue ?? 3, 0.5), 400),
                            opacity: min(max((i["opacity"] as? NSNumber)?.doubleValue ?? 1, 0.05), 1))
            }
            var edit: PackCanvas.TextEdit?
            if let t = o["textEdit"] as? [String: Any] {
                edit = .init(id: "\(t["id"] ?? "text")", x: (t["x"] as? NSNumber)?.doubleValue ?? 0, y: (t["y"] as? NSNumber)?.doubleValue ?? 0,
                             text: t["text"] as? String ?? "", size: min(max((t["size"] as? NSNumber)?.doubleValue ?? 16, 4), 1000),
                             color: (t["color"] as? String).flatMap(PackColor.init) ?? .theme("text"))
            }
            kind = .canvas(PackCanvas(shapes: shapes, width: o["width"] == nil ? nil : min(max(d("width"), 1), 2000),
                                      height: min(max(d("height", 100), 1), 2000), fit: size(o["fit"]),
                                      cursor: s("cursor"), ink: ink, textEdit: edit,
                                      pointer: handlers.contains("onPointer"), stroke: handlers.contains("onStroke"),
                                      hover: handlers.contains("onHover"), layout: handlers.contains("onLayout")))
        case "toolbar":
            kind = .toolbar(vertical: b("vertical"))
        case "swatch":
            kind = .swatch(s("color").flatMap(PackColor.init) ?? .theme("fill"), size: min(max(d("size", 28), 8), 200),
                           selected: b("selected"), pressable: (o["on"] as? [String] ?? []).contains("onPress"), round: s("shape") == "circle")
        case "shortcut":
            kind = .shortcut(label: s("label") ?? "Shortcut")
        case "disclosure":
            kind = .disclosure(label: s("label") ?? "", expanded: b("expanded"))
        case "divider": kind = .divider
        case "spacer": kind = .spacer
        default:
            throw ParseError(description: "unknown control \"\(s("t") ?? "?")\"")
        }
        let children = try (o["children"] as? [[String: Any]] ?? []).map { try parse($0, depth: depth + 1, count: &count) }
        return PackUINode(id: key, kind: kind, children: children, label: s("accessibilityLabel"))
    }
}

/// A `z.ui.canvas`. With `fit` it fills the space it's given and draws in its own units (an
/// image's pixels), scaled to fit and centered; pointer events come back in those units (SDK 3).
nonisolated struct PackCanvas: Equatable {
    /// A freehand line drawn natively while the pointer is down, then handed to `onStroke`.
    struct Ink: Equatable { var color: PackColor; var width: Double; var opacity: Double }
    /// A text field over the canvas, at a point in canvas units (`onTextChange`, `onTextEnd`).
    struct TextEdit: Equatable { var id: String; var x: Double; var y: Double; var text: String; var size: Double; var color: PackColor }

    var shapes: [PackShape]
    var width: Double?
    var height: Double
    var fit: CGSize?
    /// "crosshair", "text", "move", "pointer", "resize-nwse", "resize-nesw", "resize-ns", "resize-ew",
    /// or nil (the arrow).
    var cursor: String?
    var ink: Ink?
    var textEdit: TextEdit?
    /// Whether the pack listens for pointer events and strokes.
    var pointer: Bool
    var stroke: Bool
    /// Whether the pack wants pointer moves with no button held (to change the cursor), and the
    /// canvas's scale whenever it changes (to keep handles the same size on screen).
    var hover = false
    var layout = false
}

// MARK: - Drawing the tree

/// A utility's screen: its view tree in a scroll view, plus the standard failure card and toast.
struct UtilityView: View {
    let session: PackSession
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(PackServices.self) private var services
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if let root = session.ui {
                    ScrollView {
                        PackNodeView(node: root, session: session)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentMargins(.horizontal, 16, for: .scrollContent)
                    .contentMargins(.bottom, 16, for: .scrollContent)
                }
                if let failure = session.failure {
                    GameOverlay(title: "This utility stopped working",
                                subtitle: session.bundle.isDev ? failure : "Go back and open it again. If it keeps happening, remove it and install it again from the Library.") {
                        Button("Back") { model.closeGame() }.prominentButtonStyle()
                    }
                }
                if let toast = session.toast {
                    GameToast(text: toast).id(toast)
                }
            }
            .onAppear {
                session.resume()        // utilities carry on as soon as they're on screen again
                session.updateTheme(dark: colorScheme == .dark, accent: settings.accent.nsColor)
                session.setSize(CGSize(width: max(1, proxy.size.width - 32), height: proxy.size.height))
            }
            .onChange(of: proxy.size) { _, size in session.setSize(CGSize(width: max(1, size.width - 32), height: size.height)) }
        }
        .onChange(of: colorScheme) { _, scheme in session.updateTheme(dark: scheme == .dark, accent: settings.accent.nsColor) }
        .onChange(of: settings.accent) { _, accent in session.updateTheme(dark: colorScheme == .dark, accent: accent.nsColor) }
        // A service stopped from Settings (or timed out) changes what the utility shows.
        .onChange(of: services.running) { session.refresh() }
        .onChange(of: services.revision) { session.refresh() }
        .animation(.easeOut(duration: 0.2), value: session.toast)
    }
}

/// One node and its children. Recursive, so children are type-erased.
private struct PackNodeView: View {
    let node: PackUINode
    let session: PackSession
    @Environment(SettingsStore.self) private var settings
    @Environment(\.packInToolbar) private var inToolbar
    @Environment(\.packToolbarVertical) private var toolbarVertical

    private func send(_ event: String, _ value: Any = NSNull()) { session.uiEvent(node.id, event, value) }

    private var children: some View {
        ForEach(node.children) { AnyView(PackNodeView(node: $0, session: session)) }
    }

    var body: some View {
        switch node.kind {
        case let .text(string, style, align, selectable, color):
            let text = Text(string)
                .font(Self.font(style))
                .foregroundStyle(color.map { AnyShapeStyle(PackView.color($0, accent: settings.accent.color)) }
                                 ?? (style == .secondary || style == .caption ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)))
                .multilineTextAlignment(align == .center ? .center : align == .right ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
                // Centered and right-aligned text takes the full width; left-aligned text only its own,
                // so it sits naturally in rows next to other controls.
                .frame(maxWidth: align == .left ? nil : .infinity, alignment: align == .center ? .center : align == .right ? .trailing : .leading)
            if selectable { text.textSelection(.enabled) } else { text }

        case let .field(value, placeholder, multiline, lines, mono):
            PackFieldView(value: value, placeholder: placeholder, multiline: multiline, lines: lines, mono: mono,
                          change: { send("onChange", $0) }, submit: { send("onSubmit", $0) })

        case let .button(label, symbol, style, disabled, selected, badge, bar) where inToolbar:
            ToolbarButton(label: label, symbol: symbol, selected: selected, destructive: style == "destructive",
                          prominent: style == "prominent", badge: badge, bar: bar) { send("onPress") }
                .disabled(disabled)

        case let .menu(label, symbol, items, selected, primary, prominent):
            PackMenuButton(label: label, symbol: symbol, items: items, selected: selected, primary: primary, prominent: prominent,
                           inToolbar: inToolbar, press: { send("onPress") }, select: { send("onSelect", $0) })

        case .logo(let size):
            // The menu bar jet (a template image), in the text color.
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(Color.primary.opacity(0.92))
                .accessibilityLabel("Zephydian")

        case .band:
            // The sides at the edges, the middle centered on the whole row.
            ZStack {
                if node.children.count > 1 { AnyView(PackNodeView(node: node.children[1], session: session)) }
                HStack(spacing: 8) {
                    if let first = node.children.first { AnyView(PackNodeView(node: first, session: session)) }
                    Spacer(minLength: 8)
                    if node.children.count > 2 { AnyView(PackNodeView(node: node.children[2], session: session)) }
                }
            }
            .frame(maxWidth: .infinity)

        case let .button(label, symbol, style, disabled, _, _, _):
            let button = Button(role: style == "destructive" ? .destructive : nil) { send("onPress") } label: {
                if let symbol, !label.isEmpty { Label(label, systemImage: symbol) }
                else if let symbol { Image(systemName: symbol).accessibilityLabel(label) }
                else { Text(label) }
            }
            .disabled(disabled)
            if style == "prominent" { button.prominentButtonStyle() } else { button }

        case let .toggle(label, value):
            // Like a Settings row: the label on the left, the switch at the right edge.
            HStack(spacing: 8) {
                Text(label).font(.system(size: 13))
                Spacer(minLength: 8)
                Toggle(label, isOn: Binding(get: { value }, set: { send("onChange", $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            .accessibilityElement(children: .combine)

        case let .slider(value, lo, hi, step) where inToolbar:
            Slider(value: Binding(get: { value }, set: { v in
                send("onChange", step > 0 ? min(max(lo + ((v - lo) / step).rounded() * step, lo), hi) : v)
            }), in: lo...hi)
            .controlSize(.mini)
            .frame(width: 84)
            .accessibilityLabel(node.label ?? "Value")

        case let .slider(value, lo, hi, step):
            // Snaps to the step without tick marks, like the app's own sliders.
            Slider(value: Binding(get: { value }, set: { v in
                send("onChange", step > 0 ? min(max(lo + ((v - lo) / step).rounded() * step, lo), hi) : v)
            }), in: lo...hi)

        case let .segmented(options, selected):
            SegmentedControl(selection: Binding(get: { selected }, set: { send("onChange", $0) }),
                             options: Array(options.indices), title: { options[$0] })

        case let .picker(label, options, selected):
            Picker(label, selection: Binding(get: { selected }, set: { send("onChange", $0) })) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            }
            .pickerStyle(.menu)
            .font(.system(size: 13))

        case let .copy(text, label, concealed):
            Button {
                PackClipboard.write(text, concealed: concealed)
                session.packToast("Copied")
            } label: {
                Label(label, systemImage: "doc.on.doc")
            }
            .disabled(text.isEmpty)
            .help("Copy to the clipboard")

        case let .stack(false, spacing, _, true):
            HStack(alignment: .top, spacing: spacing) { children }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case let .stack(vertical, spacing, align, _):
            if vertical {
                VStack(alignment: align == .center ? .center : align == .right ? .trailing : .leading, spacing: spacing) { children }
                    .frame(maxWidth: .infinity, alignment: align == .center ? .center : align == .right ? .trailing : .leading)
            } else {
                HStack(spacing: spacing) { children }
                    .fixedSize(horizontal: false, vertical: true)   // a divider in a row stays as tall as the row
                    .frame(maxWidth: .infinity, alignment: align == .center ? .center : align == .right ? .trailing : .leading)
            }

        case let .section(title):
            // Content, like the Settings sections: a plain fill card, no glass.
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                VStack(alignment: .leading, spacing: 10) { children }
                    .environment(\.packInSection, true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous).fill(Tokens.fill))
            }

        case let .list(items, selected, empty):
            PackListView(items: items, selected: selected, empty: empty, image: session.image(named:),
                         select: { send("onSelect", $0) },
                         action: { id, index in send("onAction", ["id": id, "action": index]) })

        case let .canvas(canvas) where canvas.fit != nil:
            PackFitCanvas(canvas: canvas, session: session, send: send)
                .id(node.id)

        case let .canvas(canvas):
            let accent = settings.accent.color
            Canvas { context, size in
                PackView.render(canvas.shapes, in: context, size: size, accent: accent, image: session.image(named:))
            }
            .frame(width: canvas.width.map { CGFloat($0) }, height: canvas.height)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)

        case .toolbar(let vertical):
            // A floating control bar: glass behind its controls (not a GlassGroup, which would draw
            // the glass above them), Frosted's bar material on older macOS or in Frosted mode.
            // A vertical one is a tool rail, a rounded rectangle concentric with the window's corners.
            if vertical {
                VStack(spacing: 2) { children }
                    .environment(\.packInToolbar, true)
                    .environment(\.packToolbarVertical, true)
                    .controlSize(.small)
                    .padding(5)
                    .fixedSize()
                    .glassSurface(in: RoundedRectangle(cornerRadius: 15, style: .continuous), fallback: .bar)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 5)
            } else {
                HStack(spacing: 2) { children }
                    .environment(\.packInToolbar, true)
                    .controlSize(.small)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .fixedSize()
                    .glassSurface(in: Capsule(), fallback: .bar)
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 3)
            }

        case let .swatch(color, size, selected, pressable, true):
            // A color dot: the color in a circle, with a ring around the chosen one.
            let dot = ZStack {
                Circle().fill(PackView.color(color, accent: settings.accent.color))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5))
                    .frame(width: size, height: size)
                if selected { Circle().strokeBorder(Color.primary.opacity(0.9), lineWidth: 1.5).frame(width: size + 6, height: size + 6) }
            }
            .frame(width: size + 7, height: size + 7)
            .scaleEffect(selected ? 1.05 : 1)
            .contentShape(Circle())
            if pressable {
                Button { send("onPress") } label: { dot }
                    .buttonStyle(.plain)
                    .accessibilityLabel(node.label ?? "Color")
                    .accessibilityAddTraits(selected ? .isSelected : [])
            } else {
                dot.accessibilityHidden(true)
            }

        case let .swatch(color, size, selected, pressable, _):
            let shape = RoundedRectangle(cornerRadius: min(8, size / 4), style: .continuous)
            let swatch = shape
                .fill(PackView.color(color, accent: settings.accent.color))
                .overlay(shape.strokeBorder(.separator))
                .overlay(shape.inset(by: -3).strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
                .frame(width: size, height: size)
            if pressable {
                Button { send("onPress") } label: { swatch }
                    .buttonStyle(.plain)
                    .accessibilityLabel(node.label ?? "Color")
            } else {
                swatch.accessibilityHidden(true)
            }

        case let .disclosure(label, expanded):
            // A row that shows or hides what's under it; the pack keeps the open/closed state.
            VStack(alignment: .leading, spacing: 8) {
                Button { send("onToggle", !expanded) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(label).font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if expanded {
                    VStack(alignment: .leading, spacing: 10) { children }
                }
            }
            .animation(.easeOut(duration: 0.15), value: expanded)

        case let .shortcut(label):
            PackShortcutField(label: label, packID: session.bundle.id)

        case .divider where inToolbar && toolbarVertical: Divider().frame(width: 22).padding(.vertical, 2)
        case .divider where inToolbar: Divider().frame(height: 16).padding(.horizontal, 4)
        case .divider: Divider()
        case .spacer: Spacer(minLength: 0)
        }
    }

    private static func font(_ style: PackUINode.TextStyle) -> Font {
        switch style {
        case .body: .system(size: 13)
        case .title: .system(size: 15, weight: .semibold)
        case .large: .system(size: 28, weight: .semibold).monospacedDigit()
        case .secondary: .system(size: 12)
        case .caption: .system(size: 11)
        case .mono: .system(size: 13, design: .monospaced)
        }
    }
}

/// A text field that keeps its own text while you type (so the cursor never jumps) and takes the
/// pack's value whenever the pack changes it.
private struct PackFieldView: View {
    let value: String
    let placeholder: String
    let multiline: Bool
    let lines: Int
    let mono: Bool
    let change: (String) -> Void
    let submit: (String) -> Void

    @State private var text = ""

    var body: some View {
        Group {
            if multiline {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(lines, reservesSpace: true)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(mono ? .system(size: 13, design: .monospaced) : .system(size: 13))
        .onAppear { text = value }
        .onChange(of: value) { _, new in if new != text { text = new } }
        .onChange(of: text) { _, new in if new != value { change(new) } }
        .onSubmit { submit(text) }
    }
}

/// Rows in a fill card, like the Library: optional icon, title, subtitle, and up to three buttons.
private struct PackListView: View {
    let items: [PackUINode.ListItem]
    let selected: String?
    let empty: String?
    let image: (String) -> NSImage?
    let select: (String) -> Void
    let action: (String, Int) -> Void
    /// Inside a section the rows sit straight on the section's card, not on a second card.
    @Environment(\.packInSection) private var inSection

    var body: some View {
        if items.isEmpty {
            if let empty {
                Text(empty).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item)
                    if index < items.count - 1 { Divider().padding(.leading, 12) }
                }
            }
            .padding(.horizontal, inSection ? -12 : 0)
            .background(RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous).fill(inSection ? .clear : Tokens.fill))
        }
    }

    private func row(_ item: PackUINode.ListItem) -> some View {
        HStack(spacing: 10) {
            if let name = item.image, let picture = image(name) {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
            } else if let symbol = item.symbol {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13)).lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let detail = item.detail {
                Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            }
            ForEach(Array(item.actions.enumerated()), id: \.offset) { index, act in
                Button { action(item.id, index) } label: { Image(systemName: act.symbol) }
                    .buttonStyle(.borderless)
                    .help(act.label)
                    .accessibilityLabel(act.label)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected == item.id ? Tokens.fillHover : .clear)
        .contentShape(Rectangle())
        .onTapGesture { select(item.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Clipboard

nonisolated enum PackClipboard {
    /// Writes text. `concealed` marks it the way password managers do, so clipboard histories
    /// (including Zephydian's own) skip it.
    @MainActor static func write(_ text: String, concealed: Bool) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        if concealed {
            board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }
}

private struct PackInSectionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PackInToolbarKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PackToolbarVerticalKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for controls inside a `z.ui.section` card.
    var packInSection: Bool {
        get { self[PackInSectionKey.self] }
        set { self[PackInSectionKey.self] = newValue }
    }
    /// True for controls inside a `z.ui.toolbar`.
    var packInToolbar: Bool {
        get { self[PackInToolbarKey.self] }
        set { self[PackInToolbarKey.self] = newValue }
    }
    var packToolbarVertical: Bool {
        get { self[PackToolbarVerticalKey.self] }
        set { self[PackToolbarVerticalKey.self] = newValue }
    }
}

/// A utility's shortcut field: the label, the recorder, and a warning when the keys are taken.
/// Talks straight to `PackShortcuts` (observable), so it doesn't wait for the pack.
private struct PackShortcutField: View {
    let label: String
    let packID: String
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let shortcuts = PackServices.shared.shortcuts
        let current = shortcuts.current(packID: packID)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 13))
                Spacer(minLength: 8)
                ShortcutRecorder(shortcut: current) { new in
                    shortcuts.set(packID: packID, new)
                    PackServices.shared.changed()
                }
            }
            ShortcutWarning(text: ShortcutConflicts.warning(for: current, registered: !shortcuts.failed.contains(packID),
                                                            owner: packID, panel: settings.panelShortcut))
        }
    }
}

// MARK: - A pack's own window (SDK 3)

/// The screen of a pack's own window: its view tree filling the window (no scrolling, so a fit
/// canvas takes the room that's left), plus the failure card and toasts.
struct PackWindowView: View {
    let session: PackSession
    let close: () -> Void
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if let root = session.ui {
                    PackNodeView(node: root, session: session)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                if let failure = session.failure {
                    GameOverlay(title: "This utility stopped working",
                                subtitle: session.bundle.isDev ? failure : "Close the window and open it again. If it keeps happening, remove it and install it again from the Library.") {
                        Button("Close", action: close).prominentButtonStyle()
                    }
                }
                if let toast = session.toast {
                    GameToast(text: toast).id(toast).padding(.top, 48)
                }
            }
            .onAppear {
                session.updateTheme(dark: colorScheme == .dark, accent: settings.accent.nsColor)
                session.setSize(proxy.size)
            }
            .onChange(of: proxy.size) { _, size in session.setSize(size) }
        }
        .tint(settings.accent.color)
        .onChange(of: colorScheme) { _, scheme in session.updateTheme(dark: scheme == .dark, accent: settings.accent.nsColor) }
        .onChange(of: settings.accent) { _, accent in session.updateTheme(dark: colorScheme == .dark, accent: accent.nsColor) }
        .animation(.easeOut(duration: 0.2), value: session.toast)
    }
}
