# iSync

iSync is a free macOS app for copying photos, music and files from your iPhone to your Mac over USB. It works like `rsync`: it shows you what would happen, then copies only what's missing, and it finds duplicates by their content rather than their name.

iSync is an independent project, and it isn't affiliated with or endorsed by Apple Inc.

## Features in 0.2

- **Fast photo copies.** Originals come straight from the iPhone with no conversion. Copies reached about 43 MB/s on a USB 2 link in testing, about 39% faster than Apple's ImageCaptureCore.
- **A preview before every copy.** See what's new, what's already copied, what's a duplicate, and what conflicts, with counts and sizes.
- **Duplicates found by content.** The same photo has different `IMG_` names on different phones, so iSync compares capture time, dimensions and size, then confirms with SHA-256.
- **Skip or overwrite.** You choose what happens when a file already exists. Nothing else in the folder is ever deleted.
- **Archive check.** Point iSync at an old photo folder, and it won't copy what's already there. It only reads that folder.
- **Live Photos stay together,** and repeat runs skip finished files. You can pause, resume or cancel, and pick up where you left off.
- **Music to your Mac.** Tracks are copied as `Artist/Album/NN Title.ext`, with their tags and artwork intact.
- **App files.** Browse and transfer the Documents folders of apps that allow file sharing, with drag and drop.
- **Compare two iPhones.** See how many photos a second iPhone already has, without changing either phone.

iSync can't add photos or music to an iPhone yet. See the [roadmap](#roadmap).

## Requirements

- A Mac with Apple Silicon, running macOS 27 or later
- An iPhone connected with a USB cable

iSync has been tested on macOS 27.2 with an iPhone 16 Pro Max on iOS 27.2. Other iPhones and iOS versions may work, but they haven't been tested.

## Install

