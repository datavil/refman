import Foundation
import Testing

@testable import RefManCore

@Suite struct DatabaseTests {
    func makeRepo() throws -> LibraryRepository {
        try LibraryRepository(AppDatabase.inMemory())
    }

    @Test func insertAndFetchDocument() throws {
        let repo = try makeRepo()
        let details = try repo.insert(
            Document(title: "Attention Is All You Need", year: 2017, venue: "NeurIPS"),
            authors: [Author(given: "Ashish", family: "Vaswani")]
        )
        let id = details.id
        let fetched = try #require(try repo.document(id: id))
        #expect(fetched.document.title == "Attention Is All You Need")
        #expect(fetched.authors.map(\.family) == ["Vaswani"])
    }

    @Test func authorsAreDeduplicated() throws {
        let repo = try makeRepo()
        let a = try repo.insert(
            Document(title: "Paper A"), authors: [Author(given: "Jane", family: "Doe")])
        let b = try repo.insert(
            Document(title: "Paper B"), authors: [Author(given: "Jane", family: "Doe")])
        #expect(a.authors.first?.id == b.authors.first?.id)
    }

    @Test func updatePreservesFullTextAndReplacesAuthors() throws {
        let repo = try makeRepo()
        let details = try repo.insert(
            Document(title: "Old title"),
            authors: [Author(family: "First")],
            fullText: "neural networks are interesting"
        )
        var doc = details.document
        doc.title = "New title"
        let updated = try repo.update(doc, authors: [Author(family: "Second")])
        #expect(updated.authors.map(\.family) == ["Second"])
        // Full text survives the metadata update.
        #expect(try repo.search("neural").first?.document.title == "New title")
    }

    @Test func deleteCascades() throws {
        let repo = try makeRepo()
        let details = try repo.insert(Document(title: "Doomed"), fullText: "doomed body")
        let id = details.id
        try repo.insert(Annotation(documentId: id, pageIndex: 0, kind: .highlight))
        try repo.delete(documentId: id)
        #expect(try repo.document(id: id) == nil)
        #expect(try repo.annotations(documentId: id).isEmpty)
        #expect(try repo.search("doomed").isEmpty)
    }

    @Test func searchMatchesTitleAuthorsAndBody() throws {
        let repo = try makeRepo()
        try repo.insert(
            Document(title: "Protein folding"),
            authors: [Author(given: "Demis", family: "Hassabis")],
            fullText: "alphafold predicts structures"
        )
        try repo.insert(Document(title: "Unrelated"), fullText: "nothing here")
        #expect(try repo.search("protein").count == 1)
        #expect(try repo.search("hassabis").count == 1)
        #expect(try repo.search("alphafold").count == 1)
        #expect(try repo.search("quantum").isEmpty)
        // Prefix matching for type-ahead.
        #expect(try repo.search("prot").count == 1)
    }

    @Test func collectionsScopeDocuments() throws {
        let repo = try makeRepo()
        let docA = try repo.insert(Document(title: "A"))
        _ = try repo.insert(Document(title: "B"))
        let collection = try repo.createCollection(name: "ML")
        try repo.add(documentId: docA.id, toCollection: collection.id!)

        #expect(try repo.allDocuments().count == 2)
        let scoped = try repo.allDocuments(in: collection.id!)
        #expect(scoped.map(\.document.title) == ["A"])

        try repo.remove(documentId: docA.id, fromCollection: collection.id!)
        #expect(try repo.allDocuments(in: collection.id!).isEmpty)
    }

    @Test func tagsRoundTripAndOrphanCleanup() throws {
        let repo = try makeRepo()
        let doc = try repo.insert(Document(title: "Tagged"))
        let tag = try repo.addTag("transformers", toDocument: doc.id)
        // Same name → same tag row.
        let again = try repo.addTag("transformers", toDocument: doc.id)
        #expect(tag.id == again.id)
        #expect(try repo.documents(taggedWith: tag.id!).count == 1)

        try repo.removeTag(tag.id!, fromDocument: doc.id)
        #expect(try repo.allTags().isEmpty)  // orphan removed
    }

    @Test func annotationsPersistAndSort() throws {
        let repo = try makeRepo()
        let doc = try repo.insert(Document(title: "Annotated"))
        try repo.insert(
            Annotation(documentId: doc.id, pageIndex: 3, kind: .note, noteText: "later page"))
        try repo.insert(
            Annotation(
                documentId: doc.id, pageIndex: 0, kind: .highlight,
                selectedText: "important phrase"))
        let annotations = try repo.annotations(documentId: doc.id)
        #expect(annotations.map(\.pageIndex) == [0, 3])
        #expect(annotations[0].selectedText == "important phrase")
    }

    @Test func duplicateDOIRejected() throws {
        let repo = try makeRepo()
        try repo.insert(Document(title: "One", doi: "10.1/x"))
        #expect(throws: Error.self) {
            try repo.insert(Document(title: "Two", doi: "10.1/x"))
        }
    }
}
