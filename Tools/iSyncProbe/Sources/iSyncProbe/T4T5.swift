import Foundation

/// Runs preflight and decides whether an ATC session may be opened.
func atcAllowed(udid: String, approvedRisk: Bool) -> (allowed: Bool, verdict: SyncVerdict, detail: [String: Any]) {
    let p = preflight(udid: udid)
    if p.verdict == .clean { return (true, p.verdict, p.detail) }
    // The owner's approval covered a phone with old sync traces and no synced content. If
    // synced content has appeared, that's new information and the approval doesn't cover it.
    if approvedRisk && p.verdict == .unknown {
        log("  preflight is \(p.verdict.rawValue), continuing because --user-approved-sync-risk was passed")
        return (true, p.verdict, p.detail)
    }
    log("  STOP: preflight is \(p.verdict.rawValue). No ATC session was opened. The owner needs to decide.")
    return (false, p.verdict, p.detail)
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
    let seen = ath.waitForDevice(udid: udid, timeout: 8)
    r["deviceSeenByMobileDevice"] = seen
    log("  MobileDevice sees this phone: \(seen)")
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
    r["scope"] = "Handshake only. No album, photo or sync metadata is sent."
    let atc = runATC(testName: "t4", udid: udid, timeout: timeout, dataclasses: ["Photo", "Keybag"], anchors: ["Photo": "0"])
    r.merge(atc) { _, new in new }
    r["pass"] = false
    if atc["stage"] as? String == "ready-for-sync" {
        r["failure"] = "Reached ReadyForSync and stopped there, as approved. Nothing was added."
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

    r["scope"] = "Handshake only. No song, file or sync metadata is sent."

    let atc = runATC(testName: "t5", udid: udid, timeout: timeout, dataclasses: ["Media", "Keybag"], anchors: ["Media": "0"])
    r.merge(atc) { _, new in new }
    r["pass"] = false
    if atc["stage"] as? String == "ready-for-sync" {
        r["failure"] = "Reached ReadyForSync and stopped there, as approved. Nothing was added."
    } else {
        r["failure"] = "Stopped at stage: \(atc["stage"] ?? "?")"
    }
    return false
}
