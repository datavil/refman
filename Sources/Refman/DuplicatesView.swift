import RefmanCore
import SwiftUI

/// Mendeley-style duplicate resolver: live references that share a DOI or arXiv
/// ID, grouped so the user can keep one copy and trash the rest.
struct DuplicatesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.duplicateGroups.isEmpty {
                ContentUnavailableView(
                    "No Duplicates", systemImage: "square.on.square",
                    description: Text("References that share a DOI or arXiv ID appear here."))
            } else {
                List {
                    ForEach(model.duplicateGroups, id: \.first?.id) { group in
                        DuplicateGroupSection(group: group)
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
    }
}

/// One set of references for the same paper.
private struct DuplicateGroupSection: View {
    @Environment(AppModel.self) private var model
    let group: [DocumentDetails]

    var body: some View {
        Section {
            ForEach(group) { details in
                DuplicateRow(
                    details: details,
                    keep: { keep(details.id) },
                    remove: { model.delete(documentIds: [details.id]) })
            }
        } header: {
            Text(group.first?.document.title ?? "Duplicate")
        }
    }

    /// Keeps one copy, trashing the others in this group.
    private func keep(_ id: Int64) {
        model.delete(documentIds: group.map(\.id).filter { $0 != id })
    }
}

private struct DuplicateRow: View {
    @Environment(AppModel.self) private var model
    let details: DocumentDetails
    let keep: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Button {
                model.selectedDocumentId = details.id
                model.selectedDocumentIds = [details.id]
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(details.document.title).lineLimit(2)
                    HStack(spacing: 8) {
                        if !details.authorsText.isEmpty {
                            Text(details.authorsText).lineLimit(1)
                        }
                        if let year = details.document.year {
                            Text(year, format: .number.grouping(.never))
                        }
                        if details.document.fileHash != nil {
                            Image(systemName: "document.circle").imageScale(.large)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    Text("Added \(details.document.addedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .bold()
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Keep", action: keep)
                .help("Move the other copies in this group to the Trash")
            Button(role: .destructive, action: remove) {
                Label("Remove", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .help("Move this copy to the Trash")
        }
    }
}
