# Music Manager

🇬🇧 English · [🇮🇹 Italiano](README_ITA.md)

A macOS app that transfers music, albums and playlists from the **Music** app library to a **Garmin** watch (Fenix, Forerunner, Edge…) over USB (MTP), and manages what is on the watch.

> **Version 2.2.** Feedback is welcome: open an [Issue](https://github.com/RickyDive/musicmanager/issues/new/choose).
> Independent project, not affiliated with or endorsed by Garmin or Apple.

> **Scope:** music flows one way, from your Mac library to the device. The app never copies audio from a device and does not access other devices' libraries. See [docs/SCOPE.md](docs/SCOPE.md).

## Requirements
- **Apple Silicon** Mac, **macOS 26** or later
- Garmin watch with music support, USB cable
- DRM-free tracks in mp3 / m4a / aac

## Installation
Download the DMG from the [Releases](https://github.com/RickyDive/musicmanager/releases) page and follow **[docs/INSTALL.md](docs/INSTALL.md)**.
The app is not notarized (I don't have an Apple Developer account): on first launch macOS blocks it. The most reliable way to open it is one Terminal command, `xattr -cr "/Applications/Music Manager.app"` (the *System Settings ▸ Privacy & Security ▸ Open Anyway* route can hang on macOS 27). libmtp and libusb are bundled: **Homebrew is not required**.

## Main features
- Browse the Music library (Playlists / Artists / Albums / Songs) and see which tracks can be transferred.
- Reads the watch's `Music` folder with the same organization (Songs, Albums, Artists, Playlists).
- Sends tracks, albums, artists or whole playlists using an `Artist/Album/track` layout, verifies every file arrived and skips what is already there.
- `.m3u8` playlists are recreated from scratch and verified on the device after sending.
- **Custom Playlist**: build a playlist from any tab, save it to a file or to Music, send it to the watch.
- Storage bar (System, Data, Maps, Services, Music, incoming selection) with tooltips; streaming-service storage is detected, never touched.
- Artwork, mini player with AirPlay, remote libraries (SMB), deletion and cleanup of the Music folder.
- **External Drive Libraries**: browse and send music kept in a folder on a USB drive, disk or network folder, with the app's own index (only formats your Garmin accepts; nothing is written to your files).
- **Right-click menus** for every context: songs (full menu: Send to Custom / Device, Artwork Online Fix, Go to Album / Artist, Find Similar, Show in Playlist), playlist / album / artist headers (two Send rows naming the item and its song count) and the whole mini player. Subtitles show how many songs can actually be sent, e.g. "2 albums / 37 songs (6 transferable)".
- Mini player: mute button that remembers the previous volume.
- All dialogs (Fix Artwork, transfer report, Find Similar, delete, send summary…) are centred glass panels.
- Notification bell: the dot shows the most severe unread message (red = error, orange = warning).
- Network libraries (SMB): mounted at launch (3 attempts, only if the server answers), with the real server host saved so it works even when the share name does not resolve; unreachable servers show an orange (offline) or red (no server) notice instead of a system dialog.
- Interface in English and Italian.

## Reporting a problem
Menu **Help ▸ Copy Diagnostic Information**, then open an [Issue](https://github.com/RickyDive/musicmanager/issues/new/choose) and paste the text. Also: *Help ▸ Show Log in Finder*. Scenarios to try: [docs/TESTING.md](docs/TESTING.md).

## If the watch is not detected
1. Quit Garmin Express, Garmin Connect, OpenMTP, Android File Transfer, Image Capture.
2. Unlock the watch and set USB mode to MTP / "Storage".
3. Unplug and reconnect the cable.

## Building from source
```bash
brew install libmtp libusb xcodegen
xcodegen generate
open MusicManager.xcodeproj
```
To build the DMG: `Scripts/build-release.sh` (see [docs/RELEASING.md](docs/RELEASING.md)).

## Privacy
The app sends no data to servers of its own. Optional feature (off by default): the software update check asks Garmin's servers whether a new version exists, sending the contents of `GarminDevice.xml` through an undocumented service.

## What is new in 2.2
- **External Drive Libraries** (Settings ▸ Advanced, up to 3): a folder of audio files on a USB drive, disk or network folder becomes a library, with its own index built from the tags. Only formats your Garmin accepts are kept; FLAC, WAV, AIFF and ALAC are shown but cannot be sent. Incremental rescan, covers from the files, **Eject** button.
- **Remote (network) libraries**: more reliable mounting (the server is checked first, no long waits or system errors), the **Mount automatically** switch and a three-state status dot, live progress of the first XML read, a warning when the XML on the server has changed, playback with loading and slow-connection detection, and unmount of the volumes the app mounted when it quits.
- **Music and artwork**: a question before adding songs to Music (Settings ▸ General), a redesigned online artwork panel, faster start (saved file paths, library re-read when you return to the app), a *Threads to read the library* option, duplicates listed with a checkbox for each song.
- **Interface**: floating glass bars, an Xcode-style title bar with an activity capsule, one refresh and one search (⌘F), a notification bell, centred glass dialogs, a compact mode for low resolutions, richer right-click menus and mini player, one rounded selection highlight, typing in lists with the typed text in the letter indicator, three Settings tables with the same layout, revised Italian texts and a new icon.

**Good to know:** with remote libraries the first read is slow and later opens are instant; typing in lists positions only on the first letter there, so use the magnifier search. With two shares of the same name the Finder can keep an empty "ghost" entry after unmounting (`killall Finder` or a restart clears it). The software update check follows Garmin's staged distribution, as Garmin Express does.

**Known limits:** not tested on macOS 26 (developed and tested on macOS 27); not notarized (see [docs/INSTALL.md](docs/INSTALL.md) if the first launch is blocked); lossless formats are not converted or sent; playlists found in a drive folder are not imported; no remote control of the app from the Apple TV; very old AirPlay receivers may be refused by macOS itself.

Full history: [CHANGELOG.md](CHANGELOG.md). Release text: [docs/RELEASE-NOTES-2.2.md](docs/RELEASE-NOTES-2.2.md).

## License and official version
Music Manager is free software, released under the **GNU GPL v3.0** ([LICENSE](LICENSE) file). Copyright (C) 2026 Riccardo Colaiori (cr.developer).
- You may use, study and modify the code; if you distribute a modified version you must publish its source under the same license.
- **Official version:** the only official channel is the [Releases](https://github.com/RickyDive/musicmanager/releases) page of this repository. Always compare the DMG's hash with the attached `.sha256` file (`shasum -a 256 <file>.dmg`).
- Modified and redistributed versions must use a different name and must not present themselves as official or as endorsed by the author.
- Changes are proposed through a Pull Request; the author reviews and accepts them.

Bundles **libmtp** and **libusb** (LGPL 2.1+), dynamically linked: see [licenses/](licenses/README.md). Technical notes: [docs/PROJECT-NOTES.md](docs/PROJECT-NOTES.md).
