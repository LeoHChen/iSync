import AppKit
import Foundation
import iSyncCore

@MainActor
final class PhotosModel: ObservableObject {
    enum Phase: Equatable {
        case notLoaded
        case scanning(done: Int, total: Int)
        case ready
        case copying
    }

    @Published private(set) var phase: Phase = .notLoaded
    @Published private(set) var plan: CopyPlan?
    @Published private(set) var isPlanning = false
    @Published private(set) var progress = PhotoCopyEngine.Progress()
    @Published private(set) var lastResult: PhotoCopyEngine.Result?
    @Published private(set) var errorMessage: String?
    @Published private(set) var freeSpace: Int64?
    @Published private(set) var destination: URL
    @Published var layout: FolderLayout {
        didSet {
            guard layout != oldValue else { return }
            UserDefaults.standard.set(layout.rawValue, forKey: "layout-\(key)")
            replan()
        }
    }

    private unowned let device: DeviceModel
    private let key: String
    private var files: [RemoteFile] = []
    private var engine: PhotoCopyEngine?
    private var planGeneration = 0

    init(device: DeviceModel) {
        self.device = device
        key = deviceKey(udid: device.udid)
        let defaults = UserDefaults.standard
        layout = defaults.string(forKey: "layout-\(key)").flatMap(FolderLayout.init(rawValue:)) ?? .sameAsIPhone
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

    var isCopying: Bool { phase == .copying }
    var isPaused: Bool { progress.isPaused }

    var notEnoughSpace: Bool {
        guard let plan, let freeSpace else { return false }
        return plan.toCopyBytes > freeSpace
    }

    func loadIfNeeded() {
        if phase == .notLoaded { rescan() }
    }

    func rescan() {
        guard phase != .copying else { return }
        phase = .scanning(done: 0, total: 0)
        errorMessage = nil
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

    func replan() {
        planGeneration += 1
        let generation = planGeneration
        isPlanning = true
        let files = files, destination = destination, layout = layout, key = key
        Task {
            let (newPlan, free) = await Task.detached { () -> (CopyPlan, Int64?) in
                let manifest = CopyManifest.load(destination: destination, deviceKey: key)
                let plan = CopyPlanner.plan(files: files, destination: destination, manifest: manifest, layout: layout)
                return (plan, Self.freeSpace(at: destination))
            }.value
            guard generation == planGeneration else { return }
            plan = newPlan
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

    func startCopy() {
        guard let plan, plan.toCopyFiles > 0, phase == .ready else { return }
        lastResult = nil
        errorMessage = nil
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
                Task { @MainActor [weak self] in
                    self?.finished(result)
                }
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

    #if DEBUG
    private var debugLimit: Int?

    func debugUse(destination: URL, limit: Int) {
        self.destination = destination
        debugLimit = limit
    }
    #endif
}
