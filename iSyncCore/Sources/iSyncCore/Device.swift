import CIMobileDevice
import Foundation

let clientLabel = "iSync"

public final class DeviceConnection {
    public let udid: String
    let ptr: idevice_t

    public init(udid: String) throws {
        var device: idevice_t? = nil
        let e = idevice_new_with_options(&device, udid, IDEVICE_LOOKUP_USBMUX)
        guard e == IDEVICE_E_SUCCESS, let device else {
            throw ISyncError("The iPhone isn't connected.")
        }
        self.udid = udid
        ptr = device
    }

    deinit { idevice_free(ptr) }
}

/// Converts a plist node into Foundation types.
func foundationValue(_ node: plist_t?) -> Any? {
    guard let node else { return nil }
    var bin: UnsafeMutablePointer<CChar>? = nil
    var length: UInt32 = 0
    plist_to_bin(node, &bin, &length)
    guard let bin else { return nil }
    defer { plist_mem_free(bin) }
    return try? PropertyListSerialization.propertyList(
        from: Data(bytes: bin, count: Int(length)), options: [], format: nil)
}

final class Lockdown {
    let client: lockdownd_client_t
    let device: DeviceConnection

    init(device: DeviceConnection) throws {
        var c: lockdownd_client_t? = nil
        let e = lockdownd_client_new_with_handshake(device.ptr, &c, clientLabel)
        guard e == LOCKDOWN_E_SUCCESS, let c else {
            throw ISyncError("Lockdown handshake failed: \(String(cString: lockdownd_strerror(e)))")
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

public enum PairingStatus: Equatable, Sendable {
    case paired
    case needsUnlock
    case waitingForTrust
    case denied
    case failed(String)
}

public enum DevicePairing {
    /// Checks pairing and, if it's missing, asks the phone to show the Trust prompt.
    /// Call it repeatedly until the status settles.
    public static func check(udid: String) -> PairingStatus {
        let device: DeviceConnection
        do { device = try DeviceConnection(udid: udid) } catch { return .failed(error.localizedDescription) }

        var session: lockdownd_client_t? = nil
        let handshake = lockdownd_client_new_with_handshake(device.ptr, &session, clientLabel)
        if handshake == LOCKDOWN_E_SUCCESS, let session {
            lockdownd_client_free(session)
            return .paired
        }
        if handshake == LOCKDOWN_E_PASSWORD_PROTECTED { return .needsUnlock }

        var client: lockdownd_client_t? = nil
        let opened = lockdownd_client_new(device.ptr, &client, clientLabel)
        guard opened == LOCKDOWN_E_SUCCESS, let client else {
            return .failed(String(cString: lockdownd_strerror(opened)))
        }
        defer { lockdownd_client_free(client) }

        let pair = lockdownd_pair(client, nil)
        switch pair {
        case LOCKDOWN_E_SUCCESS: return .paired
        case LOCKDOWN_E_PASSWORD_PROTECTED: return .needsUnlock
        case LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING: return .waitingForTrust
        case LOCKDOWN_E_USER_DENIED_PAIRING: return .denied
        default: return .failed(String(cString: lockdownd_strerror(pair)))
        }
    }
}

public struct DeviceSummary: Equatable, Sendable {
    public var udid: String
    public var name: String
    public var productType: String
    public var modelName: String
    public var iosVersion: String
    public var buildVersion: String
    public var storageTotal: Int64?
    public var storageFree: Int64?
    public var batteryPercent: Int?
    public var isCharging: Bool?

    public var storageUsed: Int64? {
        guard let storageTotal, let storageFree else { return nil }
        return storageTotal - storageFree
    }
}

public enum DeviceInfo {
    /// Only identifiers confirmed on a real device. Others show their raw ProductType.
    static let modelNames = ["iPhone17,2": "iPhone 16 Pro Max"]

    public static func modelName(productType: String) -> String {
        modelNames[productType] ?? productType
    }

    public static func read(udid: String) throws -> DeviceSummary {
        let device = try DeviceConnection(udid: udid)
        let lockdown = try Lockdown(device: device)
        let productType = lockdown.value(key: "ProductType") as? String ?? "iPhone"
        var s = DeviceSummary(
            udid: udid,
            name: lockdown.value(key: "DeviceName") as? String ?? "iPhone",
            productType: productType,
            modelName: modelName(productType: productType),
            iosVersion: lockdown.value(key: "ProductVersion") as? String ?? "",
            buildVersion: lockdown.value(key: "BuildVersion") as? String ?? "")

        if let disk = lockdown.value(domain: "com.apple.disk_usage") as? [String: Any] {
            s.storageTotal = (disk["TotalDataCapacity"] as? NSNumber)?.int64Value
            s.storageFree = (disk["TotalDataAvailable"] as? NSNumber)?.int64Value
        }
        if let battery = lockdown.value(domain: "com.apple.mobile.battery") as? [String: Any] {
            s.batteryPercent = (battery["BatteryCurrentCapacity"] as? NSNumber)?.intValue
            s.isCharging = (battery["BatteryIsCharging"] as? NSNumber)?.boolValue
        }
        // AFC reports storage too, if lockdown didn't.
        if s.storageTotal == nil || s.storageFree == nil, let afc = try? AFCClient(device: device) {
            let info = afc.deviceInfo()
            s.storageTotal = s.storageTotal ?? info["FSTotalBytes"].flatMap { Int64($0) }
            s.storageFree = s.storageFree ?? info["FSFreeBytes"].flatMap { Int64($0) }
        }
        return s
    }

    /// The USB link speed, such as "480 Mb/s", from system_profiler.
    public static func usbLinkSpeed(udid: String) -> String? {
        let serial = udid.replacingOccurrences(of: "-", with: "")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPUSBHostDataType"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains(serial) }) else { return nil }
        for line in lines[i...min(lines.count - 1, i + 8)] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Link Speed:") {
                return String(t.dropFirst("Link Speed:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

/// Watches usbmuxd for iPhones being plugged in and unplugged.
public final class DeviceWatcher {
    private var context: idevice_subscription_context_t?
    private let onChange: ([String]) -> Void
    // Events arrive on libusbmuxd's thread, so the list is read on another one.
    private let queue = DispatchQueue(label: "isync.device-watcher")

    public init(onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard context == nil else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        idevice_events_subscribe(&context, { _, userData in
            guard let userData else { return }
            let watcher = Unmanaged<DeviceWatcher>.fromOpaque(userData).takeUnretainedValue()
            watcher.queue.async { watcher.onChange(DeviceWatcher.connectedDevices()) }
        }, me)
        queue.async { [onChange] in onChange(Self.connectedDevices()) }
    }

    public func stop() {
        if let context { idevice_events_unsubscribe(context) }
        context = nil
    }

    /// UDIDs of iPhones connected over USB.
    public static func connectedDevices() -> [String] {
        var list: UnsafeMutablePointer<idevice_info_t?>? = nil
        var count: Int32 = 0
        guard idevice_get_device_list_extended(&list, &count) == IDEVICE_E_SUCCESS, let list else { return [] }
        defer { idevice_device_list_extended_free(list) }
        var out: [String] = []
        for i in 0..<Int(count) {
            guard let info = list[i]?.pointee, info.conn_type == CONNECTION_USBMUXD else { continue }
            out.append(String(cString: info.udid))
        }
        return out
    }
}
