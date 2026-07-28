import SwiftUI

struct DocumentActionButton: View {
    let isInTrash: Bool
    let model: IPadAppModel

    var body: some View {
        if isInTrash {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                model.restoreSelectedDocument()
            }
        } else {
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                model.moveSelectedDocumentToTrash()
            }
        }
    }
}
