import AppKit
import Foundation
import iSyncCore
import UniformTypeIdentifiers

@MainActor
final class FilesModel: ObservableObject {
    struct Transfer: Equatable {
        var title: String
        var done: Int64 = 0
        var total: Int64
        var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    }

    @Published private(set) var apps: [SharedApp] = []
    @Published private(set) var loadingApps = false
    @Published private(set) var selectedApp: SharedApp?
    @Published private(set) var path = AppDocumentsSession.rootPath
    @Published private(set) var entries: [DocumentEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var transfer: Transfer?
    @Published var errorMessage: String?
    @Published var selection = Set<String>()

    private let udid: String
    /// libimobiledevice clients are used from one thread at a time.
    private let queue = DispatchQueue(label: "isync.files")
    private nonisolated(unsafe) var session: AppDocumentsSession?
    private var control: TransferControl?

    init(udid: String) { self.udid = udid }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func loadApps() {
        guard apps.isEmpty, !loadingApps else { return }
        loadingApps = true
        let udid = udid
        Task {
            do {
                apps = try await Task.detached { try SharedApps.list(udid: udid) }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            loadingApps = false
        }
    }

    func select(_ app: SharedApp) {
        guard app != selectedApp else { return }
        selectedApp = app
        path = AppDocumentsSession.rootPath
        entries = []
        selection = []
        errorMessage = nil
        loading = true
        let udid = udid, bundleID = app.bundleID, root = path
        Task {
            do {
                let list = try await onQueue { [self] in
                    session = nil
                    let s = try AppDocumentsSession(udid: udid, bundleID: bundleID)
                    session = s
                    return try s.list(root)
                }
                guard selectedApp == app else { return }
                entries = list
            } catch {
                errorMessage = error.localizedDescription
            }
            loading = false
        }
    }

    func close() {
        control?.cancel()
        queue.async { [self] in session = nil }
    }

    func refresh() { open(path: path) }

    func open(path newPath: String) {
        loading = true
        errorMessage = nil
        Task {
            do {
                let list = try await onQueue { [self] in
                    guard let session else { throw ISyncError("Choose an app first.") }
                    return try session.list(newPath)
                }
                path = newPath
                entries = list
                selection = selection.filter { id in list.contains { $0.id == id } }
            } catch {
                errorMessage = error.localizedDescription
            }
            loading = false
        }
    }

    var canGoUp: Bool { path != AppDocumentsSession.rootPath }

    func goUp() { open(path: (path as NSString).deletingLastPathComponent) }

    var selectedEntries: [DocumentEntry] { entries.filter { selection.contains($0.id) } }

    /// Shows the current folder relative to the app's Documents.
    var pathComponents: [String] {
        path.split(separator: "/").map(String.init)
    }

    func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose files to add to \(selectedApp?.name ?? "this app") on your iPhone."
        guard panel.runModal() == .OK else { return }
        upload(panel.urls)
    }

    func upload(_ urls: [URL]) {
        guard selectedApp != nil, transfer == nil, !urls.isEmpty else { return }
        let total = urls.reduce(Int64(0)) { $0 + AppDocumentsSession.localSize($1) }
        let target = path
        let control = TransferControl()
        self.control = control
        transfer = Transfer(title: "Adding to your iPhone", total: total)
        errorMessage = nil
        Task {
            let problems = await run(urls, control: control) { [self] url, onBytes in
                guard let session else { throw ISyncError("This app's files are no longer open.") }
                try session.upload(url, into: target, control: control, onBytes: onBytes)
            }
            finishTransfer(problems)
        }
    }

    func saveSelectionToMac() {
        let items = selectedEntries
        guard !items.isEmpty, transfer == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save \(items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items") on this Mac."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let control = TransferControl()
        self.control = control
        transfer = Transfer(title: "Saving to this Mac", total: 0)
        errorMessage = nil
        Task {
            // Folder sizes come from the phone, so work them out first.
            let total: Int64 = (try? await onQueue { [self] () throws -> Int64 in
                guard let session else { return 0 }
                var sum: Int64 = 0
                for item in items { sum += try session.remoteSize(item) }
                return sum
            }) ?? 0
            transfer?.total = total
            let problems = await run(items, control: control) { [self] entry, onBytes in
                guard let session else { throw ISyncError("This app's files are no longer open.") }
                try session.download(entry, into: folder, control: control, onBytes: onBytes)
            }
            finishTransfer(problems)
            if problems.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
    }

    /// Permanently deletes from the iPhone. The view asks for confirmation first.
    func deleteConfirmed(_ items: [DocumentEntry]) {
        guard transfer == nil, !items.isEmpty else { return }
        errorMessage = nil
        loading = true
        Task {
            do {
                try await onQueue { [self] in
                    guard let session else { throw ISyncError("This app's files are no longer open.") }
                    for item in items { try session.delete(item) }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            selection = []
            loading = false
            refresh()
        }
    }

    /// Runs items one at a time and collects problems. One failure doesn't stop the rest.
    private func run<Item: Sendable>(
        _ items: [Item], control: TransferControl,
        _ work: @escaping @Sendable (Item, (Int) -> Void) throws -> Void
    ) async -> [String] {
        let progress: @Sendable (Int) -> Void = { [weak self] n in
            Task { @MainActor in self?.transfer?.done += Int64(n) }
        }
        var problems: [String] = []
        for item in items {
            do {
                try await onQueue { try work(item, progress) }
            } catch {
                if control.isCancelled { break }
                problems.append(error.localizedDescription)
            }
        }
        return problems
    }

    private func finishTransfer(_ problems: [String]) {
        transfer = nil
        control = nil
        if !problems.isEmpty { errorMessage = problems.joined(separator: "\n") }
        refresh()
    }

    func cancelTransfer() { control?.cancel() }

    /// Lets a row be dragged to Finder. The file is fetched when it's dropped.
    func dragProvider(for entry: DocumentEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = entry.name
        let type: UTType = entry.isDirectory ? .folder : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
        let queue = queue
        let box = SessionBox(model: self)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            queue.async {
                do {
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("iSync-drag/\(UUID().uuidString)")
                    guard let session = box.model?.session else { throw ISyncError("This app's files are no longer open.") }
                    let url = try session.download(entry, into: dir, control: TransferControl()) { _ in }
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}

private final class SessionBox: @unchecked Sendable {
    weak var model: FilesModel?
    init(model: FilesModel) { self.model = model }
}
