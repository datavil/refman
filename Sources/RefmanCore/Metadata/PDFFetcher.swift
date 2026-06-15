import Foundation

/// Best-effort download of an openly available PDF for a reference.
/// arXiv preprints come straight from arxiv.org; DOIs go through Unpaywall,
/// which only knows about open-access copies. Paywalled papers return nil.
public struct PDFFetcher: Sendable {
    let session: URLSession
    /// Contact email required by the Unpaywall API. Empty disables DOI lookup.
    let mailto: String

    public init(session: URLSession = .shared, mailto: String = "") {
        self.session = session
        self.mailto = mailto
    }

    public func fetchArxiv(_ arxivId: String) async throws -> Data? {
        guard let url = URL(string: "https://arxiv.org/pdf/\(arxivId).pdf") else { return nil }
        return try await download(url)
    }

    /// Looks up an open-access PDF for a DOI via Unpaywall, trying every
    /// reported location until one yields actual PDF bytes.
    public func fetchOpenAccess(doi: String) async throws -> Data? {
        guard !mailto.isEmpty,
            var components = URLComponents(string: "https://api.unpaywall.org/v2/\(doi)")
        else { return nil }
        components.queryItems = [URLQueryItem(name: "email", value: mailto)]
        guard let url = components.url else { return nil }

        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let result = try JSONDecoder().decode(Unpaywall.self, from: data)

        let pdfURLs = result.oaLocations.compactMap(\.urlForPdf)
        for string in pdfURLs {
            guard let url = URL(string: string) else { continue }
            if let pdf = try? await download(url) { return pdf }
        }
        return nil
    }

    /// Downloads a URL, returning the bytes only if they are actually a PDF
    /// (guards against paywall HTML masquerading as a download).
    private func download(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue("Refman/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let isPDF = http.mimeType == "application/pdf" || data.starts(with: Array("%PDF".utf8))
        return isPDF ? data : nil
    }

    // MARK: - Wire format

    struct Unpaywall: Decodable {
        let oaLocations: [Location]

        enum CodingKeys: String, CodingKey {
            case oaLocations = "oa_locations"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            oaLocations = try container.decodeIfPresent([Location].self, forKey: .oaLocations) ?? []
        }

        struct Location: Decodable {
            let urlForPdf: String?
            enum CodingKeys: String, CodingKey { case urlForPdf = "url_for_pdf" }
        }
    }
}
