# Test scenarios

Scenarios to run on a build. For every problem, open a GitHub Issue with the *Bug report* template and paste the diagnostic information (**Help ▸ Copy Diagnostic Information**). The log is in `~/Library/Logs/MusicManager/` (**Help ▸ Show Log in Finder**).

## Core scenarios (2.1 Beta 1)
1. Install from the DMG on a Mac **without** Homebrew (checks the bundled libraries).
2. First launch: Gatekeeper workaround, welcome message, permission to control Music.
3. Watch detection (and, with no watch connected, polling every 5 s).
4. Device catalogue reading (artists / albums / playlists).
5. Send an album and a playlist; check the `.m3u8` file and the track count.
6. An artist with a special character (e.g. AC/DC) is shown correctly.
7. A device with a single storage: the storage selector does not appear.
8. Help menu: copy diagnostics, show log, third-party licenses.
9. Italian / English language.

## If the app does not open or hangs (macOS 27)
1. Use Method A of [INSTALL.md](INSTALL.md) (`xattr -cr`).
2. To understand what is going on: `bash Scripts/diagnose-launch.sh` (creates a file on the Desktop) and attach it to the Issue.
3. Try turning the network off (Wi-Fi off) and reopening: if it starts, macOS was waiting for Apple's servers.

## Garmin devices mounted as a volume — phase 1, recognition only (2.1 Beta 2)
With a device that mounts as a disk (e.g. Edge) or with the test disks (`Scripts/make-test-volume.sh`):
1. Real Edge: the Device panel shows model, software version, volume name and space, the "No music" capsule and an **Eject** button.
2. `make-test-volume.sh music`: recognised, without the "No music" capsule.
3. `make-test-volume.sh nomusic`: recognised, with the capsule.
4. `make-test-volume.sh notgarmin` and `badxml`: ignored (the panel keeps the "Connect your watch…" message).
5. Any ordinary USB stick: ignored.
6. Eject: the volume disappears and the status line says the cable can be unplugged.
7. An MTP watch connected together with an Edge: the watch works as before.
8. Help ▸ Copy Diagnostic Information: the "Garmin volumes" line lists the device.

## Volume devices — phase 1b (2.1 Beta 2)
With Settings ▸ Advanced "Check for device Software and Maps updates" ON and a Garmin volume device (e.g. Edge) connected: the "Software Updated / Upgrade Available" capsule appears next to the software version; the map icon opens the maps catalogue; the device is remembered if it supports music, so the launch-time update notice also covers it. With the option OFF nothing is sent to Garmin.

## Genre filter (2.1 Beta 2)
In the Music panel (local and remote libraries) a filter icon next to the search field lists the genres with track counts. Songs, Albums and Artists then show only tracks of that genre (Playlists are not filtered and the icon is disabled there); "Send" acts on what is shown. The first launch re-reads remote library XML files (cache format changed). Check: genre names that differ only in case merge; "No Genre" is last; switching library resets the filter.

## Choose product image (2.1 Beta 2)
Right-click the device image in the Device panel ▸ "Choose Product Image…" opens the list of Garmin products (the cached `deviceTypes.json`, refreshed at most every 7 days) with search; one click sets the image, which is remembered for stored devices (music-capable) and kept only until quit for the others. "Use Automatic Image" goes back to the automatic one. Works for MTP and volume devices.

## Language and menu bar (2.1 Beta 2)
Changing the language in Settings ▸ General updates at once the app's own menu items (File ▸ Load/Save playlist, About, Help) and window titles. The standard macOS names (File, View, Window…) are translated by the system at launch, so they follow the new language from the next launch (the app stores it as its `AppleLanguages`). Check both directions (English → Italian and back) with the system language set to each.

## Find similar (2.1 Beta 2)
1. Right-click a track (Songs tab, or inside an album / artist / playlist), an album or an artist ▸ "Find similar". A "Similar to …" window opens.
2. The list is sorted by score, with a bar from 0 to the maximum achievable and the percentage next to it. Rows look like the Songs list: click to choose (choices add up), double-click to listen.
3. "OK" adds the chosen tracks to the current selection and closes; "Send to Custom" sends them to the Custom Playlist (same rules as "Send to Custom": duplicates, clearing, online artwork for remote libraries); "Cancel" closes without doing anything.
4. Year and BPM count only if present in the library. Library copies saved before 2.1 Beta 2 do not contain them: after updating use File ▸ "Reload Library" (⌘R).
5. Checks: a track with no genre/year/BPM (no error, bar scaled correctly); album and artist as the starting point (correct title); a remote library; an empty result ("No similar tracks found").

