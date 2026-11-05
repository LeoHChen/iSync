import Foundation
import ImageCaptureCore

/// Downloads the T3 sample with Apple's public ImageCaptureCore as a speed baseline.
final class ICCDownload: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    private let udid: String
    private let deviceName: String
    private let sample: [RemoteFile]
    private let outstanding: Int
    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var finished = false
    private var result: [String: Any] = [:]
    private var queue: [(file: ICCameraFile, localName: String)] = []
    private var inFlight = 0
    private var downloaded = 0
    private var failed = 0
    private var unmatched = 0
    private var requested = 0
    private var bytes: Int64 = 0
    private var t0 = Date()
    private var cpu0 = 0.0
    private var errors: [String] = []
    private let dir: URL
    private var nextReport = Date()
    private var waitingForUnlock = false
    private var catalogHandled = false
    private let unlockDeadline = Date().addingTimeInterval(900)

    init(udid: String, deviceName: String, sample: [RemoteFile], outstanding: Int) {
        self.udid = udid
        self.deviceName = deviceName
        self.sample = sample
        self.outstanding = max(1, outstanding)
        dir = Paths.dir("icc")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func run(timeout: TimeInterval = 1800) -> [String: Any] {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        let deadline = Date().addingTimeInterval(timeout)
        while !finished && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.25))
            if camera == nil && Date().timeIntervalSince(t0) > 45 {
                finish(failure: "ImageCaptureCore didn't report this iPhone within 45 s")
            }
        }
        if !finished { finish(failure: "timed out after \(Int(timeout)) s") }
        browser.stop()
        camera?.requestCloseSession()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return result
    }

    private func finish(failure: String?) {
        guard !finished else { return }
        finished = true
        result["downloaded"] = downloaded
        result["failed"] = failed
        result["unmatched"] = unmatched
        result["bytes"] = bytes
        result["outstandingRequests"] = outstanding
        result["errors"] = Array(errors.prefix(5))
        if let failure {
            result["failure"] = failure
        } else {
            let secs = Date().timeIntervalSince(t0)
            result["seconds"] = secs
            result["MBps"] = Double(bytes) / 1e6 / secs
            result["cpuSeconds"] = processCPUSeconds() - cpu0
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        let serial = udid.replacingOccurrences(of: "-", with: "")
        let name = cam.name ?? "?"
        let devSerial = (cam.serialNumberString ?? "").replacingOccurrences(of: "-", with: "")
        // ImageCaptureCore doesn't report the UDID, so fall back to the phone's name.
        let matches = devSerial == serial || name == deviceName
        log("      ICC sees camera \"\(name)\", matches this phone: \(matches)")
        guard matches else { return }
        camera = cam
        cam.delegate = self
        t0 = Date()
        cam.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device === camera { finish(failure: "camera was removed") }
    }

    func didRemove(_ device: ICDevice) {
        if device === camera { finish(failure: "camera was removed") }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard let error else {
            log("      ICC session open, waiting for the content catalog")
            return
        }
        // -9943 means "Please unlock". Retry, since the owner may be away from the phone.
        if (error as NSError).code == -9943, Date() < unlockDeadline {
            if !waitingForUnlock {
                waitingForUnlock = true
                log("      ICC is waiting for the iPhone to be unlocked (up to 15 minutes)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.finished, let cam = self.camera else { return }
                cam.requestOpenSession()
            }
            return
        }
        finish(failure: "open session: \(error)")
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        log("      ICC access restriction removed")
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        log("      ICC reports the iPhone is locked or access restricted")
        result["accessRestricted"] = true
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        // A locked phone reports an empty catalog. The real one arrives after unlock.
        if (device.mediaFiles ?? []).isEmpty && device.isAccessRestrictedAppleDevice { return }
        if (device.mediaFiles ?? []).isEmpty && waitingForUnlock { return }
        guard !catalogHandled else { return }
        catalogHandled = true
        let catalogSeconds = Date().timeIntervalSince(t0)
        result["catalogSeconds"] = catalogSeconds
        result["accessRestricted"] = device.isAccessRestrictedAppleDevice
        result["iCloudPhotosEnabled"] = device.iCloudPhotosEnabled
        let all = device.mediaFiles ?? []
        result["catalogItems"] = all.count
        log(String(format: "      ICC catalog: %d media items in %.1f s, iCloud Photos %@", all.count, catalogSeconds,
                   device.iCloudPhotosEnabled ? "on" : "off"))

        // Live Photo videos and edit sidecars hang off a parent file, so index
        // those as well as the top-level items.
        var byName: [String: ICCameraFile] = [:]
        func add(_ f: ICCameraFile) {
            let folder = f.parentFolder?.name ?? ""
            if let n = f.name {
                byName["\(folder)/\(n)".uppercased()] = f
                if byName[n.uppercased()] == nil { byName[n.uppercased()] = f }
            }
        }
        for item in all {
            guard let f = item as? ICCameraFile else { continue }
            add(f)
            for s in f.sidecarFiles ?? [] { if let sf = s as? ICCameraFile { add(sf) } }
        }

        for rf in sample {
            let parts = rf.path.split(separator: "/").map(String.init)
            let name = parts.last ?? ""
            let folder = parts.count >= 3 ? parts[parts.count - 2] : ""
            if let f = byName["\(folder)/\(name)".uppercased()] ?? byName[name.uppercased()] {
                queue.append((f, localName(rf.path)))
            } else {
                unmatched += 1
            }
        }
        log("      ICC matched \(queue.count) of \(sample.count) sample files by name")
        guard !queue.isEmpty else {
            finish(failure: "no sample file matched a catalog item")
            return
        }
        // Clock the transfer only, as with the AFC runs.
        t0 = Date()
        cpu0 = processCPUSeconds()
        pump()
    }

    private func pump() {
        guard let camera else { return }
        while inFlight < outstanding && requested < queue.count {
            let job = queue[requested]
            requested += 1
            inFlight += 1
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: dir,
                .saveAsFilename: job.localName,
                .overwrite: true,
                .sidecarFiles: false,
            ]
            camera.requestDownloadFile(
                job.file, options: options, downloadDelegate: self,
                didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)), contextInfo: nil)
        }
        if inFlight == 0 && requested >= queue.count { finish(failure: nil) }
    }

    @objc func didDownloadFile(
        _ file: ICCameraFile, error: Error?, options: [String: Any] = [:],
        contextInfo: UnsafeMutableRawPointer?
    ) {
        inFlight -= 1
        if let error {
            failed += 1
            errors.append("\(file.name ?? "?"): \(error)")
        } else {
            downloaded += 1
            let fname = options[ICDownloadOption.savedFilename.rawValue] as? String
            var size = file.fileSize
            if let fname, let a = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(fname).path),
               let s = a[.size] as? NSNumber
            {
                size = s.int64Value
            }
            bytes += size
        }
        if Date() >= nextReport {
            nextReport = Date().addingTimeInterval(15)
            log("    \(downloaded + failed) of \(queue.count) files, \(fmtBytes(bytes))")
        }
        pump()
    }
}
