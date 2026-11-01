# Music Manager 2.3 Beta 3 — release notes (text for the GitHub pre-release)

**Tag:** `v2.3-beta3` (pre-release) · Apple Silicon, macOS 26 or later · version 2.3 Beta 3, build 47

[English](#english) · [Italiano](#italiano)

---

## English

**Music Manager 2.3 Beta 3 is the polish-and-completion release that follows Beta 2.** It adds Apple TV remote controls, an icon showing which songs are in a playlist on the watch, bigger and scalable text, typing in lists that ignores leading articles, artist thumbnails, a much improved Fix Artwork panel (with Revert and manual covers) and many small fixes. It stays a **pre-release**: the DMG and its SHA-256 are attached, and the sources are in the «Source code» archives of this page (branch `beta`, tag `v2.3-Beta3`).

Music Manager transfers music, albums and playlists from the Music app to a Garmin watch over USB (MTP) and manages what is on the watch. It is an independent project, not affiliated with or endorsed by Garmin or Apple.

### What is new since 2.3 Beta 2

**Device panel**
- **«In a playlist» icon**: in the watch's song lists, a fourth column (as in Music) shows that the song belongs to at least one playlist on the watch; hovering it shows the playlist names at once (up to 15, then «and N more»).

**Playback**
- **Apple TV remote**: with AirPlay as audio (e.g. an Apple TV), play/pause, next, previous and scrubbing from the Apple TV remote now control Music Manager. The Apple TV does not draw on-screen controls for this, and does not send the ±15 s skip buttons (they were removed). The Mac's Control Center mini player works as before.

**Lists and text**
- **Typing in lists ignores leading spaces and articles**: in Songs, Albums, Artists and the device lists, typing «rolling» finds «The Rolling Stones» (typing «the» still works). Articles handled: the, a, an, il, lo, la, i, gli, le, l', un, uno, una, el, los, las, les, der, die, das, ein, eine. The order of the lists does not change. Typing is not available in Playlist and Custom lists (their order is not alphabetical), and in remote libraries and external drives it still positions on the first letter only.
- **The second line scales with the text size** (artist/album line and similar), in five steps. The **Text size** and **Window opacity** sliders in Settings now apply when you release them; while dragging, only the preview next to the slider changes.
- **Playlist thumbnails**: the 2×2 mosaic now uses the first four covers that actually exist (e.g. songs 1, 2, 5 and 8 when 3, 4, 6 and 7 have none) instead of leaving empty cells.
- **Artists tab with thumbnails**: Artist ▸ Albums ▸ Songs, each artist with a round thumbnail like Apple Music (album covers inside an artist are slightly smaller). Thumbnails come from Apple's public search, are stored as small images in `~/Library/Application Support/MusicManager/Cache/ArtistsMiniature/`, and are used only for the local library and only when «Apple Music artwork» is on in Settings. The artwork cache now lives in one `Cache/` folder (existing files are moved at launch).

**Fix Artwork**
- Songs now come in list order (album artist, album, disc and track) instead of selection order.
- **«Ignore» asks like «Confirm»**: with more songs of the album left, it asks «Ignore the whole album?»; Yes skips them (and they no longer count in «Song n of N»), No ignores only this song.
- Albums whose cover comes from the album (not from the song) show that cover in «Original artwork», and the «use it for the other songs?» question now covers all the other songs of the album (also those that already show a cover), since the usual use is replacing the album's cover with a better one.
- Songs with a guest artist («Feat. …», «ft.») stay in their album.
- **Revert** (↶ button): removes the cover you chose and goes back to Music's own cover, or to no cover if Music has none, with a Confirm/Cancel box; if other songs of the same album have a chosen cover, it says they will be reverted too. Only the app's archive changes: covers already sent to the watch stay there until the song is sent again.
- **Add a cover by hand**: drop an image on the «Online artwork» square (from Safari or any app, from the Finder, or an image address) or paste it with ⌘V; it is a candidate like the online ones (resized to 600 px, saved as JPEG), offered to the rest of the album with the usual question.
- Music's cover shown in the panel now also appears in the list, even with «Load artwork from Music automatically» off.
- Buttons are narrower and equal in width; «OK» is now **«Done»**, because it only closes the panel.

**Fixes**
- The **Edit/Format** items no longer flicker in the top menu bar while changing Settings (including dragging the hue with «follow selection color» on).
- The selected tab in Settings (General | Appearance | Artwork | Advanced) now uses the real selection color, not a faded version.
- Status badges («Software Updated», «Map Updated», «Upgrade Available», «Check Needed») keep white text in the light theme too; the maps globe uses the same green as the status icons; status dots in Settings are larger.
- Texts that mentioned a right-click «Load artwork from Music» (a command that no longer exists) now point to **Artwork Online Fix…**.

**Not verified**
- **Playlist files as `.m3u`**: for a device whose `GarminDevice.xml` declares only M3U (not M3U8), the playlist file written to the watch is now `.m3u` (content unchanged: relative paths, UTF-8). Devices that declare M3U8, such as the fenix 9 Pro, are not affected. **This could not be tested** (no M3U-only device available): if you have one, please try sending a playlist and report. Accented names may need a different text encoding on old devices.

### Things worth knowing
- This is a beta, developed and tested on macOS 27 with the author's libraries and a fenix 9 Pro. **Not tested on macOS 26.** Not notarized: if macOS blocks the first launch, run `xattr -cr "/Applications/Music Manager.app"` (see `docs/INSTALL.md`).
- On very large libraries (over 5,000 songs) the scroll position is not kept when changing tab; typing in lists of network libraries positions only on the first letter: use the magnifier search.
- Lossless formats (ALAC, FLAC, WAV, AIFF) are shown but cannot be sent.
- The software update notice follows Garmin's staged distribution, as Garmin Express does.
- Sources: the «Source code» archives on this page, the branch beta and the tag v2.3-Beta3 contain exactly the sources of this build. main keeps the sources of the last final release.
- Please report problems on GitHub, attaching the log (Settings ▸ «Detailed log») if possible.

### Included libraries and checksum
libmtp 1.1.23
libusb 1.0.30
SHA-256 of the DMG: _acd83676c08077c268f18c5ba602394d17c38abcd3b383feae37efcdc8af0ced_.

Free software, GPL v3.0.

---

## Italiano

**Music Manager 2.3 Beta 3 è la versione di rifinitura e completamento che segue la Beta 2.** Porta i controlli dal telecomando dell'Apple TV, un'icona che indica quali brani sono in una playlist sull'orologio, testo più grande e scalabile, la digitazione negli elenchi che ignora gli articoli iniziali, le miniature degli artisti, un pannello Fix Artwork molto migliorato (con Revert e copertine a mano) e molte piccole correzioni. Resta una **pre-release**: sono allegati il DMG e il suo SHA-256, e i sorgenti sono negli archivi «Source code» di questa pagina (branch `beta`, tag `v2.3-Beta3`).

Music Manager trasferisce musica, album e playlist dall'app Musica a un orologio Garmin via USB (MTP) e gestisce ciò che c'è sull'orologio. È un progetto indipendente, non affiliato né approvato da Garmin o Apple.

### Cosa c'è di nuovo rispetto alla 2.3 Beta 2

**Pannello dispositivo**
- **Icona «in una playlist»**: negli elenchi di brani dell'orologio una quarta colonna (come in Musica) indica che il brano appartiene ad almeno una playlist sull'orologio; passandoci sopra compaiono subito i nomi delle playlist (fino a 15, poi «e altre N»).

**Riproduzione**
- **Telecomando dell'Apple TV**: con AirPlay come audio (per esempio un'Apple TV), riproduci/pausa, avanti, indietro e lo scorrimento dal telecomando dell'Apple TV ora comandano Music Manager. L'Apple TV non disegna comandi a schermo per questo e non invia i tasti di salto da ±15 s (sono stati tolti). Il mini player del Centro di Controllo del Mac funziona come prima.

