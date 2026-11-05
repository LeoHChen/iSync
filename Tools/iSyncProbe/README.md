# iSyncProbe

A command-line test tool for step 1 of iSync. It checks which device protocols
work on a connected iPhone and how fast they run. It uses the same libraries and
frameworks the real app will use.

## Requirements

- macOS on Apple Silicon, with Xcode
- Homebrew packages:

```bash
brew install libimobiledevice libplist libusbmuxd pkgconf
```

## Build

```bash
swift build -c release
```

Run it from this folder, because the build reads `Support/Info.plist` by a
relative path.

## Usage

Unlock the iPhone first. ImageCaptureCore won't run while the phone is locked.

```bash
.build/release/iSyncProbe list
.build/release/iSyncProbe t1
.build/release/iSyncProbe t2
.build/release/iSyncProbe t3 --sample-gb 2 --connections 1,2,4
.build/release/iSyncProbe preflight
```

Run with no arguments to see every command and option.

| Command | What it does | Writes to the iPhone? |
|---|---|---|
| `t1` | Pairs if needed, reads device info, reports USB link speed | Only the pairing record, if a new pairing is needed |
| `t2` | Sends a 1 MB file through an app's Documents folder, checks SHA-256, deletes it | Yes, then removes its own test file |
| `t3` | Lists `/DCIM`, copies a sample with AFC and ImageCaptureCore, reads `Photos.sqlite` | No |
| `preflight` | Looks for Finder- or iTunes-synced content over AFC, with no ATC session | No |
| `atc-check` | Loads Apple's private frameworks and checks symbols, with no device session | No |
| `t4`, `t5` | Open an ATC sync session through Apple's framework | See below |

## Safety rules for `t4` and `t5`

- Both commands rerun `preflight` and refuse to open a sync session unless the
  verdict is `clean`.
- `--user-approved-sync-risk` overrides that. Use it only after the phone's owner
  has agreed.
- The session stops at the phone's first reply to the sync request. This version
  sends no album, song or sync metadata.
- `t5` also tests AFC write access by uploading a generated test track to the music
  folder, reading it back and deleting it.
- Apple's framework runs the Grappa handshake. This tool doesn't replay captured
  Grappa blobs, include its own signing code, or use private entitlements.

## Output

Results, logs and copied files go to `~/iSyncProbe-out`, outside the repo:

| Path | Contents |
|---|---|
| `results/` | JSON results for each test |
| `afc/`, `icc/` | Photos copied by the latest speed runs |
| `preflight/` | Copies of the phone's `Photos.sqlite` and `MediaLibrary.sqlitedb` |
| `logs/` | Mac and iPhone logs from `t4` and `t5` |
| `media/` | The generated test photo and song |

These folders hold personal photos and library data. Delete them when you're done:

```bash
rm -rf ~/iSyncProbe-out
```
