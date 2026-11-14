# Music Manager

[🇬🇧 English](README.md) · 🇮🇹 Italiano

App per macOS che trasferisce musica, album e playlist dalla libreria dell'app **Musica** a un orologio **Garmin** (Fenix, Forerunner, Edge…) via USB (MTP), e ne gestisce il contenuto.

> **Versione 2.5.** Il feedback è benvenuto: apri una [Issue](https://github.com/RickyDive/musicmanager/issues/new/choose).
> Progetto indipendente, non affiliato né approvato da Garmin o Apple.

> **Ambito:** la musica va in un solo senso, dalla libreria del Mac al dispositivo. L'app non copia mai audio da un dispositivo e non accede alle librerie di altri dispositivi. Vedi [docs/SCOPE.md](docs/SCOPE.md).

## Requisiti
- Mac con **Apple Silicon**, **macOS 26** o successivo
- Orologio Garmin con supporto musica, cavo USB
- Brani senza DRM in formato mp3 / m4a / aac

## Installazione
Scarica il DMG dalla pagina [Releases](https://github.com/RickyDive/musicmanager/releases) e segui **[docs/INSTALL.md](docs/INSTALL.md)** (in inglese).
L'app non è notarizzata (non ho un account Apple Developer): al primo avvio macOS la blocca. Il modo più affidabile per aprirla è un comando da Terminale, `xattr -cr "/Applications/Music Manager.app"` (la strada *Impostazioni di Sistema ▸ Privacy e sicurezza ▸ Apri comunque* può bloccarsi su macOS 27). Le librerie libmtp e libusb sono incluse: **non serve Homebrew**.

## Funzioni principali
- Sfoglia la libreria di Musica (Playlist / Artisti / Album / Brani) e segnala i brani trasferibili.
- Legge il contenuto della cartella `Music` dell'orologio con la stessa organizzazione (Brani, Album, Artisti, Playlist).
- Invia brani, album, artisti o playlist intere con struttura `Artista/Album/brano`, verifica l'arrivo di ogni file e non ricopia quelli già presenti.
- Playlist `.m3u8` ricreata da zero e verificata sul dispositivo dopo l'invio.
- **Custom Playlist**: componi una playlist da qualsiasi scheda, salvala su file o in Musica, inviala all'orologio.
- Barra grafica dello spazio (System, Data, Maps, Services, Music, selezione in arrivo) con suggerimenti; lo spazio dei servizi di streaming viene riconosciuto, mai modificato.
- Copertine, mini player con AirPlay, librerie remote (SMB), eliminazione e pulizia della cartella Music.
- **Menu del tasto destro** per ogni contesto: brani (menu completo: Send to Custom / Device, Artwork Online Fix, Vai ad Album / Artista, Trova simili, Mostra in Playlist), intestazioni di playlist / album / artista (due righe Send con nome e numero di brani) e tutta l'area del mini player. I sottotitoli indicano quanti brani sono realmente inviabili, es. «2 album / 37 brani (6 trasferibili)».
- Mini player: pulsante muto che ricorda il volume precedente.
- Tutte le finestre (Fix Artwork, report di trasferimento, Trova simili, eliminazione, riepilogo invio…) sono pannelli di vetro centrati.
- Campanella notifiche: il pallino mostra il messaggio non letto più grave (rosso = errore, arancione = avviso).
- Librerie di rete (SMB): montate all'avvio (3 tentativi, solo se il server risponde), con il vero nome host del server salvato, così funzionano anche quando il nome della condivisione non si risolve; un server irraggiungibile mostra un avviso arancione (offline) o rosso (server assente) invece di una finestra di sistema.
- Interfaccia in italiano e inglese.

## Segnalare un problema
Menu **Aiuto ▸ Copia informazioni diagnostiche**, poi apri una [Issue](https://github.com/RickyDive/musicmanager/issues/new/choose) incollando il testo. Altri strumenti: *Aiuto ▸ Mostra il log nel Finder*. Scenari da provare: [docs/TESTING.md](docs/TESTING.md) (in inglese).

## Se l'orologio non viene rilevato
1. Chiudi Garmin Express, Garmin Connect, OpenMTP, Android File Transfer, Acquisizione Immagine.
2. Sblocca l'orologio e imposta la modalità USB su MTP/«Archiviazione».
3. Scollega e ricollega il cavo.

## Compilare dai sorgenti
```bash
brew install libmtp libusb xcodegen
xcodegen generate
open MusicManager.xcodeproj
```
Per creare il DMG: `Scripts/build-release.sh` (vedi [docs/RELEASING.md](docs/RELEASING.md)).

## Note sulla privacy
L'app non invia dati a server propri. Funzione opzionale (spenta di default): il controllo aggiornamenti software chiede ai server Garmin se esiste una nuova versione, inviando il contenuto di `GarminDevice.xml` tramite un servizio non documentato.

## Novità della 2.5
- **MusicManager Server**: legge la libreria di Musica di un altro Mac tramite un `library.json` compatto, senza esportare a mano un XML (macOS 12 o successivo sul lato server).
- **Podcast**: invia sull'orologio gli episodi già scaricati in Apple Podcasts (solo MP3; non scarica nulla).
- **Fix Artwork**: la ricerca online percorre l'intera discografia dell'artista, propone ogni edizione di un album e ignora le differenze «The» / «Best Of»; il filtro «brani senza copertina» è più veloce e non lascia mai l'elenco vuoto.
- **Custom Playlist**: PacePro (km per brano) con fino a 12 frazioni.
- **Interfaccia**: modalità anteprima nel mini player, cambio rapido degli Album (alfabetico / data di aggiunta), un'unica tabella «Sorgenti Esterne», barra del dispositivo a pillola, finestra di benvenuto ridisegnata, profili utente sperimentali.
- **Direct Copy**: avviso prima di duplicare file già presenti nella playlist.

Testo del rilascio: [docs/RELEASE-NOTES-2.5.md](docs/RELEASE-NOTES-2.5.md).

## Novità della 2.3
- **Velocità con librerie molto grandi**: misurato su una libreria di rete da 55.000 brani, i blocchi di 1–15 s sui clic sono diventati per lo più sotto il secondo, la memoria resta intorno a 400–700 MB invece di arrivare a 1,6 GB, e la digitazione per posizionarsi in un elenco è passata da 7–15 s a 0,01–0,2 s. Un'opzione *Registro dettagliato* nelle Impostazioni registra i tempi per la diagnostica.
- **Playlist**: le stesse cartelle di Apple Music (libreria locale), una miniatura per ogni playlist, e *Invia* propone di aggiungere i brani alla playlist selezionata sull'orologio.
- **Album, Artisti, Brani**: album per data di aggiunta, scheda Artisti con miniature rotonde (Artista ▸ Album ▸ Brani), digitazione negli elenchi che ignora gli articoli iniziali («rolling» trova «The Rolling Stones») e dimensione del testo che scala anche la seconda riga.
- **Custom Playlist**: opzione *Artista in evidenza*, indicatori ×N per artisti, album o brani ripetuti, selezione più chiara.
- **Fix Artwork**: fino a 10 candidate online, **Revert** alla copertina di Musica, aggiunta di una copertina a mano (trascinamento o ⌘V) e domanda «Ignorare tutto l'album?».
- **Orologio e riproduzione**: un'icona indica i brani che sono in una playlist sull'orologio; avvisi di aggiornamento di software e mappe; il **telecomando dell'Apple TV** comanda la riproduzione; il salvataggio in Musica procede a blocchi con una capsula di avanzamento e il pulsante Annulla.
- **Licenza**: note GNU GPL v3 o successiva in ogni file sorgente, nella finestra Informazioni e nell'immagine disco (`LICENSE.txt`).

**Da sapere:** con le librerie remote la prima lettura è lenta e le aperture successive sono immediate; lì la digitazione negli elenchi posiziona solo sulla prima lettera, quindi usa la ricerca con la lente. Con due condivisioni dallo stesso nome il Finder può lasciare una voce «fantasma» vuota dopo lo smontaggio (`killall Finder` o un riavvio la elimina). Il controllo degli aggiornamenti software segue la distribuzione a gruppi di Garmin, come Garmin Express.

**Limiti noti:** non provata su macOS 26 (sviluppata e provata su macOS 27); non notarizzata (vedi [docs/INSTALL.md](docs/INSTALL.md) se il primo avvio è bloccato); i formati lossless non vengono convertiti né inviati; le playlist trovate nella cartella di un'unità non si importano; ricevitori AirPlay molto vecchi possono essere rifiutati da macOS stesso; i file playlist `.m3u` per un dispositivo che dichiara solo M3U non si sono potuti provare.

Cronologia completa (in inglese): [CHANGELOG.md](CHANGELOG.md). Testo della release: [docs/RELEASE-NOTES-2.3.md](docs/RELEASE-NOTES-2.3.md).

## Licenza e versione ufficiale
Music Manager è software libero: puoi ridistribuirlo e/o modificarlo secondo i termini della **GNU General Public License, versione 3 o (a tua scelta) qualsiasi versione successiva** (file [LICENSE](LICENSE)). È distribuito senza alcuna garanzia. Copyright (C) 2026 Riccardo Colaiori (cr.developer).
- Puoi usare, studiare e modificare il codice; se distribuisci una versione modificata, devi dare a chi la riceve il codice sorgente con la stessa licenza.
- **Versione ufficiale:** l'unico canale ufficiale è la pagina [Releases](https://github.com/RickyDive/musicmanager/releases) di questo repository. Confronta sempre l'hash del DMG con il file `.sha256` allegato (`shasum -a 256 <file>.dmg`).
- **Sorgenti:** il codice sorgente di ogni release è in questo repository: le versioni finali nella branch `main` (tag `vX.Y`), le beta nella branch `beta` (tag `vX.Y-BetaN`). Gli archivi «Source code» di ogni pagina [Releases](https://github.com/RickyDive/musicmanager/releases) contengono esattamente i sorgenti di quella build.
- Le versioni modificate e ridistribuite devono usare un nome diverso e non presentarsi come ufficiali né come approvate dall'autore.
- Le modifiche si propongono con una Pull Request; le accetta l'autore. I contributi sono accolti con la stessa licenza (GPL v3 o successiva).
- **Grazie a [mcoliver](https://github.com/mcoliver):** i workflow di build e rilascio in `.github/` (controllo della build sulle pull request, bozza di rilascio sui tag; GPL v3 o successiva) sono un suo contributo, e l'idea di inviare sull'orologio gli episodi di Apple Podcasts nasce dal suo script [fixPodcastMetadata](https://github.com/mcoliver/fixPodcastMetadata) (licenza MIT; nessun codice dello script è usato).

Incorpora **libmtp** e **libusb** (LGPL 2.1+), collegate dinamicamente: vedi [licenses/](licenses/README.md). I loro sorgenti: https://github.com/libmtp/libmtp e https://github.com/libusb/libusb; le versioni incluse sono indicate nelle note di ogni release. Note tecniche (in inglese): [docs/PROJECT-NOTES.md](docs/PROJECT-NOTES.md).