## Storage bar and streaming services (2.1 Beta 3)
1. **Bar segments**: with a watch connected the bar shows System, Data, Maps, Services (only if streaming apps have content) and Music; hovering a segment shows its name and size; the free space is shown above the bar.
2. **Legend**: an entry appears only if the category takes at least 1 MB. Remove all maps → no Maps entry; a single small playlist in Music → no Music entry; empty streaming caches (128 KB each) → no Services entry.
3. **Send disabled**: select more music than the free space → the incoming segment turns red and the Send button is disabled with a tooltip; reduce the selection → back to normal.
4. **Menu flicker**: record the screen while sending a large selection; the menu bar (File / Help, no Edit) must not flicker during "Preparing tracks…".
5. **"On device" arrows**: on an album or artist header, a green arrow appears only when all its transferable tracks are on the watch. Example: an artist whose album A is fully on the watch and album B is partly on the watch shows the arrow on A only, not on the artist.
6. **Help ▸ Save GarminDevice.xml (diagnostics)** writes `GarminDevice-<date>.xml` next to the log and reveals it in Finder.
7. **Device File Manager** (Settings ▸ Advanced ▸ Tools, off by default): turn it on and a folder button appears next to the device title. Check column sorting (Name / Kind / Size / Modified, folders first), the breadcrumb, "Copy path", marks in `Music/` and `Garmin/Apps`, and **Copy to Mac…** with two files of the same name. Nothing is ever written to the device. With the toggle off the button must not appear.

8. **Map tags in the file manager**: on a watch with maps, press the check button next to "Checked …" in the Maps window once (it records the files of each map), then open the file manager on the `GARMIN` root. Each `.img` / `.gma` map file carries the name of its map in the Maps colour (e.g. "CourseView Pacific" is a golf map, not an Australian topo map); files Garmin does not attribute show "Map data".
9. **Range selection**: in Songs click one song, Shift-click a distant one → everything between is selected (or deselected, if the first click deselected). In Albums, Artists and Playlists the same works across headers and the tracks of open groups. Drag-to-select works in Songs only.
10. **Sending several playlists**: select four playlists and send. The transfer window lists them one row each (*Transferring*, then *Transferred* / *Partially* / *Check* with copied · already present · errors), keeps the whole window open between playlists, shows four complete rows without scrolling, and the bottom summary shows the totals of all playlists (selected total known from the start).
11. **Flat buttons**: every button is a flat capsule (no glass); *Delete* and *Delete All* are red-tinted with red text; disabled buttons are dimmed. Check Settings, Fix Artwork and the export windows too. *Send* has its arrow after the label; *To Custom* has its new name.
12. **Whole playlists survive tab changes and mixed selections** (Send):
    - Select one or two whole playlists (row checkbox in Playlists), switch to Artists / Albums / Songs and press *Send*: the playlists must still be sent with their `.m3u8` file (single playlist → single transfer; two or more → the multi-playlist window).
    - Then, from other tabs, add artists, albums (some partly inside the playlists) and loose songs: *Send* must show the preparation window with all tracks, and the transfer window lists each playlist plus a last row **Single songs** (copied with no playlist file). Totals read *Total* / *Selected tracks*.
    - Deselect one song of a chosen playlist from another tab (Songs / Albums / Artists): a warning appears, worded for the tab: in Artists deselect an artist's header → "…removing the artist “X”, which is in a selected playlist (…)"; in Albums → "the album “Y”"; in Songs → "the song “Z”". Deselecting a single song row inside Artists/Albums says "the song", and several at once "N songs". Singular/plural for both the subject and the playlists ("playlist will not be sent" / "playlists will not be sent"). *Cancel* → the song is selected again and the playlist is still sent with its `.m3u8`; *Confirm* → the song stays deselected and that playlist is no longer sent as a playlist (its other songs go as loose tracks).
    - In the **Playlists tab**: select two whole playlists, then untick one song of the first → same warning. *Cancel* restores the row; *Confirm* → summary becomes "1 playlist for a total of <second playlist time>" over "N-1 songs for a total of <time of the selected songs>"; unticking more songs of that playlist gives no further warning and lowers N.
    - No warning must appear: starting by picking single songs (even inside one playlist, e.g. to prepare a Custom), unticking the header (or every song) of a chosen playlist, or *Clear Selection*.
    - Clear the selection: switching tabs and pressing *Send* must do nothing (no leftover playlist).
