import Foundation

/// Copies a plan's files, keeping each group on one connection so pairs arrive together.
/// Files land under a temporary name and are renamed only once their size checks out.
public final class PhotoCopyEngine {
    /// Step 1 measured no speed gain above 2 connections on USB 2.
    public static let defaultConnections = 2

    public struct Progress: Equatable, Sendable {
        public var copiedFiles = 0
        public var totalFiles = 0
        public var copiedBytes: Int64 = 0
        public var totalBytes: Int64 = 0
        public var failedFiles = 0
        public var bytesPerSecond = 0.0
        public var secondsRemaining: Double?
        public var isPaused = false
        public var fraction: Double { totalBytes > 0 ? min(1, Double(copiedBytes) / Double(totalBytes)) : 0 }
        public init() {}
    }

    public struct Failure: Equatable, Sendable {
        public let path: String
        public let reason: String
    }

    public struct Result: Sendable {
        public var copiedFiles = 0
        public var copiedBytes: Int64 = 0
        public var failures: [Failure] = []
        public var wasCancelled = false
        /// Why the whole copy stopped early, such as the iPhone being unplugged.
        public var stopReason: String?
        public var seconds = 0.0
        public var averageBytesPerSecond: Double { seconds > 0 ? Double(copiedBytes) / seconds : 0 }
        public init() {}
    }

    private struct Shared {
        var nextGroup = 0
        var copiedFiles = 0
        var copiedBytes: Int64 = 0
        var failures: [Failure] = []
        var stopReason: String?
        var manifest: CopyManifest
        var manifestDirty = false
    }

    private let plan: CopyPlan
    private let destination: URL
    private let connections: Int
    private let chunkBytes: Int
    private let readerFactory: () throws -> RemoteFileReader
    private let shared: Locked<Shared>
    private let control = TransferControl()
    private let timing = Locked<(paused: TimeInterval, pausedAt: Date?)>((0, nil))
    private let fileManager = FileManager.default
    private let retryDelay: TimeInterval

    public init(
        plan: CopyPlan, destination: URL, manifest: CopyManifest,
        connections: Int = PhotoCopyEngine.defaultConnections, chunkBytes: Int = 1 << 20,
        retryDelay: TimeInterval = 2,
        readerFactory: @escaping () throws -> RemoteFileReader
    ) {
        self.plan = plan
        self.destination = destination
        self.connections = max(1, connections)
        self.chunkBytes = chunkBytes
        self.retryDelay = retryDelay
        self.readerFactory = readerFactory
        var m = manifest
        for f in plan.adopted { m.record(f.remote, localPath: f.localPath) }
        shared = Locked(Shared(manifest: m, manifestDirty: !plan.adopted.isEmpty))
    }

    public func pause() {
        timing.with { if $0.pausedAt == nil { $0.pausedAt = Date() } }
        control.pause()
    }

    public func resume() {
        timing.with {
            if let at = $0.pausedAt { $0.paused += Date().timeIntervalSince(at) }
            $0.pausedAt = nil
        }
        control.resume()
    }

    public func cancel() { control.cancel() }

    public var isPaused: Bool { control.isPaused }

    /// Runs in the background. Callbacks arrive on a background queue.
    public func start(onProgress: @escaping (Progress) -> Void, onFinish: @escaping (Result) -> Void) {
        let totalFiles = plan.toCopyFiles
        let totalBytes = plan.toCopyBytes
        let started = Date()
        // Stops the Mac sleeping during a long copy, which would drop the connection.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Copying photos from iPhone")

        let reporterQueue = DispatchQueue(label: "isync.copy.progress")
        var samples: [(time: Date, bytes: Int64)] = []
        var lastManifestSave = Date()
        let timer = DispatchSource.makeTimerSource(queue: reporterQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [self] in
            let snapshot = shared.with { ($0.copiedFiles, $0.copiedBytes, $0.failures.count) }
            var p = Progress()
            p.totalFiles = totalFiles
            p.totalBytes = totalBytes
            p.copiedFiles = snapshot.0
            p.copiedBytes = snapshot.1
            p.failedFiles = snapshot.2
            p.isPaused = control.isPaused
            let now = Date()
            if p.isPaused {
                samples.removeAll()
            } else {
                samples.append((now, p.copiedBytes))
                samples.removeAll { now.timeIntervalSince($0.time) > 5 }
                if let first = samples.first, now.timeIntervalSince(first.time) > 0.4 {
                    p.bytesPerSecond = Double(max(0, p.copiedBytes - first.bytes)) / now.timeIntervalSince(first.time)
                    if p.bytesPerSecond > 0 {
                        p.secondsRemaining = Double(max(0, totalBytes - p.copiedBytes)) / p.bytesPerSecond
                    }
                }
            }
            onProgress(p)
            if now.timeIntervalSince(lastManifestSave) > 10 {
                lastManifestSave = now
                saveManifest()
            }
        }
        timer.resume()

        let group = DispatchGroup()
        for _ in 0..<connections {
            group.enter()
            let t = Thread { [self] in
                worker()
                group.leave()
            }
            t.start()
        }

        group.notify(queue: reporterQueue) { [self] in
            timer.cancel()
            saveManifest()
            ProcessInfo.processInfo.endActivity(activity)
            let pausedTime = timing.with { $0.paused }
            var result = Result()
            shared.with {
                result.copiedFiles = $0.copiedFiles
                result.copiedBytes = $0.copiedBytes
                result.failures = $0.failures
                result.stopReason = $0.stopReason
            }
            result.wasCancelled = control.isCancelled && result.stopReason == nil
            result.seconds = max(0, Date().timeIntervalSince(started) - pausedTime)
            onFinish(result)
        }
    }

