# Changelog

All notable changes to **Music Manager** are listed here, newest first. Versions before 2.1 Beta 1 were internal builds (the project was called *Garmin Music Manager*); they are summarised at the end.

Music Manager is an independent project, not affiliated with or endorsed by Garmin or Apple.

## 2.1 Beta 3 — build 15 (in testing)

Theme: understanding streaming services (Spotify, Amazon Music, Deezer…) installed on the watch, and showing storage honestly.

### Added
- **Storage bar rebuilt** with five segments — *System*, *Data*, *Maps*, *Services*, *Music* — plus the striped "incoming" segment and free space.
  - *Services* adds up the cache size of every installed streaming app, read from `GarminDevice.xml`.
  - *System* is an estimate of what the MTP tree cannot show (OS, firmware, overhead).
- Instant mouse-over balloon (above the bar) on every segment with its name and size (no system tooltip delay); the legend now shows names only.
- Dynamic legend: an entry (and its segment) appears only if the category takes at least 1 MB — no maps on the device, no Maps entry.
- "xx GB free of yy GB" moved above the bar, top left.
- **Album and artist "on device" arrow**: a green arrow on the header of an album or artist when all its transferable tracks are already on the watch.
- **Help ▸ Save GarminDevice.xml (diagnostics)** and **Help ▸ Save device tree (diagnostics)**: read-only snapshots to help investigate how a watch uses its storage.
- **Device File Manager** (opt-in, *Settings ▸ Advanced ▸ Tools*, off by default): sortable Name / Kind / Size / Modified columns, clickable breadcrumb, "Copy path", marks on files created by Music Manager, by recognised apps and streaming services, and on map files (tagged with the map name, e.g. "TopoActive Western Europe"; the files that belong to each map are recorded at the next maps check, in the colour of the Maps segment of the storage bar), and **Copy to Mac…**. Read-only on the device.
- **New app icon**: icon bundle made in Icon Composer by the author (`AppIcon.icon`), to be refined later.

### Changed
- **Cancel during a transfer**: while sending, the transfer window shows a red **Cancel** button (xmark icon, same size as the buttons of the main panels) where *Close* is (Close comes back when the send is over). Clicking it does not stop anything yet: the send goes on while a panel asks *Confirm* (stop) or *Continue*. After *Confirm* the send finishes the file in progress and stops; the window says the send was stopped before completion, that not all the files were transferred and that incomplete playlists were not sent (their `.m3u8` is not created or touched; songs already copied stay on the watch). The selection is kept so you can change it and send again. The existing `.m3u8` of a playlist is now deleted only right before the new one is written, not before the songs are copied.
- **Whole playlists are remembered across tabs, and mixed sends work**: if you pick one or more whole playlists and then change tab (or add artists, albums and songs from other tabs), *Send* still creates each playlist's `.m3u8`; the other tracks are copied as loose songs and appear in the transfer window as a last row, **Single songs**. If, from another tab, you deselect a song that belongs to a selected whole playlist (leaving others of it selected), a warning asks (worded for the tab you are in: *the artist “X”* in Artists, *the album “Y”* in Albums, *the song “Z”* in Songs — or *N songs* when only part of an artist/album is removed): **Confirm** removes the song and the playlist is no longer sent as a playlist (no `.m3u8`); **Cancel** restores the song and the playlist. The same warning appears in the Playlists tab when you untick a song of a playlist that was selected whole. No question is asked when you start by picking single songs, when you deselect all the songs of a playlist, or when you clear the selection. After **Confirm** the summary reads *1 playlist for a total of …* (the playlists still whole) over *N songs for a total of …* (all the selected songs).
- **Selection summary** (bar at the bottom of the Music panel) now always ends with *N songs for a total of …* (songs counted once, even when shared between playlists, which is the real amount sent), with a first row that depends on the tab: *N playlists for a total of …* (Playlists tab, two or more playlists, summed in full), *N artists* (Artists tab) or *N albums* (Albums tab), counted like the lists group them. The Songs tab shows only the songs row.
- Buttons: *Send to Custom* is now **To Custom**; the arrow of **Send** sits after the label to point towards the device.
- **Sending several playlists at once**: the transfer window now keeps a list of the playlists, one row each — *Transferring* for the current one, then *Transferred*, *Partially* (some tracks failed) or *Check* (nothing arrived) with copied / already present / error counts. The summary at the bottom shows the whole multi-playlist transfer: the selected-tracks total is known from the start (e.g. 186), while copied / already present / errors grow as playlists finish. The playlist list always shows up to four complete rows (no partial row cut off), then scrolls. The window no longer closes and reopens between playlists.
- **Flat buttons everywhere**: the Liquid Glass effect is gone from all buttons; they share one flat capsule style (light grey; red-tinted with red text for destructive ones such as *Delete All*, like the system *Confirm*; accent colour for the main action). Panels keep their glass.
- The **Send** button is disabled when the selected tracks do not fit in the free space.
- **Fix Artwork no longer opens by itself** when you select a song without a cover: only the (optional) load of the cover from Apple Music is attempted; the online search stays in the right-click menu.
- **Fix Artwork window** redesigned like the dropped-files panel: grey header with the original and online covers (150 pt) and the song data, arrows over the online cover (double chevron when more than one cover is left in that direction), Close at the bottom left, chevrons with *Song n of N* in the centre (only with several songs), Skip / Skip All / Confirm at the right.
- Lighter grey for the *System* segment; Music/Maps/Services colours unchanged.

