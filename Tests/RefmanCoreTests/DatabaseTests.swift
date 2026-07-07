import Foundation
import Testing

@testable import RefmanCore

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

    @Test func deleteTrashesThenPurgeCascades() throws {
        let repo = try makeRepo()
        let details = try repo.insert(Document(title: "Doomed"), fullText: "doomed body")
        let id = details.id
        try repo.insert(Annotation(documentId: id, pageIndex: 0, kind: .highlight))

        // Soft delete moves it to the Trash: hidden from listings/search, recoverable.
        try repo.delete(documentId: id)
        #expect(try repo.allDocuments().isEmpty)
        #expect(try repo.search("doomed").isEmpty)
        #expect(try repo.trashedDocuments().map(\.id) == [id])

        // Restore brings it back into the library.
        try repo.restore(documentId: id)
        #expect(try repo.allDocuments().map(\.id) == [id])

        // Emptying the Trash purges it and cascades annotations + FTS.
        try repo.delete(documentId: id)
        _ = try repo.emptyTrash()
        #expect(try repo.document(id: id) == nil)
        #expect(try repo.annotations(documentId: id).isEmpty)
        #expect(try repo.search("doomed").isEmpty)
    }

    @Test func countsAndReferencedHashesTrackTrash() throws {
        let repo = try makeRepo()
        let a = try repo.insert(Document(title: "A", fileHash: "hashA"))
        _ = try repo.insert(Document(title: "B", fileHash: "hashB"))
        _ = try repo.insert(Document(title: "C"))  // no PDF

        var counts = try repo.counts()
        #expect(counts.live == 3)
        #expect(counts.withPDF == 2)
        #expect(counts.trashed == 0)
        #expect(try repo.referencedFileHashes() == Set(["hashA", "hashB"]))

        try repo.delete(documentId: a.id)
        counts = try repo.counts()
        #expect(counts.live == 2)
        #expect(counts.trashed == 1)
        // Trashed documents still reference their file until the Trash is emptied.
        #expect(try repo.referencedFileHashes() == Set(["hashA", "hashB"]))

        let freed = try repo.emptyTrash()
        #expect(freed == ["hashA"])
        #expect(try repo.referencedFileHashes() == Set(["hashB"]))
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

    @Test func searchRespectsEveryLibraryScope() throws {
        let repo = try makeRepo()
        let oldDate = Date(timeIntervalSince1970: 0)
        let recentCutoff = Date().addingTimeInterval(-3600)

        let collectionMatch = try repo.insert(Document(title: "Scopeword collection"))
        let otherMatch = try repo.insert(
            Document(title: "Scopeword other", addedAt: oldDate, modifiedAt: oldDate))
        let trashMatch = try repo.insert(Document(title: "Scopeword trash"))
        _ = try repo.insert(Document(title: "Different paper"))

        let collection = try repo.createCollection(name: "Scoped")
        try repo.add(documentId: collectionMatch.id, toCollection: collection.id!)
        let tag = try repo.addTag("scoped", toDocument: collectionMatch.id)
        try repo.markOpened(documentId: otherMatch.id)
        try repo.setReading(documentId: otherMatch.id)
        try repo.delete(documentId: trashMatch.id)

        func titles(in scope: LibrarySearchScope) throws -> Set<String> {
            Set(try repo.search("scopeword", scope: scope).map(\.document.title))
        }

        #expect(try titles(in: .all) == ["Scopeword collection", "Scopeword other"])
        #expect(try titles(in: .recent(since: recentCutoff)) == ["Scopeword collection"])
        #expect(try titles(in: .recentlyOpened(since: recentCutoff)) == ["Scopeword other"])
        #expect(try titles(in: .reading) == ["Scopeword other"])
        #expect(try titles(in: .uncategorized) == ["Scopeword other"])
        #expect(try titles(in: .trash) == ["Scopeword trash"])
        #expect(try titles(in: .collection(collection.id!)) == ["Scopeword collection"])
        #expect(try titles(in: .tag(tag.id!)) == ["Scopeword collection"])

        let duplicateA = try repo.insert(
            Document(title: "Scopeword duplicate", doi: "10.1000/duplicate"))
        let duplicateB = try repo.insert(
            Document(title: "Matching duplicate", doi: "10.1000/duplicate"))
        _ = try repo.insert(Document(title: "Scopeword unique", doi: "10.1000/unique"))

        #expect(
            try Set(repo.search("scopeword", scope: .duplicates).map(\.id))
                == [duplicateA.id, duplicateB.id])
    }

    @Test func collectionsScopeDocuments() throws {
        let repo = try makeRepo()
        let docA = try repo.insert(Document(title: "A"))
        _ = try repo.insert(Document(title: "B"))
        let collection = try repo.createCollection(name: "ML")
        try repo.add(documentId: docA.id, toCollection: collection.id!)

        #expect(try repo.allDocuments().count == 2)
        #expect(try repo.documentCount(in: collection.id!) == 1)
        let scoped = try repo.allDocuments(in: collection.id!)
        #expect(scoped.map(\.document.title) == ["A"])

        try repo.remove(documentId: docA.id, fromCollection: collection.id!)
        #expect(try repo.allDocuments(in: collection.id!).isEmpty)
        #expect(try repo.documentCount(in: collection.id!) == 0)
    }

    @Test func collectionsReorder() throws {
        let repo = try makeRepo()
        let a = try repo.createCollection(name: "Alpha")
        let b = try repo.createCollection(name: "Beta")
        let c = try repo.createCollection(name: "Gamma")
        // New collections append in creation order.
        #expect(try repo.allCollections().map(\.name) == ["Alpha", "Beta", "Gamma"])

        try repo.reorderCollections([c.id!, a.id!, b.id!])
        #expect(try repo.allCollections().map(\.name) == ["Gamma", "Alpha", "Beta"])
    }

    @Test func subcollectionsOrderIndependently() throws {
        let repo = try makeRepo()
        let parent = try repo.createCollection(name: "Parent")
        let x = try repo.createCollection(name: "X", parentId: parent.id)
        let y = try repo.createCollection(name: "Y", parentId: parent.id)
        try repo.reorderCollections([y.id!, x.id!])
        let kids = try repo.allCollections().filter { $0.parentId == parent.id }
        #expect(kids.map(\.name) == ["Y", "X"])
    }

    @Test func collectionNotesPersistUpdateAndCascade() throws {
        let repo = try makeRepo()
        let collection = try repo.createCollection(name: "Notes")

        var first = try repo.createCollectionNote(
            collectionId: collection.id!, title: "Reading Plan", body: "# Start")
        let second = try repo.createCollectionNote(
            collectionId: collection.id!, title: "Questions", body: "- Why?")
        #expect(try repo.collectionNotes(in: collection.id!).count == 2)
        #expect(try repo.collectionNotes(in: collection.id!).map(\.id) == [first.id, second.id])

        first.body = "# Start\n- Follow up"
        try repo.updateCollectionNote(first)
        #expect(try repo.collectionNotes(in: collection.id!).contains { $0.body.contains("Follow up") })

        try repo.reorderCollectionNotes([second.id!, first.id!])
        #expect(try repo.collectionNotes(in: collection.id!).map(\.id) == [second.id, first.id])

        try repo.deleteCollection(id: collection.id!)
        #expect(try repo.collectionNotes(in: collection.id!).isEmpty)
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

    @Test func colorLabelsPerDocument() throws {
        let repo = try makeRepo()
        let a = try repo.insert(Document(title: "A"))
        let b = try repo.insert(Document(title: "B"))

        try repo.setColorLabel(documentId: a.id, colorHex: "#AF52DE", label: "key finding")
        #expect(try repo.colorLabels(documentId: a.id) == ["#AF52DE": "key finding"])
        #expect(try repo.colorLabels(documentId: b.id).isEmpty)  // scoped per document

        try repo.setColorLabel(documentId: a.id, colorHex: "#AF52DE", label: "method")
        #expect(try repo.colorLabels(documentId: a.id) == ["#AF52DE": "method"])

        try repo.setColorLabel(documentId: a.id, colorHex: "#AF52DE", label: "")
        #expect(try repo.colorLabels(documentId: a.id).isEmpty)  // empty label removes
    }

    @Test func duplicateDOIsCoexistButLookupIsLiveScoped() throws {
        let repo = try makeRepo()
        // Two rows may share a DOI (dedup happens in code, not the schema).
        let a = try repo.insert(Document(title: "One", doi: "10.1/x"))
        try repo.insert(Document(title: "Two", doi: "10.1/x"))

        // A live lookup finds one of them; trashing it makes the DOI free again.
        #expect(try repo.document(doi: "10.1/x") != nil)
        try repo.delete(documentId: a.id)
        #expect(try repo.document(doi: "10.1/x")?.id != a.id)
    }

    @Test func liveDocumentNeedingPDFTargetsPDFlessLiveRow() throws {
        let repo = try makeRepo()
        let meta = try repo.insert(Document(title: "Meta only", doi: "10.1/x"))
        #expect(try repo.liveDocumentNeedingPDF(doi: "10.1/x", arxivId: nil)?.id == meta.id)

        // Once it has a PDF, it's no longer an attach target.
        var withPDF = meta.document
        withPDF.fileHash = "hash"
        try repo.update(withPDF)
        #expect(try repo.liveDocumentNeedingPDF(doi: "10.1/x", arxivId: nil) == nil)
    }

    @Test func purgeTrashedWithoutPDFRemovesOnlyTrashedMetadataCopies() throws {
        let repo = try makeRepo()
        let trashed = try repo.insert(Document(title: "Trashed", doi: "10.1/x"))
        try repo.delete(documentId: trashed.id)
        let live = try repo.insert(Document(title: "Live", doi: "10.1/x"))

        try repo.purgeTrashedWithoutPDF(doi: "10.1/x", arxivId: nil)
        #expect(try repo.document(id: trashed.id) == nil)
        #expect(try repo.document(id: live.id) != nil)
    }
}
