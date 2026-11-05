import Foundation

/// Files that belong together: same folder and same name, such as a Live Photo's HEIC and MOV.
public struct PhotoGroup: Hashable, Sendable {
    public let folder: String
    public let baseName: String
    /// The still image comes first, then the video, then sidecars.
    public let files: [RemoteFile]

    static let stills: Set<String> = ["heic", "heif", "jpg", "jpeg", "dng", "png", "tif", "tiff", "webp"]
    static let liveStills: Set<String> = ["heic", "heif", "jpg", "jpeg"]

    public var isLivePhoto: Bool {
        let exts = Set(files.map { ($0.path as NSString).pathExtension.lowercased() })
        return exts.contains("mov") && !exts.isDisjoint(with: Self.liveStills)
    }

    /// The date that places the whole group, so a pair stays together across a month boundary.
    public var date: Date { files[0].modified }
}

public enum PhotoGrouping {
    private static func rank(_ file: RemoteFile) -> Int {
        let ext = (file.path as NSString).pathExtension.lowercased()
        if PhotoGroup.stills.contains(ext) { return 0 }
        if ext == "mov" || ext == "mp4" { return 1 }
        return 2
    }

    /// Groups files by folder and name, newest group first.
    public static func groups(from files: [RemoteFile]) -> [PhotoGroup] {
        var buckets: [String: [RemoteFile]] = [:]
        for f in files {
            let p = f.path as NSString
            let key = p.deletingLastPathComponent + "/" + (p.lastPathComponent as NSString).deletingPathExtension.lowercased()
            buckets[key, default: []].append(f)
        }
        return buckets.values.map { members in
            let sorted = members.sorted { (rank($0), $0.path) < (rank($1), $1.path) }
            let p = sorted[0].path as NSString
            return PhotoGroup(
                folder: p.deletingLastPathComponent,
                baseName: (p.lastPathComponent as NSString).deletingPathExtension,
                files: sorted)
        }
        .sorted { ($0.date, $0.files[0].path) > ($1.date, $1.files[0].path) }
    }
}

public enum FolderLayout: String, Codable, CaseIterable, Sendable {
    case sameAsIPhone
    case yearMonth
}

/// Records what has been copied, so repeat runs can skip it.
public struct CopyManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var size: Int64
        public var modifiedNs: Int64
        /// Relative to the destination folder.
        public var localPath: String
    }

    public var version = 1
    public var deviceKey: String
    public var entries: [String: Entry] = [:]

    public init(deviceKey: String) { self.deviceKey = deviceKey }

    public static func url(destination: URL, deviceKey: String) -> URL {
        destination.appendingPathComponent(".isync/manifest-\(deviceKey).json")
    }

    /// Loads the manifest. A missing or unreadable one starts empty, and the planner
    /// rebuilds it from the files on disk without copying them again.
    public static func load(destination: URL, deviceKey: String) -> CopyManifest {
        let url = url(destination: destination, deviceKey: deviceKey)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(CopyManifest.self, from: data),
              manifest.deviceKey == deviceKey
        else { return CopyManifest(deviceKey: deviceKey) }
        return manifest
    }

    public func save(destination: URL) throws {
        let url = Self.url(destination: destination, deviceKey: deviceKey)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public mutating func record(_ file: RemoteFile, localPath: String) {
        entries[file.path] = Entry(size: file.size, modifiedNs: file.modifiedNs, localPath: localPath)
    }
}

public struct PlannedFile: Hashable, Sendable {
    public let remote: RemoteFile
    /// Relative to the destination folder.
    public let localPath: String
}

public struct PlannedGroup: Hashable, Sendable {
    public let files: [PlannedFile]
    public let isLivePhoto: Bool
}

public struct CopyPlan: Sendable {
    public var toCopy: [PlannedGroup] = []
    /// Already on disk with a matching size and date, but missing from the manifest.
    public var adopted: [PlannedFile] = []
    public var totalFiles = 0
    public var totalBytes: Int64 = 0
    public var alreadyCopiedFiles = 0
    public var alreadyCopiedBytes: Int64 = 0
    public var livePhotosToCopy = 0
    /// Remote paths outside /DCIM, or with ".." in them. These are never copied.
    public var skippedUnsafe = 0

