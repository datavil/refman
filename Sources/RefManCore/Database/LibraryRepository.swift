import Foundation
import GRDB

/// A document with its authors and tags resolved, for display and export.
public struct DocumentDetails: Identifiable, Equatable, Hashable, Sendable {
    public var document: Document
    public var authors: [Author]
    public var tags: [Tag]

    /// Row id; documents coming out of the repository always have one.
    public var id: Int64 { document.id ?? -1 }

    public init(document: Document, authors: [Author] = [], tags: [Tag] = []) {
        self.document = document
        self.authors = authors
        self.tags = tags
    }

    public var authorsText: String {
        authors.map(\.displayName).joined(separator: ", ")
    }
}

/// High-level library operations. All writes keep the FTS index in sync.
public final class LibraryRepository: Sendable {
    public let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    private var dbWriter: any DatabaseWriter { database.dbWriter }

    // MARK: - Documents

    /// Inserts a document with its author list. Returns the saved details.
    @discardableResult
    public func insert(
        _ document: Document,
        authors: [Author] = [],
        fullText: String? = nil
    ) throws -> DocumentDetails {
        try dbWriter.write { db in
            var doc = document
            try doc.insert(db)
            let savedAuthors = try Self.setAuthors(db, documentId: doc.id!, authors: authors)
            try Self.updateFTS(db, document: doc, authors: savedAuthors, body: fullText)
            return DocumentDetails(document: doc, authors: savedAuthors)
        }
    }

    /// Updates metadata (and optionally authors), bumping modifiedAt.
    @discardableResult
    public func update(
        _ document: Document,
        authors: [Author]? = nil
    ) throws -> DocumentDetails {
        try dbWriter.write { db in
            var doc = document
            doc.modifiedAt = Date()
            try doc.update(db)
            let savedAuthors: [Author]
            if let authors {
                try DocumentAuthor.filter(Column("documentId") == doc.id!).deleteAll(db)
                savedAuthors = try Self.setAuthors(db, documentId: doc.id!, authors: authors)
            } else {
                savedAuthors = try Self.fetchAuthors(db, documentId: doc.id!)
            }
            let body = try String.fetchOne(
                db, sql: "SELECT body FROM documentFTS WHERE rowid = ?", arguments: [doc.id!])
            try Self.updateFTS(db, document: doc, authors: savedAuthors, body: body)
            let tags = try Self.fetchTags(db, documentId: doc.id!)
            return DocumentDetails(document: doc, authors: savedAuthors, tags: tags)
        }
    }

    public func delete(documentId: Int64) throws {
        try dbWriter.write { db in
            _ = try Document.deleteOne(db, key: documentId)
            try db.execute(sql: "DELETE FROM documentFTS WHERE rowid = ?", arguments: [documentId])
        }
    }

    public func document(id: Int64) throws -> DocumentDetails? {
        try dbWriter.read { db in
            guard let doc = try Document.fetchOne(db, key: id) else { return nil }
            return DocumentDetails(
                document: doc,
                authors: try Self.fetchAuthors(db, documentId: id),
                tags: try Self.fetchTags(db, documentId: id)
            )
        }
    }

    public func document(doi: String) throws -> Document? {
        try dbWriter.read { db in
            try Document.filter(Column("doi") == doi).fetchOne(db)
        }
    }

    public func document(fileHash: String) throws -> Document? {
        try dbWriter.read { db in
            try Document.filter(Column("fileHash") == fileHash).fetchOne(db)
        }
    }

    /// All documents, optionally scoped to a collection, newest first.
    public func allDocuments(in collectionId: Int64? = nil) throws -> [DocumentDetails] {
        try dbWriter.read { db in
            let docs: [Document]
            if let collectionId {
                docs = try Document.fetchAll(
                    db,
                    sql: """
                        SELECT document.* FROM document
                        JOIN collectionDocument ON collectionDocument.documentId = document.id
                        WHERE collectionDocument.collectionId = ?
                        ORDER BY document.addedAt DESC
                        """,
                    arguments: [collectionId])
            } else {
                docs = try Document.order(Column("addedAt").desc).fetchAll(db)
            }
            return try docs.map { doc in
                DocumentDetails(
                    document: doc,
                    authors: try Self.fetchAuthors(db, documentId: doc.id!),
                    tags: try Self.fetchTags(db, documentId: doc.id!)
                )
            }
        }
    }

    /// Stores the extracted full text of a document's PDF in the FTS index.
    public func setFullText(documentId: Int64, text: String) throws {
        try dbWriter.write { db in
            guard let doc = try Document.fetchOne(db, key: documentId) else { return }
            let authors = try Self.fetchAuthors(db, documentId: documentId)
            try Self.updateFTS(db, document: doc, authors: authors, body: text)
        }
    }

    public func fullText(documentId: Int64) throws -> String? {
        try dbWriter.read { db in
            try String.fetchOne(
                db, sql: "SELECT body FROM documentFTS WHERE rowid = ?", arguments: [documentId])
        }
    }

    // MARK: - Search

    /// FTS5 search across title, abstract, authors, and full text.
    public func search(_ query: String) throws -> [DocumentDetails] {
        let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
        guard pattern != nil else { return [] }
        return try dbWriter.read { db in
            let docs = try Document.fetchAll(
                db,
                sql: """
                    SELECT document.* FROM document
                    JOIN documentFTS ON documentFTS.rowid = document.id
                    WHERE documentFTS MATCH ?
                    ORDER BY rank
                    """,
                arguments: [pattern])
            return try docs.map { doc in
                DocumentDetails(
                    document: doc,
                    authors: try Self.fetchAuthors(db, documentId: doc.id!),
                    tags: try Self.fetchTags(db, documentId: doc.id!)
                )
            }
        }
    }

