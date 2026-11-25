import Foundation

// Lecture et écriture des tags ID3v2 (MP3) et du chunk « id3 » (WAV).
// Seuls TIT2 (Title), TPE1 (Artist) et TPE2 (Album Artist) sont remplacés.
// Tous les autres frames sont recopiés à l'identique. L'audio n'est jamais réencodé :
// les octets audio sont copiés tels quels.

public struct TagSet: Equatable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?

    public init(title: String? = nil, artist: String? = nil, albumArtist: String? = nil) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
    }
}

public enum TagError: LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message): return message
        }
    }
}

public enum Tagger {
    public static func read(_ url: URL) throws -> TagSet {
        let bytes = [UInt8](try Data(contentsOf: url))
        let frames: [Frame]
        if isWAV(url) {
            frames = try wavID3(bytes)?.frames ?? []
        } else {
            frames = try parseID3(bytes, at: 0)?.frames ?? []
        }
        return TagSet(
            title: textFrame("TIT2", in: frames),
            artist: textFrame("TPE1", in: frames),
            albumArtist: textFrame("TPE2", in: frames))
    }

    public static func write(_ url: URL, title: String, artist: String, albumArtist: String) throws {
        let bytes = [UInt8](try Data(contentsOf: url))
        let out: [UInt8]
        if isWAV(url) {
            let existing = try wavID3(bytes)
            let frames = merge(existing?.frames ?? [], title: title, artist: artist, albumArtist: albumArtist)
            out = try rebuildWAV(bytes, frames: frames, major: existing?.major ?? 3)
        } else {
            let existing = try parseID3(bytes, at: 0)
            let frames = merge(existing?.frames ?? [], title: title, artist: artist, albumArtist: albumArtist)
            let audioStart = existing?.end ?? 0
            out = buildID3(major: existing?.major ?? 3, frames: frames) + bytes[audioStart...]
        }
        try Data(out).write(to: url, options: .atomic)
    }
}

// MARK: - Structures

private struct Frame {
    let id: String
    let flags: [UInt8]     // 2 octets d'en-tête, recopiés tels quels
    let payload: [UInt8]
}

private struct ID3Block {
    let major: UInt8
    let frames: [Frame]
    let end: Int           // offset de fin du tag dans le fichier
}

private func isWAV(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "wav"
}

// MARK: - ID3v2

private func parseID3(_ bytes: [UInt8], at offset: Int) throws -> ID3Block? {
    guard bytes.count >= offset + 10, Array(bytes[offset..<offset + 3]) == Array("ID3".utf8) else {
        return nil
    }
    let major = bytes[offset + 3]
    let flags = bytes[offset + 5]
    guard major == 3 || major == 4 else {
        throw TagError.unreadable("Version ID3v2.\(major) non prise en charge")
    }
    guard flags & 0x80 == 0 else {
        throw TagError.unreadable("Tag ID3 non synchronisé : non pris en charge")
    }
    let size = synchsafe(bytes, offset + 6)
    let bodyStart = offset + 10
    let bodyEnd = bodyStart + size
    guard bodyEnd <= bytes.count else { throw TagError.unreadable("Tag ID3 tronqué") }

    var frames: [Frame] = []
    var pos = bodyStart
    while pos + 10 <= bodyEnd {
        if bytes[pos] == 0 { break }                        // padding
        let id = String(decoding: bytes[pos..<pos + 4], as: UTF8.self)
        let frameSize = major == 4 ? synchsafe(bytes, pos + 4) : bigEndian32(bytes, pos + 4)
        let dataStart = pos + 10
        guard dataStart + frameSize <= bodyEnd else { throw TagError.unreadable("Frame \(id) tronquée") }
        frames.append(Frame(id: id, flags: Array(bytes[pos + 8..<pos + 10]),
                            payload: Array(bytes[dataStart..<dataStart + frameSize])))
        pos = dataStart + frameSize
    }
    return ID3Block(major: major, frames: frames, end: bodyEnd)
}

private func buildID3(major: UInt8, frames: [Frame]) -> [UInt8] {
    var body: [UInt8] = []
    for frame in frames {
        body += Array(frame.id.utf8)
        body += major == 4 ? synchsafeBytes(frame.payload.count) : bigEndianBytes(frame.payload.count)
        body += frame.flags
        body += frame.payload
    }
    return Array("ID3".utf8) + [major, 0, 0] + synchsafeBytes(body.count) + body
}

