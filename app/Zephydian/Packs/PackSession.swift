import AppKit
import SwiftUI

/// A running pack, seen by the rest of the app as one more `GameSession`. It keeps what the pack
/// shows (drawing, score, overlay, menu, toast) as observable state for `PackView`, or, for a
/// utility, its view tree for `UtilityView`.
@Observable
final class PackSession: GameSession, PackHost {
    let bundle: PackBundle

    private(set) var shapes: [PackShape] = []
    /// A utility's controls (SDK 2).
    private(set) var ui: PackUINode?
    private(set) var score = ""
    private(set) var hintText: String
    private(set) var overlay: PackOverlay?
    private(set) var menu: PackMenu?
    private(set) var toast: String?
    private(set) var failure: String?
    private(set) var isPaused = false

    @ObservationIgnored private var runtime: PackRuntime!
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var images: [String: NSImage] = [:]

    init(bundle: PackBundle, mode: PackRuntime.Mode = .panel) {
        self.bundle = bundle
        hintText = bundle.manifest.hint ?? ""
        runtime = PackRuntime(bundle: bundle, host: self, mode: mode)
        failure = runtime.failure
    }

    /// Set by the pack's own window (SDK 3).
    var windowHost: PackWindowHost? {
        get { runtime.windowHost }
        set { runtime.windowHost = newValue }
    }

    var hasFailed: Bool { failure != nil }

    // MARK: GameSession

    var scoreText: String { score }
    var hint: String { hintText }
    var showsPauseButton: Bool { bundle.manifest.pauseButton ?? false }
    var isRunning: Bool { !isPaused && failure == nil }

    func pause() {
        runtime.pause()
        isPaused = runtime.isPaused
    }

    func resume() {
        runtime.resume()
        isPaused = runtime.isPaused
    }

    func togglePause() { isPaused ? resume() : pause() }

    var isUtility: Bool { bundle.kind == .utility }

    func handleKey(_ event: NSEvent) -> Bool {
        guard failure == nil, let key = Self.packKey(event) else { return false }
        if isUtility {
            // Typing in one of the utility's fields goes to the field, not the pack.
            if event.window?.firstResponder is NSText { return false }
            if isPaused { resume() }
            return runtime.key(key)
        }
        let isEnter = key.key == "Enter", isSpace = key.key == " "
        if isPaused && showsPauseButton {
            // The "Paused" card is up: Space or Enter resumes, other keys wait.
            if isSpace || isEnter { resume(); return true }
            return false
        }
        if isPaused { resume() }                       // turn-based packs just carry on
        if isEnter, let overlay, !overlay.buttons.isEmpty {
            runtime.pressOverlayButton(overlay.buttons.firstIndex(where: \.prominent) ?? 0)
            return true
        }
        if isSpace && showsPauseButton {
            togglePause()
            return true
        }
        return runtime.key(key)
    }

    func handleKeyUp(_ event: NSEvent) -> Bool {
        guard failure == nil, !isPaused, let key = Self.packKey(event) else { return false }
        return runtime.keyUp(key)
    }

    func undo() -> Bool {
        // While typing in a utility's field, ⌘Z undoes the typing instead.
        if isUtility, NSApp.keyWindow?.firstResponder is NSText { return false }
        return failure == nil && runtime.undo()
    }

    /// ⇧⌘Z in a pack's window.
    func redo() -> Bool {
        if NSApp.keyWindow?.firstResponder is NSText { return false }
        return failure == nil && runtime.redo()
    }

    /// The window's close button or ⌘W: false if the pack keeps it open for now.
    func shouldClose() -> Bool { failure != nil || runtime.shouldClose() }

    /// A key in the pack's own window: like the panel's, plus Esc and ⌘ combinations (⌘C, ⌘S…).
    func windowKey(_ event: NSEvent) -> Bool {
        guard failure == nil, !(event.window?.firstResponder is NSText),
              let key = Self.packKey(event, window: true) else { return false }
        return runtime.key(key)
    }

    func makeView() -> AnyView { isUtility ? AnyView(UtilityView(session: self)) : AnyView(PackView(session: self)) }

