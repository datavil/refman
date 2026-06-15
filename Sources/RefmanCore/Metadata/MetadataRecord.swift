import Foundation

/// Provider-neutral resolved metadata, ready to merge into a Document.
public struct MetadataRecord: Equatable, Sendable {
    public var type: DocumentType
    public var title: String
    public var abstract: String?
    public var authors: [(given: String, family: String)]
    public var year: Int?
    public var venue: String?
    public var volume: String?
    public var issue: String?
    public var pages: String?
    public var doi: String?
    public var arxivId: String?
    public var url: String?

    public init(
        type: DocumentType = .article,
        title: String,
        abstract: String? = nil,
        authors: [(given: String, family: String)] = [],
        year: Int? = nil,
        venue: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        pages: String? = nil,
        doi: String? = nil,
        arxivId: String? = nil,
        url: String? = nil
    ) {
        self.type = type
        self.title = TextDecoding.clean(title)
        self.abstract = abstract.map(TextDecoding.clean)
        self.authors = authors.map {
            (given: TextDecoding.clean($0.given), family: TextDecoding.clean($0.family))
        }
        self.year = year
        self.venue = venue.map(TextDecoding.clean)
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.doi = doi
        self.arxivId = arxivId
        self.url = url
    }

    public static func == (lhs: MetadataRecord, rhs: MetadataRecord) -> Bool {
        lhs.title == rhs.title && lhs.doi == rhs.doi && lhs.year == rhs.year
            && lhs.authors.map(\.family) == rhs.authors.map(\.family)
    }

    /// Applies this record onto a document, overwriting resolved fields.
    public func apply(to document: inout Document) {
        document.type = type
        document.title = title
        if let abstract { document.abstract = abstract }
        if let year { document.year = year }
        if let venue { document.venue = venue }
        if let volume { document.volume = volume }
        if let issue { document.issue = issue }
        if let pages { document.pages = pages }
        if let doi { document.doi = doi }
        if let arxivId { document.arxivId = arxivId }
        if let url { document.url = url }
        document.modifiedAt = Date()
    }

    public var authorRecords: [Author] {
        authors.map { Author(given: $0.given, family: $0.family) }
    }
}

/// Anything that can turn an identifier into metadata.
public protocol MetadataResolver: Sendable {
    func resolve(doi: String) async throws -> MetadataRecord?
    func resolve(arxivId: String) async throws -> MetadataRecord?
}
