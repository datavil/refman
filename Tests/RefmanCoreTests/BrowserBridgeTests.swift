import Foundation
import Testing

@testable import RefmanCore

@Suite struct BrowserBridgeTests {
    @Test func browserMetadataRoundTripsThroughJSON() throws {
        let metadata = BrowserPageMetadata(
            title: "A Browser Paper",
            authors: [BrowserBridgeAuthor(given: "Ada", family: "Lovelace")],
            abstract: "An abstract.",
            year: 2026,
            venue: "Journal of Browsers",
            doi: "10.1000/browser",
            url: "https://example.org/paper")

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(BrowserPageMetadata.self, from: data)
        #expect(decoded == metadata)
    }

    @Test func repositoryFindsBrowserDocumentByUUID() throws {
        let repository = try LibraryRepository(AppDatabase.inMemory())
        let inserted = try repository.insert(Document(title: "Saved from Chrome"))

        let fetched = try #require(try repository.document(uuid: inserted.document.uuid))
        #expect(fetched.id == inserted.id)
        #expect(fetched.document.title == "Saved from Chrome")
    }
}
