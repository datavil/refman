import AppKit
import Foundation
import RefManCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case all
    case collection(Int64)
    case tag(Int64)
}

enum ExportFormat {
    case bibtex, ris, cslJSON
}

@MainActor
final class AppModel: ObservableObject {
    let repository: LibraryRepository
    let store: LibraryStore
    let pipeline: ImportPipeline

    @Published var documents: [DocumentDetails] = []
    @Published var collections: [RefManCore.Collection] = []
    @Published var tags: [Tag] = []
    @Published var sidebarSelection: SidebarItem = .all
    @Published var selectedDocumentId: Int64?
    @Published var searchText: String = ""
    @Published var statusMessage: String?
    @Published var isImporting = false

    init(repository: LibraryRepository, store: LibraryStore) {
        self.repository = repository
        self.store = store
        self.pipeline = ImportPipeline(repository: repository, store: store)
        reload()
    }

    static func live() -> AppModel {
        do {
            let store = try LibraryStore.default()
            let dbURL = store.rootURL.deletingLastPathComponent()
                .appendingPathComponent("library.sqlite")
            let database = try AppDatabase.open(at: dbURL)
            return AppModel(repository: LibraryRepository(database), store: store)
        } catch {
            fatalError("Could not open library: \(error)")
        }
    }

    var selectedDocument: DocumentDetails? {
        documents.first { $0.document.id == selectedDocumentId }
    }

    // MARK: - Loading

    func reload() {
        do {
            collections = try repository.allCollections()
            tags = try repository.allTags()
            if !searchText.isEmpty {
                documents = try repository.search(searchText)
            } else {
                switch sidebarSelection {
                case .all:
                    documents = try repository.allDocuments()
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
        isImporting = true
        Task {
            var imported = 0
            var duplicates = 0
            var failures = 0
            for url in urls where url.pathExtension.lowercased() == "pdf" {
                do {
                    let result = try await pipeline.importPDF(at: url)
                    if result.wasDuplicate { duplicates += 1 } else { imported += 1 }
                } catch {
                    failures += 1
                }
            }
            isImporting = false
            var parts = ["Imported \(imported)"]
            if duplicates > 0 { parts.append("\(duplicates) duplicate\(duplicates == 1 ? "" : "s") skipped") }
            if failures > 0 { parts.append("\(failures) failed") }
            statusMessage = parts.joined(separator: ", ")
            reload()
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

    func exportViaPanel(format: ExportFormat) {
        do {
            let items = try repository.allDocuments()
            let panel = NSSavePanel()
            let data: Data
            switch format {
            case .bibtex:
                panel.nameFieldStringValue = "library.bib"
                data = Data(BibTeX.export(items).utf8)
            case .ris:
                panel.nameFieldStringValue = "library.ris"
                data = Data(RIS.export(items).utf8)
            case .cslJSON:
                panel.nameFieldStringValue = "library.json"
                data = try CSLJSON.export(items)
            }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url)
            statusMessage = "Exported \(items.count) reference\(items.count == 1 ? "" : "s")"
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Editing

    func update(_ document: Document, authors: [Author]? = nil) {
        do {
            _ = try repository.update(document, authors: authors)
            reload()
        } catch {
            statusMessage = "Update failed: \(error.localizedDescription)"
        }
    }

    func deleteSelectedDocument() {
        guard let id = selectedDocumentId else { return }
        do {
            if let hash = selectedDocument?.document.fileHash {
                try? store.remove(hash: hash)
            }
            try repository.delete(documentId: id)
            selectedDocumentId = nil
            reload()
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
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

    // MARK: - Files

    func pdfURL(for details: DocumentDetails) -> URL? {
        guard let hash = details.document.fileHash, store.exists(hash: hash) else { return nil }
        return store.url(forHash: hash)
    }
}
