import Foundation
import Testing

@testable import RefManCore

@Suite struct LibraryStoreTests {
    func makeStore() throws -> LibraryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefManTests-\(UUID().uuidString)")
        return try LibraryStore(rootURL: dir)
    }

    @Test func ingestIsContentAddressedAndIdempotent() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let src = store.rootURL.appendingPathComponent("src.pdf")
        let data = Data("fake pdf bytes".utf8)
        try data.write(to: src)

        let hash1 = try store.ingest(fileAt: src)
        let hash2 = try store.ingest(fileAt: src)
        #expect(hash1 == hash2)
        #expect(hash1 == LibraryStore.sha256(of: data))
        #expect(store.exists(hash: hash1))
        #expect(try Data(contentsOf: store.url(forHash: hash1)) == data)

        try store.remove(hash: hash1)
        #expect(!store.exists(hash: hash1))
    }
}
