import Foundation

/// Decodes HTML/XML character entities and common LaTeX escapes found in
/// titles, journal names and abstracts coming from BibTeX files and metadata
/// APIs (e.g. CrossRef's "Cell Host &amp; Microbe", BibTeX's "M\\\"uller").
public enum TextDecoding {

    /// HTML- and LaTeX-decode, then collapse whitespace runs and trim.
    public static func clean(_ s: String) -> String {
        decodingLaTeX(decodingHTMLEntities(s))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTML entities

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ndash": "–", "mdash": "—", "hellip": "…",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "micro": "µ",
        "times": "×", "divide": "÷", "plusmn": "±", "minus": "−",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Pi": "Π",
        "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    public static func decodingHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return replacing(#"&(#[xX][0-9A-Fa-f]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);"#, in: s) { groups in
            let body = groups[1]
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let code = UInt32(body.dropFirst(2), radix: 16),
                    let scalar = Unicode.Scalar(code) { return String(scalar) }
            } else if body.hasPrefix("#") {
                if let code = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(code) {
                    return String(scalar)
                }
            } else if let value = namedEntities[body] {
                return value
            }
            return groups[0]  // unknown entity: leave untouched
        }
    }

    // MARK: - LaTeX

    static let symbolAccents: [String: Unicode.Scalar] = [
        "'": "\u{0301}", "`": "\u{0300}", "^": "\u{0302}", "\"": "\u{0308}",
        "~": "\u{0303}", "=": "\u{0304}", ".": "\u{0307}",
    ]
    static let letterAccents: [String: Unicode.Scalar] = [
        "c": "\u{0327}", "v": "\u{030C}", "u": "\u{0306}", "H": "\u{030B}",
        "k": "\u{0328}", "r": "\u{030A}", "b": "\u{0331}", "d": "\u{0323}",
    ]
    static let specialLetters: [String: String] = [
        "ss": "ß", "oe": "œ", "OE": "Œ", "ae": "æ", "AE": "Æ", "aa": "å",
        "AA": "Å", "o": "ø", "O": "Ø", "l": "ł", "L": "Ł", "i": "ı", "j": "ȷ",
        "dh": "ð", "DH": "Ð", "th": "þ", "TH": "Þ",
    ]
    static let mathSymbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι",
        "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ",
        "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "times": "×", "cdot": "·", "pm": "±", "mp": "∓", "to": "→",
        "rightarrow": "→", "leftarrow": "←", "infty": "∞", "leq": "≤",
        "geq": "≥", "neq": "≠", "approx": "≈", "sim": "∼", "degree": "°",
        "circ": "∘", "prime": "′",
    ]

    public static func decodingLaTeX(_ s: String) -> String {
        guard s.contains("\\") || s.contains("$") || s.contains("{") else { return s }
        var t = s

        // Unwrap inline formatting commands, keeping their content.
        t = replacing(
            #"\\(?:emph|textbf|textit|textrm|texttt|textsc|textsf|textnormal|mathrm|mathbf|mathit|mathcal|mathsf|text|mbox|hbox)\s*\{([^{}]*)\}"#,
            in: t
        ) { $0[1] }

        // Escaped special characters.
        for (escaped, plain) in [
            ("\\&", "&"), ("\\%", "%"), ("\\$", "$"), ("\\#", "#"),
            ("\\_", "_"), ("\\textbackslash", "\\"),
        ] {
            t = t.replacingOccurrences(of: escaped, with: plain)
        }

        // Symbol accents (\'e, \"{o}, …) → base letter + combining mark.
        t = replacing(#"\\(['`^"~=.])\s*\{?\s*([A-Za-z])\s*\}?"#, in: t) { g in
            guard let mark = symbolAccents[g[1]] else { return g[0] }
            return String(g[2]) + String(mark)
        }
        // Letter accents (\c{c}, \v s, …) require a brace or space so we don't
        // eat commands like \cite.
        t = replacing(#"\\([cvuHkrbd])(?:\{([A-Za-z])\}|\s+([A-Za-z]))"#, in: t) { g in
            guard let mark = letterAccents[g[1]] else { return g[0] }
            let letter = g[2].isEmpty ? g[3] : g[2]
            return letter + String(mark)
        }

        // Special letters / ligatures (\ss, \o, \ae, …). A control word absorbs
        // one trailing space in LaTeX, so "Stra\ss e" → "Straße".
        t = replacing(#"\\(ss|oe|OE|ae|AE|aa|AA|o|O|l|L|i|j|dh|DH|th|TH)(?![A-Za-z])\s?"#, in: t) {
            specialLetters[$0[1]] ?? $0[0]
        }
        // Greek letters and math symbols; unknown commands are left as-is.
        t = replacing(#"\\([A-Za-z]+)\s?"#, in: t) { mathSymbols[$0[1]] ?? $0[0] }

        // Drop math delimiters and any remaining protective braces.
        t = t.replacingOccurrences(of: "$", with: "")
        t = t.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")

        // Combine base + diacritic into precomposed characters (é, ü, …).
        return t.precomposedStringWithCanonicalMapping
    }

    // MARK: - Helper

    /// Regex replace where each match is rewritten by `transform`, which
    /// receives the matched groups (group 0 is the whole match).
    static func replacing(
        _ pattern: String, in s: String, _ transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        regex.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return result
    }
}
