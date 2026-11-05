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

**Version 0.1.** The app detects iPhones as they're plugged in, copies photos to
a Mac folder, and moves files in and out of apps that allow file sharing.

Adding photos and music to the iPhone isn't in this version. It depends on a sync
test that hasn't run yet. See [the step 1 report](docs/step1-report.md).

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

- **Originals only.** Files come straight from the iPhone's `/DCIM` folder with no
  conversion. Edits made in the Photos app aren't applied, because iOS stores them
  separately.
- **Repeat runs skip finished files.** A manifest in `.isync` inside the destination
  folder records each file's path, size and date. Each iPhone has its own manifest.
- **Files removed from the Mac folder are copied again** on the next run.
- **Nothing is overwritten.** A different file with the same name gets a numbered
  name, such as `IMG_0001 (2).HEIC`.
- **Live Photos stay together.** Files with the same name in the same iPhone folder
  are copied on one connection and placed side by side, even in the year and month
  layout.
- **Sizes are checked.** A file gets its real name only after its size matches.

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
