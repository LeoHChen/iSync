import CryptoKit
import Foundation

public struct ISyncError: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// An AFC failure, keeping the code so callers can tell a missing file from a lost connection.
struct AFCError: LocalizedError {
    let operation: String
    let code: Int32
    let text: String
    var errorDescription: String? { "\(operation): \(text)" }
    /// True when the file itself is the problem, so another attempt won't help.
    var isFileLevel: Bool { code == 8 || code == 10 || code == 16 }
}

public final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    public init(_ value: T) { self.value = value }
    @discardableResult
    public func with<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

public enum Format {
    public static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }

    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) sec" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) hr \(s % 3600 / 60) min"
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        String(format: "%.1f MB/s", bytesPerSecond / 1e6)
    }
}

public func sha256(file url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// One spelling for a path. macOS can report the same folder as /var or /private/var, and
/// indexes compare paths as text.
public func canonicalPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Where iSync keeps copies of phone databases and folder indexes on this Mac.
public func iSyncCacheDirectory() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let url = base.appendingPathComponent("iSync")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A short, stable key for a device, so its UDID isn't written into the user's folders.
public func deviceKey(udid: String) -> String {
    SHA256.hash(data: Data(udid.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}