**Elenchi e testo**
- **La digitazione negli elenchi ignora spazi e articoli iniziali**: in Brani, Album, Artisti e negli elenchi del dispositivo, digitando «rolling» si trova «The Rolling Stones» (digitando «the» si trova comunque). Articoli gestiti: the, a, an, il, lo, la, i, gli, le, l', un, uno, una, el, los, las, les, der, die, das, ein, eine. L'ordine degli elenchi non cambia. La digitazione non c'è nelle liste Playlist e Custom (il loro ordine non è alfabetico) e nelle librerie remote e unità esterne posiziona ancora solo sulla prima lettera.
- **La seconda riga scala con la dimensione del testo** (riga artista/album e simili), in cinque livelli. Gli slider **Dimensione testo** e **Trasparenza finestra** in Impostazioni ora si applicano al rilascio; durante il trascinamento cambia solo l'anteprima accanto allo slider.
- **Miniature delle playlist**: il mosaico 2×2 usa ora le prime quattro copertine che esistono davvero (per esempio i brani 1, 2, 5 e 8 se 3, 4, 6 e 7 non ne hanno) invece di lasciare celle vuote.
- **Scheda Artisti con miniature**: Artista ▸ Album ▸ Brani, ogni artista con una miniatura rotonda come in Apple Music (le copertine degli album dentro un artista sono un po' più piccole). Le miniature vengono dalla ricerca pubblica di Apple, sono salvate come piccole immagini in `~/Library/Application Support/MusicManager/Cache/ArtistsMiniature/` e si usano solo per la libreria locale e solo con «Apple Music artwork» attivo in Impostazioni. La cache delle copertine ora sta in un'unica cartella `Cache/` (i file esistenti vengono spostati all'avvio).

**Fix Artwork**
- I brani arrivano ora nell'ordine degli elenchi (artista dell'album, album, disco e traccia) invece che in quello di selezione.
- **«Ignora» chiede come «Conferma»**: se restano altri brani dell'album, chiede «Ignorare tutto l'album?»; Sì li salta (e non contano più in «Brano n di N»), No ignora solo questo brano.
- Gli album la cui copertina viene dall'album (non dal brano) mostrano quella copertina in «Artwork originale», e la domanda «usarla per gli altri brani?» ora riguarda tutti gli altri brani dell'album (anche quelli che mostrano già una copertina), perché l'uso tipico è sostituire la copertina dell'album con una migliore.
- I brani con artista ospite («Feat. …», «ft.») restano nel loro album.
- **Revert** (pulsante ↶): toglie la copertina scelta e torna a quella di Musica, o a nessuna copertina se Musica non ne ha, con un riquadro Conferma/Annulla; se altri brani dello stesso album hanno una copertina scelta, avvisa che verranno riportati anche loro. Cambia solo l'archivio dell'app: le copertine già inviate all'orologio vi restano finché il brano non viene reinviato.
- **Aggiungere una copertina a mano**: trascina un'immagine sul riquadro «Online artwork» (da Safari o da qualunque app, dal Finder, oppure un indirizzo d'immagine) o incollala con ⌘V; diventa una candidata come quelle online (ridimensionata a 600 px, salvata in JPEG) e si propone al resto dell'album con la solita domanda.
- La copertina di Musica mostrata nel pannello compare ora anche nell'elenco, anche con «Carica automaticamente le Artwork da Music» spento.
- I pulsanti sono più stretti e tutti uguali; «OK» diventa **«Fine»**, perché si limita a chiudere il pannello.

