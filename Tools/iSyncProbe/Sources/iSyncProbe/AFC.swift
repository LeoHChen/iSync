import CIMobileDevice
import Foundation

struct RemoteFile {
    let path: String
    let size: Int64
    let mtimeNs: Int64
    let birthNs: Int64
}

final class AFC {
    let ptr: afc_client_t
    private let owners: [AnyObject]

    /// Opens the shared media area over com.apple.afc.
    init(device: Device) throws {
        var c: afc_client_t? = nil
        let e = afc_client_start_service(device.ptr, &c, probeLabel)
        guard e == AFC_E_SUCCESS, let c else { throw ProbeError("afc start failed: \(e.rawValue)") }
        ptr = c
        owners = [device]
    }

    /// Wraps a client that already exists, such as one from house_arrest.
    init(raw: afc_client_t, owners: [AnyObject]) {
        ptr = raw
        self.owners = owners
    }

    deinit { afc_client_free(ptr) }

    func list(_ path: String) throws -> [String] {
        var raw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        let e = afc_read_directory(ptr, path, &raw)
        guard e == AFC_E_SUCCESS, let raw else { throw ProbeError("list \(path): afc error \(e.rawValue)") }
        defer { afc_dictionary_free(raw) }
        var out: [String] = []
        var i = 0
        while let item = raw[i] {
            let name = String(cString: item)
            if name != "." && name != ".." { out.append(name) }
            i += 1
        }
        return out
    }

    /// Returns stat fields, or nil if the path can't be read.
    func info(_ path: String) -> [String: String]? {
        var raw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        guard afc_get_file_info(ptr, path, &raw) == AFC_E_SUCCESS, let raw else { return nil }
        defer { afc_dictionary_free(raw) }
        var out: [String: String] = [:]
        var i = 0
        while let k = raw[i], let v = raw[i + 1] {
            out[String(cString: k)] = String(cString: v)
            i += 2
        }
        return out
    }

    func deviceInfo() -> [String: String] {
        var raw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        guard afc_get_device_info(ptr, &raw) == AFC_E_SUCCESS, let raw else { return [:] }
        defer { afc_dictionary_free(raw) }
        var out: [String: String] = [:]
        var i = 0
        while let k = raw[i], let v = raw[i + 1] {
            out[String(cString: k)] = String(cString: v)
            i += 2
        }
        return out
    }

    /// Streams a remote file to disk and returns the byte count.
    @discardableResult
    func copy(remote: String, to local: URL, chunk: Int, onBytes: (Int) -> Void = { _ in }) throws -> Int64 {
        var h: UInt64 = 0
        let oe = afc_file_open(ptr, remote, AFC_FOPEN_RDONLY, &h)
        guard oe == AFC_E_SUCCESS else { throw ProbeError("open \(remote): afc error \(oe.rawValue)") }
        defer { afc_file_close(ptr, h) }
        try? FileManager.default.removeItem(at: local)
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let out = try FileHandle(forWritingTo: local)
        defer { try? out.close() }
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var total: Int64 = 0
        while true {
            var got: UInt32 = 0
            let re = afc_file_read(ptr, h, buf, UInt32(chunk), &got)
            if re == AFC_E_END_OF_DATA || (re == AFC_E_SUCCESS && got == 0) { break }
            guard re == AFC_E_SUCCESS else { throw ProbeError("read \(remote): afc error \(re.rawValue)") }
            try out.write(contentsOf: Data(bytesNoCopy: buf, count: Int(got), deallocator: .none))
            total += Int64(got)
            onBytes(Int(got))
        }
        return total
    }

    func readAll(_ path: String, chunk: Int = 1 << 20) throws -> Data {
        var h: UInt64 = 0
        let oe = afc_file_open(ptr, path, AFC_FOPEN_RDONLY, &h)
        guard oe == AFC_E_SUCCESS else { throw ProbeError("open \(path): afc error \(oe.rawValue)") }
        defer { afc_file_close(ptr, h) }
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var out = Data()
        while true {
            var got: UInt32 = 0
            let re = afc_file_read(ptr, h, buf, UInt32(chunk), &got)
            if re == AFC_E_END_OF_DATA || (re == AFC_E_SUCCESS && got == 0) { break }
            guard re == AFC_E_SUCCESS else { throw ProbeError("read \(path): afc error \(re.rawValue)") }
            out.append(Data(bytes: buf, count: Int(got)))
        }
        return out
    }

    func write(_ path: String, data: Data) throws {
        var h: UInt64 = 0
        let oe = afc_file_open(ptr, path, AFC_FOPEN_WRONLY, &h)
        guard oe == AFC_E_SUCCESS else { throw ProbeError("create \(path): afc error \(oe.rawValue)") }
        defer { afc_file_close(ptr, h) }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
            var off = 0
            while off < data.count {
                var wrote: UInt32 = 0
                let n = UInt32(min(data.count - off, 1 << 20))
                let we = afc_file_write(ptr, h, base + off, n, &wrote)
                guard we == AFC_E_SUCCESS else { throw ProbeError("write \(path): afc error \(we.rawValue)") }
                off += Int(wrote)
            }
        }
    }

    func remove(_ path: String) throws {
        let e = afc_remove_path(ptr, path)
        guard e == AFC_E_SUCCESS else { throw ProbeError("remove \(path): afc error \(e.rawValue)") }
    }
}

/// Opens a fresh connection, one per worker thread.
func openAFC(udid: String) throws -> AFC {
    try AFC(device: try Device(udid: udid))
}
