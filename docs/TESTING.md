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
