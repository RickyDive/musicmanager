# Music Manager 2.3 Beta 1 — release notes (text for the GitHub pre-release)

**Tag:** `v2.3-beta1` (pre-release) · Apple Silicon, macOS 26 or later · version 2.3 Beta 1, build 34

[English](#english) · [Italiano](#italiano)

---

## English

**Music Manager 2.3 Beta 1 is a performance release: no new features.** It comes from slowdowns reported after 2.2 with very large libraries (a network library of 55,507 songs). Every fix below was found by measuring first (a detailed log and Xcode's Time Profiler), not by guessing.

Music Manager transfers music, albums and playlists from the Music app to a Garmin watch over USB (MTP) and manages what is on the watch. It is an independent project, not affiliated with or endorsed by Garmin or Apple.

### What changed since 2.2

**Lists with tens of thousands of songs**
- Opening and closing an artist or an album no longer re-counts all its songs at every redraw: the counts are computed once per group and reused.
- With *Show only transferable songs* on, the filtered lists are no longer rebuilt at every interface update.
- With large libraries (over 5,000 songs: network libraries and external drives) only the tab you are looking at keeps its list alive. Before, the hidden Songs list (55,000 rows, over 1 GB of memory after scrolling) was updated at every click and made every tab slow.
- Result on a 55,454-song network library: the freezes of 1–15 s on clicks became mostly under 1 s, and memory stays around 400–700 MB instead of reaching 1.6 GB.

**Typing to jump in a list**
- Typing one letter or several (for example «pino») in Songs, Albums or Artists no longer freezes the window: from 7–15 s to 0.01–0.2 s on a 55,454-song library.
- The match now lands just under the floating panel with the previous entry still visible above it (typing Q shows the last P, then Queen), on libraries of any size.

**Detailed log (Settings ▸ «Detailed log (diagnostics)»)**
- With the option on, lines starting with `[prestazioni]` show the seconds of each operation, the rebuilding of the lists, memory and threads before and after, every Music write (seconds per song) and every freeze of the interface longer than 0.35 s (`INTERFACCIA FERMA`, with the last click or key). Off by default; useful if you see a slowdown: turn it on and send the log with your report.

### Things worth knowing
- **Saving a playlist to Music is fast for songs already in your library** (100 songs in about 2.5 s). When the playlist contains **files that are not yet in Music** (for example from an external drive), Music itself has to import and copy them: about 0.7 s per song (165 files took 122 s). During that time the app window does not respond. This is the next thing to improve (a progress panel and a non-blocking save are planned for the next beta).
- With large libraries (over 5,000 songs) the scroll position of a tab is not kept when you change tab.
- For network libraries and external drives, typing still positions only on the first letter; the **magnifier search** is the better tool there.
- Remote libraries: the first read is slow, then it is instant. Playback depends on your connection.
- Lossless formats (ALAC, FLAC, WAV, AIFF) are shown but cannot be sent: the app does not convert audio.
- Not tested on macOS 26 (developed and tested on macOS 27, including 27.2). Not notarized: if macOS blocks the first launch, run `xattr -cr "/Applications/Music Manager.app"` (see `docs/INSTALL.md`).
- This is a beta: please report problems on GitHub, attaching the log if possible.

### Included libraries and checksum
- libmtp: _fill in with `brew list --versions libmtp`_ · libusb: _fill in with `brew list --versions libusb`_ (LGPL 2.1+, see `licenses/`).
- SHA-256 of the DMG: _fill in from the `.sha256` file_.

Free software, GPL v3.0.

---

## Italiano

**Music Manager 2.3 Beta 1 è una versione dedicata alle prestazioni: nessuna funzione nuova.** Nasce dai rallentamenti segnalati dopo la 2.2 con librerie molto grandi (una libreria di rete da 55.507 brani). Ogni correzione qui sotto è stata trovata misurando prima (log dettagliato e Time Profiler di Xcode), non a intuito.

Music Manager trasferisce musica, album e playlist dall'app Musica a un orologio Garmin via USB (MTP) e gestisce ciò che c'è sull'orologio. È un progetto indipendente, non affiliato né approvato da Garmin o Apple.

### Cosa è cambiato rispetto alla 2.2

**Elenchi con decine di migliaia di brani**
- Aprire e chiudere un artista o un album non ricalcola più i conteggi di tutti i suoi brani a ogni ridisegno: i conteggi si calcolano una volta per gruppo e si riusano.
- Con *Mostra solo i brani trasferibili* attivo, gli elenchi filtrati non si ricostruiscono più a ogni aggiornamento dell'interfaccia.
- Con librerie grandi (oltre 5.000 brani: librerie di rete e unità esterne) solo la scheda che stai guardando tiene viva la sua lista. Prima l'elenco Brani nascosto (55.000 righe, oltre 1 GB di memoria dopo lo scorrimento) veniva aggiornato a ogni clic e rallentava tutte le schede.
- Risultato su una libreria di rete da 55.454 brani: i blocchi di 1–15 s sui clic sono diventati per lo più sotto il secondo, e la memoria resta intorno a 400–700 MB invece di arrivare a 1,6 GB.

**Digitazione per posizionarsi in un elenco**
- Digitare una lettera o più lettere (per esempio «pino») in Brani, Album o Artisti non blocca più la finestra: da 7–15 s a 0,01–0,2 s su una libreria da 55.454 brani.
- La voce trovata si ferma subito sotto il pannello fluttuante, con la voce precedente ancora visibile sopra (digitando Q si vede l'ultima P e poi Queen), su librerie di qualsiasi dimensione.

**Log dettagliato (Impostazioni ▸ «Registro dettagliato (diagnostica)»)**
- Con l'opzione accesa, le righe che iniziano con `[prestazioni]` mostrano i secondi di ogni operazione, la ricostruzione degli elenchi, memoria e thread prima e dopo, ogni scrittura in Musica (secondi per brano) e ogni blocco dell'interfaccia oltre 0,35 s (`INTERFACCIA FERMA`, con l'ultimo clic o tasto). Spento di default; utile se noti un rallentamento: accendilo e invia il log con la segnalazione.

### Cose da sapere
- **Salvare una playlist in Musica è veloce per i brani già nella tua libreria** (100 brani in circa 2,5 s). Quando la playlist contiene **file non ancora in Musica** (per esempio da un'unità esterna), è Musica stessa a doverli importare e copiare: circa 0,7 s per brano (165 file hanno richiesto 122 s). In quel tempo la finestra dell'app non risponde. È il prossimo punto da migliorare (un pannello di avanzamento e un salvataggio che non blocca sono previsti per la prossima beta).
- Con librerie grandi (oltre 5.000 brani) la posizione di scorrimento di una scheda non si conserva quando si cambia scheda.
- Con le librerie di rete e le unità esterne la digitazione posiziona ancora solo sulla prima lettera; lì è più efficace la **ricerca con la lente**.
- Librerie remote: la prima lettura è lenta, poi è immediata. La riproduzione dipende dalla tua connessione.
- I formati lossless (ALAC, FLAC, WAV, AIFF) sono mostrati ma non inviabili: l'app non converte l'audio.
- Non provata su macOS 26 (sviluppata e provata su macOS 27, anche la 27.2). Non notarizzata: se macOS blocca il primo avvio, esegui `xattr -cr "/Applications/Music Manager.app"` (vedi `docs/INSTALL.md`).
- È una beta: segnala i problemi su GitHub, allegando il log se possibile.

### Librerie incluse e checksum
- libmtp: _da compilare con `brew list --versions libmtp`_ · libusb: _da compilare con `brew list --versions libusb`_ (LGPL 2.1+, vedi `licenses/`).
- SHA-256 del DMG: _da compilare dal file `.sha256`_.

Software libero, GPL v3.0.