    func makeHeaderAccessory() -> AnyView? {
        menu == nil ? nil : AnyView(PackMenuView(session: self))
    }

    // MARK: From the view

    func setSize(_ size: CGSize) { runtime.setSize(size) }

    func click(at point: CGPoint, right: Bool) {
        guard failure == nil, !(isPaused && showsPauseButton) else { return }
        if isPaused { resume() }
        runtime.click(x: point.x, y: point.y, right: right)
    }

    func pressOverlayButton(_ index: Int) { runtime.pressOverlayButton(index) }

    /// A utility control was used: `event` is its handler's name (onPress, onChange…).
    func uiEvent(_ id: String, _ event: String, _ value: Any) {
        guard failure == nil else { return }
        if isPaused { resume() }
        runtime.uiEvent(id, event, value)
    }

    /// Asks a utility for its view again (something outside it changed, like a stopped service).
    func refresh() { runtime.refresh() }
    func selectMenuItem(_ index: Int) { runtime.selectMenuItem(index) }

    /// Sends `z.theme` to the pack: the current appearance's colors as hex strings.
    func updateTheme(dark: Bool, accent: NSColor) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var colors: [String: String] = [:]
        appearance.performAsCurrentDrawingAppearance {
            let named: [String: NSColor] = [
                "accent": accent, "text": .labelColor, "secondary": .secondaryLabelColor,
                "fill": .quaternarySystemFill, "background": .windowBackgroundColor,
            ]
            for (name, color) in named { colors[name] = Self.hex(color) }
        }
        runtime.setTheme(dark: dark, colors: colors)
    }

    /// An image from the pack's assets/ folder (loaded once).
    func image(named name: String) -> NSImage? {
        // Screenshots and an image editor's pictures, for utilities allowed to use them.
        if name.hasPrefix("screenshot:") || name.hasPrefix("image:") {
            return PackServices.shared.images.picture(name, packID: bundle.id, capabilities: Set(bundle.manifest.capabilities ?? []))
        }
        // Pictures from the clipboard history, for utilities allowed to read it.
        if name.hasPrefix("clipboard:") {
            guard bundle.manifest.capabilities?.contains("clipboard.read") == true else { return nil }
            return PackServices.shared.clipboard.thumbnail(packID: bundle.id, id: String(name.dropFirst(10)))
        }
        if let cached = images[name] { return cached }
        guard let url = bundle.assetURL(name), let image = NSImage(contentsOf: url) else { return nil }
        images[name] = image
        return image
    }

    // MARK: PackHost

    func packDidDraw(_ shapes: [PackShape]) { self.shapes = shapes }
    func packViewChanged(_ node: PackUINode) { if node != ui { ui = node } }
    func packScoreChanged(_ text: String) { score = text }
    func packHintChanged(_ text: String) { hintText = text }
    func packOverlayChanged(_ overlay: PackOverlay?) { self.overlay = overlay }
    func packMenuChanged(_ menu: PackMenu?) { self.menu = menu }
    func packFailed(_ message: String) { failure = message }

    func packToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Helpers

    private static func packKey(_ event: NSEvent, window: Bool = false) -> PackKey? {
        var names: [UInt16: String] = [
            Key.left: "ArrowLeft", Key.right: "ArrowRight", Key.up: "ArrowUp", Key.down: "ArrowDown",
            Key.enter: "Enter", Key.keypadEnter: "Enter", Key.space: " ", Key.delete: "Backspace", Key.forwardDelete: "Backspace",
        ]
        if window { names[53] = "Escape" }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard window || !flags.contains(.command), !flags.contains(.control) else { return nil }
        var name = names[event.keyCode]
        if name == nil, let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
           let scalar = chars.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value) {
            name = chars
        }
        guard let name else { return nil }
        return PackKey(key: name, shift: flags.contains(.shift), option: flags.contains(.option),
                       isRepeat: event.type == .keyDown && event.isARepeat, command: flags.contains(.command))
    }

    private static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        let v = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return v[3] == 255 ? String(format: "#%02x%02x%02x", v[0], v[1], v[2]) : String(format: "#%02x%02x%02x%02x", v[0], v[1], v[2], v[3])
    }
}

