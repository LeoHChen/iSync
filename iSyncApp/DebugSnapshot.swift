#if DEBUG
import AppKit
import iSyncCore

/// Automated checks for debug builds only. Release builds don't contain this file's code.
///
/// ISYNC_SNAPSHOT=<file.png> saves a picture of the window, then quits.
///   ISYNC_SNAPSHOT_ITEM picks the page: photos, files or add.
///   ISYNC_SNAPSHOT_APP picks an app on the Files page, by bundle ID.
/// ISYNC_SELFTEST=<file.json> drives the real models on a connected iPhone, then quits.
///   ISYNC_TEST_DEST is the photo folder. ISYNC_TEST_LIMIT is how many recent files to copy.
///   ISYNC_TEST_APP is the app to test. It uploads and deletes one uniquely named test file.
@MainActor
enum DebugSnapshot {
    static func scheduleIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["ISYNC_SELFTEST"] {
            Task { @MainActor in await selfTest(model, env: env, resultPath: path) }
        } else if let path = env["ISYNC_SNAPSHOT"] {
            Task { @MainActor in await snapshot(model, env: env, path: path) }
        }
    }

    private static func waitFor(_ seconds: Double, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private static func snapshot(_ model: AppModel, env: [String: String], path: String) async {
        let delay = Double(env["ISYNC_SNAPSHOT_DELAY"] ?? "") ?? 8
        try? await Task.sleep(for: .seconds(delay / 2))
        if let udid = model.devices.first?.udid {
            switch env["ISYNC_SNAPSHOT_ITEM"] ?? "photos" {
            case "files":
                model.selection = .files(udid)
                if let device = model.device(udid) {
                    device.files.loadApps()
                    _ = await waitFor(5) { !device.files.apps.isEmpty }
                    if let wanted = env["ISYNC_SNAPSHOT_APP"],
                       let app = device.files.apps.first(where: { $0.bundleID == wanted })
                    {
                        device.files.select(app)
                    }
                }
            case "add": model.selection = .addToIPhone(udid)
            default: model.selection = .photos(udid)
            }
        }
        try? await Task.sleep(for: .seconds(delay / 2))
        save(to: path)
        NSApp.terminate(nil)
    }

    /// Draws the window to a file. Liquid Glass doesn't draw this way, so the sidebar's
    /// list is drawn separately and placed on top.
    private static func save(to path: String) {
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        func glass(_ v: NSView) -> NSView? {
            if #available(macOS 26.0, *), v is NSGlassEffectView { return v }
            for c in v.subviews { if let hit = glass(c) { return hit } }
            return nil
        }
        func outline(_ v: NSView) -> NSOutlineView? {
            if let o = v as? NSOutlineView { return o }
            for c in v.subviews { if let hit = outline(c) { return hit } }
            return nil
        }
        if let pane = glass(view), let list = outline(pane),
           let sub = list.bitmapImageRepForCachingDisplay(in: list.bounds),
           let context = NSGraphicsContext(bitmapImageRep: rep)
        {
            list.cacheDisplay(in: list.bounds, to: sub)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(white: 0.15, alpha: 1).setFill()
            pane.convert(pane.bounds, to: view).fill()
            sub.draw(in: list.convert(list.bounds, to: view))
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func selfTest(_ model: AppModel, env: [String: String], resultPath: String) async {
        var r: [String: Any] = [:]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: resultPath))
            }
            NSApp.terminate(nil)
        }
        guard await waitFor(20, until: { model.devices.first?.status == .ready }), let device = model.devices.first else {
            r["device"] = "never became ready"
            return
        }
        r["deviceReady"] = true
        r["summaryRead"] = device.summary != nil
        r["storageShown"] = device.summary?.storageFree != nil
        r["batteryShown"] = device.summary?.batteryPercent != nil
        _ = await waitFor(5) { device.linkSpeed != nil }
        r["linkSpeedShown"] = device.linkSpeed != nil

        // Photos
        let photos = device.photos
        if let dest = env["ISYNC_TEST_DEST"] {
            photos.debugUse(destination: URL(fileURLWithPath: dest), limit: Int(env["ISYNC_TEST_LIMIT"] ?? "") ?? 50)
            photos.loadIfNeeded()
            let planned = await waitFor(30) { photos.phase == .ready && photos.plan != nil && !photos.isPlanning }
            r["photosPlanned"] = planned
            r["firstPlanToCopy"] = photos.plan?.toCopyFiles ?? -1
            // Cancel first, then the rest of the copy picks up what's left.
            photos.startCopy()
            _ = await waitFor(10) { photos.progress.copiedBytes > 0 }
            try? await Task.sleep(for: .seconds(3))
            photos.cancel()
            _ = await waitFor(30) { photos.phase == .ready && photos.lastResult != nil && !photos.isPlanning }
            r["cancelReported"] = photos.lastResult?.wasCancelled ?? false
            let cancelledCopied = photos.lastResult?.copiedFiles ?? -1
            r["cancelledAfterFiles"] = cancelledCopied
            r["toCopyAfterCancel"] = photos.plan?.toCopyFiles ?? -1
            let found = FileManager.default.enumerator(atPath: dest)?.compactMap { $0 as? String } ?? []
            r["partialsAfterCancel"] = found.filter { $0.hasSuffix(".isync-partial") }.count

            photos.startCopy()
            _ = await waitFor(5) { photos.progress.bytesPerSecond > 0 }
            r["speedShown"] = photos.progress.bytesPerSecond > 0
            r["etaShown"] = photos.progress.secondsRemaining != nil

            photos.pause()
            try? await Task.sleep(for: .seconds(1.5))
            let pausedAt = photos.progress.copiedBytes
            try? await Task.sleep(for: .seconds(2))
            r["pauseHeld"] = photos.progress.copiedBytes == pausedAt && photos.isPaused
            r["pausedBytes"] = pausedAt
            if let shot = env["ISYNC_TEST_SHOT"] { save(to: shot + "-paused.png") }
            photos.resume()
            let finished = await waitFor(300) { photos.phase == .ready && photos.lastResult != nil && !photos.isPlanning }
            r["copyFinished"] = finished
            r["copied"] = photos.lastResult?.copiedFiles ?? -1
            r["failed"] = photos.lastResult?.failures.count ?? -1
            r["speedMBps"] = (photos.lastResult?.averageBytesPerSecond ?? 0) / 1e6
            r["afterCopyToCopy"] = photos.plan?.toCopyFiles ?? -1
            r["afterCopyAlready"] = photos.plan?.alreadyCopiedFiles ?? -1
            if let shot = env["ISYNC_TEST_SHOT"] { save(to: shot + "-done.png") }

            // Changing the layout mustn't copy finished files again.
            let savedLayout = photos.layout
            photos.layout = savedLayout == .yearMonth ? .sameAsIPhone : .yearMonth
            _ = await waitFor(10) { !photos.isPlanning }
            r["toCopyAfterLayoutChange"] = photos.plan?.toCopyFiles ?? -1
            photos.layout = savedLayout
        }

        // Files
        if let bundle = env["ISYNC_TEST_APP"] {
            let files = device.files
            files.loadApps()
            _ = await waitFor(10) { !files.apps.isEmpty }
            r["appsListed"] = files.apps.count
            guard let app = files.apps.first(where: { $0.bundleID == bundle }) else {
                r["app"] = "not found"
                return
            }
            files.select(app)
            _ = await waitFor(10) { !files.loading }
            let before = files.entries.count
            r["entriesListed"] = before
            let name = "iSync-selftest-\(UUID().uuidString).txt"
            let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? Data("iSync self test".utf8).write(to: local)
            defer { try? FileManager.default.removeItem(at: local) }
            files.upload([local])
            let uploaded = await waitFor(15) { files.transfer == nil && !files.loading && files.entries.contains { $0.name == name } }
            r["uploadListed"] = uploaded
            if let entry = files.entries.first(where: { $0.name == name }) {
                files.deleteConfirmed([entry])
                let gone = await waitFor(15) { !files.loading && !files.entries.contains { $0.name == name } }
                r["deleteRemoved"] = gone
                r["entriesAfterDelete"] = files.entries.count
            }
            r["filesError"] = files.errorMessage ?? ""
        }
    }
}
#else
enum DebugSnapshot {
    @MainActor static func scheduleIfRequested(_ model: AppModel) {}
}
#endif
