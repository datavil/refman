import Foundation
import PDFKit
import Testing

@testable import RefmanCore

@Suite struct ImportPipelineTests {
    /// Renders a one-page PDF containing the given text.
    func makePDF(text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("refman-test-\(UUID().uuidString).pdf")

        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        var mediaBox = pageRect
        let consumer = CGDataConsumer(url: url as CFURL)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)

        let attributed = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: pageRect.insetBy(dx: 50, dy: 50), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)

        context.endPDFPage()
        context.closePDF()
        return url
    }

    func makePipeline() throws -> (ImportPipeline, LibraryRepository, LibraryStore) {
        let repo = try LibraryRepository(AppDatabase.inMemory())
        let store = try LibraryStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("refman-store-\(UUID().uuidString)"))
        // Unroutable session so the test never hits the real network.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.5
        config.timeoutIntervalForResource = 0.5
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort: 1,
        ]
        let session = URLSession(configuration: config)
        let pipeline = ImportPipeline(
            repository: repo, store: store,
            crossRef: CrossRefClient(session: session),
            arXiv: ArXivClient(session: session))
        return (pipeline, repo, store)
    }

    @Test func importExtractsIdentifiersAndDeduplicates() async throws {
        let (pipeline, repo, store) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let pdf = try makePDF(
            text: """
                A Great Paper About Things

                Jane Doe, John Smith

                doi: 10.1234/example.5678
                arXiv:2401.12345v2

                Abstract: We study things in depth using novel methodology.
                """)
        defer { try? FileManager.default.removeItem(at: pdf) }

        guard case .imported(let result) = try await pipeline.importPDF(at: pdf) else {
            Issue.record("expected a fresh import")
            return
        }
        #expect(!result.resolvedOnline)  // network unroutable by construction

        let doc = result.details.document
        #expect(doc.doi == "10.1234/example.5678")
        #expect(doc.arxivId == "2401.12345")
        #expect(doc.abstract == "We study things in depth using novel methodology.")
        #expect(doc.fileHash != nil)
        #expect(store.exists(hash: doc.fileHash!))

        // Full text landed in the FTS index.
        #expect(try repo.search("methodology").count == 1)

        // Re-importing the identical file is a no-op duplicate.
        guard case .duplicate(let dup) = try await pipeline.importPDF(at: pdf) else {
            Issue.record("expected a duplicate")
            return
        }
        #expect(dup.id == result.details.id)
        #expect(try repo.allDocuments().count == 1)
    }

    @Test func reimportingTrashedFileReportsConflictAndCanReplace() async throws {
        let (pipeline, repo, store) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let pdf = try makePDF(text: "A Trashed Paper\n\ndoi: 10.9999/trashed.001\n\nbody")
        defer { try? FileManager.default.removeItem(at: pdf) }

        guard case .imported(let result) = try await pipeline.importPDF(at: pdf) else {
            Issue.record("expected a fresh import")
            return
        }
        let originalId = result.details.id
        #expect(result.details.document.doi == "10.9999/trashed.001")
        try repo.delete(documentId: originalId)  // move to Trash

        // A trashed match is reported as a conflict, not a silent duplicate.
        guard case .inTrash(let existing, _) = try await pipeline.importPDF(at: pdf) else {
            Issue.record("expected a trashed conflict")
            return
        }
        #expect(existing.id == originalId)

        // Replace: purge the trashed row (freeing its unique DOI), then re-import.
        // Without the purge this would hit the DOI UNIQUE constraint and throw.
        try repo.purge(documentId: originalId)
        let replaced = try await pipeline.importPDFAsNew(at: pdf)
        #expect(replaced.details.id != originalId)
        #expect(replaced.details.document.doi == "10.9999/trashed.001")
        let counts = try repo.counts()
        #expect(counts.live == 1)
        #expect(counts.trashed == 0)
    }

    @Test func refreshRecoversAbstractFromAttachedPDFWithoutOnlineMetadata() async throws {
        let (pipeline, repo, store) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }

        let pdf = try makePDF(
            text: "Abstract | This abstract was present only in the PDF.\n\nMain\nArticle body.")
        defer { try? FileManager.default.removeItem(at: pdf) }

        let hash = try store.ingest(fileAt: pdf)
        let details = try repo.insert(
            Document(title: "Offline Paper", fileHash: hash, fileName: pdf.lastPathComponent))

        let refreshed = try #require(
            try await pipeline.refreshMetadata(for: details.document))
        #expect(refreshed.document.abstract == "This abstract was present only in the PDF.")
    }
}
