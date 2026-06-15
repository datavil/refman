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
