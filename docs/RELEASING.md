# Publishing a release (maintainer)

1. `brew install libmtp xcodegen` (once).
2. `Scripts/build-release.sh` creates `build/MusicManager-<version>.dmg` and its `.sha256`.
3. On GitHub: Releases ▸ Draft a new release ▸ tag (e.g. `v2.1-beta3`), tick "pre-release" for betas, attach the DMG and the `.sha256`, paste the relevant section of `CHANGELOG.md` and the text of `docs/INSTALL.md`.
4. `MMFeedbackURL` in `project.yml` is already set to `https://github.com/RickyDive/musicmanager/issues/new/choose`; Help ▸ Send Feedback opens that page.
5. The repository must also contain the source (LGPL requirement for the bundled libraries; the links to the sources are in `THIRD-PARTY-LICENSES.txt`).
6. In the release notes state the versions of libmtp and libusb included (`brew list --versions libmtp libusb`) and the sha256 of the DMG.
7. License: GPL v3.0 (`LICENSE` file); bundled libraries LGPL 2.1+ (`licenses/` folder).

## Bundled libraries and minimum macOS version
Homebrew libraries (libmtp, libusb) are built for the macOS version Homebrew runs on: on macOS 27 they declare 27.0 as minimum and Xcode warns ("Building for macOS-26.0, but linking with dylib … built for newer version 27.0"). If they stayed that way in the package, the app would **not start on macOS 26**. `Scripts/bundle-libs.sh` therefore lowers the minimum version of the bundled libraries to the app's (`vtool`), and `Scripts/verify-bundle.sh` fails if a library requires more than macOS 26.0. Manual check: `vtool -show-build "Music Manager.app/Contents/Frameworks/libmtp.9.dylib" | grep minos`.
