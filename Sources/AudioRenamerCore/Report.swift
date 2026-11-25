import Foundation

// Textes de la fenêtre de validation et du bilan final.

public enum Report {
    static let unchanged = "(inchangé)"

    public static func label(_ category: Category) -> String {
        switch category {
        case .rename: return "À RENOMMER"
        case .tagsOnly: return "MÉTADONNÉES SEULES"
        case .ok: return "DÉJÀ CONFORME"
        case .review: return "À VÉRIFIER (non modifié)"
        case .conflict: return "CONFLIT (non modifié)"
        case .error: return "ERREUR (non modifié)"
        }
    }

    /// Compteurs. Chaque fichier n'est compté que dans une catégorie : le total est exact.
    public static func summary(_ plan: Plan) -> [(String, Int)] {
        [
            ("Fichiers audio analysés", plan.entries.count),
            ("Fichiers qui seront renommés", plan.count(.rename)),
            ("Fichiers à métadonnées seules (nom conforme)", plan.count(.tagsOnly)),
            ("Fichiers déjà conformes", plan.count(.ok)),
            ("Fichiers nécessitant une vérification", plan.count(.review)),
            ("Conflits détectés", plan.count(.conflict)),
            ("Erreurs", plan.count(.error)),
        ]
    }

    /// Lignes « Élément | AVANT | APRÈS ».
    public static func rows(_ plan: Plan) -> [[String]] {
        var out: [[String]] = []
        for entry in plan.entries {
            out.append(["\(label(entry.category)) : \(entry.source.lastPathComponent)", "", ""])
            for reason in entry.reasons {
                out.append(["    ⚠ \(reason)", "", ""])
            }
            let eligible = entry.category.eligible
            let current = entry.currentTags
            let target = entry.targetTags

            let newName = (eligible && entry.nameChanges)
                ? (entry.target?.lastPathComponent ?? unchanged) : unchanged
            let newTitle = (eligible && entry.tagsChange) ? (target?.title ?? unchanged) : unchanged
            let newArtist = (eligible && entry.tagsChange) ? (target?.artist ?? unchanged) : unchanged
            let newAlbum = (eligible && entry.tagsChange) ? (target?.albumArtist ?? unchanged) : unchanged

            out.append(["    Nom du fichier", entry.source.lastPathComponent, newName])
            out.append(["    Titre", current.title ?? "—", newTitle])
            out.append(["    Artiste", current.artist ?? "—", newArtist])
            out.append(["    Album Artist", current.albumArtist ?? "—", newAlbum])
        }
        return out
    }

    public static func finalText(_ plan: Plan, _ result: ApplyResult) -> String {
        var lines = [
            "Fichiers modifiés : \(result.applied.count)",
            "Ignorés (conflit ou changement depuis l'analyse) : \(result.skipped.count)",
            "En erreur (état initial rétabli) : \(result.failed.count)",
            "Non modifiés (à vérifier, conflits, erreurs) : \(plan.entries.count - result.applied.count)",
        ]
        for item in result.skipped {
            lines.append("  · ignoré : \(item.entry.source.lastPathComponent) — \(item.reason)")
        }
        for item in result.failed {
            lines.append("  · erreur : \(item.entry.source.lastPathComponent) — \(item.reason)")
        }
        return lines.joined(separator: "\n")
    }
}
