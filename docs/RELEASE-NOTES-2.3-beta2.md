# Music Manager 2.3 Beta 2 — release notes (text for the GitHub pre-release)

**Tag:** `v2.3-beta2` (pre-release) · Apple Silicon, macOS 26 or later · version 2.3 Beta 2, build 46

[English](#english) · [Italiano](#italiano)

---

## English

**Music Manager 2.3 Beta 2 is the improvements-and-additions release that follows the performance work of Beta 1.** It adds Apple Music playlist folders, albums sorted by date added, a clearer Custom Playlist, safer sending, a better Fix Artwork panel and software/maps update notices, and it brings Albums, Artists and Songs back to the stable 2.2 list code after an experiment with a new list engine proved unreliable on very large libraries.

Music Manager transfers music, albums and playlists from the Music app to a Garmin watch over USB (MTP) and manages what is on the watch. It is an independent project, not affiliated with or endorsed by Garmin or Apple.

### What is new since 2.3 Beta 1

**Playlists**
- **Folders as in Apple Music** (local library): the Playlists tab shows the same tree of folders and playlists, opened with the same chevrons as Artist ▸ Album. At each level: folders first, then smart/Genius playlists, then regular ones, each group alphabetical. Empty folders are hidden; searching opens the folders that contain results. Remote libraries and external drives keep the flat list.
- **Thumbnails**: every playlist has a 32 pt cover: a 2×2 mosaic of four different albums, the first track's cover if there are fewer than four albums, a gear icon for smart/Genius playlists (Music does not expose the cover you set on a playlist).

**Albums, Artists, Songs**
- **Albums by date added**: Settings ▸ General ▸ *Show Albums* (Alphabetical / Date added). With *Date added* the newest albums come first, as in Apple Music; the label next to the scroll cursor shows the period (This week, This month, Last three months, then the year).
- Albums, Artists and Songs use again the native lists of 2.2 (nested groups, selection circle on every track): the experimental flat-row engine made the lists jump or draw blank on large libraries (visible with a 55,000-song network library) and stays only in Playlists. «Disc n of m» headers are kept and aligned with the album title.
- **One selection mark** everywhere: green circle with a check (all) or a dash (partial); on playlists it sits on the corner of the cover.
- **Right-click**: on an unselected track the previous selection is kept and the clicked track is added; «Send "track" only» sends just that one and leaves your selection untouched; the menu offers «Go to Artist» in Albums, «Go to Album» in Artists, both in Songs and in the player.

**Custom Playlist**
- *Artist first* option (Settings ▸ General): artist on the main line, title and album on the small one; quick switch in the bar, with the sort button in the same pill.
- Discreet **×N badges** when the same artist, the same album or the very same song (orange) appears several times.
- Clearer selection: one band in the colour you chose (it used to overlap a system-blue band). Click selects, ⌘-click adds/removes, ⇧-click selects a range; dragging a selected row still moves all selected rows. The keyboard arrows and ⌘A do not act on this list.

**Sending to the watch**
- With exactly one playlist selected on the device, *Send* asks «Add N tracks to the playlist X?» (Add / Only Send / Cancel).
- A second send cannot start while one is being prepared, even after changing library; the status bar says «Analyzing N tracks…» so the app does not look frozen. The online artwork proposal now comes once, when sending.
- **Saving to Music** runs in batches off the main thread: the window stays responsive, a progress capsule shows «Saving to Music: n/total songs» with a Cancel button.

**Fix Artwork**
- Up to 10 candidates (was 5) with a more tolerant match: version tags such as «(End Title)» or «[Remastered]» are ignored, the artist can be partly different, and the song's own album (compilations, soundtracks) is searched first.
- «Ignore» skips the whole album, and the panel closes when no other album is left. Songs of an album tagged *Compilation* are handled as one album.
- The cover you choose now shows in lists and in the player. «Search artwork online…» is also in the right-click menu of album, artist and playlist headers.

**Updates and device panel**
- **Software update notice** also in the notification bell; the badge shows the available version («Upgrade Available: 6.73»). The check now asks Garmin's server the way Garmin Express does, and a data file such as «Time Zone Map 43.00» is no longer reported as a software update.
- Filled maps icon, filled check/cross next to the software version, and readable «Software Updated», «Map Updated», «Upgrade Available» and «Check Needed» badges in dark mode.
- Device bar: *Eject* (only when the device is managed as a volume) before the storage selector, *Connect/Disconnect* last on the right. New option *Interface uses the selection color*.

**Detailed log**
- The log keeps up to 4 MB (it was cut at 150 KB), keeps the start of the session, and records Mac sleep or the app being in the background as «pausa» instead of an interface freeze.

### Things worth knowing
- This is a beta; the new Custom Playlist selection and the Fix Artwork changes were tested on macOS 27.2 with the author's libraries.
- Not tested on macOS 26 (developed and tested on macOS 27, including 27.2). Not notarized: if macOS blocks the first launch, run `xattr -cr "/Applications/Music Manager.app"` (see `docs/INSTALL.md`).
- Fix Artwork cannot yet restore the original artwork after you chose another one (planned for the next beta). A cover already sent to the watch stays there until the song is sent again.
- On very large libraries (over 5,000 songs) the scroll position is not kept when changing tab, and typing in lists of network libraries positions only on the first letter: use the magnifier search.
- Lossless formats (ALAC, FLAC, WAV, AIFF) are shown but cannot be sent.
- The update notice follows Garmin's staged distribution, as Garmin Express does.
- Please report problems on GitHub, attaching the log (Settings ▸ «Detailed log») if possible.

### Included libraries and checksum
- libmtp: _fill in with `brew list --versions libmtp`_ · libusb: _fill in with `brew list --versions libusb`_ (LGPL 2.1+, see `licenses/`).
- SHA-256 of the DMG: _fill in from the `.sha256` file of the build to publish_.

Free software, GPL v3.0.

---

## Italiano

**Music Manager 2.3 Beta 2 è la versione di migliorie e aggiunte che segue il lavoro sulle prestazioni della Beta 1.** Porta le cartelle di playlist di Apple Music, gli album ordinati per data di aggiunta, una Custom Playlist più chiara, invii più sicuri, un pannello Fix Artwork migliore e gli avvisi di aggiornamento di software e mappe; riporta inoltre Album, Artisti e Brani al codice stabile degli elenchi della 2.2, dopo che un esperimento con un nuovo motore di elenchi si è rivelato inaffidabile con librerie molto grandi.

Music Manager trasferisce musica, album e playlist dall'app Musica a un orologio Garmin via USB (MTP) e gestisce ciò che c'è sull'orologio. È un progetto indipendente, non affiliato né approvato da Garmin o Apple.

### Cosa c'è di nuovo rispetto alla 2.3 Beta 1

**Playlist**
- **Cartelle come in Apple Music** (libreria locale): la scheda Playlist mostra lo stesso albero di cartelle e playlist, aperto con le stesse frecce di Artista ▸ Album. A ogni livello: prima le cartelle, poi le playlist smart/Genius, poi quelle normali, ogni gruppo in ordine alfabetico. Le cartelle vuote sono nascoste; la ricerca apre le cartelle che contengono risultati. Le librerie remote e le unità esterne mantengono l'elenco piatto.
- **Miniature**: ogni playlist ha una copertina da 32 pt: un mosaico 2×2 di quattro album diversi, la copertina del primo brano se gli album sono meno di quattro, un'icona a ingranaggio per le playlist smart/Genius (Musica non espone la copertina scelta per una playlist).

**Album, Artisti, Brani**
- **Album per data di aggiunta**: Impostazioni ▸ Generali ▸ *Visualizza Album* (Alfabetico / Data di aggiunta). Con *Data di aggiunta* gli album più recenti vengono per primi, come in Apple Music; l'etichetta accanto al cursore di scorrimento mostra il periodo (Questa settimana, Questo mese, Ultimi tre mesi, poi l'anno).
- Album, Artisti e Brani usano di nuovo gli elenchi nativi della 2.2 (gruppi annidati, cerchio di selezione su ogni brano): il motore sperimentale a righe piatte faceva saltare o lasciava vuoti gli elenchi con librerie grandi (visibile con una libreria di rete da 55.000 brani) e resta solo nelle Playlist. Le intestazioni «Disco n di m» sono mantenute e allineate al titolo dell'album.
- **Un solo segno di selezione** ovunque: cerchio verde con spunta (tutto) o trattino (parziale); sulle playlist sta sull'angolo della copertina.
- **Clic destro**: su un brano non selezionato la selezione precedente resta e il brano cliccato viene aggiunto; «Invia "brano" solo» invia solo quello e lascia intatta la selezione; il menu offre «Vai ad Artista» in Album, «Vai ad Album» in Artisti, entrambi in Brani e nel player.

