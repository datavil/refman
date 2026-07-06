import Foundation
import PDFKit

/// Pulls text and embedded metadata out of a PDF via PDFKit.
public enum PDFTextExtractor {
    public struct Extracted: Sendable {
        public var pageCount: Int
        public var fullText: String
        /// Text of the first few pages — where DOIs and titles live.
        public var headText: String
        /// Title from the PDF's document attributes, if plausible.
        public var embeddedTitle: String?
        /// Abstract found in the opening pages, if the PDF exposes usable text.
        public var abstract: String?
    }

    public static func extract(from url: URL, headPages: Int = 2) -> Extracted? {
        guard let doc = PDFDocument(url: url) else { return nil }

        var full = ""
        var head = ""
        for i in 0..<doc.pageCount {
            guard let text = doc.page(at: i)?.string else { continue }
            full += text + "\n"
            if i < headPages { head += text + "\n" }
        }

        var title: String?
        if let t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            // Producers often stuff filenames or junk in here; require something word-like.
            if trimmed.count > 4, !trimmed.lowercased().hasSuffix(".pdf"),
                !trimmed.lowercased().hasPrefix("untitled"), trimmed.contains(" ")
            {
                title = trimmed
            }
        }

        return Extracted(
            pageCount: doc.pageCount,
            fullText: full,
            headText: head,
            embeddedTitle: title,
            abstract: abstract(in: head)
        )
    }

    /// Extracts the text between an Abstract heading and the next front-matter
    /// or body heading. Line-based parsing matches PDFKit's output and
    /// avoids treating later mentions of "abstract" as section headings.
    static func abstract(in text: String) -> String? {
        var foundHeading = false
        var lines: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if !foundHeading {
                guard let remainder = abstractRemainder(in: line) else { continue }
                foundHeading = true
                if !remainder.isEmpty { lines.append(remainder) }
                continue
            }

            if isAbstractBoundary(line) { break }
            lines.append(line)
        }

        guard foundHeading else { return nil }
        let result = TextDecoding.cleanAbstract(lines.joined(separator: "\n"))
        guard !result.isEmpty, result.count <= 5_000 else { return nil }
        return result
    }

    private static func abstractRemainder(in line: String) -> String? {
        guard let heading = line.range(
            of: #"(?i)^(?:a\s*b\s*s\s*t\s*r\s*a\s*c\s*t|s\s*u\s*m\s*m\s*a\s*r\s*y)(?=$|[\s:.|\-—–])"#,
            options: .regularExpression
        ) else { return nil }

        let remainder = line[heading.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        guard let first = remainder.first else { return "" }

        if ":.|-—–".contains(first) {
            return remainder.dropFirst()
                .trimmingCharacters(in: .whitespaces)
        }

        // Without punctuation, accept inline text only after an all-caps or
        // letter-spaced heading. A title such as "Abstract algebra" is not one.
        let headingText = line[heading]
        guard headingText == headingText.uppercased() else { return nil }
        return remainder
    }

    private static func isAbstractBoundary(_ line: String) -> Bool {
        line.range(
            of: #"(?i)^\s*(?:(?:(?:\d+(?:\.\d+)*|[ivx]+)[.)]?\s+)?(?:introduction(?:\s+and\s+background)?|main)\s*[.:]?\s*$|(?:keywords?|key\s+words?|index\s+terms?|ccs\s+concepts?|categories\s+and\s+subject\s+descriptors?|jel\s+classification)\b)"#,
            options: .regularExpression
        ) != nil
    }
}
