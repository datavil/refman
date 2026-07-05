import Testing

@testable import RefmanCore

@Suite struct LibraryToolsTests {
    @Test func toolContractsReadAndMutateTheLibrary() throws {
        let repository = try LibraryRepository(AppDatabase.inMemory())
        let details = try repository.insert(
            Document(title: "Tool contract paper", year: 2026),
            authors: [Author(given: "Ada", family: "Lovelace")],
            fullText: "A distinctive passage for the assistant.")
        try repository.insert(
            Annotation(
                documentId: details.id, pageIndex: 2, kind: .highlight,
                selectedText: "distinctive passage", noteText: "Important"))

        let current = try LibraryTools.handle(
            name: "get_current_document", arguments: [:], repository: repository,
            currentDocumentId: details.id, textLimit: 1_000)
        #expect(current.contains("Tool contract paper"))
        #expect(current.contains("Ada Lovelace"))

        let text = try LibraryTools.handle(
            name: "get_document_text", arguments: [:], repository: repository,
            currentDocumentId: details.id, textLimit: 13)
        #expect(text == "A distinctive")

        let annotations = try LibraryTools.handle(
            name: "get_annotations", arguments: [:], repository: repository,
            currentDocumentId: details.id, textLimit: 1_000)
        #expect(annotations.contains("p.3"))
        #expect(annotations.contains("Important"))

        let result = try LibraryTools.handle(
            name: "add_tag", arguments: ["name": "reviewed"], repository: repository,
            currentDocumentId: details.id, textLimit: 1_000)
        #expect(result.contains("reviewed"))
        #expect(try repository.allTags().map(\.name) == ["reviewed"])
    }

    @Test func toolContractsReturnUsefulFailures() throws {
        let repository = try LibraryRepository(AppDatabase.inMemory())

        let missing = try LibraryTools.handle(
            name: "get_current_document", arguments: [:], repository: repository,
            currentDocumentId: 404, textLimit: 1_000)
        #expect(missing == "No document is open.")

        let missingTag = try LibraryTools.handle(
            name: "add_tag", arguments: [:], repository: repository,
            currentDocumentId: 404, textLimit: 1_000)
        #expect(missingTag == "Missing tag name.")

        let unknown = try LibraryTools.handle(
            name: "not_a_tool", arguments: [:], repository: repository,
            currentDocumentId: 404, textLimit: 1_000)
        #expect(unknown == "Unknown tool: not_a_tool")
    }
}
