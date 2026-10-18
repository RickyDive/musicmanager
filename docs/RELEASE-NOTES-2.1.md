# Music Manager 2.1 — release notes (text for the GitHub release)

**Music Manager 2.1** — transfers music, albums and playlists from the Music app to a Garmin watch over USB (MTP) and manages what is on the watch. Apple Silicon, macOS 26 or later.

### What is new since 2.0
- Genre filter, *Find similar*, multi-disc albums, "on device" arrows, Shift-click and drag selection.
- Send several playlists at once, mixed sends, a **Cancel** button with a clear summary; Send is disabled when the selection does not fit.
- Delete confirmation sheet that rewrites the affected playlists.
- Rebuilt storage bar (*System*, *Data*, *Maps*, *Services*, *Music*), free space written in the bar, *Storage Capacity*, orange/red warning when space is almost gone.
- Player with working volume on Apple TV, HomePod and amplifiers, slider that follows the AirPlay device, Now Playing info on the Apple TV, media keys.
- Garmin devices that mount as a disk (information, Eject); *experimental* music on external drives and SD cards (off by default).
- Optional read-only Device File Manager, detailed log switch, diagnostic snapshots.
- Faster start (the Music library is read in parallel). New name, icon and flat buttons.

### Known limits
- **Not tested on macOS 26** (developed and tested on macOS 27).
- **Not notarized**: if macOS blocks or slows the first launch, run `xattr -cr "/Applications/Music Manager.app"` (see `docs/INSTALL.md`).
- No remote control of the app from the Apple TV; very old AirPlay receivers may be refused by macOS itself.

### Included libraries and checksum
- libmtp: _1.1.23_ · libusb: _1.0.30_ (LGPL 2.1+, see `licenses/`).
- SHA-256 of the DMG: _d3d38801d1538559c8636eebd4ec553360e87cad56c388349201d865339ba68a_

Free software, GPL v3.0. Independent project, not affiliated with Garmin or Apple.
