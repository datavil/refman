import Foundation
import Testing

@testable import RefmanCore

@Suite struct BibTeXTests {
    let sample = """
        @article{vaswani2017attention,
          title = {Attention Is All You Need},
          author = {Vaswani, Ashish and Shazeer, Noam},
          journal = {Advances in Neural Information Processing Systems},
          year = {2017},
          volume = {30},
          pages = {5998--6008},
          doi = {10.5555/3295222.3295349}
        }

        @inproceedings{devlin2019bert,
          title = "{BERT}: Pre-training of Deep Bidirectional Transformers",
          author = "Devlin, Jacob",
          booktitle = "Proceedings of NAACL-HLT",
          year = 2019
        }
        """

    @Test func parsesMultipleEntries() {
        let entries = BibTeX.parse(sample)
        #expect(entries.count == 2)
        #expect(entries[0].type == "article")
        #expect(entries[0].citationKey == "vaswani2017attention")
        #expect(entries[0].fields["title"] == "Attention Is All You Need")
        #expect(entries[1].type == "inproceedings")
        #expect(entries[1].fields["title"] == "BERT: Pre-training of Deep Bidirectional Transformers")
        #expect(entries[1].fields["year"] == "2019")
    }

    @Test func convertsToDocument() {
        let entries = BibTeX.parse(sample)
        let (doc, authors) = BibTeX.document(from: entries[0])
        #expect(doc.type == .article)
        #expect(doc.title == "Attention Is All You Need")
        #expect(doc.year == 2017)
        #expect(doc.venue == "Advances in Neural Information Processing Systems")
        #expect(doc.pages == "5998–6008")
        #expect(authors.count == 2)
        #expect(authors[0].given == "Ashish")
        #expect(authors[0].family == "Vaswani")
    }

    @Test func parsesGivenFamilyOrder() {
        let author = BibTeX.parseAuthorName("Yoshua Bengio")
        #expect(author.given == "Yoshua")
        #expect(author.family == "Bengio")
    }

    @Test func exportRoundTrips() {
        let details = DocumentDetails(
            document: Document(
                type: .article, title: "A Study of Things", year: 2020,
                venue: "Journal of Stuff", volume: "5", pages: "1–10", doi: "10.1/xyz"),
            authors: [Author(given: "Ada", family: "Lovelace")]
        )
        let exported = BibTeX.export(details)
        let reparsed = BibTeX.parse(exported)
        #expect(reparsed.count == 1)
        let (doc, authors) = BibTeX.document(from: reparsed[0])
        #expect(doc.title == "A Study of Things")
        #expect(doc.year == 2020)
        #expect(doc.pages == "1–10")
        #expect(doc.doi == "10.1/xyz")
        #expect(authors.map(\.family) == ["Lovelace"])
    }

    @Test func citationKeyGeneration() {
        let details = DocumentDetails(
            document: Document(title: "The Quick Brown Fox", year: 2021),
            authors: [Author(given: "Jane", family: "Doe")]
        )
        #expect(BibTeX.citationKey(for: details) == "doe2021quick")
    }
}

@Suite struct RISTests {
    let sample = """
        TY  - JOUR
        TI  - Highly accurate protein structure prediction with AlphaFold
        AU  - Jumper, John
        AU  - Hassabis, Demis
        PY  - 2021
        T2  - Nature
        VL  - 596
        SP  - 583
        EP  - 589
        DO  - 10.1038/s41586-021-03819-2
        ER  -
        TY  - CONF
        TI  - Some Conference Paper
        AU  - Smith, Alice
        PY  - 2019
        ER  -
        """

    @Test func parsesEntries() {
        let entries = RIS.parse(sample)
        #expect(entries.count == 2)
        #expect(entries[0].first("TY") == "JOUR")
        #expect(entries[0].all("AU").count == 2)
        #expect(entries[1].first("TI") == "Some Conference Paper")
    }

    @Test func convertsToDocument() {
        let entries = RIS.parse(sample)
        let (doc, authors) = RIS.document(from: entries[0])
        #expect(doc.type == .article)
        #expect(doc.title == "Highly accurate protein structure prediction with AlphaFold")
        #expect(doc.year == 2021)
        #expect(doc.venue == "Nature")
        #expect(doc.pages == "583–589")
        #expect(doc.doi == "10.1038/s41586-021-03819-2")
        #expect(authors.map(\.family) == ["Jumper", "Hassabis"])
    }

    @Test func exportRoundTrips() {
        let details = DocumentDetails(
            document: Document(
                type: .conferencePaper, title: "Roundtrip", year: 2022, pages: "10–20"),
            authors: [Author(given: "Bob", family: "Builder")]
        )
        let entries = RIS.parse(RIS.export(details))
        #expect(entries.count == 1)
        let (doc, authors) = RIS.document(from: entries[0])
        #expect(doc.type == .conferencePaper)
        #expect(doc.title == "Roundtrip")
        #expect(doc.pages == "10–20")
        #expect(authors.first?.family == "Builder")
    }
}

@Suite struct CSLJSONTests {
    @Test func exportsValidJSON() throws {
        let details = DocumentDetails(
            document: Document(
                type: .article, title: "CSL Test", year: 2023, venue: "J. Tests",
                doi: "10.1/csl"),
            authors: [Author(given: "Carol", family: "Coder")]
        )
        let data = try CSLJSON.export([details])
        let array = try #require(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(array.count == 1)
        let obj = array[0]
        #expect(obj["type"] as? String == "article-journal")
        #expect(obj["title"] as? String == "CSL Test")
        #expect(obj["DOI"] as? String == "10.1/csl")
        let issued = try #require(obj["issued"] as? [String: Any])
        #expect((issued["date-parts"] as? [[Int]])?.first?.first == 2023)
    }
}

@Suite struct TextDecodingTests {
    @Test func decodesHTMLEntities() {
        #expect(TextDecoding.clean("Cell Host &amp; Microbe") == "Cell Host & Microbe")
        #expect(TextDecoding.clean("A &lt;i&gt;gene&lt;/i&gt;") == "A <i>gene</i>")
        #expect(TextDecoding.clean("5 &#956;m &#x3B1;") == "5 μm α")
        #expect(TextDecoding.clean("R&D and AT&T") == "R&D and AT&T")  // not entities
    }

    @Test func decodesLaTeXAccents() {
        #expect(TextDecoding.clean(#"M\"uller"#) == "Müller")
        #expect(TextDecoding.clean(#"{\'e}cole"#) == "école")
        #expect(TextDecoding.clean(#"Erd\H{o}s"#) == "Erdős")
        #expect(TextDecoding.clean(#"Stra\ss e"#) == "Straße")
        #expect(TextDecoding.clean(#"Sl\v{a}vik"#) == "Slǎvik")  // \v = caron
    }

    @Test func decodesLaTeXCommandsAndMath() {
        #expect(TextDecoding.clean(#"TGF-$\beta$ signaling"#) == "TGF-β signaling")
        #expect(TextDecoding.clean(#"\textbf{Bold} title"#) == "Bold title")
        #expect(TextDecoding.clean("{DNA} repair") == "DNA repair")
        #expect(TextDecoding.clean(#"50 \% yield"#) == "50 % yield")
    }

    @Test func leavesUnknownCommandsAlone() {
        // Unknown commands are kept verbatim (braces are still stripped).
        #expect(TextDecoding.clean(#"see \cite{ref}"#) == "see \\citeref")
    }
}
