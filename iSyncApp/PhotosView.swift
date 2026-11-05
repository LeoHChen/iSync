import iSyncCore
import SwiftUI

struct PhotosView: View {
    @ObservedObject var model: PhotosModel
    @ObservedObject var device: DeviceModel
    @EnvironmentObject private var app: AppModel
    @State private var confirmOverwrite = false

    var body: some View {
        Form {
            Section {
                previewArea
            } header: {
                Text("Copy originals to this Mac, with no conversion")
            }

            Section("Destination") {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.destination.path)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Change…") { model.chooseDestination() }
                            .disabled(model.isBusy)
                        Button("Show in Finder") { model.showDestination() }
                            .disabled(!FileManager.default.fileExists(atPath: model.destination.path))
                    }
                }
                Picker("Organize", selection: $model.layout) {
                    Text("Same folders as the iPhone").tag(FolderLayout.sameAsIPhone)
                    Text("Year and month").tag(FolderLayout.yearMonth)
                }
                .disabled(model.isBusy)
                ConflictPolicyPicker(policy: $model.policy, disabled: model.isBusy)
            }

            Section("Duplicates") {
                Toggle("Copy possible duplicates", isOn: $model.copyPossibleDuplicates)
                    .disabled(model.isBusy)
                ReferenceFolders(model: model)
            }

            Section {
                actionArea
            }

            if let result = model.lastResult {
                Section("Last copy") { CopyResultView(result: result) }
            }

            Section("Another iPhone") {
                OtherPhoneSection(model: model, others: app.devices.filter { $0.udid != device.udid && $0.status == .ready })
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadIfNeeded() }
        .confirmationDialog(overwriteTitle, isPresented: $confirmOverwrite, titleVisibility: .visible) {
            Button("Replace and Copy", role: .destructive) { model.startCopy() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copies from your iPhone replace the files at the same paths in this folder. This can't be undone.")
        }
    }

    private var overwriteTitle: String {
        let n = model.plan?.replaceFiles ?? 0
        return "Replace \(n.formatted()) \(n == 1 ? "file" : "files")?"
    }

    @ViewBuilder
    private var previewArea: some View {
        switch model.phase {
        case .notLoaded, .scanning:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(scanningText)
            }
        case .ready, .verifying, .copying:
            if let preview = model.preview {
                PreviewTable(preview: preview, policy: model.policy, copyPossible: model.copyPossibleDuplicates)
                if model.isPlanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.planningStatus).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.planningStatus.isEmpty ? "Checking what's already there…" : model.planningStatus)
                }
            }
        }
    }

    private var scanningText: String {
        if case .scanning(let done, let total) = model.phase, total > 0 {
            return "Reading the iPhone's photos: \(done.formatted()) of \(total.formatted())"
        }
        return "Reading the iPhone's photos…"
    }

    @ViewBuilder
    private var actionArea: some View {
        if let message = model.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            Button("Try Again") { model.rescan() }
        } else if model.isCopying {
            CopyProgressSection(
                progress: model.progress, pause: model.pause, resume: model.resume, cancel: model.cancel)
        } else if model.phase == .verifying {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(model.verifiedBytes), total: Double(max(model.verifyTotalBytes, 1)))
                HStack {
                    Text("Comparing likely duplicates with SHA-256: \(Format.bytes(model.verifiedBytes)) of \(Format.bytes(model.verifyTotalBytes))")
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel") { model.cancelVerify() }
                }
            }
        } else if model.phase == .ready, let preview = model.preview {
            readyArea(preview)
        } else {
            Text("Waiting for the iPhone's photo list.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func readyArea(_ preview: SyncPreview) -> some View {
        let plan = preview.plan
        VStack(alignment: .leading, spacing: 10) {
            if plan.toCopyFiles == 0 && !preview.needsVerification {
                Label("Nothing new to copy to this folder.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack {
                    Button(buttonTitle(preview)) {
                        if plan.replaceFiles > 0 { confirmOverwrite = true } else { model.startCopy() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPlanning || model.notEnoughSpace)
                    Text(detail(plan)).foregroundStyle(.secondary)
                }
                if preview.needsVerification {
                    Text("First, \(preview.unconfirmed.count.formatted()) likely duplicates (\(Format.bytes(preview.unconfirmedBytes))) get compared with SHA-256. Each file is only ever hashed once.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if model.notEnoughSpace, let free = model.freeSpace, let plan = model.plan {
                Label(
                    "This folder's disk has \(Format.bytes(free)) free, but the copy needs \(Format.bytes(plan.toCopyBytes)). Choose another folder or free up space.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.red)
            }
            if let notice = model.notice {
                Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            if device.isUSB2 {
                Label(
                    "Connected at USB 2 speed (\(device.linkSpeed ?? "480 Mb/s")), which limits copies to about 43 MB/s. A 10 Gb/s USB-C cable may be faster, if your iPhone supports it.",
                    systemImage: "cable.connector"
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Rescan iPhone") { model.rescan() }
            }
        }
    }

    private func buttonTitle(_ preview: SyncPreview) -> String {
        let n = preview.plan.toCopyFiles
        if n == 0 { return "Check Duplicates" }
        return "Copy \(n.formatted()) \(n == 1 ? "File" : "Files")"
    }

    private func detail(_ plan: CopyPlan) -> String {
        var parts = [Format.bytes(plan.toCopyBytes)]
        if plan.replaceFiles > 0 { parts.append("replaces \(plan.replaceFiles.formatted())") }
        if plan.livePhotosToCopy > 0 { parts.append("\(plan.livePhotosToCopy.formatted()) Live Photos stay together") }
        return parts.joined(separator: ", ")
    }
}

/// The dry run's result: every file is in exactly one row.
private struct PreviewTable: View {
    let preview: SyncPreview
    let policy: ConflictPolicy
    let copyPossible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On iPhone: \(preview.total.files.formatted()) files, \(Format.bytes(preview.total.bytes))")
                .font(.headline).monospacedDigit()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(rows, id: \.title) { row in
                    GridRow {
                        Text(row.title)
                        Text(row.tally.files.formatted()).monospacedDigit().gridColumnAlignment(.trailing)
                        Text(Format.bytes(row.tally.bytes)).monospacedDigit().gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                        Text(row.action).foregroundStyle(.secondary)
                    }
                }
            }
            if !preview.possibleDuplicates.isEmpty {
                DisclosureGroup("Show \(preview.possibleDuplicates.count.formatted()) possible duplicates") {
                    ForEach(preview.possibleDuplicates.prefix(100), id: \.self) { item in
                        VStack(alignment: .leading) {
                            Text((item.file.path as NSString).lastPathComponent).font(.callout)
                            Text("Same capture time and dimensions as \(item.similarTo)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if preview.possibleDuplicates.count > 100 {
                        Text("And \((preview.possibleDuplicates.count - 100).formatted()) more.").font(.caption)
                    }
                }
            }
        }
    }

    private struct Row {
        let title: String
        let tally: SyncTally
        let action: String
    }

    private var rows: [Row] {
        var out = [Row(title: "New", tally: preview.tally(.new), action: "Copied")]
        let recopy = policy == .overwrite
        func add(_ c: SyncCategory, _ title: String, _ action: String) {
            if preview.tally(c).files > 0 { out.append(Row(title: title, tally: preview.tally(c), action: action)) }
        }
        add(.alreadyCopied, "Already copied", recopy ? "Copied again, replacing the file" : "Skipped")
        add(.exactDuplicate, "Exact duplicates", preview.needsVerification ? "Skipped once SHA-256 confirms" : "Skipped")
        add(.sameNameDifferent, "Same name, different content", recopy ? "Replaces the existing file" : "Copied with a number added to its name")
        add(.possibleDuplicate, "Possible duplicates", copyPossible ? "Copied, and listed below" : "Not copied, and listed below")
        return out
    }
}

private struct ReferenceFolders: View {
    @ObservedObject var model: PhotosModel

    var body: some View {
        LabeledContent {
            Button("Add Folder…") { model.addReferenceFolders() }
                .disabled(model.isBusy)
        } label: {
            Text("Also check these Mac folders")
            Text("Files found here aren't copied again. iSync only reads these folders.")
        }
        ForEach(model.referenceFolders, id: \.self) { folder in
            HStack {
                Label(folder.path, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Remove") { model.removeReferenceFolder(folder) }
                    .disabled(model.isBusy)
            }
        }
    }
}

private struct OtherPhoneSection: View {
    @ObservedObject var model: PhotosModel
    let others: [DeviceModel]

    var body: some View {
        if others.isEmpty {
            Text("Plug in your other iPhone to see which of these photos it already has.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(others) { other in
                HStack {
                    Text("Compare with \(other.displayName)")
                    Spacer()
                    Button(model.isComparing ? "Comparing…" : "Compare") { model.compare(with: other) }
                        .disabled(model.isComparing || model.phase == .notLoaded)
                }
            }
        }
        if let error = model.comparisonError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        if let comparison = model.comparison {
            let r = comparison.result
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Already on \(comparison.otherName)", r.alreadyOnDestination)
                row("Possible duplicates", r.possibleDuplicates)
                row("Not on \(comparison.otherName)", r.new)
            }
            Text("From each phone's photo details, so nothing was changed. SHA-256 would confirm these before any transfer. Copying to an iPhone isn't available yet.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ tally: SyncTally) -> some View {
        GridRow {
            Text(title)
            Text(tally.files.formatted()).monospacedDigit().gridColumnAlignment(.trailing)
            Text(Format.bytes(tally.bytes)).monospacedDigit().gridColumnAlignment(.trailing).foregroundStyle(.secondary)
        }
    }
}
