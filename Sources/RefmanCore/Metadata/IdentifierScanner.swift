import Foundation

/// Finds DOIs, arXiv, and PubMed identifiers in free text (typically a PDF's
/// first pages) or in a pasted link/identifier.
public enum IdentifierScanner {
    /// A recognized identifier, tagged by source.
    public enum Identifier: Equatable, Sendable {
        case doi(String)
        case arxiv(String)
        case pubmed(String)
    }

    // Crossref's recommended modern-DOI pattern, slightly tightened for prose.
    private static let doiRegex = try! NSRegularExpression(
        pattern: #"\b10\.\d{4,9}/[-._;()/:a-zA-Z0-9]+"#)

    // New-style arXiv IDs (2007+): 4 digits, dot, 4-5 digits, optional version.
    private static let arxivRegex = try! NSRegularExpression(
        pattern: #"arXiv:\s*(\d{4}\.\d{4,5})(v\d+)?"#, options: [.caseInsensitive])

    // PubMed ID inside a URL or after a "PMID:" prefix.
    private static let pmidRegex = try! NSRegularExpression(
        pattern: #"(?:pubmed\.ncbi\.nlm\.nih\.gov/|/pubmed/|pmid:?\s*)(\d{1,8})"#,
        options: [.caseInsensitive])

    /// Classifies a pasted string into a single identifier, most specific first.
    public static func classify(_ raw: String) -> Identifier? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let doi = firstDOI(in: text) { return .doi(doi) }
        if let arxiv = firstArxivID(in: text) { return .arxiv(arxiv) }
        if let pmid = firstPMID(in: text) { return .pubmed(pmid) }
        return nil
    }

    public static func firstDOI(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = doiRegex.firstMatch(in: text, range: range),
            let r = Range(match.range, in: text)
        else { return nil }
        var doi = String(text[r])
        // Strip trailing punctuation that the greedy suffix class can swallow.
        while let last = doi.last, ".,;)".contains(last) {
            doi.removeLast()
        }
        return doi
    }

    public static func firstArxivID(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = arxivRegex.firstMatch(in: text, range: range),
            let r = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    public static func firstPMID(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        if let match = pmidRegex.firstMatch(in: text, range: range),
            let r = Range(match.range(at: 1), in: text)
        {
            return String(text[r])
        }
        // A bare numeric PMID (PubMed IDs are up to 8 digits).
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (1...8).contains(trimmed.count), trimmed.allSatisfy(\.isNumber) {
            return trimmed
        }
        return nil
    }
}
