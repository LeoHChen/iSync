import iSyncCore
import SwiftUI

/// The progress bar, speed and controls shown during a copy.
struct CopyProgressSection: View {
    let progress: PhotoCopyEngine.Progress
    let pause: () -> Void
    let resume: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progress.fraction)
            HStack {
                Text("\(progress.copiedFiles.formatted()) of \(progress.totalFiles.formatted()) files, \(Format.bytes(progress.copiedBytes)) of \(Format.bytes(progress.totalBytes))")
                    .monospacedDigit()
                Spacer()
                Text(speedText).foregroundStyle(.secondary).monospacedDigit()
            }
            if progress.failedFiles > 0 {
                Label("\(progress.failedFiles.formatted()) files couldn't be copied so far", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                if progress.isPaused {
                    Button("Resume", action: resume).buttonStyle(.borderedProminent)
                } else {
                    Button("Pause", action: pause)
                }
                Button("Cancel", action: cancel)
                Spacer()
                Text("Finished files are kept if you cancel.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var speedText: String {
        if progress.isPaused { return "Paused" }
        guard progress.bytesPerSecond > 0 else { return "Starting…" }
        var text = Format.speed(progress.bytesPerSecond)
        if let left = progress.secondsRemaining { text += ", about \(Format.duration(left)) left" }
        return text
    }
}

/// What the last copy did.
struct CopyResultView: View {
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

/// The picker for what happens when a file already exists, with its meaning spelled out.
struct ConflictPolicyPicker: View {
    @Binding var policy: ConflictPolicy
    let disabled: Bool

    var body: some View {
        Picker("If a file already exists", selection: $policy) {
            Text("Skip duplicates").tag(ConflictPolicy.skipDuplicates)
            Text("Overwrite").tag(ConflictPolicy.overwrite)
        }
        .disabled(disabled)
        Text(explanation).font(.callout).foregroundStyle(.secondary)
    }

    private var explanation: String {
        switch policy {
        case .skipDuplicates:
            return "Files already there stay as they are. A different file with the same name is kept too, with a number added to its name."
        case .overwrite:
            return "Copies again and replaces any file at the same path. Nothing else in the folder is deleted."
        }
    }
}
