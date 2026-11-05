import Foundation

public enum SyncCategory: String, CaseIterable, Sendable {
    /// Not at the destination.
    case new
    /// Copied by an earlier run, or already at its exact path.
    case alreadyCopied
    /// The same bytes exist under another name or folder, or earlier in this same run.
    case exactDuplicate
    /// A different file already has this name.
    case sameNameDifferent
    /// Same capture time and dimensions but different bytes, such as an edited or
    /// converted copy. These are never skipped silently.
    case possibleDuplicate
}

public struct SyncTally: Equatable, Sendable {
    public var files = 0
    public var bytes: Int64 = 0
    public init() {}
    mutating func add(_ file: RemoteFile) {
        files += 1
        bytes += file.size
    }
}

/// What a file might be a duplicate of.
public enum DuplicateTarget: Hashable, Sendable {
    /// A file in the destination folder.
    case destination(IndexedFile)
    /// A file in a folder the user asked to check, which is only ever read.
    case reference(IndexedFile)
    /// Another file on the same iPhone, earlier in this run.
    case sameRun(RemoteFile)
}

public struct DuplicateCandidate: Hashable, Sendable {
    public let file: RemoteFile
    public let target: DuplicateTarget
}

public struct PossibleDuplicate: Hashable, Sendable {
    public let file: RemoteFile
    public let similarTo: String
    public let willCopy: Bool
}

public struct SyncOptions: Sendable {
    public var layout: FolderLayout
    public var policy: ConflictPolicy
    /// Possible duplicates are copied unless the user turns this off in the preview.
    public var copyPossibleDuplicates: Bool

    public init(layout: FolderLayout = .sameAsIPhone, policy: ConflictPolicy = .skipDuplicates, copyPossibleDuplicates: Bool = true) {
        self.layout = layout
        self.policy = policy
        self.copyPossibleDuplicates = copyPossibleDuplicates
    }
}

/// The dry run: what would happen, with nothing changed yet.
public struct SyncPreview: Sendable {
    public var tallies: [SyncCategory: SyncTally] = [:]
    public var total = SyncTally()
    /// What the copy would do. Hand this to the engine.
    public var plan = CopyPlan()
    /// Look identical, but SHA-256 hasn't confirmed it yet. These aren't copied or
    /// recorded until it has, so a false match can't lose a file.
    public var unconfirmed: [DuplicateCandidate] = []
    public var possibleDuplicates: [PossibleDuplicate] = []
    public var skippedUnsafe = 0

    public func tally(_ c: SyncCategory) -> SyncTally { tallies[c] ?? SyncTally() }
    public var unconfirmedBytes: Int64 { unconfirmed.reduce(0) { $0 + $1.file.size } }
    public var needsVerification: Bool { !unconfirmed.isEmpty }
}

public enum SyncPlanner {
    private enum Duplicate {
        case confirmed(DuplicateTarget)
        case unconfirmed(DuplicateTarget)
    }

