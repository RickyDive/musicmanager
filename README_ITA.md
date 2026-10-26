# Music Manager

[🇬🇧 English](README.md) · 🇮🇹 Italiano

App per macOS che trasferisce musica, album e playlist dalla libreria dell'app **Musica** a un orologio **Garmin** (Fenix, Forerunner, Edge…) via USB (MTP), e ne gestisce il contenuto.

> **Versione 2.1.** Il feedback è benvenuto: apri una [Issue](https://github.com/RickyDive/musicmanager/issues/new/choose).
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

## Novità della 2.2
- **Librerie su unità esterna** (Impostazioni ▸ Avanzate, fino a 3): una cartella di file audio su una chiavetta USB, un disco o una cartella di rete diventa una libreria, con un indice proprio creato dai tag. Restano solo i formati che il tuo Garmin accetta; FLAC, WAV, AIFF e ALAC sono mostrati ma non inviabili. Riscansione incrementale, copertine dai file, pulsante **Espelli**.
- **Librerie remote (di rete)**: montaggio più affidabile (si controlla prima il server, niente lunghe attese né errori di sistema), interruttore **Monta automaticamente** e pallino di stato a tre stati, avanzamento in tempo reale della prima lettura dell'XML, avviso quando l'XML sul server è cambiato, riproduzione con caricamento e riconoscimento della connessione lenta, smontaggio dei volumi montati dall'app alla chiusura.
- **Musica e copertine**: una domanda prima di aggiungere brani a Musica (Impostazioni ▸ Generale), pannello delle copertine online ridisegnato, avvio più veloce (percorsi salvati, libreria riletta al ritorno nell'app), opzione *Thread per leggere la libreria*, duplicati elencati con una casella per ogni brano.
- **Interfaccia**: barre di vetro fluttuanti, barra del titolo in stile Xcode con capsula di attività, un solo aggiorna e una sola ricerca (⌘F), campanella delle notifiche, finestre di vetro centrate, modalità compatta per le risoluzioni basse, menu del tasto destro e mini player più ricchi, un solo evidenziatore arrotondato per la selezione, digitazione negli elenchi con il testo nell'indicatore della lettera, tre tabelle uguali nelle Impostazioni, testi italiani rivisti e nuova icona.

**Da sapere:** con le librerie remote la prima lettura è lenta e le aperture successive sono immediate; lì la digitazione negli elenchi posiziona solo sulla prima lettera, quindi usa la ricerca con la lente. Con due condivisioni dallo stesso nome il Finder può lasciare una voce «fantasma» vuota dopo lo smontaggio (`killall Finder` o un riavvio la elimina). Il controllo degli aggiornamenti software segue la distribuzione a gruppi di Garmin, come Garmin Express.

**Limiti noti:** non provata su macOS 26 (sviluppata e provata su macOS 27); non notarizzata (vedi [docs/INSTALL.md](docs/INSTALL.md) se il primo avvio è bloccato); i formati lossless non vengono convertiti né inviati; le playlist trovate nella cartella di un'unità non si importano; nessun controllo dell'app dall'Apple TV; ricevitori AirPlay molto vecchi possono essere rifiutati da macOS stesso.

Cronologia completa (in inglese): [CHANGELOG.md](CHANGELOG.md). Testo della release: [docs/RELEASE-NOTES-2.2.md](docs/RELEASE-NOTES-2.2.md).

## Licenza e versione ufficiale
Music Manager è software libero, distribuito con licenza **GNU GPL v3.0** (file [LICENSE](LICENSE)). Copyright (C) 2026 Riccardo Colaiori (cr.developer).
- Puoi usare, studiare e modificare il codice; se distribuisci una versione modificata devi pubblicarne il sorgente con la stessa licenza.
- **Versione ufficiale:** l'unico canale ufficiale è la pagina [Releases](https://github.com/RickyDive/musicmanager/releases) di questo repository. Confronta sempre l'hash del DMG con il file `.sha256` allegato (`shasum -a 256 <file>.dmg`).
- Le versioni modificate e ridistribuite devono usare un nome diverso e non presentarsi come ufficiali né come approvate dall'autore.
- Le modifiche si propongono con una Pull Request; le accetta l'autore.

Incorpora **libmtp** e **libusb** (LGPL 2.1+), collegate dinamicamente: vedi [licenses/](licenses/README.md). Note tecniche (in inglese): [docs/PROJECT-NOTES.md](docs/PROJECT-NOTES.md).
