import Foundation

/// End-to-end PDF import:
/// file → hash → store → text extraction → DOI/arXiv scan → metadata resolution → DB row.
public struct ImportPipeline: Sendable {
    public struct Result: Sendable {
        public var details: DocumentDetails
        public var wasDuplicate: Bool
        public var resolvedOnline: Bool
    }

    let repository: LibraryRepository
    let store: LibraryStore
    let crossRef: CrossRefClient
    let arXiv: ArXivClient

    public init(
        repository: LibraryRepository,
        store: LibraryStore,
        crossRef: CrossRefClient = CrossRefClient(),
        arXiv: ArXivClient = ArXivClient()
    ) {
        self.repository = repository
        self.store = store
        self.crossRef = crossRef
        self.arXiv = arXiv
    }

    /// Imports one PDF. Network failures degrade gracefully to offline metadata.
    public func importPDF(at url: URL) async throws -> Result {
        let hash = try store.ingest(fileAt: url)

        // Same bytes already in the library? Return the existing record.
        if let existing = try repository.document(fileHash: hash),
            let details = try repository.document(id: existing.id!)
        {
            return Result(details: details, wasDuplicate: true, resolvedOnline: false)
        }

        let extracted = PDFTextExtractor.extract(from: store.url(forHash: hash))
        let head = extracted?.headText ?? ""
        let doi = IdentifierScanner.firstDOI(in: head)
        let arxivId = IdentifierScanner.firstArxivID(in: head)

        // Resolve online; failures are non-fatal.
        var record: MetadataRecord?
        var resolvedOnline = false
        if let doi {
            record = try? await crossRef.resolve(doi: doi)
            resolvedOnline = record != nil
        }
        if record == nil, let arxivId {
            record = try? await arXiv.resolve(arxivId: arxivId)
            resolvedOnline = record != nil
        }

        var document = Document(
            title: extracted?.embeddedTitle ?? url.deletingPathExtension().lastPathComponent,
            doi: doi,
            arxivId: arxivId,
            fileHash: hash,
            fileName: url.lastPathComponent
        )
        var authors: [Author] = []
        if let record {
            record.apply(to: &document)
            authors = record.authorRecords
        }

        let details = try repository.insert(
            document, authors: authors, fullText: extracted?.fullText)
        return Result(details: details, wasDuplicate: false, resolvedOnline: resolvedOnline)
    }

    /// Re-resolves an existing document's metadata from its DOI/arXiv ID.
    /// Returns the updated details, or nil if it has no identifier or resolution failed.
    public func refreshMetadata(for document: Document) async throws -> DocumentDetails? {
        var record: MetadataRecord?
        if let doi = document.doi {
            record = try? await crossRef.resolve(doi: doi)
        }
        if record == nil, let arxivId = document.arxivId {
            record = try? await arXiv.resolve(arxivId: arxivId)
        }
        guard let record else { return nil }

        var updated = document
        record.apply(to: &updated)
        let authors = record.authors.isEmpty ? nil : record.authorRecords
        return try repository.update(updated, authors: authors)
    }
}
