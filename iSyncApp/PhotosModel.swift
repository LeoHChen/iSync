import AppKit
import Foundation
import iSyncCore

@MainActor
final class PhotosModel: ObservableObject {
    enum Phase: Equatable {
        case notLoaded
        case scanning(done: Int, total: Int)
        case ready
        case verifying
        case copying
    }

    struct Comparison {
        let otherName: String
        let result: PhoneComparison
    }

    @Published private(set) var phase: Phase = .notLoaded
    @Published private(set) var preview: SyncPreview?
    @Published private(set) var isPlanning = false
    @Published private(set) var planningStatus = ""
    @Published private(set) var progress = PhotoCopyEngine.Progress()
    @Published private(set) var verifiedBytes: Int64 = 0
    @Published private(set) var verifyTotalBytes: Int64 = 0
    @Published private(set) var lastResult: PhotoCopyEngine.Result?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var freeSpace: Int64?
    @Published private(set) var destination: URL
    @Published private(set) var referenceFolders: [URL]
    @Published private(set) var comparison: Comparison?
    @Published private(set) var isComparing = false
    @Published private(set) var comparisonError: String?

    @Published var layout: FolderLayout {
        didSet {
            guard layout != oldValue else { return }
            UserDefaults.standard.set(layout.rawValue, forKey: "layout-\(key)")
            replan()
        }
    }

    @Published var policy: ConflictPolicy {
        didSet {
            guard policy != oldValue else { return }
            UserDefaults.standard.set(policy.rawValue, forKey: "policy-\(key)")
            replan()
        }
    }

    @Published var copyPossibleDuplicates: Bool {
        didSet {
            guard copyPossibleDuplicates != oldValue else { return }
            UserDefaults.standard.set(copyPossibleDuplicates, forKey: "copyPossible-\(key)")
            replan()
        }
    }

    private unowned let device: DeviceModel
    private let key: String
    private var files: [RemoteFile] = []
    private var fingerprints: [String: MediaFingerprint] = [:]
    private var library: PhoneLibraryIndex?
    private var engine: PhotoCopyEngine?
    private var verifyControl: TransferControl?
    private var planGeneration = 0

    init(device: DeviceModel) {
        self.device = device
        key = deviceKey(udid: device.udid)
        let defaults = UserDefaults.standard
        layout = defaults.string(forKey: "layout-\(key)").flatMap(FolderLayout.init(rawValue:)) ?? .sameAsIPhone
        policy = defaults.string(forKey: "policy-\(key)").flatMap(ConflictPolicy.init(rawValue:)) ?? .skipDuplicates
        copyPossibleDuplicates = defaults.object(forKey: "copyPossible-\(key)") as? Bool ?? true
        referenceFolders = (defaults.stringArray(forKey: "referenceFolders") ?? []).map { URL(fileURLWithPath: $0) }
        if let saved = defaults.string(forKey: "destination-\(key)") {
            destination = URL(fileURLWithPath: saved)
        } else {
            // One folder per phone, so two phones' IMG_0001 files don't collide.
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            let folder = (device.summary?.name ?? "iPhone")
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            destination = pictures.appendingPathComponent("iSync").appendingPathComponent(folder)
        }
    }

    var isBusy: Bool { phase == .copying || phase == .verifying }
    var isCopying: Bool { phase == .copying }
    var plan: CopyPlan? { preview?.plan }

    var notEnoughSpace: Bool {
        guard let plan, let freeSpace else { return false }
        return plan.toCopyBytes > freeSpace
    }

    func loadIfNeeded() {
        if phase == .notLoaded { rescan() }
    }

