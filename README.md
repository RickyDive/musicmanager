# Music Manager

🇬🇧 English · [🇮🇹 Italiano](README_ITA.md)

A macOS app that transfers music, albums and playlists from the **Music** app library to a **Garmin** watch (Fenix, Forerunner, Edge…) over USB (MTP), and manages what is on the watch.

> **Version 2.5.** Feedback is welcome: open an [Issue](https://github.com/RickyDive/musicmanager/issues/new/choose).
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

## What is new in 2.5
- **MusicManager Server**: read a Music library from another Mac through a compact `library.json`, no XML to export by hand (macOS 12 or later on the server side).
- **Podcasts**: send the episodes you already downloaded in Apple Podcasts to the watch (MP3 only; nothing is downloaded).
- **Fix Artwork**: the online search goes through the artist's whole discography, offers every edition of an album and ignores «The» / «Best Of» differences; the «songs without cover» filter is faster and never leaves an empty list.
- **Custom Playlist**: PacePro (km per song) with up to 12 splits.
- **Interface**: preview mode in the mini player, Albums quick switch (alphabetical / date added), one «External Sources» table, pill-shaped device bar, redesigned welcome window, experimental user profiles.
- **Direct Copy**: a prompt before duplicating files already in the playlist.

Release text: [docs/RELEASE-NOTES-2.5.md](docs/RELEASE-NOTES-2.5.md).

## What is new in 2.3
- **Speed with very large libraries**: measured on a 55,000-song network library, freezes of 1–15 s on clicks became mostly under 1 s, memory stays around 400–700 MB instead of reaching 1.6 GB, and typing to jump in a list went from 7–15 s to 0.01–0.2 s. A *Detailed log* option in Settings records timings for diagnostics.
- **Playlists**: the same folders as in Apple Music (local library), a thumbnail for every playlist, and *Send* offers to add the songs to the playlist selected on the watch.
- **Albums, Artists, Songs**: albums by date added, an Artists tab with round thumbnails (Artist ▸ Albums ▸ Songs), typing in lists that ignores leading articles («rolling» finds «The Rolling Stones»), and a text size that also scales the second line.
- **Custom Playlist**: *Artist first* option, ×N badges for repeated artists, albums or songs, clearer selection.
- **Fix Artwork**: up to 10 online candidates, **Revert** to Music's own cover, add a cover by hand (drag and drop or ⌘V), and an «Ignore the whole album?» question.
- **Watch and playback**: an icon marks the songs that are in a playlist on the watch; software and maps update notices; the **Apple TV remote** controls playback; saving to Music runs in batches with a progress capsule and a Cancel button.
- **Licence**: GNU GPL v3 or later notices in every source file, in the About window and in the disk image (`LICENSE.txt`).

**Good to know:** with remote libraries the first read is slow and later opens are instant; typing in lists positions only on the first letter there, so use the magnifier search. With two shares of the same name the Finder can keep an empty «ghost» entry after unmounting (`killall Finder` or a restart clears it). The software update check follows Garmin's staged distribution, as Garmin Express does.

**Known limits:** not tested on macOS 26 (developed and tested on macOS 27); not notarized (see [docs/INSTALL.md](docs/INSTALL.md) if the first launch is blocked); lossless formats are not converted or sent; playlists found in a drive folder are not imported; very old AirPlay receivers may be refused by macOS itself; playlist files as `.m3u` for a device that declares only M3U could not be tested.

Full history: [CHANGELOG.md](CHANGELOG.md). Release text: [docs/RELEASE-NOTES-2.3.md](docs/RELEASE-NOTES-2.3.md).

## License and official version
Music Manager is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License, version 3 or (at your option) any later version** ([LICENSE](LICENSE) file). It comes with no warranty. Copyright (C) 2026 Riccardo Colaiori (cr.developer).
- You may use, study and modify the code; if you distribute a modified version, you must give its recipients the source code under the same license.
- **Official version:** the only official channel is the [Releases](https://github.com/RickyDive/musicmanager/releases) page of this repository. Always compare the DMG's hash with the attached `.sha256` file (`shasum -a 256 <file>.dmg`).
- **Sources:** the source code of every release is in this repository: final releases on the `main` branch (tags `vX.Y`), betas on the `beta` branch (tags `vX.Y-BetaN`). The «Source code» archives on each [Release](https://github.com/RickyDive/musicmanager/releases) page contain exactly the sources of that build.
- Modified and redistributed versions must use a different name and must not present themselves as official or as endorsed by the author.
- Changes are proposed through a Pull Request; the author reviews and accepts them. Contributions are accepted under the same license (GPL v3 or later).
- **Thanks to [mcoliver](https://github.com/mcoliver):** the build and release workflows in `.github/` (build check on pull requests, draft release on tags; GPL v3 or later) are his contribution, and the idea of sending Apple Podcasts episodes to the watch comes from his script [fixPodcastMetadata](https://github.com/mcoliver/fixPodcastMetadata) (MIT licence; no code from it is used).

Bundles **libmtp** and **libusb** (LGPL 2.1+), dynamically linked: see [licenses/](licenses/README.md). Their sources: https://github.com/libmtp/libmtp and https://github.com/libusb/libusb; the versions included are listed in the notes of each release. Technical notes: [docs/PROJECT-NOTES.md](docs/PROJECT-NOTES.md).
