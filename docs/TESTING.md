# Scenari di test – 2.1 Beta 1
1. Installazione da DMG su un Mac **senza** Homebrew (verifica librerie incorporate).
2. Primo avvio: aggiramento Gatekeeper, messaggio di benvenuto, permesso Musica.
3. Rilevamento orologio (e con nessun orologio collegato: ricerca ogni 5 s).
4. Lettura catalogo del dispositivo (artisti/album/playlist).
5. Invio di un album e di una playlist; verifica del file m3u8 e del numero di tracce.
6. Artista con carattere speciale (es. AC/DC) mostrato correttamente.
7. Dispositivo con un solo storage: il selettore memoria non compare.
8. Menu Aiuto: copia diagnostica, mostra log, licenze di terze parti.
9. Lingua italiano / inglese.

Per ogni problema apri una Issue su GitHub con modello "Bug report" e incolla le informazioni diagnostiche.

## Se l'app non si apre o resta bloccata (macOS 27)
1. Usa il Metodo A di `docs/INSTALL.md` (`xattr -cr`).
2. Se serve capire cosa succede: `bash Scripts/diagnose-launch.sh` (crea un file sul Desktop) e allegalo alla Issue.
3. Prova a disattivare la rete (Wi-Fi spento) e riaprire: se parte, la verifica di macOS aspettava i server Apple.

## Dispositivi Garmin come volume (2.1 Beta 2, fase 1: solo riconoscimento)
Con un dispositivo che si monta come disco (es. Edge) o con i dischi di prova (`Scripts/make-test-volume.sh`):
1. Edge reale: nel pannello Device compaiono modello, versione software, nome e spazio del volume, la capsula "No music" e il pulsante **Eject**.
2. `make-test-volume.sh music`: riconosciuto, senza capsula "No music".
3. `make-test-volume.sh nomusic`: riconosciuto, con la capsula.
4. `make-test-volume.sh notgarmin` e `badxml`: ignorati (il pannello resta con il messaggio "Collega l'orologio…").
5. Una chiavetta qualsiasi: ignorata.
6. Eject: il volume sparisce e lo stato dice che si può scollegare il cavo.
7. Con un orologio MTP collegato insieme a un Edge: l'orologio funziona come prima.
8. Aiuto ▸ Copia informazioni diagnostiche: la riga "Garmin volumes" elenca il dispositivo.

## Volume devices — phase 1b (2.1 Beta 2) / Dispositivi a volume — fase 1b

EN: With Settings ▸ Advanced "check updates" ON and a Garmin volume device (e.g. Edge) connected: the "Software Updated / Upgrade Available" capsule appears next to the software version; a globe icon opens the maps catalog; the device is remembered, so the launch-time update notice also covers it. With the option OFF nothing is sent to Garmin.

IT: Con l'opzione «controlla aggiornamenti» accesa e un dispositivo Garmin a volume collegato (es. Edge): compare la capsula «Software Updated / Upgrade Available», il globo apre il catalogo mappe, e il dispositivo viene memorizzato (l'avviso all'apertura lo include). Con l'opzione spenta non si contatta Garmin.

## Genre filter (2.1 Beta 2) / Filtro per genere
EN: In the Apple Music panel (local library and remote libraries) a filter icon next to the search field lists the genres with track counts. Songs, Albums and Artists then show only tracks of that genre (Playlists are not filtered and the icon is disabled there); "Send" acts on what is shown. The first launch re-reads remote library XML files (cache format changed). Check: genre names that differ only in case merge; "No Genre" is last; switching library resets the filter.

IT: Nel pannello Apple Music (libreria locale e remote) un'icona filtro accanto alla ricerca elenca i generi con il numero di brani. Brani, Album e Artisti mostrano solo i brani di quel genere (le Playlist non si filtrano e lì l'icona è disattivata); «Invia» agisce su ciò che si vede. Al primo avvio gli XML delle librerie remote vengono riletti (formato della cache cambiato). Da verificare: generi che differiscono solo per maiuscole si uniscono; «Senza genere» è in fondo; cambiando libreria il filtro si azzera.

## Choose product image (2.1 Beta 2) / Scelta manuale dell'immagine
EN: Right-click the device image in the Device panel ▸ "Choose Product Image…" opens the list of Garmin products (the cached `deviceTypes.json`, refreshed at most every 7 days) with search; one click sets the image, which is remembered for stored devices (music-capable) and kept only until quit for the others. "Use Automatic Image" goes back to the automatic one. Works for MTP and volume devices.
IT: Click destro sull'immagine del dispositivo ▸ «Scegli l'immagine del prodotto…» apre l'elenco dei prodotti Garmin (`deviceTypes.json` in cache, aggiornato al massimo ogni 7 giorni) con ricerca; un click imposta l'immagine, ricordata per i dispositivi memorizzati (con musica) e tenuta fino alla chiusura per gli altri. «Usa l'immagine automatica» riporta quella automatica. Vale per MTP e volumi.

## Language and menu bar (2.1 Beta 2) / Lingua e barra dei menu
EN: Changing the language in Settings ▸ General updates at once the app's own menu items (File ▸ Load/Save playlist, About, Help) and window titles. The standard macOS names (File, Edit, View, Window, Cut/Copy/Paste…) are translated by the system at launch, so they follow the new language from the next launch (the app stores it as its `AppleLanguages`). Check both directions (English→Italian and back) with the system language set to each.
IT: Cambiando lingua in Impostazioni ▸ Generale le voci proprie dell'app (File ▸ Carica/Salva playlist, Informazioni, Aiuto) e i titoli delle finestre si aggiornano subito. I nomi standard di macOS (File, Modifica, Vista, Finestra, Taglia/Copia/Incolla…) li traduce il sistema all'avvio, quindi seguono la nuova lingua dal prossimo avvio (l'app la salva come `AppleLanguages`). Provare nei due sensi (inglese→italiano e ritorno) con il sistema in ciascuna lingua.


## Trova simili (2.1 Beta 2)
1. Tasto destro su un brano (scheda Brani o dentro un album/artista/playlist), su un album o su un artista → «Trova simili» (icona apple.haptics.and.music.note). Si apre una finestra «Simili a …».
2. L'elenco è ordinato per punteggio, con una barra da 0 al massimo ottenibile e il valore a fianco. Righe come nell'elenco Brani: click per scegliere (si sommano), doppio click per ascoltare.
3. «OK» somma i brani scelti alla selezione già fatta e chiude; «Invia a Custom» li manda alla Custom Playlist (stesse regole di «Invia alla Playlist»: duplicati, svuotamento, copertine online per le librerie condivise); «Annulla» chiude senza fare nulla.
4. Anno e BPM entrano nel punteggio solo se presenti nella libreria. Le copie della libreria salvate prima della 2.1 Beta 2 non li contengono: dopo l'aggiornamento usare File ▸ «Ricarica libreria» (⌘R).
5. Verifiche: brano senza genere/anno/BPM (nessun errore, barra in scala), album e artista come partenza (titolo corretto), libreria condivisa di un'altra rete, elenco vuoto («Nessun brano simile trovato»).
