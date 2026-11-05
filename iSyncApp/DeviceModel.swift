import Foundation
import iSyncCore

@MainActor
final class DeviceModel: ObservableObject, Identifiable {
    enum Status: Equatable {
        case checking
        case needsUnlock
        case waitingForTrust
        case denied
        case failed(String)
        case ready
    }

    nonisolated let udid: String
    nonisolated var id: String { udid }
    @Published private(set) var status: Status = .checking
    @Published private(set) var summary: DeviceSummary?
    @Published private(set) var linkSpeed: String?

    private(set) lazy var photos = PhotosModel(device: self)
    private(set) lazy var files = FilesModel(udid: udid)
    private var loop: Task<Void, Never>?

    init(udid: String) { self.udid = udid }

    var displayName: String { summary?.name ?? "iPhone" }

    /// True when the link came up at USB 2, which caps copies at about 43 MB/s.
    var isUSB2: Bool { linkSpeed?.contains("480") == true }

    func start() {
        guard loop == nil else { return }
        let udid = udid
        loop = Task { [weak self] in
            // Keep checking until the phone is trusted, so the prompts clear by themselves.
            while !Task.isCancelled {
                let pairing = await Task.detached { DevicePairing.check(udid: udid) }.value
                guard let self else { return }
                switch pairing {
                case .paired: break
                case .needsUnlock: self.status = .needsUnlock
                case .waitingForTrust: self.status = .waitingForTrust
                case .denied: self.status = .denied
                case .failed(let why): self.status = .failed(why)
                }
                if pairing == .paired { break }
                try? await Task.sleep(for: .seconds(2))
            }
            guard let self, !Task.isCancelled else { return }
            // Read the name before showing pages, because it names the default folder.
            self.summary = await Task.detached(operation: { try? DeviceInfo.read(udid: udid) }).value
            self.status = .ready
            self.linkSpeed = await Task.detached { DeviceInfo.usbLinkSpeed(udid: udid) }.value
            // Storage and battery change over time.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if let s = await Task.detached(operation: { try? DeviceInfo.read(udid: udid) }).value {
                    self.summary = s
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        files.close()
    }
}
