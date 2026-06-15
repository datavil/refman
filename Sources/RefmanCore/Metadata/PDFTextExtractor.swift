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
            pageCount: doc.pageCount, fullText: full, headText: head, embeddedTitle: title)
    }
}