    public static func preview(
        files: [RemoteFile], fingerprints: [String: MediaFingerprint], destination: URL,
        manifest: CopyManifest, destinationFiles: [IndexedFile], referenceFiles: [IndexedFile] = [],
        options: SyncOptions, calendar: Calendar = .current
    ) -> SyncPreview {
        var preview = SyncPreview()
        let safe = files.filter { CopyPlanner.isSafe($0.path) }
        preview.skippedUnsafe = files.count - safe.count
        for f in safe { preview.total.add(f) }

        // Files the manifest says are done.
        var current = Set<String>()
        for f in safe {
            guard let e = manifest.entries[f.path], e.size == f.size, e.modifiedNs == f.modifiedNs else { continue }
            if let local = CopyPlanner.localFile(destination.appendingPathComponent(e.localPath)), local.size == f.size {
                current.insert(f.path)
            }
        }

        // Where to look for the same content.
        var bySize: [Int64: [(IndexedFile, Bool)]] = [:]
        var byVisual: [String: [IndexedFile]] = [:]
        for (list, isDestination) in [(destinationFiles, true), (referenceFiles, false)] {
            for item in list {
                bySize[item.fingerprint.size, default: []].append((item, isDestination))
                if let key = item.fingerprint.visualKey { byVisual[key, default: []].append(item) }
            }
        }

        let groups = PhotoGrouping.groups(from: safe)
        var duplicates: [String: Duplicate] = [:]
        var possibles: [String: String] = [:]
        var seenInRun: [String: RemoteFile] = [:]
        let destinationRoot = canonicalPath(destination) + "/"

        for group in groups {
            let dir = CopyPlanner.directory(for: group, layout: options.layout, calendar: calendar)
            for file in group.files where !current.contains(file.path) {
                let print = fingerprints[file.path] ?? MediaFingerprint(size: file.size)
                let sourceHash = manifest.sourceHash(for: file)

                // Already at its own path with the same size and date: the planner adopts it.
                let own = (dir as NSString).appendingPathComponent((file.path as NSString).lastPathComponent)
                if let local = CopyPlanner.localFile(destination.appendingPathComponent(own)), CopyPlanner.isSame(local, as: file) {
                    continue
                }

                // A match may be another file's finished copy: that's still the same photo.
                let candidates = (bySize[file.size] ?? []).filter { print.couldBeSameContent(as: $0.0.fingerprint) }
                    .sorted { $0.1 && !$1.1 }
                search: for (item, isDestination) in candidates {
                    let target: DuplicateTarget = isDestination ? .destination(item) : .reference(item)
                    if let sourceHash, let known = item.sha256 {
                        if sourceHash == known {
                            duplicates[file.path] = .confirmed(target)
                            break search
                        }
                    } else if duplicates[file.path] == nil {
                        duplicates[file.path] = .unconfirmed(target)
                    }
                }
                if duplicates[file.path] != nil { continue }

                // The same content twice on the phone gets copied once.
                if let key = print.visualKey {
                    let runKey = "\(file.size)|\(key)"
                    if let first = seenInRun[runKey] {
                        if let a = manifest.sourceHash(for: first), let sourceHash {
                            if a == sourceHash {
                                duplicates[file.path] = .confirmed(.sameRun(first))
                                continue
                            }
                        } else {
                            duplicates[file.path] = .unconfirmed(.sameRun(first))
                            continue
                        }
                    } else {
                        seenInRun[runKey] = file
                    }
                    if let similar = byVisual[key]?.first {
                        possibles[file.path] = similar.path
                    }
                }
            }
        }

        // A pair stays together: if one half would be copied, a half that matched somewhere
        // outside the destination is copied too. A match inside the destination acts as an
        // anchor instead, so the other half lands beside it.
        for group in groups {
            let wouldCopy = group.files.contains {
                !current.contains($0.path) && duplicates[$0.path] == nil
            }
            guard wouldCopy else { continue }
            for file in group.files {
                switch duplicates[file.path] {
                case .confirmed(.reference), .unconfirmed(.reference), .confirmed(.sameRun), .unconfirmed(.sameRun):
                    duplicates[file.path] = nil
                default: break
                }
            }
        }

        // Matches inside the destination count as done for planning, so nothing recopies them.
        var effective = manifest
        var neverRecopy = Set<String>()
        var confirmedInDestination: [PlannedFile] = []
        for file in safe {
            let target: DuplicateTarget
            let isConfirmed: Bool
            switch duplicates[file.path] {
            case .confirmed(let t): (target, isConfirmed) = (t, true)
            case .unconfirmed(let t): (target, isConfirmed) = (t, false)
            case nil: continue
            }
            guard case .destination(let item) = target, item.path.hasPrefix(destinationRoot) else { continue }
            let rel = String(item.path.dropFirst(destinationRoot.count))
            effective.record(file, localPath: rel)
            neverRecopy.insert(file.path)
            if isConfirmed { confirmedInDestination.append(PlannedFile(remote: file, localPath: rel)) }
        }

        // Everything that isn't skipped goes to the planner, which handles names and conflicts.
        let skipped = Set(duplicates.compactMap { path, d -> String? in
            switch d {
            case .confirmed(.destination), .unconfirmed(.destination): return nil
            default: return path
            }
        })
        let held = options.copyPossibleDuplicates ? Set<String>() : Set(possibles.keys)
        let toPlan = safe.filter { !skipped.contains($0.path) && !held.contains($0.path) }
        preview.plan = CopyPlanner.plan(
            files: toPlan, destination: destination, manifest: effective, layout: options.layout,
            policy: options.policy, neverRecopy: neverRecopy, calendar: calendar)
        preview.plan.totalFiles = preview.total.files
        preview.plan.totalBytes = preview.total.bytes
        preview.plan.adopted += confirmedInDestination
        preview.plan.skippedUnsafe = preview.skippedUnsafe

        let planned = preview.plan.toCopy.flatMap(\.files)
        let conflicted = Set(planned.filter(\.nameConflict).map(\.remote.path))
        // Under Overwrite, a recopy of an identical file at the same path was already there.
        let adopted = Set(preview.plan.adopted.map(\.remote.path))
            .union(planned.filter { $0.replaces && !$0.nameConflict }.map(\.remote.path))
        for file in safe {
            let category: SyncCategory
            if duplicates[file.path] != nil {
                category = .exactDuplicate
            } else if current.contains(file.path) || adopted.contains(file.path) {
                category = .alreadyCopied
            } else if possibles[file.path] != nil {
                category = .possibleDuplicate
            } else if conflicted.contains(file.path) {
                category = .sameNameDifferent
            } else {
                category = .new
            }
            preview.tallies[category, default: SyncTally()].add(file)
        }

        for file in safe {
            if case .unconfirmed(let target) = duplicates[file.path] {
                preview.unconfirmed.append(DuplicateCandidate(file: file, target: target))
            }
            if let similar = possibles[file.path], duplicates[file.path] == nil {
                preview.possibleDuplicates.append(
                    PossibleDuplicate(file: file, similarTo: similar, willCopy: !held.contains(file.path)))
            }
        }
        return preview
    }
}

