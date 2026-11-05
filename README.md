# iSync

iSync is a personal macOS app for moving photos, music and files between a Mac
and an iPhone over USB, with Wi-Fi to follow. It is built for one owner and is
installed directly rather than through the Mac App Store.

## Scope

- **Photos:** copy originals from the iPhone to a Mac folder, quickly and
  without format conversion. Add photos from the Mac to iSync albums on the
  iPhone.
- **Music:** copy songs from the iPhone with their tags. Add your own non-DRM
  audio files to the Music app.
- **Files:** browse and transfer the Documents folders of apps that allow file
  sharing.
- **Later:** full encrypted backup and restore, then Wi-Fi for every feature.

iSync moves data between a Mac and an iPhone. It does not transfer directly
from one iPhone to another.

## Status

**Version 0.2.** The app detects iPhones as they're plugged in. It copies photos and
music to Mac folders like `rsync`: it shows a dry run first, then copies only what's
missing, with a choice of skipping duplicates or overwriting. It also moves files in
and out of apps that allow file sharing, and can compare what two iPhones hold.

Adding photos and music to an iPhone isn't in this version. It depends on a sync test
that hasn't run yet. See [the step 1 report](docs/step1-report.md).

## Platforms

macOS 27.2 on Apple Silicon. iPhone 16 Pro Max on iOS 27.2 has been tested.

## Build and run

You need Xcode and Homebrew.

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

You don't need to move the app to `/Applications`, but it also works from there.

`iSync.xcodeproj` is generated from `project.yml`, so it isn't in the repo. Run
`xcodegen generate` again after adding files or changing `project.yml`.

## Tests

```bash
cd iSyncCore && swift test
```

`isync-check` runs the real engine on a connected iPhone. The `files` command puts
uniquely named test files in the chosen app's Documents folder, then deletes them.

```bash
cd iSyncCore && swift run isync-check info
```

```bash
cd iSyncCore && swift run isync-check photos --dest /tmp/isync-test --limit 50
```

```bash
cd iSyncCore && swift run isync-check files
```

## How photo copying works

**Originals only.** Files come straight from the iPhone's `/DCIM` folder with no
conversion. Edits made in the Photos app aren't applied, because iOS stores them
elsewhere. `.AAE` edit files are copied, but they aren't the edited photos.

**A dry run comes first.** Every file falls into exactly one group:

| Group | What it means | Skip duplicates | Overwrite |
|---|---|---|---|
| New | Not at the destination | Copied | Copied |
| Already copied | Done by an earlier run, or already at its path | Skipped | Copied again, replacing the file |
| Exact duplicate | Same bytes under another name, or twice on the phone | Skipped | Skipped |
| Same name, different content | A different file has this name | Kept, with a number added | Replaces the file |
| Possible duplicate | Same capture time and dimensions, different bytes | Copied and listed | Copied and listed |

Nothing is ever deleted except a file that Overwrite replaces at the same path.

**Duplicates are found by content, not by name,** because one photo has different
`IMG_` names on different phones.

1. Size, capture time and dimensions nominate candidates. These come from the phone's
   `Photos.sqlite` and from each Mac file's EXIF or QuickTime data, so most files don't
   need reading. If a detail is missing, it doesn't rule out a match.
2. SHA-256 decides. A file is only skipped once its hash is confirmed, and an unconfirmed
   match has no effect on where other files go. Hashes are cached, so each file is read
   for hashing once.
3. Only photos and videos are matched. Sidecars such as `.AAE` are often byte-identical
   across different photos, so they simply follow their photo.

**Other details:**

- **Archive folders.** You can list other Mac folders to check for duplicates. iSync only
  reads them, and keeps its index of them in `~/Library/Caches/iSync`.
- **Repeat runs skip finished files.** A manifest in `.isync` inside the destination folder
  records each file's path, size, date and hash. Each iPhone has its own manifest.
- **Files removed from the Mac folder are copied again** on the next run.
- **Live Photos stay together.** Files with the same name in the same iPhone folder are
  copied on one connection and placed side by side, even in the year and month layout.
- **Sizes are checked.** A file gets its real name only after its size matches.

## Comparing two iPhones

With two iPhones plugged in, the Photos page shows how many photos the other phone already
has. It reads each phone's `Photos.sqlite` and file list, compares capture time, dimensions
and size, and changes nothing on either phone. Hashing isn't needed for this overview, so it
doesn't have to read the whole library over USB. SHA-256 would confirm matches before any
transfer.

## Music

The Music page reads the phone's `MediaLibrary.sqlitedb` and copies tracks from
`/iTunes_Control/Music` to a Mac folder as `Artist/Album/NN Title.ext`. Files are copied
byte for byte, so their tags and artwork are preserved. Tracks marked as protected, or
stored as Apple Music content, are listed but not copied. Tracks with no artist or album in
the library go in `Unknown Artist` and `Unknown Album`.

## Project layout

| Path | Contents |
|---|---|
| `iSyncCore` | Swift package: device layer, photo copy engine, tests and `isync-check` |
| `iSyncApp` | SwiftUI app |
| `project.yml` | XcodeGen project definition |
| `Tools/iSyncProbe` | The step 1 feasibility tool |
| `docs` | Reports |

## Signing and libraries

The app is ad-hoc signed to run on this Mac, with no App Sandbox and no hardened
runtime. It links Homebrew's libimobiledevice and libplist from `/opt/homebrew`, so
it needs those packages installed. A `brew upgrade` that changes their versions can
stop the app from launching until you rebuild it.

To bundle the libraries later:

1. Copy `libimobiledevice`, `libimobiledevice-glue`, `libplist`, `libusbmuxd` and
   OpenSSL's `libssl` and `libcrypto` into `Contents/Frameworks`.
2. Rewrite their install names and references to `@rpath` with `install_name_tool`.
3. Re-sign each library and then the app, because rewriting breaks their signatures.
4. Check that nothing still points at Homebrew with `otool -L`.

Those libraries are LGPL or Apache licensed, so check their terms before sharing a
bundled build with anyone else.
