# Music Manager 2.5.1 — release notes (text for the GitHub release)

**Tag:** `v2.5.1` · Apple Silicon, macOS 26 or later · version 2.5.1 (build 51)

[English](#english) · [Italiano](#italiano)

---

## English

**Music Manager 2.5.1 follows 2.5 with a fix for a crash when dragging the player's progress bar, a first set of tools for runners (live PacePro forecast in the player, a reworked Running Tool panel, miles, a pace calculator) and better handling of Garmin software and maps updates.** Starting point: the published 2.5.

Music Manager transfers music, albums and playlists from the Music app to a Garmin watch over USB (MTP) and manages what is on the watch. It is an independent project, not affiliated with or endorsed by Garmin or Apple.

### What is new since 2.5

**Fix**
- **Crash while scrubbing the player.** Dragging the progress bar of the mini player, fast and repeatedly, could crash the app (this was already the case in 2.5). Scrubbing now sends the player one request at a time, and the «Now Playing» artwork is created once per song.
- **Remote library, lost connection.** If the network or the VPN drops while a remote library is being copied, the app now says so clearly (check the network or the VPN, check that the volume is still connected, try again) instead of «The file couldn't be opened.». The log records what happened.

**Custom Playlist for runners**
- **Live PacePro forecast in the player.** With the Custom Playlist and PacePro on, the mini player shows what a runner would see on the watch: running time, distance with two decimals, and current split with its pace, plus a read-only course with a runner figure that advances with the forecast distance, and «km N» signs that slide in as each kilometre is reached. It is a **forecast, not a measurement**: it holds if the Custom plays from the start, in order, with no skipping (the tooltip says so).
- **Running Tool.** The panel of the runner button («Sequence and times» before) is now the **Running Tool**, with two sections: **Block numbering** and **PacePro**. Smaller fields with fixed-width digits, switches at the size of Settings.
- **Saved settings.** A «Saved» menu in the panel stores the whole panel (sequence, mid song, rolling time, km per song, PacePro rows, start delay and unit) under a name, per user, and recalls it with one click.
- **PacePro in miles.** A «km | mi» selector (and Settings ▸ General ▸ **Running unit**: Automatic, Kilometres, Miles; Automatic follows the macOS region) switches the unit everywhere: panel, list, tags and player. The values you typed are converted and, switching back, restored exactly.
- **Pace calculator.** Type any two of distance, time and pace and the third is calculated; one button copies distance and pace into PacePro and turns PacePro and rolling time on.
- **Easier PacePro entry.** Pace fields refuse impossible values (such as 6:89) and complete themselves when you leave the field («6:8» → «6:08»); the first value goes to the first row; the rows are put in order when the panel closes.
- **«Mid» song.** With PacePro on, the middle song is the one where the middle of the race falls (start delay plus half of the race time), not the middle of the playlist.
- **List.** The time column has a fixed width, so the columns no longer move at the hour (and stay readable beyond 10 hours); the selected row keeps its time, distance and «km N» tag readable.
- **Covers.** Loading a Custom Playlist now asks Music for the covers it has in its cache, as the other tabs do.

**Garmin device**
- **Software update notes.** Notes are recovered when the watch was updated outside Music Manager (Garmin Express, the phone, the watch's own Wi-Fi) while Garmin still offers that version, and they are completed once a day when Garmin publishes them late. When Garmin has no notes the app says so; the placeholder «N/A» is not shown as a note. If the watch was updated outside the app, a message says «updated from X to Y» (local, no request to Garmin).
- **Maps.** Installed maps are checked together with the software, at launch and once a day; the maps globe turns red when a map has an update. The «Update available» window mentions, with one generic line in red, that installed maps also have updates.
- **New device window.** When a watch is connected for the first time the window shows a summary (model, software version with an «Upgrade Available» / «Software Updated» capsule, serial number, product code, storage) and the product image as soon as it is read. If «Check for device Software and Maps updates» is off, the window explains it and asks for your consent; nothing is sent to Garmin without it. Choosing Skip without a nickname registers the device under its own name, and a small panel says where to set a nickname later.
- **Settings ▸ Advanced ▸ Devices.** You can remove a single stored device (select it and press «−», with confirmation); «Forget Devices» is gone.
- **Disconnect.** After pressing Disconnect a panel says that the watch is no longer active in Music Manager but is still connected to the Mac, and that it must be disconnected safely with its own eject function before unplugging it.
- **Device panel.** «Product Number» is now «Product Code» («Cod. Prodotto»), on one line. The product image is looked up under the two file names Garmin uses (also for Edge and Forerunner 970).

**Podcasts**
- Each episode in the Podcasts list shows its description (plain text, up to two lines) under the detail line.

### Things worth knowing
- Developed and tested on macOS 27 with the author's libraries and a fenix 9 Pro. **macOS 26 and other watch models have not been tested on real machines** (the product image variants for the Forerunner 970 and the Edge are looked up but were not verified). Not notarized: if macOS blocks the first launch, run `xattr -cr "/Applications/Music Manager.app"` (see `docs/INSTALL.md`).
- The check for software and maps updates is optional and off by default: when on, Music Manager sends the contents of `GarminDevice.xml` to Garmin's servers through an undocumented service. The app asks you the first time a watch is connected; you can change it in Settings.
- Podcasts: macOS lets an app read the Apple Podcasts files only with the **Full Disk Access** permission (see the 2.5 notes); because the app is not notarized, the permission may need to be renewed after an update.
- The live forecast of the player is a forecast: it does not read anything from the watch.
- Sources: this release is on the `main` branch with the tag `v2.5.1`; the «Source code» archives of this page contain exactly the sources of this build.
- Please report problems on GitHub, attaching the log (Settings ▸ «Detailed log») if possible.

### Acknowledgements
Thanks to **mcoliver** for the continuous-integration proposal and the build checks ([issue #2](https://github.com/RickyDive/musicmanager/issues/2), [pull request #3](https://github.com/RickyDive/musicmanager/pull/3)).

### Checksum
The SHA-256 of the DMG is in the attached `.sha256` file.

Free software, GPL v3 or later.

---

## Italiano

**Music Manager 2.5.1 segue la 2.5 con la correzione di un crash trascinando la barra di avanzamento del player, un primo gruppo di strumenti per chi corre (previsione PacePro in tempo reale nel player, pannello Utilità Running rinnovato, miglia, calcolatore del passo) e una gestione migliore degli aggiornamenti software e mappe dei Garmin.** Punto di partenza: la 2.5 pubblicata.

Music Manager trasferisce musica, album e playlist dall'app Musica a un orologio Garmin via USB (MTP) e gestisce ciò che c'è sull'orologio. È un progetto indipendente, non affiliato né approvato da Garmin o Apple.

### Cosa c'è di nuovo rispetto alla 2.5

**Correzioni**
- **Crash trascinando la barra del player.** Trascinare la barra di avanzamento del mini player, in fretta e più volte, poteva far chiudere l'app (era così già nella 2.5). Ora lo scorrimento invia al player una richiesta alla volta e la copertina di «In riproduzione» viene creata una sola volta per brano.
- **Libreria remota, connessione persa.** Se la rete o la VPN cade mentre si copia una libreria remota, l'app lo dice chiaramente (controlla la rete o la VPN, verifica che il volume sia ancora collegato, riprova) invece di «The file couldn't be opened.». Il registro annota l'accaduto.

**Custom Playlist per chi corre**
- **Previsione PacePro in tempo reale nel player.** Con la Custom Playlist e PacePro attivi, il mini player mostra ciò che un runner vedrebbe sull'orologio: tempo di corsa, distanza con due decimali e frazione in corso con il suo passo, più un percorso (solo lettura) con la figura di un runner che avanza con la distanza prevista e i cartelli «km N» che scorrono quando si raggiunge ogni chilometro. È una **previsione, non una misura**: vale se la Custom suona dall'inizio, in ordine, senza salti (lo dice il tooltip).
- **Utilità Running.** Il pannello del pulsante runner (prima «Sequenza dei blocchi e tempi») diventa **Utilità Running**, con due sezioni: **Numerazione a blocchi** e **PacePro**. Campi più piccoli con cifre a larghezza fissa, interruttori della misura di Impostazioni.
- **Impostazioni salvate.** Un menù «Salvati» nel pannello memorizza tutto il pannello (sequenza, brano a metà, tempo progressivo, km per brano, righe PacePro, ritardo e unità) con un nome, per utente, e lo richiama con un clic.
- **PacePro in miglia.** Un selettore «km | mi» (e Impostazioni ▸ Generali ▸ **Running unit**: Automatica, Chilometri, Miglia; Automatica segue la regione di macOS) cambia l'unità ovunque: pannello, elenco, etichette e player. I valori scritti si convertono e, tornando indietro, si ripristinano esattamente.
- **Calcolatore del passo.** Scrivi due qualsiasi tra distanza, tempo e passo e il terzo viene calcolato; un pulsante copia distanza e passo in PacePro e accende PacePro e tempo progressivo.
- **PacePro più comodo.** I campi del passo rifiutano valori impossibili (come 6:89) e si completano all'uscita dal campo («6:8» → «6:08»); il primo valore va nella prima riga; le righe si mettono in ordine alla chiusura del pannello.
- **Brano «Metà».** Con PacePro attivo, il brano di metà è quello in cui cade la metà della gara (ritardo iniziale più metà del tempo di gara), non la metà della playlist.
- **Elenco.** La colonna del tempo ha larghezza fissa: le colonne non si spostano più al passaggio dell'ora (e restano leggibili oltre le 10 ore); nella riga selezionata restano leggibili tempo, distanza e cartello «km N».
- **Copertine.** Caricando una Custom Playlist l'app chiede a Musica le copertine che ha nella cache, come fanno le altre schede.

**Dispositivo Garmin**
- **Note degli aggiornamenti software.** Le note si recuperano quando l'orologio è stato aggiornato fuori da Music Manager (Garmin Express, telefono, Wi-Fi dell'orologio) finché Garmin offre ancora quella versione, e si completano una volta al giorno quando Garmin le pubblica in ritardo. Se Garmin non ha note, l'app lo dice; il segnaposto «N/A» non viene mostrato come nota. Se l'orologio è stato aggiornato fuori dall'app, un messaggio dice «aggiornato da X a Y» (locale, nessuna richiesta a Garmin).
- **Mappe.** Le mappe installate vengono controllate insieme al software, all'avvio e una volta al giorno; il globo delle mappe diventa rosso quando una mappa ha un aggiornamento. La finestra «Update available» segnala, con una riga generica in rosso, che anche le mappe installate hanno aggiornamenti.
- **Finestra di nuovo dispositivo.** Al primo collegamento mostra un riepilogo (modello, versione del software con la capsule «Upgrade Available» / «Software Updated», numero di serie, codice prodotto, memoria) e l'immagine del prodotto appena letta. Se «Controlla gli aggiornamenti di software e mappe del dispositivo» è spento, la finestra lo spiega e chiede il consenso; senza consenso non viene inviato nulla a Garmin. Scegliere Skip senza nickname registra comunque il dispositivo con il suo nome, e un piccolo pannello dice dove impostare il nickname dopo.
- **Impostazioni ▸ Avanzate ▸ Dispositivi.** Si può rimuovere un solo dispositivo memorizzato (selezionalo e premi «−», con conferma); «Forget Devices» non c'è più.
- **Disconnetti.** Dopo aver premuto Disconnetti, un pannello dice che l'orologio non è più attivo in Music Manager ma resta collegato al Mac, e che va scollegato in sicurezza con la sua funzione di espulsione prima di togliere il cavo.
- **Pannello del dispositivo.** «Product Number» diventa «Product Code» («Cod. Prodotto»), su una riga. L'immagine del prodotto è cercata con i due nomi di file usati da Garmin (anche per Edge e Forerunner 970).

**Podcast**
- Ogni episodio dell'elenco Podcast mostra la descrizione (testo semplice, al massimo due righe) sotto la riga dei dettagli.

### Cose da sapere
- Sviluppata e provata su macOS 27 con le librerie dell'autore e un fenix 9 Pro. **macOS 26 e altri modelli di orologio non sono stati provati su macchine reali** (le varianti dell'immagine per Forerunner 970 ed Edge sono cercate ma non verificate). Non notarizzata: se macOS blocca il primo avvio, esegui `xattr -cr "/Applications/Music Manager.app"` (vedi `docs/INSTALL.md`).
- Il controllo degli aggiornamenti software e mappe è facoltativo e spento di default: quando è acceso, Music Manager invia il contenuto di `GarminDevice.xml` ai server Garmin tramite un servizio non documentato. L'app lo chiede la prima volta che si collega un orologio; lo si cambia in Impostazioni.
- Podcast: macOS permette a un'app di leggere i file di Apple Podcasts solo con il permesso **Accesso completo al disco** (vedi le note della 2.5); poiché l'app non è notarizzata, dopo un aggiornamento il permesso può dover essere rinnovato.
- La previsione in tempo reale del player è una previsione: non legge nulla dall'orologio.
- Sorgenti: questa versione è nella branch `main` con il tag `v2.5.1`; gli archivi «Source code» di questa pagina contengono esattamente i sorgenti di questa build.
- Segnala i problemi su GitHub, allegando il registro (Impostazioni ▸ «Registro dettagliato») se possibile.

### Ringraziamenti
Grazie a **mcoliver** per la proposta di integrazione continua (CI) e i controlli di build ([issue #2](https://github.com/RickyDive/musicmanager/issues/2), [pull request #3](https://github.com/RickyDive/musicmanager/pull/3)).

### Checksum
L'SHA-256 del DMG è nel file `.sha256` allegato.

Software libero, GPL v3 o successiva.
