import Foundation

/// One photo or video from a phone's Photos.sqlite.
public struct PhoneAsset: Hashable, Sendable {
    public let remotePath: String
    public let originalName: String?
    public let fingerprint: MediaFingerprint
    public let isVideo: Bool
    public let isLivePhoto: Bool
}

/// A read-only picture of what a phone's Photos library holds, using only its database.
public struct PhoneLibraryIndex: Sendable {
    public let assets: [PhoneAsset]

    public init(assets: [PhoneAsset]) { self.assets = assets }

    /// Fingerprints by remote path, for planning a copy from this phone.
    public var fingerprints: [String: MediaFingerprint] {
        var out: [String: MediaFingerprint] = [:]
        for a in assets { out[a.remotePath] = a.fingerprint }
        return out
    }

    public static func read(database url: URL) throws -> PhoneLibraryIndex {
        let db = try SQLiteDB(path: url.path)
        let assetColumns = try db.columns("ZASSET")
        let extraColumns = try db.columns("ZADDITIONALASSETATTRIBUTES")
        let required: Set<String> = ["ZDIRECTORY", "ZFILENAME", "ZKIND", "ZKINDSUBTYPE", "ZTRASHEDSTATE"]
        let requiredExtra: Set<String> = ["ZASSET", "ZORIGINALFILESIZE", "ZORIGINALWIDTH", "ZORIGINALHEIGHT", "ZEXIFTIMESTAMPSTRING"]
        guard required.isSubset(of: assetColumns), requiredExtra.isSubset(of: extraColumns) else {
            throw ISyncError("This version of iOS has a Photos database iSync doesn't recognize.")
        }
        let hash = extraColumns.contains("ZORIGINALSTABLEHASH") ? "x.ZORIGINALSTABLEHASH" : "NULL"
        let name = extraColumns.contains("ZORIGINALFILENAME") ? "x.ZORIGINALFILENAME" : "NULL"
        // Trashed assets don't count, and neither do shared albums, which sit outside DCIM.
        let rows = try db.rows("""
            SELECT a.ZDIRECTORY AS dir, a.ZFILENAME AS file, a.ZKIND AS kind, a.ZKINDSUBTYPE AS subtype,
                   x.ZORIGINALFILESIZE AS size, x.ZORIGINALWIDTH AS w, x.ZORIGINALHEIGHT AS h,
                   x.ZEXIFTIMESTAMPSTRING AS capture, \(hash) AS stable, \(name) AS original
            FROM ZASSET a JOIN ZADDITIONALASSETATTRIBUTES x ON x.ZASSET = a.Z_PK
            WHERE a.ZTRASHEDSTATE = 0 AND a.ZDIRECTORY LIKE 'DCIM/%'
            """)
        let assets = rows.compactMap { row -> PhoneAsset? in
            guard let dir = row["dir"] as? String, let file = row["file"] as? String else { return nil }
            let print = MediaFingerprint(
                size: row["size"] as? Int64 ?? 0,
                capture: CaptureDate.normalize(row["capture"] as? String),
                width: (row["w"] as? Int64).map(Int.init), height: (row["h"] as? Int64).map(Int.init),
                stableHash: row["stable"] as? String)
            return PhoneAsset(
                remotePath: "/\(dir)/\(file)", originalName: row["original"] as? String, fingerprint: print,
                isVideo: row["kind"] as? Int64 == 1, isLivePhoto: row["subtype"] as? Int64 == 2)
        }
        return PhoneLibraryIndex(assets: assets)
    }

    /// Copies the phone's Photos database to this Mac and reads it. Nothing on the phone changes.
    public static func fetch(udid: String, cacheDirectory: URL = iSyncCacheDirectory()) throws -> PhoneLibraryIndex {
        let afc = try AFCClient.connect(udid: udid)
        let dir = cacheDirectory.appendingPathComponent(deviceKey(udid: udid))
        let url = try fetchDatabase(from: afc, remote: "/PhotoData/Photos.sqlite", into: dir, name: "Photos.sqlite")
        return try read(database: url)
    }
}

/// How one phone's library compares with another's, from metadata alone.
public struct PhoneComparison: Sendable {
    public var total = SyncTally()
    /// Same capture time, dimensions and size. SHA-256 still confirms these before any transfer.
    public var alreadyOnDestination = SyncTally()
    /// Same capture time and dimensions, but a different size, such as a converted copy.
    public var possibleDuplicates = SyncTally()
    public var new = SyncTally()
    /// Source and destination paths to hash, if they need confirming.
    public var candidates: [(source: String, destination: String)] = []
    public var destinationAssets = 0
}

public enum PhoneComparer {
    /// Compares by content, never by name. `sourceFiles` adds the rest of each group, such as a
    /// Live Photo's video, to the totals. `destinationFiles` catches matches the database
    /// doesn't list, by name and size.
    public static func compare(
        source: PhoneLibraryIndex, destination: PhoneLibraryIndex,
        sourceFiles: [RemoteFile] = [], destinationFiles: [RemoteFile] = []
    ) -> PhoneComparison {
        var result = PhoneComparison()
        result.destinationAssets = destination.assets.count

        var byExact: [String: PhoneAsset] = [:]
        var byVisual: [String: PhoneAsset] = [:]
        var byStable: [String: PhoneAsset] = [:]
        for a in destination.assets {
            if let key = a.fingerprint.visualKey {
                byExact["\(a.fingerprint.size)|\(key)"] = a
                byVisual[key] = a
            }
            if let s = a.fingerprint.stableHash { byStable[s] = a }
        }
        var byNameAndSize: [String: String] = [:]
        for f in destinationFiles {
            byNameAndSize["\((f.path as NSString).lastPathComponent.lowercased())|\(f.size)"] = f.path
        }

        // Bytes for a whole group, so a Live Photo's video is counted.
        var groupBytes: [String: Int64] = [:]
        for f in sourceFiles {
            let key = ((f.path as NSString).deletingPathExtension).lowercased()
            groupBytes[key, default: 0] += f.size
        }

        for asset in source.assets {
            let key = (asset.remotePath as NSString).deletingPathExtension.lowercased()
            let bytes = groupBytes[key] ?? asset.fingerprint.size
            var file = SyncTally()
            file.files = 1
            file.bytes = bytes
            add(file, to: &result.total)

            let print = asset.fingerprint
            var match: String?
            if let v = print.visualKey, let hit = byExact["\(print.size)|\(v)"] { match = hit.remotePath }
            if match == nil, let s = print.stableHash, let hit = byStable[s] { match = hit.remotePath }
            if match == nil {
                let name = (asset.remotePath as NSString).lastPathComponent.lowercased()
                match = byNameAndSize["\(name)|\(print.size)"]
            }
            if let match {
                add(file, to: &result.alreadyOnDestination)
                result.candidates.append((asset.remotePath, match))
            } else if let v = print.visualKey, byVisual[v] != nil {
                add(file, to: &result.possibleDuplicates)
            } else {
                add(file, to: &result.new)
            }
        }
        return result
    }

    private static func add(_ item: SyncTally, to tally: inout SyncTally) {
        tally.files += item.files
        tally.bytes += item.bytes
    }
}
