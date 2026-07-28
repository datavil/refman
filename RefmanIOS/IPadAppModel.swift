import Foundation
import Observation
import RefmanCore

@MainActor
@Observable
final class IPadAppModel {
    private(set) var repository: LibraryRepository
    private(set) var store: LibraryStore
    private(set) var libraryRootURL: URL
    private var securityScopedRootURL: URL?
    private var isAccessingSecurityScopedRoot = false

    var documents: [DocumentDetails] = []
    var collections: [RefmanCore.Collection] = []
    var tags: [Tag] = []
    var section: LibrarySection = .all
    var selectedDocumentID: Int64?
    var searchText = ""
    var statusMessage: String?
    var isImporting = false
    var importProgress = 0
    var isSwitchingLibrary = false
    var isUsingICloudDrive = false

    private var pipeline: ImportPipeline {
        ImportPipeline(repository: repository, store: store)
    }

    init(
        repository: LibraryRepository,
        store: LibraryStore,
        libraryRootURL: URL? = nil,
        securityScopedRootURL: URL? = nil,
        isAccessingSecurityScopedRoot: Bool = false
    ) {
        self.repository = repository
        self.store = store
        self.libraryRootURL = libraryRootURL ?? store.rootURL.deletingLastPathComponent()
        self.securityScopedRootURL = securityScopedRootURL
        self.isAccessingSecurityScopedRoot = isAccessingSecurityScopedRoot
        isUsingICloudDrive = securityScopedRootURL != nil
        reload()
    }

    static func live() -> IPadAppModel {
        let hadSavedBookmark = ICloudLibraryBookmark.hasSavedBookmark
        if let root = try? ICloudLibraryBookmark.resolve() {
            let isAccessing = root.startAccessingSecurityScopedResource()
            do {
                guard FileManager.default.fileExists(
                    atPath: LibraryLocation.databaseURL(root: root).path)
                else {
                    throw ICloudLibraryError.missingDatabase
                }
                return try makeModel(
                    root: root,
                    securityScopedRootURL: root,
                    isAccessingSecurityScopedRoot: isAccessing)
            } catch {
                if isAccessing {
                    root.stopAccessingSecurityScopedResource()
                }
            }
        }

        do {
            let model = try makeModel(root: LibraryLocation.defaultRoot())
            if hadSavedBookmark {
                model.statusMessage =
                    "Could not reopen the iCloud library. Choose its Refman folder again."
            }
            return model
        } catch {
            fatalError("Could not open the iPad library: \(error.localizedDescription)")
        }
    }

    var selectedDocument: DocumentDetails? {
        guard let selectedDocumentID else { return nil }
        return try? repository.document(id: selectedDocumentID)
    }

    func reload() {
        do {
            collections = try repository.allCollections()
            tags = try repository.allTags()
            if searchText.isEmpty {
                documents = try documents(for: section)
            } else {
                documents = try repository.search(searchText, scope: section.searchScope)
            }

            if let selectedDocumentID,
                !documents.contains(where: { $0.id == selectedDocumentID })
            {
                self.selectedDocumentID = nil
            }
            if selectedDocumentID == nil {
                selectedDocumentID = documents.first?.id
            }
        } catch {
            statusMessage = "Could not load the library: \(error.localizedDescription)"
        }
    }

    func selectDocument(_ id: Int64?) {
        selectedDocumentID = id
        guard let id else { return }
        try? repository.markOpened(documentId: id)
    }

