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

@Suite struct LibraryBundleTests {
    @Test func exportsBibAndCopiesAttachedPDFs() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("BundleTest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let store = try LibraryStore(rootURL: tmp.appendingPathComponent("store"))

        let pdfData = Data("fake pdf".utf8)
        let hash = try store.ingest(data: pdfData)
        // Mirror the real store: its PDFs carry the Finder hidden flag.
        var hiddenValues = URLResourceValues()
        hiddenValues.isHidden = true
        var stored = store.url(forHash: hash)
        try stored.setResourceValues(hiddenValues)
        let withPDF = DocumentDetails(
            document: Document(title: "Attached Paper", year: 2021, fileHash: hash),
            authors: [Author(family: "Doe")])
        let noPDF = DocumentDetails(
            document: Document(title: "Metadata Only", year: 2020),
            authors: [Author(family: "Roe")])

        let bundle = tmp.appendingPathComponent("Export")
        let result = try LibraryBundle.export([withPDF, noPDF], store: store, to: bundle)

        #expect(result.references == 2)
        #expect(result.pdfs == 1)
        #expect(result.notDownloaded == 0)
        #expect(result.copyErrors.isEmpty)
        // PDF sits in the bundle root next to library.bib, not a subfolder.
        let exportedPDF = bundle.appendingPathComponent("doe2021attached.pdf")
        #expect(try Data(contentsOf: exportedPDF) == pdfData)
        #expect(!fm.fileExists(atPath: bundle.appendingPathComponent("files").path))
        // The export must be visible in Finder, not inherit the store's hidden flag.
        #expect(try exportedPDF.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)

        let bib = try String(
            contentsOf: bundle.appendingPathComponent("library.bib"), encoding: .utf8)
        #expect(bib.contains("file = {:doe2021attached.pdf:PDF}"))
        // The metadata-only entry gets no file field.
        #expect(bib.contains("Metadata Only"))
    }

    @Test func endToEndExportFromRepository() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("E2EBundle-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let store = try LibraryStore(rootURL: tmp.appendingPathComponent("store"))
        let repo = try LibraryRepository(AppDatabase.inMemory())

        // Mirror the real flow: a PDF lands in the store, the document records its hash.
        let hash = try store.ingest(data: Data("real pdf bytes".utf8))
        _ = try repo.insert(
            Document(title: "Indexed Paper", year: 2021, fileHash: hash),
            authors: [Author(family: "Curie")])

        // The export reads documents back through the repository, as the app does.
        let items = try repo.allDocuments()
        #expect(items.first?.document.fileHash == hash)  // survives the round trip

        let bundle = tmp.appendingPathComponent("Export")
        let result = try LibraryBundle.export(items, store: store, to: bundle)
        #expect(result.pdfs == 1)
        #expect(
            fm.fileExists(atPath: bundle.appendingPathComponent("curie2021indexed.pdf").path))
    }

    @Test func bundleWithRISWritesBothFormats() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("BundleTest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let store = try LibraryStore(rootURL: tmp.appendingPathComponent("store"))
        let item = DocumentDetails(
            document: Document(title: "Paper", year: 2021), authors: [Author(family: "Doe")])

        let bundle = tmp.appendingPathComponent("Export")
        _ = try LibraryBundle.export([item], store: store, to: bundle, includeRIS: true)

        #expect(fm.fileExists(atPath: bundle.appendingPathComponent("library.bib").path))
        #expect(fm.fileExists(atPath: bundle.appendingPathComponent("library.ris").path))
        // Default (no RIS) omits the .ris file.
        let plain = tmp.appendingPathComponent("Plain")
        _ = try LibraryBundle.export([item], store: store, to: plain)
        #expect(!fm.fileExists(atPath: plain.appendingPathComponent("library.ris").path))
    }

    @Test func exportReplacesExistingBundle() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("BundleTest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let store = try LibraryStore(rootURL: tmp.appendingPathComponent("store"))
        let bundle = tmp.appendingPathComponent("Export")

        // Pre-existing folder with stale content should be cleared.
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: bundle.appendingPathComponent("stale.txt"))

        let item = DocumentDetails(
            document: Document(title: "Paper", year: 2021), authors: [Author(family: "Doe")])
        _ = try LibraryBundle.export([item], store: store, to: bundle)

        #expect(!fm.fileExists(atPath: bundle.appendingPathComponent("stale.txt").path))
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
