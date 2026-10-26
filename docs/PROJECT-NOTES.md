# Music Manager — Project Notes

**Current version: 2.2 (build 19, final)** · macOS 26+ · Apple Silicon only · GPL v3.0 · © 2026 Riccardo Colaiori (cr.developer)

Technical notes for contributors and testers: what the app does, how it is built, how it talks to the watch, which decisions were taken on purpose, and what is still open. For user-facing changes per release see [CHANGELOG.md](../CHANGELOG.md); for installation see [INSTALL.md](INSTALL.md); for test scenarios see [TESTING.md](TESTING.md) (Italian).

> Independent project, not affiliated with or endorsed by Garmin or Apple.

---

## 1. What the app is

A native macOS app (SwiftUI) that moves music from the **Music** app library to a **Garmin** watch (fēnix, Forerunner, Edge…) over USB and manages what is already on the watch.

- Music flows **one way**: Mac library → device. The app never copies audio from a device and never reads other devices' libraries (see [SCOPE.md](SCOPE.md)).
- The only files read back from a device are small text files (playlist `.m3u8`, a check copy of a playlist just written, `GarminDevice.xml`); they go to a temporary folder that is deleted right away.
- It does not remove DRM from anything. DRM-protected, cloud-only and Apple Lossless tracks are shown but cannot be selected.

## 2. Requirements and constraints

| Item | Value |
|---|---|
| OS | macOS 26.0 or later |
| CPU | Apple Silicon (`arm64`) only — no Intel build, no universal binary |
| Transport | USB, MTP via **libmtp** + **libusb** (bundled in the app); devices that mount as a disk are recognised read-only (see §6.4) |
| Signing | Ad hoc, **not notarized** (no Apple Developer account). Users clear the quarantine flag with `xattr -cr`; see [INSTALL.md](INSTALL.md) |
| Sandbox | Off (needs USB, `~/Music`, Apple Events to Music) |
| Audio formats | mp3, m4a, aac — intersected with the formats the device declares in `GarminDevice.xml` |
| Languages | English (default) and Italian, chosen in Settings |
| Bundle ID | `com.crdev.MusicManager` |

## 3. Feature overview (2.1)

