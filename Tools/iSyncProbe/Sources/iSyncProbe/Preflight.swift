import CIMobileDevice
import Foundation

enum SyncVerdict: String {
    case clean, synced, unknown
}

/// Checks over AFC, with no ATC session, whether the phone holds Finder- or
/// iTunes-synced media. A sync from a new host library could replace that content.
func preflight(udid: String) -> (verdict: SyncVerdict, detail: [String: Any]) {
    log("\n== Preflight: Finder- or iTunes-synced content on \(udid)")
    var r: [String: Any] = ["test": "preflight"]
    // reasons: synced content exists now. unknowns: can't rule out a problem.
    // Either one closes the gate on T4 and T5.
    var reasons: [String] = []
    var unknowns: [String] = []
    let dir = Paths.dir("preflight/\(udid)")

    do {
        let afc = try openAFC(udid: udid)
        r["afcRoot"] = (try? afc.list("/")) ?? []

        // Music side
        let itc = (try? afc.list("/iTunes_Control")) ?? []
        r["iTunesControl"] = itc
        var musicFiles = 0
        var musicBytes: Int64 = 0
        let fdirs = ((try? afc.list("/iTunes_Control/Music")) ?? []).filter { $0.hasPrefix("F") }
        for d in fdirs {
            for f in (try? afc.list("/iTunes_Control/Music/\(d)")) ?? [] {
                musicFiles += 1
                if let s = afc.info("/iTunes_Control/Music/\(d)/\(f)") { musicBytes += Int64(s["st_size"] ?? "0") ?? 0 }
            }
        }
        r["musicFolderFiles"] = musicFiles
        r["musicFolderBytes"] = musicBytes
        log("  /iTunes_Control entries: \(itc.isEmpty ? "unreadable" : itc.joined(separator: ", "))")
        log("  /iTunes_Control/Music: \(musicFiles) files, \(fmtBytes(musicBytes))")

        let itunesDir = (try? afc.list("/iTunes_Control/iTunes")) ?? []
        r["iTunesFolder"] = itunesDir
        if let prefs = try? afc.readAll("/iTunes_Control/iTunes/iTunesPrefs") { r["iTunesPrefsBytes"] = prefs.count }
        if let prefs = try? afc.readAll("/iTunes_Control/iTunes/iTunesPrefs.plist"),
           let p = try? PropertyListSerialization.propertyList(from: prefs, options: [], format: nil) as? [String: Any]
        {
            r["iTunesPrefsPlistKeys"] = Array(p.keys).sorted()
        }

        var mediaDBRead = false
        for suffix in ["", "-wal", "-shm"] {
            let remote = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb\(suffix)"
            guard afc.info(remote) != nil else { continue }
            try afc.copy(remote: remote, to: dir.appendingPathComponent("MediaLibrary.sqlitedb\(suffix)"), chunk: 1 << 20)
            if suffix.isEmpty { mediaDBRead = true }
        }
        r["mediaLibraryReadable"] = mediaDBRead
        if mediaDBRead {
            let m = analyzeMediaLibrary(path: dir.appendingPathComponent("MediaLibrary.sqlitedb").path)
            r["mediaLibrary"] = m
            log("  MediaLibrary: \(m)")
            if let e = m["error"] { unknowns.append("MediaLibrary query failed: \(e)") }
            if let s = m["itemsWithSyncID"] as? Int64, s > 0 { reasons.append("\(s) media items carry a sync ID") }
            // Playlists with a sync ID but no items are leftovers from an older sync.
            // They hold no content but show this phone was tied to a host library.
            if let s = m["playlistsWithSyncIDAndItems"] as? Int64, s > 0 {
                reasons.append("\(s) playlists with items carry a sync ID")
            }
            if let s = m["playlistsWithSyncID"] as? Int64, s > 0 {
                unknowns.append("\(s) playlists carry a sync ID, which shows an earlier host-library sync")
            }
            if let local = m["musicTracks"] as? Int64, local > 0 {
                unknowns.append("\(local) music tracks on the phone, and the effect of a new host library on them is untested")
            }
        } else {
            unknowns.append("MediaLibrary.sqlitedb isn't readable over AFC")
        }

        // Files iTunes and Finder write to record a photo-sync setup
        var legacy: [String: String] = [:]
        for n in ["PhotosFolderName", "PhotosFolderAlbums", "PhotosFolderPrefs", "iTunesPrefs", "iTunesPrefs.plist"] {
            if let i = afc.info("/iTunes_Control/iTunes/\(n)"), let t = Double(i["st_mtime"] ?? "") {
                legacy[n] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: t / 1e9))
            }
        }
        r["syncConfigFilesModified"] = legacy
        let photoConfig = legacy.keys.filter { $0.hasPrefix("PhotosFolder") }
        if !photoConfig.isEmpty {
            log("  photo-sync settings on the phone: \(photoConfig.sorted().map { "\($0) (\(legacy[$0]!))" }.joined(separator: ", "))")
            unknowns.append("photo-sync settings exist (\(photoConfig.sorted().joined(separator: ", ")))")
        }

        // Photo side
        for p in ["/PhotoData/Sync", "/Photos/Sync", "/PhotoData/PhotoCloudSharingData", "/PhotoData/iTunesPhotosCache"] {
            let entries = try? afc.list(p)
            r["path:\(p)"] = entries.map { Array($0.prefix(40)) } ?? "absent or unreadable"
        }
        var syncedPhotoFiles = 0
        if let entries = try? afc.list("/PhotoData/Sync") {
            for e in entries {
                let sub = "/PhotoData/Sync/\(e)"
                if let i = afc.info(sub), i["st_ifmt"] == "S_IFDIR" {
                    syncedPhotoFiles += ((try? afc.list(sub)) ?? []).count
                } else {
                    syncedPhotoFiles += 1
                }
            }
            r["photoDataSyncEntries"] = syncedPhotoFiles
            log("  /PhotoData/Sync: \(entries.count) entries, \(syncedPhotoFiles) items")
            if syncedPhotoFiles > 0 { reasons.append("/PhotoData/Sync holds \(syncedPhotoFiles) items") }
        }

        var photosDBRead = false
        for suffix in ["", "-wal", "-shm"] {
            let remote = "/PhotoData/Photos.sqlite\(suffix)"
            guard afc.info(remote) != nil else { continue }
            try afc.copy(remote: remote, to: dir.appendingPathComponent("Photos.sqlite\(suffix)"), chunk: 1 << 20)
            if suffix.isEmpty { photosDBRead = true }
        }
        r["photosDBReadable"] = photosDBRead
        if photosDBRead {
            let p = analyzePhotosDB(path: dir.appendingPathComponent("Photos.sqlite").path)
            r["photos"] = p
            log("  Photos.sqlite: \(p)")
            if let e = p["error"] { unknowns.append("Photos.sqlite query failed: \(e)") }
            if let s = p["assetsInSyncPaths"] as? Int64, s > 0 { reasons.append("\(s) photo assets live in a sync folder") }
        } else {
            unknowns.append("Photos.sqlite isn't readable over AFC")
        }

        // Lockdown domains that sometimes record sync state
        let device = try Device(udid: udid)
        let lockdown = try Lockdown(device: device)
        for d in ["com.apple.mobile.iTunes", "com.apple.mobile.sync_data_class", "com.apple.mobile.tethered_sync", "com.apple.mobile.data_sync"] {
            if let v = lockdown.value(domain: d) { r["lockdown:\(d)"] = v }
        }
    } catch {
        unknowns.append("\(error)")
    }

    let verdict: SyncVerdict = !reasons.isEmpty ? .synced : (!unknowns.isEmpty ? .unknown : .clean)
    r["verdict"] = verdict.rawValue
    r["syncedReasons"] = reasons
    r["unknowns"] = unknowns
    log("  verdict: \(verdict.rawValue)\(reasons.isEmpty ? "" : " [\(reasons.joined(separator: "; "))]")\(unknowns.isEmpty ? "" : " [unknown: \(unknowns.joined(separator: "; "))]")")
    writeResult(udid: udid, name: "preflight", r)
    return (verdict, r)
}

