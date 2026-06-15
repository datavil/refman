import AppKit
import QuickLook
import RefmanCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(SettingsKeys.rowDensity) private var rowDensity = RowDensity.comfortable.rawValue
    @State private var newCollectionName = ""
    @State private var showingNewCollection = false
    @State private var collectionToDelete: RefmanCore.Collection?
    @State private var subcollectionParent: RefmanCore.Collection?
    @State private var subcollectionName = ""
    @State private var previewURL: URL?
    @State private var showingAddPopover = false
    @State private var identifierText = ""
    @State private var sortOrder = [KeyPathComparator(\DocumentDetails.sortTitle)]
    @State private var columnCustomization = TableColumnCustomization<DocumentDetails>()
    @State private var showingImportReport = false
    @State private var showingPalette = false

    private var density: RowDensity { RowDensity(rawValue: rowDensity) ?? .comfortable }
    private var inTrash: Bool { model.sidebarSelection == .trash }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            documentTable
                .navigationSplitViewColumnWidth(min: 400, ideal: 560)
        } detail: {
            if let details = model.selectedDocument {
                InspectorView(details: details)
                    .id(details.document.id)  // reset editing state on selection change
            } else {
                ContentUnavailableView(
                    "No Selection", systemImage: "doc.text",
                    description: Text("Select a document, or drop PDFs anywhere to import."))
            }
        }
        .searchable(text: $model.searchText, prompt: "Search title, authors, full text")
        // Defer reloads off the current update cycle: mutating the Table's data
        // synchronously from .onChange reenters the backing NSTableView delegate.
        .onChange(of: model.searchText) { Task { @MainActor in model.reload() } }
        .onChange(of: model.sidebarSelection) { Task { @MainActor in model.reload() } }
        .onChange(of: appearance, initial: true) {
            // Drive AppKit appearance too, so panels and sheets follow along.
            switch AppAppearance(rawValue: appearance) ?? .system {
            case .system: NSApp.appearance = nil
            case .light: NSApp.appearance = NSAppearance(named: .aqua)
            case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        }
        .quickLookPreview($previewURL)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onChange(of: model.addRequested) { showingAddPopover = true }
        .onChange(of: model.paletteRequested) { showingPalette = true }
        .sheet(isPresented: $showingPalette) {
            CommandPalette(isPresented: $showingPalette)
        }
        .sheet(isPresented: $showingImportReport) {
            ImportReportView(outcomes: model.importLog)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showingAddPopover = true
                } label: {
                    Label("Add Reference", systemImage: "plus.circle")
                }
                .help("Add a reference")
                .popover(isPresented: $showingAddPopover, arrowEdge: .bottom) {
                    addPopover
                }
            }
            if inTrash {
                ToolbarItem {
                    Button(role: .destructive) {
                        model.emptyTrash()
                    } label: {
                        Label("Empty Trash", systemImage: "trash.slash")
                    }
                    .help("Permanently delete all documents in the Trash")
                    .disabled(model.documents.isEmpty)
                }
            }
            ToolbarItem {
                if let progress = model.importProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(progress.done)/\(progress.total)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.isImporting {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.statusMessage {
                HStack {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if hasImportReport {
                        Button("Report") { showingImportReport = true }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(6)
                .background(.bar)
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    if model.statusMessage == message { model.statusMessage = nil }
                }
            }
        }
    }

    /// The last import had something worth reporting (a duplicate or failure).
    private var hasImportReport: Bool {
        model.importLog.contains { $0.status != .imported }
    }

    private var sidebar: some View {
        List(selection: $model.sidebarSelection) {
            Section("Library") {
                Label("All Documents", systemImage: "books.vertical")
                    .tag(SidebarItem.all)
                Label("Recently Added", systemImage: "clock")
                    .tag(SidebarItem.recent)
                Label("Uncategorized", systemImage: "tray")
                    .tag(SidebarItem.uncategorized)
                Label("Trash", systemImage: "trash")
                    .tag(SidebarItem.trash)
            }
            Section("Collections") {
                CollectionTree(
                    parentId: nil,
                    collectionToDelete: $collectionToDelete,
                    subcollectionParent: $subcollectionParent)
                if showingNewCollection {
                    TextField("Collection name", text: $newCollectionName)
                    .onSubmit {
                        if !newCollectionName.isEmpty {
                            model.createCollection(named: newCollectionName)
                        }
                        newCollectionName = ""
                        showingNewCollection = false
                    }
                }
                Button {
                    showingNewCollection = true
                } label: {
                    Label("New Collection", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if !model.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.tags, id: \.id) { tag in
                        Label(tag.name, systemImage: "tag")
                            .tag(SidebarItem.tag(tag.id!))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog(
            "Delete “\(collectionToDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { collectionToDelete != nil },
                set: { if !$0 { collectionToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = collectionToDelete?.id { model.deleteCollection(id: id) }
                collectionToDelete = nil
            }
        } message: {
            Text("Subcollections are also deleted. Documents stay in the library.")
        }
        .alert(
            "New Subcollection in “\(subcollectionParent?.name ?? "")”",
            isPresented: Binding(
                get: { subcollectionParent != nil },
                set: { if !$0 { subcollectionParent = nil } }
            )
        ) {
            TextField("Name", text: $subcollectionName)
            Button("Create") {
                if let parent = subcollectionParent, !subcollectionName.isEmpty {
                    model.createCollection(named: subcollectionName, parentId: parent.id)
                }
                subcollectionName = ""
            }
            Button("Cancel", role: .cancel) { subcollectionName = "" }
        }
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(10)
            .help("Refman Settings (⌘,)")
        }
    }

    fileprivate static let collectionIcons: [(group: String, icons: [(name: String, symbol: String)])] = [
        (
            "Library",
            [
                ("Folder", "folder"), ("Books", "books.vertical"), ("Book", "book.closed"),
                ("Document", "doc.text"), ("Archive", "archivebox"), ("Tray", "tray.full"),
                ("Bookmark", "bookmark"), ("Tag", "tag"), ("Pin", "pin"),
                ("Paperclip", "paperclip"),
            ]
        ),
        (
            "Science",
            [
                ("Flask", "flask"), ("Test Tube", "testtube.2"), ("Microbe", "microbe"),
                ("Allergens", "allergens"), ("Atom", "atom"), ("Brain", "brain"),
                ("Syringe", "syringe"), ("Pills", "pills"), ("Stethoscope", "stethoscope"),
                ("Leaf", "leaf"), ("Pawprint", "pawprint"), ("Fish", "fish"),
                ("Bird", "bird"),
            ]
        ),
        (
            "Data",
            [
                ("Bar Chart", "chart.bar"), ("Trend", "chart.line.uptrend.xyaxis"),
                ("Function", "function"), ("Square Root", "x.squareroot"),
                ("Terminal", "terminal"), ("Gear", "gearshape"),
            ]
        ),
        (
            "Symbols",
            [
                ("Star", "star"), ("Heart", "heart"), ("Flag", "flag"), ("Bolt", "bolt"),
                ("Flame", "flame"), ("Drop", "drop"), ("Snowflake", "snowflake"),
                ("Sun", "sun.max"), ("Moon", "moon"), ("Sparkles", "sparkles"),
                ("Globe", "globe"), ("Map", "map"), ("Clock", "clock"),
                ("Calendar", "calendar"), ("Lightbulb", "lightbulb"),
                ("Graduation Cap", "graduationcap"), ("People", "person.2"),
                ("Museum", "building.columns"), ("Puzzle", "puzzlepiece"),
                ("Cube", "cube"), ("Palette", "paintpalette"), ("Camera", "camera"),
                ("Music Note", "music.note"), ("Eye", "eye"),
            ]
        ),
    ]

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add by Identifier").font(.headline)
            HStack(spacing: 8) {
                TextField("DOI, PubMed ID, arXiv ID, or link", text: $identifierText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitIdentifier)
                Button("Add", action: submitIdentifier)
                    .keyboardShortcut(.defaultAction)
                    .disabled(identifierText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Divider()
            Button {
                showingAddPopover = false
                model.importViaPanel()
            } label: {
                Label("Import PDF…", systemImage: "doc.badge.plus")
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func submitIdentifier() {
        let text = identifierText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.addByIdentifier(text)
        identifierText = ""
        showingAddPopover = false
    }

    private var documentTable: some View {
        Table(
            of: DocumentDetails.self,
            selection: $model.selectedDocumentId,
            sortOrder: $sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("Title", value: \.sortTitle) { details in
                VStack(alignment: .leading, spacing: 2) {
                    Text(details.document.title.isEmpty ? "Untitled" : details.document.title)
                        .lineLimit(2)
                    if !details.authorsText.isEmpty {
                        Text(details.authorsText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 250, ideal: 380)
            .customizationID("title")
            TableColumn("Year", value: \.sortYear) { details in
                Text(details.document.year.map(String.init) ?? "—")
            }
            .width(48)
            .customizationID("year")
            TableColumn("Venue", value: \.sortVenue) { details in
                Text(details.document.venue ?? "—").lineLimit(1)
            }
            .width(min: 100, ideal: 160)
            .customizationID("venue")
            TableColumn("PDF") { details in
                if details.document.fileHash != nil {
                    Image(systemName: "doc.fill").foregroundStyle(.red.opacity(0.7))
                }
            }
            .width(36)
            .customizationID("pdf")
        } rows: {
            ForEach(model.documents.sorted(using: sortOrder)) { details in
                TableRow(details)
                    .itemProvider { NSItemProvider(object: String(details.id) as NSString) }
            }
        }
        .environment(\.defaultMinListRowHeight, density.rowHeight)
        .contextMenu(forSelectionType: Int64.self) { ids in
            documentContextMenu(ids)
        } primaryAction: { ids in
            if let id = ids.first, !inTrash { openReader(id) }
        }
        .onKeyPress(.space) {
            guard let details = model.selectedDocument,
                let url = model.pdfURL(for: details)
            else { return .ignored }
            previewURL = url
            return .handled
        }
        .overlay {
            if model.documents.isEmpty { emptyState }
        }
    }

    @ViewBuilder
    private func documentContextMenu(_ ids: Set<Int64>) -> some View {
        if let id = ids.first {
            if inTrash {
                Button("Restore") { model.restoreFromTrash(id: id) }
                Divider()
                Button("Delete Permanently", role: .destructive) { model.purgeDocument(id: id) }
            } else {
                Button("Open PDF") { openReader(id) }
                Button("Quick Look") { quickLook(id) }
                Button("Fetch PDF") { model.fetchPDF(id: id) }
                Button("Refresh Metadata") { model.refreshMetadata(id: id) }
                Menu("Add to Collection") {
                    ForEach(model.collections, id: \.id) { collection in
                        Button(collection.name) {
                            model.selectedDocumentId = id
                            model.addSelectedDocument(toCollection: collection.id!)
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    model.selectedDocumentId = id
                    model.deleteSelectedDocument()
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if inTrash {
            ContentUnavailableView("Trash is Empty", systemImage: "trash")
        } else if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.sidebarSelection == .all {
            ContentUnavailableView {
                Label("Your Library is Empty", systemImage: "books.vertical")
            } description: {
                Text("Import PDFs or add a reference by DOI, PubMed ID, or arXiv ID.")
            } actions: {
                Button("Import PDF…") { model.importViaPanel() }
                Button("Add by Identifier…") { showingAddPopover = true }
                Button("Settings…") { openSettings() }
            }
        } else {
            ContentUnavailableView("No Documents", systemImage: "doc")
        }
    }

    private func quickLook(_ id: Int64) {
        guard let details = try? model.repository.document(id: id),
            let url = model.pdfURL(for: details)
        else { return }
        previewURL = url
    }

    private func openReader(_ id: Int64) {
        guard let details = try? model.repository.document(id: id),
            model.pdfURL(for: details) != nil
        else {
            model.statusMessage = "No PDF attached to this reference."
            return
        }
        openWindow(id: "reader", value: id)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.pathExtension.lowercased() == "pdf" {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { model.importPDFs(at: urls) }
        }
        return true
    }
}

/// One level of the collection hierarchy; recurses for subcollections.
private struct CollectionTree: View {
    @EnvironmentObject var model: AppModel
    let parentId: Int64?
    @Binding var collectionToDelete: RefmanCore.Collection?
    @Binding var subcollectionParent: RefmanCore.Collection?

    var body: some View {
        ForEach(model.collections.filter { $0.parentId == parentId }, id: \.id) { collection in
            if model.collections.contains(where: { $0.parentId == collection.id }) {
                DisclosureGroup {
                    CollectionTree(
                        parentId: collection.id,
                        collectionToDelete: $collectionToDelete,
                        subcollectionParent: $subcollectionParent)
                } label: {
                    row(for: collection)
                }
                .tag(SidebarItem.collection(collection.id!))
            } else {
                row(for: collection)
                    .tag(SidebarItem.collection(collection.id!))
            }
        }
    }

    private func row(for collection: RefmanCore.Collection) -> some View {
        Label(collection.name, systemImage: collection.icon ?? "folder")
            .contextMenu {
                Menu("Icon") {
                    ForEach(LibraryView.collectionIcons, id: \.group) { group in
                        Section(group.group) {
                            ForEach(group.icons, id: \.symbol) { icon in
                                Button {
                                    model.setCollectionIcon(id: collection.id!, to: icon.symbol)
                                } label: {
                                    Label(icon.name, systemImage: icon.symbol)
                                }
                            }
                        }
                    }
                }
                Button("New Subcollection") {
                    subcollectionParent = collection
                }
                Button("Delete Collection", role: .destructive) {
                    collectionToDelete = collection
                }
            }
            .dropDestination(for: String.self) { items, _ in
                let ids = items.compactMap(Int64.init)
                guard !ids.isEmpty else { return false }
                model.add(documentIds: ids, toCollection: collection.id!)
                return true
            }
    }
}

/// ⌘K quick navigation across documents, collections, and actions.
private struct CommandPalette: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var allDocs: [DocumentDetails] = []
    @FocusState private var focused: Bool

    private var docs: [DocumentDetails] {
        guard !query.isEmpty else { return Array(allDocs.prefix(8)) }
        let q = query.lowercased()
        return allDocs.filter {
            $0.document.title.lowercased().contains(q)
                || $0.authorsText.lowercased().contains(q)
        }.prefix(12).map { $0 }
    }

    private var collections: [RefmanCore.Collection] {
        guard !query.isEmpty else { return [] }
        return model.collections.filter { $0.name.lowercased().contains(query.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Jump to a document, collection, or action…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
                .onSubmit { if let first = docs.first { open(first) } }
            Divider()
            List {
                if !collections.isEmpty {
                    Section("Collections") {
                        ForEach(collections, id: \.id) { c in
                            Button {
                                model.sidebarSelection = .collection(c.id!)
                                isPresented = false
                            } label: {
                                Label(c.name, systemImage: c.icon ?? "folder")
                            }
                        }
                    }
                }
                Section(query.isEmpty ? "Recent" : "Documents") {
                    ForEach(docs) { d in
                        Button { open(d) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.document.title.isEmpty ? "Untitled" : d.document.title)
                                    .lineLimit(1)
                                if !d.authorsText.isEmpty {
                                    Text(d.authorsText)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                if query.isEmpty {
                    Section("Actions") {
                        Button {
                            isPresented = false
                            model.importViaPanel()
                        } label: { Label("Import PDF…", systemImage: "doc.badge.plus") }
                        Button {
                            isPresented = false
                            model.requestAdd()
                        } label: { Label("Add by Identifier…", systemImage: "plus.circle") }
                    }
                }
            }
            .listStyle(.inset)
            .buttonStyle(.plain)
        }
        .frame(width: 560, height: 420)
        .onAppear {
            allDocs = (try? model.repository.allDocuments()) ?? []
            focused = true
        }
        .onExitCommand { isPresented = false }
    }

    private func open(_ d: DocumentDetails) {
        model.sidebarSelection = .all
        model.selectedDocumentId = d.id
        isPresented = false
    }
}

/// Per-file results of the most recent import.
private struct ImportReportView: View {
    @Environment(\.dismiss) private var dismiss
    let outcomes: [ImportOutcome]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import Report").font(.headline).padding()
            Divider()
            List(outcomes) { outcome in
                HStack {
                    Image(systemName: symbol(outcome.status))
                        .foregroundStyle(color(outcome.status))
                    Text(outcome.name).lineLimit(1)
                    Spacer()
                    Text(label(outcome.status)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 360)
    }

    private func symbol(_ s: ImportOutcome.Status) -> String {
        switch s {
        case .imported: return "checkmark.circle.fill"
        case .duplicate: return "doc.on.doc"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ s: ImportOutcome.Status) -> Color {
        switch s {
        case .imported: return .green
        case .duplicate: return .secondary
        case .failed: return .orange
        }
    }

    private func label(_ s: ImportOutcome.Status) -> String {
        switch s {
        case .imported: return "Imported"
        case .duplicate: return "Duplicate"
        case .failed: return "Failed"
        }
    }
}
