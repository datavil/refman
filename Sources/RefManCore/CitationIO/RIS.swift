import Foundation

/// RIS tagged format (Mendeley/EndNote/Zotero interchange).
public enum RIS {
    public struct Entry: Equatable, Sendable {
        public var fields: [(tag: String, value: String)]

        public init(fields: [(tag: String, value: String)]) {
            self.fields = fields
        }

        public func first(_ tag: String) -> String? {
            fields.first { $0.tag == tag }?.value
        }

        public func all(_ tag: String) -> [String] {
            fields.filter { $0.tag == tag }.map(\.value)
        }

        public static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.fields.count == rhs.fields.count
                && zip(lhs.fields, rhs.fields).allSatisfy { $0.tag == $1.tag && $0.value == $1.value }
        }
    }

    // MARK: - Parsing

    public static func parse(_ input: String) -> [Entry] {
        var entries: [Entry] = []
        var current: [(String, String)] = []

        for rawLine in input.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // "TY  - JOUR": two-char tag, two spaces, dash.
            guard line.count >= 5, line.dropFirst(2).hasPrefix("  -") else { continue }
            let tag = String(line.prefix(2))
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)

            if tag == "ER" {
                if !current.isEmpty { entries.append(Entry(fields: current)) }
                current = []
            } else {
                current.append((tag, value))
            }
        }
        // Tolerate a missing trailing ER.
        if current.contains(where: { $0.0 == "TY" }) {
            entries.append(Entry(fields: current))
        }
        return entries
    }

    public static func document(from entry: Entry) -> (Document, [Author]) {
        let type: DocumentType
        switch entry.first("TY") ?? "" {
        case "JOUR": type = .article
        case "BOOK": type = .book
        case "CHAP": type = .chapter
        case "CONF", "CPAPER": type = .conferencePaper
        case "THES": type = .thesis
        case "RPRT": type = .report
        case "UNPB", "INPR": type = .preprint
        case "ELEC", "WEB": type = .webpage
        default: type = .misc
        }

        // Pages: SP/EP pair or SP alone.
        var pages: String?
        if let sp = entry.first("SP") {
            pages = entry.first("EP").map { "\(sp)–\($0)" } ?? sp
        }

        let year = (entry.first("PY") ?? entry.first("Y1"))
            .flatMap { Int($0.prefix(4)) }

        let document = Document(
            type: type,
            title: entry.first("TI") ?? entry.first("T1") ?? "",
            abstract: entry.first("AB") ?? entry.first("N2"),
            year: year,
            venue: entry.first("JO") ?? entry.first("T2") ?? entry.first("JF"),
            volume: entry.first("VL"),
            issue: entry.first("IS"),
            pages: pages,
            doi: entry.first("DO"),
            url: entry.first("UR")
        )
        let authors = (entry.all("AU") + entry.all("A1"))
            .map(BibTeX.parseAuthorName)
        return (document, authors)
    }

    // MARK: - Export

    public static func export(_ items: [DocumentDetails]) -> String {
        items.map(export).joined(separator: "\n")
    }

    public static func export(_ item: DocumentDetails) -> String {
        let d = item.document
        let ty: String
        switch d.type {
        case .article: ty = "JOUR"
        case .book: ty = "BOOK"
        case .chapter: ty = "CHAP"
        case .conferencePaper: ty = "CONF"
        case .thesis: ty = "THES"
        case .report: ty = "RPRT"
        case .preprint: ty = "UNPB"
        case .webpage: ty = "ELEC"
        case .misc: ty = "GEN"
        }

        var lines = ["TY  - \(ty)"]
        lines.append("TI  - \(d.title)")
        for a in item.authors {
            lines.append("AU  - \(a.family)\(a.given.isEmpty ? "" : ", \(a.given)")")
        }
        if let year = d.year { lines.append("PY  - \(year)") }
        if let venue = d.venue { lines.append("T2  - \(venue)") }
        if let v = d.volume { lines.append("VL  - \(v)") }
        if let n = d.issue { lines.append("IS  - \(n)") }
        if let pages = d.pages {
            let parts = pages.components(separatedBy: CharacterSet(charactersIn: "–-"))
                .filter { !$0.isEmpty }
            if parts.count == 2 {
                lines.append("SP  - \(parts[0])")
                lines.append("EP  - \(parts[1])")
            } else {
                lines.append("SP  - \(pages)")
            }
        }
        if let abstract = d.abstract { lines.append("AB  - \(abstract)") }
        if let doi = d.doi { lines.append("DO  - \(doi)") }
        if let url = d.url { lines.append("UR  - \(url)") }
        lines.append("ER  - ")
        return lines.joined(separator: "\n") + "\n"
    }
}
