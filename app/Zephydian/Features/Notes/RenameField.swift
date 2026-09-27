import AppKit
import SwiftUI

/// An inline text field for renaming a note tab.
///
/// Built on AppKit's NSTextField because it reliably reports when editing ends,
/// however that happens (Enter, clicking into the note, clicking another tab…).
/// Enter or losing focus commits; Esc cancels.
struct RenameField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Note name")
        // Take the cursor once the field is on screen, with the whole name selected.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameField
        private var finished = false

        init(parent: RenameField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // Called for Enter, Tab, clicking elsewhere, or the field disappearing.
        func controlTextDidEndEditing(_ notification: Notification) {
            finish(commit: true)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { // Esc
                finish(commit: false)
                return true
            }
            return false
        }

        private func finish(commit: Bool) {
            guard !finished else { return }
            finished = true
            commit ? parent.onCommit() : parent.onCancel()
        }
    }
}
