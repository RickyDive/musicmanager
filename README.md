# Music Manager

🇬🇧 English · [🇮🇹 Italiano](README_ITA.md)

A macOS app that transfers music, albums and playlists from the **Music** app library to a **Garmin** watch (Fenix, Forerunner, Edge…) over USB (MTP), and manages what is on the watch.

> **Version 2.1.** Feedback is welcome: open an [Issue](https://github.com/RickyDive/musicmanager/issues/new/choose).
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

## What is new in 2.1
- Music and device: genre filter and "Find similar"; multi-disc albums with "Disc n of m" headers; selection checkboxes and an "on device" status; green "on device" arrow on albums and artists; Shift-click range selection and drag-to-select.
- Sending: several playlists at once with a per-playlist transfer window, mixed sends (whole playlists plus loose songs) and a **Cancel** button that stops the send and shows what was and was not sent. Send is disabled when the selection does not fit.
- Delete: a confirmation sheet lists the songs and the playlists involved; affected playlists are rewritten without them.
- Storage bar: *System*, *Data*, *Maps*, *Services* (Spotify, Amazon Music, Deezer…), *Music*; free space written inside the bar, a *Storage Capacity* row, and an orange or red warning when the space is almost gone.
- Player and AirPlay: volume that works with Apple TV, HomePod and amplifiers ("AirPlay as audio", on by default), the in-app slider follows the AirPlay device, and the Apple TV shows cover, artist and title (Now Playing); media keys and Control Center work.
- Garmin devices mounted as a disk (e.g. Edge): information and Eject. **Experimental, off by default**: music on external drives and SD cards (Settings ▸ Advanced ▸ Tools).
- Settings ▸ Advanced ▸ Tools: optional Device File Manager (read-only), detailed log switch with *Show Log File*; Help ▸ Save GarminDevice.xml / Save device tree.
- Faster start: the Music library is read in parallel. All settings are global; flat buttons and a new icon; the app is now called **Music Manager**.

**Known limits:** not tested on macOS 26; not notarized (see [docs/INSTALL.md](docs/INSTALL.md) if the first launch is blocked); no remote control of the app from the Apple TV; very old AirPlay receivers may be refused by macOS itself.

Full history: [CHANGELOG.md](CHANGELOG.md).

## License and official version
Music Manager is free software, released under the **GNU GPL v3.0** ([LICENSE](LICENSE) file). Copyright (C) 2026 Riccardo Colaiori (cr.developer).
- You may use, study and modify the code; if you distribute a modified version you must publish its source under the same license.
- **Official version:** the only official channel is the [Releases](https://github.com/RickyDive/musicmanager/releases) page of this repository. Always compare the DMG's hash with the attached `.sha256` file (`shasum -a 256 <file>.dmg`).
- Modified and redistributed versions must use a different name and must not present themselves as official or as endorsed by the author.
- Changes are proposed through a Pull Request; the author reviews and accepts them.

Bundles **libmtp** and **libusb** (LGPL 2.1+), dynamically linked: see [licenses/](licenses/README.md). Technical notes: [docs/PROJECT-NOTES.md](docs/PROJECT-NOTES.md).