    func importPDFs(at urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        importProgress = 0

        Task {
            var imported = 0
            var duplicates = 0
            var failures = 0

            for (index, url) in urls.enumerated() {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    switch try await pipeline.importPDF(at: url) {
                    case .imported:
                        imported += 1
                    case .duplicate:
                        duplicates += 1
                    case .inTrash(let existing, _):
                        try repository.restore(documentId: existing.id)
                        imported += 1
                    }
                } catch {
                    failures += 1
                }
                importProgress = index + 1
            }

            isImporting = false
            statusMessage = Self.importSummary(
                imported: imported, duplicates: duplicates, failures: failures)
            reload()
        }
    }

    func connectICloudLibrary(at root: URL) async {
        guard !isImporting, !isSwitchingLibrary else { return }
        isSwitchingLibrary = true
        statusMessage = "Downloading the iCloud library…"
        let isAccessing = root.startAccessingSecurityScopedResource()

        do {
            try await LibraryLocation.materialize(at: root)
            guard FileManager.default.fileExists(
                atPath: LibraryLocation.databaseURL(root: root).path)
            else {
                throw ICloudLibraryError.missingDatabase
            }

            let next = try Self.makeModelComponents(root: root)
            try ICloudLibraryBookmark.save(root)

            let previousRoot = securityScopedRootURL
            let wasAccessingPreviousRoot = isAccessingSecurityScopedRoot
            repository = next.repository
            store = next.store
            libraryRootURL = root
            securityScopedRootURL = root
            isAccessingSecurityScopedRoot = isAccessing
            isUsingICloudDrive = true
            selectedDocumentID = nil
            reload()
            statusMessage = "Connected to the iCloud Drive library"

            if wasAccessingPreviousRoot, previousRoot != root {
                previousRoot?.stopAccessingSecurityScopedResource()
            }
        } catch {
            if isAccessing {
                root.stopAccessingSecurityScopedResource()
            }
            statusMessage = "Could not connect to iCloud Drive: \(error.localizedDescription)"
        }
        isSwitchingLibrary = false
    }

    func useLocalLibrary() {
        guard !isImporting, !isSwitchingLibrary else { return }
        isSwitchingLibrary = true
        do {
            let root = try LibraryLocation.defaultRoot()
            let next = try Self.makeModelComponents(root: root)
            let previousRoot = securityScopedRootURL
            let wasAccessingPreviousRoot = isAccessingSecurityScopedRoot
            repository = next.repository
            store = next.store
            libraryRootURL = root
            securityScopedRootURL = nil
            isAccessingSecurityScopedRoot = false
            isUsingICloudDrive = false
            selectedDocumentID = nil
            ICloudLibraryBookmark.clear()
            reload()
            statusMessage = "Using the local iPad library"
            if wasAccessingPreviousRoot {
                previousRoot?.stopAccessingSecurityScopedResource()
            }
        } catch {
            statusMessage = "Could not open the local library: \(error.localizedDescription)"
        }
        isSwitchingLibrary = false
    }

    func toggleReading() {
        guard let details = selectedDocument else { return }
        do {
            if details.document.isReading {
                try repository.clearReading()
            } else {
                try repository.setReading(documentId: details.id)
            }
            reload()
        } catch {
            statusMessage = "Could not update Currently Reading: \(error.localizedDescription)"
        }
    }

    func moveSelectedDocumentToTrash() {
        guard let id = selectedDocumentID else { return }
        do {
            try repository.delete(documentId: id)
            selectedDocumentID = nil
            statusMessage = "Moved to Trash"
            reload()
        } catch {
            statusMessage = "Could not move the document to Trash: \(error.localizedDescription)"
        }
    }

    func restoreSelectedDocument() {
        guard let id = selectedDocumentID else { return }
        do {
            try repository.restore(documentId: id)
            selectedDocumentID = nil
            statusMessage = "Restored from Trash"
            reload()
        } catch {
            statusMessage = "Could not restore the document: \(error.localizedDescription)"
        }
    }

    func pdfURL(for details: DocumentDetails) -> URL? {
        guard let hash = details.document.fileHash else { return nil }
        if store.exists(hash: hash) {
            return store.url(forHash: hash)
        }
        return store.ensureDownloaded(hash: hash) ? store.url(forHash: hash) : nil
    }

    private func documents(for section: LibrarySection) throws -> [DocumentDetails] {
        switch section {
        case .all:
            try repository.allDocuments()
        case .recent:
            try repository.recentDocuments(
                since: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
        case .reading:
            try repository.readingDocuments()
        case .uncategorized:
            try repository.uncategorizedDocuments()
        case .trash:
            try repository.trashedDocuments()
        case .collection(let id):
            try repository.allDocuments(in: id)
        case .tag(let id):
            try repository.documents(taggedWith: id)
        }
    }

    private static func importSummary(imported: Int, duplicates: Int, failures: Int) -> String {
        var parts = ["Imported \(imported)"]
        if duplicates > 0 {
            parts.append("\(duplicates) duplicate\(duplicates == 1 ? "" : "s") skipped")
        }
        if failures > 0 {
            parts.append("\(failures) failed")
        }
        return parts.joined(separator: ", ")
    }

    private static func makeModel(
        root: URL,
        securityScopedRootURL: URL? = nil,
        isAccessingSecurityScopedRoot: Bool = false
    ) throws -> IPadAppModel {
        let components = try makeModelComponents(root: root)
        return IPadAppModel(
            repository: components.repository,
            store: components.store,
            libraryRootURL: root,
            securityScopedRootURL: securityScopedRootURL,
            isAccessingSecurityScopedRoot: isAccessingSecurityScopedRoot)
    }

    private static func makeModelComponents(
        root: URL
    ) throws -> (repository: LibraryRepository, store: LibraryStore) {
        let store = try LibraryStore(rootURL: LibraryLocation.storeURL(root: root))
        let database = try AppDatabase.open(at: LibraryLocation.databaseURL(root: root))
        return (LibraryRepository(database), store)
    }
}
