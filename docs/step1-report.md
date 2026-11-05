# Step 1 feasibility report

**Tested 4 November 2026 on macOS 27.2 (Apple Silicon) and one iPhone, using `Tools/iSyncProbe`.**

Connecting, app file transfers and copying photos to the Mac all work on iOS 27.2. AFC copies photos up to 39% faster than ImageCaptureCore, and the USB 2 link is now the limit. Adding photos and music to the iPhone (T4 and T5) hasn't been tested, because no ATC session may open until the phone's owner confirms.

## Results

| Test | Result | Reason |
|---|---|---|
| T1 Connect | Pass | Worked after a new Trust tap. The phone first rejected the Mac's old pair record with `InvalidHostID`. |
| T2 Files | Pass | A 1 MB file went into an app's Documents folder and back with a matching SHA-256, then was deleted. |
| T3 Photos to Mac | Pass | Every copy had the right size, and no run had an error. `Photos.sqlite` is readable. |
| T4 Add a photo (ATC) | Not run | The preflight verdict is `unknown`, and the owner's own confirmation hasn't arrived. |
| T5 Add a song (ATC) | Not run | Same as T4. |

## Devices

| | iPhone 16 Pro Max | iPhone 18 Pro Max |
|---|---|---|
| ProductType | iPhone17,2 | Not connected |
| ProductVersion and BuildVersion | iOS 27.2 (24B119) | Not tested |
| DeviceName | Read successfully. Left out because this repo is public. | Not tested |
| USB link speed | 480 Mb/s (USB 2) | Not tested |
| Cable | Not identified by macOS. The Mac's port supports USB 3, but only USB 2 is active. `ActiveCable` is `No`. | Not tested |