    public var toCopyFiles: Int { toCopy.reduce(0) { $0 + $1.files.count } }
    public var toCopyBytes: Int64 { toCopy.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.remote.size } } }
}

public enum CopyPlanner {
    static func isSafe(_ path: String) -> Bool {
        guard path.hasPrefix("/DCIM/") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    private static func directory(for group: PhotoGroup, layout: FolderLayout, calendar: Calendar) -> String {
        switch layout {
        case .sameAsIPhone:
            return String(group.folder.dropFirst())
        case .yearMonth:
            let c = calendar.dateComponents([.year, .month], from: group.date)
            return String(format: "%04d/%02d", c.year ?? 0, c.month ?? 0)
        }
    }

    /// Size and modification date of a local file, or nil if it isn't there.
    private static func localFile(_ url: URL) -> (size: Int64, modified: Date)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = a[.size] as? NSNumber,
              let date = a[.modificationDate] as? Date
        else { return nil }
        return (size.int64Value, date)
    }

    private static func isSame(_ local: (size: Int64, modified: Date), as remote: RemoteFile) -> Bool {
        local.size == remote.size && abs(local.modified.timeIntervalSince(remote.modified)) < 2
    }

    /// Decides what to copy and where. An existing file is never overwritten: a different
    /// file with the same name gets a numbered name, and the whole group keeps that number.
    public static func plan(
        files: [RemoteFile], destination: URL, manifest: CopyManifest, layout: FolderLayout,
        calendar: Calendar = .current
    ) -> CopyPlan {
        var plan = CopyPlan()
        let safe = files.filter { isSafe($0.path) }
        plan.skippedUnsafe = files.count - safe.count
        plan.totalFiles = safe.count
        plan.totalBytes = safe.reduce(0) { $0 + $1.size }

        let groups = PhotoGrouping.groups(from: safe)

        // First pass: find what's current, and reserve those paths.
        var reserved = Set<String>()
        var current = Set<String>()
        for file in safe {
            guard let e = manifest.entries[file.path], e.size == file.size, e.modifiedNs == file.modifiedNs,
                  let local = localFile(destination.appendingPathComponent(e.localPath)), local.size == file.size
            else { continue }
            current.insert(file.path)
            reserved.insert(e.localPath.lowercased())
            plan.alreadyCopiedFiles += 1
            plan.alreadyCopiedBytes += file.size
        }

        // Second pass: place everything else.
        for group in groups {
            let remaining = group.files.filter { !current.contains($0.path) }
            if remaining.isEmpty { continue }

            // If part of the group is already copied, the rest goes next to it.
            var dir = directory(for: group, layout: layout, calendar: calendar)
            var base = group.baseName
            if let anchor = group.files.first(where: { current.contains($0.path) }),
               let e = manifest.entries[anchor.path]
            {
                let p = e.localPath as NSString
                dir = p.deletingLastPathComponent
                base = (p.lastPathComponent as NSString).deletingPathExtension
            }

            var n = 1
            placing: while true {
                let stem = n == 1 ? base : "\(base) (\(n))"
                var toCopy: [PlannedFile] = []
                var adopted: [PlannedFile] = []
                for file in remaining {
                    let ext = (file.path as NSString).pathExtension
                    let rel = (dir as NSString).appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
                    if reserved.contains(rel.lowercased()) {
                        n += 1
                        continue placing
                    }
                    if let local = localFile(destination.appendingPathComponent(rel)) {
                        guard isSame(local, as: file) else {
                            n += 1
                            continue placing
                        }
                        adopted.append(PlannedFile(remote: file, localPath: rel))
                    } else {
                        toCopy.append(PlannedFile(remote: file, localPath: rel))
                    }
                }
                for f in toCopy + adopted { reserved.insert(f.localPath.lowercased()) }
                plan.adopted += adopted
                plan.alreadyCopiedFiles += adopted.count
                plan.alreadyCopiedBytes += adopted.reduce(0) { $0 + $1.remote.size }
                if !toCopy.isEmpty {
                    plan.toCopy.append(PlannedGroup(files: toCopy, isLivePhoto: group.isLivePhoto))
                    if group.isLivePhoto { plan.livePhotosToCopy += 1 }
                }
                break
            }
        }
        return plan
    }
}
