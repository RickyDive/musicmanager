# Pubblicare una release (manutentore)
1. `brew install libmtp xcodegen` (una volta).
2. `Scripts/build-release.sh` → crea `build/MusicManager-<versione>.dmg` e il suo `.sha256`.
3. Su GitHub: Releases ▸ Draft a new release ▸ tag `v2.1-beta1`, spunta "pre-release", allega DMG e sha256, incolla il testo di `docs/INSTALL.md`.
4. Imposta `MMFeedbackURL` in `project.yml` (già impostato: `https://github.com/RickyDive/musicmanager/issues/new/choose`) e ricompila: la voce Aiuto ▸ Invia feedback aprirà quella pagina.
5. Il repository deve contenere anche il sorgente (requisito LGPL per le librerie incluse: link ai sorgenti in THIRD-PARTY-LICENSES.txt).
6. Nelle note della release indica le versioni di libmtp e libusb incluse (`brew list --versions libmtp libusb`) e l'hash sha256 del DMG.
7. Licenza: GPL v3.0 (file `LICENSE`); librerie incluse LGPL 2.1+ (cartella `licenses/`).

## Librerie incorporate e versione minima di macOS
Le librerie Homebrew (libmtp, libusb) vengono compilate per il macOS su cui gira Homebrew: su macOS 27 dichiarano come minima la 27.0 e Xcode avvisa («Building for macOS-26.0, but linking with dylib … built for newer version 27.0»). Se restassero così nel pacchetto, l'app **non partirebbe su macOS 26**. `Scripts/bundle-libs.sh` riporta quindi la versione minima delle librerie incorporate a quella dell'app (`vtool`), e `Scripts/verify-bundle.sh` fallisce se una libreria richiede più di macOS 26.0. Controllo manuale: `vtool -show-build "Music Manager.app/Contents/Frameworks/libmtp.9.dylib" | grep minos`.