    func rescan() {
        guard !isBusy else { return }
        phase = .scanning(done: 0, total: 0)
        errorMessage = nil
        notice = nil
        let udid = device.udid
        Task {
            do {
                let found = try await Task.detached {
                    try PhotoScanner.scan(udid: udid) { done, total in
                        Task { @MainActor [weak self] in
                            if case .scanning = self?.phase { self?.phase = .scanning(done: done, total: total) }
                        }
                    }
                }.value
                // Capture details come from the phone's database. Without it, matching falls
                // back to sizes and SHA-256, which still can't produce a wrong skip.
                let index = await Task.detached { try? PhoneLibraryIndex.fetch(udid: udid) }.value
                library = index
                fingerprints = index?.fingerprints ?? [:]
                if index == nil {
                    notice = "iSync couldn't read this iPhone's Photos database, so it can't spot edited or converted copies."
                }
                files = found
                #if DEBUG
                if let limit = debugLimit {
                    var subset: [RemoteFile] = []
                    for g in PhotoGrouping.groups(from: found) where subset.count < limit { subset += g.files }
                    files = subset
                }
                #endif
                phase = .ready
                replan()
            } catch {
                errorMessage = "Couldn't read the iPhone's photos: \(error.localizedDescription)"
                phase = .notLoaded
            }
        }
    }

    /// Runs the dry run again. Nothing is copied or changed.
    func replan() {
        planGeneration += 1
        let generation = planGeneration
        isPlanning = true
        planningStatus = "Checking what's already there…"
        let files = files, fingerprints = fingerprints, destination = destination, key = key
        let options = SyncOptions(layout: layout, policy: policy, copyPossibleDuplicates: copyPossibleDuplicates)
        let references = referenceFolders
        Task {
            let (result, free) = await Task.detached { () -> (SyncPreview, Int64?) in
                let manifest = CopyManifest.load(destination: destination, deviceKey: key)
                let destIndex = FolderIndex(folder: destination)
                destIndex.refresh(known: manifest.knownFingerprints(destination: destination, fingerprints: fingerprints))
                let refIndexes = references.map { FolderIndex(folder: $0) }
                refIndexes.forEach { $0.refresh() }
                let preview = SyncPlanner.preview(
                    files: files, fingerprints: fingerprints, destination: destination, manifest: manifest,
                    destinationFiles: destIndex.allFiles, referenceFiles: refIndexes.flatMap(\.allFiles), options: options)
                return (preview, Self.freeSpace(at: destination))
            }.value
            guard generation == planGeneration else { return }
            preview = result
            freeSpace = free
            isPlanning = false
        }
    }

    /// Free space on the volume, walking up to the nearest folder that exists.
    nonisolated private static func freeSpace(at url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u.deleteLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where to copy photos."
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
        UserDefaults.standard.set(url.path, forKey: "destination-\(key)")
        lastResult = nil
        replan()
    }

