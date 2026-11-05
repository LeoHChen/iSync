import XCTest
@testable import iSyncCore

final class GroupingTests: XCTestCase {
    private func f(_ path: String, size: Int64 = 10, at seconds: Int64 = 1000) -> RemoteFile {
        RemoteFile(path: path, size: size, modifiedNs: seconds * 1_000_000_000)
    }

    func testLivePhotoPairStaysTogetherWithStillFirst() {
        let groups = PhotoGrouping.groups(from: [f("/DCIM/100APPLE/IMG_1.MOV"), f("/DCIM/100APPLE/IMG_1.HEIC")])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isLivePhoto)
        XCTAssertEqual(groups[0].files.map(\.path), ["/DCIM/100APPLE/IMG_1.HEIC", "/DCIM/100APPLE/IMG_1.MOV"])
    }

    func testSidecarJoinsItsGroup() {
        let groups = PhotoGrouping.groups(from: [
            f("/DCIM/100APPLE/IMG_1.AAE"), f("/DCIM/100APPLE/IMG_1.MOV"), f("/DCIM/100APPLE/IMG_1.HEIC"),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.last?.path, "/DCIM/100APPLE/IMG_1.AAE")
    }

    func testSameNameInAnotherFolderIsSeparate() {
        let groups = PhotoGrouping.groups(from: [f("/DCIM/100APPLE/IMG_1.HEIC"), f("/DCIM/101APPLE/IMG_1.MOV")])
        XCTAssertEqual(groups.count, 2)
        XCTAssertFalse(groups[0].isLivePhoto)
    }

    func testPairingIgnoresExtensionCase() {
        let groups = PhotoGrouping.groups(from: [f("/DCIM/100APPLE/IMG_1.heic"), f("/DCIM/100APPLE/IMG_1.MOV")])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isLivePhoto)
    }

    func testPlainVideoIsNotALivePhoto() {
        let groups = PhotoGrouping.groups(from: [f("/DCIM/100APPLE/IMG_1.MOV")])
        XCTAssertFalse(groups[0].isLivePhoto)
    }

    func testNewestGroupComesFirst() {
        let groups = PhotoGrouping.groups(from: [f("/DCIM/100APPLE/OLD.HEIC", at: 1), f("/DCIM/100APPLE/NEW.HEIC", at: 9)])
        XCTAssertEqual(groups.map(\.baseName), ["NEW", "OLD"])
    }
}

final class ManifestTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTrip() throws {
        var m = CopyManifest(deviceKey: "abc")
        m.record(RemoteFile(path: "/DCIM/100APPLE/A.HEIC", size: 5, modifiedNs: 7), localPath: "DCIM/100APPLE/A.HEIC")
        try m.save(destination: dir)
        XCTAssertEqual(CopyManifest.load(destination: dir, deviceKey: "abc"), m)
    }

    func testMissingManifestStartsEmpty() {
        XCTAssertTrue(CopyManifest.load(destination: dir, deviceKey: "abc").entries.isEmpty)
    }

    func testCorruptManifestStartsEmpty() throws {
        let url = CopyManifest.url(destination: dir, deviceKey: "abc")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(CopyManifest.load(destination: dir, deviceKey: "abc").entries.isEmpty)
    }

    func testEachPhoneHasItsOwnManifest() throws {
        var m = CopyManifest(deviceKey: "one")
        m.record(RemoteFile(path: "/DCIM/A", size: 1, modifiedNs: 1), localPath: "A")
        try m.save(destination: dir)
        XCTAssertTrue(CopyManifest.load(destination: dir, deviceKey: "two").entries.isEmpty)
    }

    func testDeviceKeyHidesTheUDID() {
        let key = deviceKey(udid: "00000000-0000000000000000")
        XCTAssertFalse(key.contains("0000000000"))
        XCTAssertEqual(key, deviceKey(udid: "00000000-0000000000000000"))
    }
}

final class PlannerTests: XCTestCase {
    private var dir: URL!
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func f(_ path: String, size: Int64 = 4, at seconds: Int64 = 1_700_000_000) -> RemoteFile {
        RemoteFile(path: path, size: size, modifiedNs: seconds * 1_000_000_000)
    }

