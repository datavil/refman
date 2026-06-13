import Foundation

/// Resolves DOIs against the CrossRef REST API.
/// https://api.crossref.org/swagger-ui/index.html
public struct CrossRefClient: Sendable {
    let session: URLSession
    /// Polite-pool contact, appended as ?mailto= per CrossRef etiquette.
    let mailto: String?

    public init(session: URLSession = .shared, mailto: String? = nil) {
        self.session = session
        self.mailto = mailto
    }

    public func resolve(doi: String) async throws -> MetadataRecord? {
        var components = URLComponents(string: "https://api.crossref.org/works/")!
        components.path += doi
        if let mailto {
            components.queryItems = [URLQueryItem(name: "mailto", value: mailto)]
        }
        var request = URLRequest(url: components.url!)
        request.setValue("RefMan/0.1 (mailto:\(mailto ?? "unknown"))", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return Self.record(from: envelope.message)
    }

    static func record(from work: Work) -> MetadataRecord {
        let title = work.title?.first ?? ""
        let authors = (work.author ?? []).map { (given: $0.given ?? "", family: $0.family ?? "") }
        let year = work.issued?.dateParts?.first?.first ?? work.published?.dateParts?.first?.first

        let type: DocumentType
        switch work.type {
        case "journal-article": type = .article
        case "proceedings-article": type = .conferencePaper
        case "book": type = .book
        case "book-chapter": type = .chapter
        case "report": type = .report
        case "posted-content": type = .preprint
        case "dissertation": type = .thesis
        default: type = .misc
        }

        return MetadataRecord(
            type: type,
            title: title,
            abstract: work.abstract.map(Self.stripJATS),
            authors: authors,
            year: year,
            venue: work.containerTitle?.first ?? work.institution?.first?.name,
            volume: work.volume,
            issue: work.issue,
            pages: work.page,
            doi: work.DOI,
            url: work.URL
        )
    }

    /// CrossRef abstracts arrive as JATS XML; strip the tags.
    static func stripJATS(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Wire format

    struct Envelope: Decodable {
        let message: Work
    }

    struct Work: Decodable {
        let DOI: String?
        let type: String?
        let title: [String]?
        let abstract: String?
        let author: [WorkAuthor]?
        let containerTitle: [String]?
        let institution: [Institution]?
        let volume: String?
        let issue: String?
        let page: String?
        let issued: DateParts?
        let published: DateParts?
        let URL: String?

        enum CodingKeys: String, CodingKey {
            case DOI, type, title, abstract, author, institution, volume, issue, page, issued,
                published, URL
            case containerTitle = "container-title"
        }
    }

    struct Institution: Decodable {
        let name: String?
    }

    struct WorkAuthor: Decodable {
        let given: String?
        let family: String?
    }

    struct DateParts: Decodable {
        let dateParts: [[Int]]?

        enum CodingKeys: String, CodingKey {
            case dateParts = "date-parts"
        }
    }
}