func analyzeMediaLibrary(path: String) -> [String: Any] {
    var r: [String: Any] = [:]
    do {
        let db = try SQLiteDB(path: path)
        guard try db.hasTable("item") else { r["error"] = "no item table"; return r }
        r["items"] = try db.int("SELECT COUNT(*) FROM item")
        if try db.hasTable("item_store") {
            let cols = try db.columns("item_store")
            r["itemStoreColumns"] = cols
            if cols.contains("sync_id") {
                r["itemsWithSyncID"] = try db.int("SELECT COUNT(*) FROM item_store WHERE sync_id != 0")
            } else {
                r["error"] = "item_store has no sync_id column"
            }
            if cols.contains("store_saga_id") {
                r["itemsWithSagaID"] = try db.int("SELECT COUNT(*) FROM item_store WHERE store_saga_id != 0")
            }
            if cols.contains("is_ota_purchased") {
                r["itemsOTAPurchased"] = try db.int("SELECT COUNT(*) FROM item_store WHERE is_ota_purchased != 0")
            }
        } else {
            r["error"] = "no item_store table"
        }
        if try db.hasTable("item_extra"), try db.hasColumn("item_extra", "location") {
            r["itemsWithLocalFile"] = try db.int("SELECT COUNT(*) FROM item_extra WHERE location IS NOT NULL AND location != ''")
            if try db.hasColumn("item", "media_type") {
                r["musicTracks"] = try db.int("""
                    SELECT COUNT(*) FROM item i JOIN item_extra e USING (item_pid)
                    WHERE i.media_type = 8 AND e.location IS NOT NULL AND e.location != ''
                    """)
            }
        }
        if try db.hasTable("container") {
            r["playlists"] = try db.int("SELECT COUNT(*) FROM container")
            if try db.hasColumn("container", "sync_id") {
                r["playlistsWithSyncID"] = try db.int("SELECT COUNT(*) FROM container WHERE sync_id != 0")
                if try db.hasTable("container_item") {
                    r["playlistsWithSyncIDAndItems"] = try db.int("""
                        SELECT COUNT(*) FROM container c WHERE c.sync_id != 0 AND EXISTS
                        (SELECT 1 FROM container_item ci WHERE ci.container_pid = c.container_pid)
                        """)
                }
            }
        }
        if try db.hasTable("_MLDatabaseProperties") {
            let props = try db.rows("SELECT key, value FROM _MLDatabaseProperties")
            r["propertyKeys"] = props.compactMap { $0["key"] as? String }.sorted()
        }
    } catch {
        r["error"] = "\(error)"
    }
    return r
}

