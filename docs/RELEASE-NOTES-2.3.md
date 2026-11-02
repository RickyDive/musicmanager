# Music Manager 2.3 — release notes (text for the GitHub release)

**Tag:** `v2.3` · Apple Silicon, macOS 26 or later · version 2.3, build 48

[English](#english) · [Italiano](#italiano)

---

## English

**Music Manager 2.3 is the first final release after 2.2.** It brings together the work of the three 2.3 betas: much better speed with very large libraries, Apple Music playlist folders and thumbnails, albums sorted by date added, a clearer Custom Playlist, safer sending, a much improved Fix Artwork panel (with Revert and manual covers), artist thumbnails, Apple TV remote controls, software and maps update notices, and many fixes. The code is the one of Beta 3 plus the licence notices described at the end.

Music Manager transfers music, albums and playlists from the Music app to a Garmin watch over USB (MTP) and manages what is on the watch. It is an independent project, not affiliated with or endorsed by Garmin or Apple.

### What is new since 2.2

**Speed with very large libraries**
- Opening and closing an artist or an album no longer re-counts all its songs at every redraw; the filtered lists («Show only transferable songs») are no longer rebuilt at every interface update; with libraries over 5,000 songs only the tab you are looking at keeps its list alive.
- Measured on a 55,454-song network library: freezes of 1–15 s on clicks became mostly under 1 s, memory stays around 400–700 MB instead of reaching 1.6 GB, and typing to jump in a list went from 7–15 s to 0.01–0.2 s.
- **Detailed log** (Settings ▸ «Detailed log (diagnostics)»): keeps up to 4 MB and the start of the session, records sleep or background as «pausa», and logs the seconds of each operation and every interface freeze longer than 0.35 s. Off by default.

**Playlists**
- **Folders as in Apple Music** (local library): same tree of folders and playlists as in Music, opened with chevrons. At each level: folders, then smart/Genius playlists, then regular ones, each group alphabetical. Remote libraries and external drives keep the flat list.
- **Thumbnails** for every playlist: a 2×2 mosaic of the first four covers that actually exist, the first cover if fewer albums have one, a gear for smart/Genius playlists.

**Albums, Artists, Songs**
- **Albums by date added** (Settings ▸ General ▸ *Show Albums*): newest first, as in Apple Music, with a period label next to the scroll cursor.
- **Artists tab with thumbnails**: Artist ▸ Albums ▸ Songs, each artist with a round thumbnail like Apple Music. Thumbnails come from Apple's public search, are stored as small images in `~/Library/Application Support/MusicManager/Cache/ArtistsMiniature/`, and are used only for the local library and only when «Apple Music artwork» is on. The artwork cache now lives in one `Cache/` folder (existing files are moved at launch).
- **Typing in lists ignores leading spaces and articles**: «rolling» finds «The Rolling Stones».
- **One selection mark** everywhere (green circle with a check or a dash). **Right-click**: «Send "track" only», «Go to Artist» / «Go to Album».
- **Text size** now scales the second line too, in five steps. The **Text size** and **Window opacity** sliders apply when released.

**Custom Playlist**
- *Artist first* option and a quick switch in the bar; discreet ×N badges for repeated artists, albums or songs; clearer selection (click, ⌘-click, ⇧-click).

**Sending to the watch**
- With one playlist selected on the device, *Send* asks «Add N tracks to the playlist X?». A second send cannot start while one is being prepared. **Saving to Music** runs in batches with a progress capsule and a Cancel button, and the window stays responsive.
- **Device panel**: an icon in the watch's song lists shows the song belongs to at least one playlist on the watch (the names appear on hover). *Eject* (only for volumes), the storage selector and *Connect/Disconnect* last on the right.

**Fix Artwork**
- Up to 10 online candidates with a more tolerant match; songs come in list order; guest artists («Feat. …») stay in their album; compilations are handled as one album.
- **«Ignore» asks like «Confirm»** («Ignore the whole album?»). **Revert** (↶) goes back to Music's own cover. **Add a cover by hand**: drop an image (from Safari or the Finder, or an image address) or paste it with ⌘V. The cover you choose shows in the lists and in the player. Buttons are equal in width and «OK» is now «Done».

**Playback and updates**
- **Apple TV remote**: with AirPlay audio, play/pause, next, previous and scrubbing from the Apple TV remote control Music Manager.
- **Software update notice** also in the notification bell, with the available version («Upgrade Available: 6.73»), checked the way Garmin Express does; data files such as «Time Zone Map 43.00» are no longer reported as software updates. Readable status badges in light and dark.

**Fixes**
- The **Edit/Format** items no longer flicker in the menu bar while changing Settings; the selected Settings tab uses the real selection color; texts about the removed right-click «Load artwork from Music» now point to «Fix Artwork online…».

**Not verified**
- **Playlist files as `.m3u`**: for a device whose `GarminDevice.xml` declares only M3U (not M3U8), the playlist file written to the watch is `.m3u` (content unchanged). Devices that declare M3U8, such as the fenix 9 Pro, are not affected. **This could not be tested** (no M3U-only device): if you have one, please try sending a playlist and report.

### Licence notices (the only change since Beta 3)
- Music Manager is free software under the **GNU GPL, version 3 or (at your option) any later version**. Every source file starts with the standard GPL header; the About window, the READMEs and `THIRD-PARTY-LICENSES.txt` state the licence, the absence of warranty and where the sources are.
- The disk image now also contains **`LICENSE.txt`**. The bundled libmtp (1.1.23) and libusb (1.0.30) are LGPL 2.1 or later: their sources are at https://github.com/libmtp/libmtp and https://github.com/libusb/libusb, and the versions included are listed in `BUNDLED-LIBS.txt` inside the app (Contents/Resources).
- Build fix: backup files can no longer end up inside the app bundle.

### Things worth knowing
- Developed and tested on macOS 27 with the author's libraries and a fenix 9 Pro. **Not tested on macOS 26.** Not notarized: if macOS blocks the first launch, run `xattr -cr "/Applications/Music Manager.app"` (see `docs/INSTALL.md`).
- On very large libraries (over 5,000 songs) the scroll position is not kept when changing tab; typing in lists of network libraries positions only on the first letter: use the magnifier search. Remote libraries: the first read is slow, then it is instant.
- Lossless formats (ALAC, FLAC, WAV, AIFF) are shown but cannot be sent: the app does not convert audio.
- The software update notice follows Garmin's staged distribution, as Garmin Express does.
- Sources: this release is on the `main` branch with the tag `v2.3`; the «Source code» archives of this page contain exactly the sources of this build.
- Please report problems on GitHub, attaching the log (Settings ▸ «Detailed log») if possible.

### Checksum
The SHA-256 of the DMG is in the attached `.sha256` file.

Free software, GPL v3 or later.

---

## Italiano

**Music Manager 2.3 è la prima versione finale dopo la 2.2.** Riunisce il lavoro delle tre beta della 2.3: prestazioni molto migliori con librerie molto grandi, cartelle e miniature delle playlist come in Apple Music, album ordinati per data di aggiunta, una Custom Playlist più chiara, invii più sicuri, un pannello Fix Artwork molto migliorato (con Revert e copertine a mano), le miniature degli artisti, i controlli dal telecomando dell'Apple TV, gli avvisi di aggiornamento di software e mappe e molte correzioni. Il codice è quello della Beta 3, più le note di licenza descritte in fondo.

Music Manager trasferisce musica, album e playlist dall'app Musica a un orologio Garmin via USB (MTP) e gestisce ciò che c'è sull'orologio. È un progetto indipendente, non affiliato né approvato da Garmin o Apple.

### Cosa c'è di nuovo rispetto alla 2.2

**Velocità con librerie molto grandi**
- Aprire e chiudere un artista o un album non ricalcola più i conteggi di tutti i suoi brani a ogni ridisegno; gli elenchi filtrati («Mostra solo i brani trasferibili») non si ricostruiscono più a ogni aggiornamento dell'interfaccia; con librerie oltre 5.000 brani solo la scheda che stai guardando tiene viva la sua lista.
- Misurato su una libreria di rete da 55.454 brani: i blocchi di 1–15 s sui clic sono diventati per lo più sotto il secondo, la memoria resta intorno a 400–700 MB invece di arrivare a 1,6 GB, e la digitazione per posizionarsi in un elenco è passata da 7–15 s a 0,01–0,2 s.
- **Registro dettagliato** (Impostazioni ▸ «Registro dettagliato (diagnostica)»): conserva fino a 4 MB e l'inizio della sessione, registra sospensione o app in secondo piano come «pausa», e annota i secondi di ogni operazione e ogni blocco dell'interfaccia oltre 0,35 s. Spento di default.

**Playlist**
- **Cartelle come in Apple Music** (libreria locale): lo stesso albero di cartelle e playlist di Musica, aperto con le frecce. A ogni livello: cartelle, poi playlist smart/Genius, poi quelle normali, ogni gruppo in ordine alfabetico. Le librerie remote e le unità esterne mantengono l'elenco piatto.
- **Miniature** per ogni playlist: un mosaico 2×2 delle prime quattro copertine che esistono davvero, la prima copertina se gli album con copertina sono meno, un ingranaggio per le playlist smart/Genius.

**Album, Artisti, Brani**
- **Album per data di aggiunta** (Impostazioni ▸ Generali ▸ *Visualizza Album*): i più recenti per primi, come in Apple Music, con l'etichetta del periodo accanto al cursore di scorrimento.
- **Scheda Artisti con miniature**: Artista ▸ Album ▸ Brani, ogni artista con una miniatura rotonda come in Apple Music. Le miniature vengono dalla ricerca pubblica di Apple, sono salvate come piccole immagini in `~/Library/Application Support/MusicManager/Cache/ArtistsMiniature/` e si usano solo per la libreria locale e solo con «Apple Music artwork» attivo. La cache delle copertine sta ora in un'unica cartella `Cache/` (i file esistenti vengono spostati all'avvio).
- **La digitazione negli elenchi ignora spazi e articoli iniziali**: digitando «rolling» si trova «The Rolling Stones».
- **Un solo segno di selezione** ovunque (cerchio verde con spunta o trattino). **Clic destro**: «Invia "brano" solo», «Vai ad Artista» / «Vai ad Album».
- La **dimensione del testo** scala ora anche la seconda riga, in cinque livelli. Gli slider **Dimensione testo** e **Trasparenza finestra** si applicano al rilascio.