**Correzioni**
- Le voci **Modifica/Formato** non lampeggiano più nel menu in alto mentre si cambiano le Impostazioni (anche trascinando la tonalità con «segui il colore di selezione» attivo).
- La scheda attiva delle Impostazioni (General | Appearance | Artwork | Advanced) usa ora il vero colore di selezione, non una versione sbiadita.
- Le capsule di stato («Software Updated», «Map Updated», «Upgrade Available», «Check Needed») mantengono il testo bianco anche nel tema chiaro; il globo delle mappe usa lo stesso verde delle icone di stato; i pallini di stato nelle Impostazioni sono più grandi.
- I testi che citavano un clic destro «Carica Artwork da Music» (comando che non esiste più) rimandano ora a **Fix Artwork online…**.

**Non verificato**
- **File playlist `.m3u`**: per un dispositivo il cui `GarminDevice.xml` dichiara solo M3U (non M3U8), il file playlist scritto sull'orologio è ora `.m3u` (contenuto invariato: percorsi relativi, UTF-8). I dispositivi che dichiarano M3U8, come il fenix 9 Pro, non sono toccati. **Non è stato possibile provarlo** (nessun dispositivo solo-M3U a disposizione): se ne hai uno, prova a inviare una playlist e fai sapere. Su dispositivi vecchi i nomi con accenti potrebbero richiedere un'altra codifica del testo.

### Cose da sapere
- È una beta, sviluppata e provata su macOS 27 con le librerie dell'autore e un fenix 9 Pro. **Non provata su macOS 26.** Non notarizzata: se macOS blocca il primo avvio, esegui `xattr -cr "/Applications/Music Manager.app"` (vedi `docs/INSTALL.md`).
- Con librerie molto grandi (oltre 5.000 brani) la posizione di scorrimento non si conserva cambiando scheda; la digitazione negli elenchi delle librerie di rete posiziona solo sulla prima lettera: usa la ricerca con la lente.
- I formati lossless (ALAC, FLAC, WAV, AIFF) sono mostrati ma non inviabili.
- L'avviso di aggiornamento software segue la distribuzione graduale di Garmin, come Garmin Express.
- Sorgenti: gli archivi «Source code» di questa pagina, la branch beta e il tag v2.3-Beta3 contengono esattamente i sorgenti di questa build. main mantiene i sorgenti dell’ultima release finale.
- Segnala i problemi su GitHub, allegando il registro (Impostazioni ▸ «Registro dettagliato») se possibile.

### Librerie incluse e checksum
libmtp 1.1.23
libusb 1.0.30
SHA-256 of the DMG: _acd83676c08077c268f18c5ba602394d17c38abcd3b383feae37efcdc8af0ced_.

Software libero, GPL v3.0.
