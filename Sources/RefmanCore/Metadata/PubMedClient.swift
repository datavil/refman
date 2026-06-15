import Foundation

/// Resolves PubMed IDs via the NCBI E-utilities esummary endpoint (JSON).
/// https://www.ncbi.nlm.nih.gov/books/NBK25500/
public struct PubMedClient: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func resolve(pmid: String) async throws -> MetadataRecord? {
        var components = URLComponents(
            string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi")!
        components.queryItems = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "id", value: pmid),
            URLQueryItem(name: "retmode", value: "json"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Refman/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return Self.record(from: data, pmid: pmid)
    }

    /// esummary nests the record under `result.<pmid>`; parsed loosely since the
    /// key is dynamic and many fields are optional or empty.
    static func record(from data: Data, pmid: String) -> MetadataRecord? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? [String: Any],
            let entry = result[pmid] as? [String: Any],
            let title = entry["title"] as? String, !title.isEmpty
        else { return nil }

        func nonEmpty(_ key: String) -> String? {
            (entry[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        let authors = (entry["authors"] as? [[String: Any]] ?? []).compactMap {
            author -> (given: String, family: String)? in
            guard let name = author["name"] as? String, !name.isEmpty else { return nil }
            // PubMed gives "Family Initials" — e.g. "Smith JD".
            if let idx = name.lastIndex(of: " ") {
                return (String(name[name.index(after: idx)...]), String(name[..<idx]))
            }
            return ("", name)
        }

        let year = (entry["pubdate"] as? String).flatMap { Int($0.prefix(4)) }
        let articleIds = entry["articleids"] as? [[String: Any]] ?? []
        let doi = articleIds.first { ($0["idtype"] as? String) == "doi" }?["value"] as? String

        return MetadataRecord(
            type: .article,
            title: title,
            authors: authors,
            year: year,
            venue: nonEmpty("fulljournalname") ?? nonEmpty("source"),
            volume: nonEmpty("volume"),
            issue: nonEmpty("issue"),
            pages: nonEmpty("pages"),
            doi: doi,
            url: doi.map { "https://doi.org/\($0)" }
                ?? "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/"
        )
    }
}
