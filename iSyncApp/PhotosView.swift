import iSyncCore
import SwiftUI

struct PhotosView: View {
    @ObservedObject var model: PhotosModel
    @ObservedObject var device: DeviceModel

    var body: some View {
        Form {
            Section {
                summary
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
                            .disabled(model.isCopying)
                        Button("Show in Finder") { model.showDestination() }
                            .disabled(!FileManager.default.fileExists(atPath: model.destination.path))
                    }
                }
                Picker("Organize", selection: $model.layout) {
                    Text("Same folders as the iPhone").tag(FolderLayout.sameAsIPhone)
                    Text("Year and month").tag(FolderLayout.yearMonth)
                }
                .disabled(model.isCopying)
            }

            Section {
                actionArea
            }

            if let result = model.lastResult {
                Section("Last copy") { ResultView(result: result) }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadIfNeeded() }
    }

    @ViewBuilder
    private var summary: some View {
        switch model.phase {
        case .notLoaded, .scanning:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(scanningText)
            }
        case .ready, .copying:
            if let plan = model.plan {
                HStack(alignment: .top) {
                    Stat(title: "On iPhone", files: plan.totalFiles, bytes: plan.totalBytes)
                    Stat(title: "Already copied", files: plan.alreadyCopiedFiles, bytes: plan.alreadyCopiedBytes)
                    Stat(title: "To copy", files: plan.toCopyFiles, bytes: plan.toCopyBytes)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking what's already copied…")
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
            CopyProgressView(model: model)
        } else if model.phase == .ready, let plan = model.plan {
            VStack(alignment: .leading, spacing: 10) {
                if plan.toCopyFiles == 0 {
                    Label("Everything on this iPhone is already copied to this folder.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Button("Copy \(plan.toCopyFiles.formatted()) Files") { model.startCopy() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isPlanning || model.notEnoughSpace)
                        Text(estimate(plan)).foregroundStyle(.secondary)
                    }
                }
                if model.notEnoughSpace, let free = model.freeSpace {
                    Label(
                        "This folder's disk has \(Format.bytes(free)) free, but the copy needs \(Format.bytes(plan.toCopyBytes)). Choose another folder or free up space.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
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
        } else {
            Text("Waiting for the iPhone's photo list.").foregroundStyle(.secondary)
        }
    }

    private func estimate(_ plan: CopyPlan) -> String {
        var parts = [Format.bytes(plan.toCopyBytes)]
        if plan.livePhotosToCopy > 0 { parts.append("\(plan.livePhotosToCopy.formatted()) Live Photos stay together") }
        return parts.joined(separator: ", ")
    }
}

private struct Stat: View {
    let title: String
    let files: Int
    let bytes: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(files.formatted()) files").font(.title3).monospacedDigit()
            Text(Format.bytes(bytes)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CopyProgressView: View {
    @ObservedObject var model: PhotosModel

    var body: some View {
        let p = model.progress
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: p.fraction)
            HStack {
                Text("\(p.copiedFiles.formatted()) of \(p.totalFiles.formatted()) files, \(Format.bytes(p.copiedBytes)) of \(Format.bytes(p.totalBytes))")
                    .monospacedDigit()
                Spacer()
                Text(speedText(p)).foregroundStyle(.secondary).monospacedDigit()
            }
            if p.failedFiles > 0 {
                Label("\(p.failedFiles.formatted()) files couldn't be copied so far", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                if model.isPaused {
                    Button("Resume") { model.resume() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Pause") { model.pause() }
                }
                Button("Cancel") { model.cancel() }
                Spacer()
                Text("Finished files are kept if you cancel.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func speedText(_ p: PhotoCopyEngine.Progress) -> String {
        if p.isPaused { return "Paused" }
        guard p.bytesPerSecond > 0 else { return "Starting…" }
        var text = Format.speed(p.bytesPerSecond)
        if let left = p.secondsRemaining { text += ", about \(Format.duration(left)) left" }
        return text
    }
}

private struct ResultView: View {
    let result: PhotoCopyEngine.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = result.stopReason {
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if result.wasCancelled {
                Label("Copy cancelled. Finished files are kept and won't be copied again.", systemImage: "xmark.circle")
            }
            Text(summary).monospacedDigit()
            if !result.failures.isEmpty {
                DisclosureGroup("\(result.failures.count.formatted()) files couldn't be copied") {
                    ForEach(result.failures.prefix(50), id: \.path) { failure in
                        VStack(alignment: .leading) {
                            Text(failure.path).font(.callout)
                            Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if result.failures.count > 50 {
                        Text("And \((result.failures.count - 50).formatted()) more.").font(.caption)
                    }
                }
            }
        }
    }

    private var summary: String {
        var text = "Copied \(result.copiedFiles.formatted()) files, \(Format.bytes(result.copiedBytes))"
        if result.copiedBytes > 0 {
            text += ", in \(Format.duration(result.seconds)) at \(Format.speed(result.averageBytesPerSecond))"
        }
        return text + "."
    }
}
