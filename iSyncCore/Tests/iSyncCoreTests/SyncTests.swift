import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import iSyncCore

final class FingerprintTests: XCTestCase {
    func testEXIFAndQuickTimeDatesNormalizeTheSameWay() {
        XCTAssertEqual(CaptureDate.normalize("2026:11:02 19:33:25"), "20261102193325")
        XCTAssertEqual(CaptureDate.normalize("2026-11-02T19:33:25-0800"), "20261102193325")
        XCTAssertEqual(CaptureDate.normalize("2026-11-02T19:33:25.123-0800"), "20261102193325")
    }

    func testBlankDatesAreUnknown() {
        XCTAssertNil(CaptureDate.normalize(nil))
        XCTAssertNil(CaptureDate.normalize("0000:00:00 00:00:00"))
        XCTAssertNil(CaptureDate.normalize("2026"))
    }

    func testRotationDoesNotChangeDimensions() {
        // The database gives a video as 2160x3840, and the file gives 3840x2160.
        let a = MediaFingerprint(size: 5, capture: "20261102193325", width: 2160, height: 3840)
        let b = MediaFingerprint(size: 5, capture: "20261102193325", width: 3840, height: 2160)
        XCTAssertEqual(a.visualKey, b.visualKey)
        XCTAssertTrue(a.couldBeSameContent(as: b))
    }

    func testDifferentCaptureOrSizeRulesOutAMatch() {
        let a = MediaFingerprint(size: 5, capture: "20261102193325", width: 10, height: 20)
        XCTAssertFalse(a.couldBeSameContent(as: MediaFingerprint(size: 5, capture: "20261102193326", width: 10, height: 20)))
        XCTAssertFalse(a.couldBeSameContent(as: MediaFingerprint(size: 6, capture: "20261102193325", width: 10, height: 20)))
        XCTAssertFalse(a.couldBeSameContent(as: MediaFingerprint(size: 5, capture: "20261102193325", width: 11, height: 20)))
    }

    func testMissingDetailsLeaveTheDecisionToSHA256() {
        let a = MediaFingerprint(size: 5, capture: "20261102193325", width: 10, height: 20)
        XCTAssertTrue(a.couldBeSameContent(as: MediaFingerprint(size: 5)))
    }

    func testOldManifestStillLoads() throws {
        // The format version 0.1 writes: no hashes.
        let json = #"{"version":1,"deviceKey":"k","entries":{"/DCIM/A":{"size":3,"modifiedNs":7,"localPath":"DCIM/A"}}}"#
        let m = try JSONDecoder().decode(CopyManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.entries["/DCIM/A"]?.localPath, "DCIM/A")
        XCTAssertNil(m.entries["/DCIM/A"]?.sha256)
        XCTAssertNil(m.sourceHash(for: RemoteFile(path: "/DCIM/A", size: 3, modifiedNs: 7)))
    }

    func testSourceHashIsIgnoredOnceTheFileChanges() {
        var m = CopyManifest(deviceKey: "k")
        m.recordSourceHash(RemoteFile(path: "/DCIM/A", size: 3, modifiedNs: 7), sha256: "abc")
        XCTAssertEqual(m.sourceHash(for: RemoteFile(path: "/DCIM/A", size: 3, modifiedNs: 7)), "abc")
        XCTAssertNil(m.sourceHash(for: RemoteFile(path: "/DCIM/A", size: 4, modifiedNs: 7)))
        XCTAssertNil(m.sourceHash(for: RemoteFile(path: "/DCIM/A", size: 3, modifiedNs: 8)))
    }
}

final class SyncPlannerTests: XCTestCase {
    private var dest: URL!
    private let capture = "20231114221320"