### Music library (left panel)
- Reads the local Music library with `iTunesLibrary`: tabs **Playlists / Artists / Albums / Songs / Custom**, always alphabetical.
- Per-track status: transferable or not (DRM, cloud-only, Hi-Res/Apple Lossless, unsupported format, missing file), purchased badge, artwork origin icon, "on device" icon, "in a playlist" icon.
- Album and artist headers show a green "on device" arrow when **all transferable tracks** of the group are already on the watch (device-only tracks count as present; no transferable track = no arrow). Playlists show the arrow when a playlist file with the same name exists on the device.
- Multi-disc albums get "Disc n of m" headers; track numbers and durations everywhere.
- Search per tab, **genre filter** (not on Playlists), **Find similar** (weighted score from shared playlists, artist, genre, album, year, BPM; at most 3 tracks per artist; ties broken by fewer plays).
- Optional **remote libraries** (up to three): an XML exported from Music plus the media files on a mounted share (SMB). DAAP / Home Sharing was tried and abandoned (Apple's access control).
- Type-to-select in Songs/Albums/Artists; click or drag to select in Songs; selection is shared across tabs.
- **Mini player**: local playback of the track file (not tied to Music), queue from playlist/artist/album, shuffle, repeat, AirPlay (single `AVPlayer`), output-device icon, volume.

### Device panel (right panel)
- Same tabs as the library (without Custom), with track numbers, durations and album artwork when the firmware exposes it (usually it does not → placeholder).
- Header: model, software version, serial number (via Garmin's unit-info service; right-click → Copy), product picture (official image, Connect IQ Store catalogue, or manual choice from the context menu), software and **maps** status icons.
- **Storage bar** (internal storage only): System · Data · Maps · Services · Music · incoming selection · free space (details in §5).
- Delete selection (with a confirmation sheet listing the tracks and the playlists affected; affected playlists are rewritten without the deleted tracks, emptied playlists are removed), Delete All, Clear Selection.
- Devices with no music support (no `MEDIA_TRACK` in `GarminDevice.xml`) are shown read-only: info stays visible, sending and deleting are disabled at every layer.

### Sending
- Right-click or the Send button; sends tracks, albums, artists, whole playlists, several playlists, or a Custom Playlist.
- Layout on the watch: `Music/<Artist>/<Album>/<track>.<ext>`; `.m3u8` playlists are **deleted and recreated** every time, then verified on the device (present, re-downloadable, same lines — normalised comparison).
- Files already on the device (same name and artist) are skipped: a second send copies only the delta.
- A **summary window** precedes the transfer (artwork source per track: File / Apple / Garmin Cache / No Cover); a **transfer window** follows with per-track results.
- The Send button is disabled when the selection (not yet on the device) exceeds the free space; `sendSelectedTracksToDevice` also refuses it for the context-menu path.
- Optional **Fix Artwork** (off by default; AAC/M4A only): online candidates from the public iTunes Search API; the cover is written in a copy by editing the MP4 `covr` atom directly (original in Music is never opened for writing).

### Drag & drop of audio files onto the device
Audio files dragged from the Finder onto the device panel (device connected and writable) open an import panel modelled on Music's *Details* tab: tags read with AVFoundation (title, artist, album, album artist, composer, genre, year, track/disc, cover), editable only where a tag is missing, one file at a time, with a match against the Music library. Files not yet in Music are added to it through Apple Events (missing tags and the chosen cover are set from Music itself, so the cover ends up inside the file, MP3 included); files already in Music reuse the library track (or the dropped file, if Music's copy is not transferable). Everything goes through the normal summary and transfer windows and is listed in a playlist called **Direct Copy** (recreated on each drop; tracks already listed are skipped). Verified end-to-end, including MP3 covers.

### Custom Playlist
Built from any tab with "Send to Custom"; tree view with an editable name; sort Manual / Title / Artist / Album / Random; load/save as M3U8 (`~/Music/MusicManager/Custom Lib`) with three merge modes; save to Music (folder "≡♪ Music Manager") via Apple Events; "Edit in Custom" imports a device playlist.

### Settings
Tabs General / Appearance / Artwork / Advanced. All settings are **global** (no per-device profiles since 2.1 Beta 2). Appearance: Light/Dark/System previews, list text size (5 steps), window opacity, selection colour (swatches + tone slider). Advanced: known devices table (nickname, model, serial, maps, software), remote libraries, optional software/maps update check, and **Tools → Device File Manager** (off by default, see §7).

### Menus and Help
Reduced menu set (no Edit menu; ⌘X/C/V/A are forwarded to text fields by a local monitor). Help menu: copy diagnostic information, show log in Finder, **Save device tree** and **Save GarminDevice.xml** (read-only diagnostics), send feedback, third-party licenses. Log files: `~/Library/Logs/MusicManager/`.

## 4. Source layout

All code is in `MusicManager/` (~19.7k lines of Swift). Rule of the project: **no new Swift files** unless strictly needed — new types go into existing files. Code comments are in Italian.

| File | Role |
|---|---|
| `MusicManagerApp.swift` | `@main`, scenes, menu commands, `MenuState` (minimal observed state for menus, see §8) |
| `AppDelegate.swift` | Window/menu tweaks, quit confirmation, edit-menu removal, text-field context menu |
| `AppViewModel.swift` | Central state and all operations (connect, catalogue, send, delete, selection, Custom Playlist, storage breakdown, diagnostics) |
| `ContentView.swift` | Main window: panels, bottom bars, sheets, device header, device file browser |
| `CatalogBrowser.swift` | The tabbed lists (both panels), selection, context menus, Find Similar |
| `Catalog.swift` | Catalogue types (`CatalogTrack`, categories, `PlaybackSource`) |
| `MTPService.swift` | libmtp access (an actor): list, upload, download, folders, delete, name matching (`nameKey`), write lock |
| `DeviceImageService.swift` | `GarminDevice.xml` parsing (model, media capabilities, apps, `MediaCacheSize`), product images, Garmin unit-info/maps/update services, volume-device scanner, `AppFolders`, `DeviceXMLStore` |
| `MusicLibraryService.swift` | `iTunesLibrary` and external XML libraries |
| `AppleMusicScripting.swift` | Apple Events: save playlist to Music, artwork from Music |
| `StorageBarView.swift` | The storage bar and its legend |
| `MiniPlayerView.swift`, `PlayerService.swift` | Player UI and engine, audio route monitor |
| `ArtworkCache.swift`, `ArtworkExporter.swift`, `ArtworkLookupService.swift`, `MP4ArtworkWriter.swift`, `FixArtworkView.swift` | Artwork pipeline |
| `DeviceExportView.swift`, `TransferReportView.swift` | Summary and transfer windows, deletion progress |
| `GlassBars.swift` | Liquid Glass top/bottom panels |
| `SettingsView.swift`, `AppSettings.swift` | Settings UI and persistence |
| `Localization.swift` | All strings (EN/IT). **A duplicate key crashes the app at launch** — always check |
| `USBRemovalWatcher.swift` | IOKit + polling detection of unplug |
| `SharedMusicLibrary.swift` | Intentionally empty (kept so existing Xcode projects do not break) |

Scripts (`Scripts/`): `bundle-libs.sh` (copies libmtp/libusb into the bundle, lowers their minimum macOS to 26.0 with `vtool`, signs), `verify-bundle.sh`, `build-release.sh` (DMG + `.sha256`), `diagnose-launch.sh`, `make-test-volume.sh`.

Application data: `~/Library/Application Support/MusicManager/` (`Devices/Images`, `Devices/DeviceXML/<Global ID>/GarminDevice.xml` + `Maps.json`, `Artwork/…`, `External Library/…`) and `~/Music/MusicManager/` (`TEMP`, `Custom Lib`). Older folders named `GarminMusicManager` are migrated at first launch.

## 5. The storage bar and what sits on the watch

The MTP tree does not show everything that occupies the flash. The bar therefore combines three sources:

| Segment | How it is computed |
|---|---|
| **Music** | Size of the `Music/` folder (from the tracks already read). |
| **Maps** | `.gma` / `.img` files under `Garmin/` (recursive scan, done at connection / storage change only). |
| **Data** | The rest of the `Garmin/` folder (activities, apps, settings…). |
| **Services** | Sum of `MediaCacheSize` of every `audio-content-provider-app` in `GarminDevice.xml` (Spotify, Amazon Music, Deezer…), not distinguished. Shown only if > 0. |
| **System** | Estimate: capacity − free − all segments above. ≈ 3.45 GiB on a fēnix 9 Pro (OS, firmware, overhead). It is an estimate, not a measured value. |
| **Incoming** | Striped segment for the selected tracks not yet on the device (red if it exceeds the free space). |

Display rules: "xx GB free of yy GB" sits above the bar (and shows what will remain after sending the selection); sizes live in a mouse-over tooltip on each segment, the legend shows names only; a legend entry and its segment appear only if the category occupies ≥ 1 MB (no maps → no Maps entry; empty 128 KB service caches → no Services entry). Only the internal storage gets a bar.

### Streaming services on the watch (analysis, Beta 3)
- Installed services appear in `GarminDevice.xml` as `<App>` entries: `AppName`, `StoreId`, `AppId`, `AppType` (`audio-content-provider-app` for streaming services, `watch-app` otherwise), `MediaCacheSize` (bytes; **131072 = empty cache**), `FileName` (`.PRG`).
- Their index/metadata files (`<ID>.DAT/.IDX/.IMT`) live in `Garmin/Apps/DATA` and are owned by the watch: **the app never writes there**.
- Downloaded content is **not visible through MTP**; the growth of the hidden space matched the growth of `MediaCacheSize` (Deezer: Δ cache 27,328,512 B vs Δ hidden 29,012,808 B).
- Services do **not** use `Music/`. The risk for Music Manager is therefore *competition for free space*, not path collisions. This is why the Send button is blocked when space is insufficient.
- Tested: Amazon Music and Deezer (measured). Spotify could not be measured (needs Premium) and YouTube Music was not installable on the fēnix 9 (store reports it incompatible). Space measurements are considered **closed**: the Services segment is read from `MediaCacheSize` for every streaming app, regardless of service.

## 6. How data is read from the device

1. **Metadata** — MTP properties first (title, artist, album, duration). If the watch does not expose them: title = file name, artist/album from the folders (`Music/Artist/Album/track.mp3` or `Music/Album/track.mp3`). Duration, track and disc numbers are enriched from the matching file in the Music library (matched by file name + artist + album, then file name + artist, then the sanitised artist, finally unique file name).
2. **Artwork** — MTP "representative sample"; most firmwares do not support it, a placeholder is shown (not an error).
3. **Playlists** — `.m3u` / `.m3u8` in `Music`, matched to tracks by **full path**.
4. **Artist/album names** — folder names are sanitised on the device (`AC/DC` → `AC_DC`); the app remembers the original of what it sends and recovers the real name from the library.
5. **Capabilities** — `GarminDevice.xml` (`MEDIA_TRACK`, `MEDIA_PLAYLIST` with `TransferDirection = InputToUnit`). Missing file or missing `DataType` = unknown capability: nothing is blocked.
6. **Volume-mounted devices** (e.g. Edge) — a scanner looks for removable volumes with a valid `Garmin/GarminDevice.xml`; they get model, software, space, maps, serial and an Eject button. **No transfer yet** (phase 2 needs a volume device that supports music).

### Garmin web services used (all anonymous, all optional unless noted)
- `omt.garmin.com/api/unit-info/…` — serial number and official picture (always on, sends only the unit ID).
- Connect IQ Store `deviceTypes` catalogue — product pictures.
- Software update check and maps catalogue (`omt.garmin.com/api/maps/universal/update`) — **off by default**; they send the contents of `GarminDevice.xml` (which contains unlock codes). Setting: *Check for device Software and Maps updates*.
- Maps are informational only: installing or updating them stays with Garmin Express. `Maps.json` per device is the only source; Garmin is queried at first connection or on demand, with proposals to re-check after 90 days or when the maps on the device changed.

## 7. Device File Manager

Behind **Settings ▸ Advanced ▸ Tools ▸ Device File Manager** (off at first launch). A folder button next to the device title opens a sortable table (Name / Kind / Size / Modified, folders first) with a clickable breadcrumb, "Copy path", marks on known files (Music Manager's own folders; app or streaming-service names on `Garmin/Apps` files recognised through the `FileName` stems of the XML) and **Copy to Mac…**. It never writes to the device. A text preview was designed and rejected. It started as a diagnostic tool to study how streaming services use the device and stays in the public release as an opt-in, read-only way to browse the watch without third-party programs.

## 8. Technical notes worth remembering

- **Menu flicker.** SwiftUI re-evaluates `Commands` on every publish of a `@FocusedObject`; observing the whole view model rebuilt the menus (and briefly resurrected the Edit menu) while tracks were being prepared. Menus now observe only `MenuState` (`isBusy`, `hasDevice`, `customPlaylistEmpty`, with `removeDuplicates`) and read the view model without observing it.
- **Sending uses libmtp through an actor** that performs blocking calls; long operations are wrapped in `withTimeout` (file-private in `AppViewModel.swift`). A replaced file or an AVFoundation-rewritten file on the watch was the only configuration that ever hung a transfer — artwork is therefore written by editing the `covr` atom in a TEMP copy, and existing files are replaced with a single attempt.
- **Folder creation errors (PTP 2002)** came from matching names case-sensitively; `MTPService.nameKey(_:loose:)` normalises Unicode (NFC), case, trailing spaces/dots, optionally accents and width, and `ensureFolder` re-reads the listing before reporting a real failure.
- **Verification is by file name** (not size or checksum): some firmwares report slightly different sizes for correct files, a stricter check produced false negatives. Could become an option.
- **`List` selection on macOS.** `.onTapGesture` is exclusive and breaks native selection and drag; the lists use `.simultaneousGesture` or manual selection. Native highlighting is hidden (`HideNativeSelection`) so the user's selection colour always shows.
- **SF Symbols licence** forbids their use in app icons or logos; the app icon (two cards — Music in coral, Device in green — joined by an arrow, on a grey gradient) is drawn from original shapes.
- **Libraries built on macOS 27.** Homebrew builds libmtp/libusb with minimum macOS 27.0, which would make the app fail to start on macOS 26. `bundle-libs.sh` lowers it to 26.0; `verify-bundle.sh` fails if any bundled library requires more.
- **First launch on macOS 27.** A quarantined, ad hoc signed app can hang in `_dyld_start` before running a single instruction (not an app bug). `xattr -cr "/Applications/Music Manager.app"` always solved it. `Scripts/diagnose-launch.sh` collects data. Notarization would fix it for good but needs a paid account (declined for now).

## 9. Decisions taken on purpose

- **One-way flow, no reading of other devices' libraries** (legal and positioning reasons) — pull requests adding it will not be accepted.
- **No drag & drop to populate the Custom Playlist**: three attempts with different APIs never worked reliably; it uses an explicit "Send to Custom" action. Reordering inside the list uses the native `.onMove`.
- **No DAAP / Home Sharing**, no manual production-serial scanning of the watch, no vector drawing of the watch with a storage ring, no compact top panels — all tried or proposed and dropped.
- **All settings global**, one profile.
- **Maps are informational**; the app does not install or update maps.
- **No Windows port**: the app is tied to Music, SwiftUI and the macOS MTP situation; dedicated Windows tools already exist.
- **Not notarized**: no Developer ID account for now.

## 10. Known limitations

- Uses the first MTP device found.
- Transfers are synchronous, with no per-file progress bar.
- The Garmin/maps breakdown is a recursive scan done at connection or storage change only; Music size updates on every refresh.
- The "System" segment is an estimate; "Services" is the sum of all streaming apps.
- Device artwork is best effort and usually absent.
- `.fit` files are not read.
- Distribution: App Sandbox off; Mac App Store would need USB access re-evaluated.

## 11. Open items

- Beta 3 verified on hardware (2026-10-18) and closed; 2.1 released the same day.
- Real macOS 26 test (never done: no machine available); confirm the bundled libraries load there.
- Icon: `AppIcon.icon` is now the author's own Icon Composer bundle (3 layers); to be refined later.
- Statistics panel (idea, not designed).
- AirPlay volume with Apple TV: under test (Settings ▸ Advanced ▸ Tools: *AirPlay as audio*, detailed log).
- Music on volumes (SD cards / mass storage) is experimental and off by default: to be tested with a disk image and a real device.
- Public 2.1: user guide done (docs/MusicManager-UserGuide-v2.1.docx), final README done. Remaining for the maintainer: DMG, sha256, GitHub release v2.1.

**Decisions (2026-10-17):** the Device File Manager **stays** in the public release (read-only on the device, off by default behind Settings ▸ Advanced ▸ Tools): it lets users browse the watch without third-party programs. Streaming space measurements are closed (Spotify not measurable without Premium).

- AirPlay test (2026-10-18): Apple TV OK with "AirPlay as audio"; Yamaha RX-A2020 (2012) refused by the system ("Unable to connect") on macOS 27 — device limitation, not an app issue.

- Cancel during a transfer with several playlists + loose songs: tested OK on 2026-10-18 (4 complete playlists sent, the fifth not sent, correct totals and warning).

## 12. Candidates for 2.2 (noted 2026-10-18, not for 2.1)
- **Remote controls from the Apple TV** (play/pause, previous/next, progress bar in Music ▸ Now Playing): an attempt (commands enabled, skip ±15 s, log of every command received) is kept in `docs/2.2-remote-commands-attempt.md`, not in 2.1. The banner with cover, artist and title already works in Beta 3.
- **Library read**: now parallel (`MusicLibraryService.parallelRead`, kept in 2.1); keep checking thread safety of `ITLibMediaItem`, and consider reading `item.location` lazily instead of for every song at startup.
- **Remote libraries, artwork** (idea of 2026-10-18, to try in 2.2 Beta): reading covers from a library on the network takes many seconds while browsing the catalogue. Proposal: do not read covers while browsing; read only the covers of the songs involved at check-and-send time (summary window). If a remote cover is missing at that point, show the online artwork search panel (when the option is on) for all the songs that have none. To verify first: where covers are read today for remote libraries, and what depends on them in the lists (icons, "without cover" filter and count).
- **Drag and drop without adding to Music** (from GitHub issue 1, 2026-10-19): after the import panel ask "Add the new songs to Music?" (Yes / No, only to the watch / Cancel, with a "remember" option). "No" sends the dropped file directly (as already done for songs of Music that cannot be copied). Limit to check: a cover chosen in the panel can be written into the sent file only for AAC/M4A.
- **External library in Music XML format** (GitHub issue 1, on hold): use the `Location` paths directly when the file exists, derive the source folder from the common prefix when "Music Folder" is missing, clear message when no file is reachable, diagnostics with counts. Only if the user has a library conforming to the Music standard; plain folders of files are covered by drag and drop.
- **Cover placeholder** (noted 2026-10-19, from the remote-library test): when a song has no cover, the placeholder with a single note (`music.note`) stays in **Songs**. In **Albums** use `music.quarternote.3` as the placeholder. **Artists** follow the same rule: an album without a cover shows `music.quarternote.3`.
- **External drive source with its own JSON index** (idea of 2026-10-19, related to GitHub issue 1, not for Beta 1): a new library type (icon `externaldrive`) that scans a folder/volume, reads the tags and builds an index in `Application Support/MusicManager/ExternalIndex/<id>.json` (paths relative to the root, volume UUID, incremental rescan, optional `.m3u8` playlists). It reuses the `ext:` track pipeline. Refinement: the catalog only contains files compatible with the user's registered Garmin device (from the stored `GarminDevice.xml`; requires the device to have been connected at least once; the user is told the catalog is built for [device]); no Music lookup for these sources; artwork from the file if present, otherwise the existing Fix Artwork panel. Decisions: no registered device → source blocked; several devices → pick one from a 2-column list (name, supported audio formats); `.m3u8` files imported read-only; original user files are never modified, only the copies sent to the device. Device choice: if a device is connected it is used (with a notice); otherwise the single registered one, or a list to choose from. Details in the project doc *GH-1 — Idea: sorgente «Unità esterna» con indice JSON proprio*.
- **Music on volumes**: out of experimental once tested with a real SD card / mass-storage device.
- Free-space block on external SD memories (`isSelectedStorageInternal` heuristic), still awaiting a real device.

**Decided 2026-10-18:** own AirPlay device list — discarded (the system picker is fine); "valore fermo" slider — done in Beta 3; "AirPlay as audio" on by default — kept; parallel library read — kept; update-window capsules — 10 pt (done).


## 13. External Drive Libraries (2.2)
Implemented in 2.2 (no new Swift files): `DriveLibraryConfig` (AppSettings.swift, saved in UserDefaults `drive_libraries`), `DriveIndex` / `DriveLibraryService` / `DriveLibraryManager` (MusicLibraryService.swift), `AppViewModel.selectDriveLibrary` / `confirmDriveRescan`, menu entries in ContentView, section and `DriveSetupSheet` in SettingsView. Track ids are `ext:drive-<libraryUUID>:<relative path>`, so the existing `ext:` pipeline (Fix Artwork, send, Custom Playlist) is reused. The device formats come from the stored `GarminDevice.xml` (`DeviceXMLStore` + `DeviceImageService.mediaCapabilities`) intersected with `LocalTrack.appExtensions`. `isRemoteNetworkLibraryActive` is false for drive libraries (covers read while browsing).
Open points: tag reading uses identifier raw values (`id3/trck`, `itsk/trkn`…) and was not run; Save to Music from the Custom Playlist still asks "Add to Music" for these songs (same as other `ext:` songs).
Playlists: the import of `.m3u`/`.m3u8` from the drive is switched off (`DriveLibraryService.importPlaylists = false`) because the references in user files can point elsewhere (e.g. the Mac's disk) and look correct while being wrong.
Future idea: when a Custom Playlist is created while a drive library is open, "Save" would write the usual `.m3u8` in `~/Music/MusicManager/Custom Lib` **and also** a playlist on the drive itself, with a tag the app recognises (so it can be read back with correct, drive-relative references).

## 14. Low resolutions and accessibility (implemented in 2.2: compact mode, min 1024×530, threshold 700 pt per pane)

**Implemented (2.2).** Compact mode: each half narrower than 700 pt (window below ~1400 pt) shows tabs, library/storage pickers and bottom-bar buttons as icons only (tooltips keep the names). The window minimum is now 1024×530 pt, so "Larger Text" displays (e.g. 1024×666) work and the window can sit above the Dock; at first launch it is fitted to the visible screen. Dialogs (Settings, pre-send summary, live transfer report) are 90 % of the main window's height (min 300 pt; Settings min 480 pt) and Settings opens centred on the main window; sheets stay attached to the title bar (macOS), so they cannot be centred vertically.

**Still to check for accessibility**: accessibility labels on icon-only buttons, VoiceOver order, "Reduce transparency" / "Increase contrast" with the glass panels, keyboard access to the toolbar popovers.

## 15. UI restyling (started as a trial, kept in 2.2)

Started as a trial during the 2.2 betas and kept in the final 2.2. (The intermediate items below are the development log; the "known issue" lines were written during the betas and were not all re-checked for the final.)
- **Floating glass capsules** for the top and bottom bars of each panel (`GlassBars.swift`, radius 26, 8 pt side margin, 2 pt gap below the title bar), always as wide as the panel; controls that do not fit are clipped, never widening the capsule. No divider between the two panels; both halves get explicit widths from a `GeometryReader`.
- **Title bar as a Xcode-style toolbar**: activity capsule (app name + last message, spinner or a blue progress ring for "n of N" operations, icon by message type) drawn *inside the content* in the title strip, because the macOS toolbar does not widen leading items; refresh, search (Music / Device target, ⌘F), settings and the notification bell (history of the last 100 messages, unread badge) are toolbar buttons. An invisible `.principal` placeholder keeps them on the right in windowed mode; in full screen the capsule is a toolbar item with a computed width (`fullScreenReserve`) and the titlebar buttons that appear on hover momentarily push the right-hand buttons into the overflow menu — known, to be reconsidered. The bottom status bar was removed.
- **Device panel controls on the tab row**: Connect/Disconnect, Eject and the storage picker (like the library picker in Music); descriptive tooltips on every new button and on the bottom bars.
- **Mini player**: title and artist/album kept close; playback and volume sliders follow the pane width.
- **Two-line hints** ("No track playing" / "Connect the device via USB").
- **Network libraries at launch** (SMB only for now): unmounted volumes of remote libraries are mounted automatically and the result is notified; other protocols and the wider handling of mounted volumes wait for the reply on GH-1.
- **Open idea — library sources and start-up order** (to think over, not designed): with several sources (Local / Network / USB or external drive) let the user choose in Settings a *list of libraries and the order in which they are loaded at launch* (or which one opens first). Today the app always starts on the local library and a remote one is opened by hand from the library picker; the SMB volume is mounted at launch only so the choice is ready. Questions to settle: what to do when the first source is unreachable (fall back to the next? ask?), whether to preload several sources, and how it interacts with the "network libraries" rules of GH-1.
- **Open ideas**: Liquid Glass for the whole title strip (content under the toolbar + scroll-edge effect), alternative layouts for full screen.
- **Known issue (to fix)**: when sending one or more playlists, after the last track is transferred the app writes the m3u8 file(s); during that phase the transfer window's **Cancel** button is still active, although all tracks have already been copied. Cancel should be disabled (or hidden) once the transfer phase is over and only the playlist files remain.
- **Glass panels**: the delete confirmation is now a `GlassModalPresenter` panel (real glass, centred on the main window; panels are not movable) as a test; if it works, the other sheets (transfer report, Send to device, Fix Artwork, …) can follow. Sheets can only blur their own content, so their glass is weak.
- **Known issue (to investigate)**: with the local library, selecting **several albums at once** and sending them, the online artwork choice is not offered for the albums that have no artwork, even though the corresponding option in Settings is on. To check whether the online lookup is only started for single-album/single-track selections.
- **Rule for glass panels**: buttons in dialogs/sheets/panels use `.flatRoomy` / `.flatProminentRoomy` (14 pt side padding); the bars keep 6 pt because their widths are computed. Panels converted so far: delete confirmation, Send to device summary. Known edge: if the plan is cleared elsewhere while the Send-to-device panel is open (e.g. device lost), the panel stays until closed.
- **Glass panels and the main queue**: never call `NSApp.runModal` from inside a `DispatchQueue.main.async` block (or a MainActor `Task`) if the panel's content must load or refresh something: the serial main queue stays busy until the panel closes. Use `onNextRunLoop { … }` (run-loop perform) as the entry point. The Product Image picker keeps the timer-based loader (`OffMainResult`) added while finding this; it can be simplified back to `.task`/`AsyncImage` once the run-loop fix is confirmed.
- **Testing the update window**: with the unit's real `Id`, Garmin's `device-software/v1/updates` answered an empty list for an XML edited to 6.48 (log: «installata 6.48; il server propone »), so the server evaluates the unit, not the XML version. Use the `debugFakeSoftwareUpdate` default (see CHANGELOG) to test the window.
- **Done (glass panels)**: every sheet is now a `GlassModalPresenter` panel — Fix Artwork (`presentFixArtwork()`, in-panel prompt card instead of `.alert`) and the transfer report (`presentTransferReport()`, `TransferReportHost`, in-panel stop confirmation, compact totals grid at reduced height). Panels are centred and NOT movable (all `isMovableByWindowBackground` code removed). `.alert` inside borderless panels is unreliable → use overlay cards. Unverified: background `.alert`s of the main window while the report panel is open. (Product Image loader already simplified back to `.task`.)
- **To do next**: Lossless formats: index FLAC/WAV/AIFF (and ALAC) in External Drive Libraries, blocked and not sendable, with the real format name (ALAC/FLAC/WAV/AIFF) as the reason label instead of "Hi-Res"; no tags → file name as title, folders as artist/album. Open items: BUG: loading a custom playlist from file into a custom list that already has tracks does not check for duplicates (doubles are created) — ask "add anyway / skip duplicates" like the other duplicate prompts; online artwork choice missing when several local albums are sent; GH-1 reply (External Drive Libraries vs XML, how "Hi-Res" is decided for ALAC).

## 16. Context menus, mini player, remote libraries (2.2)
- **Context menus** (`CatalogBrowser.contextMenuItems(...)`, generic over `CatalogTrack`): a track row gets the full menu (Send *n* to Device when several are selected, Send to Custom / Device with the track name cut at 15 characters, divider, Artwork Online Fix — always on the whole selection —, Go to Album / Artist, Find Similar, divider, Show in Playlist submenu only when the track is in a playlist, and "Show only songs without cover" with a check). Playlist / album / artist headers get only the two Send rows, labelled with the element name and song count (`menuSendIDs(for:)`, `(forGroup:)`, `groupLabel`). Send to Device replaces "Send to Watch" and is disabled when no device is connected or the formats are not sendable (e.g. ALAC). Go to / Show in Playlist use `ExternalRevealRequest` (`vm.externalReveal`).
- Subtitles use `subtitleText` and show "(n transferable)" when some selected songs cannot be sent.
- **Mini player**: `.contextMenu` on the whole area (same actions as the track menu on the playing song); mute button with `volumeBeforeMute`.
- **Similar tracks panel**: To Custom / To Device buttons (`canSendToDevice`, `onSendToDevice`).
- **Fix Artwork**: album-mates are found by *album artist* (guest-artist tracks were excluded before). `ArtworkCache.didClearNotification` makes the view model bump `artworkRevision`, which resets `artworkOrigins` — otherwise "Clear artwork cache" left stale origins and the count was wrong.
- **Notification bell**: the outer dot takes the colour of the most severe unread notice (`unreadHasError` → red, else orange); counter font reduced.
- **Remote (network) libraries**: `RemoteLibraryConfig` now stores `serverHost` (real SMB host, e.g. `MacMini-ServerM2-2.local`, read with smbutil when mounted via `refreshNetworkAddress`; the share name shown in Finder can differ and may not resolve). `LibraryReachability.check` probes TCP 445/139 on the candidates (saved host, host from the path, Bonjour variants, spaces encoded). `mountRemoteLibrariesAtLaunch` mounts each library in sequence, 3 attempts 5 s apart, only if the probe answers; an already mounted volume just refreshes the address. **No bookmark fallback**: it hung for more than 2 minutes and showed a system dialog when the server was unreachable. Offline → orange notice; online without server → red after ~1 min, no dialog.
- Ideas not done: retry mounting on network change, manual retry button, parallel mounting of several libraries.
- **Idea (after 2.2, not started): one «External Sources» table.** Settings ▸ Advanced now has two similar tables (Remote Libraries, External Drive Libraries). They could become one table (status dot, Nickname, Path, a small icon for the type) with a «+» menu offering «XML file (network)…» and «Folder on drive…», and one «−». Only the interface would be merged: `RemoteLibraryConfig` and `DriveLibraryConfig` stay separate (mount at launch, server check and the network editor for the remote ones; device catalog and scan for the drive ones). To merge: the two selection states and the pending-name states, the dot tooltip and click (network editor only for remote rows), error messages. Candidate to do together with the «library sources and start-up order» idea above; if network and USB handling turn out too different, leave the two tables as they are.

## 17. 2.2 final (build 19): what was settled after the betas
- **Quit and network volumes.** `AppDelegate.applicationShouldTerminate` returns `.terminateLater` and `finishQuitUnmountingNetwork` runs `AppViewModel.unmountVolumesMountedByApp()`: it unmounts the volumes of the configured remote libraries (found through their bookmarks) that were not mounted when the app started, after stopping the player; up to 4 `unmountAndEjectDevice` attempts 0.6 s apart (OSStatus −47 = busy), 9 s timeout, each result in the detailed log. A forced unmount (`umount -f`) was tried and removed ("Operation not permitted"). If the volume is held by the Finder or another app the app reports it and does not force.
- **Finder "ghost" entries.** Two shares with the same name get different mount points (`/Volumes/Name`, `/Volumes/Name-1`); after unmounting the Finder may keep an empty entry. Display cache only: `killall Finder` or a restart clears it. Documented in the release notes.
- **Spinners.** `BusyScope` (`.library` / `.device`): the device-panel spinner follows `deviceBusy`, the refresh button `libraryBusy || refreshAllRunning`; the title-bar capsule shows everything.
- **Remote libraries.** `Mount automatically` switch (off by default) with a three-state dot (mounted / server answers but not mounted / unreachable); `selectRemoteLibrary` asks before mounting. When a library opens from the saved copy, `RemoteLibraryManager.sourceChangedSinceCache` compares size and date of the XML (no copy) and the title bar warns "changed on the server: press Refresh"; it never re-reads by itself. Cache `external-library-v4-<hash>.json` with the signature of the XML it was built from.
- **Type-ahead in lists.** `TypeAheadMonitor` composes the typed text at key time (event timestamp, 1 s pause); the text is shown in the letter indicator (`ScrollLetterBubble(model:typed:)`, right-aligned, `fixedSize`, last 24 characters). Remote libraries and external drives use only the first letter (`typeAheadFirstLetterOnly`): each scroll is slow on very large lists; the magnifier search is the recommended way there.
- **External drives without a registered Garmin.** `DriveLibraryManager.deviceChoices()` falls back to the "Generic Garmin" profile (AAC, M4A, MP3) and the app offers to rebuild the catalog when a Garmin with different formats is connected. FLAC/ALAC/WAV/AIFF are indexed, labelled with their real format and blocked.
- **Software update check.** Checked against the Garmin server with the real unit: the automatic request returns only the "Map Region Grouping file" (`isPrimaryFirmware=0`); Garmin Express on the same unit showed nothing either, so Garmin's staged distribution is the likely reason and the behaviour is considered correct. The detailed log lists the fields of each element returned; the hidden switch `defaults write com.crdev.MusicManager debugUpdateInteractive -bool YES` sends `IsUserInteractive: true`. For 2.3: treat as firmware only the elements with `isPrimaryFirmware = 1`.
- **Battery level.** Tested on a real Garmin: `LIBMTP_Get_Batterylevel` returns an error (code −1) — the device does not expose the standard MTP property. Not possible; the test code was removed.
- **Icon.** `AppIcon.icon`: the SVG layers no longer carry the transparent bounding `<rect opacity="0">` (with a solid layer colour it was painted as a full rectangle) and `icon.json` has no `color-space-for-untagged-svg-colors` key (older Icon Composer versions reject the file: "The data isn't in the correct format").
- **Final checks.** Quick test on macOS 27.2 (Release Candidate): Garmin connection, remote libraries (the XML exported by the new Music is still valid), USB libraries, AirPlay (HomePod, Apple TV), saving to Music, quit with unmount without ghost volumes.
- **GitHub issue #1** closed on 2026-10-24 (supported libraries: XML exported by Apple Music; no audio conversion; External Drive Libraries born from the report).

## 18. Plan for 2.3
The list of ideas lives in the project document *v2.3 - idee e miglioramenti*. Decided order: **2.3 Beta 1 = performance phase only** (measure and fix the slowdowns after switching between local and network libraries, speed of writing to Music — `AppleMusicScripting.addLines` does one library-wide search per track —, background activity and caches); **2.3 Beta 2 = improvements and additions** (playlist folders as in Music, Custom Playlist with artist emphasised and repetition markers, add to a device playlist with Send, albums sorted by date added, interface colour, Eject button only when needed, playlist file format M3U/M3U8 by device, Apple TV remote commands test, in-playlist icon on the device, device → Custom → device, larger artwork search). Also in the list for later: the `hdiutil create` → `diskutil image create` change in `Scripts/build-release.sh`.

