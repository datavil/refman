import Foundation

public enum BibTeX {
    public struct Entry: Equatable, Sendable {
        public var type: String
        public var citationKey: String
        public var fields: [String: String]

        public init(type: String, citationKey: String, fields: [String: String]) {
            self.type = type
            self.citationKey = citationKey
            self.fields = fields
        }
    }

    // MARK: - Parsing

    /// Parses a .bib file's entries. Tolerant: skips malformed entries,
    /// handles nested braces and quoted values.
    public static func parse(_ input: String) -> [Entry] {
        var entries: [Entry] = []
        var scanner = Substring(input)

        while let atIndex = scanner.firstIndex(of: "@") {
            scanner = scanner[scanner.index(after: atIndex)...]
            guard let braceIndex = scanner.firstIndex(of: "{") else { break }
            let type = scanner[..<braceIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            scanner = scanner[scanner.index(after: braceIndex)...]
            if type == "comment" || type == "preamble" || type == "string" {
                continue  // skip to next @
            }
            guard let commaIndex = scanner.firstIndex(of: ",") else { break }
            let key = scanner[..<commaIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            scanner = scanner[scanner.index(after: commaIndex)...]

            var fields: [String: String] = [:]
            fieldLoop: while true {
                // field name
                guard let eq = scanner.firstIndex(of: "=") else { break }
                // Stop if we hit the entry's closing brace before the next '='.
                if let close = scanner.firstIndex(of: "}"), close < eq {
                    scanner = scanner[scanner.index(after: close)...]
                    break
                }
                let name = scanner[..<eq]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n,{}"))
                    .lowercased()
                scanner = scanner[scanner.index(after: eq)...]
                // skip whitespace
                while let f = scanner.first, f.isWhitespace { scanner = scanner.dropFirst() }
                guard let open = scanner.first else { break }

                var value = ""
                switch open {
                case "{":
                    var depth = 0
                    var idx = scanner.startIndex
                    loop: while idx < scanner.endIndex {
                        let c = scanner[idx]
                        switch c {
                        case "{": depth += 1; if depth > 1 { value.append(c) }
                        case "}":
                            depth -= 1
                            if depth == 0 {
                                idx = scanner.index(after: idx)
                                break loop
                            }
                            value.append(c)
                        default: value.append(c)
                        }
                        idx = scanner.index(after: idx)
                    }
                    scanner = scanner[idx...]
                case "\"":
                    scanner = scanner.dropFirst()
                    if let end = scanner.firstIndex(of: "\"") {
                        value = String(scanner[..<end])
                        scanner = scanner[scanner.index(after: end)...]
                    } else {
                        break fieldLoop
                    }
                default:
                    // bare value (number) — read until , or }
                    var idx = scanner.startIndex
                    while idx < scanner.endIndex, scanner[idx] != ",", scanner[idx] != "}" {
                        value.append(scanner[idx])
                        idx = scanner.index(after: idx)
                    }
                    scanner = scanner[idx...]
                }
                if !name.isEmpty {
                    fields[name] = normalize(value)
                }
                // consume separator
                while let f = scanner.first, f.isWhitespace || f == "," {
                    scanner = scanner.dropFirst()
                }
                if scanner.first == "}" {
                    scanner = scanner.dropFirst()
                    break
                }
            }
            entries.append(Entry(type: type, citationKey: String(key), fields: fields))
        }
        return entries
    }

    /// Decodes LaTeX/HTML escapes, collapses whitespace, strips protective braces.
    static func normalize(_ value: String) -> String {
        TextDecoding.clean(value)
    }

    /// Converts a parsed entry into a document + authors.
    public static func document(from entry: Entry) -> (Document, [Author]) {
        let f = entry.fields
        let type: DocumentType
        switch entry.type {
        case "article": type = .article
        case "book": type = .book
        case "inbook", "incollection": type = .chapter
        case "inproceedings", "conference": type = .conferencePaper
        case "phdthesis", "mastersthesis": type = .thesis
        case "techreport": type = .report
        case "misc" where f["eprint"] != nil: type = .preprint
        default: type = .misc
        }

        let document = Document(
            type: type,
            title: f["title"] ?? "",
            abstract: f["abstract"],
            year: f["year"].flatMap { Int($0) },
            venue: f["journal"] ?? f["booktitle"],
            volume: f["volume"],
            issue: f["number"],
            pages: f["pages"]?.replacingOccurrences(of: "--", with: "–"),
            doi: f["doi"],
            arxivId: f["eprint"],
            url: f["url"]
        )
        let authors = (f["author"] ?? "")
            .components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(parseAuthorName)
        return (document, authors)
    }

    /// Handles both "Family, Given" and "Given Family".
    public static func parseAuthorName(_ name: String) -> Author {
        if let comma = name.firstIndex(of: ",") {
            let family = name[..<comma].trimmingCharacters(in: .whitespaces)
            let given = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            return Author(given: given, family: family)
        }
        if let lastSpace = name.lastIndex(of: " ") {
            return Author(
                given: String(name[..<lastSpace]),
                family: String(name[name.index(after: lastSpace)...]))
        }
        return Author(family: name)
    }

    // MARK: - Export

    public static func export(_ items: [DocumentDetails]) -> String {
        items.map(export).joined(separator: "\n\n") + "\n"
    }

    public static func export(_ item: DocumentDetails) -> String {
        export(item, file: nil)
    }

    /// Exports one entry, optionally writing `file` with a relative attachment
    /// path (JabRef `description:path:type` form, which Zotero and Mendeley
    /// both read on import).
    public static func export(_ item: DocumentDetails, file: String?) -> String {
        let d = item.document
        let bibType: String
        switch d.type {
        case .article: bibType = "article"
        case .book: bibType = "book"
        case .chapter: bibType = "incollection"
        case .conferencePaper: bibType = "inproceedings"
        case .thesis: bibType = "phdthesis"
        case .report: bibType = "techreport"
        case .preprint, .webpage, .misc: bibType = "misc"
        }

        var fields: [(String, String)] = []
        fields.append(("title", d.title))
        if !item.authors.isEmpty {
            let names = item.authors
                .map { $0.family + ($0.given.isEmpty ? "" : ", \($0.given)") }
                .joined(separator: " and ")
            fields.append(("author", names))
        }
        if let year = d.year { fields.append(("year", String(year))) }
        if let venue = d.venue {
            fields.append((d.type == .conferencePaper ? "booktitle" : "journal", venue))
        }
        if let v = d.volume { fields.append(("volume", v)) }
        if let n = d.issue { fields.append(("number", n)) }
        if let p = d.pages {
            fields.append(("pages", p.replacingOccurrences(of: "–", with: "--")))
        }
        if let doi = d.doi { fields.append(("doi", doi)) }
        if let arxiv = d.arxivId {
            fields.append(("eprint", arxiv))
            fields.append(("archiveprefix", "arXiv"))
        }
        if let url = d.url { fields.append(("url", url)) }
        if let file { fields.append(("file", ":\(file):PDF")) }

        let body = fields
            .map { "  \($0.0) = {\($0.1)}" }
            .joined(separator: ",\n")
        return "@\(bibType){\(citationKey(for: item)),\n\(body)\n}"
    }

    /// e.g. "smith2021attention"
    public static func citationKey(for item: DocumentDetails) -> String {
        let family = item.authors.first?.family.lowercased() ?? "anon"
        let year = item.document.year.map(String.init) ?? "nd"
        let firstWord = item.document.title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first { $0.count > 3 } ?? ""
        return (family + year + firstWord)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
