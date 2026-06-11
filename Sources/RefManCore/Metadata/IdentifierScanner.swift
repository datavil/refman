import Foundation

/// Finds DOIs and arXiv identifiers in free text (typically a PDF's first pages).
public enum IdentifierScanner {
    // Crossref's recommended modern-DOI pattern, slightly tightened for prose.
    private static let doiRegex = try! NSRegularExpression(
        pattern: #"\b10\.\d{4,9}/[-._;()/:a-zA-Z0-9]+"#)

    // New-style arXiv IDs (2007+): 4 digits, dot, 4-5 digits, optional version.
    private static let arxivRegex = try! NSRegularExpression(
        pattern: #"arXiv:\s*(\d{4}\.\d{4,5})(v\d+)?"#, options: [.caseInsensitive])

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
}
