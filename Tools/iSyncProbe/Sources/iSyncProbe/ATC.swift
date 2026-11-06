import CoreFoundation
import Foundation

/// Apple's private AirTrafficHost framework, loaded at runtime.
///
/// iSync deliberately leaves the Grappa handshake and any signing to Apple's own
/// code, as the plan says. This file doesn't replay captured Grappa blobs, carry
/// its own CIG signing, or use private entitlements. If Apple's code won't complete
/// the handshake from this process, the test records how far it got and stops.
final class AirTrafficHost {
    static let frameworkPaths = [
        "/System/Library/PrivateFrameworks/AirTrafficHost.framework/AirTrafficHost",
        "/Library/Apple/System/Library/PrivateFrameworks/AirTrafficHost.framework/Versions/A/AirTrafficHost",
    ]
    static let mobileDevicePaths = [
        "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
        "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/Versions/A/MobileDevice",
    ]

    let handle: UnsafeMutableRawPointer
    let loadedFrom: String
    let mobileDevice: UnsafeMutableRawPointer
    let mobileDeviceFrom: String

    typealias Conn = UnsafeMutableRawPointer
    typealias Msg = UnsafeMutableRawPointer

    let createWithLibrary: @convention(c) (CFString, CFString, UInt32) -> Conn?
    let sendHostInfo: @convention(c) (Conn, CFDictionary) -> Int
    let sendPowerAssertion: @convention(c) (Conn, CFBoolean) -> Int
    let sendSyncRequest: @convention(c) (Conn, CFArray, CFDictionary, CFDictionary) -> Int
    let readMessage: @convention(c) (Conn) -> Msg?
    let grappaSessionID: @convention(c) (Conn) -> UInt32
    let currentSessionNumber: @convention(c) (Conn) -> UInt32
    let invalidate: @convention(c) (Conn) -> Int
    let release: @convention(c) (Conn) -> Void
    let messageName: @convention(c) (Msg) -> Unmanaged<CFString>?
    let messageParam: @convention(c) (Msg, CFString) -> Unmanaged<CFTypeRef>?

    init() throws {
        func open(_ paths: [String]) throws -> (UnsafeMutableRawPointer, String) {
            var errors: [String] = []
            for p in paths {
                if let h = dlopen(p, RTLD_NOW) { return (h, p) }
                errors.append("\(p): \(String(cString: dlerror()))")
            }
            throw ProbeError("dlopen failed: \(errors.joined(separator: "; "))")
        }
        (mobileDevice, mobileDeviceFrom) = try open(Self.mobileDevicePaths)
        (handle, loadedFrom) = try open(Self.frameworkPaths)
        let h = handle
        func sym<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let p = dlsym(h, name) else { throw ProbeError("missing symbol \(name)") }
            return unsafeBitCast(p, to: T.self)
        }
        createWithLibrary = try sym("ATHostConnectionCreateWithLibrary", (@convention(c) (CFString, CFString, UInt32) -> Conn?).self)
        sendHostInfo = try sym("ATHostConnectionSendHostInfo", (@convention(c) (Conn, CFDictionary) -> Int).self)
        sendPowerAssertion = try sym("ATHostConnectionSendPowerAssertion", (@convention(c) (Conn, CFBoolean) -> Int).self)
        sendSyncRequest = try sym("ATHostConnectionSendSyncRequest", (@convention(c) (Conn, CFArray, CFDictionary, CFDictionary) -> Int).self)
        readMessage = try sym("ATHostConnectionReadMessage", (@convention(c) (Conn) -> Msg?).self)
        grappaSessionID = try sym("ATHostConnectionGetGrappaSessionId", (@convention(c) (Conn) -> UInt32).self)
        currentSessionNumber = try sym("ATHostConnectionGetCurrentSessionNumber", (@convention(c) (Conn) -> UInt32).self)
        invalidate = try sym("ATHostConnectionInvalidate", (@convention(c) (Conn) -> Int).self)
        release = try sym("ATHostConnectionRelease", (@convention(c) (Conn) -> Void).self)
        messageName = try sym("ATCFMessageGetName", (@convention(c) (Msg) -> Unmanaged<CFString>?).self)
        messageParam = try sym("ATCFMessageGetParam", (@convention(c) (Msg, CFString) -> Unmanaged<CFTypeRef>?).self)
    }
}