/// Settles unconfirmed duplicates with SHA-256. Each file is hashed once: results are kept in
/// the manifest and the folder indexes.
public final class DuplicateVerifier {
    public struct Result: Sendable {
        public var manifest: CopyManifest
        public var failures: [String] = []
        public var wasCancelled = false
    }

    private let readerFactory: () throws -> RemoteFileReader
    private let connections: Int

    public init(connections: Int = PhotoCopyEngine.defaultConnections, readerFactory: @escaping () throws -> RemoteFileReader) {
        self.connections = max(1, connections)
        self.readerFactory = readerFactory
    }

    public func run(
        candidates: [DuplicateCandidate], manifest: CopyManifest, indexes: [FolderIndex],
        control: TransferControl, onBytes: @escaping (Int) -> Void
    ) -> Result {
        // Files on this Mac are quick, so they go first.
        var failures: [String] = []
        for candidate in candidates {
            let item: IndexedFile
            switch candidate.target {
            case .destination(let i), .reference(let i): item = i
            case .sameRun: continue
            }
            guard let index = indexes.first(where: { item.path.hasPrefix(canonicalPath($0.folder) + "/") }) else { continue }
            do { _ = try index.sha256(ofPath: item.path) } catch { failures.append("\(item.path): \(error.localizedDescription)") }
        }
        indexes.forEach { $0.save() }

        var remotes: [RemoteFile] = []
        var seen = Set<String>()
        for candidate in candidates {
            var both = [candidate.file]
            if case .sameRun(let other) = candidate.target { both.append(other) }
            for f in both where manifest.sourceHash(for: f) == nil && seen.insert(f.path).inserted { remotes.append(f) }
        }

        let next = Locked(0)
        let output = Locked(Result(manifest: manifest, failures: failures))
        let total = remotes.count
        let group = DispatchGroup()
        for _ in 0..<connections {
            group.enter()
            Thread { [readerFactory] in
                defer { group.leave() }
                guard var reader = try? readerFactory() else {
                    output.with { $0.failures.append("Couldn't connect to the iPhone.") }
                    return
                }
                while control.checkpoint() {
                    let i: Int = next.with { n in defer { n += 1 }; return n }
                    if i >= total { return }
                    let file = remotes[i]
                    for attempt in 1...2 {
                        var moved = 0
                        do {
                            let hash = try reader.sha256(remote: file.path, chunk: 1 << 20, control: control) { n in
                                moved += n
                                onBytes(n)
                            }
                            output.with { $0.manifest.recordSourceHash(file, sha256: hash) }
                            break
                        } catch is TransferCancelled {
                            return
                        } catch {
                            onBytes(-moved)
                            if attempt == 2 || (error as? AFCError)?.isFileLevel == true {
                                output.with { $0.failures.append("\(file.path): \(error.localizedDescription)") }
                                break
                            }
                            if let fresh = try? readerFactory() { reader = fresh }
                        }
                    }
                }
            }.start()
        }
        group.wait()
        output.with { $0.wasCancelled = control.isCancelled }
        return output.with { $0 }
    }
}