**Custom Playlist**
- Opzione *Artista in evidenza* e interruttore rapido nella barra; indicatori ×N discreti per artisti, album o brani ripetuti; selezione più chiara (clic, ⌘-clic, ⇧-clic).

**Invio all'orologio**
- Con una playlist selezionata sul dispositivo, *Invia* chiede «Aggiungere N brani alla playlist X?». Un secondo invio non può partire mentre uno è in preparazione. Il **salvataggio in Musica** procede a blocchi con una capsula di avanzamento e il pulsante Annulla, e la finestra resta reattiva.
- **Pannello dispositivo**: un'icona negli elenchi di brani dell'orologio indica che il brano appartiene ad almeno una playlist sull'orologio (i nomi compaiono passandoci sopra). *Espelli* (solo per i volumi), selettore memoria e *Connetti/Disconnetti* ultimo a destra.

**Fix Artwork**
- Fino a 10 candidate online con un confronto più tollerante; i brani arrivano nell'ordine degli elenchi; gli artisti ospite («Feat. …») restano nel loro album; le compilation sono trattate come un solo album.
- **«Ignora» chiede come «Conferma»** («Ignorare tutto l'album?»). **Revert** (↶) torna alla copertina di Musica. **Aggiungere una copertina a mano**: trascina un'immagine (da Safari o dal Finder, oppure un indirizzo d'immagine) o incollala con ⌘V. La copertina scelta compare negli elenchi e nel player. I pulsanti sono tutti uguali e «OK» diventa «Fine».

**Riproduzione e aggiornamenti**
- **Telecomando dell'Apple TV**: con AirPlay come audio, riproduci/pausa, avanti, indietro e scorrimento dal telecomando dell'Apple TV comandano Music Manager.
- **Avviso di aggiornamento software** anche nella campanella, con la versione disponibile («Upgrade Available: 6.73»), controllato come fa Garmin Express; file di dati come «Time Zone Map 43.00» non vengono più segnalati come aggiornamenti software. Capsule di stato leggibili in tema chiaro e scuro.

**Correzioni**
- Le voci **Modifica/Formato** non lampeggiano più nel menu in alto mentre si cambiano le Impostazioni; la scheda attiva delle Impostazioni usa il vero colore di selezione; i testi sul clic destro «Carica Artwork da Music» (non più esistente) rimandano ora a «Fix Artwork online…».

**Non verificato**
- **File playlist `.m3u`**: per un dispositivo il cui `GarminDevice.xml` dichiara solo M3U (non M3U8), il file playlist scritto sull'orologio è `.m3u` (contenuto invariato). I dispositivi che dichiarano M3U8, come il fenix 9 Pro, non sono toccati. **Non è stato possibile provarlo** (nessun dispositivo solo-M3U): se ne hai uno, prova a inviare una playlist e fai sapere.

### Note di licenza (l'unica modifica rispetto alla Beta 3)
- Music Manager è software libero con licenza **GNU GPL, versione 3 o (a tua scelta) qualsiasi versione successiva**. Ogni file sorgente inizia con l'intestazione GPL standard; la finestra Informazioni, i README e `THIRD-PARTY-LICENSES.txt` indicano la licenza, l'assenza di garanzia e dove sono i sorgenti.
- L'immagine disco contiene ora anche **`LICENSE.txt`**. Le librerie incluse libmtp (1.1.23) e libusb (1.0.30) sono LGPL 2.1 o successiva: i loro sorgenti sono su https://github.com/libmtp/libmtp e https://github.com/libusb/libusb, e le versioni incluse sono elencate in `BUNDLED-LIBS.txt` dentro l'app (Contents/Resources).
- Correzione di build: i file di backup non possono più finire dentro il pacchetto dell'app.

### Cose da sapere
- Sviluppata e provata su macOS 27 con le librerie dell'autore e un fenix 9 Pro. **Non provata su macOS 26.** Non notarizzata: se macOS blocca il primo avvio, esegui `xattr -cr "/Applications/Music Manager.app"` (vedi `docs/INSTALL.md`).
- Con librerie molto grandi (oltre 5.000 brani) la posizione di scorrimento non si conserva cambiando scheda; la digitazione negli elenchi delle librerie di rete posiziona solo sulla prima lettera: usa la ricerca con la lente. Librerie remote: la prima lettura è lenta, poi è immediata.
- I formati lossless (ALAC, FLAC, WAV, AIFF) sono mostrati ma non inviabili: l'app non converte l'audio.
- L'avviso di aggiornamento software segue la distribuzione graduale di Garmin, come Garmin Express.
- Sorgenti: questa versione è nella branch `main` con il tag `v2.3`; gli archivi «Source code» di questa pagina contengono esattamente i sorgenti di questa build.
- Segnala i problemi su GitHub, allegando il registro (Impostazioni ▸ «Registro dettagliato») se possibile.

### Checksum
L'SHA-256 del DMG è nel file `.sha256` allegato.

Software libero, GPL v3 o successiva.