func analyzePhotosDB(path: String) -> [String: Any] {
    var r: [String: Any] = [:]
    do {
        let db = try SQLiteDB(path: path)
        guard try db.hasTable("ZGENERICALBUM") else { r["error"] = "no ZGENERICALBUM table"; return r }
        let kinds = try db.rows("SELECT ZKIND AS kind, COUNT(*) AS n FROM ZGENERICALBUM GROUP BY ZKIND ORDER BY ZKIND")
        var map: [String: Int64] = [:]
        for k in kinds { map["\(k["kind"] ?? "null")"] = k["n"] as? Int64 ?? 0 }
        r["albumKinds"] = map
        // Album kind numbers aren't documented, so they're recorded but not used to
        // decide. Where the assets actually live is the evidence.
        if try db.hasTable("ZASSET") {
            r["assets"] = try db.int("SELECT COUNT(*) FROM ZASSET")
            let cols = try db.columns("ZASSET")
            if cols.contains("ZDIRECTORY") {
                r["assetsInSyncPaths"] = try db.int("""
                    SELECT COUNT(*) FROM ZASSET WHERE ZDIRECTORY LIKE '%Sync%' OR ZDIRECTORY LIKE '%SYNCD%'
                    """)
            }
            if cols.contains("ZSAVEDASSETTYPE") {
                let t = try db.rows("SELECT ZSAVEDASSETTYPE AS t, COUNT(*) AS n FROM ZASSET GROUP BY ZSAVEDASSETTYPE")
                var tm: [String: Int64] = [:]
                for x in t { tm["\(x["t"] ?? "null")"] = x["n"] as? Int64 ?? 0 }
                r["savedAssetTypes"] = tm
            }
            if cols.contains("ZCLOUDLOCALSTATE") {
                let t = try db.rows("SELECT ZCLOUDLOCALSTATE AS t, COUNT(*) AS n FROM ZASSET GROUP BY ZCLOUDLOCALSTATE")
                var tm: [String: Int64] = [:]
                for x in t { tm["\(x["t"] ?? "null")"] = x["n"] as? Int64 ?? 0 }
                r["cloudLocalStates"] = tm
            }
        }
    } catch {
        r["error"] = "\(error)"
    }
    return r
}
