import iSyncCore
import SwiftUI

struct MusicView: View {
    @ObservedObject var model: MusicModel
    @State private var confirmOverwrite = false

    var body: some View {
        VStack(spacing: 0) {
            controls
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            trackTable
        }
        .onAppear { model.loadIfNeeded() }
        .confirmationDialog(overwriteTitle, isPresented: $confirmOverwrite, titleVisibility: .visible) {
            Button("Replace and Copy", role: .destructive) { model.startCopy() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copies from your iPhone replace the files at the same paths in this folder. This can't be undone.")
        }
    }

    private var overwriteTitle: String {
        let n = model.preview?.plan.replaceFiles ?? 0
        return "Replace \(n.formatted()) \(n == 1 ? "file" : "files")?"
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryLine
            HStack {
                Text("Folder")
                Text(model.destination.path)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("Change…") { model.chooseDestination() }
                    .disabled(model.isCopying)
                Button("Show in Finder") { model.showDestination() }
                    .disabled(!FileManager.default.fileExists(atPath: model.destination.path))
            }
            ConflictPolicyPicker(policy: $model.policy, disabled: model.isCopying)
            actionArea
            if let result = model.lastResult { CopyResultView(result: result) }
        }
        .padding(16)
    }

    @ViewBuilder
    private var summaryLine: some View {
        if let s = model.summary {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(s.copyable.formatted()) tracks on this iPhone, \(Format.bytes(s.copyableBytes))")
                    .font(.headline).monospacedDigit()
                Text(detailLine(s)).font(.callout).foregroundStyle(.secondary)
            }
        } else if model.phase == .loading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the iPhone's music library…")
            }
        }
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            Button("Try Again") { model.reload() }
        }
    }

    private func detailLine(_ s: MusicSummary) -> String {
        var parts: [String] = []
        parts.append(s.protected == 0 ? "None are copy-protected" : "\(s.protected.formatted()) are copy-protected and can't be copied")
        if s.notOnIPhone > 0 { parts.append("\(s.notOnIPhone.formatted()) aren't stored on this iPhone") }
        return parts.joined(separator: ". ") + "."
    }

    @ViewBuilder
    private var actionArea: some View {
        if model.isCopying {
            CopyProgressSection(progress: model.progress, pause: model.pause, resume: model.resume, cancel: model.cancel)
        } else if let preview = model.preview {
            let plan = preview.plan
            VStack(alignment: .leading, spacing: 6) {
                if plan.toCopyFiles == 0 {
                    Label("Nothing new to copy to this folder.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Button("Copy \(plan.toCopyFiles.formatted()) \(plan.toCopyFiles == 1 ? "Track" : "Tracks")") {
                            if plan.replaceFiles > 0 { confirmOverwrite = true } else { model.startCopy() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.notEnoughSpace)
                        Text(previewDetail(preview)).foregroundStyle(.secondary)
                    }
                }
                if model.notEnoughSpace, let free = model.freeSpace {
                    Label(
                        "This folder's disk has \(Format.bytes(free)) free, but the copy needs \(Format.bytes(plan.toCopyBytes)).",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                }
            }
        }
    }

    private func previewDetail(_ p: MusicPlanner.Preview) -> String {
        var parts = [Format.bytes(p.plan.toCopyBytes)]
        if p.alreadyCopied.files > 0 { parts.append("\(p.alreadyCopied.files.formatted()) already copied") }
        if p.sameNameDifferent.files > 0 { parts.append("\(p.sameNameDifferent.files.formatted()) with the same name as a different file") }
        return parts.joined(separator: ", ")
    }

    private var trackTable: some View {
        Table(model.tracks) {
            TableColumn("Title", value: \.title)
            TableColumn("Artist") { (t: MusicTrack) in Text(t.albumArtist ?? t.artist ?? "") }
            TableColumn("Album") { (t: MusicTrack) in Text(t.album ?? "") }
            TableColumn("#") { (t: MusicTrack) in
                Text(t.trackNumber > 0 ? "\(t.trackNumber)" : "").monospacedDigit()
            }
            .width(min: 24, ideal: 30, max: 40)
            TableColumn("Time") { (t: MusicTrack) in
                Text(time(t.durationMs)).monospacedDigit()
            }
            .width(min: 40, ideal: 50, max: 60)
            TableColumn("Status") { (t: MusicTrack) in
                switch t.status {
                case .copyable: Text("Copyable").foregroundStyle(.secondary)
                case .protected(let why): Text("Protected").foregroundStyle(.orange).help(why)
                case .notOnIPhone: Text("Not on iPhone").foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 100, max: 120)
        }
    }

    private func time(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
