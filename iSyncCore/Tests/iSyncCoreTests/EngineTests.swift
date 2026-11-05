import XCTest
@testable import iSyncCore

/// A pretend iPhone connection that can misbehave on request.
final class FakeReader: RemoteFileReader {
    struct Behaviour {
        var contents: [String: Int] = [:]
        var failOnce: Set<String> = []
        var shortRead: Set<String> = []
        var missing: Set<String> = []
        var chunkDelay: TimeInterval = 0
    }

    let behaviour: Locked<Behaviour>
    let order: Locked<[(Int, String)]>
    let id: Int
    /// A connection that has failed stays broken, like a real one.
    private var isBroken = false

    init(id: Int, behaviour: Locked<Behaviour>, order: Locked<[(Int, String)]>) {
        self.id = id
        self.behaviour = behaviour
        self.order = order
    }

    func copy(remote: String, to local: URL, chunk: Int, control: TransferControl, onBytes: (Int) -> Void) throws -> Int64 {
        if isBroken { throw AFCError(operation: "Read", code: 30, text: "connection closed") }
        order.with { $0.append((id, remote)) }
        let b = behaviour.with { $0 }
        if b.missing.contains(remote) { throw AFCError(operation: "Open", code: 8, text: "not found") }
        if b.failOnce.contains(remote) {
            behaviour.with { $0.failOnce.remove(remote) }
            isBroken = true
            throw AFCError(operation: "Read", code: 30, text: "mux error")
        }
        var size = b.contents[remote] ?? 0
        if b.shortRead.contains(remote) { size -= 1 }
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let out = try FileHandle(forWritingTo: local)
        defer { try? out.close() }
        var written = 0
        while written < size {
            guard control.checkpoint() else { throw TransferCancelled() }
            let n = min(chunk, size - written)
            try out.write(contentsOf: Data(count: n))
            written += n
            onBytes(n)
            if b.chunkDelay > 0 { Thread.sleep(forTimeInterval: b.chunkDelay) }
        }
        return Int64(written)
    }
}

