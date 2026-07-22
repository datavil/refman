import RefmanCore
import SwiftUI

/// Right-hand metadata editor for the selected document.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    let details: DocumentDetails

    @State private var draft: Document
    @State private var authorsText: String
    @State private var newTag = ""
    @State private var isEditingAbstract = false
    @FocusState private var abstractFocused: Bool

    init(details: DocumentDetails) {
        self.details = details
        _draft = State(initialValue: details.document)
        _authorsText = State(
            initialValue: details.authors.map(\.displayName).joined(separator: " and "))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pdfURL = model.pdfURL(for: details),
                let documentID = details.document.id
            {
                Button {
                    openWindow(id: "reader", value: documentID)
                } label: {
                    VStack {
                        Label("Open PDF", systemImage: "book")
                        PDFPageThumbnail(url: pdfURL)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.vertical)
                .accessibilityLabel("Open PDF")
                .help("Open PDF")
            }

            Form {
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

                Section {
                    ScrollableMaxHeight(maxHeight: 220) {
                        if isEditingAbstract {
                            TextField("Abstract", text: bind(\.abstract), axis: .vertical)
                                .lineLimit(3...)
                                .multilineTextAlignment(.leading)
                                .labelsHidden()
                                .focused($abstractFocused)
                        } else if let abstract = draft.abstract, !abstract.isEmpty {
                            Text(abstract)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("No abstract available.")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Abstract")
                        Spacer()
                        Button(
                            isEditingAbstract ? "Done" : "Edit",
                            systemImage: isEditingAbstract ? "checkmark" : "pencil"
                        ) {
                            isEditingAbstract.toggle()
                            abstractFocused = isEditingAbstract
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }

                insightSection("Summary", \.summary, insight: .summary, action: "Summarize")
                insightSection("Key Points", \.keyPoints, insight: .keyPoints, action: "Key Points")
                insightSection("Methods", \.methods, insight: .methods, action: "Methods")
                insightSection("Limitations", \.limitations, insight: .limitations, action: "Limitations")

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
                    Button("Save Changes") {
                        save()
                        isEditingAbstract = false
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(!hasChanges)
                }
            }
            .formStyle(.grouped)
            // Insights are generated elsewhere (the AI panel or library menu); keep
            // the editable draft in sync so saving metadata edits never clobbers them.
            .onChange(of: details.document) {
                draft.summary = details.document.summary
                draft.keyPoints = details.document.keyPoints
                draft.methods = details.document.methods
                draft.limitations = details.document.limitations
            }
            // Refresh a newly extracted abstract without discarding an unsaved edit.
            .onChange(of: details.document.abstract) { previous, abstract in
                if draft.abstract == previous {
                    draft.abstract = abstract
                }
            }
        }
    }

    /// A read-only section rendering one AI insight as Markdown, with a hint
    /// pointing at the generating command when empty.
    @ViewBuilder
    private func insightSection(
        _ title: String, _ keyPath: KeyPath<Document, String?>,
        insight: DocumentInsight, action: String
    ) -> some View {
        Section(title) {
            if let id = details.document.id, model.isGeneratingInsight(insight, for: id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Generating…").foregroundStyle(.secondary)
                }
            } else if let text = draft[keyPath: keyPath]?.trimmingCharacters(in: .whitespaces),
                !text.isEmpty
            {
                ScrollableMaxHeight(maxHeight: 220) {
                    MarkdownText(text: text).textSelection(.enabled)
                }
            } else {
                Text("Right-click the paper → \(action) to generate this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasChanges: Bool {
        draft != details.document
            || authorsText != details.authors.map(\.displayName).joined(separator: " and ")
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

/// Scrolls its content once it grows past `maxHeight`, but hugs the content
/// (no empty box) while it's shorter — used for long abstracts/summaries.
struct ScrollableMaxHeight<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ContentHeightKey.self, value: geo.size.height)
                    })
        }
        // Hug content until it exceeds the cap, then lock to the cap and scroll.
        .frame(height: contentHeight == 0 ? nil : min(contentHeight, maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
