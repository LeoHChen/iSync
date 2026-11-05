import Foundation
import SQLite3

/// A minimal reader for local copies of the phone's databases.
final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String) throws {
        // Opened read-write so SQLite can apply the WAL. This is a local copy,
        // never the phone's own database.
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw ProbeError("open \(path): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    deinit { sqlite3_close(db) }

    func rows(_ sql: String) throws -> [[String: Any]] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw ProbeError("sql: \(String(cString: sqlite3_errmsg(db))) in \(sql)")
        }
        defer { sqlite3_finalize(st) }
        var out: [[String: Any]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(st) {
                let name = String(cString: sqlite3_column_name(st, i))
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(st, i)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(st, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(st, i))
                case SQLITE_BLOB: row[name] = "<blob>"
                default: row[name] = NSNull()
                }
            }
            out.append(row)
        }
        return out
    }

    func int(_ sql: String) throws -> Int64 {
        guard let first = try rows(sql).first?.values.first as? Int64 else { return 0 }
        return first
    }

    func tableCount() throws -> Int64 {
        try int("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'")
    }

    func hasTable(_ t: String) throws -> Bool {
        try int("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(t)'") > 0
    }

    func columns(_ t: String) throws -> [String] {
        try rows("PRAGMA table_info(\(t))").compactMap { $0["name"] as? String }
    }

    func hasColumn(_ t: String, _ c: String) throws -> Bool {
        try columns(t).contains(c)
    }
}