final class EngineTests: XCTestCase {
    private var dir: URL!
    private let behaviour = Locked(FakeReader.Behaviour())
    private let order = Locked<[(Int, String)]>([])
    private let nextID = Locked(0)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ path: String, size: Int = 1024) -> RemoteFile {
        behaviour.with { $0.contents[path] = size }
        return RemoteFile(path: path, size: Int64(size), modifiedNs: 1_700_000_000_000_000_000)
    }

    private func engine(_ files: [RemoteFile], connections: Int = 2, factory: (() throws -> RemoteFileReader)? = nil) -> PhotoCopyEngine {
        let manifest = CopyManifest(deviceKey: "k")
        let plan = CopyPlanner.plan(files: files, destination: dir, manifest: manifest, layout: .sameAsIPhone)
        let make = factory ?? { [self] in
            FakeReader(id: nextID.with { n in n += 1; return n }, behaviour: behaviour, order: order)
        }
        return PhotoCopyEngine(plan: plan, destination: dir, manifest: manifest, connections: connections,
                               chunkBytes: 256, retryDelay: 0, readerFactory: make)
    }

    private func run(_ e: PhotoCopyEngine, during: ((PhotoCopyEngine) -> Void)? = nil) -> PhotoCopyEngine.Result {
        let done = expectation(description: "finished")
        var result = PhotoCopyEngine.Result()
        e.start(onProgress: { _ in }, onFinish: { result = $0; done.fulfill() })
        during?(e)
        wait(for: [done], timeout: 30)
        return result
    }

    private func leftovers() -> [String] {
        let all = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        return all.filter { $0.hasSuffix(".isync-partial") }
    }

    func testCopiesFilesAndRecordsThem() throws {
        let a = file("/DCIM/100APPLE/A.HEIC"), b = file("/DCIM/100APPLE/B.HEIC", size: 2048)
        let r = run(engine([a, b]))
        XCTAssertEqual(r.copiedFiles, 2)
        XCTAssertEqual(r.copiedBytes, 3072)
        XCTAssertTrue(r.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("DCIM/100APPLE/B.HEIC")).count, 2048)
        let m = CopyManifest.load(destination: dir, deviceKey: "k")
        XCTAssertEqual(m.entries[a.path]?.localPath, "DCIM/100APPLE/A.HEIC")
        XCTAssertEqual(m.entries.count, 2)
    }

    func testRepeatRunPlansNothing() throws {
        let files = [file("/DCIM/100APPLE/A.HEIC"), file("/DCIM/100APPLE/B.MOV")]
        _ = run(engine(files))
        let m = CopyManifest.load(destination: dir, deviceKey: "k")
        let again = CopyPlanner.plan(files: files, destination: dir, manifest: m, layout: .sameAsIPhone)
        XCTAssertEqual(again.toCopyFiles, 0)
        XCTAssertEqual(again.alreadyCopiedFiles, 2)
    }

    func testPhoneDateIsKeptOnTheCopy() throws {
        let a = file("/DCIM/100APPLE/A.HEIC")
        _ = run(engine([a]))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("DCIM/100APPLE/A.HEIC").path)
        XCTAssertEqual((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, a.modified.timeIntervalSince1970, accuracy: 1)
    }

    func testLivePhotoPairUsesOneConnection() {
        var files: [RemoteFile] = []
        for i in 0..<40 {
            files.append(file("/DCIM/100APPLE/IMG_\(i).HEIC"))
            files.append(file("/DCIM/100APPLE/IMG_\(i).MOV"))
        }
        let r = run(engine(files, connections: 4))
        XCTAssertEqual(r.copiedFiles, 80)
        let log = order.with { $0 }
        for i in 0..<40 {
            let heic = log.first { $0.1.hasSuffix("IMG_\(i).HEIC") }
            let mov = log.first { $0.1.hasSuffix("IMG_\(i).MOV") }
            XCTAssertEqual(heic?.0, mov?.0, "pair \(i) split across connections")
        }
    }

    func testWrongSizeFailsAndLeavesNoFile() {
        let a = file("/DCIM/100APPLE/A.HEIC")
        behaviour.with { $0.shortRead.insert(a.path) }
        let r = run(engine([a]))
        XCTAssertEqual(r.copiedFiles, 0)
        XCTAssertEqual(r.copiedBytes, 0)
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("DCIM/100APPLE/A.HEIC").path))
        XCTAssertEqual(leftovers(), [])
        XCTAssertNil(CopyManifest.load(destination: dir, deviceKey: "k").entries[a.path])
    }

    func testMissingFileIsReportedAndOthersContinue() {
        let a = file("/DCIM/100APPLE/A.HEIC"), b = file("/DCIM/100APPLE/B.HEIC")
        behaviour.with { $0.missing.insert(a.path) }
        let r = run(engine([a, b]))
        XCTAssertEqual(r.copiedFiles, 1)
        XCTAssertEqual(r.failures.map(\.path), [a.path])
        XCTAssertNil(r.stopReason)
    }

    func testLostConnectionRetriesOnANewConnection() {
        let a = file("/DCIM/100APPLE/A.HEIC")
        behaviour.with { $0.failOnce.insert(a.path) }
        let r = run(engine([a], connections: 1))
        XCTAssertEqual(r.copiedFiles, 1)
        XCTAssertTrue(r.failures.isEmpty)
        XCTAssertEqual(nextID.with { $0 }, 2)
    }

    func testUnpluggedPhoneStopsWithAClearReason() {
        let a = file("/DCIM/100APPLE/A.HEIC"), b = file("/DCIM/100APPLE/B.HEIC")
        behaviour.with { $0.failOnce = [a.path, b.path] }
        let made = Locked(0)
        let beh = behaviour, ord = order
        let e = engine([a, b], connections: 1, factory: {
            let n = made.with { c in c += 1; return c }
            if n > 1 { throw ISyncError("gone") }
            return FakeReader(id: n, behaviour: beh, order: ord)
        })
        let r = run(e)
        XCTAssertEqual(r.copiedFiles, 0)
        XCTAssertTrue(r.stopReason?.contains("disconnected") == true)
        XCTAssertFalse(r.wasCancelled)
        XCTAssertEqual(leftovers(), [])
    }

    func testCancelStopsAndLeavesNoPartialFiles() {
        behaviour.with { $0.chunkDelay = 0.01 }
        let files = (0..<20).map { file("/DCIM/100APPLE/F\($0).HEIC", size: 25_600) }
        let r = run(engine(files)) { e in
            Thread.sleep(forTimeInterval: 0.2)
            e.cancel()
        }
        XCTAssertTrue(r.wasCancelled)
        XCTAssertLessThan(r.copiedFiles, 20)
        XCTAssertEqual(leftovers(), [])
        // What finished before the cancel still counts on the next run.
        XCTAssertEqual(CopyManifest.load(destination: dir, deviceKey: "k").entries.count, r.copiedFiles)
    }

    func testPauseHoldsAndResumeFinishes() {
        behaviour.with { $0.chunkDelay = 0.005 }
        let files = (0..<6).map { file("/DCIM/100APPLE/F\($0).HEIC", size: 25_600) }
        let e = engine(files)
        let done = expectation(description: "finished")
        var result = PhotoCopyEngine.Result()
        let latest = Locked(PhotoCopyEngine.Progress())
        e.start(onProgress: { p in latest.with { $0 = p } }, onFinish: { result = $0; done.fulfill() })
        e.pause()
        Thread.sleep(forTimeInterval: 0.7)
        let a = latest.with { $0 }
        XCTAssertTrue(a.isPaused)
        Thread.sleep(forTimeInterval: 0.6)
        let b = latest.with { $0 }
        XCTAssertEqual(a.copiedBytes, b.copiedBytes, "bytes moved while paused")
        XCTAssertLessThan(b.copiedFiles, 6)
        e.resume()
        wait(for: [done], timeout: 30)
        XCTAssertEqual(result.copiedFiles, 6)
    }

    func testDiskProblemStopsTheWholeCopy() {
        // A file sits where the first folder needs to go.
        FileManager.default.createFile(atPath: dir.appendingPathComponent("DCIM").path, contents: Data())
        let r = run(engine([file("/DCIM/100APPLE/A.HEIC"), file("/DCIM/100APPLE/B.HEIC")]))
        XCTAssertEqual(r.copiedFiles, 0)
        XCTAssertTrue(r.stopReason?.contains("destination folder") == true)
    }

    func testFileAppearingAfterPlanningIsNotReplaced() throws {
        let a = file("/DCIM/100APPLE/A.HEIC")
        let e = engine([a])
        let existing = dir.appendingPathComponent("DCIM/100APPLE/A.HEIC")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: existing)
        let r = run(e)
        XCTAssertEqual(r.copiedFiles, 0)
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: existing), Data("mine".utf8))
    }

    func testNoConnectionAtAllReportsAReason() {
        let a = file("/DCIM/100APPLE/A.HEIC")
        let r = run(engine([a], factory: { throw ISyncError("nope") }))
        XCTAssertEqual(r.copiedFiles, 0)
        XCTAssertNotNil(r.stopReason)
    }
}
