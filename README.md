# Music Manager

🇬🇧 English · [🇮🇹 Italiano](README_ITA.md)

A macOS app that transfers music, albums and playlists from the **Music** app library to a **Garmin** watch (Fenix, Forerunner, Edge…) over USB (MTP), and manages what is on the watch.

> **Version 2.1 Beta 1** — testing phase. Feedback is welcome: open an [Issue](https://github.com/RickyDive/musicmanager/issues/new/choose).
> Independent project, not affiliated with or endorsed by Garmin or Apple.

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
- Storage bar (Garmin, maps, music, incoming selection).
- Artwork, mini player with AirPlay, remote libraries (SMB), deletion and cleanup of the Music folder.
- Interface in English and Italian.

## Reporting a problem
Menu **Help ▸ Copy Diagnostic Information**, then open an [Issue](https://github.com/RickyDive/musicmanager/issues/new/choose) and paste the text. Also: *Help ▸ Show Log in Finder*. Scenarios to try: [docs/TESTING.md](docs/TESTING.md) (Italian).

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
To build the DMG: `Scripts/build-release.sh` (see [docs/RELEASING.md](docs/RELEASING.md), Italian).

## Privacy
The app sends no data to servers of its own. Optional feature (off by default): the software update check asks Garmin's servers whether a new version exists, sending the contents of `GarminDevice.xml` through an undocumented service.

## What is new in 2.1 Beta 2
- Work in progress. Main item: investigating the first-launch hang seen on macOS 27 (see `docs/TESTING.md`).
- App legal text and bundled-library list updated for the GPL v3.0.

## License and official version
Music Manager is free software, released under the **GNU GPL v3.0** ([LICENSE](LICENSE) file). Copyright (C) 2026 Riccardo Colaiori (cr.developer).
- You may use, study and modify the code; if you distribute a modified version you must publish its source under the same license.
- **Official version:** the only official channel is the [Releases](https://github.com/RickyDive/musicmanager/releases) page of this repository. Always compare the DMG's hash with the attached `.sha256` file (`shasum -a 256 <file>.dmg`).
- Modified and redistributed versions must use a different name and must not present themselves as official or as endorsed by the author.
- Changes are proposed through a Pull Request; the author reviews and accepts them.

Bundles **libmtp** and **libusb** (LGPL 2.1+), dynamically linked: see [licenses/](licenses/README.md). Technical history: [docs/NOTE-DI-PROGETTO.md](docs/NOTE-DI-PROGETTO.md) (Italian).