extension AirTrafficHost {
    /// CFBundleVersion of AirTrafficHost.framework on this Mac.
    var frameworkVersion: String {
        let path = "/System/Library/PrivateFrameworks/AirTrafficHost.framework/Resources/Info.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleVersion"] as? String
        else { return "" }
        return version
    }
}

private let seenDevices = Locked<Set<String>>([])
private var copyDeviceIdentifier: (@convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>)?

extension AirTrafficHost {
    /// Lets MobileDevice discover the phone, which AirTrafficHost needs before it can connect.
    func waitForDevice(udid: String, timeout: TimeInterval) -> Bool {
        typealias Callback = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>, UnsafeMutableRawPointer?) -> Void
        typealias Subscribe = @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
        guard let s = dlsym(mobileDevice, "AMDeviceNotificationSubscribe"),
              let c = dlsym(mobileDevice, "AMDeviceCopyDeviceIdentifier")
        else { return false }
        copyDeviceIdentifier = unsafeBitCast(c, to: (@convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>).self)
        let subscribe = unsafeBitCast(s, to: Subscribe.self)
        var note: UnsafeMutableRawPointer?
        let rc = subscribe({ info, _ in
            guard let device = info[0], let identify = copyDeviceIdentifier else { return }
            let id = identify(device).takeRetainedValue() as String
            seenDevices.with { _ = $0.insert(id) }
        }, 0, 0, nil, &note)
        guard rc == 0 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.1, false)
            if seenDevices.with({ $0.contains(udid) }) { return true }
        }
        return false
    }
}

/// Keeps the same library ID across runs, so the phone only ever sees one host library.
func iSyncLibraryID() -> String {
    let url = Paths.out.appendingPathComponent("library-id.txt")
    if let s = try? String(contentsOf: url, encoding: .utf8) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
    }
    let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).uppercased()
    try? id.write(to: url, atomically: true, encoding: .utf8)
    return id
}

struct ATCEvent {
    let ms: Int
    let kind: String
    let detail: String
    var json: [String: Any] { ["ms": ms, "kind": kind, "detail": detail] }
}

/// Starts `log stream` for this process so the framework's own messages are saved.
final class HostLogCapture {
    private let process = Process()
    private let handle: FileHandle?
    let url: URL

    init(name: String) {
        url = Paths.dir("logs").appendingPathComponent("\(name)-host.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--level", "debug", "--style", "compact",
            "--predicate", "processID == \(getpid()) OR process == \"fairplayd\" OR process == \"AMPDevicesAgent\"",
        ]
        if let handle {
            process.standardOutput = handle
            process.standardError = handle
        }
        try? process.run()
        Thread.sleep(forTimeInterval: 1)
    }

    func stop() {
        Thread.sleep(forTimeInterval: 1)
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? handle?.close()
    }

    /// Returns lines that mention the handshake.
    func interestingLines(limit: Int = 40) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let keys = ["grappa", "fairplay", "fpsd", "corefp", "entitle", "athostconnection", "airtraffic", "syncfailed", "denied"]
        let hits = text.components(separatedBy: "\n").filter { line in
            let l = line.lowercased()
            return keys.contains { l.contains($0) }
        }
        return Array(hits.suffix(limit)).map { String($0.prefix(240)) }
    }
}

/// Saves the phone's own ATC log lines, as a cross-check only.
final class DeviceLogCapture {
    private let process = Process()
    private let handle: FileHandle?
    let url: URL

    init(name: String, udid: String) {
        url = Paths.dir("logs").appendingPathComponent("\(name)-device.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/idevicesyslog")
        process.arguments = ["-u", udid, "--no-colors", "--process", "atc|medialibraryd|assetsd|fairplayd"]
        if let handle {
            process.standardOutput = handle
            process.standardError = handle
        }
        try? process.run()
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? handle?.close()
    }

