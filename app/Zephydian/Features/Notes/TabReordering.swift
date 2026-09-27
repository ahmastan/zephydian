import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Private type for dragging note tabs (declared in project.yml). Text views ignore it,
    /// so dropping a tab onto the note can't paste anything into it.
    static let zephydianNoteTab = UTType(exportedAs: "com.ahmastan.zephydian.note-tab")
}

extension NSItemProvider {
    /// A drag item carrying a note's id, visible only inside Zephydian.
    static func noteTab(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data(id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.zephydianNoteTab.identifier, visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }
}

/// Reorders tabs live while dragging: as the dragged tab passes over another, they swap places.
struct NoteTabDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggingID: UUID?
    let notes: NotesStore

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.zephydianNoteTab]) && draggingID != nil
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != targetID else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            notes.move(draggingID, to: targetID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}
