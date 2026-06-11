import Foundation

/// Resolves arXiv IDs via the arXiv Atom API.
/// https://info.arxiv.org/help/api/user-manual.html
public struct ArXivClient: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func resolve(arxivId: String) async throws -> MetadataRecord? {
        let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(arxivId)")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return Self.parse(atom: data, arxivId: arxivId)
    }

    static func parse(atom data: Data, arxivId: String) -> MetadataRecord? {
        let parser = AtomEntryParser()
        guard let entry = parser.parse(data) else { return nil }
        // The API returns an empty entry (no id/title) for unknown IDs.
        guard !entry.title.isEmpty, entry.title != "Error" else { return nil }

        let year = entry.published.flatMap { Int($0.prefix(4)) }
        let authors = entry.authors.map { full -> (given: String, family: String) in
            // arXiv gives "Given Family" — split on last space.
            if let idx = full.lastIndex(of: " ") {
                return (String(full[..<idx]), String(full[full.index(after: idx)...]))
            }
            return ("", full)
        }
        return MetadataRecord(
            type: .preprint,
            title: entry.title,
            abstract: entry.summary,
            authors: authors,
            year: year,
            venue: "arXiv",
            doi: entry.doi,
            arxivId: arxivId,
            url: "https://arxiv.org/abs/\(arxivId)"
        )
    }
}

/// Minimal XMLParser-based reader for a single Atom <entry>.
private final class AtomEntryParser: NSObject, XMLParserDelegate {
    struct Entry {
        var title = ""
        var summary: String?
        var published: String?
        var doi: String?
        var authors: [String] = []
    }

    private var entry: Entry?
    private var path: [String] = []
    private var text = ""

    func parse(_ data: Data) -> Entry? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        return entry
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        path.append(name)
        text = ""
        if name == "entry" { entry = Entry() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        defer { path.removeLast() }
        guard entry != nil, path.contains("entry") else { return }
        let value = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        switch name {
        case "title": entry?.title = value
        case "summary": entry?.summary = value
        case "published": entry?.published = value
        case "arxiv:doi": entry?.doi = value
        case "name" where path.dropLast().last == "author":
            entry?.authors.append(value)
        default: break
        }
    }
}
