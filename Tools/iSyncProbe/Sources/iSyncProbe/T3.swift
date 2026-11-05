import CIMobileDevice
import Foundation

struct T3Options {
    var sampleBytes: Int64 = 2_000_000_000
    var connections: [Int] = [1, 2, 4]
    var chunkBytes: Int = 1 << 20
    var runICC = true
    var iccFirst = false
    var iccOutstanding = 1
    var probePhotosDB = true
    var resultName = "t3"
    /// Skips the newest files, so a run reads files the phone hasn't cached yet.
    var offsetBytes: Int64 = 0
}

/// Lists /DCIM with four connections and returns each regular file.
func walkDCIM(udid: String) throws -> (files: [RemoteFile], seconds: Double, folders: [String]) {
    let t0 = Date()
    let root = try openAFC(udid: udid)
    let top = try root.list("/DCIM")
    var folders: [String] = []
    var names: [String] = []
    for entry in top {
        let p = "/DCIM/\(entry)"
        guard let info = root.info(p) else { continue }
        if info["st_ifmt"] == "S_IFDIR" {
            folders.append(entry)
            for f in (try? root.list(p)) ?? [] { names.append("\(p)/\(f)") }
        } else {
            names.append(p)
        }
    }
    let next = Locked(0)
    let out = Locked<[RemoteFile]>([])
    let failure = Locked<String?>(nil)
    let progress = Locked(0)
    parallel(workers: 4) { _ in
        do {
            let afc = try openAFC(udid: udid)
            while true {
                let i = next.with { (n: inout Int) -> Int in defer { n += 1 }; return n }
                if i >= names.count { break }
                guard let s = afc.info(names[i]), s["st_ifmt"] == "S_IFREG" else { continue }
                let rf = RemoteFile(
                    path: names[i],
                    size: Int64(s["st_size"] ?? "0") ?? 0,
                    mtimeNs: Int64(s["st_mtime"] ?? "0") ?? 0,
                    birthNs: Int64(s["st_birthtime"] ?? "0") ?? 0)
                out.with { $0.append(rf) }
                let d = progress.with { (n: inout Int) -> Int in n += 1; return n }
                if d % 5000 == 0 { log("  listed \(d) of \(names.count)") }
            }
        } catch {
            failure.with { $0 = "\(error)" }
        }
    }
    if let f = failure.with({ $0 }) { throw ProbeError(f) }
    return (out.with { $0 }, Date().timeIntervalSince(t0), folders.sorted())
}

/// Picks the newest files up to the target size. Single files over half the
/// target are skipped so one long video doesn't become the whole sample.
func pickSample(_ files: [RemoteFile], target: Int64, offset: Int64 = 0) -> (sample: [RemoteFile], skippedLarge: Int) {
    var out: [RemoteFile] = []
    var total: Int64 = 0
    var skipped = 0
    var passed: Int64 = 0
    for f in files.sorted(by: { $0.mtimeNs > $1.mtimeNs }) {
        if total >= target { break }
        if f.size > target / 2 { skipped += 1; continue }
        if passed < offset {
            passed += f.size
            continue
        }
        out.append(f)
        total += f.size
    }
    return (out, skipped)
}

func localName(_ remote: String) -> String {
    remote.replacingOccurrences(of: "/DCIM/", with: "").replacingOccurrences(of: "/", with: "_")
}

struct CopyRun {
    let connections: Int
    let chunkBytes: Int
    let bytes: Int64
    let seconds: Double
    let files: Int
    let sizeMismatches: Int
    let errors: [String]
    let cpuSeconds: Double
    var mbps: Double { Double(bytes) / 1e6 / seconds }
}

