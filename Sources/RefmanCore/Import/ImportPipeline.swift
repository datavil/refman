import Foundation

/// End-to-end PDF import:
/// file → hash → store → text extraction → DOI/arXiv scan → metadata resolution → DB row.
public struct ImportPipeline: Sendable {
    public struct Result: Sendable {
        public var details: DocumentDetails
        public var wasDuplicate: Bool
        public var resolvedOnline: Bool
    }

    /// Result of adding a reference from a pasted identifier.
    public enum AddOutcome: Sendable {
        case added(DocumentDetails)
        case duplicate(DocumentDetails)
        case notFound
        case unrecognized
    }

    let repository: LibraryRepository
    let store: LibraryStore
    let crossRef: CrossRefClient
    let arXiv: ArXivClient
    let pubMed: PubMedClient
    let pdfFetcher: PDFFetcher

    public init(
        repository: LibraryRepository,
        store: LibraryStore,
        crossRef: CrossRefClient = CrossRefClient(),
        arXiv: ArXivClient = ArXivClient(),
        pubMed: PubMedClient = PubMedClient(),
        pdfFetcher: PDFFetcher = PDFFetcher()
    ) {
        self.repository = repository
        self.store = store
        self.crossRef = crossRef
        self.arXiv = arXiv
        self.pubMed = pubMed
        self.pdfFetcher = pdfFetcher
    }

    /// Outcome of importing a single PDF.
    public enum PDFOutcome: Sendable {
        case imported(Result)
        /// A live (non-trashed) document already holds these bytes; skipped.
        case duplicate(DocumentDetails)
        /// The matching document is in the Trash; the caller must decide whether
        /// to restore it or import the file as a separate new copy.
        case inTrash(existing: DocumentDetails, sourceURL: URL)
    }

    /// Imports one PDF. Network failures degrade gracefully to offline metadata.
    public func importPDF(at url: URL) async throws -> PDFOutcome {
        let hash = try store.ingest(fileAt: url)

        // Same bytes already on file? Surface the existing record so the caller
        // can skip a live duplicate or prompt about a trashed one.
        if let existing = try repository.document(fileHash: hash),
            let details = try repository.document(id: existing.id!)
        {
            return existing.deletedAt == nil
                ? .duplicate(details)
                : .inTrash(existing: details, sourceURL: url)
        }

        return .imported(try await ingest(hash: hash, url: url))
    }

    /// Imports `url` as a brand-new record even when its bytes match an existing
    /// (e.g. trashed) document — used when the user opts to keep a separate copy.
    public func importPDFAsNew(at url: URL) async throws -> Result {
        let hash = try store.ingest(fileAt: url)
        return try await ingest(hash: hash, url: url)
    }

    /// Extracts text, resolves metadata online, and inserts a fresh document row.
    private func ingest(hash: String, url: URL) async throws -> Result {
        let extracted = PDFTextExtractor.extract(from: store.url(forHash: hash))
        let head = extracted?.headText ?? ""
        let scannedDOI = IdentifierScanner.firstDOI(in: head)
        let scannedArxiv = IdentifierScanner.firstArxivID(in: head)

        // Resolve online; failures are non-fatal.
        var record: MetadataRecord?
        var resolvedOnline = false
        if let scannedDOI {
            record = try? await crossRef.resolve(doi: scannedDOI)
            resolvedOnline = record != nil
        }
        if record == nil, let scannedArxiv {
            record = try? await arXiv.resolve(arxivId: scannedArxiv)
            resolvedOnline = record != nil
        }

        let doi = record?.doi ?? scannedDOI
        let arxivId = record?.arxivId ?? scannedArxiv

        // Same paper already in the library without a PDF (e.g. added by DOI)?
        // Attach the file to it rather than creating a duplicate row.
        if let existing = try repository.liveDocumentNeedingPDF(doi: doi, arxivId: arxivId) {
            var updated = existing
            record?.apply(to: &updated)
            updated.fileHash = hash
            updated.fileName = url.lastPathComponent
            let details = try repository.update(
                updated, authors: record?.authorRecords, fullText: extracted?.fullText)
            return Result(details: details, wasDuplicate: false, resolvedOnline: resolvedOnline)
        }

        // A metadata-only copy sitting in the Trash is superseded by this import.
        try repository.purgeTrashedWithoutPDF(doi: doi, arxivId: arxivId)

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

    /// Adds a (PDF-less) reference from a pasted DOI, arXiv ID, PubMed ID, or link.
    /// Dedupes on DOI when the resolved record carries one.
    public func importIdentifier(_ raw: String) async throws -> AddOutcome {
        guard let identifier = IdentifierScanner.classify(raw) else { return .unrecognized }

        let record: MetadataRecord?
        switch identifier {
        case .doi(let doi): record = try? await crossRef.resolve(doi: doi)
        case .arxiv(let id): record = try? await arXiv.resolve(arxivId: id)
        case .pubmed(let pmid): record = try? await pubMed.resolve(pmid: pmid)
        }
        guard let record else { return .notFound }

        if let doi = record.doi, let existing = try repository.document(doi: doi),
            let details = try repository.document(id: existing.id!)
        {
            return .duplicate(details)
        }

        var document = Document()
        record.apply(to: &document)

        // Best-effort: attach an openly available PDF if one can be found.
        var fullText: String?
        if let (data, name) = try? await downloadPDF(arxivId: record.arxivId, doi: record.doi) {
            let hash = try store.ingest(data: data)
            document.fileHash = hash
            document.fileName = name
            fullText = PDFTextExtractor.extract(from: store.url(forHash: hash))?.fullText
        }

        let details = try repository.insert(
            document, authors: record.authorRecords, fullText: fullText)
        return .added(details)
    }

    /// Attaches a user-picked local PDF to an existing reference, storing its
    /// bytes and indexing its extracted text.
    public func attachPDF(at url: URL, to document: Document) throws -> DocumentDetails {
        let hash = try store.ingest(fileAt: url)
        var updated = document
        updated.fileHash = hash
        updated.fileName = url.lastPathComponent
        let fullText = PDFTextExtractor.extract(from: store.url(forHash: hash))?.fullText
        return try repository.update(updated, fullText: fullText)
    }

    /// Downloads and attaches an open-access PDF to an existing document.
    /// Returns the updated details, or nil if no PDF could be found.
    public func fetchPDF(for document: Document) async throws -> DocumentDetails? {
        guard let (data, name) = try await downloadPDF(
            arxivId: document.arxivId, doi: document.doi)
        else { return nil }

        let hash = try store.ingest(data: data)
        var updated = document
        updated.fileHash = hash
        updated.fileName = name
        let fullText = PDFTextExtractor.extract(from: store.url(forHash: hash))?.fullText
        return try repository.update(updated, fullText: fullText)
    }

    /// Finds a downloadable PDF, preferring the arXiv copy and falling back to
    /// an open-access copy of the DOI.
    private func downloadPDF(
        arxivId: String?, doi: String?
    ) async throws -> (data: Data, fileName: String)? {
        if let arxivId, let data = try? await pdfFetcher.fetchArxiv(arxivId) {
            return (data, "\(arxivId).pdf")
        }
        if let doi, let data = try? await pdfFetcher.fetchOpenAccess(doi: doi) {
            return (data, "\(doi.replacingOccurrences(of: "/", with: "_")).pdf")
        }
        return nil
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