    private func saveManifest() {
        let copy: CopyManifest? = shared.with { s in
            guard s.manifestDirty else { return nil }
            s.manifestDirty = false
            return s.manifest
        }
        try? copy?.save(destination: destination)
    }

    private func stopAll(_ reason: String) {
        shared.with { if $0.stopReason == nil { $0.stopReason = reason } }
        control.cancel()
    }

    private func worker() {
        var reader: RemoteFileReader
        do {
            reader = try readerFactory()
        } catch {
            stopAll("Couldn't connect to the iPhone: \(error.localizedDescription)")
            return
        }
        while control.checkpoint() {
            let index: Int = shared.with { s in defer { s.nextGroup += 1 }; return s.nextGroup }
            guard index < plan.toCopy.count else { return }
            for file in plan.toCopy[index].files {
                guard control.checkpoint() else { return }
                copyOne(file, reader: &reader)
            }
        }
    }

    private func copyOne(_ file: PlannedFile, reader: inout RemoteFileReader) {
        let final = destination.appendingPathComponent(file.localPath)
        let dir = final.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(final.lastPathComponent).isync-partial")
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            stopAll("Couldn't write to the destination folder: \(error.localizedDescription)")
            return
        }

        for attempt in 1...2 {
            var bytesThisAttempt: Int64 = 0
            do {
                try? fileManager.removeItem(at: temp)
                let got = try reader.copy(remote: file.remote.path, to: temp, chunk: chunkBytes, control: control) { n in
                    bytesThisAttempt += Int64(n)
                    self.shared.with { $0.copiedBytes += Int64(n) }
                }
                let onDisk = (try? fileManager.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)??.int64Value
                guard got == file.remote.size, onDisk == file.remote.size else {
                    throw ISyncError("Size check failed: expected \(file.remote.size) bytes, got \(onDisk ?? got).")
                }
                // Never replace a file that appeared since planning.
                try fileManager.moveItem(at: temp, to: final)
                try? fileManager.setAttributes(
                    [.modificationDate: file.remote.modified, .creationDate: file.remote.modified], ofItemAtPath: final.path)
                shared.with {
                    $0.copiedFiles += 1
                    $0.manifest.record(file.remote, localPath: file.localPath)
                    $0.manifestDirty = true
                }
                return
            } catch {
                try? fileManager.removeItem(at: temp)
                shared.with { $0.copiedBytes -= bytesThisAttempt }
                if error is TransferCancelled { return }
                if let e = error as? CocoaError, e.isFileError, e.code != .fileWriteFileExists {
                    stopAll("Couldn't write to the destination folder: \(e.localizedDescription)")
                    return
                }
                if let e = error as? AFCError, e.isFileLevel {
                    shared.with { $0.failures.append(Failure(path: file.remote.path, reason: e.localizedDescription)) }
                    return
                }
                if attempt == 2 {
                    shared.with { $0.failures.append(Failure(path: file.remote.path, reason: error.localizedDescription)) }
                    return
                }
                // A lost connection is likely. Reconnect once before giving up.
                Thread.sleep(forTimeInterval: retryDelay)
                do {
                    reader = try readerFactory()
                } catch {
                    stopAll("The iPhone was disconnected. Plug it back in to continue where this left off.")
                    return
                }
            }
        }
    }
}
