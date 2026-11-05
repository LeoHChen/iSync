import CIMobileDevice
import Foundation

public struct SharedApp: Identifiable, Hashable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
}

public struct DocumentEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date
}

public enum SharedApps {
    /// Lists installed apps that allow file sharing.
    public static func list(udid: String) throws -> [SharedApp] {
        let device = try DeviceConnection(udid: udid)
        var client: instproxy_client_t? = nil
        let e = instproxy_client_start_service(device.ptr, &client, clientLabel)
        guard e == INSTPROXY_E_SUCCESS, let client else {
            throw ISyncError("Couldn't list the iPhone's apps.")
        }
        defer { instproxy_client_free(client) }
        // instproxy_client_options_add is variadic and can't be called from Swift.
        let options = plist_new_dict()
        defer { plist_free(options) }
        plist_dict_set_item(options, "ApplicationType", plist_new_string("User"))
        let attributes = plist_new_array()
        for a in ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "UIFileSharingEnabled"] {
            plist_array_append_item(attributes, plist_new_string(a))
        }
        plist_dict_set_item(options, "ReturnAttributes", attributes)
        var result: plist_t? = nil
        guard instproxy_browse(client, options, &result) == INSTPROXY_E_SUCCESS, let result else {
            throw ISyncError("Couldn't list the iPhone's apps.")
        }
        defer { plist_free(result) }
        let apps = foundationValue(result) as? [[String: Any]] ?? []
        return apps.compactMap { app -> SharedApp? in
            guard (app["UIFileSharingEnabled"] as? Bool) == true, let id = app["CFBundleIdentifier"] as? String else { return nil }
            let name = (app["CFBundleDisplayName"] as? String) ?? (app["CFBundleName"] as? String) ?? id
            return SharedApp(bundleID: id, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// One app's Documents folder. Use it from one thread at a time.
public final class AppDocumentsSession {
    public static let rootPath = "/Documents"
    private let houseArrest: house_arrest_client_t
    private let device: DeviceConnection
    private var afc: AFCClient?

    public init(udid: String, bundleID: String) throws {
        device = try DeviceConnection(udid: udid)
        var client: house_arrest_client_t? = nil
        let e = house_arrest_client_start_service(device.ptr, &client, clientLabel)
        guard e == HOUSE_ARREST_E_SUCCESS, let client else {
            throw ISyncError("Couldn't open the app's files.")
        }
        houseArrest = client
        guard house_arrest_send_command(client, "VendDocuments", bundleID) == HOUSE_ARREST_E_SUCCESS else {
            house_arrest_client_free(client)
            throw ISyncError("Couldn't open the app's files.")
        }
        var response: plist_t? = nil
        house_arrest_get_result(client, &response)
        defer { if let response { plist_free(response) } }
        if let error = (foundationValue(response) as? [String: Any])?["Error"] {
            house_arrest_client_free(client)
            throw ISyncError("The iPhone wouldn't open this app's files: \(error)")
        }
        var raw: afc_client_t? = nil
        guard afc_client_new_from_house_arrest_client(client, &raw) == AFC_E_SUCCESS, let raw else {
            house_arrest_client_free(client)
            throw ISyncError("Couldn't open the app's files.")
        }
        afc = AFCClient(raw: raw, owners: [])
    }

    deinit {
        // The AFC client must be freed before the service it runs over.
        afc = nil
        house_arrest_client_free(houseArrest)
    }

    private var client: AFCClient {
        get throws {
            guard let afc else { throw ISyncError("This app's files are no longer open.") }
            return afc
        }
    }

    private func entry(at path: String, using afc: AFCClient) -> DocumentEntry? {
        guard let s = afc.info(path) else { return nil }
        return DocumentEntry(
            path: path, name: (path as NSString).lastPathComponent,
            isDirectory: s["st_ifmt"] == "S_IFDIR",
            size: Int64(s["st_size"] ?? "") ?? 0,
            modified: Date(timeIntervalSince1970: (Double(s["st_mtime"] ?? "") ?? 0) / 1e9))
    }

    /// Lists a folder, with folders first. Hidden files aren't shown.
    public func list(_ path: String) throws -> [DocumentEntry] {
        let afc = try client
        return try afc.list(path)
            .filter { !$0.hasPrefix(".") }
            .compactMap { entry(at: (path as NSString).appendingPathComponent($0), using: afc) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// Total bytes in a local file or folder, for progress.
    public static func localSize(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return children.reduce(0) { $0 + localSize($1) }
    }

    /// Total bytes in a remote file or folder, for progress.
    public func remoteSize(_ entry: DocumentEntry) throws -> Int64 {
        guard entry.isDirectory else { return entry.size }
        return try list(entry.path).reduce(0) { $0 + (try remoteSize($1)) }
    }

    /// Copies a local file or folder into `remoteDirectory`. Refuses to replace anything on the
    /// phone. A file appears under its real name only after its size has been checked.
    public func upload(_ local: URL, into remoteDirectory: String, control: TransferControl, onBytes: (Int) -> Void) throws {
        let afc = try client
        let name = local.lastPathComponent
        let target = (remoteDirectory as NSString).appendingPathComponent(name)
        guard afc.info(target) == nil else {
            throw ISyncError("\"\(name)\" already exists on the iPhone, so it wasn't replaced.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir) else {
            throw ISyncError("\"\(name)\" couldn't be found on the Mac.")
        }
        if isDir.boolValue {
            try afc.makeDirectory(target)
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try upload(child, into: target, control: control, onBytes: onBytes)
            }
            return
        }
        let temp = (remoteDirectory as NSString).appendingPathComponent(".isync-partial-\(UUID().uuidString)")
        do {
            try afc.upload(local: local, to: temp, control: control, onBytes: onBytes)
            let want = Self.localSize(local)
            let got = Int64(afc.info(temp)?["st_size"] ?? "") ?? -1
            guard want == got else { throw ISyncError("Size check failed for \"\(name)\": expected \(want) bytes, got \(got).") }
            try afc.rename(temp, to: target)
        } catch {
            try? afc.remove(temp)
            throw error
        }
    }

    /// Copies a file or folder to a Mac folder, using a numbered name if the name is taken.
    /// Returns where it landed.
    @discardableResult
    public func download(_ entry: DocumentEntry, into localDirectory: URL, control: TransferControl, onBytes: (Int) -> Void) throws -> URL {
        let afc = try client
        let fm = FileManager.default
        try fm.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        let target = Self.availableURL(for: entry.name, in: localDirectory)
        if entry.isDirectory {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            for child in try list(entry.path) {
                try download(child, into: target, control: control, onBytes: onBytes)
            }
            return target
        }
        let temp = localDirectory.appendingPathComponent(".\(entry.name).isync-partial")
        do {
            try? fm.removeItem(at: temp)
            let got = try afc.copy(remote: entry.path, to: temp, chunk: 1 << 20, control: control, onBytes: onBytes)
            guard got == entry.size else {
                throw ISyncError("Size check failed for \"\(entry.name)\": expected \(entry.size) bytes, got \(got).")
            }
            try fm.moveItem(at: temp, to: target)
            try? fm.setAttributes([.modificationDate: entry.modified], ofItemAtPath: target.path)
            return target
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    static func availableURL(for name: String, in directory: URL) -> URL {
        let first = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Permanently deletes a file or folder on the iPhone. Callers must confirm with the user first.
    public func delete(_ entry: DocumentEntry) throws {
        let afc = try client
        if entry.isDirectory {
            try afc.removeRecursively(entry.path)
        } else {
            try afc.remove(entry.path)
        }
    }
}
