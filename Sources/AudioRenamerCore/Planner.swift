import Foundation

// Phase 1 : analyse sans modification (buildPlan).
// Phase 2 : application après validation explicite (applyPlan).

public enum Category: String {
    case rename        // modification éligible : changement de nom
    case tagsOnly      // modification éligible : tags seuls
    case ok            // déjà conforme
    case review        // probable ou incertain : jamais modifié automatiquement
    case conflict      // nom final déjà utilisé : jamais modifié
    case error         // illisible : jamais modifié

    public var eligible: Bool { self == .rename || self == .tagsOnly }
}

public final class FileEntry {
    public let source: URL
    public internal(set) var category: Category = .error
    public internal(set) var currentTags = TagSet()
    public internal(set) var target: URL? = nil
    public internal(set) var targetTags: TagSet? = nil
    public internal(set) var reasons: [String] = []
    var parse: ParseResult? = nil

    init(source: URL) {
        self.source = source
    }

    var nameChanges: Bool {
        guard let target = target else { return false }
        return target.lastPathComponent != source.lastPathComponent
    }

    var tagsChange: Bool {
        guard let targetTags = targetTags else { return false }
        return targetTags != currentTags
    }

    func markConflict(_ reason: String) {
        category = .conflict
        reasons.append(reason)
    }
}

public struct Plan {
    public let entries: [FileEntry]

    public func count(_ category: Category) -> Int {
        entries.filter { $0.category == category }.count
    }
}

public struct ApplyResult {
    public var applied: [FileEntry] = []
    public var skipped: [(entry: FileEntry, reason: String)] = []
    public var failed: [(entry: FileEntry, reason: String)] = []
}

// MARK: - Phase 1

public func buildPlan(paths: [URL]) -> Plan {
    let entries = collectAudioFiles(paths).map(analyseFile)
    detectConflicts(entries)
    return Plan(entries: entries)
}

public func collectAudioFiles(_ inputs: [URL]) -> [URL] {
    let fm = FileManager.default
    var found: [String: URL] = [:]

    func consider(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["mp3", "wav"].contains(ext), !isSymlink(url) else { return }
        let standard = url.standardizedFileURL
        found[standard.path] = standard
    }

    for input in inputs {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: input.path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            // .skipsHiddenFiles écarte les fichiers cachés et les « ._ » de macOS.
            guard let enumerator = fm.enumerator(
                at: input,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where isRegularFile(url) {
                consider(url)
            }
        } else {
            consider(input)
        }
    }
    return found.values.sorted { $0.path.lowercased() < $1.path.lowercased() }
}

private func analyseFile(_ url: URL) -> FileEntry {
    let entry = FileEntry(source: url)
    let current: TagSet
    do {
        current = try Tagger.read(url)
    } catch {
        entry.category = .error
        entry.reasons = ["Lecture impossible : \(error.localizedDescription)"]
        return entry
    }
    entry.currentTags = current

    let parse = analyse(stem: url.deletingPathExtension().lastPathComponent, tagArtist: current.artist)
    entry.parse = parse
    guard parse.status == .certain, let stem = parse.formattedStem() else {
        entry.category = .review
        entry.reasons = parse.reasons
        return entry
    }

    let newURL = url.deletingLastPathComponent()
        .appendingPathComponent(stem + "." + url.pathExtension)
    if newURL.lastPathComponent != url.lastPathComponent {
        entry.target = newURL
    }
    entry.targetTags = TagSet(title: parse.metadataTitle(),
                              artist: parse.artistText,
                              albumArtist: parse.artistText)
    if entry.nameChanges {
        entry.category = .rename
    } else if entry.tagsChange {
        entry.category = .tagsOnly
    } else {
        entry.category = .ok
    }
    return entry
}

/// Deux fichiers visant le même nom, ou un nom déjà présent sur le disque.
private func detectConflicts(_ entries: [FileEntry]) {
    var groups: [String: [FileEntry]] = [:]
    for entry in entries where entry.category.eligible && entry.nameChanges {
        if let target = entry.target {
            groups[target.path.lowercased(), default: []].append(entry)
        }
    }
    for group in groups.values where group.count > 1 {
        group.forEach { $0.markConflict("Même nom final pour plusieurs fichiers") }
    }
    for entry in entries where entry.category.eligible && entry.nameChanges {
        if let target = entry.target, isTaken(target, by: entry.source) {
            entry.markConflict("Le nom « \(target.lastPathComponent) » existe déjà")
        }
    }
}

// MARK: - Phase 2

/// À n'appeler qu'après validation explicite de l'utilisateur.
public func applyPlan(_ plan: Plan) -> ApplyResult {
    var result = ApplyResult()
    // Les conflits sont recalculés juste avant d'écrire.
    detectConflicts(plan.entries)

    for entry in plan.entries where entry.category.eligible {
        let source = entry.source
        guard FileManager.default.fileExists(atPath: source.path) else {
            result.skipped.append((entry, "Fichier disparu depuis l'analyse"))
            continue
        }
        if entry.nameChanges, let target = entry.target, isTaken(target, by: source) {
            result.skipped.append((entry, "Nom final devenu occupé"))
            continue
        }
        do {
            var current = source
            if entry.nameChanges, let target = entry.target {
                try moveWithoutOverwrite(source, to: target)
                current = target
            }
            if entry.tagsChange, let tags = entry.targetTags {
                do {
                    try Tagger.write(current,
                                     title: tags.title ?? "",
                                     artist: tags.artist ?? "",
                                     albumArtist: tags.albumArtist ?? "")
                } catch {
                    // Rétablir le nom d'origine si l'écriture des tags échoue.
                    if current != source {
                        try? moveWithoutOverwrite(current, to: source)
                    }
                    throw error
                }
            }
            result.applied.append(entry)
        } catch {
            result.failed.append((entry, error.localizedDescription))
        }
    }
    return result
}

// MARK: - Fichiers

/// Vrai si `target` existe et n'est pas le même fichier que `source`.
private func isTaken(_ target: URL, by source: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: target.path) else { return false }
    return !isSameFile(target, source)
}

private func isSameFile(_ a: URL, _ b: URL) -> Bool {
    let idA = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    let idB = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    guard let x = idA, let y = idB else { return false }
    return (x as AnyObject).isEqual(y as AnyObject)
}

private func isRegularFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
}

private func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
}

/// Ne jamais écraser : `moveItem` échoue si la cible existe déjà.
private func moveWithoutOverwrite(_ source: URL, to target: URL) throws {
    let fm = FileManager.default
    if source.lastPathComponent.lowercased() == target.lastPathComponent.lowercased() {
        // Simple changement de casse : passer par un nom temporaire (FS insensible à la casse).
        let temp = source.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString)")
        try fm.moveItem(at: source, to: temp)
        try fm.moveItem(at: temp, to: target)
        return
    }
    if fm.fileExists(atPath: target.path) {
        throw CocoaError(.fileWriteFileExists)
    }
    try fm.moveItem(at: source, to: target)
}
