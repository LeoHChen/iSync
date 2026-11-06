import Foundation

public struct IndexedFile: Codable, Hashable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Double
    public var fingerprint: MediaFingerprint
    public var sha256: String?

    public init(path: String, size: Int64, modified: Double, fingerprint: MediaFingerprint, sha256: String? = nil) {
        self.path = path
        self.size = size
        self.modified = modified
        self.fingerprint = fingerprint
        self.sha256 = sha256
    }
}

/// What a folder on this Mac holds. Results are cached outside the folder, so an archive is
/// never written to, and each file is read once unless it changes.
public final class FolderIndex {
    public let folder: URL
    private let cacheURL: URL
    private let files = Locked<[String: IndexedFile]>([:])

    public init(folder: URL, cacheDirectory: URL = iSyncCacheDirectory()) {
        self.folder = folder
        let name = "folder-\(deviceKey(udid: canonicalPath(folder))).json"
        cacheURL = cacheDirectory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([String: IndexedFile].self, from: data) {
            files.with { $0 = cached }
        }
    }

    public var allFiles: [IndexedFile] { files.with { Array($0.values) } }

    /// Walks the folder, skipping hidden files, and reads anything new or changed. `known`
    /// holds details already on hand for a path, such as files iSync copied itself, which saves
    /// opening them.
    public func refresh(known: [String: MediaFingerprint] = [:], onProgress: ((Int, Int) -> Void)? = nil) {
        let fm = FileManager.default
        var found: [(URL, Int64, Double)] = []
        if let walker = fm.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        {
            for case let url as URL in walker {
                guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      v.isRegularFile == true
                else { continue }
                found.append((URL(fileURLWithPath: canonicalPath(url)), Int64(v.fileSize ?? 0), v.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        let existing = files.with { $0 }
        var fresh: [String: IndexedFile] = [:]
        var toRead: [(URL, Int64, Double)] = []
        for item in found {
            if let cached = existing[item.0.path], cached.size == item.1, cached.modified == item.2 {
                fresh[item.0.path] = cached
            } else if let print = known[item.0.path], print.size == item.1 {
                fresh[item.0.path] = IndexedFile(path: item.0.path, size: item.1, modified: item.2, fingerprint: print)
            } else {
                toRead.append(item)
            }
        }
        let next = Locked(0)
        let results = Locked(fresh)
        let total = toRead.count
        DispatchQueue.concurrentPerform(iterations: max(1, min(6, ProcessInfo.processInfo.activeProcessorCount))) { _ in
            while true {
                let i: Int = next.with { n in defer { n += 1 }; return n }
                if i >= total { return }
                let (url, size, modified) = toRead[i]
                let print = LocalMediaReader.fingerprint(of: url, size: size)
                results.with { $0[url.path] = IndexedFile(path: url.path, size: size, modified: modified, fingerprint: print) }
                if i % 200 == 0 { onProgress?(i, total) }
            }
        }
        files.with { $0 = results.with { $0 } }
        save()
    }

    /// The file's SHA-256, worked out once and then remembered.
    public func sha256(ofPath path: String) throws -> String {
        let key = canonicalPath(URL(fileURLWithPath: path))
        if let known = files.with({ $0[key]?.sha256 }) { return known }
        let hash = try iSyncCore.sha256(file: URL(fileURLWithPath: key))
        files.with { $0[key]?.sha256 = hash }
        return hash
    }

    public func save() {
        let snapshot = files.with { $0 }
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
