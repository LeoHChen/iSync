import AVFoundation
import Foundation

public struct MusicTrack: Identifiable, Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case copyable
        /// DRM or Apple Music content, which wouldn't play once copied.
        case protected(String)
        /// In the library but not stored on this iPhone.
        case notOnIPhone
    }

    public let id: Int64
    public let title: String
    public let artist: String?
    public let albumArtist: String?
    public let album: String?
    public let trackNumber: Int
    public let discNumber: Int
    public let durationMs: Int64
    public let remotePath: String?
    public let size: Int64
    public var modifiedNs: Int64
    public var status: Status
    /// The library's own subscription flag, which alone doesn't mean the file has DRM.
    public let subscriptionFlag: Bool

    public var remoteFile: RemoteFile? {
        remotePath.map { RemoteFile(path: $0, size: size, modifiedNs: modifiedNs) }
    }
}

public struct MusicSummary: Equatable, Sendable {
    public var total = 0
    public var copyable = 0
    public var copyableBytes: Int64 = 0
    public var protected = 0
    public var notOnIPhone = 0
    public var subscriptionFlagged = 0

    public init(_ tracks: [MusicTrack]) {
        total = tracks.count
        for t in tracks {
            switch t.status {
            case .copyable:
                copyable += 1
                copyableBytes += t.size
            case .protected: protected += 1
            case .notOnIPhone: notOnIPhone += 1
            }
            if t.subscriptionFlag { subscriptionFlagged += 1 }
        }
    }
}

public enum MusicLibrary {
    static let mediaTypeMusic = 8

    /// Reads a local copy of MediaLibrary.sqlitedb.
    public static func read(database url: URL) throws -> [MusicTrack] {
        let db = try SQLiteDB(path: url.path)
        let store = try db.columns("item_store")
        func flag(_ name: String) -> String { store.contains(name) ? "s.\(name)" : "0" }
        let rows = try db.rows("""
            SELECT i.item_pid AS pid, i.track_number AS track, i.disc_number AS disc,
                   e.title AS title, e.total_time_ms AS ms, e.location AS location, e.file_size AS size,
                   b.path AS base, a.item_artist AS artist, al.album AS album, aa.album_artist AS album_artist,
                   \(flag("is_protected")) AS protected, \(flag("key_id")) AS key_id, \(flag("is_subscription")) AS subscription
            FROM item i
            JOIN item_extra e ON e.item_pid = i.item_pid
            LEFT JOIN item_store s ON s.item_pid = i.item_pid
            LEFT JOIN base_location b ON b.base_location_id = i.base_location_id
            LEFT JOIN item_artist a ON a.item_artist_pid = i.item_artist_pid
            LEFT JOIN album al ON al.album_pid = i.album_pid
            LEFT JOIN album_artist aa ON aa.album_artist_pid = i.album_artist_pid
            WHERE i.media_type = \(mediaTypeMusic)
            """)
        func text(_ v: Any?) -> String? {
            guard let s = v as? String, !s.isEmpty else { return nil }
            return s
        }
        func number(_ v: Any?) -> Int64 {
            if let i = v as? Int64 { return i }
            if let d = v as? Double { return Int64(d) }
            return 0
        }
        return rows.map { row in
            let location = text(row["location"])
            let base = text(row["base"])
            var path: String?
            if let location, let base { path = "/\(base)/\(location)" }
            var status = MusicTrack.Status.copyable
            let ext = ((location ?? "") as NSString).pathExtension.lowercased()
            if path == nil {
                status = .notOnIPhone
            } else if number(row["protected"]) != 0 {
                status = .protected("Marked as protected")
            } else if number(row["key_id"]) != 0 {
                status = .protected("Has a DRM key")
            } else if ext == "m4p" || ext == "movpkg" {
                status = .protected("Protected file type")
            } else if base?.hasPrefix("iTunes_Control/Music") != true {
                // Apple Music downloads and caches live outside iTunes_Control/Music.
                status = .protected("Stored as Apple Music content")
            }
            return MusicTrack(
                id: number(row["pid"]), title: text(row["title"]) ?? "Unknown Title", artist: text(row["artist"]),
                albumArtist: text(row["album_artist"]), album: text(row["album"]),
                trackNumber: Int(number(row["track"])), discNumber: Int(number(row["disc"])),
                durationMs: number(row["ms"]), remotePath: path, size: number(row["size"]),
                modifiedNs: 0, status: status, subscriptionFlag: number(row["subscription"]) != 0)
        }
        .sorted { ($0.albumArtist ?? $0.artist ?? "", $0.album ?? "", $0.discNumber, $0.trackNumber, $0.title)
            < ($1.albumArtist ?? $1.artist ?? "", $1.album ?? "", $1.discNumber, $1.trackNumber, $1.title) }
    }

