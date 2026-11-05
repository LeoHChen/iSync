import CIMobileDevice
import Foundation

public struct RemoteFile: Hashable, Sendable, Codable {
    public let path: String
    public let size: Int64
    /// Nanoseconds since 1970, as AFC reports them.
    public let modifiedNs: Int64

    public init(path: String, size: Int64, modifiedNs: Int64) {
        self.path = path
        self.size = size
        self.modifiedNs = modifiedNs
    }

    public var modified: Date { Date(timeIntervalSince1970: Double(modifiedNs) / 1e9) }
}

/// Lets a long transfer be paused, resumed and cancelled from another thread.
public final class TransferControl {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    public var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    public func pause() {
        condition.lock()
        paused = true
        condition.unlock()
    }

    public func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks while paused. Returns false if cancelled.
    public func checkpoint() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        return !cancelled
    }
}

struct TransferCancelled: Error {}

/// Reads remote files on one connection. The engine depends on this so tests can use a fake.
public protocol RemoteFileReader: AnyObject {
    func copy(remote: String, to local: URL, chunk: Int, control: TransferControl, onBytes: (Int) -> Void) throws -> Int64
}

public final class AFCClient: RemoteFileReader {
    let ptr: afc_client_t
    private let owners: [AnyObject]

    /// Opens the phone's shared media area.
    public init(device: DeviceConnection) throws {
        var c: afc_client_t? = nil
        let e = afc_client_start_service(device.ptr, &c, clientLabel)
        guard e == AFC_E_SUCCESS, let c else {
            throw ISyncError("Couldn't open the iPhone's media area: \(String(cString: afc_strerror(e)))")
        }
        ptr = c
        owners = [device]
    }

    init(raw: afc_client_t, owners: [AnyObject]) {
        ptr = raw
        self.owners = owners
    }

    deinit { afc_client_free(ptr) }

    public static func connect(udid: String) throws -> AFCClient {
        try AFCClient(device: try DeviceConnection(udid: udid))
    }

    private func failure(_ op: String, _ e: afc_error_t) -> AFCError {
        AFCError(operation: op, code: Int32(e.rawValue), text: String(cString: afc_strerror(e)))
    }

    public func list(_ path: String) throws -> [String] {
        var raw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        let e = afc_read_directory(ptr, path, &raw)
        guard e == AFC_E_SUCCESS, let raw else { throw failure("List \(path)", e) }
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
    public func info(_ path: String) -> [String: String]? {
        var raw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        guard afc_get_file_info(ptr, path, &raw) == AFC_E_SUCCESS, let raw else { return nil }
        defer { afc_dictionary_free(raw) }
        return Self.pairs(raw)
    }

    public func deviceInfo() -> [String: String] {
        var raw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        guard afc_get_device_info(ptr, &raw) == AFC_E_SUCCESS, let raw else { return [:] }
        defer { afc_dictionary_free(raw) }
        return Self.pairs(raw)
    }

    private static func pairs(_ raw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while let k = raw[i], let v = raw[i + 1] {
            out[String(cString: k)] = String(cString: v)
            i += 2
        }
        return out
    }

    /// Streams a remote file to disk. The caller owns where it lands and what happens on failure.
    public func copy(remote: String, to local: URL, chunk: Int, control: TransferControl, onBytes: (Int) -> Void) throws -> Int64 {
        var handle: UInt64 = 0
        let opened = afc_file_open(ptr, remote, AFC_FOPEN_RDONLY, &handle)
        guard opened == AFC_E_SUCCESS else { throw failure("Open \(remote)", opened) }
        defer { afc_file_close(ptr, handle) }

        FileManager.default.createFile(atPath: local.path, contents: nil)
        let out = try FileHandle(forWritingTo: local)
        defer { try? out.close() }

        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var total: Int64 = 0
        while true {
            guard control.checkpoint() else { throw TransferCancelled() }
            var got: UInt32 = 0
            let read = afc_file_read(ptr, handle, buffer, UInt32(chunk), &got)
            if read == AFC_E_END_OF_DATA || (read == AFC_E_SUCCESS && got == 0) { break }
            guard read == AFC_E_SUCCESS else { throw failure("Read \(remote)", read) }
            try out.write(contentsOf: Data(bytesNoCopy: buffer, count: Int(got), deallocator: .none))
            total += Int64(got)
            onBytes(Int(got))
        }
        return total
    }

    /// Streams a local file to the phone.
    public func upload(local: URL, to remote: String, chunk: Int = 1 << 20, control: TransferControl, onBytes: (Int) -> Void) throws {
        var handle: UInt64 = 0
        let opened = afc_file_open(ptr, remote, AFC_FOPEN_WRONLY, &handle)
        guard opened == AFC_E_SUCCESS else { throw failure("Create \(remote)", opened) }
        defer { afc_file_close(ptr, handle) }
        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        while true {
            guard control.checkpoint() else { throw TransferCancelled() }
            guard let data = try input.read(upToCount: chunk), !data.isEmpty else { break }
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
                var offset = 0
                while offset < data.count {
                    var wrote: UInt32 = 0
                    let e = afc_file_write(ptr, handle, base + offset, UInt32(data.count - offset), &wrote)
                    guard e == AFC_E_SUCCESS else { throw failure("Write \(remote)", e) }
                    offset += Int(wrote)
                }
            }
            onBytes(data.count)
        }
    }

    public func rename(_ from: String, to: String) throws {
        let e = afc_rename_path(ptr, from, to)
        guard e == AFC_E_SUCCESS else { throw failure("Rename \(from)", e) }
    }

    public func makeDirectory(_ path: String) throws {
        let e = afc_make_directory(ptr, path)
        guard e == AFC_E_SUCCESS else { throw failure("Create folder \(path)", e) }
    }

    func remove(_ path: String) throws {
        let e = afc_remove_path(ptr, path)
        guard e == AFC_E_SUCCESS else { throw failure("Delete \(path)", e) }
    }

    func removeRecursively(_ path: String) throws {
        let e = afc_remove_path_and_contents(ptr, path)
        guard e == AFC_E_SUCCESS else { throw failure("Delete \(path)", e) }
    }
}
