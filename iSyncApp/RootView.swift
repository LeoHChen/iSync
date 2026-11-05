import iSyncCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                if let notice = model.notice {
                    NoticeBar(text: notice) { model.notice = nil }
                }
                DetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("iSync")
        .onAppear { DebugSnapshot.scheduleIfRequested(model) }
    }
}

private struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(10)
        .background(.bar)
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.devices) { device in
                DeviceSection(device: device)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.devices.isEmpty {
                Text("No iPhone connected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeviceSection: View {
    @ObservedObject var device: DeviceModel

    var body: some View {
        Section {
            DeviceCard(device: device)
                .selectionDisabled()
                .padding(.vertical, 4)
            if device.status == .ready {
                Label("Photos", systemImage: "photo.on.rectangle").tag(SidebarItem.photos(device.udid))
                Label("Files", systemImage: "folder").tag(SidebarItem.files(device.udid))
                Label("Add to iPhone", systemImage: "plus.rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
                    .tag(SidebarItem.addToIPhone(device.udid))
            }
        }
    }
}

private struct DeviceCard: View {
    @ObservedObject var device: DeviceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(device.displayName, systemImage: "iphone").font(.headline)
            if let s = device.summary {
                Text("\(s.modelName), iOS \(s.iosVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                if let used = s.storageUsed, let total = s.storageTotal, let free = s.storageFree, total > 0 {
                    ProgressView(value: Double(used), total: Double(total))
                        .controlSize(.small)
                        .accessibilityLabel("Storage used")
                    Text("\(Format.bytes(used)) used, \(Format.bytes(free)) free")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let percent = s.batteryPercent {
                    Label(
                        s.isCharging == true ? "\(percent)%, charging" : "\(percent)%",
                        systemImage: s.isCharging == true ? "battery.100.bolt" : batteryIcon(percent)
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusLine: String {
        switch device.status {
        case .checking, .ready: return "Connecting…"
        case .needsUnlock: return "Unlock your iPhone"
        case .waitingForTrust: return "Tap Trust on your iPhone"
        case .denied: return "Not trusted"
        case .failed: return "Can't connect"
        }
    }

    private func batteryIcon(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

private struct DetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let item = model.selection, let device = model.device(item.udid) {
            DeviceDetail(device: device, item: item)
        } else if let device = model.devices.first {
            DeviceDetail(device: device, item: .photos(device.udid))
        } else {
            ContentUnavailableView(
                "Connect your iPhone", systemImage: "iphone",
                description: Text("Plug it into this Mac with a USB cable and unlock it."))
        }
    }
}

private struct DeviceDetail: View {
    @ObservedObject var device: DeviceModel
    let item: SidebarItem

    var body: some View {
        switch device.status {
        case .ready:
            switch item {
            case .photos: PhotosView(model: device.photos, device: device)
            case .files: FilesView(model: device.files)
            case .addToIPhone: AddToIPhoneView()
            }
        case .checking:
            ProgressView("Connecting to your iPhone…")
        case .needsUnlock:
            ContentUnavailableView(
                "Unlock your iPhone", systemImage: "lock.iphone",
                description: Text("iSync can't connect until it's unlocked."))
        case .waitingForTrust:
            ContentUnavailableView(
                "Tap Trust on your iPhone", systemImage: "hand.tap",
                description: Text("Then enter your passcode if it asks."))
        case .denied:
            ContentUnavailableView(
                "Your iPhone doesn't trust this Mac", systemImage: "xmark.shield",
                description: Text("Unplug it, plug it back in, and tap Trust."))
        case .failed(let why):
            ContentUnavailableView(
                "Can't connect to your iPhone", systemImage: "exclamationmark.triangle",
                description: Text("\(why)\nTry unplugging it and plugging it back in."))
        }
    }
}

/// Stands in for a feature that depends on the T4 and T5 sync tests.
private struct AddToIPhoneView: View {
    var body: some View {
        ContentUnavailableView(
            "Not available yet", systemImage: "plus.rectangle.on.rectangle",
            description: Text("Adding photos and music to your iPhone isn't in this version. It depends on a sync test that hasn't run yet."))
    }
}
