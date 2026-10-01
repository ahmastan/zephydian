import AppKit
import SwiftUI

/// Line sizes in notes are Markdown headings, so the file stays plain Markdown that any app
/// shows the same way: ⌘+ turns a line into ### → ## → #, ⌘− goes back, ⌘0 makes it normal text.
enum NoteHeadings {
    static let baseSize: CGFloat = 13

    /// How much bigger each heading level is than normal text (levels 4 to 6 are bold only).
    static func scale(_ level: Int) -> CGFloat {
        switch level {
        case 1: 1.5
        case 2: 1.3
        case 3: 1.15
        default: 1
        }
    }

    /// The heading level of a line (0 for normal text) and how many characters its `# ` takes.
    static func prefix(of line: String) -> (level: Int, length: Int) {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return (0, 0) }
        let rest = line.dropFirst(hashes)
        if rest.isEmpty || rest.first == "\n" { return (hashes, hashes) }
        guard rest.first == " " else { return (0, 0) }
        return (hashes, hashes + 1)
    }

    /// The level after one step bigger (+1) or smaller (-1): normal → ### → ## → #.
    static func step(_ level: Int, by direction: Int) -> Int {
        let ladder = [0, 3, 2, 1]
        // Levels 4 to 6 sit between normal text and ###.
        let rank = ladder.firstIndex(of: level) ?? (direction > 0 ? 0 : 1)
        return ladder[max(0, min(ladder.count - 1, rank + direction))]
    }
}

/// The note editor: plain text, with heading lines shown larger and their `#` marks faint.
struct NoteEditor: NSViewRepresentable {
    let text: String
    let monospaced: Bool
    /// Changing this puts the cursor in the editor.
    var focusRequest = 0
    let onChange: (String) -> Void
    var onFocus: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = NoteTextView(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false   // Markdown wants straight quotes and dashes
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Note text")
        textView.delegate = context.coordinator
        textView.monospaced = monospaced
        textView.onFocus = onFocus
        textView.string = text
        textView.restyle()
        scroll.documentView = textView
        context.coordinator.lastFocusRequest = focusRequest
        if focusRequest > 0 { textView.focusWhenShown() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NoteTextView else { return }
        textView.onFocus = onFocus
        var needsStyle = false
        if textView.monospaced != monospaced {
            textView.monospaced = monospaced
            needsStyle = true
        }
        // Changed somewhere else (a ticked box, another window, another app): show it, keeping the cursor.
        if textView.string != text, !textView.hasMarkedText() {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            needsStyle = true
        }
        if needsStyle { textView.restyle() }
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            textView.focusWhenShown()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        var lastFocusRequest = 0

        init(_ parent: NoteEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NoteTextView else { return }
            textView.restyle()
            parent.onChange(textView.string)
        }
    }
}

final class NoteTextView: NSTextView {
    var monospaced = false
    var onFocus: (Bool) -> Void = { _ in }
    private var wantsFocus = false

    private var baseFont: NSFont {
        monospaced ? .monospacedSystemFont(ofSize: NoteHeadings.baseSize - 0.5, weight: .regular)
                   : .systemFont(ofSize: NoteHeadings.baseSize)
    }

    private func headingFont(_ level: Int) -> NSFont {
        let size = (NoteHeadings.baseSize - (monospaced ? 0.5 : 0)) * NoteHeadings.scale(level)
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        return monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }

    /// Re-applies the look: normal text, then larger heading lines with faint `#` marks
    /// (not inside ``` code blocks).
    func restyle() {
        guard let storage = textStorage, !hasMarkedText() else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let text = storage.string as NSString
        storage.beginEditing()
        storage.setAttributes(base, range: NSRange(location: 0, length: text.length))
        var inCode = false
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines]) { line, range, _, _ in
            guard let line else { return }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); return }
            guard !inCode else { return }
            let heading = NoteHeadings.prefix(of: line)
            guard heading.level > 0 else { return }
            storage.addAttribute(.font, value: self.headingFont(heading.level), range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                 range: NSRange(location: range.location, length: min(heading.length, range.length)))
        }
        storage.endEditing()
        typingAttributes = base
    }

    /// ⌘+ / ⌘− / ⌘0 change the size of the current line (or of every selected line).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift)
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "=", "+": changeLineSize(by: 1)
        case "-", "_": changeLineSize(by: -1)
        case "0": changeLineSize(by: 0)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// One step bigger (+1), smaller (-1), or back to normal text (0), as an undoable edit.
    func changeLineSize(by direction: Int) {
        let text = string as NSString
        let selection = selectedRange()
        let lines = text.lineRange(for: selection)
        // An empty last line (the cursor after the final return) has no characters to enumerate.
        if lines.length == 0 {
            guard direction > 0 else { return }
            insertText("### ", replacementRange: selection)
            return
        }
        var replacement = ""
        var firstDelta: Int?, totalDelta = 0
        text.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            let line = text.substring(with: enclosing)
            let old = NoteHeadings.prefix(of: line)
            let level = direction == 0 ? 0 : NoteHeadings.step(old.level, by: direction)
            let body = String(line.dropFirst(old.length))
            let prefix = level == 0 ? "" : String(repeating: "#", count: level) + " "
            let delta = (prefix as NSString).length - old.length
            if firstDelta == nil { firstDelta = delta }
            totalDelta += delta
            replacement += prefix + body
        }
        guard replacement != text.substring(with: lines), shouldChangeText(in: lines, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: lines, with: replacement)
        didChangeText()
        let first = firstDelta ?? 0
        let start = max(lines.location, selection.location + first)
        setSelectedRange(NSRange(location: start, length: max(0, selection.length + totalDelta - first)))
    }

    /// Takes the cursor now, or as soon as the view is in a window.
    func focusWhenShown() {
        if let window { window.makeFirstResponder(self) } else { wantsFocus = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus, let window {
            wantsFocus = false
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus(false) }
        return resigned
    }
}
