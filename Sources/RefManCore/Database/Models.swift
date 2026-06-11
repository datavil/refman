import Foundation
import GRDB

public enum DocumentType: String, Codable, CaseIterable, Sendable {
    case article, book, chapter, conferencePaper, thesis, report, preprint, webpage, misc
}

public struct Document: Identifiable, Equatable, Hashable, Codable,
    FetchableRecord, MutablePersistableRecord, Sendable
{
    public var id: Int64?
    public var uuid: String
    public var type: DocumentType
    public var title: String
    public var abstract: String?
    public var year: Int?
    public var venue: String?
    public var volume: String?
    public var issue: String?
    public var pages: String?
    public var doi: String?
    public var arxivId: String?
    public var url: String?
    public var fileHash: String?
    public var fileName: String?
    public var addedAt: Date
    public var modifiedAt: Date

    public init(
        id: Int64? = nil,
        uuid: String = UUID().uuidString,
        type: DocumentType = .article,
        title: String = "",
        abstract: String? = nil,
        year: Int? = nil,
        venue: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        pages: String? = nil,
        doi: String? = nil,
        arxivId: String? = nil,
        url: String? = nil,
        fileHash: String? = nil,
        fileName: String? = nil,
        addedAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.uuid = uuid
        self.type = type
        self.title = title
        self.abstract = abstract
        self.year = year
        self.venue = venue
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.doi = doi
        self.arxivId = arxivId
        self.url = url
        self.fileHash = fileHash
        self.fileName = fileName
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt
    }

    public static let databaseTableName = "document"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let authors = hasMany(Author.self, through: hasMany(DocumentAuthor.self), using: DocumentAuthor.author)
    public static let tags = hasMany(Tag.self, through: hasMany(DocumentTag.self), using: DocumentTag.tag)
    public static let annotations = hasMany(Annotation.self)
}

public struct Author: Identifiable, Equatable, Hashable, Codable,
    FetchableRecord, MutablePersistableRecord, Sendable
{
    public var id: Int64?
    public var given: String
    public var family: String

    public init(id: Int64? = nil, given: String = "", family: String) {
        self.id = id
        self.given = given
        self.family = family
    }

    public static let databaseTableName = "author"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// "Given Family", or just one of them when the other is empty.
    public var displayName: String {
        [given, family].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public struct DocumentAuthor: Codable, FetchableRecord, PersistableRecord, Sendable {
    public var documentId: Int64
    public var authorId: Int64
    public var position: Int

    public init(documentId: Int64, authorId: Int64, position: Int) {
        self.documentId = documentId
        self.authorId = authorId
        self.position = position
    }

    public static let databaseTableName = "documentAuthor"
    public static let author = belongsTo(Author.self)
}

public struct Collection: Identifiable, Equatable, Hashable, Codable,
    FetchableRecord, MutablePersistableRecord, Sendable
{
    public var id: Int64?
    public var uuid: String
    public var name: String
    public var parentId: Int64?

    public init(id: Int64? = nil, uuid: String = UUID().uuidString, name: String, parentId: Int64? = nil) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.parentId = parentId
    }

    public static let databaseTableName = "collection"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct CollectionDocument: Codable, FetchableRecord, PersistableRecord, Sendable {
    public var collectionId: Int64
    public var documentId: Int64

    public init(collectionId: Int64, documentId: Int64) {
        self.collectionId = collectionId
        self.documentId = documentId
    }

    public static let databaseTableName = "collectionDocument"
}

public struct Tag: Identifiable, Equatable, Hashable, Codable,
    FetchableRecord, MutablePersistableRecord, Sendable
{
    public var id: Int64?
    public var name: String

    public init(id: Int64? = nil, name: String) {
        self.id = id
        self.name = name
    }

    public static let databaseTableName = "tag"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct DocumentTag: Codable, FetchableRecord, PersistableRecord, Sendable {
    public var documentId: Int64
    public var tagId: Int64

    public init(documentId: Int64, tagId: Int64) {
        self.documentId = documentId
        self.tagId = tagId
    }

    public static let databaseTableName = "documentTag"
    public static let tag = belongsTo(Tag.self)
}

public enum AnnotationKind: String, Codable, Sendable {
    case highlight, underline, note
}

public struct Annotation: Identifiable, Equatable, Hashable, Codable,
    FetchableRecord, MutablePersistableRecord, Sendable
{
    public var id: Int64?
    public var uuid: String
    public var documentId: Int64
    public var pageIndex: Int
    public var kind: AnnotationKind
    public var colorHex: String
    /// JSON-encoded array of quads, each quad 8 doubles (PDF-space points).
    public var quadPoints: String?
    public var selectedText: String?
    public var noteText: String?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: Int64? = nil,
        uuid: String = UUID().uuidString,
        documentId: Int64,
        pageIndex: Int,
        kind: AnnotationKind,
        colorHex: String = "#FFEB3B",
        quadPoints: String? = nil,
        selectedText: String? = nil,
        noteText: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.uuid = uuid
        self.documentId = documentId
        self.pageIndex = pageIndex
        self.kind = kind
        self.colorHex = colorHex
        self.quadPoints = quadPoints
        self.selectedText = selectedText
        self.noteText = noteText
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public static let databaseTableName = "annotation"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
