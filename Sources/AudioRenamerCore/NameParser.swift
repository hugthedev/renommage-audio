import Foundation

// Analyse structurée d'un nom de fichier (sans E/S).
// Le tag Artist sert uniquement d'indice pour détecter une inversion.
// En cas de doute, le statut passe à « probable » ou « incertain » et rien n'est modifié.

enum Status: String {
    case certain, probable, incertain
}

struct ParseResult {
    var status: Status
    var artists: [String] = []
    var title: String = ""
    var attribute: String? = nil
    var attributeIsDefault = false
    var inverted = false
    var notes: [String] = []
    var reasons: [String] = []

    var artistText: String { artists.joined(separator: ", ") }

    /// « ARTISTE - TITRE (ATTRIBUT) » sans extension.
    func formattedStem() -> String? {
        guard !artists.isEmpty, !title.isEmpty, let attribute = attribute else { return nil }
        return "\(artistText) - \(title) (\(attribute))"
    }

    /// Valeur du tag Title : « TITRE (ATTRIBUT) ».
    func metadataTitle() -> String? {
        guard !title.isEmpty, let attribute = attribute else { return nil }
        return "\(title) (\(attribute))"
    }
}

// MARK: - Motifs

private let invisibleRe = RX.make("[\u{200B}-\u{200F}\u{202A}-\u{202E}\u{2060}-\u{2064}\u{FEFF}\u{00AD}]")
private let bracketsRe = RX.make(#"\[[^\[\]]*\]"#)
private let urlRe = RX.make(#"https?://\S+|www\.\S+|\b[\w-]+\.(?:com|fr|net|org|io)\b"#, caseInsensitive: true)
private let bpmRe = RX.make(#"\b\d{2,3}\s*bpm\b"#, caseInsensitive: true)
private let parenRe = RX.make(#"\(([^()]*)\)"#)
private let emptyParenRe = RX.make(#"\(\s*\)"#)
private let oddCharRe = RX.make(#"\s[^\w\s(),&/.'!?+-]\s"#)
private let wsRe = RX.make(#"\s+"#)
// Contenu d'une parenthèse qui n'est qu'une information technique.
private let techRe = RX.make(
    #"^\s*(?:\d{2,3}\s*(?:bpm|k|kbps|kb|kbit/s)?|\d+(?:[.,]\d+)?\s*(?:khz|hz)|\d+\s*bits?|mp3|wav|aiff|flac|hq|hd)\s*$"#,
    caseInsensitive: true)
// Attributs génériques : formes longues avant les courtes.
private let attributeKeywords =
    "extended remix|radio edit|extended mix|original mix|fuvi clan|remix|rework|edit|mix|version|bootleg|flip|mashup|dub|vip|instrumental|acapella"
private let attributeRe = RX.make(#"\b(?:"# + attributeKeywords + #")\b"#, caseInsensitive: true)
private let attributeTailRe = RX.make(#"(?:^|\s)((?:"# + attributeKeywords + #"))$"#, caseInsensitive: true)
private let artistSplitRe = RX.make(#"\s*(?:,|&|/|\b(?:feat|ft)\b\.?)\s*"#, caseInsensitive: true)
private let suspectRe = RX.make(#"https?://|www\.|\.(?:com|fr|net|org|io)\b|\bpool\b"#, caseInsensitive: true)
private let trailingNumberRe = RX.make(#"\s\d{2,3}$"#)
private let wordRe = RX.make(#"[^\W\d_]+"#)

private let protectedExpressions = ["Intro Clean", "Intro Dirty", "Intro - Clean", "Intro - Dirty", "Extended Mix"]
private let defaultAttribute = "Radio Edit"
private let maxArtists = 2

// MARK: - Analyse

func analyse(stem: String, tagArtist: String?) -> ParseResult {
    var notes: [String] = []
    var text = clean(stem, &notes)

    // 1. Parenthèses d'attributs (protégés ou génériques). Les autres, comme « (Fr) »
    //    ou « (Pasilda) », restent dans le nom.
    var attrContents: [String] = []
    text = mapParens(text) { _, inner in
        let content = inner.trimmed
        if isProtected(content) || content.hits(attributeRe) {
            attrContents.append(content)
            return " "
        }
        return nil
    }
    text = text.replaced(wsRe, with: " ").trimmed

    // Numéro isolé en fin de nom : signalé, jamais supprimé.
    let tailWarning = text.hits(trailingNumberRe)
        ? ["Numéro isolé en fin de nom : à vérifier avant tout renommage"] : []

    // 2. Séparation artiste / titre.
    let segments = splitTopLevelDash(text)
    if segments.count > 2 {
        return ParseResult(status: .probable, notes: notes,
                           reasons: ["Structure ambiguë : plus de deux segments séparés par ' - '"])
    }

    var left = ""
    var right: String? = nil
    if segments.count == 2 {
        left = segments[0]
        right = segments[1]
    } else if let range = text.range(of: "_s_", options: .caseInsensitive) {
        left = String(text[..<range.lowerBound])
        right = String(text[range.upperBound...])
        notes.append("Séparateur compact « _s_ » reconnu")
    } else {
        // Format compact sans séparateur : ARTISTE_ATTRIBUT, titre absent.
        let flat = text.replacingOccurrences(of: "_", with: " ")
        let ns = flat as NSString
        guard let m = attributeTailRe.firstMatch(in: flat, range: NSRange(location: 0, length: ns.length)) else {
            return ParseResult(status: .incertain,
                               notes: notes + ["Séparateur artiste/titre introuvable"],
                               reasons: ["Format non reconnu : fichier laissé intact"])
        }
        if attrContents.isEmpty {
            attrContents = [ns.substring(with: m.range(at: 1))]
        }
        let artistPart = ns.substring(to: m.range(at: 1).location).trimmed
        return finish(left: artistPart, right: nil, attrContents: attrContents, tagArtist: tagArtist,
                      notes: notes, reasons: ["Titre absent du nom de fichier (format compact)"])
    }

    return finish(
        left: left.replacingOccurrences(of: "_", with: " ").trimmed,
        right: right.map { $0.replacingOccurrences(of: "_", with: " ").trimmed },
        attrContents: attrContents, tagArtist: tagArtist, notes: notes, reasons: tailWarning)
}

private func finish(left: String, right: String?, attrContents: [String], tagArtist: String?,
                    notes inNotes: [String], reasons inReasons: [String]) -> ParseResult {
    var notes = inNotes
    var reasons = inReasons

    let (attribute, isDefault, attrReasons) = resolveAttribute(attrContents, &notes)
    reasons += attrReasons

    // Ordre par défaut : ARTISTE - TITRE. Inversion seulement si le tag Artist
    // désigne clairement la partie droite.
    var artistSide = left
    var titleSide = right
    var inverted = false
    if let right = right, let tag = tagArtist, !tag.trimmed.isEmpty {
        let tagNames = Set(splitArtists(tag).map(normKey))
        let leftHit = !tagNames.isDisjoint(with: splitArtists(left).map(normKey))
        let rightHit = !tagNames.isDisjoint(with: splitArtists(right).map(normKey))
        if leftHit && rightHit {
            reasons.append("Ordre artiste/titre ambigu : le tag Artist correspond aux deux parties")
        } else if rightHit && !leftHit {
            artistSide = right
            titleSide = left
            inverted = true
            notes.append("Inversion artiste/titre détectée grâce au tag Artist")
        } else if !leftHit {
            reasons.append("Le tag Artist ne correspond à aucune partie du nom")
        }
    }

    let artists = dedupeArtists(splitArtists(artistSide), &notes)
    if artists.isEmpty {
        reasons.append("Artiste non identifiable")
    } else if artists.count > maxArtists {
        reasons.append("Plus de \(maxArtists) artistes distincts")
    }
    if artistSide.hits(suspectRe) {
        reasons.append("Partie artiste suspecte (URL, plateforme ou pool)")
    }

    var title = ""
    if let t = titleSide {
        let collapsed = t.replaced(wsRe, with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        title = capitalizeWords(collapsed)
        if title.isEmpty {
            reasons.append("Titre vide")
        } else if title.hits(suspectRe) {
            reasons.append("Titre suspect (URL, plateforme ou pool)")
        }
    }

    // Caractère « / » interdit dans un nom de fichier : on ne devine pas.
    if title.contains("/") || (attribute ?? "").contains("/") {
        reasons.append("Caractère « / » dans le titre : vérifier le nom")
    }

    return ParseResult(
        status: reasons.isEmpty ? .certain : .probable,
        artists: artists, title: title, attribute: attribute,
        attributeIsDefault: isDefault, inverted: inverted, notes: notes, reasons: reasons)
}

// MARK: - Nettoyage

private func clean(_ stem: String, _ notes: inout [String]) -> String {
    var s = stem.replaced(invisibleRe, with: "")
    if s.hits(bracketsRe) {
        notes.append("Contenu entre crochets supprimé")
        s = s.replaced(bracketsRe, with: " ")
    }
    if s.hits(urlRe) {
        notes.append("URL ou nom de source supprimé")
        s = s.replaced(urlRe, with: " ")
    }
    if s.hits(bpmRe) {
        notes.append("Indication BPM supprimée")
        s = s.replaced(bpmRe, with: " ")
    }
    s = mapParens(s) { _, inner in
        let content = inner.trimmed
        guard content.fullMatch(techRe) else { return nil }
        notes.append("Information technique supprimée : (\(content))")
        return " "
    }
    s = s.replaced(emptyParenRe, with: " ")
    s = s.replaced(oddCharRe, with: " ")
    return s.replaced(wsRe, with: " ").trimmed
}

/// Applique `transform` à chaque parenthèse « (contenu) ». Renvoie nil pour la garder.
private func mapParens(_ s: String, _ transform: (String, String) -> String?) -> String {
    let ns = s as NSString
    var out = ""
    var last = 0
    for m in parenRe.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        let full = ns.substring(with: m.range)
        let inner = ns.substring(with: m.range(at: 1))
        out += transform(full, inner) ?? full
        last = m.range.location + m.range.length
    }
    out += ns.substring(from: last)
    return out
}

// MARK: - Attributs

private func isProtected(_ content: String) -> Bool {
    let n = normKey(content)
    return n.hasPrefix("extended mix by ") || protectedExpressions.contains { normKey($0) == n }
}

/// Renvoie (attribut, est_par_défaut, raisons_bloquantes).
private func resolveAttribute(_ contents: [String], _ notes: inout [String]) -> (String, Bool, [String]) {
    if contents.isEmpty {
        notes.append("Aucun attribut trouvé : « \(defaultAttribute) » appliqué par défaut")
        return (defaultAttribute, true, [])
    }
    let cleaned = contents.map { $0.replaced(wsRe, with: " ").trimmed }
    if cleaned.count > 1 && cleaned.contains(where: { normKey($0).hasPrefix("intro") }) {
        // « Intro - Clean » ne se fusionne avec rien : ce serait changer son sens.
        return (cleaned.joined(separator: " ; "), false,
                ["Plusieurs attributs dont « Intro » : fusion impossible sans risque"])
    }
    // Doublons strictement identiques supprimés. Protégés gardés tels quels, génériques capitalisés.
    var unique: [String] = []
    for c in cleaned where !unique.contains(c) {
        unique.append(c)
    }
    let parts = unique.map { isProtected($0) ? $0 : capitalizeWords($0) }
    let merged = parts.joined(separator: " ")
    if unique.count > 1 {
        notes.append("Attributs fusionnés : « \(merged) »")
    }
    return (merged, false, [])
}

// MARK: - Artistes et titres

private func splitTopLevelDash(_ text: String) -> [String] {
    let chars = Array(text)
    var parts: [String] = []
    var current = ""
    var depth = 0
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "(" { depth += 1 }
        if c == ")" { depth = max(0, depth - 1) }
        if depth == 0, i + 2 < chars.count, chars[i] == " ", chars[i + 1] == "-", chars[i + 2] == " " {
            parts.append(current)
            current = ""
            i += 3
            continue
        }
        current.append(c)
        i += 1
    }
    parts.append(current)
    return parts.map { $0.trimmed }
}

private func splitArtists(_ text: String) -> [String] {
    text.splitBy(artistSplitRe)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -_")) }
        .filter { !$0.isEmpty }
}

/// Répétitions exactes supprimées ; un crédit qui partage un mot de plus de 3 lettres
/// avec un artiste déjà retenu est écarté, et ce choix est signalé.
private func dedupeArtists(_ names: [String], _ notes: inout [String]) -> [String] {
    var kept: [String] = []
    var keptWords = Set<String>()
    for raw in names {
        let name = capitalizeWords(raw)
        if kept.contains(where: { normKey($0) == normKey(name) }) {
            notes.append("Répétition exacte supprimée : \(name)")
            continue
        }
        let words = Set(name.allMatches(wordRe).map { $0.lowercased() }.filter { $0.count > 3 })
        let shared = words.intersection(keptWords)
        if !shared.isEmpty {
            notes.append("Crédit « \(name) » écarté : mot déjà présent (\(shared.sorted().joined(separator: ", ")))")
            continue
        }
        kept.append(name)
        keptWords.formUnion(words)
    }
    return kept
}

/// Majuscule en tête de mot ; les mots déjà entièrement en majuscules sont conservés.
func capitalizeWords(_ text: String) -> String {
    text.components(separatedBy: " ").map { word -> String in
        guard !word.isEmpty, word != word.uppercased() else { return word }
        var chars = Array(word)
        if let i = chars.firstIndex(where: { $0.isLetter }) {
            chars.replaceSubrange(i...i, with: Array(String(chars[i]).uppercased()))
        }
        return String(chars)
    }.joined(separator: " ")
}

private func normKey(_ s: String) -> String {
    s.replaced(wsRe, with: " ").trimmed.lowercased()
}