**Custom Playlist**
- Opzione *Artista in evidenza* (Impostazioni ▸ Generali): artista nella riga principale, titolo e album nella riga piccola; interruttore rapido nella barra, con il pulsante di ordinamento nella stessa pillola.
- **Indicatori ×N** discreti quando lo stesso artista, lo stesso album o lo stesso brano (arancione) compare più volte.
- Selezione più chiara: una sola fascia nel colore scelto (prima si sovrapponeva a una fascia blu di sistema). Il clic seleziona, ⌘-clic aggiunge/toglie, ⇧-clic seleziona un intervallo; trascinando una riga selezionata si spostano ancora tutte le righe selezionate. Le frecce della tastiera e ⌘A non agiscono su questa lista.

**Invio all'orologio**
- Con una sola playlist selezionata sul dispositivo, *Invia* chiede «Aggiungere N brani alla playlist X?» (Aggiungi / Solo invia / Annulla).
- Un secondo invio non può partire mentre uno è in preparazione, nemmeno cambiando libreria; la barra di stato dice «Analisi di N brani…» così l'app non sembra bloccata. La proposta di ricerca copertine online arriva una sola volta, all'invio.
- **Il salvataggio in Musica** procede a blocchi fuori dal thread principale: la finestra resta reattiva e una capsula di avanzamento mostra «Salvataggio in Musica: n/totale brani» con il pulsante Annulla.

