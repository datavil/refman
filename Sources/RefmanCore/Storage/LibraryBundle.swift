import Foundation

/// Exports references as a portable folder — `library.bib` plus the attached
/// PDFs alongside it, linked by relative filename so other reference managers
/// (Zotero, Mendeley) import the attachments.
public enum LibraryBundle {
    public struct Result: Sendable {
        public var references: Int
        public var pdfs: Int
        /// References whose PDF wasn't on disk yet (e.g. evicted from iCloud); a
        /// download was requested so a later run can pick them up.
        public var notDownloaded: Int
        /// Human-readable reasons for PDFs that failed to copy.
        public var copyErrors: [String]
    }

    /// Writes the bundle at `bundle`, replacing any existing item there. The
    /// PDFs are always copied; `includeBibTeX`/`includeRIS`/`includeXML` control
    /// which bibliography sidecars (`library.bib`/`.ris`/`.xml`) accompany them.
    public static func export(
        _ items: [DocumentDetails], store: LibraryStore, to bundle: URL,
        includeBibTeX: Bool = true, includeRIS: Bool = false, includeXML: Bool = false
    ) throws -> Result {
        let fm = FileManager.default
        if fm.fileExists(atPath: bundle.path) { try fm.removeItem(at: bundle) }
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)

        var usedNames = Set<String>()
        var entries: [String] = []
        var copied = 0
        var notDownloaded = 0
        var copyErrors: [String] = []
        for item in items {
            var relPath: String?
            if let hash = item.document.fileHash {
                // Materialize evicted iCloud files before copying.
                if store.ensureDownloaded(hash: hash) {
                    let base = uniqueName(BibTeX.citationKey(for: item), used: &usedNames)
                    do {
                        var dest = bundle.appendingPathComponent("\(base).pdf")
                        try fm.copyItem(at: store.url(forHash: hash), to: dest)
                        // Store files carry the Finder hidden flag, which copyItem
                        // preserves; clear it so the export is visible in Finder.
                        var values = URLResourceValues()
                        values.isHidden = false
                        try? dest.setResourceValues(values)
                        relPath = "\(base).pdf"
                        copied += 1
                    } catch {
                        copyErrors.append(error.localizedDescription)
                    }
                } else {
                    notDownloaded += 1
                }
            }
            entries.append(BibTeX.export(item, file: relPath))
        }
        if includeBibTeX {
            let bib = entries.joined(separator: "\n\n") + "\n"
            try Data(bib.utf8).write(to: bundle.appendingPathComponent("library.bib"))
        }
        if includeRIS {
            try Data(RIS.export(items).utf8).write(
                to: bundle.appendingPathComponent("library.ris"))
        }
        if includeXML {
            try Data(EndNoteXML.export(items).utf8).write(
                to: bundle.appendingPathComponent("library.xml"))
        }
        return Result(
            references: items.count, pdfs: copied,
            notDownloaded: notDownloaded, copyErrors: copyErrors)
    }

    /// A unique `.pdf` base name within the bundle, suffixing on collision.
    private static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        let root = base.isEmpty ? "document" : base
        var candidate = root
        var n = 2
        while used.contains(candidate) {
            candidate = "\(root)-\(n)"
            n += 1
        }
        used.insert(candidate)
        return candidate
    }
}
