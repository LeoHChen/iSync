import CIMobileDevice
import Foundation

let probeLabel = "iSyncProbe"

func listDevices() -> [(udid: String, connection: String)] {
    var list: UnsafeMutablePointer<idevice_info_t?>? = nil
    var count: Int32 = 0
    guard idevice_get_device_list_extended(&list, &count) == IDEVICE_E_SUCCESS, let list else { return [] }
    defer { idevice_device_list_extended_free(list) }
    var out: [(String, String)] = []
    for i in 0..<Int(count) {
        guard let info = list[i]?.pointee else { continue }
        let conn = info.conn_type == CONNECTION_USBMUXD ? "USB" : "network"
        out.append((String(cString: info.udid), conn))
    }
    return out
}

final class Device {
    let udid: String
    let ptr: idevice_t

    init(udid: String) throws {
        var d: idevice_t? = nil
        let e = idevice_new_with_options(&d, udid, IDEVICE_LOOKUP_USBMUX)
        guard e == IDEVICE_E_SUCCESS, let d else { throw ProbeError("idevice_new failed: \(e.rawValue)") }
        self.udid = udid
        self.ptr = d
    }

    deinit { idevice_free(ptr) }
}

func lockdownErrorText(_ e: lockdownd_error_t) -> String {
    "\(String(cString: lockdownd_strerror(e))) (\(e.rawValue))"
}

/// Converts a plist node into Foundation types.
func foundationValue(_ p: plist_t?) -> Any? {
    guard let p else { return nil }
    var bin: UnsafeMutablePointer<CChar>? = nil
    var len: UInt32 = 0
    plist_to_bin(p, &bin, &len)
    guard let bin else { return nil }
    defer { plist_mem_free(bin) }
    let data = Data(bytes: bin, count: Int(len))
    return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
}

final class Lockdown {
    let client: lockdownd_client_t
    let device: Device

    init(device: Device) throws {
        var c: lockdownd_client_t? = nil
        let e = lockdownd_client_new_with_handshake(device.ptr, &c, probeLabel)
        guard e == LOCKDOWN_E_SUCCESS, let c else {
            throw ProbeError("lockdown handshake failed: \(lockdownErrorText(e))")
        }
        client = c
        self.device = device
    }

    deinit { lockdownd_client_free(client) }

    func value(domain: String? = nil, key: String? = nil) -> Any? {
        var node: plist_t? = nil
        guard lockdownd_get_value(client, domain, key, &node) == LOCKDOWN_E_SUCCESS else { return nil }
        defer { if let node { plist_free(node) } }
        return foundationValue(node)
    }
}

enum PairOutcome: CustomStringConvertible {
    case alreadyPaired, paired, denied, timedOut(String)
    var description: String {
        switch self {
        case .alreadyPaired: return "already paired"
        case .paired: return "paired just now"
        case .denied: return "user denied the Trust prompt"
        case .timedOut(let why): return "timed out: \(why)"
        }
    }
    var ok: Bool {
        switch self {
        case .alreadyPaired, .paired: return true
        default: return false
        }
    }
}

/// Confirms pairing and, if it's missing, asks the phone to show the Trust prompt.
func ensurePaired(udid: String, waitSeconds: Double) throws -> PairOutcome {
    let device = try Device(udid: udid)
    if (try? Lockdown(device: device)) != nil { return .alreadyPaired }

    var c: lockdownd_client_t? = nil
    let e = lockdownd_client_new(device.ptr, &c, probeLabel)
    guard e == LOCKDOWN_E_SUCCESS, let c else {
        throw ProbeError("lockdown connect failed: \(lockdownErrorText(e))")
    }
    defer { lockdownd_client_free(c) }

    let deadline = Date().addingTimeInterval(waitSeconds)
    var last = ""
    while true {
        let r = lockdownd_pair(c, nil)
        if r == LOCKDOWN_E_SUCCESS { return .paired }
        if r == LOCKDOWN_E_USER_DENIED_PAIRING { return .denied }
        let text = lockdownErrorText(r)
        if text != last {
            switch r {
            case LOCKDOWN_E_PASSWORD_PROTECTED: log("  waiting: unlock the iPhone")
            case LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING: log("  waiting: tap Trust on the iPhone")
            default: log("  waiting: \(text)")
            }
            last = text
        }
        if Date() > deadline { return .timedOut(text) }
        Thread.sleep(forTimeInterval: 3)
    }
}
