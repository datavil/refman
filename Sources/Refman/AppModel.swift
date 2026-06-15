import AppKit
import Foundation
import RefmanCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case all
    case recent
    case uncategorized
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
    case bibtex, ris, cslJSON
}

@MainActor
final class AppModel: ObservableObject {
    let repository: LibraryRepository
    let store: LibraryStore

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
    @Published var collections: [RefmanCore.Collection] = []
    @Published var tags: [Tag] = []
    @Published var sidebarSelection: SidebarItem = .all
    @Published var selectedDocumentId: Int64?
    @Published var searchText: String = ""
    @Published var statusMessage: String?
    @Published var isImporting = false
    @Published var importProgress: (done: Int, total: Int)?
    @Published var importLog: [ImportOutcome] = []

    /// Incremented to ask the UI to surface the add-reference popover / command palette.
    @Published var addRequested = 0
    @Published var paletteRequested = 0

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
        return (try? LibraryLocation.defaultRoot())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Refman")
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
                case .recent:
                    let weekAgo = Calendar.current.date(
                        byAdding: .day, value: -7, to: Date()) ?? Date()
                    documents = try repository.recentDocuments(since: weekAgo)
                case .uncategorized:
                    documents = try repository.uncategorizedDocuments()
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
                    let result = try await pipeline.importPDF(at: url)
                    log.append(.init(name: name, status: result.wasDuplicate ? .duplicate : .imported))
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

    func moveLibraryToICloudDrive() {
        guard let target = LibraryLocation.iCloudDriveRoot() else {
            statusMessage = "iCloud Drive isn't enabled on this Mac."
            return
        }
        moveLibrary(to: target)
    }

    func moveLibraryToLocal() {
        guard let target = try? LibraryLocation.defaultRoot() else { return }
        moveLibrary(to: target)
    }

    /// Points the library at `newRoot`, then asks the user to relaunch (the open
    /// database connection isn't reopened in place). If a library already exists
    /// at the destination (e.g. synced from another Mac) it's adopted in place
    /// rather than overwritten.
    private func moveLibrary(to newRoot: URL) {
        let current = libraryRootURL
        guard current.standardizedFileURL != newRoot.standardizedFileURL else { return }
        let destHasLibrary = FileManager.default.fileExists(
            atPath: LibraryLocation.databaseURL(root: newRoot).path)
        do {
            if !destHasLibrary {
                try LibraryLocation.relocate(from: current, to: newRoot)
            }
            try? LibraryLocation.setHidden(true, at: newRoot)
            UserDefaults.standard.set(newRoot.path, forKey: SettingsKeys.libraryRootPath)
            statusMessage = destHasLibrary
                ? "Found an existing library here — quit and reopen Refman to use it."
                : "Library moved — quit and reopen Refman to use the new location."
        } catch {
            statusMessage = "Move failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Files

    func pdfURL(for details: DocumentDetails) -> URL? {
        guard let hash = details.document.fileHash else { return nil }
        if store.exists(hash: hash) { return store.url(forHash: hash) }
        // Possibly evicted by iCloud — request a download for next time.
        return store.ensureDownloaded(hash: hash) ? store.url(forHash: hash) : nil
    }
}