The port on the iPhone 16 Pro Max is [limited to 10 Gb/s](https://9to5mac.com/2024/09/11/usb-3-iphone-16-pro/) over USB 3, about 20 times this link's speed. With both ends capable of USB 3, the cable is the most likely limit. No USB 3 cable has been tested.

## T3: photos to Mac

### Library

| Measure | Value |
|---|---|
| Files in `/DCIM` | 34,694 |
| Total size | 191.03 GB |
| Folders | 66 |
| Time to list everything | About 4 s, using 4 connections |
| iCloud Photos | Off, so the originals are on the phone. This is why Settings has no "Optimize iPhone Storage" option. |

### Speed

Each run copied about 2 GB of files that the test hadn't read before. The samples differ, so small differences between rows aren't meaningful.

| Method | Connections or requests | Read size | Files | MB/s |
|---|---|---|---|---|
| AFC | 1 | 1 MB | 506 | 36.3 |
| AFC | 1 | 1 MB | 423 | 36.0 |
| AFC | 2 | 1 MB | 158 | 42.7 |
| AFC | 4 | 1 MB | 288 | 42.8 |
| ImageCaptureCore | 1 | Not applicable | 409 | 30.8 |

The same 73 files, copied repeatedly, show the same pattern without the sample differences. The phone may have served these from its cache.

| AFC connections | MB/s |
|---|---|
| 1 | 38.8 |
| 2 | 43.2 |
| 4 | 43.5 |

At these speeds, the whole 191 GB library would take about 74 minutes with AFC and about 103 minutes with ImageCaptureCore.

### What the numbers show

- **Connections:** two connections add about 18%. Four add nothing more, because the link is already full. This needs retesting on USB 3.
- **Read size:** read size matters. 64 KB reads gave 24.2 MB/s. On samples of large videos, 1 MB reads gave 39.0 MB/s and 4 MB reads gave 40.1 MB/s.
- **File integrity:** AFC and ImageCaptureCore produced byte-identical copies of all 818 files both methods copied (409 in each of two comparisons).
- **Locked phone:** AFC kept working while the phone was locked. ImageCaptureCore refused to start until it was unlocked (`-9943`, "Please unlock").
- **ImageCaptureCore in parallel:** four requests in flight gave 32.0 MB/s on files the test had already read, so there's no meaningful gain.

### ImageCaptureCore's limits

- Its catalog reports 100% complete at 5,251 items, while `Photos.sqlite` has 15,374 assets. I haven't found out why.
- It didn't list 10 of 419 sample files in one run and 14 of 423 in another. In the second run, those were 10 JPG, 2 HEIC, 1 JPEG and 1 PNG.
- It failed to detect the phone once in 4 runs, then worked on retry.

### Photos.sqlite

`/PhotoData/Photos.sqlite` is readable over AFC. It's 934 MB, copied in 24 s, with 100 tables, 15,374 assets and 362 album rows. So albums and edit information should be available to the app later. Schema names can change between iOS versions.

### Not measured

- **The Photos app's Import:** it needs the GUI, so ImageCaptureCore stands in for it. Photos does extra library processing, so its Import may be slower than this baseline.
- **USB 3:** no USB 3 cable was available during these runs.

## T4 and T5: how far ATC got

No ATC session was opened. The test stopped at the safety gate.

| Stage | T4 photo | T5 song |
|---|---|---|
| Load `AirTrafficHost` and `MobileDevice` with `dlopen` | Yes | Yes |
| Resolve the required symbols | Yes | Yes |
| Pairing accepted by Apple's framework | Yes | Yes |
| Preflight | `unknown`, so stopped | `unknown`, so stopped |
| AFC upload to `/iTunes_Control/Music` | Not applicable | Not attempted |
| `SyncAllowed`, Grappa, `ReadyForSync`, manifest | Not attempted | Not attempted |

### Why the preflight says `unknown`

Nothing on the phone is Finder-synced today, but the effect of a new host library can't be ruled out.

| Check | Finding |
|---|---|
| Media items with a sync ID | 0 of 1,070 |
| Photo assets in a sync folder | 0 of 15,374. `/PhotoData/Sync` doesn't exist. |
| Playlists with a sync ID | 9, all with no items, created in 2018 and 2019 |
| Photo-sync settings | `PhotosFolderName`, `PhotosFolderAlbums` and `PhotosFolderPrefs`, last changed in December 2018 |
| Music stored on the phone | 1,023 tracks, 8.07 GB, with no test yet of how a new host library treats them |

### What to expect

[mediaporter's research](https://github.com/faeton/mediaporter/blob/main/research/docs/AIRTRAFFICHOST_FINDINGS.md) found that Apple's framework can't complete Grappa from a third-party process, because `fairplayd` requires the Apple-only entitlement `com.apple.private.fpsd.client`. That work was done on iOS 26.3.1 and hasn't been confirmed on iOS 27.2.

mediaporter gets past this by [replaying a captured Grappa blob and using separately written CIG signing code](https://github.com/faeton/mediaporter/blob/main/research/docs/ATC_SYNC_FLOW.md). iSync's plan is for Apple's code to run the handshake, so `iSyncProbe` does neither of those things. It also uses no private entitlements. Its code is original, and mediaporter was only read for the protocol.

## Recommendation

These are provisional for adding to the iPhone, because T4 and T5 haven't run.

| Feature | Recommendation | Basis |
|---|---|---|
| Photos to Mac | AFC, 2 connections, 1 MB reads | Measured. It's faster than ImageCaptureCore, works on a locked phone, and sees every file in `/DCIM`. |
| Files | AFC through house_arrest | Measured in T2. |
| Add photos to iPhone | The helper app with PhotoKit, unless the handshake succeeds | Published research suggests Apple's framework will refuse. PhotoKit is a public API, and it puts photos in the main library, where they can be edited and deleted. |
| Add music to iPhone | Not shown to be viable | The only published route needs the replayed blob and separate signing code. Apple offers no public alternative. |

## Next steps

1. **Confirm the handshake.** With the owner's OK, run `t4` and `t5` with `--user-approved-sync-risk`. They stop at the phone's first reply and send no album, song or sync metadata.
2. **Try a USB 3 cable.** Rerun `t3` to measure the real gain. Four connections may start to help at that speed.
3. **Test the iPhone 18 Pro Max.** It hasn't been connected yet.

## Open questions

- **`iTunesPrefs` timestamps:** `iTunesPrefs` and `iTunesPrefs.plist` on the phone show a change at 07:02:48 UTC, during testing. `iSyncProbe` has no code that writes to them, and T2 only wrote its own test file to an app's Documents folder. The cause is unknown. It may be the phone itself, or Finder's device service reacting to the new pairing.
- **ImageCaptureCore's catalog:** why does it list only 5,251 items?

## Sources

- [9to5Mac: iPhone 16 Pro USB 3 speeds](https://9to5mac.com/2024/09/11/usb-3-iphone-16-pro/)
- [mediaporter](https://github.com/faeton/mediaporter): `research/docs/AIRTRAFFICHOST_FINDINGS.md` and `research/docs/ATC_SYNC_FLOW.md`
