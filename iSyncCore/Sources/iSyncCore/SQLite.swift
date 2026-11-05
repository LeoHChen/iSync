import Foundation
import SQLite3

/// A minimal reader for local copies of a phone's databases. It never touches the phone.
final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String) throws {
        // A copied WAL database opens read-only if SQLite can use its -shm file. If it
        // can't, this is only a local copy, so opening it for writing to apply the WAL is safe.
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, (try? rows("SELECT 1 FROM sqlite_master LIMIT 1")) != nil {
            return
        }
        sqlite3_close(db)
        db = nil
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw ISyncError("Couldn't open a copy of the iPhone's database: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    deinit { sqlite3_close(db) }

    func rows(_ sql: String) throws -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ISyncError("Database query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        var out: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, i))
                default: break
                }
            }
            out.append(row)
        }
        return out
    }

    func columns(_ table: String) throws -> Set<String> {
        Set(try rows("PRAGMA table_info(\(table))").compactMap { $0["name"] as? String })
    }
}

/// Copies a database and its WAL files from the phone, unless the copy is already current.
func fetchDatabase(from afc: AFCClient, remote: String, into directory: URL, name: String) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let control = TransferControl()
    let stampURL = directory.appendingPathComponent("\(name).stamp")
    let stamp = ["", "-wal", "-shm"].compactMap { suffix -> String? in
        guard let i = afc.info(remote + suffix) else { return nil }
        // -shm changes constantly and only matters alongside -wal, so it isn't compared.
        return suffix == "-shm" ? nil : "\(suffix):\(i["st_size"] ?? ""):\(i["st_mtime"] ?? "")"
    }.joined(separator: "|")
    let local = directory.appendingPathComponent(name)
    if fm.fileExists(atPath: local.path), (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp, !stamp.isEmpty {
        return local
    }
    guard afc.info(remote) != nil else { throw ISyncError("\(remote) isn't readable on this iPhone.") }
    for suffix in ["", "-wal", "-shm"] {
        let target = directory.appendingPathComponent(name + suffix)
        try? fm.removeItem(at: target)
        if afc.info(remote + suffix) != nil {
            _ = try afc.copy(remote: remote + suffix, to: target, chunk: 1 << 20, control: control) { _ in }
        }
    }
    try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
    return local
}