// MARK: - Views

/// The game area: the pack's drawing list, drawn natively with Canvas, plus the standard cards.
struct PackView: View {
    let session: PackSession
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Read the state here (not inside Canvas) so SwiftUI redraws when it changes.
        let shapes = session.shapes
        let accent = settings.accent.color

        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Canvas { context, size in
                    Self.render(shapes, in: context, size: size, accent: accent, image: session.image(named:))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(ClickCatcher { point, right in session.click(at: point, right: right) })
                .accessibilityElement()
                .accessibilityLabel("\(session.bundle.manifest.name) game area")

                cards

                if let toast = session.toast {
                    GameToast(text: toast).id(toast)
                }
            }
            .onAppear {
                session.updateTheme(dark: colorScheme == .dark, accent: settings.accent.nsColor)
                session.setSize(proxy.size)
            }
            .onChange(of: proxy.size) { _, size in session.setSize(size) }
        }
        .padding(.horizontal, 12)
        .onChange(of: colorScheme) { _, scheme in session.updateTheme(dark: scheme == .dark, accent: settings.accent.nsColor) }
        .onChange(of: settings.accent) { _, accent in session.updateTheme(dark: colorScheme == .dark, accent: accent.nsColor) }
        .animation(.easeOut(duration: 0.15), value: session.overlay)
        .animation(.easeOut(duration: 0.15), value: session.isPaused)
        .animation(.easeOut(duration: 0.2), value: session.toast)
    }

    @ViewBuilder private var cards: some View {
        if let failure = session.failure {
            GameOverlay(title: "This game stopped working",
                        subtitle: session.bundle.isDev ? failure : "Go back and open it again. If it keeps happening, remove it and install it again from the Library.") {
                Button("Back") { model.closeGame() }.prominentButtonStyle()
            }
        } else if session.isPaused && session.showsPauseButton {
            GameOverlay(title: "Paused", subtitle: session.score.isEmpty ? nil : session.score) {
                Button("Resume") { session.resume() }.prominentButtonStyle()
            }
        } else if let overlay = session.overlay {
            GameOverlay(title: overlay.title, subtitle: overlay.subtitle) {
                ForEach(Array(overlay.buttons.enumerated()), id: \.offset) { index, button in
                    if button.prominent {
                        Button(button.label) { session.pressOverlayButton(index) }.prominentButtonStyle()
                    } else {
                        Button(button.label) { session.pressOverlayButton(index) }.panelButtonStyle()
                    }
                }
            }
        }
    }

    // MARK: Drawing

    static func color(_ c: PackColor, accent: Color) -> Color {
        switch c {
        case .theme("accent"): accent
        case .theme("secondary"): Color(nsColor: .secondaryLabelColor)
        case .theme("fill"): Tokens.fill
        case .theme("background"): Color(nsColor: .windowBackgroundColor)
        case .theme: Color(nsColor: .labelColor)
        case let .rgba(r, g, b, a): Color(.sRGB, red: r, green: g, blue: b, opacity: a)
        }
    }

    static func render(_ shapes: [PackShape], in base: GraphicsContext, size: CGSize, accent: Color,
                       image: (String) -> NSImage?) {
        var context = base
        var stack: [GraphicsContext] = []

        func color(_ c: PackColor) -> Color { Self.color(c, accent: accent) }
        func paint(_ path: Path, _ style: PackShape.Style) {
            let fill = style.fill ?? (style.stroke == nil ? .theme("text") : nil)
            if let fill { context.fill(path, with: .color(color(fill))) }
            if let stroke = style.stroke, style.lineWidth > 0 {
                context.stroke(path, with: .color(color(stroke)),
                               style: StrokeStyle(lineWidth: style.lineWidth, lineCap: style.round ? .round : .butt,
                                                  lineJoin: style.round ? .round : .miter))
            }
        }

        for shape in shapes {
            switch shape {
            case .clear(let c):
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color(c)))
            case let .rect(rect, radius, style):
                paint(radius > 0 ? Path(roundedRect: rect, cornerRadius: radius, style: .continuous) : Path(rect), style)
            case let .circle(center, radius, style):
                paint(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), style)
            case let .ellipse(rect, style):
                paint(Path(ellipseIn: rect), style)
            case let .shadow(c, radius, dx, dy):
                context.addFilter(.shadow(color: color(c), radius: radius, x: dx, y: dy))
            case let .symbol(name, center, size, c):
                let symbol = Text(Image(systemName: name)).font(.system(size: size * 0.8)).foregroundStyle(color(c))
                context.draw(symbol, at: center, anchor: .center)
            case let .gradient(rect, radius, colors):
                let path = radius > 0 ? Path(roundedRect: rect, cornerRadius: radius, style: .continuous) : Path(rect)
                let stops = colors.isEmpty ? [Color.clear] : colors.map(color)
                context.fill(path, with: .linearGradient(Gradient(colors: stops), startPoint: CGPoint(x: rect.minX, y: rect.minY),
                                                         endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            case let .clip(rect, radius):
                context.clip(to: radius > 0 ? Path(roundedRect: rect, cornerRadius: radius, style: .continuous) : Path(rect))
            case let .line(a, b, c, width, round):
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                context.stroke(path, with: .color(color(c)), style: StrokeStyle(lineWidth: width, lineCap: round ? .round : .butt))
            case let .path(points, closed, style):
                guard let first = points.first else { continue }
                var path = Path()
                path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
                if closed { path.closeSubpath() }
                paint(path, style)
            case let .text(string, point, size, weight, c, align, font):
                let weights: [PackShape.Weight: Font.Weight] = [.regular: .regular, .medium: .medium, .semibold: .semibold, .bold: .bold]
                let designs: [PackShape.Font: Font.Design] = [.system: .default, .rounded: .rounded, .mono: .monospaced]
                let text = Text(string).font(.system(size: size, weight: weights[weight] ?? .regular, design: designs[font] ?? .default))
                    .foregroundStyle(color(c))
                let anchor: UnitPoint = switch align { case .left: .leading; case .center: .center; case .right: .trailing }
                context.draw(text, at: point, anchor: anchor)
            case let .image(name, rect, opacity, pixelate):
                guard var nsImage = image(name) else { continue }
                if pixelate > 0, let blocks = PackImages.pixelated(nsImage, block: pixelate) { nsImage = blocks }
                var copy = context
                copy.opacity *= opacity
                copy.draw(Image(nsImage: nsImage), in: rect)
            case .save: stack.append(context)
            case .restore: if let saved = stack.popLast() { context = saved }
            case let .translate(x, y): context.translateBy(x: x, y: y)
            case .rotate(let r): context.rotate(by: .radians(r))
            case .scale(let s): context.scaleBy(x: s, y: s)
            case .alpha(let a): context.opacity = a
            }
        }
    }
}

