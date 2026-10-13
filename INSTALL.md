MUSIC MANAGER – Installazione / Installation
=============================================

ITALIANO
--------
Requisiti: Mac con Apple Silicon, macOS 26 o successivo, orologio Garmin con cavo USB.

0. Scarica solo da https://github.com/RickyDive/musicmanager/releases e verifica l'hash: `shasum -a 256 MusicManager-<versione>.dmg` deve coincidere con il file `.sha256` della release.
1. Apri il DMG e trascina "Music Manager" nella cartella Applicazioni.
2. Al primo avvio macOS dirà che l'app non può essere aperta (non è notarizzata: lo sviluppatore non ha un account Apple Developer). È normale.
3. Apri Impostazioni di Sistema ▸ Privacy e sicurezza, scorri in basso e clicca "Apri comunque" accanto a "Music Manager". Conferma con la password.
   In alternativa, da Terminale:
       xattr -dr com.apple.quarantine "/Applications/Music Manager.app"
4. Alla prima lettura/invio macOS chiede il permesso di controllare "Musica" (automazione): clicca OK. Senza questo permesso l'app non può leggere la libreria né creare playlist. Se l'hai negato per errore: Impostazioni di Sistema ▸ Privacy e sicurezza ▸ Automazione ▸ Music Manager ▸ attiva "Musica".
5. Se l'orologio non viene rilevato: chiudi Garmin Express / Android File Transfer / Acquisizione Immagine, ricollega il cavo.

Problemi? Menu Aiuto ▸ "Copia informazioni diagnostiche" e incollale nella segnalazione su GitHub.

ENGLISH
-------
Requirements: Apple Silicon Mac, macOS 26 or later, Garmin watch with USB cable.

0. Download only from https://github.com/RickyDive/musicmanager/releases and verify the hash: `shasum -a 256 MusicManager-<version>.dmg` must match the release's `.sha256` file.
1. Open the DMG and drag "Music Manager" to Applications.
2. On first launch macOS says the app cannot be opened (it is not notarized: the developer has no Apple Developer account). This is expected.
3. Open System Settings ▸ Privacy & Security, scroll down and click "Open Anyway" next to "Music Manager". Confirm with your password.
   Or, from Terminal:
       xattr -dr com.apple.quarantine "/Applications/Music Manager.app"
4. On first read/send macOS asks permission to control "Music" (automation): click OK. Without it the app cannot read your library or create playlists. If you denied it by mistake: System Settings ▸ Privacy & Security ▸ Automation ▸ Music Manager ▸ enable "Music".
5. If the watch is not detected: quit Garmin Express / Android File Transfer / Image Capture and reconnect the cable.

Problems? Help ▸ "Copy Diagnostic Information" and paste it in your GitHub issue.
