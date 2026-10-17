# Music Manager — Project Notes

**Current version: 2.1 Beta 3 (build 15)** · macOS 26+ · Apple Silicon only · GPL v3.0 · © 2026 Riccardo Colaiori (cr.developer)

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

## 3. Feature overview (2.1 Beta 3)

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

- Verify Beta 3 on hardware: menu flicker fix (same recording as before), album/artist "on device" arrows, file manager, tooltips and legend threshold, *Save GarminDevice.xml*.
- Real macOS 26 test; confirm the bundled libraries load there.
- Icon: `AppIcon.icon` is now the author's own Icon Composer bundle (3 layers); to be refined later.
- Statistics panel (idea, not designed).
- Public 2.1: updated user guide, final README.

**Decisions (2026-10-17):** the Device File Manager **stays** in the public release (read-only on the device, off by default behind Settings ▸ Advanced ▸ Tools): it lets users browse the watch without third-party programs. Streaming space measurements are closed (Spotify not measurable without Premium).
