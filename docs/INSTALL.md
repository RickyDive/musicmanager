MUSIC MANAGER – Installation
============================

Requirements: Apple Silicon Mac, macOS 26 or later, Garmin watch with USB cable.

0. Download only from https://github.com/RickyDive/musicmanager/releases and verify the hash: `shasum -a 256 MusicManager-<version>.dmg` must match the release's `.sha256` file.
1. Open the DMG and drag "Music Manager" to Applications.
2. The app is not notarized (the developer has no Apple Developer account): macOS will not open it on first launch. This is expected. You have two methods.

   METHOD A – Terminal (recommended; it also works on macOS 27, where method B may hang)
   Open Terminal and run, one line at a time:
       xattr -cr "/Applications/Music Manager.app"
       open "/Applications/Music Manager.app"
   The first command removes the quarantine flag macOS puts on downloaded files.

   METHOD B – System Settings
   System Settings ▸ Privacy & Security, scroll down and click "Open Anyway" next to "Music Manager". Confirm with your password.
   If the app does not open and stays stuck (even Force Quit may not be enough): restart the Mac and use Method A before opening it again.

3. On first read/send macOS asks permission to control "Music" (automation): click OK. Without it the app cannot read your library or create playlists. If you denied it by mistake: System Settings ▸ Privacy & Security ▸ Automation ▸ Music Manager ▸ enable "Music".
4. If the watch is not detected: quit Garmin Express / Android File Transfer / Image Capture and reconnect the cable.

Problems? Help ▸ "Copy Diagnostic Information" and paste it in your GitHub issue. If the app cannot even open, include your macOS version and the method you used.
