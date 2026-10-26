# Music Manager 2.2 — release notes (text for the GitHub release)

**Tag:** `v2.2` · Apple Silicon, macOS 26 or later · version 2.2, build 19

[English](#english) · [Italiano](#italiano)

---

## English

### Why this app exists
This app started at home. My wife asked me how to create a playlist and put the tracks on her Garmin Forerunner. The honest answer was a long list of steps: build the playlist in Music, find the files, open Garmin Express, copy things across, check that everything arrived. Too many steps for something that should be simple. Music Manager is meant to be the **single place** where you pick the music, build the playlist and send it to the watch, and where you see what is on the watch.

**Music Manager 2.2** transfers music, albums and playlists from the Music app to a Garmin watch over USB (MTP) and manages what is on the watch. It is an independent project, not affiliated with or endorsed by Garmin or Apple.

### What is new since 2.1

**New: External Drive Libraries** (Settings ▸ Advanced, up to 3)
- Pick a folder of audio files on a USB drive, disk or network folder (subfolders included). The app builds its own index from the tags; no XML exported from Music is needed. Your files are never modified.
- Only formats your Garmin accepts are kept (mp3, m4a, aac, read from the stored `GarminDevice.xml`). If no Garmin has been connected yet, a "Generic Garmin" profile is used and the catalog can be rebuilt when one is connected. FLAC, WAV, AIFF and ALAC are shown, labelled with their real format, and cannot be sent.
- Incremental rescan, covers read from the files (missing ones can be searched online), and an **Eject** button that stops playback, ejects the drive safely and returns to the local library.
- Born from a GitHub issue (see the thanks below).

**Remote (network) libraries**
- More reliable mounting: the app checks that the server answers before opening the share, uses the real server address, tries at most three times and no longer waits minutes or shows a system error when the server is off or on another network.
- New switch **Mount automatically** (off by default). Off: at launch only a light check runs; the status dot shows *mounted* (filled green), *server answers but not mounted* (hollow green) or *not reachable* (red), and choosing a library asks before connecting. On: libraries are mounted at launch.
- First read with live progress ("Copying the XML: 12.4 of 49.7 MB") and a clear message if the transfer stalls; later opens are instant from a saved copy. If the XML on the server has changed since the copy was saved, a warning asks you to press Refresh.
- Playback from a remote library shows "Loading from the remote server…", detects a slow connection and offers to turn remote playback off.
- When the app quits it unmounts the network volumes it mounted itself and leaves the others alone.

**Music, artwork and Custom Playlist**
- **Ask before adding to Music** (Settings ▸ General, on by default): drag and drop can add songs to Music or send them only to the watch.
- Redesigned online artwork panel; the confirmed cover is proposed to every song of the album; the send summary tells *Online Artwork* from *App Cache*.
- The Music library is re-read when you come back to the app, and the file paths are remembered, so starting is faster. New *Threads to read the library* option for Macs where Music slows down.
- Duplicates are listed with a checkbox for each song; loading a playlist file into a filled Custom Playlist asks too. *Load | Save* split button.
- Typing in a list no longer loses letters when the list is large, and the typed text shows in the letter indicator by the scroll bar.

**Interface**
- Floating glass bars, Xcode-style title bar with an activity capsule, a single refresh and search (⌘F), and a notification bell with the last 100 messages (red dot for errors, orange for warnings).
- Every dialog is a centred Liquid Glass panel; a compact mode for low resolutions (minimum window 1024×530).
- Right-click menus for songs, playlists, albums, artists and the mini player; the speaker icon mutes and remembers the volume.
- Selected rows use one rounded highlight in the colour you choose; spinners appear only where the app is working (library, device or both).
- Settings ▸ Advanced: three tables with the same layout, a "+" to add and a nickname asked first.
- Italian texts revised; new app icon.

### Things worth knowing
- **Remote libraries:** the first read is slow, then it is instant. Playback depends on your connection. Typing in a list positions only on the first letter for remote libraries and external drives (each scroll is slow on a very large list): the **magnifier search is much more effective** there.
- **Finder "ghost" entries:** if two shares have the same name, the Finder can keep an empty entry after they are unmounted. It is only a display leftover: `killall Finder` in Terminal, or a restart, clears it.
- **Software update check:** it follows Garmin's staged distribution, the same as Garmin Express. If Garmin Express shows nothing for your watch, the app will not either; it does not claim to detect every update.
- Drive libraries do not import the `.m3u/.m3u8` playlists found in the folder.
- Lossless formats (ALAC, FLAC, WAV, AIFF) are shown but cannot be sent: the app does not convert audio.
- No remote control of the app from the Apple TV; very old AirPlay receivers may be refused by macOS itself.
- Not tested on macOS 26 (developed and tested on macOS 27, including the 27.2 RC). Not notarized: if macOS blocks the first launch, run `xattr -cr "/Applications/Music Manager.app"` (see `docs/INSTALL.md`).

### Thanks
To the user who opened GitHub issue #1: your report, and the detailed testing that followed, helped me shape the idea of External Drive Libraries (folders on USB and network drives). Thank you.

### Included libraries and checksum
- libmtp: _fill in with `brew list --versions libmtp`_ · libusb: _fill in with `brew list --versions libusb`_ (LGPL 2.1+, see `licenses/`).
- SHA-256 of the DMG: _fill in from the `.sha256` file_.

Free software, GPL v3.0.

---

## Italiano

### Perché esiste questa app
L'app è nata in casa. Mia moglie mi ha chiesto come creare una playlist e mettere i brani sul suo Garmin Forerunner. La risposta onesta era un elenco lungo di passaggi: creare la playlist in Musica, trovare i file, aprire Garmin Express, copiare, controllare che fosse arrivato tutto. Troppi passaggi per una cosa che dovrebbe essere semplice. Music Manager vuole essere **un unico posto** dove scegliere la musica, comporre la playlist e inviarla all'orologio, e dove vedere cosa c'è sull'orologio.

**Music Manager 2.2** trasferisce musica, album e playlist dall'app Musica a un orologio Garmin via USB (MTP) e gestisce ciò che c'è sull'orologio. È un progetto indipendente, non affiliato né approvato da Garmin o Apple.

### Novità rispetto alla 2.1

**Novità: librerie su unità esterna** (Impostazioni ▸ Avanzate, fino a 3)
- Scegli una cartella di file audio su una chiavetta USB, un disco o una cartella di rete (sottocartelle comprese). L'app crea un proprio indice dai tag; non serve un XML esportato da Musica. I tuoi file non vengono mai modificati.
- Restano solo i formati che il tuo Garmin accetta (mp3, m4a, aac, dal `GarminDevice.xml` salvato). Se non è mai stato collegato un Garmin si usa un profilo «Garmin generico», e il catalogo si può ricostruire quando se ne collega uno. FLAC, WAV, AIFF e ALAC sono mostrati con il loro formato reale e non sono inviabili.
- Riscansione incrementale, copertine lette dai file (per le mancanti c'è la ricerca online) e pulsante **Espelli**, che ferma la riproduzione, espelle l'unità in sicurezza e torna alla libreria locale.
- Nata da una segnalazione su GitHub (vedi i ringraziamenti).

**Librerie remote (di rete)**
- Montaggio più affidabile: l'app controlla che il server risponda prima di aprire la condivisione, usa l'indirizzo reale del server, prova al massimo tre volte e non attende più minuti né mostra errori di sistema quando il server è spento o su un'altra rete.
- Nuovo interruttore **Monta automaticamente** (spento di default). Spento: all'avvio c'è solo un controllo leggero; il pallino indica *montata* (verde pieno), *il server risponde ma non è montata* (verde vuoto) o *non raggiungibile* (rosso), e scegliendo una libreria l'app chiede prima di collegarsi. Acceso: le librerie si montano all'avvio.
- Prima lettura con avanzamento in tempo reale («Copia dell'XML: 12,4 di 49,7 MB») e un messaggio chiaro se il trasferimento si blocca; le aperture successive sono immediate da una copia salvata. Se l'XML sul server è cambiato dopo il salvataggio della copia, un avviso chiede di premere Aggiorna.
- La riproduzione da una libreria remota mostra «Caricamento dal server remoto…», riconosce una connessione lenta e propone di disattivare la riproduzione remota.
- Alla chiusura l'app smonta i volumi di rete che ha montato lei e lascia gli altri.

**Musica, copertine e Custom Playlist**
- **Chiedi prima di aggiungere a Musica** (Impostazioni ▸ Generale, attivo di default): con il trascinamento i brani si possono aggiungere a Musica oppure inviare solo all'orologio.
- Pannello delle copertine online ridisegnato; la copertina confermata è proposta a ogni brano dell'album; il riepilogo di invio distingue *Online Artwork* da *App Cache*.
- La libreria di Musica viene riletta quando torni nell'app e i percorsi dei file sono ricordati, quindi l'avvio è più veloce. Nuova opzione *Thread per leggere la libreria* per i Mac su cui Musica rallenta.
- I duplicati sono elencati con una casella per ogni brano; anche il caricamento di un file playlist in una Custom Playlist piena chiede. Pulsante diviso *Carica | Salva*.
- Digitando in un elenco non si perdono più lettere quando l'elenco è grande, e il testo digitato compare nell'indicatore della lettera accanto alla barra di scorrimento.

**Interfaccia**
- Barre di vetro fluttuanti, barra del titolo in stile Xcode con capsula di attività, un solo aggiorna e una sola ricerca (⌘F), campanella con gli ultimi 100 messaggi (pallino rosso per gli errori, arancione per gli avvisi).
- Ogni finestra è un pannello Liquid Glass centrato; modalità compatta per le risoluzioni basse (finestra minima 1024×530).
- Menu del tasto destro per brani, playlist, album, artisti e mini player; l'icona dell'altoparlante attiva il muto e ricorda il volume.
- Le righe selezionate usano un solo evidenziatore arrotondato nel colore scelto; le rotelle compaiono solo dove l'app lavora (libreria, dispositivo o entrambi).
- Impostazioni ▸ Avanzate: tre tabelle con la stessa struttura, «+» per aggiungere e nickname richiesto subito.
- Testi italiani rivisti; nuova icona dell'app.

### Cose da sapere
- **Librerie remote:** la prima lettura è lenta, poi è immediata. La riproduzione dipende dalla tua connessione. Con le librerie remote e le unità esterne la digitazione in un elenco posiziona solo sulla prima lettera (ogni scorrimento è lento su un elenco molto grande): lì la **ricerca con la lente è molto più efficace**.
- **Voci «fantasma» nel Finder:** se due condivisioni hanno lo stesso nome, dopo lo smontaggio il Finder può lasciare una voce vuota. È solo un residuo grafico: `killall Finder` nel Terminale, oppure un riavvio, lo elimina.
- **Controllo aggiornamenti software:** segue la distribuzione a gruppi di Garmin, come Garmin Express. Se Garmin Express non mostra nulla per il tuo orologio, non lo mostra nemmeno l'app: non promette di rilevare ogni aggiornamento.
- Le librerie su unità non importano le playlist `.m3u/.m3u8` trovate nella cartella.
- I formati lossless (ALAC, FLAC, WAV, AIFF) sono mostrati ma non inviabili: l'app non converte l'audio.
- Nessun controllo dell'app dall'Apple TV; ricevitori AirPlay molto vecchi possono essere rifiutati da macOS stesso.
- Non provata su macOS 26 (sviluppata e provata su macOS 27, anche la 27.2 RC). Non notarizzata: se macOS blocca il primo avvio, esegui `xattr -cr "/Applications/Music Manager.app"` (vedi `docs/INSTALL.md`).

### Ringraziamenti
All'utente che ha aperto la issue GitHub n. 1: la segnalazione, e i test dettagliati che ne sono seguiti, mi hanno aiutato a sviluppare l'idea delle librerie su unità esterna (cartelle su USB e dischi di rete). Grazie.

### Librerie incluse e checksum
- libmtp: _da compilare con `brew list --versions libmtp`_ · libusb: _da compilare con `brew list --versions libusb`_ (LGPL 2.1+, vedi `licenses/`).
- SHA-256 del DMG: _da compilare dal file `.sha256`_.

Software libero, GPL v3.0.
