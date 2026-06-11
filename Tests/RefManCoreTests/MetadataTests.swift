import Foundation
import Testing

@testable import RefManCore

@Suite struct IdentifierScannerTests {
    @Test func findsDOIInProse() {
        let text = "This article (doi: 10.1038/s41586-021-03819-2). More text follows."
        #expect(IdentifierScanner.firstDOI(in: text) == "10.1038/s41586-021-03819-2")
    }

    @Test func stripsTrailingPunctuation() {
        #expect(IdentifierScanner.firstDOI(in: "see https://doi.org/10.1000/abc123.") == "10.1000/abc123")
    }

    @Test func noDOIReturnsNil() {
        #expect(IdentifierScanner.firstDOI(in: "no identifiers here, just 3.14") == nil)
    }

    @Test func findsArxivID() {
        #expect(IdentifierScanner.firstArxivID(in: "arXiv:1706.03762v7 [cs.CL]") == "1706.03762")
        #expect(IdentifierScanner.firstArxivID(in: "arxiv: 2304.12345") == "2304.12345")
        #expect(IdentifierScanner.firstArxivID(in: "no preprint") == nil)
    }
}

@Suite struct CrossRefTests {
    @Test func decodesWorkIntoRecord() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/crossref", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(CrossRefClient.Envelope.self, from: data)
        let record = CrossRefClient.record(from: envelope.message)

        #expect(record.title == "Highly accurate protein structure prediction with AlphaFold")
        #expect(record.type == .article)
        #expect(record.venue == "Nature")
        #expect(record.year == 2021)
        #expect(record.volume == "596")
        #expect(record.pages == "583-589")
        #expect(record.doi == "10.1038/s41586-021-03819-2")
        #expect(record.authors.count == 3)
        #expect(record.authors.first?.family == "Jumper")
        // JATS tags stripped from abstract.
        #expect(record.abstract?.hasPrefix("Proteins are essential") == true)
        #expect(record.abstract?.contains("<") == false)
    }
}

@Suite struct ArXivTests {
    @Test func parsesAtomEntry() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/arxiv", withExtension: "xml"))
        let data = try Data(contentsOf: url)
        let record = try #require(ArXivClient.parse(atom: data, arxivId: "1706.03762"))

        #expect(record.title == "Attention Is All You Need")
        #expect(record.type == .preprint)
        #expect(record.year == 2017)
        #expect(record.arxivId == "1706.03762")
        #expect(record.doi == "10.48550/arXiv.1706.03762")
        #expect(record.authors.map(\.family) == ["Vaswani", "Shazeer", "Parmar"])
        #expect(record.authors.first?.given == "Ashish")
        #expect(record.summary(prefix: "The dominant sequence"))
    }
}

extension MetadataRecord {
    fileprivate func summary(prefix: String) -> Bool {
        abstract?.hasPrefix(prefix) == true
    }
}
