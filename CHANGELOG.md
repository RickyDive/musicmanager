# Changelog

All notable changes to **Music Manager** are listed here, newest first. Versions before 2.1 Beta 1 were internal builds (the project was called *Garmin Music Manager*); they are summarised at the end.

Music Manager is an independent project, not affiliated with or endorsed by Garmin or Apple.

## 2.1 Beta 3 — build 15 (in testing)

Theme: understanding streaming services (Spotify, Amazon Music, Deezer…) installed on the watch, and showing storage honestly.

### Added
- **Storage bar rebuilt** with five segments — *System*, *Data*, *Maps*, *Services*, *Music* — plus the striped "incoming" segment and free space.
  - *Services* adds up the cache size of every installed streaming app, read from `GarminDevice.xml`.
  - *System* is an estimate of what the MTP tree cannot show (OS, firmware, overhead).
- Mouse-over tooltips on every segment of the bar with its name and size; the legend now shows names only.
- Dynamic legend: an entry (and its segment) appears only if the category takes at least 1 MB — no maps on the device, no Maps entry.
- "xx GB free of yy GB" moved above the bar, top left.
- **Album and artist "on device" arrow**: a green arrow on the header of an album or artist when all its transferable tracks are already on the watch.
- **Help ▸ Save GarminDevice.xml (diagnostics)** and **Help ▸ Save device tree (diagnostics)**: read-only snapshots to help investigate how a watch uses its storage.
- **Device File Manager** (opt-in, *Settings ▸ Advanced ▸ Tools*, off by default): sortable Name / Kind / Size / Modified columns, clickable breadcrumb, "Copy path", marks on files created by Music Manager or by recognised apps and streaming services, and **Copy to Mac…**. Read-only on the device.
- New app icon artwork prepared (coral *Music* card with audio bars → green *Device* card on a grey gradient), to be integrated before the public 2.1.

### Changed
- The **Send** button is disabled when the selected tracks do not fit in the free space.
- Lighter grey for the *System* segment; Music/Maps/Services colours unchanged.

### Fixed
- **Flickering menu bar** while tracks were being prepared for sending (the Edit menu briefly reappeared): menus no longer observe the whole view model.
- Removed a duplicate bridging header left over from the old project name.

### Findings (no code change)
- Streaming services do **not** use the `Music/` folder; their content is invisible to MTP and tracks the `MediaCacheSize` value in `GarminDevice.xml`. The only interaction with Music Manager is competition for free space.

---

## 2.1 Beta 2 — build 14 (closed 2026-10-15)

### Added
- **Garmin devices that mount as a disk** (e.g. Edge): recognition, model, software, volume space, maps, serial number, "No music" capsule and an **Eject** button. No transfer yet.
- **Genre filter** and **Find similar** (right-click on a track, album, artist or playlist; scored by shared playlists, artist, genre, album, year and BPM; at most 3 tracks per artist; fewer plays first on ties).
- Manual choice of the **product picture** (context menu on the picture).
- **Delete confirmation sheet** listing the tracks to remove and the playlists affected; affected playlists are rewritten without the deleted tracks and emptied ones are removed. Buttons: Clear Selection, Delete, Delete All.
- Multi-disc albums show **"Disc n of m"** headers; track numbers and durations also in the Device panel.
- Mini player: status icons next to the title, and a context menu on the cover (*Send to Custom*, *Send to watch*).
- Selection checkboxes on the left, an "on device" status column on the right; selection shared across tabs; drag-to-select in Songs.
- Right-click **Copy** on the serial number; device status dot in the Devices table.
- Settings: unified look across tabs, selection colour with a tone slider, "Reset all settings".
- Legal text, third-party licenses and library versions bundled in the app.

### Changed
- App renamed **Music Manager** (GitHub name); data folders and the playlist folder in Music are migrated automatically.
- **All settings are global** (per-device profiles removed).
- Reduced menu set (no Edit menu); menus follow the chosen language.
- Storage bar: macOS-Storage-style colours, separators between segments, free space shown *after* the selection.
- Sending from the Playlists tab with a partial selection now asks what to do instead of sending loose tracks.
- Selection is cleared after every successful transfer.
- Playlist verification after sending is more tolerant (normalised lines) and logs the reason when it fails.

