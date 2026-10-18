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

## Novità della 2.1
- Music e dispositivo: filtro per genere e «Trova simili»; album multi-disco con intestazioni «Disc n of m»; caselle di selezione e stato «sul dispositivo»; freccia verde «sul dispositivo» su album e artisti; selezione a intervallo con Maiusc+clic e trascinamento per selezionare.
- Invio: più playlist insieme con una finestra di trasferimento per playlist, invii misti (playlist intere più brani singoli) e pulsante **Annulla** che ferma l'invio e mostra cosa è stato inviato e cosa no. «Invia» è disattivato quando la selezione non entra.
- Eliminazione: una finestra di conferma elenca i brani e le playlist coinvolte; le playlist interessate vengono riscritte senza di essi.
- Barra dello spazio: *System*, *Data*, *Maps*, *Services* (Spotify, Amazon Music, Deezer…), *Music*; spazio libero scritto dentro la barra, riga *Storage Capacity* e avviso arancione o rosso quando lo spazio sta finendo.
- Player e AirPlay: volume che funziona con Apple TV, HomePod e amplificatori («AirPlay come audio», attivo di default), il cursore dell'app segue il dispositivo AirPlay e l'Apple TV mostra copertina, artista e titolo (In riproduzione); funzionano i tasti multimediali e il Centro di Controllo.
- Dispositivi Garmin montati come disco (es. Edge): informazioni ed Espelli. **Sperimentale, spento di default**: musica su dischi esterni e schede SD (Impostazioni ▸ Avanzate ▸ Strumenti).
- Impostazioni ▸ Avanzate ▸ Strumenti: File Manager del dispositivo opzionale (sola lettura), interruttore del registro dettagliato con *Mostra il file di registro*; Aiuto ▸ Salva GarminDevice.xml / Salva albero del dispositivo.
- Avvio più rapido: la libreria di Music viene letta in parallelo. Tutte le impostazioni sono globali; pulsanti piatti e nuova icona; l'app si chiama ora **Music Manager**.

**Limiti noti:** non provata su macOS 26; non notarizzata (vedi [docs/INSTALL.md](docs/INSTALL.md) se il primo avvio è bloccato); nessun controllo dell'app dall'Apple TV; ricevitori AirPlay molto vecchi possono essere rifiutati da macOS stesso.

Cronologia completa (in inglese): [CHANGELOG.md](CHANGELOG.md).

## Licenza e versione ufficiale
Music Manager è software libero, distribuito con licenza **GNU GPL v3.0** (file [LICENSE](LICENSE)). Copyright (C) 2026 Riccardo Colaiori (cr.developer).
- Puoi usare, studiare e modificare il codice; se distribuisci una versione modificata devi pubblicarne il sorgente con la stessa licenza.
- **Versione ufficiale:** l'unico canale ufficiale è la pagina [Releases](https://github.com/RickyDive/musicmanager/releases) di questo repository. Confronta sempre l'hash del DMG con il file `.sha256` allegato (`shasum -a 256 <file>.dmg`).
- Le versioni modificate e ridistribuite devono usare un nome diverso e non presentarsi come ufficiali né come approvate dall'autore.
- Le modifiche si propongono con una Pull Request; le accetta l'autore.

Incorpora **libmtp** e **libusb** (LGPL 2.1+), collegate dinamicamente: vedi [licenses/](licenses/README.md). Note tecniche (in inglese): [docs/PROJECT-NOTES.md](docs/PROJECT-NOTES.md).
