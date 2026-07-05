import AppKit
import Foundation
import RefmanCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case all
    case recent
    case recentlyOpened
    case reading
    case uncategorized
    case duplicates
    case trash
    case collection(Int64)
    case tag(Int64)
}

/// Outcome of importing one file, for the import report.
struct ImportOutcome: Identifiable {
    enum Status { case imported, duplicate, failed }
    let id = UUID()
    let name: String
    let status: Status
}

/// A single in-flight AI insight generation, keyed so the inspector can show a
/// spinner on the right section until it finishes.
struct InsightJob: Hashable {
    let documentId: Int64
    let insight: DocumentInsight
}

struct LibraryStats {
    var documents: Int
    var withPDF: Int
    var trashed: Int
    var sizeBytes: Int64
}

struct IntegrityReport {
    /// Live documents whose referenced PDF is missing from storage.
    var missing: [(id: Int64, title: String)]
    /// Stored PDFs no document references.
    var orphanHashes: [String]

    var isClean: Bool { missing.isEmpty && orphanHashes.isEmpty }
}

enum ExportFormat {
    case bibtex, ris, cslJSON, endNoteXML
}

@MainActor
final class AppModel: ObservableObject {
    let repository: LibraryRepository
    let store: LibraryStore
    let updater = Updater()

    /// Rebuilt per access so it always uses the current contact email from Settings.
    var pipeline: ImportPipeline {
        let email = UserDefaults.standard.string(forKey: SettingsKeys.contactEmail) ?? ""
        return ImportPipeline(
            repository: repository,
            store: store,
            crossRef: CrossRefClient(mailto: email.isEmpty ? nil : email),
            pdfFetcher: PDFFetcher(mailto: email))
    }

    @Published var documents: [DocumentDetails] = []
    /// Groups of live references sharing a DOI/arXiv ID, for the Duplicates view.
    @Published var duplicateGroups: [[DocumentDetails]] = []
    /// AI insight generations currently running, so the UI can show a spinner.
    @Published var generatingInsights: Set<InsightJob> = []
    /// Collection ids whose summary is currently being generated.
    @Published var generatingCollectionSummaries: Set<Int64> = []
    @Published var collections: [RefmanCore.Collection] = []
    @Published var tags: [Tag] = []
    @Published var sidebarSelection: SidebarItem = .all
    @Published var selectedDocumentIds: Set<Int64> = []

    /// Single-selection convenience derived from `selectedDocumentIds`.
    /// `nil` when zero or multiple rows are selected.
    var selectedDocumentId: Int64? {
        get { selectedDocumentIds.count == 1 ? selectedDocumentIds.first : nil }
        set { selectedDocumentIds = newValue.map { [$0] } ?? [] }
    }
    @Published var searchText: String = ""
    @Published var statusMessage: String?
    @Published var isImporting = false
    @Published var importProgress: (done: Int, total: Int)?
    @Published var importLog: [ImportOutcome] = []

    /// Incremented to ask the UI to surface the add-reference popover / command palette.
    @Published var addRequested = 0
    @Published var paletteRequested = 0
    @Published var aiSettingsRequested = 0
    @Published var settingsRequested = 0

    init(repository: LibraryRepository, store: LibraryStore) {
        self.repository = repository
        self.store = store
        reload()
    }

    static func live() -> AppModel {
        do {
            let root = resolvedLibraryRoot()
            LibraryLocation.normalizeCasing(of: root)
            let store = try LibraryStore(rootURL: LibraryLocation.storeURL(root: root))
            let database = try AppDatabase.open(at: LibraryLocation.databaseURL(root: root))
            // Keep the library folder hidden in Finder (the flag may not sync, so
            // reassert it on every launch).
            try? LibraryLocation.setHidden(true, at: root)
            return AppModel(repository: LibraryRepository(database), store: store)
        } catch {
            fatalError("Could not open library: \(error)")
        }
    }

    /// The library root to open: a user-chosen location (e.g. iCloud Drive) or
    /// the default Application Support folder.
    static func resolvedLibraryRoot() -> URL {
        if let path = UserDefaults.standard.string(forKey: SettingsKeys.libraryRootPath),
            !path.isEmpty
        {
            return URL(fileURLWithPath: path)
        }
        // No location configured yet (e.g. a fresh install of the distributed
        // app). If a library already exists in iCloud Drive, adopt it so a
        // synced library shows up without manual setup.
        if let iCloud = LibraryLocation.iCloudDriveRoot(),
            FileManager.default.fileExists(atPath: LibraryLocation.databaseURL(root: iCloud).path)
        {
            return iCloud
        }
        return (try? LibraryLocation.defaultRoot())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Refman")
    }

