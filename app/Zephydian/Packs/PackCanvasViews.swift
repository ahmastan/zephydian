import AppKit
import SwiftUI

// Views behind SDK 3's editing controls: a canvas that fills its space and takes the pointer
// (an image editor's picture), and the buttons of a floating toolbar.

/// How a canvas's own units fit into the space it has: scaled down to fit (never up past one point
/// per unit) and centered.
nonisolated struct FitLayout: Equatable {
    var scale: CGFloat
    var origin: CGPoint

    init(content: CGSize, in space: CGSize) {
        let s = min(space.width / max(content.width, 1), space.height / max(content.height, 1), 1)
        scale = max(s, 0.001)
        origin = CGPoint(x: ((space.width - content.width * scale) / 2).rounded(),
                         y: ((space.height - content.height * scale) / 2).rounded())
    }

    func units(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }
    func points(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
}

/// A `z.ui.canvas` with `fit`: the pack's drawing, scaled to fit, plus pointer events, a live
/// freehand line (`ink`) and a text field (`textEdit`) over it. Content, so no glass.
struct PackFitCanvas: View {
    let canvas: PackCanvas
    let session: PackSession
    let send: (String, Any) -> Void

    @Environment(SettingsStore.self) private var settings
    /// The freehand line being drawn, in canvas units. Drawn here, so it keeps up with the pointer.
    @State private var live: [CGPoint] = []

    var body: some View {
        // Read the state here (not inside Canvas) so SwiftUI redraws when it changes.
        let accent = settings.accent.color
        let shapes = canvas.shapes, fit = canvas.fit ?? CGSize(width: 1, height: 1), ink = canvas.ink, live = live
        GeometryReader { proxy in
            let layout = FitLayout(content: fit, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    var c = context
                    c.translateBy(x: layout.origin.x, y: layout.origin.y)
                    c.scaleBy(x: layout.scale, y: layout.scale)
                    c.clip(to: Path(CGRect(origin: .zero, size: fit)))
                    PackView.render(shapes, in: c, size: fit, accent: accent, image: session.image(named:))
                    if let ink, let first = live.first {
                        var path = Path()
                        path.move(to: first)
                        live.dropFirst().forEach { path.addLine(to: $0) }
                        if live.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
                        c.opacity = ink.opacity
                        c.stroke(path, with: .color(PackView.color(ink.color, accent: accent)),
                                 style: StrokeStyle(lineWidth: ink.width, lineCap: .round, lineJoin: .round))
                    }
                }
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)

                PointerCatcher(layout: layout, cursor: canvas.cursor, inking: ink != nil && canvas.stroke, listens: canvas.pointer,
                               hovers: canvas.hover,
                               pointer: { type, point, event in
                                   send(type == "hover" ? "onHover" : "onPointer", Self.pointerEvent(type, point, event, scale: layout.scale))
                               },
                               inkMoved: { point in
                                   if let last = self.live.last, hypot(last.x - point.x, last.y - point.y) * layout.scale < 1 { return }
                                   self.live.append(point)
                               },
                               inkEnded: { event in
                                   let points = Self.simplify(self.live, tolerance: 0.5 / layout.scale)
                                   self.live = []
                                   guard !points.isEmpty else { return }
                                   send("onStroke", ["points": points.prefix(5000).map { [Double($0.x), Double($0.y)] },
                                                     "shift": event.modifierFlags.contains(.shift)] as [String: Any])
                               })

                if let edit = canvas.textEdit {
                    let at = layout.points(CGPoint(x: edit.x, y: edit.y))
                    let size = max(6, edit.size * layout.scale)
                    CanvasTextField(text: edit.text, fontSize: size, color: NSColor(PackView.color(edit.color, accent: accent)),
                                    change: { send("onTextChange", $0) }, end: { send("onTextEnd", $0) })
                        .id(edit.id)
                        .frame(width: max(120, proxy.size.width - at.x - 8), height: size * 1.4)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .offset(x: at.x - 4, y: at.y - size * 0.7)
                }
            }
            .onAppear { if canvas.layout { send("onLayout", ["scale": Double(layout.scale)]) } }
            .onChange(of: layout.scale) { _, scale in if canvas.layout { send("onLayout", ["scale": Double(scale)]) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Image")
    }

    private static func pointerEvent(_ type: String, _ p: CGPoint, _ event: NSEvent, scale: CGFloat) -> [String: Any] {
        let flags = event.modifierFlags
        return ["type": type, "x": Double(p.x), "y": Double(p.y), "shift": flags.contains(.shift), "option": flags.contains(.option),
                "command": flags.contains(.command), "clicks": event.type == .leftMouseDown ? event.clickCount : 0,
                "scale": Double(scale)]
    }

    /// Fewer points along the same line (Ramer–Douglas–Peucker), so long strokes stay small.
    nonisolated static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let p = points[a], q = points[b]
            let dx = q.x - p.x, dy = q.y - p.y, length = max(hypot(dx, dy), 0.0001)
            var worst = 0 as CGFloat, index = a
            for i in (a + 1)..<b {
                let d = abs(dy * points[i].x - dx * points[i].y + q.x * p.y - q.y * p.x) / length
                if d > worst { worst = d; index = i }
            }
            if worst > tolerance {
                keep[index] = true
                stack.append((a, index))
                stack.append((index, b))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}

/// Mouse down, drag and up over the canvas, in canvas units, with the pack's cursor.
private struct PointerCatcher: NSViewRepresentable {
    let layout: FitLayout
    let cursor: String?
    let inking: Bool
    let listens: Bool
    let hovers: Bool
    let pointer: (String, CGPoint, NSEvent) -> Void
    let inkMoved: (CGPoint) -> Void
    let inkEnded: (NSEvent) -> Void

    func makeNSView(context: Context) -> PointerView { PointerView() }

    func updateNSView(_ view: PointerView, context: Context) {
        view.layout = layout
        view.inking = inking
        view.listens = listens
        view.hovers = hovers
        view.pointer = pointer
        view.inkMoved = inkMoved
        view.inkEnded = inkEnded
        let next = Self.cursor(cursor)
        if next != view.cursor {
            view.cursor = next
            view.window?.invalidateCursorRects(for: view)
        }
    }

    static func cursor(_ name: String?) -> NSCursor {
        switch name {
        case "crosshair": return .crosshair
        case "text": return .iBeam
        case "move": return .openHand
        case "pointer": return .pointingHand
        case "resize-nwse", "resize-nesw", "resize-ns", "resize-ew":
            // The window-edge resize arrows (macOS 15+); up/down and left/right ones before that.
            if #available(macOS 15, *) {
                let position: NSCursor.FrameResizePosition = switch name {
                case "resize-nwse": .topLeft
                case "resize-nesw": .topRight
                case "resize-ns": .top
                default: .left
                }
                return .frameResize(position: position, directions: .all)
            }
            return name == "resize-ew" ? .resizeLeftRight : name == "resize-ns" ? .resizeUpDown : .crosshair
        default: return .arrow
        }
    }

    final class PointerView: NSView {
        var layout = FitLayout(content: CGSize(width: 1, height: 1), in: CGSize(width: 1, height: 1))
        var inking = false
        var listens = false
        var hovers = false
        var cursor = NSCursor.arrow
        var pointer: (String, CGPoint, NSEvent) -> Void = { _, _, _ in }
        var inkMoved: (CGPoint) -> Void = { _ in }
        var inkEnded: (NSEvent) -> Void = { _ in }
        private var drawing = false

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func mouseMoved(with event: NSEvent) {
            if hovers && !drawing { pointer("hover", units(event), event) }
        }

        private func units(_ event: NSEvent) -> CGPoint { layout.units(convert(event.locationInWindow, from: nil)) }

        override func mouseDown(with event: NSEvent) {
            // Clicking the picture ends typing in a text field first (it reports its text).
            window?.makeFirstResponder(self)
            drawing = inking
            if drawing { inkMoved(units(event)) } else if listens { pointer("down", units(event), event) }
        }

        override func mouseDragged(with event: NSEvent) {
            if drawing { inkMoved(units(event)) } else if listens { pointer("move", units(event), event) }
        }

        override func mouseUp(with event: NSEvent) {
            if drawing { drawing = false; inkEnded(event) } else if listens { pointer("up", units(event), event) }
        }
    }
}

/// Typing a text label on the canvas. AppKit's field reports reliably when typing ends (Enter, Esc,
/// clicking elsewhere), like the notes' rename field.
private struct CanvasTextField: NSViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let color: NSColor
    let change: (String) -> Void
    let end: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Text")
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.moveToEndOfDocument(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = color
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CanvasTextField
        private var finished = false

        init(parent: CanvasTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.change(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !finished, let field = notification.object as? NSTextField else { return }
            finished = true
            parent.end(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Enter and Esc both finish typing (Esc keeps what was typed; ⌘Z takes it back).
            if selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.insertNewline(_:)) {
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

/// A button in a `z.ui.toolbar`: an icon, a line-weight glyph or short text, with a hover and a
/// selected state, so a set of tools reads like one control. It sits on the toolbar's glass, so it
/// has none of its own; a prominent one (the main action) is filled with the accent.
struct ToolbarButton: View {
    let label: String
    let symbol: String?
    let selected: Bool
    let destructive: Bool
    var prominent = false
    var badge: String?
    var bar: Double = 0
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.packToolbarVertical) private var vertical
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                content
                if let badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .padding(2)
                        .opacity(hovering || selected ? 0.9 : 0.55)
                        .accessibilityHidden(true)
                }
            }
            .background(shape.fill(fill))
            .overlay {
                if selected && contrast == .increased { shape.strokeBorder(.tint, lineWidth: 1) }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
            .scaleEffect(hovering && !selected && !prominent && !reduceMotion ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { hovering = inside } }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: symbol == nil && bar == 0 ? 13 : 9, style: .continuous) }

    private var fill: AnyShapeStyle {
        if prominent { return AnyShapeStyle(.tint) }
        if selected { return AnyShapeStyle(Color.accentColor.opacity(0.22)) }
        return hovering && isEnabled ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(.clear)
    }

    private var foreground: AnyShapeStyle {
        if prominent { return AnyShapeStyle(.white) }
        if selected { return AnyShapeStyle(.tint) }
        return destructive ? AnyShapeStyle(.red) : AnyShapeStyle(Color.primary.opacity(0.85))
    }

    @ViewBuilder private var content: some View {
        if bar > 0 {
            Capsule()
                .fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.6)))
                .frame(width: 15, height: bar)
                .frame(width: 25, height: 24)
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: vertical ? 13.5 : 13, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: vertical ? 33 : 26, height: vertical ? 29 : 24)
        } else {
            Text(label)
                .font(.system(size: 12, weight: prominent ? .semibold : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .frame(height: 24)
        }
    }
}

/// A `z.ui.menu`: a button with a menu of choices, ticked at the chosen one. With a primary action
/// (Save, with Save As… in its menu) clicking the button does that, and its arrow opens the menu.
struct PackMenuButton: View {
    let label: String
    let symbol: String?
    let items: [String]
    let selected: Int
    let primary: Bool
    let prominent: Bool
    let inToolbar: Bool
    let press: () -> Void
    let select: (Int) -> Void

    var body: some View {
        Group {
            if primary {
                Menu { choices } label: { title } primaryAction: { press() }
            } else {
                Menu { choices } label: { title }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(inToolbar && symbol != nil && !primary ? .hidden : .visible)
        .fixedSize()
        .font(.system(size: 12, weight: prominent ? .semibold : .medium))
        .padding(.horizontal, inToolbar ? 4 : 0)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var choices: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            Button { select(index) } label: {
                if index == selected { Label(item, systemImage: "checkmark") } else { Text(item) }
            }
        }
    }

    @ViewBuilder private var title: some View {
        if let symbol, label.isEmpty || inToolbar && !primary {
            Image(systemName: symbol)
        } else if let symbol {
            Label(label, systemImage: symbol)
        } else {
            Text(label)
        }
    }
}
