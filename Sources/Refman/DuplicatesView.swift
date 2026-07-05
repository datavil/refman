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

    private var newestID: Int64? {
        group.max { $0.document.addedAt < $1.document.addedAt }?.id
    }

    private var oldestID: Int64? {
        group.min { $0.document.addedAt < $1.document.addedAt }?.id
    }

    var body: some View {
        Section {
            ForEach(group.sorted { $0.document.addedAt > $1.document.addedAt }) { details in
                DuplicateRow(
                    details: details,
                    addedDateEmphasis: details.id == newestID
                        ? .newest : details.id == oldestID ? .oldest : .none,
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
    @State private var highlightCount = 0
    let details: DocumentDetails
    let addedDateEmphasis: AddedDateEmphasis
    let keep: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center) {
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

                    HStack {
                        Label {
                            Text(
                                "\(addedDateEmphasis.label)Added \(details.document.addedAt.formatted(date: .abbreviated, time: .shortened))"
                            )
                        } icon: {
                            Image(systemName: addedDateEmphasis.systemImage)
                        }
                        .foregroundStyle(addedDateEmphasis.color)

                        if highlightCount > 0 {
                            Label(
                                "\(highlightCount) \(highlightCount == 1 ? "Highlight" : "Highlights")",
                                systemImage: "highlighter"
                            )
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.yellow.opacity(0.45), in: .capsule)
                        }
                    }
                    .font(.subheadline)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            HStack {
                Button("Keep", action: keep)
                    .help("Move the other copies in this group to the Trash")
                Button(role: .destructive, action: remove) {
                    Label("Remove", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help("Move this copy to the Trash")
            }
        }
        .task(id: details.id) {
            highlightCount =
                (try? model.repository.annotations(documentId: details.id))?
                .count(where: { $0.kind == .highlight }) ?? 0
        }
    }
}

private enum AddedDateEmphasis {
    case newest
    case oldest
    case none

    var label: String {
        switch self {
        case .newest: "Newest · "
        case .oldest: "Oldest · "
        case .none: ""
        }
    }

    var systemImage: String {
        switch self {
        case .newest: "leaf.fill"
        case .oldest: "hourglass.bottomhalf.filled"
        case .none: "calendar"
        }
    }

    var color: Color {
        switch self {
        case .newest: .green
        case .oldest: .orange
        case .none: .secondary
        }
    }
}
