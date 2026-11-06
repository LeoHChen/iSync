import SQLite3
import XCTest
@testable import iSyncCore

/// Builds small databases shaped like the ones on an iPhone.
private func makeDatabase(at url: URL, _ sql: String) throws {
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    var error: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
        XCTFail(String(cString: error!))
    }
}

final class PhoneLibraryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func photosDB(_ name: String, rows: [String]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var sql = """
        CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZDIRECTORY TEXT, ZFILENAME TEXT, ZKIND INT, ZKINDSUBTYPE INT, ZTRASHEDSTATE INT);
        CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZASSET INT, ZORIGINALFILESIZE INT, ZORIGINALWIDTH INT, ZORIGINALHEIGHT INT, ZEXIFTIMESTAMPSTRING TEXT, ZORIGINALSTABLEHASH TEXT, ZORIGINALFILENAME TEXT);
        """
        sql += rows.joined()
        try makeDatabase(at: url, sql)
        return url
    }

    private func row(_ id: Int, dir: String = "DCIM/100APPLE", file: String, kind: Int = 0, subtype: Int = 0, trashed: Int = 0,
                     size: Int = 100, w: Int = 4032, h: Int = 3024, date: String = "2026:11:02 19:33:25", stable: String? = nil) -> String {
        let s = stable.map { "'\($0)'" } ?? "NULL"
        return """
        INSERT INTO ZASSET VALUES (\(id), '\(dir)', '\(file)', \(kind), \(subtype), \(trashed));
        INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (\(id), \(id), \(size), \(w), \(h), '\(date)', \(s), '\(file)');
        """
    }

    func testReadsAssets() throws {
        let index = try PhoneLibraryIndex.read(database: photosDB("a.sqlite", rows: [row(1, file: "IMG_1.HEIC", subtype: 2)]))
        let a = try XCTUnwrap(index.assets.first)
        XCTAssertEqual(a.remotePath, "/DCIM/100APPLE/IMG_1.HEIC")
        XCTAssertEqual(a.fingerprint.capture, "20261102193325")
        XCTAssertEqual(a.fingerprint.size, 100)
        XCTAssertTrue(a.isLivePhoto)
    }

    func testTrashedAndSharedAlbumAssetsAreLeftOut() throws {
        let index = try PhoneLibraryIndex.read(database: photosDB("a.sqlite", rows: [
            row(1, file: "KEEP.HEIC"),
            row(2, file: "TRASHED.HEIC", trashed: 1),
            row(3, dir: "PhotoData/PhotoCloudSharingData/x", file: "SHARED.HEIC"),
        ]))
        XCTAssertEqual(index.assets.map(\.remotePath), ["/DCIM/100APPLE/KEEP.HEIC"])
    }

    func testUnrecognizedDatabaseIsAClearError() throws {
        let url = dir.appendingPathComponent("odd.sqlite")
        try makeDatabase(at: url, "CREATE TABLE ZASSET (Z_PK INTEGER); CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER);")
        XCTAssertThrowsError(try PhoneLibraryIndex.read(database: url)) {
            XCTAssertTrue($0.localizedDescription.contains("doesn't recognize"))
        }
    }

    func testSamePhotoWithDifferentNamesCountsAsOnTheDestination() throws {
        // IMG_ numbers differ between phones. Content decides.
        let a = try PhoneLibraryIndex.read(database: photosDB("a.sqlite", rows: [row(1, file: "IMG_0001.HEIC")]))
        let b = try PhoneLibraryIndex.read(database: photosDB("b.sqlite", rows: [row(1, dir: "DCIM/120APPLE", file: "IMG_7777.HEIC")]))
        let c = PhoneComparer.compare(source: a, destination: b)
        XCTAssertEqual(c.alreadyOnDestination.files, 1)
        XCTAssertEqual(c.new.files, 0)
        XCTAssertEqual(c.candidates.first?.destination, "/DCIM/120APPLE/IMG_7777.HEIC")
    }

    func testSameNameDifferentPhotoIsNew() throws {
        let a = try PhoneLibraryIndex.read(database: photosDB("a.sqlite", rows: [row(1, file: "IMG_0001.HEIC", date: "2026:11:02 19:33:25")]))
        let b = try PhoneLibraryIndex.read(database: photosDB("b.sqlite", rows: [row(1, file: "IMG_0001.HEIC", size: 500, date: "2020:01:01 00:00:00")]))
        let c = PhoneComparer.compare(source: a, destination: b)
        XCTAssertEqual(c.new.files, 1)
        XCTAssertEqual(c.alreadyOnDestination.files, 0)
    }

    func testConvertedCopyIsAPossibleDuplicate() throws {
        let a = try PhoneLibraryIndex.read(database: photosDB("a.sqlite", rows: [row(1, file: "IMG_1.HEIC", size: 100)]))
        let b = try PhoneLibraryIndex.read(database: photosDB("b.sqlite", rows: [row(1, file: "IMG_9.JPG", size: 60)]))
        let c = PhoneComparer.compare(source: a, destination: b)
        XCTAssertEqual(c.possibleDuplicates.files, 1)
        XCTAssertEqual(c.alreadyOnDestination.files, 0)
    }

    func testStableHashMatchCountsEvenWhenDetailsDiffer() throws {
        let a = try PhoneLibraryIndex.read(database: photosDB("a.sqlite", rows: [row(1, file: "IMG_1.HEIC", size: 100, stable: "XYZ")]))
        let b = try PhoneLibraryIndex.read(database: photosDB("b.sqlite", rows: [row(1, file: "IMG_9.HEIC", size: 100, date: "2020:01:01 00:00:00", stable: "XYZ")]))
        XCTAssertEqual(PhoneComparer.compare(source: a, destination: b).alreadyOnDestination.files, 1)
    }

    func testBytesIncludeALivePhotosVideo() throws {
        let a = try PhoneLibraryIndex.read(database: photosDB("a.sqlite", rows: [row(1, file: "IMG_1.HEIC", subtype: 2, size: 100)]))
        let b = PhoneLibraryIndex(assets: [])
        let files = [RemoteFile(path: "/DCIM/100APPLE/IMG_1.HEIC", size: 100, modifiedNs: 0),
                     RemoteFile(path: "/DCIM/100APPLE/IMG_1.MOV", size: 900, modifiedNs: 0)]
        let c = PhoneComparer.compare(source: a, destination: b, sourceFiles: files)
        XCTAssertEqual(c.new.files, 1)
        XCTAssertEqual(c.new.bytes, 1000)
    }

    func testFingerprintsFeedThePlanner() throws {
        let index = try PhoneLibraryIndex.read(database: photosDB("a.sqlite", rows: [row(1, file: "IMG_1.HEIC")]))
        XCTAssertEqual(index.fingerprints["/DCIM/100APPLE/IMG_1.HEIC"]?.capture, "20261102193325")
    }
}

