# Music Manager 2.5 — release notes (text for the GitHub release)

**Tag:** `v2.5` · Apple Silicon, macOS 26 or later · version 2.5 (build 50)

[English](#english) · [Italiano](#italiano)

---

## English

**Music Manager 2.5 adds a way to read a music library from another Mac without exporting an XML by hand**, together with the work of the internal 2.4 build (which was never published). Starting point: the published 2.3.

Music Manager transfers music, albums and playlists from the Music app to a Garmin watch over USB (MTP) and manages what is on the watch. It is an independent project, not affiliated with or endorsed by Garmin or Apple.

### What is new since 2.3

**Remote library from MusicManager Server**
- New companion project: **[MusicManager Server](https://github.com/RickyDive/musicmanager-server)** (free software, GPL v3 or later). A small menu bar app for the Mac that holds the Music library: it reads the library and keeps a compact `library.json` up to date next to it (every 30 minutes up to 24 hours, or on demand with «Scan now»). It needs **macOS 12 or later**; for older Macs the XML exported by Music keeps working as before.
- In Settings ▸ Advanced ▸ Remote Libraries the «+» button (and the file change button) now accepts this `library.json` as well as an XML. Everything else is the same as for an XML remote library: the file is copied with progress, cached, the files folder is found automatically, network volumes are mounted at launch and a change of the source is noticed.
- Tested with a library of 55,507 songs on an external SSD of a Mac mini (opened in about 2 seconds, songs played from the network share) and with 29,507 songs on an Intel Mac with macOS 12.
- The messages about reading the library file no longer say «XML», since the file can now be a JSON.
- When a remote library has changed on the server, the Refresh button of the title bar is highlighted with the interface colour until the library is read again.

**Podcasts from Apple Podcasts to the watch**
- New **Podcasts** tab in the device panel (after the Songs tab, behind a small divider). It lists the episodes you have already downloaded in the Apple Podcasts app, grouped by programme (and season); select some and press **Send**. Music Manager **does not download anything**: it only reads what Apple Podcasts has already downloaded on the Mac.
- Each file is sent to the `Podcasts` folder with the tags the watch needs (genre «Podcast», programme, episode title, author, episode number; a season is added to the programme name, e.g. «Programme S07»). The tags are written on a temporary copy: the original Apple file is never modified.
- One list for both sides: episodes already on the watch show a green check; files on the watch whose episode is no longer downloaded appear in a final «Only on the device» section. Right-click one or more rows ▸ **Remove from device** (with confirmation).
- The storage bar of the device has a new purple **Podcasts** segment (before, those megabytes were counted in «System»).
- **Covers:** a cover already embedded in the episode file is kept; if there is none, Music Manager uses the artwork Apple Podcasts has already stored on the Mac (nothing is downloaded) and embeds it in the copy sent to the watch. The watch shows it.
- **Programme headings:** each programme has a heading like an album's: its cover, name and description, on a band in the colour Apple Podcasts assigns to the programme (read from the Apple Podcasts library, nothing is downloaded). Episodes are indented under the programme name.
- Only MP3 episodes that are completely downloaded can be sent.

**Interface**
- **Preview mode.** A «timer» button in the mini player plays each song for 15 seconds starting at about 30 % of its length, then moves on to the next, to audition a playlist, an artist or an album quickly. It works with any list you play from and stays on until you switch it off.
- **Albums: quick switch between alphabetical and date added.** A button next to the tabs in the Albums tab of the Music panel («Abc» or a calendar) switches the order with one click; it replaces the «Show Albums» setting, and the choice is remembered.
- **User profiles (experimental).** For several people sharing one macOS account: an optional switch in Settings ▸ Advanced adds a round button in the title bar to switch between users (up to 5). Each user has their own settings, language, remembered devices and external sources; the Music library and the artwork stay common.
- **One table for external sources.** In Settings ▸ Advanced, Remote Libraries and External Drive Libraries are now a single «External Sources» table with up to 5 entries in total; «+» asks which kind to add (network library, from a Music XML or a MusicManager Server JSON, or folder on an external drive). Nothing changes in how each kind works.
- **Device bar buttons as pills.** The storage selector, *Eject* and *Connect / Disconnect* look like the Custom Playlist controls; the library selector of the Music panel too. Same behaviour as before.
- **Settings window:** the tab bar and «Reset all settings» are aligned with the boxes; the window is a little narrower.

**Artwork, Custom Playlist and sending**
- **Fix Artwork, online search.** The search now goes through the artist's whole discography on the iTunes Store: all the editions of an album are offered (not only the first), «The Best of» and «Best Of» are treated as the same title, and self-titled albums no longer match a compilation of the same artist. The arrows to browse the candidates stay fixed in the corners of the cover.
- **Songs without a cover.** The «Show songs without cover» filter scans the library once per album, remembers albums it has already checked for 10 minutes and shows its progress; when nothing is left, the list offers «Show all songs» instead of staying empty.
- **Custom Playlist: PacePro.** Up to 12 splits (km and pace), an optional start delay and a «Km per song» switch show at which kilometre each song starts and during which song each kilometre is passed.
- **Go to Album / Go to Artist** position reliably even with very large libraries and many open groups.
- **Direct Copy.** Dropping again files already listed in the device's «Direct Copy» playlist now asks whether to skip or add the duplicates, instead of adding them silently.
- **Welcome window** redesigned (app icon, glass panel, «Don't show at next launch» checkbox).
- **Speed** with very large libraries: typing to jump in a list, opening tabs and scanning covers are noticeably faster.

### Things worth knowing
- Developed and tested on macOS 27 with the author's libraries and a fenix 9 Pro. Not notarized: if macOS blocks the first launch, run `xattr -cr "/Applications/Music Manager.app"` (see `docs/INSTALL.md`). The same applies to MusicManager Server, whose release page explains it.
- Podcasts: macOS lets an app read the Apple Podcasts files only with the **Full Disk Access** permission. Music Manager explains this in the Podcasts tab and opens the right System Settings page; turn Music Manager on there and reopen the app. Because the app is not notarized, the permission may need to be renewed after an update (turn it off and on again).
- Star ratings are not part of the server's JSON; play counts are (they are used to order similar songs).
- A remote library is checked when it is opened. If it changes on the server while the app is open, the Refresh button is highlighted only when the library is opened again: switch to another library and back, or restart the app, to read the new content.
- Sources: this release is on the `main` branch with the tag `v2.5`; the «Source code» archives of this page contain exactly the sources of this build. MusicManager Server has its own repository and releases.
- Please report problems on GitHub, attaching the log (Settings ▸ «Detailed log») if possible.

### Acknowledgements
Thanks to **mcoliver**: the idea of the Podcasts feature comes from his script [fixPodcastMetadata](https://github.com/mcoliver/fixPodcastMetadata) (MIT licence), which fixes the tags of Apple Podcasts episodes and copies them to the watch. No code from it is used: Music Manager's version is written from scratch. Thanks also for the continuous-integration proposal and the build checks suggested in [issue #2](https://github.com/RickyDive/musicmanager/issues/2).

### Checksum
The SHA-256 of the DMG is in the attached `.sha256` file.

Free software, GPL v3 or later.

---

## Italiano

**Music Manager 2.5 aggiunge un modo per leggere una libreria musicale di un altro Mac senza esportare a mano un XML**, insieme al lavoro della build interna 2.4 (mai pubblicata). Punto di partenza: la 2.3 pubblicata.

Music Manager trasferisce musica, album e playlist dall'app Musica a un orologio Garmin via USB (MTP) e gestisce ciò che c'è sull'orologio. È un progetto indipendente, non affiliato né approvato da Garmin o Apple.

### Cosa c'è di nuovo rispetto alla 2.3

**Libreria remota da MusicManager Server**
- Nuovo progetto complementare: **[MusicManager Server](https://github.com/RickyDive/musicmanager-server)** (software libero, GPL v3 o successiva). Una piccola app nella barra dei menù per il Mac che contiene la libreria di Musica: legge la libreria e tiene aggiornato accanto ad essa un `library.json` compatto (ogni 30 minuti fino a 24 ore, oppure a richiesta con «Scansiona ora»). Richiede **macOS 12 o successivo**; per i Mac più vecchi l'XML esportato da Musica continua a funzionare come prima.
- In Impostazioni ▸ Avanzate ▸ Librerie remote il pulsante «+» (e quello di cambio file) accetta ora questo `library.json` oltre a un XML. Tutto il resto è come per una libreria remota XML: il file è copiato con avanzamento, messo in cache, la cartella dei file si trova da sola, i volumi di rete sono montati all'avvio e un cambiamento della sorgente viene notato.
- Provato con una libreria di 55.507 brani su un SSD esterno di un Mac mini (aperta in circa 2 secondi, brani riprodotti dalla condivisione di rete) e con 29.507 brani su un Mac Intel con macOS 12.
- I messaggi sulla lettura del file della libreria non dicono più «XML», perché il file può essere un JSON.
- Quando una libreria remota è cambiata sul server, il pulsante Aggiorna della barra del titolo si evidenzia con il colore dell'interfaccia finché la libreria non viene riletta.

**Podcast di Apple Podcasts sull'orologio**
- Nuova scheda **Podcast** nel pannello del dispositivo (dopo la scheda Brani, dietro un piccolo divisore). Elenca gli episodi che hai già scaricato nell'app Podcast di Apple, raggruppati per programma (e stagione); selezionane alcuni e premi **Invia**. Music Manager **non scarica nulla**: legge soltanto ciò che Apple Podcasts ha già scaricato sul Mac.
- Ogni file va nella cartella `Podcasts` con i tag che servono all'orologio (genere «Podcast», programma, titolo dell'episodio, autore, numero di puntata; la stagione si aggiunge al nome del programma, ad esempio «Programma S07»). I tag sono scritti su una copia temporanea: il file originale di Apple non viene mai modificato.
- Un solo elenco per entrambi i lati: gli episodi già sull'orologio hanno la spunta verde; i file sull'orologio il cui episodio non è più scaricato compaiono in una sezione finale «Solo sul dispositivo». Tasto destro su una o più righe ▸ **Rimuovi dal dispositivo** (con conferma).
- La barra della memoria del dispositivo ha un nuovo segmento viola **Podcast** (prima quei megabyte erano contati in «System»).
- **Copertine:** se il file dell'episodio ha già una copertina incorporata viene conservata; altrimenti Music Manager usa l'immagine che Apple Podcasts ha già salvato sul Mac (non scarica nulla) e la incorpora nella copia inviata all'orologio. L'orologio la mostra.
- **Intestazioni dei programmi:** ogni programma ha un'intestazione come quella degli album: copertina, nome e descrizione, su una fascia del colore che Apple Podcasts assegna al programma (letto dalla libreria di Apple Podcasts, senza scaricare nulla). Gli episodi sono rientrati sotto il nome del programma.
- Si possono inviare solo episodi MP3 scaricati per intero.

**Interfaccia**
- **Modalità anteprima.** Un pulsante «timer» nel mini player suona ogni brano per 15 secondi a partire da circa il 30 % della durata e passa al successivo, per ascoltare in fretta una playlist, un artista o un album. Vale per qualunque elenco da cui riproduci e resta attivo finché non lo spegni.
- **Album: cambio rapido tra ordine alfabetico e per data di aggiunta.** Un pulsante accanto alle schede, nella scheda Album del pannello Music («Abc» oppure un calendario), cambia l'ordine con un clic; sostituisce l'impostazione «Visualizza Album», e la scelta viene ricordata.
- **Profili utente (sperimentale).** Per più persone con lo stesso account macOS: un interruttore opzionale in Impostazioni ▸ Avanzate aggiunge un pulsante tondo nella barra del titolo per passare da un utente all'altro (fino a 5). Ogni utente ha impostazioni, lingua, dispositivi memorizzati e sorgenti esterne proprie; la libreria di Musica e le copertine restano comuni.
- **Una sola tabella per le sorgenti esterne.** In Impostazioni ▸ Avanzate, Librerie Remote e Librerie su Dispositivi Esterni diventano un'unica tabella «Sorgenti Esterne» con al massimo 5 voci in tutto; «+» chiede che tipo aggiungere (libreria in rete, da XML di Musica o JSON di MusicManager Server, o cartella su unità esterna). Il funzionamento di ciascun tipo non cambia.
- **Pulsanti della barra del dispositivo a pillola.** Il selettore dello storage, *Espelli* e *Connetti / Disconnetti* hanno l'aspetto dei controlli della Custom Playlist, come il selettore della libreria del pannello Musica. Comportamento invariato.
- **Finestra Impostazioni:** la barra delle schede e «Ripristina tutte le impostazioni» sono allineate ai riquadri; la finestra è un po' più stretta.

**Copertine, Custom Playlist e invio**
- **Fix Artwork, ricerca online.** La ricerca percorre l'intera discografia dell'artista su iTunes Store: vengono proposte tutte le edizioni di un album (non solo la prima), «The Best of» e «Best Of» sono trattati come lo stesso titolo e gli album omonimi dell'artista non corrispondono più a una compilation. Le frecce per scorrere le candidate restano fisse negli angoli della copertina.
- **Brani senza copertina.** Il filtro «Mostra brani senza copertina» analizza la libreria una volta per album, ricorda per 10 minuti gli album già controllati e mostra l'avanzamento; quando non resta nulla, l'elenco offre «Mostra tutti i brani» invece di restare vuoto.
- **Custom Playlist: PacePro.** Fino a 12 frazioni (km e passo), un ritardo di partenza facoltativo e l'interruttore «Km per brano» mostrano a quale chilometro parte ogni brano e durante quale brano si passa ogni chilometro.
- **Vai all'Album / Vai all'Artista** si posizionano in modo affidabile anche con librerie molto grandi e molti gruppi aperti.
- **Direct Copy.** Trascinare di nuovo file già presenti nella playlist «Direct Copy» del dispositivo chiede ora se saltare o aggiungere i duplicati, invece di aggiungerli in silenzio.
- **Finestra di benvenuto** ridisegnata (icona dell'app, pannello di vetro, casella «Non mostrare al prossimo avvio»).
- **Velocità** con librerie molto grandi: digitazione per spostarsi negli elenchi, apertura delle schede e scansione delle copertine sono sensibilmente più rapide.

### Cose da sapere
- Sviluppata e provata su macOS 27 con le librerie dell'autore e un fenix 9 Pro. Non notarizzata: se macOS blocca il primo avvio, esegui `xattr -cr "/Applications/Music Manager.app"` (vedi `docs/INSTALL.md`). Lo stesso vale per MusicManager Server, la cui pagina di rilascio lo spiega.
- Podcast: macOS permette a un'app di leggere i file di Apple Podcasts solo con il permesso **Accesso completo al disco**. Music Manager lo spiega nella scheda Podcast e apre la pagina giusta delle Impostazioni di Sistema; attiva lì Music Manager e riapri l'app. Poiché l'app non è notarizzata, dopo un aggiornamento il permesso può dover essere rinnovato (spegnilo e riaccendilo).
- Le valutazioni in stelle non fanno parte del JSON del server; il numero di riproduzioni sì (serve a ordinare i brani simili).
- Una libreria remota viene controllata quando si apre. Se cambia sul server mentre l'app è aperta, il pulsante Aggiorna si evidenzia solo riaprendo la libreria: passa a un'altra libreria e torna, oppure riavvia l'app, per leggere il nuovo contenuto.
- Sorgenti: questa versione è nella branch `main` con il tag `v2.5`; gli archivi «Source code» di questa pagina contengono esattamente i sorgenti di questa build. MusicManager Server ha un repository e rilasci propri.
- Segnala i problemi su GitHub, allegando il registro (Impostazioni ▸ «Registro dettagliato») se possibile.

### Ringraziamenti
Grazie a **mcoliver**: l'idea della funzione Podcast nasce dal suo script [fixPodcastMetadata](https://github.com/mcoliver/fixPodcastMetadata) (licenza MIT), che corregge i tag degli episodi di Apple Podcasts e li copia sull'orologio. Nessun codice dello script è usato: la versione di Music Manager è scritta da zero. Grazie anche per la proposta di integrazione continua (CI) e per i controlli di build suggeriti nella [issue #2](https://github.com/RickyDive/musicmanager/issues/2).

### Checksum
L'SHA-256 del DMG è nel file `.sha256` allegato.

Software libero, GPL v3 o successiva.