    // MARK: - Collections

    @discardableResult
    public func createCollection(name: String, parentId: Int64? = nil) throws -> Collection {
        try dbWriter.write { db in
            var c = Collection(name: name, parentId: parentId)
            try c.insert(db)
            return c
        }
    }

    public func allCollections() throws -> [Collection] {
        try dbWriter.read { db in
            try Collection.order(Column("name")).fetchAll(db)
        }
    }

    public func renameCollection(id: Int64, to name: String) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE collection SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    public func deleteCollection(id: Int64) throws {
        _ = try dbWriter.write { db in try Collection.deleteOne(db, key: id) }
    }

    public func add(documentId: Int64, toCollection collectionId: Int64) throws {
        try dbWriter.write { db in
            try CollectionDocument(collectionId: collectionId, documentId: documentId)
                .upsert(db)
        }
    }

    public func remove(documentId: Int64, fromCollection collectionId: Int64) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM collectionDocument WHERE collectionId = ? AND documentId = ?",
                arguments: [collectionId, documentId])
        }
    }

    // MARK: - Tags

    @discardableResult
    public func addTag(_ name: String, toDocument documentId: Int64) throws -> Tag {
        try dbWriter.write { db in
            let tag: Tag
            if let existing = try Tag.filter(Column("name") == name).fetchOne(db) {
                tag = existing
            } else {
                var t = Tag(name: name)
                try t.insert(db)
                tag = t
            }
            try DocumentTag(documentId: documentId, tagId: tag.id!).upsert(db)
            return tag
        }
    }

    public func removeTag(_ tagId: Int64, fromDocument documentId: Int64) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM documentTag WHERE documentId = ? AND tagId = ?",
                arguments: [documentId, tagId])
            // Drop orphaned tags.
            try db.execute(
                sql: """
                    DELETE FROM tag WHERE id = ?
                    AND NOT EXISTS (SELECT 1 FROM documentTag WHERE tagId = ?)
                    """,
                arguments: [tagId, tagId])
        }
    }

    public func allTags() throws -> [Tag] {
        try dbWriter.read { db in try Tag.order(Column("name")).fetchAll(db) }
    }

    public func documents(taggedWith tagId: Int64) throws -> [DocumentDetails] {
        try dbWriter.read { db in
            let docs = try Document.fetchAll(
                db,
                sql: """
                    SELECT document.* FROM document
                    JOIN documentTag ON documentTag.documentId = document.id
                    WHERE documentTag.tagId = ?
                    ORDER BY document.addedAt DESC
                    """,
                arguments: [tagId])
            return try docs.map { doc in
                DocumentDetails(
                    document: doc,
                    authors: try Self.fetchAuthors(db, documentId: doc.id!),
                    tags: try Self.fetchTags(db, documentId: doc.id!)
                )
            }
        }
    }

    // MARK: - Annotations

    @discardableResult
    public func insert(_ annotation: Annotation) throws -> Annotation {
        try dbWriter.write { db in
            var a = annotation
            try a.insert(db)
            return a
        }
    }

    public func deleteAnnotation(uuid: String) throws {
        try dbWriter.write { db in
            try db.execute(sql: "DELETE FROM annotation WHERE uuid = ?", arguments: [uuid])
        }
    }

    public func annotations(documentId: Int64) throws -> [Annotation] {
        try dbWriter.read { db in
            try Annotation
                .filter(Column("documentId") == documentId)
                .order(Column("pageIndex"), Column("createdAt"))
                .fetchAll(db)
        }
    }

    // MARK: - Internals

    private static func setAuthors(
        _ db: Database, documentId: Int64, authors: [Author]
    ) throws -> [Author] {
        var saved: [Author] = []
        for (i, author) in authors.enumerated() {
            let a: Author
            if let existing = try Author
                .filter(Column("given") == author.given && Column("family") == author.family)
                .fetchOne(db)
            {
                a = existing
            } else {
                var new = author
                new.id = nil
                try new.insert(db)
                a = new
            }
            try DocumentAuthor(documentId: documentId, authorId: a.id!, position: i).upsert(db)
            saved.append(a)
        }
        return saved
    }

    private static func fetchAuthors(_ db: Database, documentId: Int64) throws -> [Author] {
        try Author.fetchAll(
            db,
            sql: """
                SELECT author.* FROM author
                JOIN documentAuthor ON documentAuthor.authorId = author.id
                WHERE documentAuthor.documentId = ?
                ORDER BY documentAuthor.position
                """,
            arguments: [documentId])
    }

    private static func fetchTags(_ db: Database, documentId: Int64) throws -> [Tag] {
        try Tag.fetchAll(
            db,
            sql: """
                SELECT tag.* FROM tag
                JOIN documentTag ON documentTag.tagId = tag.id
                WHERE documentTag.documentId = ?
                ORDER BY tag.name
                """,
            arguments: [documentId])
    }

    private static func updateFTS(
        _ db: Database, document: Document, authors: [Author], body: String?
    ) throws {
        try db.execute(
            sql: "DELETE FROM documentFTS WHERE rowid = ?", arguments: [document.id!])
        try db.execute(
            sql: """
                INSERT INTO documentFTS(rowid, title, abstract, authors, body)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                document.id!,
                document.title,
                document.abstract ?? "",
                authors.map(\.displayName).joined(separator: ", "),
                body ?? "",
            ])
    }
}
