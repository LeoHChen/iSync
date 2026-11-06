import AppKit
import Foundation
import iSyncCore

@MainActor
final class MusicModel: ObservableObject {
    enum Phase: Equatable {
        case notLoaded
        case loading
        case ready
        case copying
    }

    @Published private(set) var phase: Phase = .notLoaded
    @Published private(set) var tracks: [MusicTrack] = []
    @Published private(set) var summary: MusicSummary?
    @Published private(set) var preview: MusicPlanner.Preview?
    @Published private(set) var progress = PhotoCopyEngine.Progress()
    @Published private(set) var lastResult: PhotoCopyEngine.Result?
    @Published private(set) var errorMessage: String?
    @Published private(set) var freeSpace: Int64?
    @Published private(set) var destination: URL
    @Published var policy: ConflictPolicy {
        didSet {
            guard policy != oldValue else { return }
            UserDefaults.standard.set(policy.rawValue, forKey: "musicPolicy-\(key)")
            replan()
        }
    }

    private unowned let device: DeviceModel
    private let key: String
    private var engine: PhotoCopyEngine?
    private var planGeneration = 0

    init(device: DeviceModel) {
        self.device = device
        let phoneKey = deviceKey(udid: device.udid)
        key = phoneKey + "-music"
        let defaults = UserDefaults.standard
        policy = defaults.string(forKey: "musicPolicy-\(key)").flatMap(ConflictPolicy.init(rawValue:)) ?? .skipDuplicates
        if let saved = defaults.string(forKey: "musicDestination-\(key)") {
            destination = URL(fileURLWithPath: saved)
        } else {
            let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            let folder = (device.summary?.name ?? "iPhone")
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            destination = music.appendingPathComponent("iSync").appendingPathComponent(folder)
        }
    }

    var isCopying: Bool { phase == .copying }

    var notEnoughSpace: Bool {
        guard let preview, let freeSpace else { return false }
        return preview.plan.toCopyBytes > freeSpace
    }

    func loadIfNeeded() {
        if phase == .notLoaded { reload() }
    }

    func reload() {
        guard phase != .copying else { return }
        phase = .loading
        errorMessage = nil
        let udid = device.udid
        Task {
            do {
                let found = try await Task.detached { try MusicLibrary.fetch(udid: udid) }.value
                #if DEBUG
                if let limit = debugLimit {
                    tracks = Array(found.filter { $0.status == .copyable }.prefix(limit))
                } else {
                    tracks = found
                }
                #else
                tracks = found
                #endif
                summary = MusicSummary(tracks)
                phase = .ready
                replan()
            } catch {
                errorMessage = "Couldn't read the iPhone's music: \(error.localizedDescription)"
                phase = .notLoaded
            }
        }
    }

    func replan() {
        planGeneration += 1
        let generation = planGeneration
        let tracks = tracks, destination = destination, key = key, policy = policy
        Task {
            let (result, free) = await Task.detached { () -> (MusicPlanner.Preview, Int64?) in
                let manifest = CopyManifest.load(destination: destination, deviceKey: key)
                let plan = MusicPlanner.plan(tracks: tracks, destination: destination, manifest: manifest, policy: policy)
                var u = destination
                while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u.deleteLastPathComponent() }
                let free = (try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage
                return (plan, free)
            }.value
            guard generation == planGeneration else { return }
            preview = result
            freeSpace = free
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where to copy music."
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
        UserDefaults.standard.set(url.path, forKey: "musicDestination-\(key)")
        lastResult = nil
        replan()
    }

    func showDestination() {
        if FileManager.default.fileExists(atPath: destination.path) {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    func startCopy() {
        guard let plan = preview?.plan, plan.toCopyFiles > 0, phase == .ready else { return }
        lastResult = nil
        var start = PhotoCopyEngine.Progress()
        start.totalFiles = plan.toCopyFiles
        start.totalBytes = plan.toCopyBytes
        progress = start
        phase = .copying
        let udid = device.udid
        let engine = PhotoCopyEngine(
            plan: plan, destination: destination, manifest: CopyManifest.load(destination: destination, deviceKey: key),
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
                    self?.lastResult = result
                    self?.engine = nil
                    self?.phase = .ready
                    self?.replan()
                }
            })
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