func copySample(udid: String, sample: [RemoteFile], connections n: Int, chunk: Int, into dir: URL) -> CopyRun {
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let next = Locked(0)
    let bytes = Locked<Int64>(0)
    let mismatches = Locked(0)
    let errors = Locked<[String]>([])
    let total = sample.reduce(Int64(0)) { $0 + $1.size }

    // Connect first so connection setup isn't counted as transfer time.
    var clients: [AFC?] = []
    for _ in 0..<n {
        do { clients.append(try openAFC(udid: udid)) } catch {
            clients.append(nil)
            errors.with { $0.append("connect: \(error)") }
        }
    }
    let conns = clients
    let done = Locked(false)
    let reporter = Thread {
        var lastLog = Date()
        while !done.with({ $0 }) {
            Thread.sleep(forTimeInterval: 1)
            if Date().timeIntervalSince(lastLog) >= 15 {
                lastLog = Date()
                log("    \(fmtBytes(bytes.with { $0 })) of \(fmtBytes(total))")
            }
        }
    }
    reporter.start()

    let t0 = Date()
    let cpu0 = processCPUSeconds()
    parallel(workers: n) { w in
        guard let afc = conns[w] else { return }
        while true {
            let i = next.with { (x: inout Int) -> Int in defer { x += 1 }; return x }
            if i >= sample.count { break }
            let f = sample[i]
            do {
                let got = try afc.copy(
                    remote: f.path, to: dir.appendingPathComponent(localName(f.path)), chunk: chunk,
                    onBytes: { b in bytes.with { $0 += Int64(b) } })
                if got != f.size { mismatches.with { $0 += 1 } }
            } catch {
                errors.with { $0.append("\(error)") }
            }
        }
    }
    let secs = Date().timeIntervalSince(t0)
    done.with { $0 = true }
    return CopyRun(
        connections: n, chunkBytes: chunk, bytes: bytes.with { $0 }, seconds: secs, files: sample.count,
        sizeMismatches: mismatches.with { $0 }, errors: errors.with { $0 },
        cpuSeconds: processCPUSeconds() - cpu0)
}

/// T3(d): is Photos.sqlite readable over AFC? Copies it out and counts rows.
func probePhotosDB(udid: String) -> [String: Any] {
    var r: [String: Any] = [:]
    do {
        let afc = try openAFC(udid: udid)
        let dir = Paths.dir("preflight/\(udid)")
        guard let info = afc.info("/PhotoData/Photos.sqlite") else {
            r["readable"] = false
            r["reason"] = "stat of /PhotoData/Photos.sqlite failed"
            r["photoDataVisible"] = (try? afc.list("/PhotoData")) ?? "listing /PhotoData failed"
            return r
        }
        r["sizeBytes"] = Int64(info["st_size"] ?? "0") ?? 0
        let t0 = Date()
        for suffix in ["", "-wal", "-shm"] where afc.info("/PhotoData/Photos.sqlite\(suffix)") != nil {
            try afc.copy(remote: "/PhotoData/Photos.sqlite\(suffix)",
                         to: dir.appendingPathComponent("Photos.sqlite\(suffix)"), chunk: 1 << 20)
        }
        r["copySeconds"] = Date().timeIntervalSince(t0)
        r["readable"] = true
        let db = try SQLiteDB(path: dir.appendingPathComponent("Photos.sqlite").path)
        r["tables"] = try db.tableCount()
        if try db.hasTable("ZASSET") { r["assetRows"] = try db.int("SELECT COUNT(*) FROM ZASSET") }
        if try db.hasColumn("ZASSET", "ZTRASHEDSTATE") {
            r["assetsNotTrashed"] = try db.int("SELECT COUNT(*) FROM ZASSET WHERE ZTRASHEDSTATE = 0")
        }
        if try db.hasTable("ZGENERICALBUM") { r["albumRows"] = try db.int("SELECT COUNT(*) FROM ZGENERICALBUM") }
    } catch {
        r["readable"] = r["readable"] ?? false
        r["error"] = "\(error)"
    }
    return r
}