final class MusicTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func library() throws -> [MusicTrack] {
        let url = dir.appendingPathComponent("MediaLibrary.sqlitedb")
        try makeDatabase(at: url, """
        CREATE TABLE item (item_pid INTEGER PRIMARY KEY, media_type INT, track_number INT, disc_number INT, base_location_id INT, item_artist_pid INT, album_pid INT, album_artist_pid INT);
        CREATE TABLE item_extra (item_pid INTEGER PRIMARY KEY, title TEXT, total_time_ms REAL, location TEXT, file_size INT);
        CREATE TABLE item_store (item_pid INTEGER PRIMARY KEY, is_protected INT, key_id INT, is_subscription INT);
        CREATE TABLE base_location (base_location_id INTEGER PRIMARY KEY, path TEXT);
        CREATE TABLE item_artist (item_artist_pid INTEGER PRIMARY KEY, item_artist TEXT);
        CREATE TABLE album (album_pid INTEGER PRIMARY KEY, album TEXT);
        CREATE TABLE album_artist (album_artist_pid INTEGER PRIMARY KEY, album_artist TEXT);
        INSERT INTO base_location VALUES (1, 'iTunes_Control/Music/F00'), (2, 'Music/Downloads');
        INSERT INTO item_artist VALUES (1, 'Band');
        INSERT INTO album VALUES (1, 'Record');
        INSERT INTO album_artist VALUES (1, 'Band');
        INSERT INTO item VALUES (1, 8, 3, 1, 1, 1, 1, 1), (2, 8, 4, 1, 1, 1, 1, 1), (3, 8, 5, 1, 1, 1, 1, 1),
                                (4, 8, 6, 1, 2, 1, 1, 1), (5, 8, 7, 1, 0, 1, 1, 1), (6, 8, 8, 1, 1, 1, 1, 1), (7, 4, 1, 1, 1, 1, 1, 1);
        INSERT INTO item_extra VALUES (1, 'Plain', 1000, 'AAAA.mp3', 10), (2, 'Marked', 1000, 'BBBB.m4a', 20), (3, 'Keyed', 1000, 'CCCC.m4a', 30),
                                      (4, 'Apple Music', 1000, 'DDDD.m4a', 40), (5, 'Cloud Only', 1000, '', 0), (6, 'Flagged', 1000, 'EEEE.mp3', 60), (7, 'Not Music', 1000, 'FFFF.mp4', 70);
        INSERT INTO item_store VALUES (1, 0, 0, 0), (2, 1, 0, 0), (3, 0, 77, 0), (4, 0, 0, 0), (5, 0, 0, 0), (6, 0, 0, 1), (7, 0, 0, 0);
        """)
        return try MusicLibrary.read(database: url)
    }

    private func track(_ tracks: [MusicTrack], _ title: String) throws -> MusicTrack {
        try XCTUnwrap(tracks.first { $0.title == title })
    }

    func testReadsTrackDetails() throws {
        let t = try track(library(), "Plain")
        XCTAssertEqual(t.artist, "Band")
        XCTAssertEqual(t.album, "Record")
        XCTAssertEqual(t.trackNumber, 3)
        XCTAssertEqual(t.durationMs, 1000)
        XCTAssertEqual(t.remotePath, "/iTunes_Control/Music/F00/AAAA.mp3")
        XCTAssertEqual(t.status, .copyable)
    }

    func testOnlyMusicIsListed() throws {
        XCTAssertNil(try library().first { $0.title == "Not Music" })
    }

    func testProtectedTracksAreFlagged() throws {
        let t = try library()
        if case .protected = try track(t, "Marked").status {} else { XCTFail("is_protected") }
        if case .protected = try track(t, "Keyed").status {} else { XCTFail("key_id") }
        if case .protected = try track(t, "Apple Music").status {} else { XCTFail("location") }
    }

    func testTrackThatIsNotOnThePhoneIsFlagged() throws {
        XCTAssertEqual(try track(library(), "Cloud Only").status, .notOnIPhone)
    }

    func testSubscriptionFlagAloneDoesNotBlockAPlainFile() throws {
        // Real library: these are ordinary MP3s, with no DRM in the file.
        let t = try track(library(), "Flagged")
        XCTAssertEqual(t.status, .copyable)
        XCTAssertTrue(t.subscriptionFlag)
    }

    func testSummaryCounts() throws {
        let s = MusicSummary(try library())
        XCTAssertEqual(s.total, 6)
        XCTAssertEqual(s.copyable, 2)
        XCTAssertEqual(s.protected, 3)
        XCTAssertEqual(s.notOnIPhone, 1)
        XCTAssertEqual(s.subscriptionFlagged, 1)
        XCTAssertEqual(s.copyableBytes, 70)
    }

    private func t(_ title: String = "Song", artist: String? = "Band", albumArtist: String? = nil, album: String? = "Record",
                   track: Int = 3, disc: Int = 1, path: String = "/iTunes_Control/Music/F00/A.mp3", size: Int64 = 10,
                   status: MusicTrack.Status = .copyable) -> MusicTrack {
        MusicTrack(id: 1, title: title, artist: artist, albumArtist: albumArtist, album: album, trackNumber: track, discNumber: disc,
                   durationMs: 1, remotePath: path, size: size, modifiedNs: 1_700_000_000_000_000_000, status: status, subscriptionFlag: false)
    }

    func testLayout() {
        XCTAssertEqual(MusicPlanner.relativePath(for: t()), "Band/Record/03 Song.mp3")
    }

    func testAlbumArtistWinsSoCompilationsStayTogether() {
        XCTAssertEqual(MusicPlanner.relativePath(for: t(artist: "Guest", albumArtist: "Various Artists")), "Various Artists/Record/03 Song.mp3")
    }

    func testSecondDiscAndMissingDetails() {
        XCTAssertEqual(MusicPlanner.relativePath(for: t(disc: 2)), "Band/Record/2-03 Song.mp3")
        XCTAssertEqual(MusicPlanner.relativePath(for: t(artist: nil, album: nil, track: 0)), "Unknown Artist/Unknown Album/Song.mp3")
    }

    func testUnsafeCharactersCannotEscapeTheFolder() {
        let path = MusicPlanner.relativePath(for: t("../../evil: part/2", artist: "A/C D", album: "..."))
        // ".." inside a name is harmless once "/" is gone. As a whole folder name it isn't.
        XCTAssertFalse(path.split(separator: "/").contains { $0 == ".." || $0 == "." })
        XCTAssertEqual(path.split(separator: "/").count, 3)
        XCTAssertTrue(path.hasPrefix("A-C D/Unknown Album/"))
    }

    func testProtectedTracksAreNeverPlanned() {
        let p = MusicPlanner.plan(tracks: [t(status: .protected("x")), t(status: .notOnIPhone)], destination: dir, manifest: CopyManifest(deviceKey: "k"), policy: .overwrite)
        XCTAssertEqual(p.plan.toCopyFiles, 0)
        XCTAssertEqual(p.plan.totalFiles, 0)
    }

    func testRepeatRunSkipsAndOverwriteRecopies() throws {
        let track = t()
        let url = dir.appendingPathComponent("Band/Record/03 Song.mp3")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10).write(to: url)
        var m = CopyManifest(deviceKey: "k")
        m.record(track.remoteFile!, localPath: "Band/Record/03 Song.mp3")
        let skip = MusicPlanner.plan(tracks: [track], destination: dir, manifest: m, policy: .skipDuplicates)
        XCTAssertEqual(skip.plan.toCopyFiles, 0)
        XCTAssertEqual(skip.alreadyCopied.files, 1)
        let over = MusicPlanner.plan(tracks: [track], destination: dir, manifest: m, policy: .overwrite)
        XCTAssertEqual(over.plan.replaceFiles, 1)
    }

    func testDifferentFileWithTheSameNameIsKeptUnderSkipAndReplacedUnderOverwrite() throws {
        let url = dir.appendingPathComponent("Band/Record/03 Song.mp3")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 99).write(to: url)
        let m = CopyManifest(deviceKey: "k")
        let skip = MusicPlanner.plan(tracks: [t()], destination: dir, manifest: m, policy: .skipDuplicates)
        XCTAssertEqual(skip.plan.toCopy.first?.files.first?.localPath, "Band/Record/03 Song (2).mp3")
        XCTAssertEqual(skip.sameNameDifferent.files, 1)
        let over = MusicPlanner.plan(tracks: [t()], destination: dir, manifest: m, policy: .overwrite)
        XCTAssertEqual(over.plan.toCopy.first?.files.first?.localPath, "Band/Record/03 Song.mp3")
        XCTAssertEqual(over.plan.replaceFiles, 1)
    }

    func testTwoTracksWithTheSameNameBothGetCopied() {
        let a = t(path: "/iTunes_Control/Music/F00/A.mp3"), b = t(path: "/iTunes_Control/Music/F01/B.mp3")
        let p = MusicPlanner.plan(tracks: [a, b], destination: dir, manifest: CopyManifest(deviceKey: "k"), policy: .skipDuplicates)
        XCTAssertEqual(Set(p.plan.toCopy.flatMap { $0.files.map(\.localPath) }), ["Band/Record/03 Song.mp3", "Band/Record/03 Song (2).mp3"])
    }
}
