# Step 1 feasibility report

**Tested 4 November 2026 on macOS 27.2 (Apple Silicon) and one iPhone, using `Tools/iSyncProbe`.**

Connecting, app file transfers and copying photos to the Mac all work on iOS 27.2. AFC copies photos up to 39% faster than ImageCaptureCore, and the USB 2 link is now the limit. Adding photos and music to the iPhone (T4 and T5) hasn't been tested, because no ATC session may open until the phone's owner confirms.

## Results

| Test | Result | Reason |
|---|---|---|
| T1 Connect | Pass | Worked after a new Trust tap. The phone first rejected the Mac's old pair record with `InvalidHostID`. |
| T2 Files | Pass | A 1 MB file went into an app's Documents folder and back with a matching SHA-256, then was deleted. |
| T3 Photos to Mac | Pass | Every AFC copy had the right size, with no errors. ImageCaptureCore also works, with the limits listed below. `Photos.sqlite` is readable. |
| T4 Add a photo (ATC) | Handshake passed. No photo added. | Reached `ReadyForSync`, then stopped as approved. |
| T5 Add a song (ATC) | Not completed. No song added. | The first attempt was refused because of a bug in the request. The corrected run wasn't made, for the reason under T4 and T5 below. |

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

- **Connections:** two connections add 11% to 18%. Four add nothing more, because the link is already full. This needs retesting on USB 3.
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
- **USB 3:** every run used the cable that was plugged in, which linked at USB 2.

## T4 and T5: how far ATC got

The phone's owner approved a handshake-only test: Apple's `AirTrafficHost` framework runs the session, the test stops at the phone's first reply to the sync request, and no album, song or sync metadata is sent. No Grappa data was replayed, no signing code of our own was used, and no special entitlements were needed.

| Stage | T4 photos, corrected | T4 and T5, first attempt |
|---|---|---|
| Load `AirTrafficHost` and `MobileDevice` | Yes | Yes |
| Open the session | Yes | Yes |
| `SyncAllowed` | Yes | Yes |
| Framework generates an 84-byte Grappa blob | Yes | Yes |
| Reply to the sync request | `ReadyForSync`, with an 83-byte Grappa reply | `SyncFailed`, ErrorCode 12 |
| Send sync metadata or files | Not attempted | Not attempted |

**ErrorCode 12 wasn't about Grappa.** The phone's log said why: `Sending sync disallowed, incompatible version: (null) vs. 10.5.0.115 required`. The first requests carried no host version, because the test passed an empty dictionary as the last argument of `ATHostConnectionSendSyncRequest`. That argument is merged into the request's `HostInfo`. Passing `LibraryID`, `SyncHostName`, `SyncedDataclasses` and `Version` fixed it. The version sent is the real version of `AirTrafficHost.framework`.

### What the handshake changed on the phone

All content was unchanged before and after: media items, tracks, playlists, photo assets, albums and every file in `/DCIM` and `/iTunes_Control/Music`. iOS did do three things:

- It created empty folders: `/PhotoData/Sync`, `/Airlock/Keybag` and `/Airlock/Photo`.
- It ran `prepareForSyncWithHostAnchor: 0` and queued a `cleanup sync state` job. This phone has no synced photos, so nothing was removed, but it suggests a session from a new library could clear previously synced photos on a phone that has them.
- When the session closed, it cancelled and finished the session normally.

### Why the corrected T5 wasn't run

T5 was to run only if T4 changed nothing, and T4 did change something. The same preparation step for music hasn't been observed, and every music track on this phone is flagged `sync_in_my_library`. So running it is the phone owner's decision.

### What's still unknown

- **Signing.** Published research says sync metadata needs a CIG signature made from the phone's Grappa reply. Whether Apple's framework can make that signature for a third-party process hasn't been tested.
- **Photo metadata.** The published format covers video. The format for adding photos isn't documented.
- **Metadata has never been sent,** so nothing beyond `ReadyForSync` has been tested.

## Recommendation

| Feature | Recommendation | Basis |
|---|---|---|
| Photos to Mac | AFC, 2 connections, 1 MB reads | Measured. It's faster than ImageCaptureCore, works on a locked phone, and sees every file in `/DCIM`. |
| Files | AFC through house_arrest | Measured in T2. |
| Add photos to iPhone | Find out next whether Apple's framework can sign sync metadata. Keep the PhotoKit helper app as the fallback. | The main reason to expect failure is gone, but the steps after the handshake are untested. |
| Add music to iPhone | Same open question as photos, plus the effect of anchor 0 on existing tracks | Apple offers no public alternative. |

## Next steps

1. **Decide on T5.** The corrected handshake for music needs the owner's decision.
2. **Test signing.** Check, without a phone, whether Apple's framework exposes CIG signing.
3. **Try a USB 3 cable.** Rerun `t3` to measure the real gain. Four connections may start to help at that speed.
4. **Test the iPhone 18 Pro Max.** It hasn't been connected yet.

## Open questions

- **`iTunesPrefs` timestamps:** `iTunesPrefs` and `iTunesPrefs.plist` on the phone show a change at 07:02:48 UTC, during testing. `iSyncProbe` has no code that writes to them, and T2 only wrote its own test file to an app's Documents folder. The cause is unknown. It may be the phone itself, or Finder's device service reacting to the new pairing.
- **ImageCaptureCore's catalog:** why does it list only 5,251 items?

## Sources

- [9to5Mac: iPhone 16 Pro USB 3 speeds](https://9to5mac.com/2024/09/11/usb-3-iphone-16-pro/)
- [mediaporter](https://github.com/faeton/mediaporter): `research/docs/AIRTRAFFICHOST_FINDINGS.md` and `research/docs/ATC_SYNC_FLOW.md`
