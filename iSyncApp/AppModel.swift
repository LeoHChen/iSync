import Foundation
import iSyncCore

enum SidebarItem: Hashable {
    case photos(String)
    case music(String)
    case files(String)
    case addToIPhone(String)

    var udid: String {
        switch self {
        case .photos(let u), .music(let u), .files(let u), .addToIPhone(let u): return u
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var devices: [DeviceModel] = []
    @Published var selection: SidebarItem?
    /// A message that outlasts the phone it's about, such as one unplugged during a copy.
    @Published var notice: String?

    private var watcher: DeviceWatcher?

    func start() {
        guard watcher == nil else { return }
        let w = DeviceWatcher { [weak self] udids in
            Task { @MainActor in self?.update(connected: udids) }
        }
        watcher = w
        w.start()
    }

    private func update(connected udids: [String]) {
        for device in devices where !udids.contains(device.udid) {
            if device.photos.isCopying || device.music.isCopying {
                notice = "\(device.displayName) was unplugged during a copy. Finished files are saved. Plug it back in to continue."
            }
            device.stop()
        }
        devices.removeAll { !udids.contains($0.udid) }
        for udid in udids where !devices.contains(where: { $0.udid == udid }) {
            let device = DeviceModel(udid: udid)
            devices.append(device)
            device.start()
        }
        if let selected = selection, !udids.contains(selected.udid) { selection = nil }
        if selection == nil, let first = devices.first {
            selection = .photos(first.udid)
        }
    }

    func device(_ udid: String) -> DeviceModel? {
        devices.first { $0.udid == udid }
    }
}
