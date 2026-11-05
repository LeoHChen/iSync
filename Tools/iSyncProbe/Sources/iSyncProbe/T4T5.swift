import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Runs preflight and decides whether an ATC session may be opened.
func atcAllowed(udid: String, approvedRisk: Bool) -> (allowed: Bool, verdict: SyncVerdict, detail: [String: Any]) {
    let p = preflight(udid: udid)
    if p.verdict == .clean { return (true, p.verdict, p.detail) }
    if approvedRisk {
        log("  preflight is \(p.verdict.rawValue), continuing because --user-approved-sync-risk was passed")
        return (true, p.verdict, p.detail)
    }
    log("  STOP: preflight is \(p.verdict.rawValue). No ATC session was opened. The owner needs to decide.")
    return (false, p.verdict, p.detail)
}

/// Builds the small test photo locally, so it holds no personal data.
func makeTestJPEG() throws -> URL {
    let url = Paths.dir("media").appendingPathComponent("iSync-test.jpg")
    let (w, h) = (1024, 768)
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ProbeError("CGContext failed") }
    for y in 0..<h {
        ctx.setFillColor(red: 0.1, green: 0.3 + 0.5 * CGFloat(y) / CGFloat(h), blue: 0.7, alpha: 1)
        ctx.fill(CGRect(x: 0, y: y, width: w, height: 1))
    }
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw ProbeError("JPEG encoder failed") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw ProbeError("JPEG write failed") }
    return url
}

/// Speaks a short phrase, converts it to AAC and adds a title tag.
func makeTestSong() throws -> URL {
    let dir = Paths.dir("media")
    let aiff = dir.appendingPathComponent("t.aiff")
    let raw = dir.appendingPathComponent("t-raw.m4a")
    let out = dir.appendingPathComponent("iSync-test-song.m4a")
    for u in [aiff, raw, out] { try? FileManager.default.removeItem(at: u) }
    let say = runTool("/usr/bin/say", ["-o", aiff.path, "iSync test"])
    guard say.code == 0 else { throw ProbeError("say failed: \(say.output)") }
    let conv = runTool("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", aiff.path, raw.path])
    guard conv.code == 0 else { throw ProbeError("afconvert failed: \(conv.output)") }

    let asset = AVURLAsset(url: raw)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        throw ProbeError("AVAssetExportSession unavailable")
    }
    let title = AVMutableMetadataItem()
    title.identifier = .commonIdentifierTitle
    title.value = "iSync Test Song" as NSString
    title.extendedLanguageTag = "und"
    export.metadata = [title]
    export.outputURL = out
    export.outputFileType = .m4a
    let done = DispatchSemaphore(value: 0)
    export.exportAsynchronously { done.signal() }
    done.wait()
    guard export.status == .completed else {
        throw ProbeError("tagging failed: \(export.error.map { "\($0)" } ?? "unknown")")
    }
    return out
}

/// Runs the part T4 and T5 share. Returns the furthest stage reached.
func runATC(testName: String, udid: String, timeout: Double, dataclasses: [String], anchors: [String: String]) -> [String: Any] {
    var r: [String: Any] = [:]
    let ath: AirTrafficHost
    do {
        ath = try AirTrafficHost()
    } catch {
        r["framework"] = "\(error)"
        r["stage"] = "framework-not-loaded"
        return r
    }
    r["framework"] = ath.loadedFrom
    r["mobileDeviceFramework"] = ath.mobileDeviceFrom
    log("  dlopen OK: \(ath.loadedFrom)")

    let hostLog = HostLogCapture(name: "\(testName)-\(udid)")
    let deviceLog = DeviceLogCapture(name: "\(testName)-\(udid)", udid: udid)
    let session = ATCSession(ath: ath, udid: udid, timeout: timeout)
    let stage = session.handshake(dataclasses: dataclasses, anchors: anchors)
    r["stage"] = stage
    r["stages"] = session.stages
    log("  furthest stage: \(stage)")
    session.close()
    Thread.sleep(forTimeInterval: 1)
    hostLog.stop()
    deviceLog.stop()
    r["timeline"] = session.timeline
    r["messagesSeen"] = session.allSeen
    r["hostLog"] = hostLog.url.path
    r["deviceLog"] = deviceLog.url.path
    let hostLines = hostLog.interestingLines()
    let deviceLines = deviceLog.interestingLines()
    r["hostLogHits"] = hostLines
    r["deviceLogHits"] = deviceLines
    log("  host log lines about the handshake: \(hostLines.count)")
    for l in hostLines.suffix(12) { log("    | \(l)") }
    log("  device log lines: \(deviceLines.count)")
    for l in deviceLines.suffix(12) { log("    | \(l)") }
    return r
}