13. **Selection summary** (bar at the bottom of the Music panel): Playlists tab with two or more playlists → *N playlists for a total of …* + *M songs for a total of …*; Artists → *N artists* + songs row; Albums → *N albums* + songs row; Songs → songs row only.
14. **Cancel during a transfer**: start a long send (several playlists + loose songs). The bottom-right button of the transfer window is a red *Cancel* (same size as *Send* / *Delete All* on the main panels). Click it: the send keeps going and a panel asks *Confirm* / *Continue*. *Continue* → nothing changes. *Confirm* → "Stopping after the current file…", then the window shows the stopped note, *Close* is back in the same place and size; only completed playlists have their `.m3u8` on the watch; the playlist in progress and the next ones do not; the selection is still there. Also check a plain send of loose songs, and a stop requested during the last file (the playlist is then complete and its `.m3u8` is created).

### Measuring where a streaming service stores its data
Goal: find where Spotify / Amazon Music / YouTube Music / Deezer put downloaded content. One service at a time:
1. Connect the watch and choose Help ▸ "Save device tree (diagnostics)": this creates `DeviceTree-<date>.txt` in `~/Library/Logs/MusicManager/` (revealed in Finder), and Help ▸ "Save GarminDevice.xml (diagnostics)". Call these "before".
2. On the watch (or with the service's app) download ONE small playlist of the service and wait for the download to finish.
3. Reconnect the watch and save both files again ("after").
4. Send the files (or their comparison): new lines show folders, extensions and sizes; the `MediaCacheSize` of the service in `GarminDevice.xml` shows how much it holds.

These actions are read-only. Do not delete or copy anything on the watch during the test.


## Music on volumes (2.1 Beta 3, experimental)
Use `Scripts/make-test-volume.sh music` (or a writable disk image with `Garmin/GarminDevice.xml` and an empty `Music` folder):
1. Settings ▸ Advanced ▸ Tools: turn on "Music on external drives and SD cards". Back in the Device panel, **Connect** appears next to Eject (only with the switch on and a music-capable volume).
2. Connect: the panel switches to the normal device view (model, storage bar for the volume, empty catalog); the button becomes Disconnect.
3. Send a song, a playlist and loose songs from Music: files appear under `Music/Artist/Album/`, the `.m3u8` in `Music`; catalog and storage bar update.
4. Delete a song, then an album: files and empty folders are removed (permanent); Empty Music folder works.
5. Disconnect, then Eject: the volume is released. Eject from Finder while connected: the app behaves as if the cable was unplugged.
6. Switch off: Connect disappears. Titles/artists/albums on the volume come from file and folder names (no MTP metadata); durations and track numbers from the Music library.


## Detailed log and AirPlay volume (2.1 Beta 3)
1. Settings ▸ Advanced ▸ Tools: turn on "Detailed log (diagnostics)"; "Show Log File" selects `~/Library/Logs/MusicManager/MusicManager.log` in Finder. The log shows "Log level: detailed".
2. AirPlay to the Mac / amplifier / Apple TV: move the volume slider once. The log has `[debug] AirPlay volume:` lines — flags, route devices (class, name, volume, volumeControlType, canSetVolume), result of `setVolume`, and a re-read 0.5 s later. Expected on Apple TV: the re-read tells whether the device applied the level (then the volume works) or not (then the device exposes no absolute volume control).
3. With the switch off nothing `[debug]` is written. Help ▸ Copy Diagnostic Information shows "Detailed log: on/off".

## AirPlay as audio — Apple TV test (2.1 Beta 3)
Settings ▸ Advanced ▸ Tools ▸ "AirPlay as audio" (on by default): choose the Apple TV again from the AirPlay button and play a song.
1. Does the volume slider stay next to the Apple TV in the system AirPlay panel after Play?
2. Does the in-app volume slider change the Apple TV volume? Is the title shown on the Apple TV the right one?
3. With the detailed log ON, the `[debug] AirPlay volume:` lines should show `riproduzioneEsterna=false`.
4. Check HomePod and the Mac too (nothing should get worse); OFF restores the previous behaviour.

## Slider follows the AirPlay device (2.1 Beta 3)
With "AirPlay as audio" ON and a remote device playing: move the slider inside the system AirPlay panel; when you stop moving it, the in-app slider should jump to the final value within about half a second (it does not follow while you drag). Moving the in-app slider must still control the device without jumps (the app waits 1.5 s after your last move before following the device). Detailed log: `il cursore lo segue` lines show each sync.

## Now Playing info (2.1 Beta 3)
1. Play a song with cover art, with "AirPlay as audio" ON and an Apple TV selected: the Apple TV banner shows the cover and "Artist / Title" of the song playing (not another one).
2. Change song, pause, resume, move the progress slider: the banner and the time bar follow.
3. Control Center ▸ Now Playing shows the same song; the keyboard media keys (play/pause, next, previous) control the app.
4. With the detailed log ON, each update writes a "[debug] In riproduzione: pubblicato …" line.

## Startup time with Apple Music closed (2.1 Beta 3)
Switch on the detailed log, quit Music and the app, start the app and note when the "open Music in the background?" question appears. The log shows "Libreria: lettura iniziata/finita in N s" and "Avvio: controllo apertura Musica": the difference between the two timestamps tells whether the wait is the library read or something earlier.

With the detailed log on, the library read also logs how long the conversion of the songs took (they are now read 8 at a time), how many files are on mounted volumes and how many songs have no path.

## Library read in parallel (2.1)
The library read asks Music's service for every song's file location. If the service is slow (about 40 ms per request, seen on macOS 27) 1000 songs in a row take about a minute. The read now runs in parallel (`MusicLibraryService.parallelRead`; set it to `false` to go back to one at a time). Check: start with Music closed and time the wait; the detailed log shows "Libreria: N brani letti in X s (in parallelo)". Check also that the song count, the playlists and the order are the same as before.

## Storage bar: free space inside the bar (2.1 Beta 3)
1. The free space is written in the middle of the free part of the bar; the total is in the "Storage Capacity" row under Serial Number (also on a volume seen as a disk).
2. Select songs: the value updates to what would remain after the send; the striped segment is green while the value fits.
3. Select enough songs to leave only a little free space: the value disappears and the striped segment turns orange; with more than the free space it turns red.
4. Maps are purple in the bar and in the legend; check the panel rows do not overlap the bar (one more line than before).


## 2.2 — what to test
1. Start twice: the second start should log "percorsi dalla copia salvata: ~N" (detailed log on) and be fast even with a slow Music service. Move/rename a file: that song must still get its new path.
2. Open an external (network) library: browsing must not read covers (no loading notice); songs without covers appear without cover icon until you send/add to Custom. Then send: covers are read (loading notice), missing ones open the online search panel.
3. SD card / volume: select more songs than the free space; Send must be disabled with the red bar message.
4. Settings ▸ General ▸ "Ask before adding to Music" (on by default). Drag a file that is not in Music onto the Device side, complete the panel and press Send: an alert asks "Add to Music?". Test "Only to the watch" (Music library unchanged, song sent in "Direct Copy"), "Add to Music" (as before) and Cancel. Then turn the option off: no question, songs are added.
5. With an external library, add its songs to the Custom Playlist and press Save to Music: the alert lists the songs; test "Save without them" and "Add to Music".
6. Custom Playlist with songs of your local library only: Save to Music with a new name asks "Save to Music?" (the playlist is created only on "Save to Music"); with an existing name only the usual replace/add question appears.
7. Add songs to Music (drag and drop → "Add to Music"), then remove them from Music with the app still open ("Move to Bin"): drag the same files again; the question must list them as new. Also: delete a song in Music, go back to Music Manager and check the lists update by themselves (detailed log: "riletta al ritorno nell'app").
8. Settings ▸ Advanced ▸ Tools ▸ "Threads to read the Music library": try Automatic, 1, 4; restart the app each time and compare the "lettura finita" time in the detailed log (the log line shows the threads used). Nothing should change in the result, only in the time.
9. Custom Playlist with songs of an external library, loaded from a `.m3u8` in Custom Lib: Save to Music ▸ Add. Afterwards open the `.m3u8`: the copied songs must point to the Music media folder, not to `/Volumes/…` (only if Music copies files to its folder). A second Save to Music must not ask to add them again.
10. Open a `.m3u8` with some files missing (unmount the volume): the status says "N of M"; the log lists the missing paths.
11. Online artwork panel (Send or Add to Custom with songs without cover): Confirm and Ignore are in the grey area, aligned to the bottom of the artwork; Ignore is disabled on the last song; Confirm on the last song keeps the panel open. OK with every cover chosen closes at once and the send goes on; OK with a found-but-not-chosen cover, or songs not yet viewed, shows the warning with the counts (Continue / Back). Close closes without the warning. After closing, the send reaches the transfer summary with the confirmed covers.


## 2.2 — External Drive Libraries
Requires a Garmin that accepts music connected at least once (so its GarminDevice.xml is stored). Use a USB drive with a folder of audio files (about 1000 in the test).
1. Settings ▸ Advanced ▸ External Drive Libraries ▸ "Add Folder…". With no registered device an alert explains that one must be connected first.
2. With the Garmin connected: the sheet says the catalog is built for it (with its formats). Create it: the progress line shows "Looking for audio files…" and "Reading tracks: N of M"; the row then shows device and track count. Note the time of the first scan.
3. Rescan with the button on the row: it must be much faster (files unchanged are reused). Add or remove a file on the drive and rescan: only the change is picked up. Check the detailed log: "Unità esterna «…»: N brani, M playlist in X s".
4. Library menu (top right): the new library appears with the `externaldrive` icon. Open it: songs, albums, artists and playlists browse normally; covers present in the files show while scrolling; no question about Music anywhere.
5. Only compatible files: put a .flac/.wav in the folder: it must not appear. With the device disconnected and two registered devices, the sheet shows the two-column list (Device | Supported audio formats).
6. Playlists: `.m3u` / `.m3u8` files in the folder are not imported for now: the library shows no playlists from them (only the Playlists tab empty).
7. Select songs and send to the device; add songs to the Custom Playlist: missing covers go to the online search panel as for network libraries; the send writes the confirmed cover only into the sent copy.
8. Unplug the drive: the menu entry is red "unavailable" and disabled; the Settings row shows the same. Replug and open it again.
9. Connect a different Garmin with different formats while the library is open: the app proposes "Rebuild for …".
10. Remove the library in Settings (trash): its index file is deleted, the drive is untouched; if it was open the app returns to the local library.
11. Library picker: a long library name stays on one line and is cut with "…"; the button is wide enough for "La mia musica".
12. Eject: with the drive library open a button with the eject symbol appears left of the picker (not with the local or a network library); press it: back to the local library and the drive unmounts (status: "…ejected: you can unplug it"). Try it while the Custom Playlist holds songs of the drive: they stay in the list but their files are gone.
13. Involuntary disconnection: with the drive library open, pull the cable (or eject from Finder): the app returns to the local library with the status "The drive of library … was disconnected". Replug: the menu entry is usable again.
14. Choose the drive library from the menu after adding/removing a file on the drive: the change is there without pressing refresh (incremental, only new files are read).

## Device without music (tested 2026-10-19)
Old Garmin nuvi (mass storage, software 5.20, 435,8 MB): detected as an external disk; the panel shows model, software version, serial number and volume space with the red "Music not supported" badge and the note that transfers are not available; only "Eject" is active. A device without music is not registered, so it does not count for External Drive Libraries (the "no registered device" message appears if it is the only one connected so far).
Eject on the nuvi: confirmed (2026-10-19): the device is also ejected correctly at system level (it disappears from Finder).
15. Eject while a song of the drive is playing in the mini player: the system refuses and the status shows "Cannot eject the drive of library …" with the reason (confirmed 2026-10-19). Stop playback and eject again: it works.
16. Eject while a song of the drive is playing: playback stops, the drive is ejected and the app returns to the local library. If something else keeps the drive busy (for example a Finder window or another app) the status shows "Cannot eject the drive of library …" and the library stays open.
17. Eject refused with "OSStatus error -47" (drive busy): the app retries (up to 8 times, about 5 s, after stopping playback; 3 times otherwise) and, if it still fails, adds "Programs using the drive: …" (from lsof) to the status line and writes the same to the log. Report which programs are listed (Finder, mds/Spotlight and other system services may not be visible).
Eject with a song playing (patient version, 2026-10-19): confirmed. Playback stops, the drive is ejected after the retries, the status says "Drive of library … ejected: you can unplug it." and the app returns to the local library.
Drive not connected (2026-10-19): confirmed. In Settings the row shows the red icon with the cross and "Library “…” is not available: connect the drive."; the rescan button is disabled and the trash button stays active.
External Drive Library on a network folder (NAS, not macOS), 2026-10-19: works with a few files (read correctly). Not yet measured with about a thousand files (first scan, rescan at every open, covers while browsing).