/// The pack's header menu (for example a difficulty), drawn like the built-in games' menus.
private struct PackMenuView: View {
    let session: PackSession

    var body: some View {
        if let menu = session.menu {
            Menu {
                Picker(menu.title, selection: Binding(get: { menu.selected }, set: { session.selectMenuItem($0) })) {
                    ForEach(Array(menu.items.enumerated()), id: \.offset) { index, item in
                        Text(item).tag(index)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(menu.selected >= 0 && menu.selected < menu.items.count ? menu.items[menu.selected] : menu.title)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .headerMenuStyle()
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(menu.title): \(menu.selected >= 0 && menu.selected < menu.items.count ? menu.items[menu.selected] : "none")")
        }
    }
}

/// Reports left and right clicks (Control-click counts as right) in the view's top-left coordinates.
private struct ClickCatcher: NSViewRepresentable {
    let onClick: (CGPoint, _ right: Bool) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.onClick = onClick }

    final class CatcherView: NSView {
        var onClick: (CGPoint, Bool) -> Void = { _, _ in }
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            onClick(convert(event.locationInWindow, from: nil), event.modifierFlags.contains(.control))
        }
        override func rightMouseDown(with event: NSEvent) { onClick(convert(event.locationInWindow, from: nil), true) }
    }
}