private func merge(_ frames: [Frame], title: String, artist: String, albumArtist: String) -> [Frame] {
    let replaced: Set<String> = ["TIT2", "TPE1", "TPE2"]
    var out = frames.filter { !replaced.contains($0.id) }
    out.append(Frame(id: "TIT2", flags: [0, 0], payload: encodeText(title)))
    out.append(Frame(id: "TPE1", flags: [0, 0], payload: encodeText(artist)))
    out.append(Frame(id: "TPE2", flags: [0, 0], payload: encodeText(albumArtist)))
    return out
}

private func textFrame(_ id: String, in frames: [Frame]) -> String? {
    guard let frame = frames.first(where: { $0.id == id }), let encoding = frame.payload.first else {
        return nil
    }
    let body = Data(frame.payload.dropFirst())
    let stringEncoding: String.Encoding
    switch encoding {
    case 0: stringEncoding = .isoLatin1
    case 1: stringEncoding = .utf16          // avec BOM
    case 2: stringEncoding = .utf16BigEndian
    case 3: stringEncoding = .utf8
    default: return nil
    }
    guard let text = String(data: body, encoding: stringEncoding) else { return nil }
    let first = text.components(separatedBy: "\u{0}").first?.trimmed ?? ""
    return first.isEmpty ? nil : first
}

/// Encodage UTF-16 avec BOM : valide en ID3v2.3 comme en ID3v2.4, et lu par Rekordbox.
private func encodeText(_ value: String) -> [UInt8] {
    var out: [UInt8] = [1, 0xFF, 0xFE]
    for unit in value.utf16 {
        out.append(UInt8(unit & 0xFF))
        out.append(UInt8(unit >> 8))
    }
    out += [0, 0]
    return out
}

// MARK: - WAV

private func wavChunks(_ bytes: [UInt8]) throws -> [(id: String, data: [UInt8])] {
    guard bytes.count >= 12,
          String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
          String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else {
        throw TagError.unreadable("Fichier WAV invalide")
    }
    var chunks: [(id: String, data: [UInt8])] = []
    var pos = 12
    while pos + 8 <= bytes.count {
        let id = String(decoding: bytes[pos..<pos + 4], as: UTF8.self)
        let size = littleEndian32(bytes, pos + 4)
        let start = pos + 8
        guard start + size <= bytes.count else { throw TagError.unreadable("Chunk \(id) tronqué") }
        chunks.append((id, Array(bytes[start..<start + size])))
        pos = start + size + (size % 2)      // les chunks sont alignés sur 2 octets
    }
    return chunks
}

private func wavID3(_ bytes: [UInt8]) throws -> ID3Block? {
    guard let chunk = try wavChunks(bytes).first(where: { $0.id.lowercased() == "id3 " }) else {
        return nil
    }
    return try parseID3(chunk.data, at: 0)
}

private func rebuildWAV(_ bytes: [UInt8], frames: [Frame], major: UInt8) throws -> [UInt8] {
    var body = Array("WAVE".utf8)
    for chunk in try wavChunks(bytes) where chunk.id.lowercased() != "id3 " {
        body += riffChunk(chunk.id, chunk.data)
    }
    body += riffChunk("id3 ", buildID3(major: major, frames: frames))
    return Array("RIFF".utf8) + littleEndianBytes(body.count) + body
}

private func riffChunk(_ id: String, _ data: [UInt8]) -> [UInt8] {
    var out = Array(id.utf8) + littleEndianBytes(data.count) + data
    if data.count % 2 == 1 { out.append(0) }
    return out
}

// MARK: - Entiers

private func synchsafe(_ b: [UInt8], _ i: Int) -> Int {
    (Int(b[i] & 0x7F) << 21) | (Int(b[i + 1] & 0x7F) << 14) | (Int(b[i + 2] & 0x7F) << 7) | Int(b[i + 3] & 0x7F)
}

private func synchsafeBytes(_ n: Int) -> [UInt8] {
    [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
}

private func bigEndian32(_ b: [UInt8], _ i: Int) -> Int {
    (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
}

private func bigEndianBytes(_ n: Int) -> [UInt8] {
    [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
}

private func littleEndian32(_ b: [UInt8], _ i: Int) -> Int {
    Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
}

private func littleEndianBytes(_ n: Int) -> [UInt8] {
    [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]
}
