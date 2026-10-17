# Music Manager

🇬🇧 English · [🇮🇹 Italiano](README_ITA.md)

A macOS app that transfers music, albums and playlists from the **Music** app library to a **Garmin** watch (Fenix, Forerunner, Edge…) over USB (MTP), and manages what is on the watch.

> **Version 2.1 Beta 3** — testing phase. Feedback is welcome: open an [Issue](https://github.com/RickyDive/musicmanager/issues/new/choose).
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

## What is new in 2.1 Beta 3
- Storage bar rebuilt: *System*, *Data*, *Maps*, *Services* (streaming apps such as Spotify, Amazon Music, Deezer), *Music*; tooltips with sizes, dynamic legend, free space above the bar.
- Send is disabled when the selection does not fit in the free space.
- Green "on device" arrow on album and artist headers when all their transferable tracks are already on the watch.
- Help ▸ Save GarminDevice.xml / Save device tree (read-only diagnostics); optional Device File Manager (Settings ▸ Advanced ▸ Tools, off by default).
- Shift-click range selection in all Music tabs; drag-to-select in Songs.
- Sending several playlists: the transfer window lists every playlist with its outcome and shows the total.
- Flat buttons (no glass), a new app icon, and map files tagged with the map name in the Device File Manager.
- Fixed the flickering menu bar while tracks are being prepared.

Full history: [CHANGELOG.md](CHANGELOG.md).

## What was new in 2.1 Beta 2
- Genre filter, "Find similar", Garmin devices mounted as volumes (recognition), manual choice of the product image.
- Music lists: selection checkboxes on the left, "on device" status icon in the selection column; multi-disc albums with "Disc n of m" headers; the Device list shows track numbers and durations.
- Device panel: Clear Selection, Delete and Delete All buttons; Delete opens a detailed confirmation listing the songs and the playlists involved, and rewrites those playlists without the deleted songs (playlists left empty are removed from the device).
- Settings: unified look across all tabs, selection colour with tone slider, connected-device indicator, Copy for the serial number.
- All settings are now global (no more per-device profiles).
- Known issue under investigation: slow or blocked first launch on macOS 27 (see `docs/INSTALL.md` and `docs/TESTING.md`).

## License and official version
Music Manager is free software, released under the **GNU GPL v3.0** ([LICENSE](LICENSE) file). Copyright (C) 2026 Riccardo Colaiori (cr.developer).
- You may use, study and modify the code; if you distribute a modified version you must publish its source under the same license.
- **Official version:** the only official channel is the [Releases](https://github.com/RickyDive/musicmanager/releases) page of this repository. Always compare the DMG's hash with the attached `.sha256` file (`shasum -a 256 <file>.dmg`).
- Modified and redistributed versions must use a different name and must not present themselves as official or as endorsed by the author.
- Changes are proposed through a Pull Request; the author reviews and accepts them.

Bundles **libmtp** and **libusb** (LGPL 2.1+), dynamically linked: see [licenses/](licenses/README.md). Technical notes: [docs/PROJECT-NOTES.md](docs/PROJECT-NOTES.md).
