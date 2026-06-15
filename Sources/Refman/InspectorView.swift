import RefmanCore
import SwiftUI

/// Right-hand metadata editor for the selected document.
struct InspectorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    let details: DocumentDetails

    @State private var draft: Document
    @State private var authorsText: String
    @State private var newTag = ""

    init(details: DocumentDetails) {
        self.details = details
        _draft = State(initialValue: details.document)
        _authorsText = State(
            initialValue: details.authors.map(\.displayName).joined(separator: " and "))
    }

    var body: some View {
        Form {
            Section {
                if model.pdfURL(for: details) != nil {
                    Button {
                        openWindow(id: "reader", value: details.document.id!)
                    } label: {
                        Label("Open PDF", systemImage: "book")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
            }

            Section("Reference") {
                Picker("Type", selection: $draft.type) {
                    ForEach(DocumentType.allCases, id: \.self) { type in
                        Text(label(for: type)).tag(type)
                    }
                }
                TextField("Title", text: $draft.title, axis: .vertical).lineLimit(1...4)
                TextField("Authors", text: $authorsText, prompt: Text("Family, Given and …"))
                TextField("Year", value: $draft.year, format: .number.grouping(.never))
                TextField("Venue", text: bind(\.venue))
                TextField("Volume", text: bind(\.volume))
                TextField("Issue", text: bind(\.issue))
                TextField("Pages", text: bind(\.pages))
                TextField("DOI", text: bind(\.doi))
                TextField("arXiv ID", text: bind(\.arxivId))
                TextField("URL", text: bind(\.url))
            }

            Section("Abstract") {
                TextField("Abstract", text: bind(\.abstract), axis: .vertical)
                    .lineLimit(3...12)
                    .multilineTextAlignment(.leading)
                    .labelsHidden()
            }

            Section("Tags") {
                if !details.tags.isEmpty {
                    FlowTags(tags: details.tags) { tag in
                        model.removeTag(tag.id!)
                    }
                }
                TextField("Add tag…", text: $newTag)
                    .onSubmit {
                        model.addTag(newTag.trimmingCharacters(in: .whitespaces))
                        newTag = ""
                    }
            }

            Section {
                Button("Save Changes") { save() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(!hasChanges)
                Button("Copy BibTeX") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        BibTeX.export(currentDetails), forType: .string)
                    model.statusMessage = "BibTeX copied"
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hasChanges: Bool {
        draft != details.document
            || authorsText != details.authors.map(\.displayName).joined(separator: " and ")
    }

    private var currentDetails: DocumentDetails {
        DocumentDetails(document: draft, authors: parsedAuthors, tags: details.tags)
    }

    private var parsedAuthors: [Author] {
        authorsText
            .components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(BibTeX.parseAuthorName)
    }

    private func save() {
        model.update(draft, authors: parsedAuthors)
    }

    /// Binds an optional String field, mapping "" <-> nil.
    private func bind(_ keyPath: WritableKeyPath<Document, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func label(for type: DocumentType) -> String {
        switch type {
        case .article: return "Journal Article"
        case .book: return "Book"
        case .chapter: return "Book Chapter"
        case .conferencePaper: return "Conference Paper"
        case .thesis: return "Thesis"
        case .report: return "Report"
        case .preprint: return "Preprint"
        case .webpage: return "Web Page"
        case .misc: return "Other"
        }
    }
}

/// Simple wrapping tag chips with delete.
struct FlowTags: View {
    let tags: [Tag]
    let onDelete: (Tag) -> Void

    var body: some View {
        FlexibleHStack(spacing: 6) {
            ForEach(tags, id: \.id) { tag in
                HStack(spacing: 4) {
                    Text(tag.name).font(.callout)
                    Button {
                        onDelete(tag)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.quaternary))
            }
        }
    }
}

/// Minimal flow layout.
struct FlexibleHStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
