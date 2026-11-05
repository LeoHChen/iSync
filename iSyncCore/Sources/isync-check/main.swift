import CryptoKit
import Foundation
import iSyncCore

// Runs the real engine against a connected iPhone from the command line.
//   isync-check info
//   isync-check photos --dest <folder> [--limit 50] [--layout sameAsIPhone|yearMonth]
//   isync-check files  [--bundle <id>]
//   isync-check sync --dest <folder> [--limit 50] [--policy skipDuplicates|overwrite] [--reference <folder>] [--copy]
//   isync-check compare --other <udid>|self
//   isync-check music --dest <folder> [--limit 20] [--policy skipDuplicates|overwrite] [--copy] [--drm-check]
// Only `files` writes to the phone. It deletes only its own uniquely named test items.

func say(_ s: String) { print(s); fflush(stdout) }
func fail(_ s: String) -> Never { say("FAIL: \(s)"); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "" : args.removeFirst()
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard let udid = option("--udid") ?? DeviceWatcher.connectedDevices().first else { fail("no iPhone connected") }

switch command {
case "info":
    say("pairing: \(DevicePairing.check(udid: udid))")
    do {
        let s = try DeviceInfo.read(udid: udid)
        say("model: \(s.modelName) (\(s.productType)), iOS \(s.iosVersion) (\(s.buildVersion))")
        say("storage: \(s.storageUsed.map(Format.bytes) ?? "?") used, \(s.storageFree.map(Format.bytes) ?? "?") free of \(s.storageTotal.map(Format.bytes) ?? "?")")
        say("battery: \(s.batteryPercent.map { "\($0)%" } ?? "?"), charging: \(s.isCharging.map { "\($0)" } ?? "?")")
        say("USB link: \(DeviceInfo.usbLinkSpeed(udid: udid) ?? "?")")
    } catch { fail("\(error.localizedDescription)") }

case "photos":
    guard let destPath = option("--dest") else { fail("--dest is required") }
    let dest = URL(fileURLWithPath: destPath)
    let limit = Int(option("--limit") ?? "50") ?? 50
    let layout = FolderLayout(rawValue: option("--layout") ?? "sameAsIPhone") ?? .sameAsIPhone
    let key = deviceKey(udid: udid)
    do {
        let t0 = Date()
        let all = try PhotoScanner.scan(udid: udid)
        say("scan: \(all.count) files, \(Format.bytes(all.reduce(0) { $0 + $1.size })) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")

        // Whole groups only, newest first, so pairs aren't cut in half.
        var subset: [RemoteFile] = []
        for g in PhotoGrouping.groups(from: all) where subset.count < limit { subset += g.files }
        func planNow() -> CopyPlan {
            CopyPlanner.plan(files: subset, destination: dest, manifest: CopyManifest.load(destination: dest, deviceKey: key), layout: layout)
        }
        func run(_ plan: CopyPlan) -> PhotoCopyEngine.Result {
            let sem = DispatchSemaphore(value: 0)
            var out = PhotoCopyEngine.Result()
            let e = PhotoCopyEngine(
                plan: plan, destination: dest, manifest: CopyManifest.load(destination: dest, deviceKey: key),
                readerFactory: { try AFCClient.connect(udid: udid) })
            e.start(onProgress: { _ in }, onFinish: { out = $0; sem.signal() })
            sem.wait()
            return out
        }

        let first = planNow()
        say("first plan: \(first.toCopyFiles) to copy (\(Format.bytes(first.toCopyBytes))), \(first.alreadyCopiedFiles) already copied, \(first.livePhotosToCopy) Live Photos")
        let r1 = run(first)
        say(String(format: "first run: %d files, %@, %.1f s, %.1f MB/s, %d failed, stop=%@", r1.copiedFiles, Format.bytes(r1.copiedBytes), r1.seconds, r1.averageBytesPerSecond / 1e6, r1.failures.count, r1.stopReason ?? "none"))
        for f in r1.failures.prefix(5) { say("  failed: \(f.reason)") }

        // Pairs must land side by side, and every size must match.
        var mismatched = 0, pairsTogether = 0, pairsSplit = 0
        let m = CopyManifest.load(destination: dest, deviceKey: key)
        for f in subset {
            guard let e = m.entries[f.path] else { mismatched += 1; continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent(e.localPath).path)[.size] as? NSNumber)??.int64Value
            if size != f.size { mismatched += 1 }
        }
        for g in PhotoGrouping.groups(from: subset) where g.isLivePhoto {
            let folders = Set(g.files.compactMap { m.entries[$0.path].map { ($0.localPath as NSString).deletingLastPathComponent } })
            if folders.count == 1 { pairsTogether += 1 } else { pairsSplit += 1 }
        }
        say("verify: \(mismatched) size mismatches, \(pairsTogether) Live Photo groups together, \(pairsSplit) split")

        let second = planNow()
        say("second plan: \(second.toCopyFiles) to copy, \(second.alreadyCopiedFiles) already copied")
        let r2 = run(second)
        say("second run: \(r2.copiedFiles) files copied")
        let partials = (FileManager.default.enumerator(atPath: dest.path)?.compactMap { $0 as? String } ?? []).filter { $0.hasSuffix(".isync-partial") }
        say("partial files left: \(partials.count)")
        if r1.failures.isEmpty && r1.stopReason == nil && mismatched == 0 && pairsSplit == 0 && r2.copiedFiles == 0 && second.toCopyFiles == 0 && partials.isEmpty {
            say("PASS")
        } else {
            fail("see above")
        }
    } catch { fail("\(error.localizedDescription)") }

case "files":
    do {
        let apps = try SharedApps.list(udid: udid)
        say("apps with file sharing: \(apps.count)")
        guard let app = option("--bundle").flatMap({ id in apps.first { $0.bundleID == id } }) ?? apps.first else { fail("no apps") }
        say("using: \(app.name)")
        let session = try AppDocumentsSession(udid: udid, bundleID: app.bundleID)
        let root = AppDocumentsSession.rootPath
        let control = TransferControl()
        let tag = "iSync-check-\(UUID().uuidString)"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(tag)
        defer { try? FileManager.default.removeItem(at: work) }
        let outDir = work.appendingPathComponent("back")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        func hash(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        var payload = Data(count: 5_000_000)
        payload.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }

        // A file: in, listed, refused on overwrite, out, compared, deleted.
        let local = work.appendingPathComponent("\(tag).bin")
        try payload.write(to: local)
        let t0 = Date()
        try session.upload(local, into: root, control: control) { _ in }
        say(String(format: "upload: %.1f MB/s", 5.0 / Date().timeIntervalSince(t0)))
        let listed = try session.list(root)
        guard let entry = listed.first(where: { $0.name == local.lastPathComponent }) else { fail("uploaded file isn't listed") }
        say("listed: size \(entry.size), no partial files visible: \(!listed.contains { $0.name.contains("isync-partial") })")
        var refused = false
        do { try session.upload(local, into: root, control: control) { _ in } } catch { refused = true; say("overwrite refused: \(error.localizedDescription)") }
        guard refused else { fail("an existing file was replaced") }
        let t1 = Date()
        let back = try session.download(entry, into: outDir, control: control) { _ in }
        say(String(format: "download: %.1f MB/s", 5.0 / Date().timeIntervalSince(t1)))
        guard try hash(back) == hash(local) else { fail("file changed in the round trip") }
        say("sha256 match: true")
        let again = try session.download(entry, into: outDir, control: control) { _ in }
        say("second download keeps both: \(again.lastPathComponent != back.lastPathComponent)")
        try session.delete(entry)
        guard try !session.list(root).contains(where: { $0.path == entry.path }) else { fail("test file wasn't deleted") }
        say("test file deleted from the iPhone")

        // A folder, both ways.
        let folder = work.appendingPathComponent("\(tag)-folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("two".utf8).write(to: folder.appendingPathComponent("inner/b.txt"))
        try session.upload(folder, into: root, control: control) { _ in }
        guard let remoteFolder = try session.list(root).first(where: { $0.name == folder.lastPathComponent }), remoteFolder.isDirectory else { fail("folder isn't listed") }
        let folderBack = try session.download(remoteFolder, into: outDir, control: control) { _ in }
        let inner = try String(contentsOf: folderBack.appendingPathComponent("inner/b.txt"), encoding: .utf8)
        guard inner == "two" else { fail("folder contents changed") }
        say("folder round trip: ok")
        try session.delete(remoteFolder)
        guard try !session.list(root).contains(where: { $0.path == remoteFolder.path }) else { fail("test folder wasn't deleted") }
        say("test folder deleted from the iPhone")
        say("PASS")
    } catch { fail("\(error.localizedDescription)") }

case "sync":
    guard let destPath = option("--dest") else { fail("--dest is required") }
    let dest = URL(fileURLWithPath: destPath)
    let limit = Int(option("--limit") ?? "50") ?? 50
    let policy = ConflictPolicy(rawValue: option("--policy") ?? "skipDuplicates") ?? .skipDuplicates
    let key = deviceKey(udid: udid)
    func show(_ p: SyncPreview, _ label: String) {
        say("\(label): \(p.total.files) files, \(Format.bytes(p.total.bytes))")
        for c in SyncCategory.allCases { say("  \(c.rawValue): \(p.tally(c).files), \(Format.bytes(p.tally(c).bytes))") }
        say("  to copy: \(p.plan.toCopyFiles), \(Format.bytes(p.plan.toCopyBytes)); replaces: \(p.plan.replaceFiles); unconfirmed: \(p.unconfirmed.count), \(Format.bytes(p.unconfirmedBytes))")
    }
    do {
        let t0 = Date()
        let library = try PhoneLibraryIndex.fetch(udid: udid)
        say(String(format: "photos database: %d assets in %.1f s", library.assets.count, Date().timeIntervalSince(t0)))
        let all = try PhotoScanner.scan(udid: udid)
        var subset: [RemoteFile] = []
        for g in PhotoGrouping.groups(from: all) where subset.count < limit { subset += g.files }
        let prints = library.fingerprints
        let known = subset.filter { prints[$0.path] != nil }.count
        say("sample: \(subset.count) files, \(known) with database details")

        let destIndex = FolderIndex(folder: dest)
        let refIndex = option("--reference").map { FolderIndex(folder: URL(fileURLWithPath: $0)) }
        let t1 = Date()
        destIndex.refresh()
        refIndex?.refresh()
        say(String(format: "indexed %d files in the destination and %d in the reference folder in %.1f s", destIndex.allFiles.count, refIndex?.allFiles.count ?? 0, Date().timeIntervalSince(t1)))

        var manifest = CopyManifest.load(destination: dest, deviceKey: key)
        let options = SyncOptions(policy: policy)
        func preview() -> SyncPreview {
            SyncPlanner.preview(
                files: subset, fingerprints: prints, destination: dest, manifest: manifest,
                destinationFiles: destIndex.allFiles, referenceFiles: refIndex?.allFiles ?? [], options: options)
        }
        var p = preview()
        show(p, "preview")
        if !args.contains("--copy") { say("dry run: nothing copied"); break }

        if p.needsVerification {
            let t2 = Date()
            let verifier = DuplicateVerifier(readerFactory: { try AFCClient.connect(udid: udid) })
            let result = verifier.run(candidates: p.unconfirmed, manifest: manifest, indexes: [destIndex, refIndex].compactMap { $0 }, control: TransferControl()) { _ in }
            manifest = result.manifest
            try manifest.save(destination: dest)
            say(String(format: "verified %d candidates in %.1f s, failures %d", p.unconfirmed.count, Date().timeIntervalSince(t2), result.failures.count))
            p = preview()
            show(p, "after SHA-256")
        }
        let sem = DispatchSemaphore(value: 0)
        var r = PhotoCopyEngine.Result()
        let engine = PhotoCopyEngine(plan: p.plan, destination: dest, manifest: manifest, readerFactory: { try AFCClient.connect(udid: udid) })
        engine.start(onProgress: { _ in }, onFinish: { r = $0; sem.signal() })
        sem.wait()
        say(String(format: "copied %d files, %@, %.1f MB/s, failed %d, stop=%@", r.copiedFiles, Format.bytes(r.copiedBytes), r.averageBytesPerSecond / 1e6, r.failures.count, r.stopReason ?? "none"))

        destIndex.refresh()
        manifest = CopyManifest.load(destination: dest, deviceKey: key)
        let again = preview()
        show(again, "second preview")
        say(again.plan.toCopyFiles == 0 || policy == .overwrite ? "PASS" : "FAIL: a repeat run would copy files")
    } catch { fail("\(error.localizedDescription)") }

case "compare":
    guard let other = option("--other") else { fail("--other <udid>|self is required") }
    let otherUDID = other == "self" ? udid : other
    do {
        let t0 = Date()
        let source = try PhoneLibraryIndex.fetch(udid: udid)
        let target = try PhoneLibraryIndex.fetch(udid: otherUDID)
        let sourceFiles = try PhotoScanner.scan(udid: udid)
        let targetFiles = try PhotoScanner.scan(udid: otherUDID)
        let c = PhoneComparer.compare(source: source, destination: target, sourceFiles: sourceFiles, destinationFiles: targetFiles)
        say(String(format: "compared in %.1f s, from metadata only. Source assets %d, destination assets %d", Date().timeIntervalSince(t0), source.assets.count, target.assets.count))
        say("  already on destination: \(c.alreadyOnDestination.files), \(Format.bytes(c.alreadyOnDestination.bytes))")
        say("  possible duplicates: \(c.possibleDuplicates.files), \(Format.bytes(c.possibleDuplicates.bytes))")
        say("  new: \(c.new.files), \(Format.bytes(c.new.bytes))")
        // A small sample proves the metadata match against real bytes.
        let sample = Int(option("--hash-sample") ?? "0") ?? 0
        if sample > 0, !c.candidates.isEmpty {
            let a = try AFCClient.connect(udid: udid), b = try AFCClient.connect(udid: otherUDID)
            let control = TransferControl()
            var same = 0, tested = 0
            let step = max(1, c.candidates.count / sample)
            for i in stride(from: 0, to: c.candidates.count, by: step).prefix(sample) {
                let pair = c.candidates[i]
                let x = try a.sha256(remote: pair.source, control: control) { _ in }
                let y = try b.sha256(remote: pair.destination, control: control) { _ in }
                tested += 1
                if x == y { same += 1 }
            }
            say("  SHA-256 sample: \(same) of \(tested) candidates identical")
        }
    } catch { fail("\(error.localizedDescription)") }

case "music":
    let policy = ConflictPolicy(rawValue: option("--policy") ?? "skipDuplicates") ?? .skipDuplicates
    let key = deviceKey(udid: udid) + "-music"
    do {
        let tracks = try MusicLibrary.fetch(udid: udid)
        let s = MusicSummary(tracks)
        say("library: \(s.total) music items. copyable \(s.copyable) (\(Format.bytes(s.copyableBytes))), protected \(s.protected), not on iPhone \(s.notOnIPhone), subscription flag \(s.subscriptionFlagged)")
        var reasons: [String: Int] = [:]
        for t in tracks { if case .protected(let r) = t.status { reasons[r, default: 0] += 1 } }
        if !reasons.isEmpty { say("  protected because: \(reasons)") }
        guard let destPath = option("--dest") else { break }
        let dest = URL(fileURLWithPath: destPath)
        var chosen = tracks.filter { $0.status == .copyable }
        if let limit = option("--limit").flatMap(Int.init) { chosen = Array(chosen.prefix(limit)) }
        func plan() -> MusicPlanner.Preview {
            MusicPlanner.plan(tracks: chosen, destination: dest, manifest: CopyManifest.load(destination: dest, deviceKey: key), policy: policy)
        }
        let p = plan()
        say("preview: new \(p.new.files), already copied \(p.alreadyCopied.files), same name different \(p.sameNameDifferent.files), to copy \(p.plan.toCopyFiles), \(Format.bytes(p.plan.toCopyBytes))")
        if !args.contains("--copy") { say("dry run: nothing copied"); break }
        let sem = DispatchSemaphore(value: 0)
        var r = PhotoCopyEngine.Result()
        let engine = PhotoCopyEngine(plan: p.plan, destination: dest, manifest: CopyManifest.load(destination: dest, deviceKey: key), readerFactory: { try AFCClient.connect(udid: udid) })
        engine.start(onProgress: { _ in }, onFinish: { r = $0; sem.signal() })
        sem.wait()
        say(String(format: "copied %d tracks, %@, %.1f MB/s, failed %d, stop=%@", r.copiedFiles, Format.bytes(r.copiedBytes), r.averageBytesPerSecond / 1e6, r.failures.count, r.stopReason ?? "none"))
        for f in r.failures.prefix(5) { say("  failed: \(f.reason)") }
        let again = plan()
        say("second preview: to copy \(again.plan.toCopyFiles), already copied \(again.alreadyCopied.files)")
        if args.contains("--drm-check") {
            let manifest = CopyManifest.load(destination: dest, deviceKey: key)
            let done = DispatchSemaphore(value: 0)
            let urls = manifest.entries.values.map { dest.appendingPathComponent($0.localPath) }
            Task.detached {
                var protected = 0
                for url in urls where await MusicLibrary.hasDRM(url) { protected += 1 }
                say("DRM check on \(urls.count) copied files: \(protected) protected")
                done.signal()
            }
            done.wait()
        }
    } catch { fail("\(error.localizedDescription)") }

default:
    say("usage: isync-check info | photos --dest <folder> [--limit 50] [--layout sameAsIPhone|yearMonth] | files [--bundle <id>] | sync --dest <folder> | compare --other <udid>|self | music [--dest <folder>]")
    exit(2)
}
