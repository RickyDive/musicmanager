# Music Manager

[🇬🇧 English](README.md) · 🇮🇹 Italiano

App per macOS che trasferisce musica, album e playlist dalla libreria dell'app **Musica** a un orologio **Garmin** (Fenix, Forerunner, Edge…) via USB (MTP), e ne gestisce il contenuto.

> **Versione 2.1 Beta 3** — fase di test. Cerco feedback: apri una [Issue](https://github.com/RickyDive/musicmanager/issues/new/choose).
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

## Novità della 2.1 Beta 3
- Barra dello spazio rifatta: *System*, *Data*, *Maps*, *Services* (app di streaming come Spotify, Amazon Music, Deezer), *Music*; suggerimenti con le dimensioni, legenda dinamica, spazio libero sopra la barra.
- «Invia» è disattivato quando la selezione non entra nello spazio libero.
- Freccia verde «sul dispositivo» sulle intestazioni di album e artisti quando tutti i loro brani trasferibili sono già sull'orologio.
- Aiuto ▸ Salva GarminDevice.xml / Salva albero del dispositivo (diagnostica in sola lettura); File Manager del dispositivo opzionale (Impostazioni ▸ Avanzate ▸ Strumenti, spento di default).
- Corretto il lampeggio della barra dei menu durante la preparazione dei brani.

Cronologia completa (in inglese): [CHANGELOG.md](CHANGELOG.md).

## Novità della 2.1 Beta 2
- Filtro per genere, «Trova simili», dispositivi Garmin montati come volume (riconoscimento), scelta manuale dell'immagine del prodotto.
- Elenchi Music: caselle di selezione a sinistra, icona «sul dispositivo» nella colonna della selezione; album multi-disco con intestazioni «Disc n of m»; l'elenco Device mostra numeri di traccia e durate.
- Pannello Device: pulsanti Pulisci selezione, Elimina e Cancella Tutto; Elimina apre una conferma dettagliata con i brani e le playlist coinvolte, e riscrive quelle playlist senza i brani eliminati (le playlist che restano vuote vengono rimosse dal dispositivo).
- Impostazioni: aspetto uniforme in tutte le schede, colore di selezione con cursore di tonalità, indicatore di dispositivo collegato, Copia del numero di serie.
- Tutte le impostazioni sono ora globali (niente più profili per dispositivo).
- Problema noto in analisi: primo avvio lento o bloccato su macOS 27 (vedi `docs/TESTING.md`).

## Licenza e versione ufficiale
Music Manager è software libero, distribuito con licenza **GNU GPL v3.0** (file [LICENSE](LICENSE)). Copyright (C) 2026 Riccardo Colaiori (cr.developer).
- Puoi usare, studiare e modificare il codice; se distribuisci una versione modificata devi pubblicarne il sorgente con la stessa licenza.
- **Versione ufficiale:** l'unico canale ufficiale è la pagina [Releases](https://github.com/RickyDive/musicmanager/releases) di questo repository. Confronta sempre l'hash del DMG con il file `.sha256` allegato (`shasum -a 256 <file>.dmg`).
- Le versioni modificate e ridistribuite devono usare un nome diverso e non presentarsi come ufficiali né come approvate dall'autore.
- Le modifiche si propongono con una Pull Request; le accetta l'autore.

Incorpora **libmtp** e **libusb** (LGPL 2.1+), collegate dinamicamente: vedi [licenses/](licenses/README.md). Note tecniche (in inglese): [docs/PROJECT-NOTES.md](docs/PROJECT-NOTES.md).
