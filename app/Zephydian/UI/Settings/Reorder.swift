import SwiftUI
import UniformTypeIdentifiers

// Drag-to-reorder for rows in the Settings window. SwiftUI's `onMove` does nothing inside a grouped
// `Form` on macOS, so rows are dragged with `onDrag` and slide into place as the drag passes over
// the others (the list is reordered live, so no drop line is needed).

extension View {
    /// Makes a row draggable within its list. `dragging` is shared by the rows of one list;
    /// `move(dragged, target)` puts the dragged row where the target row is.
    func reorderable<ID: Hashable>(_ id: ID, dragging: Binding<ID?>, move: @escaping (ID, ID) -> Void) -> some View {
        onDrag {
            dragging.wrappedValue = id
            return NSItemProvider(object: "\(id)" as NSString)
        }
        .onDrop(of: [.plainText], delegate: ReorderDropDelegate(target: id, dragging: dragging, move: move))
    }
}

private struct ReorderDropDelegate<ID: Hashable>: DropDelegate {
    let target: ID
    @Binding var dragging: ID?
    let move: (ID, ID) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragged = dragging, dragged != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { move(dragged, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

extension Array where Element: Equatable {
    /// Moves `element` to where `target` is (after it when moving down, before it when moving up).
    mutating func move(_ element: Element, onto target: Element) {
        guard let from = firstIndex(of: element), let to = firstIndex(of: target), from != to else { return }
        move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }
}