    /// Copies the phone's music database to this Mac, reads it, and checks each file on the phone.
    public static func fetch(udid: String, cacheDirectory: URL = iSyncCacheDirectory()) throws -> [MusicTrack] {
        let afc = try AFCClient.connect(udid: udid)
        let dir = cacheDirectory.appendingPathComponent(deviceKey(udid: udid))
        let url = try fetchDatabase(from: afc, remote: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb", into: dir, name: "MediaLibrary.sqlitedb")
        var tracks = try read(database: url)
        for i in tracks.indices {
            guard let path = tracks[i].remotePath else { continue }
            guard let s = afc.info(path) else {
                tracks[i].status = .notOnIPhone
                continue
            }
            tracks[i].modifiedNs = Int64(s["st_mtime"] ?? "") ?? 0
        }
        return tracks
    }

    /// Whether a copied file has DRM, from the file itself.
    public static func hasDRM(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).load(.hasProtectedContent)) ?? false
    }
}

public enum MusicPlanner {
    /// Makes a name safe for a folder or file on a Mac.
    static func sanitize(_ raw: String, fallback: String) -> String {
        var out = ""
        for c in raw {
            if c == "/" || c == ":" || c == "\\" {
                out.append("-")
            } else if !(c.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? false) {
                out.append(c)
            }
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        out = String(out.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? fallback : out
    }

    /// Artist/Album/NN Title.ext, using the album artist so compilations stay in one folder.
    public static func relativePath(for track: MusicTrack) -> String {
        let artist = sanitize(track.albumArtist ?? track.artist ?? "", fallback: "Unknown Artist")
        let album = sanitize(track.album ?? "", fallback: "Unknown Album")
        let title = sanitize(track.title, fallback: "Unknown Title")
        let ext = ((track.remotePath ?? "") as NSString).pathExtension
        var number = ""
        if track.trackNumber > 0 {
            number = String(format: "%02d ", track.trackNumber)
            if track.discNumber > 1 { number = "\(track.discNumber)-" + number }
        }
        let name = number + title
        return "\(artist)/\(album)/\(ext.isEmpty ? name : "\(name).\(ext)")"
    }

    public struct Preview: Sendable {
        public var plan = CopyPlan()
        public var new = SyncTally()
        public var alreadyCopied = SyncTally()
        public var sameNameDifferent = SyncTally()
    }

    /// Plans a copy of the copyable tracks. Protected tracks are never included.
    public static func plan(tracks: [MusicTrack], destination: URL, manifest: CopyManifest, policy: ConflictPolicy) -> Preview {
        var preview = Preview()
        var reserved = Set<String>()
        var current = Set<String>()
        let files = tracks.compactMap { track -> (MusicTrack, RemoteFile)? in
            guard track.status == .copyable, let file = track.remoteFile else { return nil }
            return (track, file)
        }
        for (_, file) in files {
            guard let e = manifest.entries[file.path], e.size == file.size, e.modifiedNs == file.modifiedNs,
                  let local = CopyPlanner.localFile(destination.appendingPathComponent(e.localPath)), local.size == file.size
            else { continue }
            current.insert(file.path)
            reserved.insert(e.localPath.lowercased())
        }
        for (track, file) in files {
            preview.plan.totalFiles += 1
            preview.plan.totalBytes += file.size
            if current.contains(file.path) {
                preview.alreadyCopied.add(file)
                preview.plan.alreadyCopiedFiles += 1
                preview.plan.alreadyCopiedBytes += file.size
                if policy == .overwrite, let e = manifest.entries[file.path] {
                    preview.plan.toCopy.append(PlannedGroup(
                        files: [PlannedFile(remote: file, localPath: e.localPath, replaces: true)], isLivePhoto: false))
                }
                continue
            }
            let wanted = relativePath(for: track)
            let dir = (wanted as NSString).deletingLastPathComponent
            let stem = ((wanted as NSString).lastPathComponent as NSString).deletingPathExtension
            let ext = (wanted as NSString).pathExtension
            var n = 1
            while true {
                let name = n == 1 ? stem : "\(stem) (\(n))"
                let rel = (dir as NSString).appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
                if reserved.contains(rel.lowercased()) {
                    n += 1
                    continue
                }
                if let local = CopyPlanner.localFile(destination.appendingPathComponent(rel)) {
                    let same = CopyPlanner.isSame(local, as: file)
                    if policy == .overwrite {
                        reserved.insert(rel.lowercased())
                        preview.plan.toCopy.append(PlannedGroup(
                            files: [PlannedFile(remote: file, localPath: rel, replaces: true, nameConflict: !same)], isLivePhoto: false))
                        if same { preview.alreadyCopied.add(file) } else { preview.sameNameDifferent.add(file) }
                    } else if same {
                        reserved.insert(rel.lowercased())
                        preview.plan.adopted.append(PlannedFile(remote: file, localPath: rel))
                        preview.plan.alreadyCopiedFiles += 1
                        preview.plan.alreadyCopiedBytes += file.size
                        preview.alreadyCopied.add(file)
                    } else {
                        n += 1
                        continue
                    }
                } else {
                    reserved.insert(rel.lowercased())
                    preview.plan.toCopy.append(PlannedGroup(
                        files: [PlannedFile(remote: file, localPath: rel, nameConflict: n > 1)], isLivePhoto: false))
                    if n > 1 { preview.sameNameDifferent.add(file) } else { preview.new.add(file) }
                }
                break
            }
        }
        return preview
    }
}