    var selectedDocument: DocumentDetails? {
        documents.first { $0.document.id == selectedDocumentId }
    }

    private var selectedSearchScope: LibrarySearchScope {
        switch sidebarSelection {
        case .all: .all
        case .recent:
            .recent(
                since: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
        case .recentlyOpened:
            .recentlyOpened(
                since: Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date())
        case .reading: .reading
        case .uncategorized: .uncategorized
        case .duplicates: .duplicates
        case .trash: .trash
        case .collection(let id): .collection(id)
        case .tag(let id): .tag(id)
        }
    }

    // MARK: - Loading

    func reload() {
        do {
            collections = try repository.allCollections()
            tags = try repository.allTags()
            if !searchText.isEmpty {
                documents = try repository.search(searchText, scope: selectedSearchScope)
                if sidebarSelection == .duplicates {
                    let matchingIds = Set(documents.map(\.id))
                    duplicateGroups = try repository.duplicateGroups().filter { group in
                        group.contains { matchingIds.contains($0.id) }
                    }
                    documents = duplicateGroups.flatMap { $0 }
                }
            } else {
                switch sidebarSelection {
                case .all:
                    documents = try repository.allDocuments()
                case .recent:
                    let weekAgo = Calendar.current.date(
                        byAdding: .day, value: -7, to: Date()) ?? Date()
                    documents = try repository.recentDocuments(since: weekAgo)
                case .recentlyOpened:
                    let twoDaysAgo = Calendar.current.date(
                        byAdding: .day, value: -2, to: Date()) ?? Date()
                    documents = try repository.recentlyOpenedDocuments(since: twoDaysAgo)
                case .reading:
                    documents = try repository.readingDocuments()
                case .uncategorized:
                    documents = try repository.uncategorizedDocuments()
                case .duplicates:
                    duplicateGroups = try repository.duplicateGroups()
                    documents = duplicateGroups.flatMap { $0 }
                case .trash:
                    documents = try repository.trashedDocuments()
                case .collection(let id):
                    documents = try repository.allDocuments(in: id)
                case .tag(let id):
                    documents = try repository.documents(taggedWith: id)
                }
            }
        } catch {
            statusMessage = "Load failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Import

    func importViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importPDFs(at: panel.urls)
    }

    func importPDFs(at urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { return }
        isImporting = true
        importLog = []
        importProgress = (0, pdfs.count)
        Task {
            var log: [ImportOutcome] = []
            for (i, url) in pdfs.enumerated() {
                importProgress = (i, pdfs.count)
                let name = url.lastPathComponent
                do {
                    switch try await pipeline.importPDF(at: url) {
                    case .imported:
                        log.append(.init(name: name, status: .imported))
                    case .duplicate:
                        // Keep every dropped PDF: a byte-identical file becomes a
                        // separate record rather than being skipped. Same-paper
                        // dupes surface in the Duplicates view for cleanup.
                        _ = try await pipeline.importPDFAsNew(at: url)
                        log.append(.init(name: name, status: .imported))
                    case .inTrash(let existing, let sourceURL):
                        switch promptTrashConflict(name: name, existing: existing) {
                        case .restore:
                            try repository.restore(documentId: existing.id)
                            log.append(.init(name: name, status: .imported))
                        case .replace:
                            // Drop the trashed record (frees its unique DOI), then
                            // import the file fresh.
                            try repository.purge(documentId: existing.id)
                            _ = try await pipeline.importPDFAsNew(at: sourceURL)
                            log.append(.init(name: name, status: .imported))
                        case .skip:
                            log.append(.init(name: name, status: .duplicate))
                        }
                    }
                } catch {
                    log.append(.init(name: name, status: .failed))
                }
            }
            isImporting = false
            importProgress = nil
            importLog = log
            let imported = log.filter { $0.status == .imported }.count
            let duplicates = log.filter { $0.status == .duplicate }.count
            let failures = log.filter { $0.status == .failed }.count
            var parts = ["Imported \(imported)"]
            if duplicates > 0 { parts.append("\(duplicates) duplicate\(duplicates == 1 ? "" : "s") skipped") }
            if failures > 0 { parts.append("\(failures) failed") }
            statusMessage = parts.joined(separator: ", ")
            reload()
        }
    }

    private enum TrashConflictChoice { case restore, replace, skip }

    /// Asks what to do when an imported PDF matches a document in the Trash.
    private func promptTrashConflict(name: String, existing: DocumentDetails) -> TrashConflictChoice {
        let alert = NSAlert()
        alert.messageText = "“\(existing.document.title)” is in the Trash"
        alert.informativeText =
            "\(name) matches a reference currently in your Trash. Restore the existing "
            + "one, or replace it with a fresh import? Replacing permanently discards the "
            + "trashed copy and its notes."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .restore
        case .alertSecondButtonReturn: return .replace
        default: return .skip
        }
    }

    /// Adds a reference from a pasted DOI, PubMed ID, arXiv ID, or link.
    func addByIdentifier(_ raw: String) {
        Task {
            do {
                switch try await pipeline.importIdentifier(raw) {
                case .added(let details):
                    let hasPDF = details.document.fileHash != nil
                    statusMessage =
                        "Added “\(details.document.title)”"
                        + (hasPDF ? " with PDF" : " (no open-access PDF found)")
                    reload()
                    selectedDocumentId = details.id
                case .duplicate(let details):
                    statusMessage = "Already in library"
                    selectedDocumentId = details.id
                case .notFound:
                    statusMessage = "No metadata found for that identifier"
                case .unrecognized:
                    statusMessage = "Not a recognized DOI, PubMed ID, arXiv ID, or link"
                }
            } catch {
                statusMessage = "Add failed: \(error.localizedDescription)"
            }
        }
    }

    /// Attaches a local PDF file the user picks to an existing reference.
    func attachPDF(id: Int64) {
        guard let details = documents.first(where: { $0.document.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try pipeline.attachPDF(at: url, to: details.document)
            statusMessage = "PDF attached"
            reload()
        } catch {
            statusMessage = "Attach failed: \(error.localizedDescription)"
        }
    }

    /// Downloads and attaches an open-access PDF to an existing reference.
    func fetchPDF(id: Int64) {
        guard let details = documents.first(where: { $0.document.id == id }) else { return }
        guard details.document.doi != nil || details.document.arxivId != nil else {
            statusMessage = "Needs a DOI or arXiv ID to find a PDF"
            return
        }
        statusMessage = "Fetching PDF…"
        Task {
            do {
                if try await pipeline.fetchPDF(for: details.document) != nil {
                    statusMessage = "PDF attached"
                } else {
                    statusMessage = "No open-access PDF found"
                }
                reload()
            } catch {
                statusMessage = "Fetch failed: \(error.localizedDescription)"
            }
        }
    }

    func refreshMetadata(id: Int64) {
        guard let details = documents.first(where: { $0.document.id == id }) else { return }
        Task {
            do {
                if try await pipeline.refreshMetadata(for: details.document) != nil {
                    statusMessage = "Metadata refreshed"
                } else {
                    statusMessage = "No metadata found — needs a DOI or arXiv ID"
                }
                reload()
            } catch {
                statusMessage = "Refresh failed: \(error.localizedDescription)"
            }
        }
    }

    func refreshMetadata(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        Task {
            var refreshed = 0
            for id in ids {
                guard let details = documents.first(where: { $0.document.id == id }) else { continue }
                do {
                    if try await pipeline.refreshMetadata(for: details.document) != nil { refreshed += 1 }
                } catch {
                    statusMessage = "Refresh failed: \(error.localizedDescription)"
                }
            }
            reload()
            statusMessage = "Refreshed metadata for \(refreshed) of \(ids.count)"
        }
    }

    func importBibliographyViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "bib"), UTType(filenameExtension: "ris"),
        ].compactMap { $0 }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        var count = 0
        for url in panel.urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let items: [(Document, [Author])]
            if url.pathExtension.lowercased() == "ris" {
                items = RIS.parse(text).map(RIS.document(from:))
            } else {
                items = BibTeX.parse(text).map(BibTeX.document(from:))
            }
            for (doc, authors) in items {
                // Skip DOI duplicates quietly.
                if let doi = doc.doi, (try? repository.document(doi: doi)) != nil { continue }
                if (try? repository.insert(doc, authors: authors)) != nil { count += 1 }
            }
        }
        statusMessage = "Imported \(count) reference\(count == 1 ? "" : "s")"
        reload()
    }

    // MARK: - Export

    func exportViaPanel(format: ExportFormat, collectionId: Int64? = nil, name: String? = nil) {
        exportViaPanel(
            format: format, items: (try? repository.allDocuments(in: collectionId)) ?? [], name: name)
    }

    func exportViaPanel(format: ExportFormat, documentIds ids: [Int64]) {
        exportViaPanel(
            format: format, items: ids.compactMap { try? repository.document(id: $0) }, name: nil)
    }

    private func exportViaPanel(format: ExportFormat, items: [DocumentDetails], name: String?) {
        guard !items.isEmpty else {
            statusMessage = "Nothing to export."
            return
        }
        do {
            let base = exportBaseName(name)
            let panel = NSSavePanel()
            let data: Data
            switch format {
            case .bibtex:
                panel.nameFieldStringValue = "\(base).bib"
                data = Data(BibTeX.export(items).utf8)
            case .ris:
                panel.nameFieldStringValue = "\(base).ris"
                data = Data(RIS.export(items).utf8)
            case .cslJSON:
                panel.nameFieldStringValue = "\(base).json"
                data = try CSLJSON.export(items)
            case .endNoteXML:
                panel.nameFieldStringValue = "\(base).xml"
                data = Data(EndNoteXML.export(items).utf8)
            }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url)
            statusMessage = "Exported \(items.count) reference\(items.count == 1 ? "" : "s")"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Exports the whole library (nil) or one collection as a portable folder.
    func exportBundleViaPanel(
        collectionId: Int64?, name: String? = nil,
        includeBibTeX: Bool = true, includeRIS: Bool = false, includeXML: Bool = false
    ) {
        exportBundleViaPanel(
            items: (try? repository.allDocuments(in: collectionId)) ?? [], name: name,
            includeBibTeX: includeBibTeX, includeRIS: includeRIS, includeXML: includeXML)
    }

    /// Exports an explicit set of documents (a selection or single paper).
    func exportBundleViaPanel(
        documentIds ids: [Int64],
        includeBibTeX: Bool = true, includeRIS: Bool = false, includeXML: Bool = false
    ) {
        exportBundleViaPanel(
            items: ids.compactMap { try? repository.document(id: $0) }, name: nil,
            includeBibTeX: includeBibTeX, includeRIS: includeRIS, includeXML: includeXML)
    }

    /// Writes `items` as a portable folder: the attached PDFs plus whichever
    /// bibliography sidecars (`library.bib`/`.ris`/`.xml`) are requested, linked
    /// by relative path so Zotero/Mendeley import them.
    private func exportBundleViaPanel(
        items: [DocumentDetails], name: String?,
        includeBibTeX: Bool, includeRIS: Bool, includeXML: Bool
    ) {
        guard !items.isEmpty else {
            statusMessage = "Nothing to export."
            return
        }
        do {
            let panel = NSSavePanel()
            panel.title = "Export with PDFs"
            panel.message = "Choose where to save the export folder"
            panel.nameFieldLabel = "Folder name:"
            panel.nameFieldStringValue = exportBaseName(name)
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let bundle = panel.url else { return }

            let result = try LibraryBundle.export(
                items, store: store, to: bundle,
                includeBibTeX: includeBibTeX, includeRIS: includeRIS, includeXML: includeXML)
            var message =
                "Exported \(result.references) reference\(result.references == 1 ? "" : "s") "
                + "with \(result.pdfs) PDF\(result.pdfs == 1 ? "" : "s")"
            if result.notDownloaded > 0 {
                message += " — \(result.notDownloaded) not yet downloaded from iCloud; "
                    + "try again shortly"
            }
            if let firstError = result.copyErrors.first {
                message += " — couldn't copy \(result.copyErrors.count): \(firstError)"
            }
            statusMessage = message
            NSWorkspace.shared.activateFileViewerSelecting([bundle])
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Imports a folder: an exported bundle (a `.bib` whose `file` fields point
    /// to PDFs in `files/`) attaches its PDFs; a folder of loose PDFs goes
    /// through the normal import pipeline. Imported docs join `collectionId`.
    func importFromFolderViaPanel(collectionId: Int64? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
            ?? []

        if let bib = contents.first(where: { $0.pathExtension.lowercased() == "bib" }),
            let text = try? String(contentsOf: bib, encoding: .utf8)
        {
            var count = 0
            var withPDF = 0
            for entry in BibTeX.parse(text) {
                let (parsed, authors) = BibTeX.document(from: entry)
                var doc = parsed
                if let rel = entry.fields["file"].flatMap(Self.attachmentPath) {
                    let pdf = folder.appendingPathComponent(rel)
                    if let hash = try? store.ingest(fileAt: pdf) {
                        doc.fileHash = hash
                        doc.fileName = pdf.lastPathComponent
                        withPDF += 1
                    }
                }
                if let doi = doc.doi, (try? repository.document(doi: doi)) != nil { continue }
                if let saved = try? repository.insert(doc, authors: authors) {
                    count += 1
                    if let cid = collectionId, let id = saved.document.id {
                        try? repository.add(documentId: id, toCollection: cid)
                    }
                }
            }
            statusMessage =
                "Imported \(count) reference\(count == 1 ? "" : "s") "
                + "with \(withPDF) PDF\(withPDF == 1 ? "" : "s")"
            reload()
        } else {
            let nested =
                (try? fm.contentsOfDirectory(
                    at: folder.appendingPathComponent("files"), includingPropertiesForKeys: nil))
                ?? []
            let pdfs = (contents + nested).filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else {
                statusMessage = "No .bib file or PDFs found in that folder."
                return
            }
            importPDFs(at: pdfs)
        }
    }

    /// Extracts the path from a BibTeX `file` field, accepting both a bare path
    /// and the JabRef `description:path:type` triple.
    private static func attachmentPath(from field: String) -> String? {
        let parts = field.components(separatedBy: ":")
        let path = parts.count >= 3 ? parts[1] : field
        return path.isEmpty ? nil : path
    }

    /// Export base name: a sanitized provided name (e.g. a collection's), or
    /// `refman-<unix time>` when none is given.
    private func exportBaseName(_ name: String?) -> String {
        guard let name else { return "refman-\(Int(Date().timeIntervalSince1970))" }
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "refman-\(Int(Date().timeIntervalSince1970))" : cleaned
    }

    /// Formats the given documents with citeproc and puts the result on the
    /// pasteboard. Document order follows `ids` for in-text citations.
    func copyCitation(documentIds ids: [Int64], style: Citeproc.Style, mode: Citeproc.Mode) {
        let items = ids.compactMap { try? repository.document(id: $0) }
        guard !items.isEmpty else { return }
        do {
            let text = try Citeproc.format(items, style: style, mode: mode)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let what = mode == .bibliography ? "reference" : "in-text citation"
            statusMessage = "Copied \(style.label) \(what) (\(items.count) item\(items.count == 1 ? "" : "s"))"
        } catch {
            statusMessage = "Couldn't format citation: \(error.localizedDescription)"
        }
    }

    // MARK: - Editing

    /// Generates an AI insight (summary, key points, …) for a document and
    /// stores it on the paper.
    func generateInsight(_ insight: DocumentInsight, for id: Int64) {
        guard let details = documents.first(where: { $0.id == id }),
            let action = AssistantPrompts.document.first(where: { $0.saves == insight })
        else { return }
        let title = details.document.title
        let job = InsightJob(documentId: id, insight: insight)
        generatingInsights.insert(job)
        statusMessage = "Generating \(action.label.lowercased()) for “\(title)”…"
        Task {
            defer { generatingInsights.remove(job) }
            do {
                let text = try await AssistantModel.generateText(
                    prompt: action.prompt, documentId: id, repository: repository)
                guard !text.isEmpty else {
                    statusMessage = "\(action.label) came back empty"
                    return
                }
                try repository.setInsight(insight, documentId: id, text: text)
                reload()
                statusMessage = "\(action.label) created for “\(title)”"
            } catch {
                statusMessage = "\(action.label) failed: \(error.localizedDescription)"
            }
        }
    }

    /// True while the given insight is being generated for a document.
    func isGeneratingInsight(_ insight: DocumentInsight, for id: Int64) -> Bool {
        generatingInsights.contains(InsightJob(documentId: id, insight: insight))
    }

    /// Total character budget for the full text fed into a collection summary,
    /// split across its papers so a large collection can't overflow the model.
    private static let collectionTextBudget = 60_000

    /// Generates a synthesizing summary of a collection from the full text of its
    /// papers and stores it on the collection. Always regenerates.
    func summarizeCollection(id: Int64) {
        guard !generatingCollectionSummaries.contains(id) else { return }
        let docs = (try? repository.allDocuments(in: id)) ?? []
        guard !docs.isEmpty else {
            statusMessage = "This collection has no documents to summarize."
            return
        }
        let name = collections.first { $0.id == id }?.name ?? ""
        let repository = self.repository
        generatingCollectionSummaries.insert(id)
        statusMessage = "Summarizing “\(name)”…"
        Task {
            defer { generatingCollectionSummaries.remove(id) }
            do {
                let digest = Self.collectionDigest(docs, repository: repository)
                let prompt = AssistantPrompts.collectionSummary + "\n\n" + digest
                let text = try await AssistantModel.generateText(
                    prompt: prompt, documentId: docs[0].id, repository: repository)
                guard !text.isEmpty else {
                    statusMessage = "Summary came back empty"
                    return
                }
                try repository.setCollectionSummary(id: id, text: text)
                reload()
                statusMessage = "Summary created for “\(name)”"
            } catch {
                statusMessage = "Collection summary failed: \(error.localizedDescription)"
            }
        }
    }

    /// True while the given collection's summary is being generated.
    func isGeneratingCollectionSummary(_ id: Int64) -> Bool {
        generatingCollectionSummaries.contains(id)
    }

    /// Assembles the papers into a titled digest, truncating each to its share of
    /// the budget (falling back to the abstract when full text is unavailable).
    private static func collectionDigest(
        _ docs: [DocumentDetails], repository: LibraryRepository
    ) -> String {
        let perDoc = max(1, collectionTextBudget / docs.count)
        return docs.map { details in
            let title = details.document.title.isEmpty ? "Untitled" : details.document.title
            let full = (try? repository.fullText(documentId: details.id)) ?? nil
            let body = (full ?? details.document.abstract ?? "").prefix(perDoc)
            return "## \(title)\n\(body)"
        }
        .joined(separator: "\n\n")
    }

    func update(_ document: Document, authors: [Author]? = nil) {
        do {
            _ = try repository.update(document, authors: authors)
            reload()
        } catch {
            statusMessage = "Update failed: \(error.localizedDescription)"
        }
    }

    /// Moves the selected document to the Trash (recoverable).
    func deleteSelectedDocument() {
        guard let id = selectedDocumentId else { return }
        do {
            try repository.delete(documentId: id)
            selectedDocumentId = nil
            reload()
            statusMessage = "Moved to Trash"
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Moves the given documents to the Trash (recoverable).
    func delete(documentIds ids: [Int64]) {
        guard !ids.isEmpty else { return }
        do {
            for id in ids { try repository.delete(documentId: id) }
            selectedDocumentIds = []
            reload()
            statusMessage = ids.count == 1 ? "Moved to Trash" : "Moved \(ids.count) to Trash"
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Records that a document's reader was opened (drives "Recently Opened").
    func markOpened(id: Int64) {
        try? repository.markOpened(documentId: id)
        reload()
    }

    /// Marks one document as "Currently Reading", replacing any previous one.
    func setReading(id: Int64) {
        do {
            try repository.setReading(documentId: id)
            reload()
        } catch {
            statusMessage = "Could not mark as reading: \(error.localizedDescription)"
        }
    }

    /// Clears the "Currently Reading" mark.
    func clearReading() {
        try? repository.clearReading()
        reload()
    }

    func restoreFromTrash(id: Int64) {
        do {
            try repository.restore(documentId: id)
            reload()
            statusMessage = "Restored from Trash"
        } catch {
            statusMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    /// Permanently deletes one trashed document and its PDF (if unreferenced).
    func purgeDocument(id: Int64) {
        do {
            let hash = (try? repository.document(id: id))?.document.fileHash
            try repository.purge(documentId: id)
            if let hash, try repository.document(fileHash: hash) == nil {
                try? store.remove(hash: hash)
            }
            if selectedDocumentId == id { selectedDocumentId = nil }
            reload()
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func emptyTrash() {
        do {
            let freed = try repository.emptyTrash()
            for hash in freed { try? store.remove(hash: hash) }
            selectedDocumentId = nil
            reload()
            statusMessage = "Trash emptied"
        } catch {
            statusMessage = "Could not empty Trash: \(error.localizedDescription)"
        }
    }

    func createCollection(named name: String, parentId: Int64? = nil) {
        do {
            _ = try repository.createCollection(name: name, parentId: parentId)
            reload()
        } catch {
            statusMessage = "Could not create collection: \(error.localizedDescription)"
        }
    }

    func deleteCollection(id: Int64) {
        do {
            try repository.deleteCollection(id: id)
            if sidebarSelection == .collection(id) { sidebarSelection = .all }
            reload()
        } catch {
            statusMessage = "Could not delete collection: \(error.localizedDescription)"
        }
    }

    func renameCollection(id: Int64, to name: String) {
        do {
            try repository.renameCollection(id: id, to: name)
            reload()
        } catch {
            statusMessage = "Could not rename collection: \(error.localizedDescription)"
        }
    }

    /// Reorders the siblings under `parentId` after a drag in the sidebar.
    func moveCollections(parentId: Int64?, from source: IndexSet, to destination: Int) {
        var siblings = collections.filter { $0.parentId == parentId }
        siblings.move(fromOffsets: source, toOffset: destination)
        do {
            try repository.reorderCollections(siblings.compactMap(\.id))
            reload()
        } catch {
            statusMessage = "Could not reorder collections: \(error.localizedDescription)"
        }
    }

    func addSelectedDocument(toCollection collectionId: Int64) {
        guard let id = selectedDocumentId else { return }
        try? repository.add(documentId: id, toCollection: collectionId)
        reload()
    }

    func add(documentIds: [Int64], toCollection collectionId: Int64) {
        for id in documentIds {
            try? repository.add(documentId: id, toCollection: collectionId)
        }
        reload()
    }

    func setCollectionIcon(id: Int64, to icon: String?) {
        do {
            try repository.setCollectionIcon(id: id, to: icon)
            reload()
        } catch {
            statusMessage = "Could not change icon: \(error.localizedDescription)"
        }
    }

    func addTag(_ name: String) {
        guard let id = selectedDocumentId, !name.isEmpty else { return }
        _ = try? repository.addTag(name, toDocument: id)
        reload()
    }

    func removeTag(_ tagId: Int64) {
        guard let id = selectedDocumentId else { return }
        try? repository.removeTag(tagId, fromDocument: id)
        reload()
    }

    // MARK: - Commands

    func requestAdd() { addRequested += 1 }
    func requestPalette() { paletteRequested += 1 }
    func requestAISettings() { aiSettingsRequested += 1 }
    func requestSettings() { settingsRequested += 1 }

    // MARK: - Library maintenance

    /// The Refman support directory holding `library.sqlite` and `Storage/`.
    var libraryRootURL: URL { store.rootURL.deletingLastPathComponent() }

    func libraryStats() -> LibraryStats? {
        guard let counts = try? repository.counts() else { return nil }
        let size = (try? store.totalSize()) ?? 0
        return LibraryStats(
            documents: counts.live, withPDF: counts.withPDF,
            trashed: counts.trashed, sizeBytes: size)
    }

    /// Compares stored PDFs against documents and reports mismatches.
    func runIntegrityCheck() -> IntegrityReport? {
        do {
            let referenced = try repository.referencedFileHashes()
            let stored = try store.allStoredHashes()
            let missing: [(Int64, String)] = try (repository.allDocuments()).compactMap { d in
                guard let hash = d.document.fileHash, !stored.contains(hash) else { return nil }
                return (d.id, d.document.title.isEmpty ? "Untitled" : d.document.title)
            }
            let orphans = stored.subtracting(referenced).sorted()
            return IntegrityReport(missing: missing, orphanHashes: orphans)
        } catch {
            statusMessage = "Integrity check failed: \(error.localizedDescription)"
            return nil
        }
    }

    func removeOrphanFiles(_ hashes: [String]) {
        for hash in hashes { try? store.remove(hash: hash) }
        statusMessage = "Removed \(hashes.count) orphaned file\(hashes.count == 1 ? "" : "s")"
    }

    /// Prompts for a destination and writes a library backup there.
    func backupViaPanel() {
        let panel = NSSavePanel()
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "Refman-backup-\(date).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backup(to: url)
    }

    /// Zips `library.sqlite` + `Storage/` into the chosen archive.
    func backup(to destination: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try runDitto(["-c", "-k", "--keepParent", libraryRootURL.path, destination.path])
            statusMessage = "Backed up to \(destination.lastPathComponent)"
        } catch {
            statusMessage = "Backup failed: \(error.localizedDescription)"
        }
    }

    /// Restores a backup archive, overwriting the current library.
    /// The open database isn't reloaded, so the user must relaunch.
    func restore(from archive: URL) {
        do {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("refman-restore-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            try runDitto(["-x", "-k", archive.path, temp.path])

            guard let dbSource = findFile(named: "library.sqlite", under: temp) else {
                statusMessage = "Restore failed: no library found in archive"
                return
            }
            let sourceRoot = dbSource.deletingLastPathComponent()
            let fm = FileManager.default
            for item in ["library.sqlite", "Storage"] {
                let src = sourceRoot.appendingPathComponent(item)
                let dst = libraryRootURL.appendingPathComponent(item)
                guard fm.fileExists(atPath: src.path) else { continue }
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
            statusMessage = "Library restored — quit and reopen Refman to load it."
        } catch {
            statusMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func runDitto(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "Refman", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "ditto exited with \(process.terminationStatus)"])
        }
    }

    private func findFile(named name: String, under directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    // MARK: - iCloud / library location

    /// Whether iCloud Drive is enabled on this Mac.
    var iCloudDriveAvailable: Bool { LibraryLocation.iCloudDriveRoot() != nil }

    /// Whether the active library currently lives in an iCloud container.
    var isInICloudDrive: Bool { LibraryLocation.isICloud(libraryRootURL) }

    /// Home-relative display path of the active library.
    var libraryLocationDisplay: String {
        libraryRootURL.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    func moveLibraryToICloudDrive() async {
        guard let target = LibraryLocation.iCloudDriveRoot() else {
            statusMessage = "iCloud Drive isn't enabled on this Mac."
            return
        }
        await moveLibrary(to: target)
    }

    func moveLibraryToLocal() async {
        guard let target = try? LibraryLocation.defaultRoot() else { return }
        await moveLibrary(to: target)
    }

    /// Points the library at `newRoot`, then relaunches so the move takes effect
    /// (the open database connection isn't reopened in place). If a library
    /// already exists at the destination (e.g. synced from another Mac) it's
    /// adopted in place rather than overwritten.
    private func moveLibrary(to newRoot: URL) async {
        let current = libraryRootURL
        guard current.standardizedFileURL != newRoot.standardizedFileURL else { return }
        // Adopt an existing library in place only when joining an iCloud library
        // already synced from another Mac. A move to local always relocates so a
        // stale leftover (e.g. from an earlier failed move) can't shadow the real
        // library.
        let destHasLibrary = FileManager.default.fileExists(
            atPath: LibraryLocation.databaseURL(root: newRoot).path)
        let adopt = destHasLibrary && LibraryLocation.isICloud(newRoot)
        do {
            if !adopt {
                // Download evicted iCloud files before moving them out of the
                // container; dataless placeholders would otherwise move as empty.
                if LibraryLocation.isICloud(current) {
                    statusMessage = "Downloading library from iCloud…"
                    try await LibraryLocation.materialize(at: current)
                }
                try LibraryLocation.relocate(from: current, to: newRoot)
            }
            try? LibraryLocation.setHidden(true, at: newRoot)
            UserDefaults.standard.set(newRoot.path, forKey: SettingsKeys.libraryRootPath)
            relaunch()
        } catch {
            statusMessage = "Move failed: \(error.localizedDescription)"
        }
    }

    /// Quits and reopens the app so it reloads from the current library location.
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
            #!/bin/bash
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            /usr/bin/open "\(bundleURL.path)"
            """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("refman-relaunch-\(UUID().uuidString).sh")
        guard (try? script.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil else {
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Files

    func pdfURL(for details: DocumentDetails) -> URL? {
        guard let hash = details.document.fileHash else { return nil }
        if store.exists(hash: hash) { return store.url(forHash: hash) }
        // Possibly evicted by iCloud — request a download for next time.
        return store.ensureDownloaded(hash: hash) ? store.url(forHash: hash) : nil
    }
}
