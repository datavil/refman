import Foundation
import Testing

@testable import RefmanCore

@Suite struct PDFTextExtractorTests {
    @Test func extractsAbstractUntilIntroduction() {
        let text = """
            A Paper Title
            Jane Researcher

            Abstract
            Background
            Existing extraction misses some layouts.
            Results
            This parser handles them.

            1. Introduction
            This must not become part of the abstract.
            """

        #expect(
            PDFTextExtractor.abstract(in: text)
                == "Existing extraction misses some layouts. This parser handles them.")
    }

    @Test func extractsInlineAndLetterSpacedHeadings() {
        #expect(
            PDFTextExtractor.abstract(
                in: "Abstract | We present a robust parser.\nKeywords: parsing, metadata")
                == "We present a robust parser.")
        #expect(
            PDFTextExtractor.abstract(in: "Abstract—We handle dash separators.\n1 Introduction")
                == "We handle dash separators.")
        #expect(
            PDFTextExtractor.abstract(
                in: "A B S T R A C T  We support letter-spaced headings.\nI. INTRODUCTION")
                == "We support letter-spaced headings.")
        #expect(
            PDFTextExtractor.abstract(in: "Summary\nWe also support summary headings.\nMain")
                == "We also support summary headings.")
    }

    @Test func ignoresTitleBeginningWithAbstract() {
        #expect(PDFTextExtractor.abstract(in: "Abstract Algebra for Beginners\nChapter One") == nil)
    }
}

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

    @Test func findsPMID() {
        #expect(IdentifierScanner.firstPMID(in: "PMID: 34265844") == "34265844")
        #expect(
            IdentifierScanner.firstPMID(in: "https://pubmed.ncbi.nlm.nih.gov/34265844/")
                == "34265844")
        #expect(IdentifierScanner.firstPMID(in: "34265844") == "34265844")
        #expect(IdentifierScanner.firstPMID(in: "not a pmid") == nil)
    }

    @Test func classifyPicksMostSpecific() {
        #expect(IdentifierScanner.classify("10.1038/s41586-021-03819-2") == .doi("10.1038/s41586-021-03819-2"))
        #expect(IdentifierScanner.classify("arXiv:1706.03762") == .arxiv("1706.03762"))
        #expect(IdentifierScanner.classify("https://pubmed.ncbi.nlm.nih.gov/34265844/") == .pubmed("34265844"))
        #expect(IdentifierScanner.classify("34265844") == .pubmed("34265844"))
        #expect(IdentifierScanner.classify("  ") == nil)
        #expect(IdentifierScanner.classify("hello world") == nil)
    }
}

@Suite struct PubMedTests {
    @Test func decodesSummaryIntoRecord() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/pubmed", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let record = try #require(PubMedClient.record(from: data, pmid: "34265844"))

        #expect(record.title == "Highly accurate protein structure prediction with AlphaFold.")
        #expect(record.type == .article)
        #expect(record.venue == "Nature")
        #expect(record.year == 2021)
        #expect(record.volume == "596")
        #expect(record.issue == "7873")
        #expect(record.pages == "583-589")
        #expect(record.doi == "10.1038/s41586-021-03819-2")
        #expect(record.authors.map(\.family) == ["Jumper", "Evans", "Pritzel"])
        #expect(record.authors.first?.given == "J")
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

    @Test func stripsMarkupAndWhitespaceFromTitle() {
        let raw = "Architects of immunity: How dendritic cells shape CD8\n  <sup>+</sup>\n  T cell fate"
        let cleaned = CrossRefClient.stripJATS(raw)
        // The superscript attaches to its base token, keeping the trailing space.
        #expect(cleaned == "Architects of immunity: How dendritic cells shape CD8+ T cell fate")
    }

    @Test func dropsAbstractHeadingWithoutGluing() {
        let raw = "<jats:title>Abstract</jats:title><jats:p>Single-cell omics revolutionized profiling.</jats:p>"
        #expect(CrossRefClient.stripJATS(raw) == "Single-cell omics revolutionized profiling.")
    }

    @Test func dropsStructuredSectionHeadings() {
        let raw = """
            <jats:sec><jats:title>Background</jats:title><jats:p>10x kits are common.</jats:p></jats:sec>\
            <jats:sec><jats:title>Results</jats:title><jats:p>Parse scaled better.</jats:p></jats:sec>
            """
        #expect(CrossRefClient.stripJATS(raw) == "10x kits are common. Parse scaled better.")
    }

    @Test func keepsInlineMarkupTight() {
        // Inline tags are removed without injecting a space, so digits/words stay joined.
        #expect(CrossRefClient.stripJATS("up to 10<jats:sup>6</jats:sup> cells") == "up to 106 cells")
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

@Suite struct PDFFetcherTests {
    @Test func decodesUnpaywallPDFLocations() throws {
        let json = """
            {"is_oa": true, "oa_locations": [
              {"host_type": "publisher", "url_for_pdf": null},
              {"host_type": "repository", "url_for_pdf": "https://example.org/paper.pdf"}
            ]}
            """
        let result = try JSONDecoder().decode(
            PDFFetcher.Unpaywall.self, from: Data(json.utf8))
        #expect(result.oaLocations.compactMap(\.urlForPdf) == ["https://example.org/paper.pdf"])
    }

    @Test func toleratesMissingLocations() throws {
        let result = try JSONDecoder().decode(
            PDFFetcher.Unpaywall.self, from: Data(#"{"is_oa": false}"#.utf8))
        #expect(result.oaLocations.isEmpty)
    }
}

extension MetadataRecord {
    fileprivate func summary(prefix: String) -> Bool {
        abstract?.hasPrefix(prefix) == true
    }
}
