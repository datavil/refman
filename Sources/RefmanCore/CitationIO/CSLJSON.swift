import Foundation

/// CSL-JSON export — the input format for citeproc processors.
/// https://github.com/citation-style-language/schema
public enum CSLJSON {
    public static func export(_ items: [DocumentDetails]) throws -> Data {
        let objects = items.map(object)
        return try JSONSerialization.data(
            withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
    }

    static func object(_ item: DocumentDetails) -> [String: Any] {
        let d = item.document
        var obj: [String: Any] = [
            "id": BibTeX.citationKey(for: item),
            "type": cslType(d.type),
            "title": d.title,
        ]
        if !item.authors.isEmpty {
            obj["author"] = item.authors.map { a -> [String: String] in
                var name: [String: String] = ["family": a.family]
                if !a.given.isEmpty { name["given"] = a.given }
                return name
            }
        }
        if let year = d.year {
            obj["issued"] = ["date-parts": [[year]]]
        }
        if let venue = d.venue { obj["container-title"] = venue }
        if let v = d.volume { obj["volume"] = v }
        if let n = d.issue { obj["issue"] = n }
        if let p = d.pages { obj["page"] = p }
        if let doi = d.doi { obj["DOI"] = doi }
        if let url = d.url { obj["URL"] = url }
        if let abstract = d.abstract { obj["abstract"] = abstract }
        return obj
    }

    static func cslType(_ type: DocumentType) -> String {
        switch type {
        case .article: return "article-journal"
        case .book: return "book"
        case .chapter: return "chapter"
        case .conferencePaper: return "paper-conference"
        case .thesis: return "thesis"
        case .report: return "report"
        case .preprint: return "article"
        case .webpage: return "webpage"
        case .misc: return "document"
        }
    }
}