**Fix Artwork**
- Fino a 10 candidate (prima 5) con un confronto più tollerante: diciture di versione come «(End Title)» o «[Remastered]» vengono ignorate, l'artista può differire in parte e si cerca prima nell'album del brano (compilation, colonne sonore).
- «Ignora» salta l'intero album, e il pannello si chiude quando non restano altri album. I brani di un album con tag *Compilation* sono trattati come un solo album.
- La copertina scelta ora compare negli elenchi e nel player. «Cerca copertine online…» è anche nel menu del clic destro delle intestazioni di album, artista e playlist.

**Aggiornamenti e pannello dispositivo**
- **Avviso di aggiornamento software** anche nella campanella; la capsula mostra la versione disponibile («Upgrade Available: 6.73»). Il controllo interroga il server Garmin come fa Garmin Express, e un file di dati come «Time Zone Map 43.00» non viene più segnalato come aggiornamento software.
- Icona Mappe piena, spunta/croce piene accanto alla versione software e capsule «Software Updated», «Map Updated», «Upgrade Available» e «Check Needed» leggibili in modo scuro.
- Barra del dispositivo: *Espelli* (solo se il dispositivo è gestito come volume) prima del selettore memoria, *Connetti/Disconnetti* ultimo a destra. Nuova opzione *L'interfaccia usa il colore di selezione*.

**Registro dettagliato**
- Il registro conserva fino a 4 MB (prima era tagliato a 150 KB), mantiene l'inizio della sessione e registra la sospensione del Mac o l'app in secondo piano come «pausa» invece che come blocco dell'interfaccia.

### Cose da sapere
- È una beta; la nuova selezione della Custom Playlist e le modifiche a Fix Artwork sono state provate su macOS 27.2 con le librerie dell'autore.
- Non provata su macOS 26 (sviluppata e provata su macOS 27, anche la 27.2). Non notarizzata: se macOS blocca il primo avvio, esegui `xattr -cr "/Applications/Music Manager.app"` (vedi `docs/INSTALL.md`).
- Fix Artwork non può ancora ripristinare la copertina originale dopo averne scelta un'altra (previsto per la prossima beta). Una copertina già inviata all'orologio vi resta finché il brano non viene reinviato.
- Con librerie molto grandi (oltre 5.000 brani) la posizione di scorrimento non si conserva cambiando scheda, e la digitazione negli elenchi delle librerie di rete posiziona solo sulla prima lettera: usa la ricerca con la lente.
- I formati lossless (ALAC, FLAC, WAV, AIFF) sono mostrati ma non inviabili.
- L'avviso di aggiornamento segue la distribuzione graduale di Garmin, come Garmin Express.
- Segnala i problemi su GitHub, allegando il registro (Impostazioni ▸ «Registro dettagliato») se possibile.

### Librerie incluse e checksum
- libmtp: _da compilare con `brew list --versions libmtp`_ · libusb: _da compilare con `brew list --versions libusb`_ (LGPL 2.1+, vedi `licenses/`).
- SHA-256 del DMG: _da compilare dal file `.sha256` della build da pubblicare_.

Software libero, GPL v3.0.