func t3(udid: String, options o: T3Options) -> Bool {
    log("\n== T3 Photos to Mac: \(udid)")
    var r: [String: Any] = ["test": "T3"]
    defer { writeResult(udid: udid, name: o.resultName, r) }
    do {
        let deviceName = (try? Lockdown(device: try Device(udid: udid)))?.value(key: "DeviceName") as? String ?? ""
        let walk = try walkDCIM(udid: udid)
        let total = walk.files.reduce(Int64(0)) { $0 + $1.size }
        var byExt: [String: Int] = [:]
        for f in walk.files { byExt[(f.path as NSString).pathExtension.uppercased(), default: 0] += 1 }
        r["dcim"] = [
            "files": walk.files.count, "totalBytes": total, "listSeconds": walk.seconds,
            "folders": walk.folders.count, "byExtension": byExt,
        ] as [String: Any]
        log("  (a) /DCIM: \(walk.files.count) files, \(fmtBytes(total)) in \(walk.folders.count) folders, listed in \(String(format: "%.1f", walk.seconds)) s")
        log("      types: \(byExt.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        guard !walk.files.isEmpty else {
            r["pass"] = false
            r["failure"] = "/DCIM has no files"
            return false
        }

        let (sample, skipped) = pickSample(walk.files, target: o.sampleBytes, offset: o.offsetBytes)
        let sampleBytes = sample.reduce(Int64(0)) { $0 + $1.size }
        var sampleExt: [String: Int] = [:]
        for f in sample { sampleExt[(f.path as NSString).pathExtension.uppercased(), default: 0] += 1 }
        r["sample"] = ["files": sample.count, "bytes": sampleBytes, "skippedLargeFiles": skipped, "offsetBytes": o.offsetBytes, "byExtension": sampleExt] as [String: Any]
        log("  (b) sample: \(sample.count) files, \(fmtBytes(sampleBytes)), newest \(fmtBytes(o.offsetBytes)) skipped, also skipped \(skipped) files over \(fmtBytes(o.sampleBytes / 2))")

        func runICCBaseline() {
            log("  (c) ImageCaptureCore baseline on the same files")
            let icc = ICCDownload(udid: udid, deviceName: deviceName, sample: sample, outstanding: o.iccOutstanding).run()
            r["imageCaptureCore"] = icc
            if let m = icc["MBps"] as? Double {
                log(String(format: "      -> %.1f MB/s, %d files downloaded, %d not matched, %d failed",
                           m, icc["downloaded"] as? Int ?? 0, icc["unmatched"] as? Int ?? 0, icc["failed"] as? Int ?? 0))
            } else {
                log("      -> no result: \(icc["failure"] ?? "unknown")")
            }
        }

        // Pass --icc-first to give ImageCaptureCore the cold phone cache.
        if o.runICC && o.iccFirst { runICCBaseline() }

        var runs: [[String: Any]] = []
        var allOK = true
        let afcDir = Paths.dir("afc")
        for n in o.connections {
            log("      copying with \(n) connection(s), \(o.chunkBytes / 1024) KB reads")
            let run = copySample(udid: udid, sample: sample, connections: n, chunk: o.chunkBytes, into: afcDir)
            log(String(format: "      -> %.1f MB/s (%@ in %.1f s), CPU %.1f s, size mismatches %d, errors %d",
                       run.mbps, fmtBytes(run.bytes), run.seconds, run.cpuSeconds, run.sizeMismatches, run.errors.count))
            runs.append([
                "connections": n, "chunkBytes": run.chunkBytes, "bytes": run.bytes, "seconds": run.seconds,
                "MBps": run.mbps, "cpuSeconds": run.cpuSeconds, "sizeMismatches": run.sizeMismatches,
                "errors": Array(run.errors.prefix(5)),
            ])
            if run.sizeMismatches != 0 || !run.errors.isEmpty { allOK = false }
        }
        r["afcRuns"] = runs
        r["afcCopiesKeptIn"] = afcDir.path

        if o.runICC && !o.iccFirst { runICCBaseline() }
        if o.runICC, (r["imageCaptureCore"] as? [String: Any])?["MBps"] != nil {
            let cmp = compareCopies(afc: afcDir, icc: Paths.dir("icc"), sample: sample)
            r["byteComparison"] = cmp
            log("      byte comparison with the AFC copies: \(cmp)")
        }

        if o.probePhotosDB {
            log("  (d) /PhotoData/Photos.sqlite")
            let dbr = probePhotosDB(udid: udid)
            r["photosDB"] = dbr
            log("      \(dbr)")
        }

        r["pass"] = allOK
        if !allOK { r["failure"] = "AFC copy reported errors or size mismatches" }
        return allOK
    } catch {
        r["pass"] = false
        r["failure"] = "\(error)"
        log("  FAIL: \(error)")
        return false
    }
}

/// Hashes matching files from both methods to see whether they're byte-identical.
func compareCopies(afc: URL, icc: URL, sample: [RemoteFile]) -> [String: Any] {
    var same = 0, different = 0, missing = 0
    for f in sample {
        let name = localName(f.path)
        let a = afc.appendingPathComponent(name), b = icc.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: a.path), FileManager.default.fileExists(atPath: b.path) else {
            missing += 1
            continue
        }
        if let x = try? sha256(file: a), let y = try? sha256(file: b), x == y { same += 1 } else { different += 1 }
    }
    return ["identical": same, "different": different, "notInBoth": missing]
}
