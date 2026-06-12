import Foundation

/// The assistant's library tools, shared by the app (which answers the
/// Ollama agent's `refman/toolCall` requests) and refman-agent's MCP server
/// (which serves the Claude backend directly from the database).
public enum LibraryTools {
    /// Executes a tool and returns model-readable text. `textLimit` caps
    /// `get_document_text` so small local models aren't flooded.
    public static func handle(
        name: String, arguments: [String: Any],
        repository: LibraryRepository, currentDocumentId: Int64,
        textLimit: Int
    ) throws -> String {
        func targetId() -> Int64 {
            (arguments["document_id"] as? NSNumber)?.int64Value ?? currentDocumentId
        }

        switch name {
        case "get_current_document":
            guard let details = try repository.document(id: currentDocumentId) else {
                return "No document is open."
            }
            return describe(details)

        case "get_document_text":
            let id = targetId()
            guard let text = try repository.fullText(documentId: id), !text.isEmpty else {
                return "No extracted text for document \(id)."
            }
            return String(text.prefix(textLimit))

        case "search_library":
            let query = arguments["query"] as? String ?? ""
            let results = try repository.search(query)
            guard !results.isEmpty else { return "No matches for ‘\(query)’." }
            return results.prefix(10).map(describe).joined(separator: "\n---\n")

        case "get_annotations":
            let id = targetId()
            let annotations = try repository.annotations(documentId: id)
            guard !annotations.isEmpty else { return "No annotations on document \(id)." }
            return annotations.map { a in
                var line = "p.\(a.pageIndex + 1) [\(a.kind.rawValue)]"
                if let t = a.selectedText, !t.isEmpty { line += " “\(t)”" }
                if let n = a.noteText, !n.isEmpty { line += " — note: \(n)" }
                return line
            }.joined(separator: "\n")

        case "add_tag":
            guard let tagName = arguments["name"] as? String, !tagName.isEmpty else {
                return "Missing tag name."
            }
            let id = targetId()
            _ = try repository.addTag(tagName, toDocument: id)
            return "Tagged document \(id) with ‘\(tagName)’."

        default:
            return "Unknown tool: \(name)"
        }
    }

    private static func describe(_ details: DocumentDetails) -> String {
        let d = details.document
        var lines = ["id: \(d.id ?? -1)", "title: \(d.title)"]
        if !details.authorsText.isEmpty { lines.append("authors: \(details.authorsText)") }
        if let year = d.year { lines.append("year: \(year)") }
        if let venue = d.venue { lines.append("venue: \(venue)") }
        if let doi = d.doi { lines.append("doi: \(doi)") }
        if let abstract = d.abstract { lines.append("abstract: \(abstract.prefix(600))") }
        return lines.joined(separator: "\n")
    }
}