    override func setUpWithError() throws {
        dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dest)
    }

    private func remote(_ path: String, size: Int64 = 100, at seconds: Int64 = 1_700_000_000) -> RemoteFile {
        RemoteFile(path: path, size: size, modifiedNs: seconds * 1_000_000_000)
    }

    private func print(size: Int64 = 100, capture: String? = nil, w: Int? = 4032, h: Int? = 3024) -> MediaFingerprint {
        MediaFingerprint(size: size, capture: capture ?? self.capture, width: w, height: h)
    }

    /// A file at the destination, as the index would report it.
    private func indexed(_ rel: String, size: Int64 = 100, print p: MediaFingerprint? = nil, sha: String? = nil, inFolder folder: URL? = nil, at seconds: Double = 1_000) throws -> IndexedFile {
        let root = folder ?? dest!
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: Int(size)).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
        return IndexedFile(path: canonicalPath(url), size: size, modified: seconds, fingerprint: p ?? print(size: size), sha256: sha)
    }

    private func preview(
        _ files: [RemoteFile], prints: [String: MediaFingerprint] = [:], manifest: CopyManifest? = nil,
        dest destFiles: [IndexedFile] = [], reference: [IndexedFile] = [], options: SyncOptions = SyncOptions()
    ) -> SyncPreview {
        SyncPlanner.preview(
            files: files, fingerprints: prints, destination: dest, manifest: manifest ?? CopyManifest(deviceKey: "k"),
            destinationFiles: destFiles, referenceFiles: reference, options: options)
    }

    private func planned(_ p: SyncPreview) -> [String] {
        p.plan.toCopy.flatMap { $0.files.map(\.localPath) }.sorted()
    }

    func testNewFileIsCopied() {
        let a = remote("/DCIM/100APPLE/A.HEIC")
        let p = preview([a], prints: [a.path: print()])
        XCTAssertEqual(p.tally(.new).files, 1)
        XCTAssertEqual(p.tally(.new).bytes, 100)
        XCTAssertEqual(planned(p), ["DCIM/100APPLE/A.HEIC"])
        XCTAssertFalse(p.needsVerification)
    }

    func testDifferentNameSameContentIsACandidateNotACopy() throws {
        // The user's case: the same photo, renamed on the other phone.
        let a = remote("/DCIM/100APPLE/IMG_0001.HEIC")
        let there = try indexed("old/IMG_9999.HEIC")
        let p = preview([a], prints: [a.path: print()], dest: [there])
        XCTAssertEqual(p.tally(.exactDuplicate).files, 1)
        XCTAssertEqual(p.plan.toCopyFiles, 0)
        XCTAssertEqual(p.unconfirmed.map(\.file), [a])
    }

    func testMatchingHashesConfirmTheDuplicate() throws {
        let a = remote("/DCIM/100APPLE/IMG_0001.HEIC")
        var m = CopyManifest(deviceKey: "k")
        m.recordSourceHash(a, sha256: "same")
        let there = try indexed("old/IMG_9999.HEIC", sha: "same")
        let p = preview([a], prints: [a.path: print()], manifest: m, dest: [there])
        XCTAssertEqual(p.tally(.exactDuplicate).files, 1)
        XCTAssertEqual(p.plan.toCopyFiles, 0)
        XCTAssertFalse(p.needsVerification)
        XCTAssertEqual(p.plan.adopted.map(\.localPath), ["old/IMG_9999.HEIC"])
    }

    func testDifferentHashesBecomeAPossibleDuplicateAndAreCopied() throws {
        // Identical size, time and dimensions but different bytes: must never be skipped.
        let a = remote("/DCIM/100APPLE/IMG_0001.HEIC")
        var m = CopyManifest(deviceKey: "k")
        m.recordSourceHash(a, sha256: "one")
        let there = try indexed("old/IMG_9999.HEIC", sha: "two")
        let p = preview([a], prints: [a.path: print()], manifest: m, dest: [there])
        XCTAssertEqual(p.tally(.exactDuplicate).files, 0)
        XCTAssertEqual(p.tally(.possibleDuplicate).files, 1)
        XCTAssertEqual(planned(p), ["DCIM/100APPLE/IMG_0001.HEIC"])
        XCTAssertEqual(p.possibleDuplicates.first?.willCopy, true)
    }

    func testEditedOrConvertedCopyIsAPossibleDuplicateAndIsCopied() throws {
        let a = remote("/DCIM/100APPLE/IMG_0001.HEIC", size: 100)
        let there = try indexed("old/converted.jpg", size: 70, print: print(size: 70))
        let p = preview([a], prints: [a.path: print(size: 100)], dest: [there])
        XCTAssertEqual(p.tally(.possibleDuplicate).files, 1)
        XCTAssertEqual(p.possibleDuplicates.first?.similarTo, there.path)
        XCTAssertEqual(p.plan.toCopyFiles, 1)
    }

    func testPossibleDuplicatesCanBeHeldBackButStayListed() throws {
        let a = remote("/DCIM/100APPLE/IMG_0001.HEIC", size: 100)
        let there = try indexed("old/converted.jpg", size: 70, print: print(size: 70))
        let p = preview([a], prints: [a.path: print(size: 100)], dest: [there], options: SyncOptions(copyPossibleDuplicates: false))
        XCTAssertEqual(p.plan.toCopyFiles, 0)
        XCTAssertEqual(p.tally(.possibleDuplicate).files, 1)
        XCTAssertEqual(p.possibleDuplicates.first?.willCopy, false)
    }

    func testFileIdenticalToAnotherFinishedCopyIsADuplicate() throws {
        // A was copied earlier. B is the same photo under another name on the phone.
        let a = remote("/DCIM/100APPLE/A.HEIC"), b = remote("/DCIM/101APPLE/B.HEIC")
        let there = try indexed("DCIM/100APPLE/A.HEIC", sha: "same", at: Double(a.modifiedNs) / 1e9)
        var m = CopyManifest(deviceKey: "k")
        m.record(a, localPath: "DCIM/100APPLE/A.HEIC", sha256: "same")
        m.recordSourceHash(b, sha256: "same")
        let p = preview([a, b], prints: [a.path: print(), b.path: print()], manifest: m, dest: [there])
        XCTAssertEqual(p.tally(.alreadyCopied).files, 1)
        XCTAssertEqual(p.tally(.exactDuplicate).files, 1)
        XCTAssertEqual(p.plan.toCopyFiles, 0)
    }

    func testAHashFromTheEngineMeansNoHashingOnTheNextPreview() throws {
        // First run copied A and hashed it. B is the same photo. Nothing should need reading again.
        let a = remote("/DCIM/100APPLE/A.HEIC"), b = remote("/DCIM/101APPLE/B.HEIC")
        let there = try indexed("DCIM/100APPLE/A.HEIC", at: Double(a.modifiedNs) / 1e9)
        var m = CopyManifest(deviceKey: "k")
        m.record(a, localPath: "DCIM/100APPLE/A.HEIC", sha256: "same")
        m.recordSourceHash(b, sha256: "same")
        let p = preview([a, b], prints: [a.path: print(), b.path: print()], manifest: m, dest: [there])
        XCTAssertFalse(p.needsVerification)
        XCTAssertEqual(p.tally(.exactDuplicate).files, 1)
    }

    func testSameContentTwiceOnThePhoneIsCopiedOnce() {
        let a = remote("/DCIM/100APPLE/A.HEIC"), b = remote("/DCIM/101APPLE/B.HEIC")
        var m = CopyManifest(deviceKey: "k")
        m.recordSourceHash(a, sha256: "same")
        m.recordSourceHash(b, sha256: "same")
        let p = preview([a, b], prints: [a.path: print(), b.path: print()], manifest: m)
        XCTAssertEqual(p.plan.toCopyFiles, 1)
        XCTAssertEqual(p.tally(.exactDuplicate).files, 1)
        XCTAssertFalse(p.needsVerification)
    }

    func testSimilarFilesOnThePhoneAreBothCopiedOnceHashesDiffer() {
        let a = remote("/DCIM/100APPLE/A.HEIC"), b = remote("/DCIM/101APPLE/B.HEIC")
        var m = CopyManifest(deviceKey: "k")
        m.recordSourceHash(a, sha256: "one")
        m.recordSourceHash(b, sha256: "two")
        let p = preview([a, b], prints: [a.path: print(), b.path: print()], manifest: m)
        XCTAssertEqual(p.plan.toCopyFiles, 2)
    }

    func testUnverifiedSameRunMatchIsHeldUntilHashed() {
        let a = remote("/DCIM/100APPLE/A.HEIC"), b = remote("/DCIM/101APPLE/B.HEIC")
        let p = preview([a, b], prints: [a.path: print(), b.path: print()])
        XCTAssertEqual(p.plan.toCopyFiles, 1)
        XCTAssertEqual(p.unconfirmed.count, 1)
    }

    func testReferenceFolderMatchSkipsTheCopyButNeverWritesThere() throws {
        let archive = dest.appendingPathComponent("../\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: archive) }
        let a = remote("/DCIM/100APPLE/IMG_1.HEIC")
        var m = CopyManifest(deviceKey: "k")
        m.recordSourceHash(a, sha256: "same")
        let there = try indexed("2019/holiday.heic", sha: "same", inFolder: archive)
        let p = preview([a], prints: [a.path: print()], manifest: m, reference: [there])
        XCTAssertEqual(p.tally(.exactDuplicate).files, 1)
        XCTAssertEqual(p.plan.toCopyFiles, 0)
        // Nothing to record: the manifest only tracks the destination.
        XCTAssertEqual(p.plan.adopted, [])
    }

    func testPairStaysTogetherWhenStillIsInAReferenceFolder() throws {
        let archive = dest.appendingPathComponent("../\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: archive) }
        let still = remote("/DCIM/100APPLE/IMG_1.HEIC"), video = remote("/DCIM/100APPLE/IMG_1.MOV", size: 500)
        var m = CopyManifest(deviceKey: "k")
        m.recordSourceHash(still, sha256: "same")
        let there = try indexed("2019/holiday.heic", sha: "same", inFolder: archive)
        let p = preview([still, video], prints: [still.path: print()], manifest: m, reference: [there])
        // Copying only the video would split the pair across folders.
        XCTAssertEqual(planned(p), ["DCIM/100APPLE/IMG_1.HEIC", "DCIM/100APPLE/IMG_1.MOV"])
        XCTAssertEqual(p.plan.toCopy.count, 1)
    }

    func testVideoLandsBesideAStillThatMatchedInTheDestination() throws {
        let still = remote("/DCIM/100APPLE/IMG_1.HEIC"), video = remote("/DCIM/100APPLE/IMG_1.MOV", size: 500)
        var m = CopyManifest(deviceKey: "k")
        m.recordSourceHash(still, sha256: "same")
        let there = try indexed("2019/holiday.heic", sha: "same")
        let p = preview([still, video], prints: [still.path: print()], manifest: m, dest: [there])
        XCTAssertEqual(planned(p), ["2019/holiday.MOV"])
    }

    func testSameNameDifferentContentKeepsBothUnderSkip() throws {
        let a = remote("/DCIM/100APPLE/IMG_1.HEIC")
        _ = try indexed("DCIM/100APPLE/IMG_1.HEIC", size: 999, print: print(size: 999, capture: "20200101000000"))
        let p = preview([a], prints: [a.path: print()])
        XCTAssertEqual(p.tally(.sameNameDifferent).files, 1)
        XCTAssertEqual(planned(p), ["DCIM/100APPLE/IMG_1 (2).HEIC"])
        XCTAssertEqual(p.plan.replaceFiles, 0)
    }

    func testSameNameDifferentContentIsReplacedUnderOverwrite() throws {
        let a = remote("/DCIM/100APPLE/IMG_1.HEIC")
        _ = try indexed("DCIM/100APPLE/IMG_1.HEIC", size: 999, print: print(size: 999, capture: "20200101000000"))
        let p = preview([a], prints: [a.path: print()], options: SyncOptions(policy: .overwrite))
        XCTAssertEqual(p.tally(.sameNameDifferent).files, 1)
        XCTAssertEqual(planned(p), ["DCIM/100APPLE/IMG_1.HEIC"])
        XCTAssertEqual(p.plan.replaceFiles, 1)
    }

    func testFinishedFileIsSkippedUnderSkipAndRecopiedUnderOverwrite() throws {
        let a = remote("/DCIM/100APPLE/A.HEIC")
        let there = try indexed("DCIM/100APPLE/A.HEIC", at: Double(a.modifiedNs) / 1e9)
        var m = CopyManifest(deviceKey: "k")
        m.record(a, localPath: "DCIM/100APPLE/A.HEIC")
        let skip = preview([a], prints: [a.path: print()], manifest: m, dest: [there])
        XCTAssertEqual(skip.tally(.alreadyCopied).files, 1)
        XCTAssertEqual(skip.plan.toCopyFiles, 0)
        let over = preview([a], prints: [a.path: print()], manifest: m, dest: [there], options: SyncOptions(policy: .overwrite))
        XCTAssertEqual(over.tally(.alreadyCopied).files, 1)
        XCTAssertEqual(over.plan.replaceFiles, 1)
    }

    func testOverwriteStillDoesNotCreateAnotherCopyOfADuplicate() throws {
        // Overwrite replaces the same path. It doesn't add a second copy under another name.
        let a = remote("/DCIM/100APPLE/IMG_1.HEIC")
        var m = CopyManifest(deviceKey: "k")
        m.recordSourceHash(a, sha256: "same")
        let there = try indexed("old/IMG_9.HEIC", sha: "same")
        let p = preview([a], prints: [a.path: print()], manifest: m, dest: [there], options: SyncOptions(policy: .overwrite))
        XCTAssertEqual(p.plan.toCopyFiles, 0)
        XCTAssertEqual(p.tally(.exactDuplicate).files, 1)
    }

    func testNoFileEverLeavesThePreviewUncounted() throws {
        let files = [remote("/DCIM/1/A.HEIC", size: 1), remote("/DCIM/1/B.HEIC", size: 2), remote("/DCIM/1/C.MOV", size: 3)]
        let p = preview(files)
        XCTAssertEqual(SyncCategory.allCases.reduce(0) { $0 + p.tally($1).files }, 3)
        XCTAssertEqual(SyncCategory.allCases.reduce(Int64(0)) { $0 + p.tally($1).bytes }, 6)
        XCTAssertEqual(p.total.files, 3)
    }

    func testFileWithNoCaptureDateIsNominatedBySizeAndDecidedByHash() throws {
        let a = remote("/DCIM/100APPLE/SCREEN.PNG")
        let there = try indexed("old/screen-copy.png", print: MediaFingerprint(size: 100))
        let p = preview([a], prints: [a.path: print()], dest: [there])
        XCTAssertEqual(p.unconfirmed.count, 1)
    }

    func testVerifierHashesEachFileOnceAndSettlesThePreview() throws {
        let a = remote("/DCIM/100APPLE/IMG_1.HEIC"), b = remote("/DCIM/101APPLE/IMG_2.HEIC", size: 200)
        let folder = FolderIndex(folder: dest, cacheDirectory: dest.appendingPathComponent(".cache"))
        _ = try indexed("old/one.heic", size: 100)
        try Data(count: 200).write(to: dest.appendingPathComponent("old/two.heic"))
        folder.refresh()
        let indexFiles = folder.allFiles
        XCTAssertEqual(indexFiles.count, 2)

        // One real match, and one that only looks like a match.
        let behaviour = Locked(FakeReader.Behaviour())
        let localHashA = try sha256(file: dest.appendingPathComponent("old/one.heic"))
        behaviour.with {
            $0.contents = [a.path: 100, b.path: 200]
            $0.hashes = [a.path: localHashA, b.path: "not-the-same"]
        }
        let first = preview([a, b], prints: [:], dest: indexFiles)
        XCTAssertEqual(first.unconfirmed.count, 2)

        let readers = Locked<[FakeReader]>([])
        let verifier = DuplicateVerifier(connections: 1) {
            let r = FakeReader(id: 1, behaviour: behaviour, order: Locked([]))
            readers.with { $0.append(r) }
            return r
        }
        let result = verifier.run(candidates: first.unconfirmed, manifest: CopyManifest(deviceKey: "k"), indexes: [folder], control: TransferControl()) { _ in }
        XCTAssertTrue(result.failures.isEmpty)

        let second = preview([a, b], prints: [:], manifest: result.manifest, dest: folder.allFiles)
        XCTAssertFalse(second.needsVerification)
        XCTAssertEqual(second.tally(.exactDuplicate).files, 1)
        XCTAssertEqual(planned(second), ["DCIM/101APPLE/IMG_2.HEIC"])

        // A second pass finds nothing left to hash.
        let hashedBefore = readers.with { $0.flatMap { $0.hashed.with { $0 } } }.count
        XCTAssertEqual(hashedBefore, 2)
        _ = verifier.run(candidates: second.unconfirmed, manifest: result.manifest, indexes: [folder], control: TransferControl()) { _ in }
        XCTAssertEqual(readers.with { $0.flatMap { $0.hashed.with { $0 } } }.count, 2)
    }
}

final class FolderIndexTests: XCTestCase {
    private var dir: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: cache)
    }

    private func makePhoto(_ name: String, date: String?) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let date { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date] }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testReadsCaptureDateAndDimensionsFromAPhoto() throws {
        _ = try makePhoto("a.jpeg", date: "2026:11:02 19:33:25")
        let index = FolderIndex(folder: dir, cacheDirectory: cache)
        index.refresh()
        let p = try XCTUnwrap(index.allFiles.first?.fingerprint)
        XCTAssertEqual(p.capture, "20261102193325")
        XCTAssertEqual(p.longSide, 40)
        XCTAssertEqual(p.shortSide, 30)
    }

    func testPhotoWithoutADateStillHasSizeAndDimensions() throws {
        _ = try makePhoto("a.jpeg", date: nil)
        let index = FolderIndex(folder: dir, cacheDirectory: cache)
        index.refresh()
        let p = try XCTUnwrap(index.allFiles.first?.fingerprint)
        XCTAssertNil(p.capture)
        XCTAssertEqual(p.longSide, 40)
    }

    func testHiddenAndPartialFilesAreIgnored() throws {
        try Data("x".utf8).write(to: dir.appendingPathComponent(".IMG_1.HEIC.isync-partial"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".isync"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".isync/manifest.json"))
        try Data("y".utf8).write(to: dir.appendingPathComponent("real.txt"))
        let index = FolderIndex(folder: dir, cacheDirectory: cache)
        index.refresh()
        XCTAssertEqual(index.allFiles.map { ($0.path as NSString).lastPathComponent }, ["real.txt"])
    }

    func testHashIsCachedAcrossInstancesAndClearedWhenTheFileChanges() throws {
        let url = dir.appendingPathComponent("a.txt")
        try Data("one".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: url.path)
        let first = FolderIndex(folder: dir, cacheDirectory: cache)
        first.refresh()
        let hash = try first.sha256(ofPath: url.path)
        first.save()

        let second = FolderIndex(folder: dir, cacheDirectory: cache)
        second.refresh()
        XCTAssertEqual(second.allFiles.first?.sha256, hash)

        try Data("different".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: url.path)
        second.refresh()
        XCTAssertNil(second.allFiles.first?.sha256)
    }

    func testKnownDetailsSaveOpeningTheFile() throws {
        let url = try makePhoto("a.jpeg", date: "2026:11:02 19:33:25")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)!.int64Value
        let given = MediaFingerprint(size: size, capture: "19990101000000", width: 1, height: 2)
        let index = FolderIndex(folder: dir, cacheDirectory: cache)
        index.refresh(known: [canonicalPath(url): given])
        XCTAssertEqual(index.allFiles.first?.fingerprint.capture, "19990101000000")
    }

    func testKnownDetailsAreIgnoredIfTheSizeChanged() throws {
        let url = try makePhoto("a.jpeg", date: "2026:11:02 19:33:25")
        let given = MediaFingerprint(size: 1, capture: "19990101000000", width: 1, height: 2)
        let index = FolderIndex(folder: dir, cacheDirectory: cache)
        index.refresh(known: [canonicalPath(url): given])
        XCTAssertEqual(index.allFiles.first?.fingerprint.capture, "20261102193325")
    }

    func testIndexingNeverWritesIntoTheFolder() throws {
        _ = try makePhoto("a.jpeg", date: "2026:11:02 19:33:25")
        let index = FolderIndex(folder: dir, cacheDirectory: cache)
        index.refresh()
        _ = try index.sha256(ofPath: index.allFiles[0].path)
        index.save()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.jpeg"])
    }
}
