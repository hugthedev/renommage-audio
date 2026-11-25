import XCTest
@testable import AudioRenamerCore

final class NameParserTests: XCTestCase {

    private func name(_ stem: String, tag: String? = nil) -> String? {
        analyse(stem: stem, tagArtist: tag).formattedStem()
    }

    func testStandardFormatKeepsOrderAndAttribute() {
        XCTAssertEqual(name("David Guetta - Titanium (Extended Mix)"),
                       "David Guetta - Titanium (Extended Mix)")
    }

    func testInversionOnlyWithMatchingTag() {
        let r = analyse(stem: "Titanium - David Guetta (Extended Mix)", tagArtist: "David Guetta")
        XCTAssertTrue(r.inverted)
        XCTAssertEqual(r.formattedStem(), "David Guetta - Titanium (Extended Mix)")
        XCTAssertFalse(analyse(stem: "Titanium - David Guetta (Extended Mix)", tagArtist: nil).inverted)
    }

    func testCleaningRemovesBracketsBpmAndTechnicalGroups() {
        XCTAssertEqual(name("Hugel - Track [CLEAN] 128 BPM (320k) (WAV)"),
                       "Hugel - Track (Radio Edit)")
    }

    func testNonAttributeParenthesesStayInArtist() {
        XCTAssertEqual(name("David Guetta (Fr) - Titanium (Extended Mix)"),
                       "David Guetta (Fr) - Titanium (Extended Mix)")
    }

    func testProtectedAttributesKeptVerbatim() {
        XCTAssertEqual(name("Hugel - Track Name (Intro - Clean)"), "Hugel - Track Name (Intro - Clean)")
        XCTAssertEqual(name("Hugel - Track Name (Intro Dirty)"), "Hugel - Track Name (Intro Dirty)")
        XCTAssertEqual(name("David Penn - The Night (Extended Mix By Fuvi Clan)"),
                       "David Penn - The Night (Extended Mix By Fuvi Clan)")
    }

    func testAttributesMergedKeepingProtectedIntact() {
        XCTAssertEqual(name("Hugel - Track (Hugel Remix) (Extended Mix)"),
                       "Hugel - Track (Hugel Remix Extended Mix)")
    }

    func testIntroNeverMerged() {
        XCTAssertEqual(analyse(stem: "Hugel - Song (Intro - Clean) (Extended Mix)", tagArtist: nil).status, .probable)
    }

    func testDefaultAttribute() {
        let r = analyse(stem: "Hugel - Track Name", tagArtist: nil)
        XCTAssertEqual(r.attribute, "Radio Edit")
        XCTAssertTrue(r.attributeIsDefault)
    }

    func testTitleParenthesesKept() {
        let r = analyse(stem: "Ethnica - Ethnica (Pasilda) (Extended Mix)", tagArtist: nil)
        XCTAssertEqual(r.title, "Ethnica (Pasilda)")
        XCTAssertEqual(r.attribute, "Extended Mix")
    }

    func testFeatBecomesTwoArtists() {
        XCTAssertEqual(analyse(stem: "Black Eyed Peas feat. Sia - Pump It (Original Mix)", tagArtist: nil).artists,
                       ["Black Eyed Peas", "Sia"])
    }

    func testThreeArtistsNeedVerification() {
        XCTAssertEqual(analyse(stem: "A, B, C - Song (Radio Edit)", tagArtist: nil).status, .probable)
    }

    func testCompactSeparator() {
        XCTAssertEqual(name("Hugel_s_Track Name"), "Hugel - Track Name (Radio Edit)")
    }

    func testCompactWithoutTitleNeedsVerification() {
        let r = analyse(stem: "David_Penn_Extended_Remix", tagArtist: nil)
        XCTAssertEqual(r.status, .probable)
        XCTAssertEqual(r.artists, ["David Penn"])
    }

    func testUnparseableIsIncertain() {
        XCTAssertEqual(analyse(stem: "Random text without separator", tagArtist: nil).status, .incertain)
    }

    func testTrailingNumberFlaggedNotRemoved() {
        let r = analyse(stem: "Hugel - Track 128", tagArtist: nil)
        XCTAssertEqual(r.status, .probable)
        XCTAssertTrue(r.title.contains("128"))
    }

    func testDuplicateAttributesDeduplicated() {
        XCTAssertEqual(name("Artist A - Song (Edit) (Edit)"), "Artist A - Song (Edit)")
    }

    func testArtistSharingLongWordDropped() {
        XCTAssertEqual(analyse(stem: "David Guetta & Guetta Remix - Titanium", tagArtist: nil).artists,
                       ["David Guetta"])
    }

    func testCapitalisation() {
        XCTAssertEqual(capitalizeWords("BLACK EYED peas"), "BLACK EYED Peas")
        XCTAssertEqual(name("black eyed peas - pump it (original mix)"),
                       "Black Eyed Peas - Pump It (Original Mix)")
    }
}

final class TaggerRoundTripTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testMp3TagsWrittenAndReadBack() throws {
        let url = try tempDir().appendingPathComponent("song.mp3")
        // Données audio factices : suffisent pour tester l'écriture des tags.
        try Data(repeating: 0xAB, count: 300).write(to: url)
        try Tagger.write(url, title: "Titanium (Extended Mix)", artist: "David Guetta", albumArtist: "David Guetta")
        let tags = try Tagger.read(url)
        XCTAssertEqual(tags.title, "Titanium (Extended Mix)")
        XCTAssertEqual(tags.artist, "David Guetta")
        XCTAssertEqual(tags.albumArtist, "David Guetta")
    }

    func testAudioBytesUnchangedAfterTagWrite() throws {
        let url = try tempDir().appendingPathComponent("song.mp3")
        let audio = Data(repeating: 0x5A, count: 300)
        try audio.write(to: url)
        try Tagger.write(url, title: "A", artist: "B", albumArtist: "B")
        try Tagger.write(url, title: "C", artist: "D", albumArtist: "D")   // deuxième écriture
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(Array(bytes.suffix(300)), [UInt8](audio))
        XCTAssertEqual(try Tagger.read(url).title, "C")
    }

    func testWavTagsWrittenAndReadBack() throws {
        let url = try tempDir().appendingPathComponent("song.wav")
        try makeMinimalWav().write(to: url)
        try Tagger.write(url, title: "Track Name (Radio Edit)", artist: "Hugel", albumArtist: "Hugel")
        let tags = try Tagger.read(url)
        XCTAssertEqual(tags.title, "Track Name (Radio Edit)")
        XCTAssertEqual(tags.artist, "Hugel")
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(String(decoding: bytes[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: bytes[8..<12], as: UTF8.self), "WAVE")
    }

    private func makeMinimalWav() -> Data {
        var body = Data("WAVE".utf8)
        var fmt = Data()
        fmt.append(contentsOf: [1, 0, 1, 0])                 // PCM, mono
        fmt.append(contentsOf: [0x40, 0x1F, 0, 0])           // 8000 Hz
        fmt.append(contentsOf: [0x80, 0x3E, 0, 0])           // octets/s
        fmt.append(contentsOf: [2, 0, 16, 0])                // alignement, 16 bits
        body += Data("fmt ".utf8) + Data([16, 0, 0, 0]) + fmt
        let samples = Data(repeating: 0, count: 200)
        body += Data("data".utf8) + Data([200, 0, 0, 0]) + samples
        var riff = Data("RIFF".utf8)
        riff.append(contentsOf: withUnsafeBytes(of: UInt32(body.count).littleEndian) { Array($0) })
        return riff + body
    }
}
