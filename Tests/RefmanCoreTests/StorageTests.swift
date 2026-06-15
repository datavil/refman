import Foundation
import Testing

@testable import RefmanCore

@Suite struct LibraryStoreTests {
    func makeStore() throws -> LibraryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefmanTests-\(UUID().uuidString)")
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

    @Test func reportsStoredHashesAndSize() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let a = try store.ingest(data: Data("alpha".utf8))
        let b = try store.ingest(data: Data("beta longer bytes".utf8))
        #expect(try store.allStoredHashes() == Set([a, b]))
        #expect(try store.totalSize() == Int64("alpha".utf8.count + "beta longer bytes".utf8.count))
    }
}

@Suite struct LibraryLocationTests {
    @Test func relocateMovesDatabaseAndStorage() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("RelocTest-\(UUID().uuidString)")
        let from = base.appendingPathComponent("from")
        let to = base.appendingPathComponent("to")
        defer { try? fm.removeItem(at: base) }

        // Seed a library: database file + a PDF in Storage/.
        let store = try LibraryStore(rootURL: LibraryLocation.storeURL(root: from))
        let hash = try store.ingest(data: Data("pdf".utf8))
        try Data("db".utf8).write(to: LibraryLocation.databaseURL(root: from))

        try LibraryLocation.relocate(from: from, to: to)

        // Source is emptied; destination has both pieces.
        #expect(!fm.fileExists(atPath: LibraryLocation.databaseURL(root: from).path))
        #expect(!fm.fileExists(atPath: LibraryLocation.storeURL(root: from).path))
        #expect(fm.fileExists(atPath: LibraryLocation.databaseURL(root: to).path))
        let moved = try LibraryStore(rootURL: LibraryLocation.storeURL(root: to))
        #expect(moved.exists(hash: hash))
    }

    @Test func setHiddenTogglesFinderFlag() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("HiddenTest-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try LibraryLocation.setHidden(true, at: dir)
        var values = try dir.resourceValues(forKeys: [.isHiddenKey])
        #expect(values.isHidden == true)

        try LibraryLocation.setHidden(false, at: dir)
        values = try dir.resourceValues(forKeys: [.isHiddenKey])
        #expect(values.isHidden == false)
    }

    @Test func normalizeCasingRenamesFolder() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("CaseTest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: parent) }

        let old = parent.appendingPathComponent("Refman")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: old.appendingPathComponent("keep.txt"))

        let desired = parent.appendingPathComponent("Refman")
        LibraryLocation.normalizeCasing(of: desired)

        let names = try fm.contentsOfDirectory(atPath: parent.path)
        #expect(names == ["Refman"])
        #expect(fm.fileExists(atPath: desired.appendingPathComponent("keep.txt").path))
    }

    @Test func iCloudDetection() {
        #expect(LibraryLocation.isICloud(
            URL(fileURLWithPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Refman")))
        #expect(!LibraryLocation.isICloud(
            URL(fileURLWithPath: "/Users/x/Library/Application Support/Refman")))
    }
}
