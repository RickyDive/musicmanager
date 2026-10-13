MUSIC MANAGER – Installazione / Installation
=============================================

ITALIANO
--------
Requisiti: Mac con Apple Silicon, macOS 26 o successivo, orologio Garmin con cavo USB.

0. Scarica solo da https://github.com/RickyDive/musicmanager/releases e verifica l'hash: `shasum -a 256 MusicManager-<versione>.dmg` deve coincidere con il file `.sha256` della release.
1. Apri il DMG e trascina "Music Manager" nella cartella Applicazioni.
2. L'app non è notarizzata (lo sviluppatore non ha un account Apple Developer): macOS non la apre al primo avvio. È normale. Hai due metodi.

   METODO A – Terminale (consigliato, funziona anche su macOS 27 dove il metodo B può bloccarsi)
   Apri Terminale ed esegui, una riga alla volta:
       xattr -cr "/Applications/Music Manager.app"
       open "/Applications/Music Manager.app"
   Il primo comando toglie il blocco di quarantena applicato da macOS ai file scaricati.

   METODO B – Impostazioni di Sistema
   Impostazioni di Sistema ▸ Privacy e sicurezza, scorri in basso e clicca "Apri comunque" accanto a "Music Manager". Conferma con la password.
   Se l'app non si apre e resta bloccata (anche l'Uscita forzata può non bastare): riavvia il Mac e usa il Metodo A prima di riaprirla.

3. Alla prima lettura/invio macOS chiede il permesso di controllare "Musica" (automazione): clicca OK. Senza questo permesso l'app non può leggere la libreria né creare playlist. Se l'hai negato per errore: Impostazioni di Sistema ▸ Privacy e sicurezza ▸ Automazione ▸ Music Manager ▸ attiva "Musica".
4. Se l'orologio non viene rilevato: chiudi Garmin Express / Android File Transfer / Acquisizione Immagine, ricollega il cavo.

Problemi? Menu Aiuto ▸ "Copia informazioni diagnostiche" e incollale nella segnalazione su GitHub. Se l'app non riesce nemmeno ad aprirsi, indica nella segnalazione la versione di macOS e il metodo usato.

ENGLISH
-------
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
