import Foundation
@preconcurrency import GRDB

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

    // Non-optional keys for table sorting.
    public var sortTitle: String { document.title }
    public var sortYear: Int { document.year ?? 0 }
    public var sortVenue: String { document.venue ?? "" }
}

/// The library section that constrains a full-text search.
public enum LibrarySearchScope: Sendable {
    case all
    case recent(since: Date)
    case recentlyOpened(since: Date)
    case reading
    case uncategorized
    case duplicates
    case trash
    case collection(Int64)
    case tag(Int64)
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
        authors: [Author]? = nil,
        fullText: String? = nil
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
            // Use freshly extracted text when provided; otherwise keep the existing body.
            let body = try fullText ?? String.fetchOne(
                db, sql: "SELECT body FROM documentFTS WHERE rowid = ?", arguments: [doc.id!])
            try Self.updateFTS(db, document: doc, authors: savedAuthors, body: body)
            let tags = try Self.fetchTags(db, documentId: doc.id!)
            return DocumentDetails(document: doc, authors: savedAuthors, tags: tags)
        }
    }

    /// Moves a document to the Trash (recoverable). Its PDF and FTS row are kept.
    public func delete(documentId: Int64) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE document SET deletedAt = ?, modifiedAt = ? WHERE id = ?",
                arguments: [Date(), Date(), documentId])
        }
    }

    /// Restores a trashed document.
    public func restore(documentId: Int64) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE document SET deletedAt = NULL, modifiedAt = ? WHERE id = ?",
                arguments: [Date(), documentId])
        }
    }

    /// Permanently deletes a single document and its FTS row.
    public func purge(documentId: Int64) throws {
        try dbWriter.write { db in
            _ = try Document.deleteOne(db, key: documentId)
            try db.execute(sql: "DELETE FROM documentFTS WHERE rowid = ?", arguments: [documentId])
        }
    }

    /// Permanently deletes every trashed document. Returns the file hashes that
    /// are no longer referenced by any remaining document, for storage cleanup.
    public func emptyTrash() throws -> [String] {
        try dbWriter.write { db in
            let trashed = try Document.filter(Column("deletedAt") != nil).fetchAll(db)
            let ids = trashed.compactMap(\.id)
            for id in ids {
                try db.execute(sql: "DELETE FROM documentFTS WHERE rowid = ?", arguments: [id])
            }
            try Document.deleteAll(db, keys: ids)
            // Only hashes no surviving document still uses are safe to delete.
            let hashes = Set(trashed.compactMap(\.fileHash))
            return try hashes.filter { hash in
                try Document.filter(Column("fileHash") == hash).fetchCount(db) == 0
            }
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

    /// A *live* (non-trashed) document with this DOI, if any. Trashed rows are
    /// ignored so a paper in the Trash doesn't block re-adding it by DOI.
    public func document(doi: String) throws -> Document? {
        try dbWriter.read { db in
            try Document
                .filter(Column("doi") == doi && Column("deletedAt") == nil)
                .fetchOne(db)
        }
    }

    /// A live reference for the same paper (matched by DOI or arXiv ID) that has
    /// no PDF yet — the target for auto-attaching an imported PDF.
    public func liveDocumentNeedingPDF(doi: String?, arxivId: String?) throws -> Document? {
        guard let match = Self.paperMatch(doi: doi, arxivId: arxivId) else { return nil }
        return try dbWriter.read { db in
            try Document
                .filter(Column("deletedAt") == nil && Column("fileHash") == nil && match)
                .fetchOne(db)
        }
    }

    /// Permanently removes trashed, PDF-less references for the same paper. Used
    /// when importing a PDF for a paper whose metadata-only copy was trashed.
    public func purgeTrashedWithoutPDF(doi: String?, arxivId: String?) throws {
        guard let match = Self.paperMatch(doi: doi, arxivId: arxivId) else { return }
        try dbWriter.write { db in
            let ids = try Document
                .filter(Column("deletedAt") != nil && Column("fileHash") == nil && match)
                .fetchAll(db).compactMap(\.id)
            for id in ids {
                try db.execute(sql: "DELETE FROM documentFTS WHERE rowid = ?", arguments: [id])
            }
            try Document.deleteAll(db, keys: ids)
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
                        WHERE collectionDocument.collectionId = ? AND document.deletedAt IS NULL
                        ORDER BY document.addedAt DESC
                        """,
                    arguments: [collectionId])
            } else {
                docs = try Document
                    .filter(Column("deletedAt") == nil)
                    .order(Column("addedAt").desc)
                    .fetchAll(db)
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

    /// Documents added on or after the given date, newest first.
    public func recentDocuments(since date: Date) throws -> [DocumentDetails] {
        try dbWriter.read { db in
            let docs = try Document
                .filter(Column("addedAt") >= date && Column("deletedAt") == nil)
                .order(Column("addedAt").desc)
                .fetchAll(db)
            return try docs.map { doc in
                DocumentDetails(
                    document: doc,
                    authors: try Self.fetchAuthors(db, documentId: doc.id!),
                    tags: try Self.fetchTags(db, documentId: doc.id!)
                )
            }
        }
    }

    /// Records that the document's reader was just opened.
    public func markOpened(documentId: Int64) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE document SET openedAt = ? WHERE id = ?",
                arguments: [Date(), documentId])
        }
    }

    /// Documents opened on or after the given date, most recently opened first.
    public func recentlyOpenedDocuments(since date: Date) throws -> [DocumentDetails] {
        try dbWriter.read { db in
            let docs = try Document
                .filter(Column("openedAt") >= date && Column("deletedAt") == nil)
                .order(Column("openedAt").desc)
                .fetchAll(db)
            return try docs.map { doc in
                DocumentDetails(
                    document: doc,
                    authors: try Self.fetchAuthors(db, documentId: doc.id!),
                    tags: try Self.fetchTags(db, documentId: doc.id!)
                )
            }
        }
    }

    /// Marks one document as "Currently Reading", clearing any previous one
    /// (only a single document may be marked at a time).
    public func setReading(documentId: Int64) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE document SET isReading = 0 WHERE isReading = 1")
            try db.execute(
                sql: "UPDATE document SET isReading = 1 WHERE id = ?", arguments: [documentId])
        }
    }

    /// Clears the "Currently Reading" mark.
    public func clearReading() throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE document SET isReading = 0 WHERE isReading = 1")
        }
    }

    /// The single document marked "Currently Reading", if any.
    public func readingDocuments() throws -> [DocumentDetails] {
        try dbWriter.read { db in
            let docs = try Document
                .filter(Column("isReading") == true && Column("deletedAt") == nil)
                .fetchAll(db)
            return try docs.map { doc in
                DocumentDetails(
                    document: doc,
                    authors: try Self.fetchAuthors(db, documentId: doc.id!),
                    tags: try Self.fetchTags(db, documentId: doc.id!)
                )
            }
        }
    }

    /// Live documents that share a strong identifier (DOI, arXiv ID, or identical
    /// PDF bytes), grouped so the user can resolve duplicates. Each returned group
    /// has 2+ members; groups are ordered by the first member's title.
    public func duplicateGroups() throws -> [[DocumentDetails]] {
        let live = try allDocuments()
        var byKey: [String: [DocumentDetails]] = [:]
        for details in live {
            let doc = details.document
            let key: String?
            if let doi = doc.doi?.lowercased(), !doi.isEmpty {
                key = "doi:\(doi)"
            } else if let arxiv = doc.arxivId?.lowercased(), !arxiv.isEmpty {
                key = "arxiv:\(arxiv)"
            } else if let hash = doc.fileHash, !hash.isEmpty {
                key = "hash:\(hash)"
            } else {
                key = nil
            }
            if let key { byKey[key, default: []].append(details) }
        }
        return byKey.values
            .filter { $0.count > 1 }
            .sorted { $0[0].document.title.localizedStandardCompare($1[0].document.title) == .orderedAscending }
    }

    /// Documents that belong to no collection, newest first.
    public func uncategorizedDocuments() throws -> [DocumentDetails] {
        try dbWriter.read { db in
            let docs = try Document.fetchAll(
                db,
                sql: """
                    SELECT document.* FROM document
                    WHERE document.id NOT IN (SELECT documentId FROM collectionDocument)
                    AND document.deletedAt IS NULL
                    ORDER BY document.addedAt DESC
                    """)
            return try docs.map { doc in
                DocumentDetails(
                    document: doc,
                    authors: try Self.fetchAuthors(db, documentId: doc.id!),
                    tags: try Self.fetchTags(db, documentId: doc.id!)
                )
            }
        }
    }

    /// Trashed documents, most recently deleted first.
    public func trashedDocuments() throws -> [DocumentDetails] {
        try dbWriter.read { db in
            let docs = try Document
                .filter(Column("deletedAt") != nil)
                .order(Column("deletedAt").desc)
                .fetchAll(db)
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

    /// Stores an AI-generated insight (summary, key points, …) on the document.
    /// The column is taken from `DocumentInsight`'s fixed raw values, so the
    /// interpolation here is not user-controlled.
    public func setInsight(_ insight: DocumentInsight, documentId: Int64, text: String) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE document SET \(insight.rawValue) = ?, modifiedAt = ? WHERE id = ?",
                arguments: [text, Date(), documentId])
        }
    }

    public func fullText(documentId: Int64) throws -> String? {
        try dbWriter.read { db in
            try String.fetchOne(
                db, sql: "SELECT body FROM documentFTS WHERE rowid = ?", arguments: [documentId])
        }
    }

    // MARK: - Search

    /// FTS5 search across title, abstract, authors, and full text, constrained
    /// to the selected library section.
    public func search(
        _ query: String, scope: LibrarySearchScope = .all
    ) throws -> [DocumentDetails] {
        if case .duplicates = scope {
            let matchingIds = Set(try search(query, scope: .all).map(\.id))
            return try duplicateGroups()
                .filter { group in group.contains { matchingIds.contains($0.id) } }
                .flatMap { $0 }
        }

        let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
        guard pattern != nil else { return [] }

        let condition: String
        var arguments: StatementArguments = [pattern]
        switch scope {
        case .all, .duplicates:
            condition = "document.deletedAt IS NULL"
        case .recent(let date):
            condition = "document.deletedAt IS NULL AND document.addedAt >= ?"
            arguments += [date]
        case .recentlyOpened(let date):
            condition = "document.deletedAt IS NULL AND document.openedAt >= ?"
            arguments += [date]
        case .reading:
            condition = "document.deletedAt IS NULL AND document.isReading = 1"
        case .uncategorized:
            condition = """
                document.deletedAt IS NULL
                AND NOT EXISTS (
                    SELECT 1 FROM collectionDocument
                    WHERE collectionDocument.documentId = document.id
                )
                """
        case .trash:
            condition = "document.deletedAt IS NOT NULL"
        case .collection(let id):
            condition = """
                document.deletedAt IS NULL
                AND EXISTS (
                    SELECT 1 FROM collectionDocument
                    WHERE collectionDocument.documentId = document.id
                    AND collectionDocument.collectionId = ?
                )
                """
            arguments += [id]
        case .tag(let id):
            condition = """
                document.deletedAt IS NULL
                AND EXISTS (
                    SELECT 1 FROM documentTag
                    WHERE documentTag.documentId = document.id
                    AND documentTag.tagId = ?
                )
                """
            arguments += [id]
        }

        return try dbWriter.read { db in
            let docs = try Document.fetchAll(
                db,
                sql: """
                    SELECT document.* FROM document
                    JOIN documentFTS ON documentFTS.rowid = document.id
                    WHERE documentFTS MATCH ? AND \(condition)
                    ORDER BY rank
                    """,
                arguments: arguments)
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
            // Append after existing siblings.
            let next = try Int.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM collection
                    WHERE parentId IS ?
                    """,
                arguments: [parentId]) ?? 0
            var c = Collection(name: name, parentId: parentId, sortOrder: next)
            try c.insert(db)
            return c
        }
    }

    public func allCollections() throws -> [Collection] {
        try dbWriter.read { db in
            try Collection.order(Column("sortOrder"), Column("name")).fetchAll(db)
        }
    }

    /// Rewrites `sortOrder` for the given sibling ids in the order provided.
    public func reorderCollections(_ orderedIds: [Int64]) throws {
        try dbWriter.write { db in
            for (index, id) in orderedIds.enumerated() {
                try db.execute(
                    sql: "UPDATE collection SET sortOrder = ? WHERE id = ?",
                    arguments: [index, id])
            }
        }
    }

    /// Stores an AI-generated summary of a collection, with its generation time.
    public func setCollectionSummary(id: Int64, text: String) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE collection SET summary = ?, summaryUpdatedAt = ? WHERE id = ?",
                arguments: [text, Date(), id])
        }
    }

    public func setCollectionIcon(id: Int64, to icon: String?) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE collection SET icon = ? WHERE id = ?", arguments: [icon, id])
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
                    WHERE documentTag.tagId = ? AND document.deletedAt IS NULL
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

    // MARK: - Color labels

    public func colorLabels(documentId: Int64) throws -> [String: String] {
        try dbWriter.read { db in
            let rows = try ColorLabel.filter(Column("documentId") == documentId).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.colorHex, $0.label) })
        }
    }

    /// Sets the label for a color in one document; an empty label removes it.
    public func setColorLabel(documentId: Int64, colorHex: String, label: String) throws {
        try dbWriter.write { db in
            if label.isEmpty {
                try db.execute(
                    sql: "DELETE FROM colorLabel WHERE documentId = ? AND colorHex = ?",
                    arguments: [documentId, colorHex])
            } else {
                try ColorLabel(documentId: documentId, colorHex: colorHex, label: label)
                    .upsert(db)
            }
        }
    }

    // MARK: - Maintenance & stats

    /// Every file hash referenced by a document, including trashed ones.
    public func referencedFileHashes() throws -> Set<String> {
        try dbWriter.read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT fileHash FROM document WHERE fileHash IS NOT NULL"))
        }
    }

    /// Counts for the library stats pane.
    public func counts() throws -> (live: Int, trashed: Int, withPDF: Int) {
        try dbWriter.read { db in
            let live = try Document.filter(Column("deletedAt") == nil).fetchCount(db)
            let trashed = try Document.filter(Column("deletedAt") != nil).fetchCount(db)
            let withPDF = try Document
                .filter(Column("deletedAt") == nil && Column("fileHash") != nil)
                .fetchCount(db)
            return (live, trashed, withPDF)
        }
    }

    // MARK: - Internals

    /// Matches a document to a paper by DOI or arXiv ID (OR of whichever are
    /// present). Nil when neither identifier is given.
    private static func paperMatch(doi: String?, arxivId: String?) -> SQLExpression? {
        var terms: [SQLExpression] = []
        if let doi { terms.append(Column("doi") == doi) }
        if let arxivId { terms.append(Column("arxivId") == arxivId) }
        guard let first = terms.first else { return nil }
        return terms.dropFirst().reduce(first) { $0 || $1 }
    }

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
