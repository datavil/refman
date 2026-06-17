import Foundation
import GRDB

/// Owns the SQLite connection and schema migrations.
public final class AppDatabase: Sendable {
    public let dbWriter: any DatabaseWriter

    public init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    /// Opens (creating if needed) the database at the given URL.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: url.path)
        return try AppDatabase(dbQueue)
    }

    /// Opens the database from a second process (refman-agent's MCP server):
    /// waits briefly on locks held by the app instead of failing immediately.
    public static func openShared(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.busyMode = .timeout(2.0)
        return try AppDatabase(DatabaseQueue(path: url.path, configuration: config))
    }

    /// Filesystem path of the database, if file-backed.
    public var path: String? {
        (dbWriter as? DatabaseQueue)?.path
    }

    /// An in-memory database, for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "document") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("type", .text).notNull().defaults(to: "article")
                t.column("title", .text).notNull().defaults(to: "")
                t.column("abstract", .text)
                t.column("year", .integer)
                t.column("venue", .text)
                t.column("volume", .text)
                t.column("issue", .text)
                t.column("pages", .text)
                t.column("doi", .text).unique()
                t.column("arxivId", .text)
                t.column("url", .text)
                t.column("fileHash", .text)
                t.column("fileName", .text)
                t.column("addedAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
            }

            try db.create(table: "author") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("given", .text).notNull().defaults(to: "")
                t.column("family", .text).notNull()
                t.uniqueKey(["given", "family"])
            }

            try db.create(table: "documentAuthor") { t in
                t.belongsTo("document", onDelete: .cascade).notNull()
                t.belongsTo("author", onDelete: .cascade).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
                t.primaryKey(["documentId", "authorId"])
            }

            try db.create(table: "collection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("parentId", .integer)
                    .references("collection", onDelete: .cascade)
            }

            try db.create(table: "collectionDocument") { t in
                t.belongsTo("collection", onDelete: .cascade).notNull()
                t.belongsTo("document", onDelete: .cascade).notNull()
                t.primaryKey(["collectionId", "documentId"])
            }

            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
            }

            try db.create(table: "documentTag") { t in
                t.belongsTo("document", onDelete: .cascade).notNull()
                t.belongsTo("tag", onDelete: .cascade).notNull()
                t.primaryKey(["documentId", "tagId"])
            }

            try db.create(table: "annotation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text).notNull().unique()
                t.belongsTo("document", onDelete: .cascade).notNull()
                t.column("pageIndex", .integer).notNull()
                t.column("kind", .text).notNull() // highlight | underline | note
                t.column("colorHex", .text).notNull().defaults(to: "#FFEB3B")
                t.column("quadPoints", .text) // JSON-encoded [[Double]]
                t.column("selectedText", .text)
                t.column("noteText", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
            }

            // Full-text index, manually maintained; rowid mirrors document.id.
            try db.create(virtualTable: "documentFTS", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("abstract")
                t.column("authors")
                t.column("body")
            }
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "collection") { t in
                t.add(column: "icon", .text)
            }
        }

        migrator.registerMigration("v3") { db in
            try db.create(table: "colorLabel") { t in
                t.belongsTo("document", onDelete: .cascade).notNull()
                t.column("colorHex", .text).notNull()
                t.column("label", .text).notNull()
                t.primaryKey(["documentId", "colorHex"])
            }
        }

        migrator.registerMigration("v4") { db in
            // Soft delete: trashed documents keep a timestamp; nil means live.
            try db.alter(table: "document") { t in
                t.add(column: "deletedAt", .datetime)
            }
        }

        migrator.registerMigration("v5") { db in
            // Re-clean abstracts stored by older builds: drop section headings,
            // collapse the whitespace JATS pretty-printing left behind.
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, abstract FROM document WHERE abstract IS NOT NULL")
            for row in rows {
                let id: Int64 = row["id"]
                let abstract: String = row["abstract"]
                let cleaned = TextDecoding.cleanAbstract(abstract)
                guard cleaned != abstract else { continue }
                try db.execute(
                    sql: "UPDATE document SET abstract = ? WHERE id = ?",
                    arguments: [cleaned, id])
                try db.execute(
                    sql: "UPDATE documentFTS SET abstract = ? WHERE rowid = ?",
                    arguments: [cleaned, id])
            }
        }

        migrator.registerMigration("v6") { db in
            // Re-clean titles for LaTeX/whitespace leftovers (e.g. "\," → space).
            let rows = try Row.fetchAll(db, sql: "SELECT id, title FROM document")
            for row in rows {
                let id: Int64 = row["id"]
                let title: String = row["title"]
                let cleaned = TextDecoding.clean(title)
                guard cleaned != title else { continue }
                try db.execute(
                    sql: "UPDATE document SET title = ? WHERE id = ?",
                    arguments: [cleaned, id])
                try db.execute(
                    sql: "UPDATE documentFTS SET title = ? WHERE rowid = ?",
                    arguments: [cleaned, id])
            }
        }

        migrator.registerMigration("v7") { db in
            // Track reader opens (for "Recently Opened") and the single
            // "Currently Reading" document.
            try db.alter(table: "document") { t in
                t.add(column: "openedAt", .datetime)
                t.add(column: "isReading", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v8") { db in
            // AI-generated summary, kept separate from the original abstract.
            try db.alter(table: "document") { t in
                t.add(column: "summary", .text)
            }
        }

        migrator.registerMigration("v9") { db in
            // Further AI-generated insights, alongside the summary.
            try db.alter(table: "document") { t in
                t.add(column: "keyPoints", .text)
                t.add(column: "methods", .text)
                t.add(column: "limitations", .text)
            }
        }

        return migrator
    }
}
