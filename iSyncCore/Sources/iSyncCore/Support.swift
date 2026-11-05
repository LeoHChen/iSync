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
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
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

/// A short, stable key for a device, so its UDID isn't written into the user's folders.
public func deviceKey(udid: String) -> String {
    SHA256.hash(data: Data(udid.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}