1. Download `iSync-0.2.0.dmg` from [Releases](https://github.com/LeoHChen/iSync/releases).
2. Open the DMG and drag **iSync** to **Applications**.
3. Open iSync. macOS will refuse the first time, as explained below.

### The first time you open iSync

iSync isn't notarized by Apple, because that requires a paid Developer ID, so macOS blocks it the first time.

1. Open iSync, and click **Done** when macOS says it can't verify the app.
2. Go to **System Settings > Privacy & Security**.
3. Scroll down to **Security**, and click **Open Anyway** next to the iSync message.
4. Click **Open Anyway** again and enter your password.

You only need to do this once. On some older versions of macOS, you can instead right-click the app and choose **Open**.

Only do this if you trust the source. You can check your download against the checksum on the release page, or [build iSync yourself](#build-from-source).

## Usage

Plug in your iPhone and unlock it. If it asks, tap **Trust** and enter your passcode. Your iPhone then appears in the sidebar with its model, storage and battery.

### Photos

1. Choose a destination folder and how to organize it: the same folders as the iPhone, or by year and month.
2. Choose what happens if a file already exists.
3. Read the preview, and click **Copy**.

| Group | What it means | Skip duplicates | Overwrite |
|---|---|---|---|
| New | Not at the destination | Copied | Copied |
| Already copied | Done by an earlier run, or already at its path | Skipped | Copied again, replacing the file |
| Exact duplicate | Same bytes under another name, or twice on the phone | Skipped | Skipped |
| Same name, different content | A different file has this name | Kept, with a number added to its name | Replaces the file |
| Possible duplicate | Same capture time and dimensions, different bytes | Copied and listed | Copied and listed |

You can turn off **Copy possible duplicates** to hold those files back. They stay listed either way.

### Music

Choose **Music** in the sidebar, then click **Copy**. Protected tracks are listed but not copied, because they wouldn't play once copied.

### Files

Choose **Files**, then pick an app. Drag files in from Finder, or use **Add Files…** and **Save to Mac…**. Deleting a file from your iPhone always asks you to confirm first.

## How it works

iSync talks to your iPhone the same way Finder does, using open-source [libimobiledevice](https://libimobiledevice.org) libraries.

- **usbmuxd and lockdown** detect the iPhone, handle the Trust pairing, and start services on the phone.
- **AFC** reads the shared media area, which holds `/DCIM` and `/iTunes_Control/Music`.
- **house_arrest** opens the Documents folder of an app that allows file sharing.
- **`Photos.sqlite` and `MediaLibrary.sqlitedb`** are copied to your Mac and read there, for capture details and track names. They're never changed on the phone.

### Finding duplicates

1. **Candidates come from details, not bytes.** Size, capture time and dimensions nominate possible matches, using the phone's database and each Mac file's EXIF or QuickTime data. A detail that's missing doesn't rule out a match.
2. **SHA-256 decides.** A file is only skipped once its hash confirms the match. An unconfirmed match has no effect on where other files go. Hashes are cached, so each file is read for hashing once.
3. **Only photos and videos are matched.** Edit sidecars such as `.AAE` are often byte-identical across different photos, so they simply follow their photo.

A manifest in `.isync` inside the destination folder records each file's path, size, date and hash. Each iPhone has its own manifest. Files are written under a temporary name and get their real name only after their size checks out.

## Privacy

Everything stays on your Mac. iSync has no accounts, no analytics and no network code.

iSync keeps copies of your iPhone's photo and music databases in `~/Library/Caches/iSync`. You can delete that folder at any time, and iSync will recreate it when needed.

## Build from source

You need Xcode, [Homebrew](https://brew.sh) and the libraries below.

```bash
brew install libimobiledevice libplist libusbmuxd pkgconf xcodegen
```

```bash
xcodegen generate
```

```bash
xcodebuild -project iSync.xcodeproj -scheme iSync -configuration Release -derivedDataPath build build
```

```bash
open build/Build/Products/Release/iSync.app
```

This build links Homebrew's libraries, so it needs them installed. To build the self-contained app and the DMG, install [dmgbuild](https://dmgbuild.readthedocs.io) and run:

```bash
scripts/make-release.sh
```

### Tests

```bash
cd iSyncCore && swift test
```

`isync-check` runs the real engine against a connected iPhone. Its `files` command puts uniquely named test files in an app's Documents folder, then deletes them.

```bash
cd iSyncCore && swift run isync-check info
```

### Project layout

| Path | Contents |
|---|---|
| `iSyncCore` | Swift package: device layer, copy engine, tests and `isync-check` |
| `iSyncApp` | SwiftUI app |
| `Tools/iSyncProbe` | Research tool for protocol tests, which isn't part of the app |
| `docs` | Research reports |
| `scripts` | Release packaging |

## Known limitations

- **Copying to an iPhone isn't available yet.** The destination is always a Mac folder.
- **Edits aren't included.** You get the originals. `.AAE` edit files are copied, but they aren't the edited photos.
- **USB only.** Wi-Fi is on the roadmap.
- **Your cable can limit speed.** A USB 2 cable caps copies at about 43 MB/s. iSync tells you when the link is running at USB 2.
- **The iPhone comparison is an estimate.** It uses photo details, not bytes, so treat it as a preview.
- **Tracks with no artist or album** in your library go in `Unknown Artist` and `Unknown Album`.
- **Files you delete from the Mac folder are copied again** on the next run.
- **Not notarized,** so the first launch takes the extra steps above.
- **Limited testing.** 0.2 has been tested on one iPhone model and one version of iOS.

## History

| Date | Milestone |
|---|---|
| 2026-11-05 | Research and plan |
| 2026-11-05 | Feasibility tests on iOS 27.2 ([report](docs/step1-report.md)) |
| 2026-11-05 | **0.1:** device detection, fast photo copies, app files |
| 2026-11-06 | **0.2:** rsync-style preview, skip or overwrite, content-based duplicates, archive folder check, music to Mac, app icon |

## Roadmap

These plans may change.

| Version | Plan |
|---|---|
| 0.3 | Add photos to an iPhone, and iPhone-to-iPhone transfers through the Mac |
| 0.4 | Add music to an iPhone, depending on further research |
| 0.5 | Full backup and restore |
| 0.6 | Wi-Fi connections |
| Later | Developer ID signing and notarization, Intel support, exporting edited photos, wider iPhone model support |

## License

iSync is under the [MIT License](LICENSE). The release package includes libimobiledevice, libimobiledevice-glue, libplist and libusbmuxd under the LGPL 2.1, and OpenSSL under the Apache License 2.0. See [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) for details and source links.

iPhone, Mac, macOS, Finder and iOS are trademarks of Apple Inc.