### Fixed
- Quit with an unsaved Custom Playlist: the confirmation is now a lighter window like "Clear the playlist?" (no warning icon, name field, three standard-size buttons on one row: Save to File, Quit, Cancel).
- Send to device window: rows are shorter (vertical padding 8 → 4 pt).
- "Clear the playlist?" confirmation: no warning triangle; the three buttons (Save to File, Confirm Clear with the trash icon, Cancel) sit on one row at the same size as the main bar buttons.
- Custom Playlist: choosing **Add** (without emptying) when sending a whole playlist to a Custom that already has tracks no longer renames the Custom to "<playlist>_copy"; the name is left as the user set it (or empty). **Empty and send** still names it "<playlist>_copy".
- Custom Playlist: selecting everything in Artists, Albums or Songs and sending it to the Custom no longer names the Custom after a playlist that happens to be contained in the selection (e.g. "WDW Dopey_copy"); the name is set automatically only when copying from a playlist chosen in the Playlists tab.
- Custom Playlist bar: **Send** is now the last button on the right (like the other panels) and **Clear** is the third button after *Save to Music*; Send is disabled (red) when the Custom Playlist would not fit in the free space.
- Storage bar: in the Custom tab the "+ n GB" stripe shows only the space the Custom Playlist would occupy (tracks not already on the device), not the selection made in other tabs.
- Custom Playlist header now also shows the total size of its files after the duration (e.g. "1042 tracks, 78 hours, 7 minutes / 5.3 GB").
- Device Albums/Artists tabs: an album whose tracks have different artists (e.g. guests) is now a single album under its album artist, as in Music. The album artist and Compilation flag are read from the matching file in the Music library.
- **Send to device window (check step)**: the divider lines between tracks showed only under the right-hand column and were offset; the list now draws a full-width line between rows and the artwork-source label is vertically centred on its row.
- **Send to device window**: the confirm button at the bottom is now **Proceed** (it was *Send to watch*, redundant with the window title).
- **Flickering menu bar** while tracks were being prepared for sending (the Edit menu briefly reappeared): menus no longer observe the whole view model.
- Removed a duplicate bridging header left over from the old project name.
- **Double-click to play** (tracks, albums, artists, playlists, *Find similar*) stopped working after the selection change; it is detected again.
- **Shift-click range selection**: click a song (or an album / artist / playlist header or track), then Shift-click a distant one to select (or deselect) everything in between. In Albums, Artists and Playlists the range follows the rows currently visible (open groups only).
- **Drag-to-select in Songs** works again (press on a song and drag to select or deselect the range, with auto-scroll at the edges).

### Known issues
- Map files in the Device File Manager are tagged with the map name only after a **maps check** has recorded the files of each installed map: with a `Maps.json` written by an older build, press the check button next to "Checked …" in the Maps window once. Map data files that Garmin does not attribute to a map show as "Map data".
- The transfer window's list of playlists uses an estimated row height (four rows shown without scrolling); it may need a small adjustment.

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