    func showDestination() {
        if FileManager.default.fileExists(atPath: destination.path) {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    func addReferenceFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Check These"
        panel.message = "Choose folders to check for duplicates, such as an old photo archive. iSync only reads them."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !referenceFolders.contains(url) { referenceFolders.append(url) }
        saveReferenceFolders()
        replan()
    }

    func removeReferenceFolder(_ url: URL) {
        referenceFolders.removeAll { $0 == url }
        saveReferenceFolders()
        replan()
    }

    private func saveReferenceFolders() {
        UserDefaults.standard.set(referenceFolders.map(\.path), forKey: "referenceFolders")
    }

    /// Settles any unconfirmed duplicates with SHA-256, then copies.
    func startCopy() {
        guard let preview, phase == .ready else { return }
        lastResult = nil
        errorMessage = nil
        if preview.needsVerification {
            verify(preview.unconfirmed)
        } else if preview.plan.toCopyFiles > 0 {
            runEngine(preview.plan)
        }
    }

    private func verify(_ candidates: [DuplicateCandidate]) {
        let udid = device.udid, destination = destination, key = key
        let references = referenceFolders
        let control = TransferControl()
        verifyControl = control
        verifiedBytes = 0
        verifyTotalBytes = candidates.reduce(0) { $0 + $1.file.size }
        phase = .verifying
        Task {
            let result = await Task.detached { () -> DuplicateVerifier.Result in
                let manifest = CopyManifest.load(destination: destination, deviceKey: key)
                let destIndex = FolderIndex(folder: destination)
                let refIndexes = references.map { FolderIndex(folder: $0) }
                let verifier = DuplicateVerifier(readerFactory: { try AFCClient.connect(udid: udid) })
                let result = verifier.run(candidates: candidates, manifest: manifest, indexes: [destIndex] + refIndexes, control: control) { n in
                    Task { @MainActor [weak self] in self?.verifiedBytes += Int64(n) }
                }
                try? result.manifest.save(destination: destination)
                return result
            }.value
            verifyControl = nil
            phase = .ready
            if result.wasCancelled {
                replan()
                return
            }
            if !result.failures.isEmpty {
                notice = "\(result.failures.count.formatted()) files couldn't be checked, so they weren't copied or skipped this time."
            }
            planGeneration += 1
            let generation = planGeneration
            isPlanning = true
            let files = files, fingerprints = fingerprints
            let options = SyncOptions(layout: layout, policy: policy, copyPossibleDuplicates: copyPossibleDuplicates)
            let updated = await Task.detached { () -> SyncPreview in
                let destIndex = FolderIndex(folder: destination)
                let refIndexes = references.map { FolderIndex(folder: $0) }
                return SyncPlanner.preview(
                    files: files, fingerprints: fingerprints, destination: destination, manifest: result.manifest,
                    destinationFiles: destIndex.allFiles, referenceFiles: refIndexes.flatMap(\.allFiles), options: options)
            }.value
            guard generation == planGeneration else { return }
            preview = updated
            isPlanning = false
            if updated.plan.toCopyFiles > 0 { runEngine(updated.plan) }
        }
    }

    func cancelVerify() { verifyControl?.cancel() }

    private func runEngine(_ plan: CopyPlan) {
        var start = PhotoCopyEngine.Progress()
        start.totalFiles = plan.toCopyFiles
        start.totalBytes = plan.toCopyBytes
        progress = start
        phase = .copying
        let udid = device.udid
        let manifest = CopyManifest.load(destination: destination, deviceKey: key)
        let engine = PhotoCopyEngine(
            plan: plan, destination: destination, manifest: manifest,
            readerFactory: { try AFCClient.connect(udid: udid) })
        self.engine = engine
        engine.start(
            onProgress: { p in
                Task { @MainActor [weak self] in
                    if self?.phase == .copying { self?.progress = p }
                }
            },
            onFinish: { result in
                Task { @MainActor [weak self] in self?.finished(result) }
            })
    }

    private func finished(_ result: PhotoCopyEngine.Result) {
        lastResult = result
        engine = nil
        phase = .ready
        replan()
    }

    func pause() {
        engine?.pause()
        progress.isPaused = true
    }

    func resume() {
        engine?.resume()
        progress.isPaused = false
    }

    func cancel() { engine?.cancel() }

    /// Works out what another connected iPhone already has. Neither phone is changed.
    func compare(with other: DeviceModel) {
        guard let library, !isComparing else { return }
        isComparing = true
        comparisonError = nil
        let udid = other.udid, name = other.displayName, sourceFiles = files
        Task {
            do {
                let result = try await Task.detached { () -> PhoneComparison in
                    let target = try PhoneLibraryIndex.fetch(udid: udid)
                    let targetFiles = try PhotoScanner.scan(udid: udid)
                    return PhoneComparer.compare(source: library, destination: target, sourceFiles: sourceFiles, destinationFiles: targetFiles)
                }.value
                comparison = Comparison(otherName: name, result: result)
            } catch {
                comparisonError = "Couldn't read \(name): \(error.localizedDescription)"
            }
            isComparing = false
        }
    }

    #if DEBUG
    private var debugLimit: Int?

    func debugUse(destination: URL, limit: Int) {
        self.destination = destination
        debugLimit = limit
    }
    #endif
}
