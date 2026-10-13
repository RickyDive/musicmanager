# Garmin Music Manager — v2.0.1

**Richiede macOS 26.0 o successivo, su Mac con chip Apple Silicon.** Il progetto compila solo per
`arm64`: niente build o binari Intel/x86_64, niente universal binary.

App macOS (SwiftUI) che:
- si collega via USB (MTP, con **libmtp**) a Fenix / Forerunner / Edge e ne sfoglia il file system;
- legge la libreria dell'app Musica (**iTunesLibrary**), organizzata in **Brani / Album / Artisti / Playlist**, e segnala quali brani sono trasferibili (no DRM, no solo-cloud, mp3/m4a/aac);
- legge la cartella `Music` dell'orologio con la stessa organizzazione (Brani / Album / Artisti / Playlist M3U), oltre alla vista «File» per sfogliare tutte le cartelle;
- mostra la **copertina dell'album** nelle righe dei brani e nelle intestazioni degli album, sia per Apple Music sia per il dispositivo Garmin (lato Garmin è "best effort": molti dispositivi non espongono questa proprietà via MTP, in quel caso compare un segnaposto, non un errore);
- mostra per ogni **playlist** il numero di brani e la **durata totale**;
- invia i brani nella cartella `Music` dell'orologio, mantenendo la struttura **Artista/Album** (`Music/Artista/Album/brano.ext`); ogni invio **verifica l'arrivo** di ogni file (stessa dimensione del sorgente, con un secondo tentativo in caso di esito negativo) e **non duplica** i brani già presenti e corretti;
- durante ogni invio mostra una **finestra di trasferimento** che scorre automaticamente per tenere visibile il brano in elaborazione, con l'esito di ciascuno (In corso / Trasferito / Già presente / Errore) e un riepilogo finale (selezionati, copiati, già presenti, in errore);
- **non ricopia** i brani già presenti sul dispositivo (controllo per nome file, senza confronto byte a byte): un secondo invio della stessa playlist o di una playlist che condivide brani con un'altra copia solo il "delta" mancante;
- quando elimini brani dalla vista **Musica** del dispositivo, se la cartella **Album** resta vuota viene rimossa, e se anche la cartella **Artista** resta vuota di conseguenza viene rimossa a sua volta (la cartella `Music` non viene mai toccata); l'eliminazione dalla vista **File** resta invece "grezza", senza questa pulizia automatica;
- **pulsante "Svuota cartella Music"** sotto il pannello del dispositivo, per eliminare in un colpo solo tutto il contenuto musicale (brani, cartelle Artista/Album, file playlist), con conferma;
- **controllo opzionale degli aggiornamenti software** del dispositivo (Impostazioni → Avanzate → Devices, spento di default): una volta all'apertura chiede ai server Garmin se esiste un aggiornamento e mostra «Software Updated» / «Upgrade Available» accanto alla versione; invia a Garmin il contenuto di GarminDevice.xml e usa un servizio non documentato;
- invia una **playlist intera**: prima di tutto **rilegge la playlist direttamente da Musica** (non una copia già caricata in questa app), cosi riflette sempre lo stato attuale anche se è stata modificata nel frattempo; un eventuale file `.m3u8` già presente sul dispositivo viene **sempre eliminato e ricreato da zero**, referenziando tutti i brani risultati presenti; un singolo brano realmente non trasferibile viene escluso ed evidenziato nella finestra di trasferimento senza bloccare gli altri;
- lato dispositivo, eliminare una **playlist** (pulsante "Elimina playlist" sulla relativa riga) rimuove solo il file `.m3u8`, non i brani audio che referenzia;
- nelle schede Album/Artisti/Playlist, il pulsante "Seleziona" diventa **"Deseleziona"** quando tutti i brani del gruppo sono già selezionati, per selezionare o deselezionare tutto con un click;
- **barra grafica della memoria interna** (solo per lo storage interno, non per schede SD): grigio scuro per lo spazio totale, grigio chiaro per la cartella Garmin (mappe escluse), giallo per le mappe (`.gma`/`.img`), verde per la cartella Music; lo spazio libero sul totale è indicato sotto la barra;
- la vista **File** del dispositivo è "ancorata" alla cartella `Music`: non è possibile risalire fino alla radice della memoria (cartelle di sistema del dispositivo escluse);
- interfaccia disponibile in **inglese (predefinita) e italiano**, scelta dal pannello **Impostazioni** dell'app (menu Impostazioni / ⌘,), non più da un selettore nella finestra principale;
- dal pannello **Impostazioni** si sceglie anche quale elenco mostrare per primo all'apertura (Playlist/Album/Artisti/Brani), sia per Apple Music sia per il dispositivo Garmin; entrambe le impostazioni restano salvate per i prossimi avvii;
- all'avvio (e per impostazione predefinita) le due viste partono dalla scheda **Playlist**;
- le schede di Apple Music e del dispositivo Garmin sono nell'ordine **Playlist, Artisti, Album, Brani**, con gli elenchi sempre in ordine alfabetico, sia lato Apple Music sia lato Garmin; il selettore delle schede è allineato a sinistra (non più centrato) in entrambi i pannelli;
- lato Apple Music, dopo "Brani" c'è una quinta scheda, **Custom Playlist**: al posto del campo di ricerca c'è il nome da assegnare alla playlist, e sotto un elenco (vuoto all'inizio) dei brani aggiunti. Si popola dalle altre schede (Playlist/Artisti/Album/Brani) con il pulsante **✔︎** — un'ulteriore opzione a destra di "Seleziona"/"Deseleziona" — presente sia sulle intestazioni (playlist/album/artista intero) sia sui singoli brani, anche quelli annidati dentro un gruppo. Un brano già presente nella Custom Playlist viene segnalato con una richiesta di conferma prima di aggiungerlo comunque una seconda volta. Una volta popolata: **"Invia all'orologio"** la trasferisce con lo stesso meccanismo di controllo delle altre playlist (file `.m3u8` ricreato da zero, referenziando tutti i brani risultati presenti), e **"Salva in Apple Music"** la crea (o la aggiorna, se esiste già una playlist con lo stesso nome) anche nell'app Musica, via Apple Event — alla prima volta macOS chiede il permesso di automazione per controllare Musica;
- dopo un trasferimento, la vista del dispositivo si aggiorna automaticamente (con una breve pausa prima della rilettura, per dare tempo al firmware di aggiornare il proprio elenco interno) cosi il conteggio dei brani per ogni playlist risulta corretto senza bisogno di un refresh manuale;
- **mini player** sopra l'elenco di Apple Music, alla stessa altezza dei controlli di storage/modalità del dispositivo (così le due righe Playlist/Artisti/Album/Brani restano allineate): copertina, titolo, artista/album, barra di avanzamento scorrevole a mano con i tempi, e i pulsanti indietro/play-pausa/avanti. Si avvia con un **doppio click** su un brano dell'elenco; indietro/avanti scorrono gli altri brani dello stesso contesto (l'intero elenco Brani, oppure l'album/artista/playlist aperti). La riproduzione è locale (il file del brano stesso), non è collegata all'app Musica;
- lato dispositivo, il pulsante "Svuota cartella Music" è ora sulla stessa riga di "Elimina" (il pulsante "Download" è stato rimosso), allineata con la riga "Invia all'orologio" di Apple Music;
- il mini player e l'area di stato del dispositivo Garmin usano il materiale **Liquid Glass** di macOS 26;
- **chiusura del programma**: se il dispositivo è ancora connesso (⌘Q, menu "Esci" o chiusura della finestra), viene chiesta prima conferma di voler davvero uscire e, se confermato, se si vuole anche disconnettere il dispositivo prima di uscire; se nessun dispositivo è connesso il programma si chiude senza chiedere nulla.

## Novità della 1.6 (riassunto delle sotto-versioni 1.5.1 – 1.5.6)

Dove questo elenco e quello sopra divergono, vale questo. Il dettaglio completo è nel documento di stato del progetto «v1.6 - stato del progetto».

- **Librerie remote** (Impostazioni ▸ Advanced): fino a 3 librerie lette da un XML esportato da Musica con i file su una cartella montata (SMB); selezione dal menu della finestra principale; icone di rete locale / altra rete (conferma Sì/No) / `network.slash` rosso se il server non risponde (verifica TCP o file leggibile, ripetuta al ritorno della rete); MAC del router modificabile (disattivato offline). L'accesso DAAP / Home Sharing è stato abbandonato.
- **Schede**: Artisti = artista dell'album ▸ album ▸ brani (con «Compilations»); Album per nome + artista dell'album; numero di traccia (o disco/traccia); «Vai all'Album / Artista»; copertine caricate da Musica solo su richiesta; posizione delle liste conservata.
- **Brani**: icona iCloud azzurra (solo cloud), capsula gialla «Hi-Res» (Apple Lossless, non trasferibile), borsa arancione per gli acquisti iTunes; indicatore animato del brano in riproduzione.
- **Custom Playlist**: salvataggio/caricamento su file M3U8 in `~/Music/GarminMusicManager/Custom Lib` (con tre modi di unione), «Svuota» con conferma, riepilogo «N brani, X ore e Y minuti», salvataggio in Musica nella cartella «≡♪ Garmin Music Manager», domanda di salvataggio all'uscita. (Dalla 1.6.2 «Salva in cartella» è stato rimosso, sostituito dal salvataggio della playlist su file.)
- **Invio all'orologio**: precontrollo delle copertine mancanti con proposta di ricerca online prima della conferma; riepilogo con i conteggi per origine (Apple / Garmin Cache / File / No Cover, mancanti in rosso).
- **Riproduzione**: AirPlay con un unico `AVPlayer`; preparazione in background dei file su volumi di rete; lettura di iTunesLibrary fuori dal thread principale con Musica aperta.
- **Impostazioni**: schede General / Appearance / Artwork / Advanced; lingua di sistema alla prima apertura; per dispositivo solo l'Aspetto; «Ripristina tutte le impostazioni».
- **Finestra e icona**: apertura sempre alla dimensione minima (1440 × 780, mai a schermo intero); pannelli di vetro a tutta larghezza; icona `AppIcon.icon` (Icon Composer).

## Setup

Serve Homebrew installato nativamente per Apple Silicon (percorso `/opt/homebrew`), non una copia
Intel eseguita sotto Rosetta.

```bash
brew install libmtp libusb xcodegen
cd GarminMusicManager
xcodegen generate
open GarminMusicManager.xcodeproj
```

In Xcode: Signing & Capabilities → scegli il tuo Team (o lascia "Sign to Run Locally"), poi ⌘R.

## Se il dispositivo non si apre

1. Chiudi Garmin Connect, Garmin Express, OpenMTP, Android File Transfer o altre app simili.
2. Sblocca l'orologio e imposta la modalità USB su MTP/"Archiviazione" se richiesto.
3. Scollega e ricollega il cavo, poi premi «Connetti».

## Icona dell'app

`GarminMusicManager/AppIcon.icon` è l'icona creata con Icon Composer (livelli SVG vettoriali, effetto vetro di macOS 26). Per cambiarla basta aprirla con Icon Composer e salvarla con lo stesso nome: Xcode la compila come `AppIcon`.

## Come vengono letti i dati dal Garmin

- **Metadati**: prima quelli MTP (titolo, artista, album, durata). Se l'orologio non li espone, il titolo è il nome del file e artista/album sono dedotti dalle cartelle (`Music/Artista/Album/brano.mp3` oppure `Music/Album/brano.mp3`); la durata resta sconosciuta (non viene mostrata).
- **Copertine**: tentate via la proprietà MTP "representative sample". Se il firmware del dispositivo non la supporta, che è il caso più comune, viene mostrato un segnaposto: non è un errore da segnalare.
- **Playlist**: file `.m3u` / `.m3u8` nella cartella `Music`, abbinati ai brani per nome file.

## Limiti noti del prototipo

- Usa il primo dispositivo MTP trovato.
- La verifica del trasferimento controlla solo il **nome** del file sul dispositivo (non la dimensione né un checksum): alcuni firmware MTP riportano una dimensione leggermente diversa da quella del file sorgente anche per file perfettamente corretti, e un confronto più stretto produceva falsi negativi. Questo è volutamente il compromesso scelto; se un giorno servisse un controllo più rigoroso (dimensione o checksum) si può aggiungere come opzione.
- La ripartizione della memoria (cartella Garmin e mappe) richiede una scansione ricorsiva della cartella `Garmin`: viene calcolata solo alla connessione o al cambio memoria, non a ogni refresh, per non rallentare l'uso quotidiano. La dimensione della cartella Music invece si aggiorna sempre, perché deriva dai brani già letti (nessuna scansione aggiuntiva).
- Le dylib sono quelle di Homebrew per Apple Silicon (percorso `/opt/homebrew`; il progetto non cerca
  più `/usr/local`, il percorso usato da Homebrew su Intel). Per distribuire l'app servono libmtp/libusb
  incorporate nel bundle (es. con `dylibbundler`) e firma/notarizzazione.
- App Sandbox disattivata; per il Mac App Store serve rivalutare l'accesso USB.
- Gli upload sono sincroni e senza barra di avanzamento per singolo file.
- Non c'è ancora la lettura dei `.fit` (prossimo passo: Garmin FIT SDK via Swift Package Manager).
# GarminMusicManager v1.6.1 — stato del progetto (patch, 2026-10-09)

Patch sulla 1.6 (congelata). Versione 1.6.1, build 4. **Non compilata né verificata.**

## Bug corretto
Pannello Apple Music › tab Playlist: inviando al Device **più playlist insieme** venivano inviati tutti i brani ma nessun file `.m3u8`. Con una sola playlist tutto funzionava.

## Causa
Il percorso «playlist intera» (`wholePlaylistSelectionID`) si attiva solo con esattamente una playlist selezionata; con due o più la selezione cadeva nell'invio di brani sparsi, senza playlist.

## Correzione
- `CatalogBrowser` emette già `onSelectedPlaylistsChange` (id di tutte le playlist interamente selezionate); `ContentView` lo collega a `vm.selectedApplePlaylistIDs`.
- `AppViewModel.sendSelectedTracksToDevice`: se tab Playlist, ≥2 playlist intere e l'unione dei loro brani coincide con la selezione → `sendPlaylistsToDevice(groups)`.
- `sendPlaylistsToDevice`: rilegge ogni playlist, costruisce l'unione senza doppioni e chiama `prepareExportBody(items:playlistName:playlists:)`.
- `prepareExportBody` scrive un `.m3u8` per playlist in TEMP e valorizza `stagedPlaylists`.
- `confirmDeviceExport`: con ≥2 playlist, per ciascuna chiama `sendTracksAsPlaylist(name:items:)` (brani con delta + `uploadPlaylist`). `stagedPlaylists` azzerato in conferma e annulla.
- Controllo artwork online (`askArtworkSearchIfNeeded`) eseguito una volta sull'unione, prima del riepilogo.

## Limiti noti
- Selezione composta esattamente da ≥2 playlist intere; selezioni miste o parziali inviano ancora solo i brani.
- Il report di trasferimento viene sostituito a ogni playlist (resta l'ultimo).
- Il riepilogo mostra i nomi uniti da virgola nella riga «Playlist».
# GarminMusicManager v1.6.2 — stato del progetto (patch, 2026-10-09)

Patch sulla 1.6.1 (che include il fix invio multi-playlist). Versione 1.6.2, build 5. **Non compilata né verificata.**

## Bug corretto
Durante i trasferimenti compariva «Creazione cartella fallita: PTP Layer error 2002: LIBMTP_Create_Folder: Could not send object info», anche se cartella e file erano già sul device. Accadeva soprattutto con artisti/album già presenti.

## Causa (probabile)
`ensureFolder` cercava la cartella con confronto solo case-insensitive esatto. Se il device riporta il nome con codifica Unicode diversa (accenti scomposti), spazi/punti finali, o l'elenco era incompleto, la cartella non veniva riconosciuta, si tentava di ricrearla e il device rifiutava il duplicato (errore 2002).

## Correzione (`MTPService.swift`)
- Nuovo `MTPService.nameKey(_:loose:)`: NFC, minuscolo, trim di spazi/punti; modalità `loose` ignora anche accenti e larghezza.
- `ensureFolder`, `findFolder`, `fileExists` usano `nameKey`.
- `ensureFolder`: se la creazione fallisce, rilegge l'elenco fino a 3 volte (pausa 0,4 s, anche confronto `loose`) e usa la cartella trovata; l'errore è mostrato solo se non esiste davvero.

## Note
Se l'errore ricompare, servono il nome esatto di artista/album coinvolti (può essere un nome non valido per il device o un genitore non cartella).

## Seconda correzione (invio di più playlist)
«Chiudi» nella finestra di trasferimento resta disabilitato fino alla fine dell'ultima playlist (un solo `perform` attorno al ciclo in `confirmDeviceExport`).

## Aggiunta: ordinamento «Casuale» nella Custom Playlist
Nel menu «Ordina per» della Custom Playlist c'è la nuova voce «Casuale»: mischia a caso i brani; «Manuale» ripristina l'ordine precedente.

## Menu tasto destro riordinato; rimosso «Salva in cartella»
Ordine: «Invia a Custom» («Invia n a Custom» con più brani selezionati, icona `tray.and.arrow.down`) · separatore · «Fix Artwork online…» (solo se attivo in Impostazioni) · «Ricarica Artwork da Apple Music» (ora sempre presente) · separatore · «Deseleziona tutto». In coda restano, dopo un altro separatore, Seleziona/Deseleziona, «Invia all'orologio» (con dispositivo) e «Vai all'album/artista» (scheda Brani).
Icone SF Symbols: `tray.and.arrow.down` (Invia a Custom), `waveform.badge.magnifyingglass` (Artwork Online Fix), `mail.and.text.magnifyingglass` (Ricarica Artwork da Apple Music), `clear` (Deseleziona tutto).
Rimosso «Salva in cartella» e tutto il codice orfano: `saveSelectedTracksToFolder`, `saveTracksToFolder`, `localSaveFolder`, `RowMenu.canSaveToFolder/saveToFolder`, chiavi `button_save_to_folder`, `transfer_dialog_title_local_tracks`, `status_saving`, `status_saved_to_folder(_with_failures)`, `menu_fix_artwork`, `menu_load_artwork`. Resta `localExportFolder` (usata da TEMP/Custom Lib).

## Playlist: sottotitolo come nella Custom Playlist
Sottotitolo «N brani, X ore e Y minuti» (stesse regole singolare/plurale della Custom Playlist); tolto il numero di brani ridondante a destra nelle intestazioni delle playlist.

## Artisti: numero ridondante tolto
Il numero a destra nell'intestazione degli artisti è stato tolto: il sottotitolo «N album / X brani» lo contiene già.

## Album: numero ridondante tolto
Tolto il numero di brani a destra nelle intestazioni degli album (già nel sottotitolo).

## Durata dei brani
In tutte le liste la durata sta subito a sinistra del riquadro di selezione, che è l'ultimo elemento a destra in una colonna di larghezza fissa.

## Barra di selezione con durata totale
In basso, oltre al numero di elementi selezionati, compare la durata totale («N selezionati, X ore e Y minuti»), sia per Apple Music sia per il dispositivo.

## Icone «Vai all'album / Vai all'artista»
Aggiunte nel menu tasto destro della scheda Brani: `music.pages` e `microphone.dynamic.on.stand`.

## Icone del menu tasto destro
Forzato `.labelStyle(.titleAndIcon)` sulle voci del menu contestuale, perché le icone non comparivano.

## Icona Seleziona / Deseleziona nel menu tasto destro
`checkmark.square` (Seleziona) e `square` (Deseleziona).

## «Clear Selection» unificato
Menu tasto destro e pulsante in basso: stesso testo («Pulisci selezione» / «Clear Selection») e stessa icona `xmark.circle`.

## Pulsante «Invia a Custom»
Rinominato il pulsante «Invia alla Playlist» in «Invia a Custom», con l'icona `tray.and.arrow.down` del menu tasto destro.

## Custom Playlist: pulsante singolo Carica/Salva
Un solo pulsante: lista vuota → «Carica da file», lista con brani → «Salva su file»; dopo «Svuota» torna «Carica da file».

## Alert «Svuota» della Custom Playlist
Pulsanti: Salva su file (verde) · Conferma svuotamento · Annulla.

## Pannello About ridisegnato
Nuovo pannello «Informazioni su…» in stile Musica: icona grande, nome, versione e build, copyright e «Note legali…».

## Conferma «Svuota» con pulsante verde
Finestra SwiftUI con «Salva su file» su sfondo verde (predefinito), «Conferma svuotamento» e «Annulla».

## Ordina per: divisore e ritorno da «Casuale» a «Manuale»
Divisore prima di «Casuale»; tornando a «Manuale» da «Casuale» si sceglie se mantenere l'ordine casuale come Manuale o ripristinare il Manuale precedente.

## Menu File
Rimossa «Nuova finestra»; aggiunte «Carica da file…» e «Salva su file…» (Custom Playlist) con le stesse icone del pannello.

## Finestra: larghezza fissa, altezza libera
Larghezza bloccata a 1440 pt, altezza ridimensionabile; all'apertura la finestra usa l'altezza libera dello schermo (senza barra dei menu né Dock).

## Pallino verde
Larghezza fissa a 1440 pt tranne a schermo intero; il pallino verde offre «Riempi» (altezza) e schermo intero.

## Volume con AirPlay
Con AirPlay attivo il cursore del volume agisce sul volume del dispositivo di uscita di sistema (CoreAudio) invece che su `AVPlayer.volume`.

## Apertura di Apple Music all'avvio
Corretta la risposta all'avviso «Apri Musica?» (poteva risultare «No») e aggiunti messaggi di stato durante l'apertura.

## Volume AirPlay: verifica e ripiego
Il volume di sistema viene riletto dopo la scrittura; se non coincide si usa AppleScript («set volume output volume»). Corregge il volume che funzionava solo alla prima selezione di AirPlay.

## Volume AirPlay come Musica (sperimentale)
Il volume del dispositivo AirPlay si regola tramite il contesto di uscita AVFoundation (a runtime), con ripiego sul volume di sistema. Esito nel log di Xcode («[AirPlayVolume]»).

## Icona AirPlay
I dispositivi AirPlay usano l'icona `hifispeaker.fill`.

## Icone delle uscite audio
Apple TV, HomePod e HomePod mini hanno la propria icona; altoparlanti Bluetooth e dispositivi AirPlay sconosciuti usano `hifispeaker.fill`, a sinistra del nome del dispositivo.
Volume AirPlay: riconoscimento tramite il dispositivo di `player.outputContext` (`routeIsRemote`); il cursore regola quel dispositivo.
Pulizia: rimosso il codice di diagnostica del volume AirPlay (log `[AirPlayVolume]`); resta solo la regolazione del dispositivo del percorso.
Cursore volume mini player: larghezza 130 pt.

## Release congelata
1.6.2 (build 5) congelata il 2026-10-10 dopo il test dell'utente. Nuove modifiche: usare una nuova copia (1.6.3).

## 2.0.1
Copia di lavoro derivata dalla 2.0 (congelata, build 11). Versione 2.0.1, build 12. Correzione: nella barra della memoria la scritta «+ dimensione» dei brani selezionati e la lineetta verticale non scendono più sulla legenda; stanno sopra la barra, allineate alla fine del segmento a strisce. Il rilevamento di un dispositivo collegato ora controlla ogni 5 secondi (prima 20; con un dispositivo già connesso il controllo termina subito). Dopo l'invio di una playlist il file .m3u8 viene verificato sul dispositivo (presente, riscaricabile, stesso contenuto; fino a 3 tentativi) e il numero di brani mostrato sotto il nome è controllato con rilettura ripetuta; le playlist del dispositivo si abbinano ai brani per percorso completo e non più per solo nome file. Sul dispositivo artisti e album mostrano il nome vero (AC/DC e non AC_DC): si ricorda l'originale di ciò che si invia e lo si ricava dalla libreria; nel ripiego di esportazione della copertina si portano nella copia tutti i metadati del file. Nuova icona dell'app (livelli ridimensionati e riposizionati). Filtro playlist: la terza voce è ora «Solo smart o Genius» (al posto di «Tutte tranne le smart»). Il selettore della memoria compare solo se il dispositivo ne ha più d'una. Da qui in avanti le modifiche vanno in questa cartella.

## 2.0 (release finale)
Release finale 2.0, build 11, derivata dalla 2.0 Beta 5 (congelata, build 10) senza modifiche al codice: cambia solo l'etichetta di versione. Fine della fase Beta. Congelata il 2026-10-12. Nuove modifiche: usare una nuova copia (2.0.1 / 2.1).

## 2.0 Beta 5
Copia di lavoro derivata dalla 2.0 Beta 4 (congelata, build 9). Versione 2.0 Beta 5, build 10. Congelata il 2026-10-12 dopo il test dell'utente (drag & drop con invio e playlist Direct Copy verificati). Release finale: 2.0.

## 2.0 Beta 4
Copia di lavoro derivata dalla 2.0 Beta 3 (congelata, build 8). Versione 2.0 Beta 4, build 9. Congelata il 2026-10-12 dopo il test dell'utente (mappe operative). Nuove modifiche: 2.0 Beta 5.

## 2.0 Beta 3
Copia di lavoro derivata dalla 2.0 Beta 2 (congelata, build 7). Versione 2.0 Beta 3, build 8. Da qui in avanti tutte le modifiche vanno in questa cartella.

### Pulizia e ottimizzazione
Rimosso il codice non più usato (`setMediaPath`, `modifiedCount`, `deviceSelectionCount`, la chiave di testo `n_albums`). Il riepilogo del pannello dispositivo (artisti, album, durata totale) si calcola una sola volta e si ricalcola solo quando cambiano i brani del dispositivo o della libreria (`AppViewModel.deviceSummary`), invece che a ogni ridisegno del pannello. `SharedMusicLibrary.swift` resta vuoto per non rompere il riferimento nel progetto Xcode.

- Controllo «Music capable»: da `GarminDevice.xml` (`MEDIA_TRACK`) si capisce se il dispositivo supporta la musica; se no, info visibili ma invio, cancellazione e svuotamento disattivati. I formati inviabili seguono quelli dichiarati nel file.

## 2.0 Beta 2
Copia di lavoro derivata dalla 2.0 Beta 1 (congelata, build 6). Versione 2.0 Beta 2, build 7. Da qui in avanti tutte le modifiche vanno in questa cartella.

### Dimensione del testo negli elenchi
Impostazioni → Aspetto: cursore a cinque posizioni (da 10 a 16 pt, Medium = 13 come prima; sotto la barra Extra small / Medium / Large) con l'anteprima di un album a caso della libreria (con copertina); sotto il cursore dell'opacità un'anteprima della trasparenza della finestra. Cambia solo la prima riga: titolo di playlist, artista, album e brano; righe secondarie, icone e pannelli restano uguali.
Schede Album e Artisti: sotto i brani dentro un album non si ripete più «Artista — Album» (già nell'intestazione): resta solo l'artista del brano, se diverso da quello dell'album; le righe sono più basse. Nelle Playlist e in Brani la riga resta.

## 2.0 Beta 1
Copia di lavoro derivata dalla 1.6.2 (congelata, build 5). Versione 2.0 Beta 1, build 6. Da qui in avanti tutte le modifiche vanno in questa cartella.

### Posizionamento da tastiera
Negli elenchi Brani, Album e Artisti digitando alcune lettere la lista scorre alla voce più simile (non cambia la selezione). Pausa di 1 s = nuovo testo; Esc/Cancella correggono.
Posizionamento da tastiera: tasti intercettati con un monitor locale AppKit (TypeAheadMonitor).
Posizionamento da tastiera: identificatori tipizzati per scrollTo (correzione).
Posizionamento da tastiera: scostamento di righe (8 Album/Artisti, 12 Brani) per non nascondere la voce sotto i pannelli.
Ricerca: testo separato per la Custom Playlist (customSearch), indipendente da quello delle altre schede.
Ricerca per scheda: Brani=titolo, Album=album, Artisti=artista, Playlist=qualsiasi etichetta; Custom separata.

### Edit in Custom (playlist del dispositivo)
Menu tasto destro o pulsante sulla playlist del device: la importa nella Custom con il suo nome. Brani in libreria (abbinati per titolo+artista) o solo device (icona applewatch). L'invio sostituisce la playlist sul dispositivo, ricontrollando la presenza dei brani solo-device.
Icona brano solo-device nella colonna di «già inviato» (stessa misura).
Libreria di un'altra rete: l'Apple Artwork non si carica da sola; si carica all'invio alla Custom e al device, con proposta di ricerca online se manca.
Barra dello spazio: dimensioni in GB accanto a Garmin, Maps, Music.
Edit in Custom con Custom già piena: stessa scelta del caricamento da file (sovrascrivi / attuali in coda / playlist del device in coda).
Alert import da device: «Playlist del device in coda» prima di «Brani attuali in coda».
Alert import da device: descrizione di Sovrascrivi in terza posizione.
Alert import da device: ordine descrizioni = attuali in coda, device in coda, Sovrascrivi.
Alert import da device: Playlist First / Current Tracks First / Replace (pulsanti e descrizioni).
Import da device con Custom piena: foglio con ordine dei pulsanti controllato.
Titolo pannello Apple Music: icona music.note.square.stack.

## 2.1 Beta 1 (build 13)
- App rinominata **Music Manager**, bundle ID `com.crdev.MusicManager`. Il nuovo ID azzera impostazioni (UserDefaults) e permessi: vanno riconcessi.
- libmtp/libusb incorporate nel bundle (`Scripts/bundle-libs.sh`), firma ad hoc, nessun account Developer.
- Distribuzione: DMG su GitHub Releases (`Scripts/build-release.sh`, vedi `docs/RELEASING.md`); istruzioni utente in `docs/INSTALL.md`.
- Nuovo menu Aiuto (diagnostica, log, feedback, licenze), messaggio di benvenuto, log in `~/Library/Logs/MusicManager/`.
- Invariati di proposito: cartella Application Support, `~/Music/GarminMusicManager`, cartella playlist "≡♪ Garmin Music Manager" in Musica.
- Repository: https://github.com/RickyDive/musicmanager