### Fixed
- Wrong "N playlists not updated" warning after deleting tracks.
- Maps icon missing for the fēnix 9 Pro in Settings; maps icon shown for watches without maps (e.g. Forerunner 255).
- Menu text not following the language; extra *Format* menu appearing.
- Artist names such as *AC/DC* matched correctly between the library and the watch.
- Bundled libmtp/libusb now declare macOS 26.0 as their minimum, so the app can start on macOS 26 even when built on macOS 27.

### Known issues
- Slow or blocked first launch on macOS 27 for a quarantined, non-notarized app — clear the flag with `xattr -cr "/Applications/Music Manager.app"` (see `docs/INSTALL.md`).

---

## 2.1 Beta 1 — build 13 (first public pre-release)

- Distributed as a **DMG on GitHub Releases**, with a `.sha256` file; libmtp and libusb **bundled** (Homebrew no longer required), ad hoc signed, not notarized.
- **Help menu**: copy diagnostic information, show log in Finder, send feedback, third-party licenses; log in `~/Library/Logs/MusicManager/`; welcome message on first launch.
- License GPL v3.0; scope statement in `docs/SCOPE.md`.

---

## Earlier internal builds (1.0 – 2.0.1)

### 2.0.1
- Storage bar: the "+ size" label of the selection sits above the bar.
- Device detection polls every 5 s; after sending, the `.m3u8` is verified on the device and the playlist track count re-read; playlist tracks matched by full path.
- Real artist/album names (AC/DC, not AC_DC) on the watch; new app icon; playlist filter "Smart or Genius only"; storage selector only when the device has more than one.

### 2.0 (final) and 2.0 betas
- **Maps (informational)**: per-device `Maps.json`, "maps changed" and 90-day re-check proposals, red/green map icon.
- **Software update check** (opt-in) with a table of registered devices; local copy of `GarminDevice.xml` per device.
- **Serial number** and official product picture from Garmin's unit-info service.
- **Music-capable detection** and accepted formats read from `GarminDevice.xml`; devices without music are read-only.
- **Drag & drop of audio files** onto the device panel: import panel modelled on Music's *Details*, files added to Music if missing, transferred through a *Direct Copy* playlist.
- Fix Artwork can apply a cover to the rest of the album; "Show only songs without cover" filter.
- Type-to-select in lists, per-tab search, "Edit in Custom" for device playlists, list text size, window opacity, Light/Dark/System previews, selection colour swatches.
- Code cleanup; minimum macOS raised to 26.0.

### 1.6 (1.5.1 – 1.6.2)
- **Remote libraries** (up to three, from an exported XML plus mounted media), local/other-network icons.
- Artists tab organised as album artist ▸ album ▸ tracks; "Go to album / artist".
- Custom Playlist: save/load M3U8, merge modes, save to Music, sort *Random*, one Load/Save button.
- Several playlists can be sent at once; missing-artwork pre-check before sending; transfer summary by artwork origin.
- Fixes: folder-creation error 2002 on already existing folders; multi-playlist send; AirPlay volume.
- Redesigned About panel; window width fixed, height free.

### 1.5 and 1.4
- Artwork origin and "already on watch" icons; striped "incoming" segment in the storage bar; deletion progress window; per-row selection in Playlists; non-transferable tracks (cloud-only, DRM, Hi-Res) clearly marked and unselectable; deleting device playlists with protection of tracks shared with other playlists; Custom Playlist redesigned as a tree; window opacity; audio-output icon in the mini player.

### 1.3
- **Liquid Glass** interface; product picture of the watch in the device panel; device data from `GarminDevice.xml`; Light/Dark/System appearance; volume, AirPlay, shuffle and repeat in the mini player; playback from playlists, artists and albums.

### 1.2
- **Fix Artwork** (online cover candidates, direct MP4 `covr` editing), context menus, local TEMP preparation with a summary window before sending, USB unplug detection, automatic connection.

### 1.1
- Custom Playlist (select/deselect with a single "Send to Playlist" action), save to Music with conflict handling, Manual ordering, whole-playlist send keeping order, automatic connection at launch.

### 1.0
- First working version: MTP connection, library and device browsing (Playlists / Artists / Albums / Songs), sending with verification and no duplicates, playlists recreated from scratch, mini player, storage bar, Italian and English interface.
