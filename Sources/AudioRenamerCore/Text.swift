import Foundation

// Utilitaires d'expressions régulières et de chaînes (NSRegularExpression, syntaxe ICU).

enum RX {
    static func make(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // Les motifs sont constants et valides : un échec serait un bug de développement.
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Vrai si le motif trouve au moins une correspondance.
    func hits(_ re: NSRegularExpression) -> Bool {
        re.firstMatch(in: self, range: NSRange(location: 0, length: utf16.count)) != nil
    }

    /// Vrai si le motif (ancré ou non) couvre toute la chaîne.
    func fullMatch(_ re: NSRegularExpression) -> Bool {
        guard let m = re.firstMatch(in: self, range: NSRange(location: 0, length: utf16.count)) else {
            return false
        }
        return m.range.length == utf16.count
    }

    func replaced(_ re: NSRegularExpression, with template: String) -> String {
        re.stringByReplacingMatches(in: self, range: NSRange(location: 0, length: utf16.count),
                                    withTemplate: template)
    }

    /// Découpe sur toutes les correspondances du motif (séparateurs retirés).
    func splitBy(_ re: NSRegularExpression) -> [String] {
        let ns = self as NSString
        var parts: [String] = []
        var last = 0
        for m in re.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }

    /// Toutes les correspondances du motif.
    func allMatches(_ re: NSRegularExpression) -> [String] {
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }
}
