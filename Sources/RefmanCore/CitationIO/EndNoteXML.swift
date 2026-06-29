import Foundation

/// EndNote XML export — the most broadly importable bibliographic XML
/// (Zotero, Mendeley, and EndNote all read it).
public enum EndNoteXML {
    public static func export(_ items: [DocumentDetails]) -> String {
        let records = items.map(record).joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <xml>
            <records>
            \(records)
            </records>
            </xml>
            """ + "\n"
    }

    /// EndNote ref-type name and its numeric code for a document type.
    private static func refType(_ type: DocumentType) -> (name: String, code: Int) {
        switch type {
        case .article: return ("Journal Article", 17)
        case .book: return ("Book", 6)
        case .chapter: return ("Book Section", 5)
        case .conferencePaper: return ("Conference Paper", 47)
        case .thesis: return ("Thesis", 32)
        case .report: return ("Report", 27)
        case .preprint: return ("Manuscript", 36)
        case .webpage: return ("Web Page", 12)
        case .misc: return ("Generic", 13)
        }
    }

    private static func record(_ item: DocumentDetails) -> String {
        let d = item.document
        let type = refType(d.type)

        var lines = ["<record>"]
        lines.append("<ref-type name=\"\(escape(type.name))\">\(type.code)</ref-type>")

        if !item.authors.isEmpty {
            lines.append("<contributors>")
            lines.append("<authors>")
            for a in item.authors {
                let name = a.given.isEmpty ? a.family : "\(a.family), \(a.given)"
                lines.append("<author>\(escape(name))</author>")
            }
            lines.append("</authors>")
            lines.append("</contributors>")
        }

        lines.append("<titles>")
        lines.append("<title>\(escape(d.title))</title>")
        if let venue = d.venue { lines.append("<secondary-title>\(escape(venue))</secondary-title>") }
        lines.append("</titles>")

        if let year = d.year { lines.append("<dates><year>\(year)</year></dates>") }
        if let v = d.volume { lines.append("<volume>\(escape(v))</volume>") }
        if let n = d.issue { lines.append("<number>\(escape(n))</number>") }
        if let pages = d.pages { lines.append("<pages>\(escape(pages))</pages>") }
        if let abstract = d.abstract { lines.append("<abstract>\(escape(abstract))</abstract>") }
        if let doi = d.doi {
            lines.append("<electronic-resource-num>\(escape(doi))</electronic-resource-num>")
        }
        if let url = d.url {
            lines.append("<urls><related-urls><url>\(escape(url))</url></related-urls></urls>")
        }

        lines.append("</record>")
        return lines.joined(separator: "\n")
    }

    private static func escape(_ s: String) -> String {
        s.replacing("&", with: "&amp;")
            .replacing("<", with: "&lt;")
            .replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;")
            .replacing("'", with: "&apos;")
    }
}