    /// Puts a file on disk the way the engine would.
    private func place(_ file: RemoteFile, at rel: String) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: Int(file.size)).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: file.modified], ofItemAtPath: url.path)
    }

    private func plan(_ files: [RemoteFile], _ m: CopyManifest, _ layout: FolderLayout = .sameAsIPhone) -> CopyPlan {
        CopyPlanner.plan(files: files, destination: dir, manifest: m, layout: layout, calendar: utc)
    }

    private func allPlanned(_ p: CopyPlan) -> [String] {
        p.toCopy.flatMap { $0.files.map(\.localPath) }.sorted()
    }

    func testEmptyDestinationCopiesEverything() {
        let p = plan([f("/DCIM/100APPLE/A.HEIC"), f("/DCIM/100APPLE/B.HEIC")], CopyManifest(deviceKey: "k"))
        XCTAssertEqual(p.toCopyFiles, 2)
        XCTAssertEqual(p.toCopyBytes, 8)
        XCTAssertEqual(p.alreadyCopiedFiles, 0)
        XCTAssertEqual(allPlanned(p), ["DCIM/100APPLE/A.HEIC", "DCIM/100APPLE/B.HEIC"])
    }

    func testSecondRunCopiesNothing() throws {
        let a = f("/DCIM/100APPLE/A.HEIC")
        try place(a, at: "DCIM/100APPLE/A.HEIC")
        var m = CopyManifest(deviceKey: "k")
        m.record(a, localPath: "DCIM/100APPLE/A.HEIC")
        let p = plan([a], m)
        XCTAssertEqual(p.toCopyFiles, 0)
        XCTAssertEqual(p.alreadyCopiedFiles, 1)
        XCTAssertEqual(p.alreadyCopiedBytes, 4)
    }

    func testOnlyNewFilesAreCopied() throws {
        let a = f("/DCIM/100APPLE/A.HEIC"), b = f("/DCIM/100APPLE/B.HEIC")
        try place(a, at: "DCIM/100APPLE/A.HEIC")
        var m = CopyManifest(deviceKey: "k")
        m.record(a, localPath: "DCIM/100APPLE/A.HEIC")
        XCTAssertEqual(allPlanned(plan([a, b], m)), ["DCIM/100APPLE/B.HEIC"])
    }

    func testFileRemovedFromMacIsCopiedAgain() {
        let a = f("/DCIM/100APPLE/A.HEIC")
        var m = CopyManifest(deviceKey: "k")
        m.record(a, localPath: "DCIM/100APPLE/A.HEIC")
        XCTAssertEqual(allPlanned(plan([a], m)), ["DCIM/100APPLE/A.HEIC"])
    }

    func testChangedPhoneFileGetsNewNameAndOldCopyIsKept() throws {
        let old = f("/DCIM/100APPLE/A.HEIC", size: 4)
        try place(old, at: "DCIM/100APPLE/A.HEIC")
        var m = CopyManifest(deviceKey: "k")
        m.record(old, localPath: "DCIM/100APPLE/A.HEIC")
        let p = plan([f("/DCIM/100APPLE/A.HEIC", size: 9)], m)
        XCTAssertEqual(allPlanned(p), ["DCIM/100APPLE/A (2).HEIC"])
    }

    func testChangedDateOnlyIsTreatedAsChanged() throws {
        let old = f("/DCIM/100APPLE/A.HEIC", at: 1_000)
        try place(old, at: "DCIM/100APPLE/A.HEIC")
        var m = CopyManifest(deviceKey: "k")
        m.record(old, localPath: "DCIM/100APPLE/A.HEIC")
        XCTAssertEqual(allPlanned(plan([f("/DCIM/100APPLE/A.HEIC", at: 2_000)], m)), ["DCIM/100APPLE/A (2).HEIC"])
    }

    func testDifferentExistingFileIsNeverOverwritten() throws {
        try place(f("/x", size: 99), at: "DCIM/100APPLE/A.HEIC")
        let p = plan([f("/DCIM/100APPLE/A.HEIC", size: 4)], CopyManifest(deviceKey: "k"))
        XCTAssertEqual(allPlanned(p), ["DCIM/100APPLE/A (2).HEIC"])
    }

    func testLostManifestAdoptsMatchingFilesWithoutCopying() throws {
        let a = f("/DCIM/100APPLE/A.HEIC")
        try place(a, at: "DCIM/100APPLE/A.HEIC")
        let p = plan([a], CopyManifest(deviceKey: "k"))
        XCTAssertEqual(p.toCopyFiles, 0)
        XCTAssertEqual(p.adopted.map(\.localPath), ["DCIM/100APPLE/A.HEIC"])
        XCTAssertEqual(p.alreadyCopiedFiles, 1)
    }

    func testPairConflictNumbersBothFilesTheSame() throws {
        try place(f("/x", size: 99), at: "DCIM/100APPLE/A.MOV")
        let p = plan([f("/DCIM/100APPLE/A.HEIC"), f("/DCIM/100APPLE/A.MOV")], CopyManifest(deviceKey: "k"))
        XCTAssertEqual(allPlanned(p), ["DCIM/100APPLE/A (2).HEIC", "DCIM/100APPLE/A (2).MOV"])
    }

    func testRestOfPartlyCopiedPairGoesBesideIt() throws {
        let heic = f("/DCIM/100APPLE/A.HEIC"), mov = f("/DCIM/100APPLE/A.MOV")
        try place(heic, at: "2020/05/A.HEIC")
        var m = CopyManifest(deviceKey: "k")
        m.record(heic, localPath: "2020/05/A.HEIC")
        // Even after switching layout, the MOV follows its HEIC.
        XCTAssertEqual(allPlanned(plan([heic, mov], m, .sameAsIPhone)), ["2020/05/A.MOV"])
    }

    func testYearMonthLayoutUsesTheFileDate() {
        // 2023-11-14 UTC
        let p = plan([f("/DCIM/100APPLE/A.HEIC", at: 1_700_000_000)], CopyManifest(deviceKey: "k"), .yearMonth)
        XCTAssertEqual(allPlanned(p), ["2023/11/A.HEIC"])
    }

    func testYearMonthKeepsPairTogetherAcrossMonthEnd() {
        // The HEIC is on 31 Oct and the MOV on 1 Nov, UTC.
        let heic = f("/DCIM/100APPLE/A.HEIC", at: 1_698_796_799)
        let mov = f("/DCIM/100APPLE/A.MOV", at: 1_698_796_801)
        let p = plan([heic, mov], CopyManifest(deviceKey: "k"), .yearMonth)
        XCTAssertEqual(p.toCopy.count, 1)
        XCTAssertEqual(allPlanned(p), ["2023/10/A.HEIC", "2023/10/A.MOV"])
    }

    func testYearMonthSeparatesSameNameFromDifferentFolders() {
        let p = plan([f("/DCIM/100APPLE/A.HEIC"), f("/DCIM/101APPLE/A.HEIC", at: 1_700_000_100)],
                     CopyManifest(deviceKey: "k"), .yearMonth)
        XCTAssertEqual(allPlanned(p), ["2023/11/A (2).HEIC", "2023/11/A.HEIC"])
    }

    func testCaseDifferenceCountsAsSamePath() {
        // Mac volumes usually ignore case, so these can't share a name.
        let p = plan([f("/DCIM/100APPLE/A.HEIC", at: 2), f("/DCIM/101APPLE/a.heic", at: 1)],
                     CopyManifest(deviceKey: "k"), .yearMonth)
        XCTAssertEqual(Set(allPlanned(p).map { $0.lowercased() }).count, 2)
    }

    func testUnsafePathsAreSkipped() {
        let p = plan([f("/DCIM/../secret"), f("/PhotoData/x"), f("/DCIM/100APPLE/A.HEIC")], CopyManifest(deviceKey: "k"))
        XCTAssertEqual(p.skippedUnsafe, 2)
        XCTAssertEqual(allPlanned(p), ["DCIM/100APPLE/A.HEIC"])
    }

    func testLivePhotosAreCounted() {
        let p = plan([f("/DCIM/100APPLE/A.HEIC"), f("/DCIM/100APPLE/A.MOV"), f("/DCIM/100APPLE/B.HEIC")],
                     CopyManifest(deviceKey: "k"))
        XCTAssertEqual(p.livePhotosToCopy, 1)
    }
}
