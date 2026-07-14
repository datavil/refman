import Foundation
import JavaScriptCore

/// Formats in-text citations and bibliographies with citeproc-js (bundled),
/// run in JavaScriptCore against bundled CSL styles and locales.
/// Input items are mapped to CSL-JSON via `CSLJSON.object`.
public enum Citeproc {
    public enum Style: String, CaseIterable, Sendable {
        case apa
        case mla = "modern-language-association"
        case harvard = "harvard-cite-them-right"
        case chicago = "chicago-author-date"
        case chicagoNotes = "chicago-notes-bibliography"
        case nature
        case ieee
        case acs = "american-chemical-society"
        case ama = "american-medical-association"
        case vancouver = "nlm-citation-sequence"

        public enum Category: CaseIterable, Sendable {
            case general
            case science
            case medical

            public var label: String {
                switch self {
                case .general: return "General & Humanities"
                case .science: return "Science & Engineering"
                case .medical: return "Medicine"
                }
            }
        }

        public var label: String {
            switch self {
            case .apa: return "APA"
            case .mla: return "MLA"
            case .harvard: return "Harvard (Cite Them Right)"
            case .chicago: return "Chicago (Author-Date)"
            case .chicagoNotes: return "Chicago (Notes & Bibliography)"
            case .nature: return "Nature"
            case .ieee: return "IEEE"
            case .acs: return "ACS"
            case .ama: return "AMA"
            case .vancouver: return "Vancouver (NLM)"
            }
        }

        public var category: Category {
            switch self {
            case .apa, .mla, .harvard, .chicago, .chicagoNotes: return .general
            case .nature, .ieee, .acs: return .science
            case .ama, .vancouver: return .medical
            }
        }
    }

    public enum Mode: Sendable { case citation, bibliography }

    public enum CiteprocError: Error, LocalizedError {
        case resourceMissing(String)
        case engineFailed(String)

        public var errorDescription: String? {
            switch self {
            case .resourceMissing(let r): return "Missing citation resource: \(r)"
            case .engineFailed(let m): return m
            }
        }
    }

    /// Returns the formatted citation (in-text) or bibliography for `items` in
    /// the given style. Citation order follows `items`; bibliography order is
    /// decided by the style.
    public static func format(_ items: [DocumentDetails], style: Style, mode: Mode) throws
        -> String
    {
        guard !items.isEmpty else { return "" }
        let styleXML = try resourceString(style.rawValue, "csl")
        let localeXMLByID = try Dictionary(
            uniqueKeysWithValues: localeIDs.map { id in
                (id, try resourceString("locales-\(id)", "xml"))
            })
        let citeprocJS = try resourceString("citeproc", "js")

        // CSL-JSON items keyed by a unique id; reuse the same ids for ordering.
        var counts: [String: Int] = [:]
        var ids: [String] = []
        var itemsByID: [String: [String: Any]] = [:]
        for item in items {
            var obj = CSLJSON.object(item)
            var id = (obj["id"] as? String) ?? UUID().uuidString
            let n = (counts[id] ?? 0) + 1
            counts[id] = n
            if n > 1 { id = "\(id)-\(n)" }
            obj["id"] = id
            ids.append(id)
            itemsByID[id] = obj
        }

        let context = JSContext()!
        var thrown: String?
        context.exceptionHandler = { _, value in thrown = value?.toString() }
        context.evaluateScript(citeprocJS)
        context.evaluateScript(driver)
        guard let fn = context.objectForKeyedSubscript("refmanFormat"), !fn.isUndefined else {
            throw CiteprocError.engineFailed(thrown ?? "citeproc failed to load")
        }
        let modeStr = mode == .bibliography ? "bibliography" : "citation"
        let result = fn.call(withArguments: [styleXML, localeXMLByID, itemsByID, ids, modeStr])
        if let thrown { throw CiteprocError.engineFailed(thrown) }
        guard let text = result?.toString(), result?.isUndefined == false else {
            throw CiteprocError.engineFailed("no output produced")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// citeproc-js driver: builds an engine bound to the injected locale/items
    /// and returns plain-text output for one cluster or the whole bibliography.
    private static let driver = """
        function refmanFormat(styleXml, localeXmlById, itemsObj, ids, mode) {
          var sys = {
            retrieveLocale: function(lang) {
              var id = (lang || 'en-US').replace('_', '-');
              return localeXmlById[id] || localeXmlById['en-US'];
            },
            retrieveItem: function(id) { return itemsObj[id]; }
          };
          var engine = new CSL.Engine(sys, styleXml);
          engine.setOutputFormat('text');
          if (mode === 'bibliography') {
            engine.updateItems(ids);
            var res = engine.makeBibliography();
            if (!res || !res[1]) return '';
            return res[1].join('');
          }
          var citationItems = ids.map(function(id) { return { id: id }; });
          var citation = { citationItems: citationItems, properties: { noteIndex: 0 } };
          return engine.previewCitationCluster(citation, [], [], 'text');
        }
        """

    /// True when the bundled citeproc assets resolve from the located bundle.
    /// Exercised by the packaged-app resource smoke check, which would otherwise
    /// only surface a missing bundle when a user first copies a citation.
    public static func resourcesAvailable() -> Bool {
        guard (try? resourceString("citeproc", "js")) != nil else { return false }
        return Style.allCases.allSatisfy { (try? resourceString($0.rawValue, "csl")) != nil }
            && localeIDs.allSatisfy {
                (try? resourceString("locales-\($0)", "xml")) != nil
            }
    }

    private static let localeIDs = ["en-US", "en-GB"]

    private static func resourceString(_ name: String, _ ext: String) throws -> String {
        guard
            let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Citeproc")
                ?? bundle.url(forResource: name, withExtension: ext),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else { throw CiteprocError.resourceMissing("\(name).\(ext)") }
        return contents
    }

    /// Locates `RefmanCore_RefmanCore.bundle` defensively: in the hand-packaged
    /// `.app` it lives in `Contents/Resources`, where `Bundle.module` would
    /// crash. Falls back to `Bundle.module` for `swift run`/`swift test`.
    private static let bundle: Bundle = {
        let name = "Refman_RefmanCore.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: BundleToken.self).resourceURL,
            Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent(),
        ]
        for url in candidates.compactMap({ $0?.appendingPathComponent(name) }) {
            if let resolved = Bundle(url: url) { return resolved }
        }
        return Bundle.module
    }()

    private final class BundleToken {}
}