    func interestingLines(limit: Int = 40) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let keys = ["grappa", "sync", "host", "error", "fail", "denied", "auth"]
        let hits = text.components(separatedBy: "\n").filter { line in
            let l = line.lowercased()
            return keys.contains { l.contains($0) }
        }
        return Array(hits.suffix(limit)).map { String($0.prefix(240)) }
    }
}

/// Runs the ATC handshake through Apple's framework and records each stage.
final class ATCSession {
    let ath: AirTrafficHost
    let udid: String
    let timeout: TimeInterval
    private let t0 = Date()
    private let events = Locked<[ATCEvent]>([])
    private let seen = Locked<[String]>([])
    private let messages = Locked<[String: String]>([:])
    private let stopping = Locked(false)
    private var conn: AirTrafficHost.Conn?
    private let libraryID = iSyncLibraryID()
    private let readerDone = DispatchSemaphore(value: 0)

    var stages: [String: Any] = [:]

    init(ath: AirTrafficHost, udid: String, timeout: TimeInterval) {
        self.ath = ath
        self.udid = udid
        self.timeout = timeout
    }

    func event(_ kind: String, _ detail: String) {
        let e = ATCEvent(ms: Int(Date().timeIntervalSince(t0) * 1000), kind: kind, detail: detail)
        events.with { $0.append(e) }
        log(String(format: "    %6.2fs %@ %@", Double(e.ms) / 1000, kind, String(detail.prefix(300))))
    }

    var timeline: [[String: Any]] { events.with { $0.map(\.json) } }

    /// Reads the parameters that explain the phone's answer. Grappa data is only ever
    /// described by its length, and is never saved.
    private func describe(_ msg: AirTrafficHost.Msg) -> String {
        var parts: [String] = []
        for key in ["ErrorCode", "RequiredVersion", "Reason", "Allowed", "Dataclasses", "DataclassAnchors", "DeviceInfo", "SyncTypes"] {
            guard let v = ath.messageParam(msg, key as CFString)?.takeUnretainedValue() else { continue }
            parts.append("\(key)=\(summary(v))")
        }
        return parts.joined(separator: " ")
    }

    private func summary(_ value: CFTypeRef) -> String {
        if CFGetTypeID(value) == CFDataGetTypeID() {
            return "<\(CFDataGetLength((value as! CFData))) bytes>"
        }
        if CFGetTypeID(value) == CFDictionaryGetTypeID(), let d = value as? [String: Any] {
            let inner = d.map { k, v -> String in
                if let data = v as? Data { return "\(k)=<\(data.count) bytes>" }
                return "\(k)=\(String(describing: v).prefix(80))"
            }
            return "{" + inner.sorted().joined(separator: ", ") + "}"
        }
        return String((CFCopyDescription(value) as String).prefix(160))
    }

