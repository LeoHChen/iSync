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

Step 1 is a feasibility test. `Tools/iSyncProbe` is a command-line tool that
checks which device protocols work on the target iOS version. There is no app
yet.

## Platforms

macOS 27.2 on Apple Silicon. iPhone 16 Pro Max and iPhone 18 Pro Max on iOS 27.2.
