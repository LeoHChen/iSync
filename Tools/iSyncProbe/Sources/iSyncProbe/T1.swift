import CIMobileDevice
import Foundation

/// Reads USB link speed from system_profiler and port state from IOKit.
func usbLinkInfo(udid: String) -> [String: Any] {
    var out: [String: Any] = [:]
    let serial = udid.replacingOccurrences(of: "-", with: "")
    let sp = runTool("/usr/sbin/system_profiler", ["SPUSBHostDataType"]).output
    let lines = sp.components(separatedBy: "\n")
    if let i = lines.firstIndex(where: { $0.contains(serial) }) {
        let window = lines[max(0, i - 6)...min(lines.count - 1, i + 8)]
        for l in window {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Link Speed:") { out["linkSpeed"] = String(t.dropFirst(11)).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("Location ID:") { out["locationID"] = String(t.dropFirst(12)).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("Power Allocated:") { out["powerAllocated"] = String(t.dropFirst(16)).trimmingCharacters(in: .whitespaces) }
        }
    }
    // A USB-C port lists its negotiated transports and whether the cable reports
    // itself as active. No USB3 in TransportsActive means the link came up as USB 2.
    let reg = runTool("/usr/sbin/ioreg", ["-p", "IOService", "-rc", "AppleHPMInterfaceType10", "-w0"]).output
    var ports: [[String: String]] = []
    var cur: [String: String] = [:]
    for raw in reg.components(separatedBy: "\n") {
        let l = raw.replacingOccurrences(of: "|", with: " ").trimmingCharacters(in: .whitespaces)
        for key in ["PortDescription", "TransportsActive", "ActiveCable", "OpticalCable", "ConnectionActive"] {
            if l.hasPrefix("\"\(key)\" = ") {
                cur[key] = String(l.dropFirst(key.count + 5)).replacingOccurrences(of: "\"", with: "")
            }
        }
        if l.hasPrefix("+-o Port-USB-C") {
            if !cur.isEmpty { ports.append(cur) }
            cur = [:]
        }
    }
    if !cur.isEmpty { ports.append(cur) }
    let active = ports.filter { $0["ConnectionActive"] == "Yes" }
    out["usbcPorts"] = active
    let usb3 = active.contains { ($0["TransportsActive"] ?? "").contains("USB3") }
    out["cableAssessment"] = usb3
        ? "A port negotiated USB 3 or faster."
        : "No active port negotiated USB3. The link is USB 2, usually because of a USB 2 cable. iOS doesn't report the cable's identity."
    return out
}

func t1(udid: String, conn: String, wait: Double) -> Bool {
    log("\n== T1 Connect: \(udid)")
    var r: [String: Any] = ["udid": udid, "connection": conn, "test": "T1"]
    defer { writeResult(udid: udid, name: "t1", r) }
    do {
        let outcome = try ensurePaired(udid: udid, waitSeconds: wait)
        r["pairing"] = outcome.description
        log("  pairing: \(outcome)")
        guard outcome.ok else {
            r["pass"] = false
            r["failure"] = "pairing: \(outcome)"
            return false
        }
        let device = try Device(udid: udid)
        let lockdown = try Lockdown(device: device)
        for k in ["DeviceName", "ProductType", "ProductVersion", "BuildVersion", "PasswordProtected"] {
            let v = lockdown.value(key: k)
            r[k] = v ?? NSNull()
            log("  \(k): \(v ?? "nil")")
        }
        let link = usbLinkInfo(udid: udid)
        r["usb"] = link
        log("  USB link speed: \(link["linkSpeed"] ?? "unknown")")
        if let ports = link["usbcPorts"] as? [[String: String]] {
            for p in ports {
                log("  port \(p["PortDescription"] ?? "?"): transports \(p["TransportsActive"] ?? "?"), active cable \(p["ActiveCable"] ?? "?")")
            }
        }
        log("  cable: \(link["cableAssessment"] ?? "")")
        r["pass"] = true
        return true
    } catch {
        r["pass"] = false
        r["failure"] = "\(error)"
        log("  FAIL: \(error)")
        return false
    }
}