    private func startReader() {
        let thread = Thread { [self] in
            defer { readerDone.signal() }
            guard let conn else { return }
            var nils = 0
            while !stopping.with({ $0 }) {
                guard let m = ath.readMessage(conn) else {
                    nils += 1
                    if nils >= 3 {
                        event("read", "ATHostConnectionReadMessage returned nothing \(nils) times, so the connection is closed")
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                    continue
                }
                nils = 0
                let name = ath.messageName(m)?.takeUnretainedValue() as String? ?? "(unnamed)"
                let desc = describe(m)
                seen.with { $0.append(name) }
                messages.with { $0[name] = desc }
                event("recv", desc.isEmpty ? name : "\(name) \(desc)")
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Waits for one of `names` while keeping the run loop serviced.
    private func waitFor(_ names: Set<String>, timeout t: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(t)
        var index = seen.with { $0.count }
        // Messages that have already arrived count too.
        if let hit = seen.with({ $0.first(where: { names.contains($0) }) }) { return hit }
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.1, false)
            let found: String? = seen.with { list in
                defer { index = list.count }
                return list[min(index, list.count)...].first(where: { names.contains($0) })
            }
            if let found { return found }
        }
        return nil
    }

    func message(_ name: String) -> String? { messages.with { $0[name] } }
    var allSeen: [String] { seen.with { $0 } }

    /// Returns the furthest stage reached. Stops at the first stage that fails.
    func handshake(dataclasses: [String], anchors: [String: String]) -> String {
        let host = Host.current().localizedName ?? "iSync Mac"
        event("create", "ATHostConnectionCreateWithLibrary library=\(libraryID)")
        guard let c = ath.createWithLibrary(libraryID as CFString, udid as CFString, 0) else {
            event("error", "ATHostConnectionCreateWithLibrary returned NULL")
            return "connection-create-failed"
        }
        conn = c
        startReader()
        stages["connectionCreated"] = true
        CFRunLoopRunInMode(.defaultMode, 0.5, false)

        // The phone rejects a request with no host version. This is the real version of Apple's
        // framework, which is what's actually acting as the host here.
        let version = ath.frameworkVersion
        stages["hostVersionSent"] = version
        let hostInfo: [String: Any] = [
            "LibraryID": libraryID,
            "SyncHostName": host,
            "SyncedDataclasses": [String](),
            "Version": version,
        ]
        event("send", "SendPowerAssertion rc=\(ath.sendPowerAssertion(c, kCFBooleanTrue))")
        event("send", "SendHostInfo rc=\(ath.sendHostInfo(c, hostInfo as CFDictionary))")

        event("wait", "SyncAllowed, up to \(Int(timeout)) s")
        guard waitFor(["SyncAllowed"], timeout: timeout) != nil else {
            stages["syncAllowed"] = false
            event("result", "No SyncAllowed. Messages seen: \(allSeen)")
            return "host-info-sent"
        }
        stages["syncAllowed"] = true
        let g0 = ath.grappaSessionID(c)
        stages["grappaSessionBeforeRequest"] = Int(g0)
        event("info", "Grappa session id before sync request: \(g0)")

        // The last argument is merged into the request's HostInfo, beside Apple's Grappa data.
        let rc = ath.sendSyncRequest(
            c, dataclasses as CFArray, anchors as CFDictionary, hostInfo as CFDictionary)
        stages["sendSyncRequestReturn"] = rc
        event("send", "SendSyncRequest dataclasses=\(dataclasses) rc=\(rc)")

        event("wait", "ReadyForSync or SyncFailed, up to \(Int(timeout)) s")
        let outcome = waitFor(["ReadyForSync", "SyncFailed"], timeout: timeout)
        let g1 = ath.grappaSessionID(c)
        stages["grappaSessionAfterRequest"] = Int(g1)
        stages["grappaEstablished"] = g1 != 0
        event("info", "Grappa session id after sync request: \(g1), session number \(ath.currentSessionNumber(c))")
        switch outcome {
        case "ReadyForSync":
            stages["readyForSync"] = true
            return "ready-for-sync"
        case "SyncFailed":
            stages["readyForSync"] = false
            stages["syncFailed"] = message("SyncFailed") ?? ""
            return "sync-failed-after-request"
        default:
            stages["readyForSync"] = false
            event("result", "No reply to the sync request. Messages seen: \(allSeen)")
            return "no-reply-to-sync-request"
        }
    }

    func close() {
        stopping.with { $0 = true }
        guard let c = conn else { return }
        event("send", "SendPowerAssertion(false) rc=\(ath.sendPowerAssertion(c, kCFBooleanFalse))")
        event("send", "Invalidate rc=\(ath.invalidate(c))")
        // ReadMessage can stay blocked after the connection closes, so only wait briefly.
        // Releasing the connection under a blocked read would crash and lose these results.
        if readerDone.wait(timeout: .now() + 3) == .timedOut {
            event("info", "reader thread still blocked after close, so the connection was left to process exit")
        } else {
            ath.release(c)
        }
        conn = nil
    }
}
