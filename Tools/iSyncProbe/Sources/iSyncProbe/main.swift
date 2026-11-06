import Foundation

let usage = """
    iSyncProbe: tests which device protocols work on the connected iPhone(s).

    usage: iSyncProbe <command> [options]

    commands:
      list                  list connected devices
      pair                  confirm pairing, or show the Trust prompt and wait
      t1                    connect, read device info, report USB link speed
      t2                    round-trip a test file through an app's Documents
      t3                    copy photos to the Mac, AFC vs ImageCaptureCore
      preflight             check for Finder- or iTunes-synced content
      t4                    ATC handshake for photos, adding nothing (runs preflight first)
      t5                    ATC handshake for music, adding nothing (runs preflight first)
      atc-check             load Apple's frameworks and check symbols. Opens no session.
      all                   t1, t2, t3, preflight, and t4 and t5 if preflight is clean

    options:
      --udid <udid>         test one device instead of every connected device
      --sample-gb <n>       size of the T3 copy sample (default 2)
      --offset-gb <n>       skip the newest n GB so the T3 read is uncached
      --connections <list>  AFC connection counts for T3 (default 1,2,4)
      --chunk-kb <n>        AFC read size (default 1024)
      --no-icc              skip the ImageCaptureCore baseline
      --icc-first           run ImageCaptureCore before the AFC copies
      --skip-photos-db      skip the Photos.sqlite check in T3
      --result-name <name>  file name for this T3 run's results (default t3)
      --icc-outstanding <n> simultaneous ImageCaptureCore requests (default 1)
      --bundle <id>         preferred app for T2
      --wait <seconds>      how long to wait for the Trust prompt (default 120)
      --atc-timeout <s>     how long to wait for each ATC stage (default 60)
      --user-approved-sync-risk
                            run t4/t5 if preflight is unknown. Only use this after
                            the phone's owner has agreed. Never overrides synced.

    Output goes to ~/iSyncProbe-out, outside the repo.
    """

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    log(usage)
    exit(2)
}
args.removeFirst()

var udidFilter: String?
var t3Options = T3Options()
var bundle: String?
var wait = 120.0
var atcTimeout = 60.0
var approvedRisk = false

var i = 0
func nextValue(_ name: String) -> String {
    i += 1
    guard i < args.count else {
        log("missing value for \(name)")
        exit(2)
    }
    return args[i]
}
while i < args.count {
    switch args[i] {
    case "--udid": udidFilter = nextValue("--udid")
    case "--sample-gb": t3Options.sampleBytes = Int64((Double(nextValue("--sample-gb")) ?? 2) * 1e9)
    case "--offset-gb": t3Options.offsetBytes = Int64((Double(nextValue("--offset-gb")) ?? 0) * 1e9)
    case "--connections":
        t3Options.connections = nextValue("--connections").split(separator: ",").compactMap { Int($0) }
    case "--chunk-kb": t3Options.chunkBytes = (Int(nextValue("--chunk-kb")) ?? 1024) * 1024
    case "--no-icc": t3Options.runICC = false
    case "--icc-first": t3Options.iccFirst = true
    case "--skip-photos-db": t3Options.probePhotosDB = false
    case "--result-name": t3Options.resultName = nextValue("--result-name")
    case "--icc-outstanding": t3Options.iccOutstanding = Int(nextValue("--icc-outstanding")) ?? 1
    case "--bundle": bundle = nextValue("--bundle")
    case "--wait": wait = Double(nextValue("--wait")) ?? 120
    case "--atc-timeout": atcTimeout = Double(nextValue("--atc-timeout")) ?? 60
    case "--user-approved-sync-risk": approvedRisk = true
    default:
        log("unknown option \(args[i])\n\n\(usage)")
        exit(2)
    }
    i += 1
}

let devices = listDevices().filter { udidFilter == nil || $0.udid == udidFilter }
if command == "list" {
    for d in devices { log("\(d.udid)  \(d.connection)") }
    if devices.isEmpty { log("no devices") }
    exit(0)
}
let usbDevices = devices.filter { $0.connection == "USB" }
guard !usbDevices.isEmpty else {
    log("No iPhone connected over USB.")
    exit(1)
}

var failed = false
for d in usbDevices {
    switch command {
    case "pair":
        do {
            let o = try ensurePaired(udid: d.udid, waitSeconds: wait)
            log("\(d.udid): \(o)")
            if !o.ok { failed = true }
        } catch {
            log("\(d.udid): \(error)")
            failed = true
        }
    case "t1": if !t1(udid: d.udid, conn: d.connection, wait: wait) { failed = true }
    case "t2": if !t2(udid: d.udid, preferredBundle: bundle) { failed = true }
    case "t3": if !t3(udid: d.udid, options: t3Options) { failed = true }
    case "preflight":
        if preflight(udid: d.udid).verdict != .clean { failed = true }
    case "atc-check":
        do {
            let a = try AirTrafficHost()
            log("AirTrafficHost loaded from \(a.loadedFrom)")
            log("MobileDevice loaded from \(a.mobileDeviceFrom)")
            log("all required symbols resolved; no device session opened")
        } catch {
            log("FAIL: \(error)")
            failed = true
        }
    case "t4": if !t4(udid: d.udid, timeout: atcTimeout, approvedRisk: approvedRisk) { failed = true }
    case "t5": if !t5(udid: d.udid, timeout: atcTimeout, approvedRisk: approvedRisk) { failed = true }
    case "all":
        guard t1(udid: d.udid, conn: d.connection, wait: wait) else {
            failed = true
            continue
        }
        if !t2(udid: d.udid, preferredBundle: bundle) { failed = true }
        if !t3(udid: d.udid, options: t3Options) { failed = true }
        if !t4(udid: d.udid, timeout: atcTimeout, approvedRisk: approvedRisk) { failed = true }
        if !t5(udid: d.udid, timeout: atcTimeout, approvedRisk: approvedRisk) { failed = true }
    default:
        log(usage)
        exit(2)
    }
}
exit(failed ? 1 : 0)