func t4(udid: String, timeout: Double, approvedRisk: Bool) -> Bool {
    log("\n== T4 Add a photo to the iPhone over ATC: \(udid)")
    var r: [String: Any] = ["test": "T4"]
    defer { writeResult(udid: udid, name: "t4", r) }
    let gate = atcAllowed(udid: udid, approvedRisk: approvedRisk)
    r["preflightVerdict"] = gate.verdict.rawValue
    guard gate.allowed else {
        r["pass"] = false
        r["stage"] = "not-run-preflight-\(gate.verdict.rawValue)"
        r["failure"] = "Stopped before any ATC session: preflight verdict is \(gate.verdict.rawValue)."
        return false
    }
    do {
        let jpeg = try makeTestJPEG()
        r["testPhoto"] = jpeg.path
        log("  test photo: \(jpeg.path)")
    } catch {
        r["failure"] = "\(error)"
    }
    let atc = runATC(testName: "t4", udid: udid, timeout: timeout, dataclasses: ["Photo", "Keybag"], anchors: ["Photo": "0"])
    r.merge(atc) { _, new in new }
    r["pass"] = false
    if atc["stage"] as? String == "ready-for-sync" {
        r["failure"] = "Reached ReadyForSync. Uploading a photo isn't implemented yet, because this stage has never been reached."
    } else {
        r["failure"] = "Stopped at stage: \(atc["stage"] ?? "?")"
    }
    return false
}

func t5(udid: String, timeout: Double, approvedRisk: Bool) -> Bool {
    log("\n== T5 Add one song to the Music app over ATC: \(udid)")
    var r: [String: Any] = ["test": "T5"]
    defer { writeResult(udid: udid, name: "t5", r) }
    let gate = atcAllowed(udid: udid, approvedRisk: approvedRisk)
    r["preflightVerdict"] = gate.verdict.rawValue
    guard gate.allowed else {
        r["pass"] = false
        r["stage"] = "not-run-preflight-\(gate.verdict.rawValue)"
        r["failure"] = "Stopped before any ATC session: preflight verdict is \(gate.verdict.rawValue)."
        return false
    }

    // Tests AFC write access to the music folder separately from ATC, then removes the file.
    do {
        let song = try makeTestSong()
        r["testSong"] = song.path
        let data = try Data(contentsOf: song)
        log("  test song: \(song.path), \(data.count) bytes")
        let afc = try openAFC(udid: udid)
        let remote = "/iTunes_Control/Music/F00/ISYP\(Int.random(in: 1000...9999)).m4a"
        if afc.info("/iTunes_Control/Music/F00") == nil {
            r["afcUpload"] = "skipped: /iTunes_Control/Music/F00 doesn't exist"
            log("  AFC upload skipped: F00 doesn't exist")
        } else {
            try afc.write(remote, data: data)
            let back = try afc.readAll(remote)
            let match = sha256(back) == sha256(data)
            try afc.remove(remote)
            let gone = afc.info(remote) == nil
            r["afcUpload"] = ["sha256Match": match, "removed": gone] as [String: Any]
            log("  AFC upload to the music folder: sha256 match \(match), test file removed \(gone)")
        }
    } catch {
        r["afcUpload"] = "failed: \(error)"
        log("  AFC upload failed: \(error)")
    }

    let atc = runATC(testName: "t5", udid: udid, timeout: timeout, dataclasses: ["Media", "Keybag"], anchors: ["Media": "0"])
    r.merge(atc) { _, new in new }
    r["pass"] = false
    if atc["stage"] as? String == "ready-for-sync" {
        r["failure"] = "Reached ReadyForSync. Registering a song isn't implemented yet, because this stage has never been reached."
    } else {
        r["failure"] = "Stopped at stage: \(atc["stage"] ?? "?")"
    }
    return false
}
