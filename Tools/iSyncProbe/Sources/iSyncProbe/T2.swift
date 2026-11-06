import CIMobileDevice
import Foundation

struct FileSharingApp {
    let bundleID: String
    let name: String
}

func listFileSharingApps(device: Device) throws -> (all: Int, sharing: [FileSharingApp]) {
    var client: instproxy_client_t? = nil
    let e = instproxy_client_start_service(device.ptr, &client, probeLabel)
    guard e == INSTPROXY_E_SUCCESS, let client else {
        throw ProbeError("installation_proxy start failed: \(e.rawValue)")
    }
    defer { instproxy_client_free(client) }
    // instproxy_client_options_add is variadic and can't be called from Swift,
    // so the options are built by hand.
    let opts = plist_new_dict()
    defer { plist_free(opts) }
    plist_dict_set_item(opts, "ApplicationType", plist_new_string("User"))
    let attrs = plist_new_array()
    for a in ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "UIFileSharingEnabled"] {
        plist_array_append_item(attrs, plist_new_string(a))
    }
    plist_dict_set_item(opts, "ReturnAttributes", attrs)
    var result: plist_t? = nil
    let be = instproxy_browse(client, opts, &result)
    guard be == INSTPROXY_E_SUCCESS, let result else { throw ProbeError("browse failed: \(be.rawValue)") }
    defer { plist_free(result) }
    let apps = foundationValue(result) as? [[String: Any]] ?? []
    let sharing = apps.compactMap { a -> FileSharingApp? in
        guard (a["UIFileSharingEnabled"] as? Bool) == true, let id = a["CFBundleIdentifier"] as? String else { return nil }
        return FileSharingApp(bundleID: id, name: (a["CFBundleDisplayName"] as? String) ?? (a["CFBundleName"] as? String) ?? id)
    }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    return (apps.count, sharing)
}

final class HouseArrest {
    let ptr: house_arrest_client_t
    let device: Device

    init(device: Device) throws {
        var c: house_arrest_client_t? = nil
        let e = house_arrest_client_start_service(device.ptr, &c, probeLabel)
        guard e == HOUSE_ARREST_E_SUCCESS, let c else {
            throw ProbeError("house_arrest start failed: \(e.rawValue)")
        }
        ptr = c
        self.device = device
    }

    deinit { house_arrest_client_free(ptr) }

    func vendDocuments(_ bundleID: String) throws -> AFC {
        let e = house_arrest_send_command(ptr, "VendDocuments", bundleID)
        guard e == HOUSE_ARREST_E_SUCCESS else { throw ProbeError("VendDocuments send failed: \(e.rawValue)") }
        var res: plist_t? = nil
        house_arrest_get_result(ptr, &res)
        defer { if let res { plist_free(res) } }
        let dict = foundationValue(res) as? [String: Any] ?? [:]
        if let err = dict["Error"] { throw ProbeError("VendDocuments: \(err)") }
        var afc: afc_client_t? = nil
        let ae = afc_client_new_from_house_arrest_client(ptr, &afc)
        guard ae == AFC_E_SUCCESS, let afc else { throw ProbeError("afc over house_arrest failed: \(ae.rawValue)") }
        return AFC(raw: afc, owners: [self])
    }
}

func t2(udid: String, preferredBundle: String?) -> Bool {
    log("\n== T2 Files: \(udid)")
    var r: [String: Any] = ["test": "T2"]
    defer { writeResult(udid: udid, name: "t2", r) }
    do {
        let device = try Device(udid: udid)
        let apps = try listFileSharingApps(device: device)
        r["userApps"] = apps.all
        r["fileSharingApps"] = apps.sharing.count
        log("  user apps: \(apps.all), with file sharing: \(apps.sharing.count)")
        guard !apps.sharing.isEmpty else {
            r["pass"] = false
            r["failure"] = "no installed app enables UIFileSharingEnabled"
            log("  FAIL: \(r["failure"]!)")
            return false
        }
        var order = apps.sharing
        if let p = preferredBundle, let i = order.firstIndex(where: { $0.bundleID == p }) {
            order.insert(order.remove(at: i), at: 0)
        }

        var attempts: [String] = []
        for app in order.prefix(5) {
            log("  trying \(app.name) (\(app.bundleID))")
            do {
                let ha = try HouseArrest(device: device)
                let afc = try ha.vendDocuments(app.bundleID)
                let path = "/Documents/iSyncProbe-test-\(UUID().uuidString).bin"
                var bytes = Data(count: 1 << 20)
                bytes.withUnsafeMutableBytes { p in
                    _ = SecRandomCopyBytes(kSecRandomDefault, p.count, p.baseAddress!)
                }
                let want = sha256(bytes)
                let t0 = Date()
                try afc.write(path, data: bytes)
                let up = Date().timeIntervalSince(t0)
                let t1 = Date()
                let back = try afc.readAll(path)
                let down = Date().timeIntervalSince(t1)
                let got = sha256(back)
                try afc.remove(path)
                let gone = afc.info(path) == nil
                r["app"] = app.name
                r["bundleID"] = app.bundleID
                r["sha256Match"] = want == got
                r["removed"] = gone
                r["uploadMBps"] = 1.048576 / up
                r["downloadMBps"] = 1.048576 / down
                log(String(format: "  1 MB up %.1f MB/s, down %.1f MB/s", 1.048576 / up, 1.048576 / down))
                log("  sha256 match: \(want == got), test file removed: \(gone)")
                r["pass"] = want == got && gone
                if want != got { r["failure"] = "SHA-256 mismatch" }
                if !gone { r["failure"] = "test file still present after delete" }
                return want == got && gone
            } catch {
                attempts.append("\(app.bundleID): \(error)")
                log("    failed: \(error)")
            }
        }
        r["pass"] = false
        r["failure"] = attempts.joined(separator: "; ")
        return false
    } catch {
        r["pass"] = false
        r["failure"] = "\(error)"
        log("  FAIL: \(error)")
        return false
    }
}
