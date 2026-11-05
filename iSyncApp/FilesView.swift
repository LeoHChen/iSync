import iSyncCore
import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @ObservedObject var model: FilesModel
    @State private var isDropTarget = false
    @State private var pendingDelete: [DocumentEntry] = []
    @State private var showDeleteConfirmation = false

    var body: some View {
        HSplitView {
            appList
                .frame(minWidth: 170, idealWidth: 200, maxWidth: 280)
            folderPane
                .frame(minWidth: 400)
        }
        .onAppear { model.loadApps() }
        .confirmationDialog(deleteTitle, isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete from iPhone", role: .destructive) {
                model.deleteConfirmed(pendingDelete)
                pendingDelete = []
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("This permanently deletes it from your iPhone and can't be undone.")
        }
    }

    private var deleteTitle: String {
        if pendingDelete.count == 1 { return "Delete “\(pendingDelete[0].name)”?" }
        return "Delete \(pendingDelete.count) items?"
    }

    private func askToDelete(_ items: [DocumentEntry]) {
        guard !items.isEmpty else { return }
        pendingDelete = items
        showDeleteConfirmation = true
    }

    private var appSelection: Binding<String?> {
        Binding(
            get: { model.selectedApp?.id },
            set: { id in
                if let app = model.apps.first(where: { $0.id == id }) { model.select(app) }
            })
    }

    private var appList: some View {
        List(model.apps, selection: appSelection) { app in
            Label(app.name, systemImage: "app").tag(app.id)
        }
        .overlay {
            if model.loadingApps {
                ProgressView("Loading apps…")
            } else if model.apps.isEmpty {
                Text("No apps with file sharing").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var folderPane: some View {
        if model.selectedApp == nil {
            ContentUnavailableView(
                "Choose an app", systemImage: "folder",
                description: Text("These apps allow file sharing. Their Documents folders appear here."))
        } else {
            VStack(spacing: 0) {
                toolbar
                Divider()
                table
                if let transfer = model.transfer {
                    Divider()
                    TransferBar(transfer: transfer) { model.cancelTransfer() }
                }
                if let error = model.errorMessage {
                    Divider()
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Dismiss") { model.errorMessage = nil }
                    }
                    .padding(10)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: handleDrop)
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Button { model.goUp() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoUp || model.loading)
                .accessibilityLabel("Back")
                .help("Back")
            Text(model.pathComponents.joined(separator: " › "))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.loading)
                .accessibilityLabel("Refresh")
                .help("Refresh")
            Button("Add Files…") { model.chooseFilesToAdd() }
                .disabled(model.transfer != nil)
            Button("Save to Mac…") { model.saveSelectionToMac() }
                .disabled(model.selection.isEmpty || model.transfer != nil)
            Button("Delete…") { askToDelete(model.selectedEntries) }
                .disabled(model.selection.isEmpty || model.transfer != nil)
        }
        .padding(10)
    }

    private var table: some View {
        Table(of: DocumentEntry.self, selection: $model.selection) {
            TableColumn("Name") { (entry: DocumentEntry) in
                Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                    .lineLimit(1).truncationMode(.middle)
            }
            TableColumn("Size") { (entry: DocumentEntry) in
                Text(entry.isDirectory ? "" : Format.bytes(entry.size)).monospacedDigit()
            }
            .width(min: 60, ideal: 80, max: 110)
            TableColumn("Modified") { (entry: DocumentEntry) in
                Text(entry.modified.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 120, ideal: 160, max: 200)
        } rows: {
            ForEach(model.entries) { entry in
                TableRow(entry).itemProvider { model.dragProvider(for: entry) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let items = model.entries.filter { ids.contains($0.id) }
            if items.count == 1, items[0].isDirectory {
                Button("Open") { model.open(path: items[0].path) }
            }
            if !items.isEmpty {
                Button("Save to Mac…") {
                    model.selection = ids
                    model.saveSelectionToMac()
                }
                Divider()
                Button("Delete…", role: .destructive) { askToDelete(items) }
            }
        } primaryAction: { ids in
            if ids.count == 1, let entry = model.entries.first(where: { ids.contains($0.id) }), entry.isDirectory {
                model.open(path: entry.path)
            }
        }
        .overlay {
            if model.loading && model.entries.isEmpty {
                ProgressView()
            } else if !model.loading && model.entries.isEmpty && model.errorMessage == nil {
                ContentUnavailableView(
                    "This folder is empty", systemImage: "tray.and.arrow.down",
                    description: Text("Drag files here to add them to your iPhone."))
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in matching {
                let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                    _ = provider.loadObject(ofClass: URL.self) { value, _ in continuation.resume(returning: value) }
                }
                if let url { urls.append(url) }
            }
            model.upload(urls)
        }
        return true
    }
}

private struct TransferBar: View {
    let transfer: FilesModel.Transfer
    let cancel: () -> Void

    var body: some View {
        HStack {
            Text(transfer.title)
            ProgressView(value: transfer.fraction)
            Text("\(Format.bytes(transfer.done)) of \(Format.bytes(transfer.total))")
                .monospacedDigit().foregroundStyle(.secondary)
            Button("Cancel", action: cancel)
        }
        .padding(10)
    }
}
