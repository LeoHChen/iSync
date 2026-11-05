import CryptoKit
import Foundation

enum Paths {
    static let out = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("iSyncProbe-out")
    static func dir(_ name: String) -> URL {
        let u = out.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func log(_ s: String) {
    print(s)
    fflush(stdout)
}

func sha256(_ d: Data) -> String {
    SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

func sha256(file url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hasher = SHA256()
    while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func fmtBytes(_ n: Int64) -> String {
    let v = Double(n)
    if v >= 1e9 { return String(format: "%.2f GB", v / 1e9) }
    if v >= 1e6 { return String(format: "%.1f MB", v / 1e6) }
    if v >= 1e3 { return String(format: "%.1f KB", v / 1e3) }
    return "\(n) B"
}

/// Runs a program and returns its exit code and combined output.
@discardableResult
func runTool(_ path: String, _ args: [String]) -> (code: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Makes a value safe for JSONSerialization.
func jsonSafe(_ v: Any) -> Any {
    switch v {
    case let d as [String: Any]: return d.mapValues(jsonSafe)
    case let a as [Any]: return a.map(jsonSafe)
    case let d as Data: return "<\(d.count) bytes>"
    case let d as Date: return ISO8601DateFormatter().string(from: d)
    case let s as String: return s
    case let n as NSNumber: return n
    default: return String(describing: v)
    }
}

func writeResult(udid: String, name: String, _ dict: [String: Any]) {
    let dir = Paths.dir("results")
    let url = dir.appendingPathComponent("\(udid)-\(name).json")
    var d = dict
    d["recordedAt"] = ISO8601DateFormatter().string(from: Date())
    if let data = try? JSONSerialization.data(
        withJSONObject: jsonSafe(d), options: [.prettyPrinted, .sortedKeys])
    {
        try? data.write(to: url)
        log("  results: \(url.path)")
    }
}

/// User plus system CPU time used by this process so far.
func processCPUSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
        + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func with<R>(_ f: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return f(&value)
    }
}

/// Runs `body` on `workers` threads and waits for them all.
func parallel(workers: Int, _ body: @escaping (Int) -> Void) {
    DispatchQueue.concurrentPerform(iterations: workers) { body($0) }
}
