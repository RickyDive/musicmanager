# Publishing a release (maintainer)

Release DMGs are built by GitHub Actions (`.github/workflows/`) from the tagged source, not on anyone's own Mac. Anyone can then check how a DMG was made: the run page shows the commit, every build step and the SHA-256 of the DMG. The workflow only creates a **draft**: the maintainer checks it and publishes it. DMGs are never committed: `.gitignore` excludes them.

## Versioned release
1. Set `CFBundleShortVersionString` (e.g. `2.4` or `2.4 Beta 1`) and `CFBundleVersion` in `project.yml`, and add the section to `CHANGELOG.md` (heading `## 2.4 Beta 1 — build 40`).
2. Optional: write curated notes in `docs/RELEASE-NOTES-<version>.md` (e.g. `docs/RELEASE-NOTES-2.4.md`, `docs/RELEASE-NOTES-2.4-beta1.md`).
3. Tag the commit and push the tag: `git tag v2.4 && git push origin v2.4` (beta: `v2.4-beta1`). Betas are tagged on the `beta` branch, finals on `main`.
4. The **Release** workflow runs:
   - it checks the tag matches `CFBundleShortVersionString` in `project.yml` on the tagged commit, and fails otherwise;
   - it runs `Scripts/build-release.sh` on a GitHub macOS runner;
   - it creates a draft release named `Music Manager v<version> (CI build)` with the DMG, its `.sha256`, a link to the run, the release notes (from `docs/RELEASE-NOTES-<version>.md`, else the `CHANGELOG.md` section), the bundled libmtp/libusb versions and the changeset since the previous tag. Betas are flagged as pre-releases.
5. Download the DMG from the draft and check it on your Mac. Then open the draft ▸ Edit, optionally rename it, tick *Set as the latest release* for a final release, and **Publish release**.

The draft is visible only to people with write access. The workflow never publishes a release, never marks one *Latest* and never changes a release it did not create. Re-running it replaces only its own draft.

The tagged commit must contain `.github/workflows/`, because GitHub runs the workflows of the tagged commit: merge `main` into `beta` before tagging a beta. To rebuild an existing tag: Actions ▸ Release ▸ Run workflow ▸ tag.

## Building by hand instead
`brew install libmtp libusb xcodegen` (once), then `Scripts/build-release.sh` creates `build/MusicManager-<version>.dmg` and its `.sha256`. To publish that DMG instead: Releases ▸ Draft a new release ▸ tag, tick "pre-release" only for betas, attach the DMG and the `.sha256`, paste the release notes and the text of `docs/INSTALL.md`. The tag still triggers the workflow, but its draft never replaces or duplicates your release: delete the draft when you no longer need it.

A DMG built by hand and the CI one will not have the same SHA-256 (different Xcode versions, ad hoc signatures and disk image timestamps). Compare their contents instead, e.g. mount both and run `diff -r` on the apps, or compare `vtool -show-build` and `otool -L` of the binary and the bundled libraries.

## Pull requests
Every pull request that touches the app (`MusicManager/`, `Scripts/`, `project.yml`) builds the DMG. It is attached to the run page for 7 days and nothing is published.

## Requirements
- `Scripts/` must be committed: CI builds with `Scripts/build-release.sh`, and `project.yml` runs `Scripts/bundle-libs.sh` as a build phase.
- `MMFeedbackURL` in `project.yml` points to `https://github.com/RickyDive/musicmanager/issues/new/choose`; Help ▸ Send Feedback opens that page.
- The repository must contain the source (LGPL requirement for the bundled libraries; the links to the sources are in `THIRD-PARTY-LICENSES.txt`).
- License: GPL v3.0 (`LICENSE` file); bundled libraries LGPL 2.1+ (`licenses/` folder).
- Optional repository variables: `RUNNER_MACOS` (JSON runner labels instead of `macos-26`), `XCODE_VERSION` (e.g. `26.1`).

## Bundled libraries and minimum macOS version
Homebrew libraries (libmtp, libusb) are built for the macOS version Homebrew runs on: on macOS 27 they declare 27.0 as minimum and Xcode warns ("Building for macOS-26.0, but linking with dylib … built for newer version 27.0"). If they stayed that way in the package, the app would **not start on macOS 26**. `Scripts/bundle-libs.sh` therefore lowers the minimum version of the bundled libraries to the app's (`vtool`), and `Scripts/verify-bundle.sh` fails if a library requires more than macOS 26.0. Manual check: `vtool -show-build "Music Manager.app/Contents/Frameworks/libmtp.9.dylib" | grep minos`.
