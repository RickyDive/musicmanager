import Foundation
import SwiftUI

// MARK: - Lingue supportate

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    /// Inglese è la lingua principale (ripiego di default); italiano l'unica alternativa.
    case en, it

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .en: return "English"
        case .it: return "Italiano"
        }
    }

    /// Lingua da usare alla prima apertura (nessuna impostazione salvata): italiano se la lingua preferita del
    /// sistema è l'italiano, inglese per tutte le altre.
    static var systemDefault: AppLanguage {
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("it") ? .it : .en
    }

    var flag: String {
        switch self {
        case .en: return "🇬🇧"
        case .it: return "🇮🇹"
        }
    }
}

// MARK: - Archivio globale della lingua

/// Tiene la lingua corrente in modo accessibile da qualunque punto del codice — viste SwiftUI,
/// `AppViewModel` (Main Actor), ma anche `MTPError` e l'actor `MTPService` — senza vincoli di
/// isolamento, perché quei tipi non sono legati al Main Actor. La lingua si cambia dal pannello
/// Impostazioni (menu dell'app); le letture da altri contesti sono innocue anche se colgono per
/// un istante il valore precedente durante un cambio, dato che non è mai un dato critico (nel
/// peggiore dei casi un singolo messaggio resta nella lingua precedente).
enum LocalizationStore {

    /// Predefinita: inglese. È un'impostazione globale dell'app (vedi `AppSettings.Profile`), uguale per ogni dispositivo.
    nonisolated(unsafe) static var language: AppLanguage = .en

    /// I menu standard di macOS (File, Modifica, Vista, Finestra, Aiuto, Copia, Incolla…) sono tradotti dal sistema in base
    /// alle lingue dell'app all'AVVIO: non si possono cambiare a programma già aperto. Si salva quindi la lingua scelta come
    /// lingua dell'app (`AppleLanguages`) perché dal prossimo avvio anche quei menu la seguano.
    static func applySystemMenuLanguage() {
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }
}

/// Wrapper `@MainActor`/`ObservableObject` attorno a `LocalizationStore`, usato dalle viste
/// SwiftUI (il selettore è nel pannello Impostazioni): cambiare `language` qui aggiorna sia
/// l'archivio globale sia, tramite `@Published`, ogni vista che osserva questa istanza condivisa
/// (`SettingsView` per il Picker, `ContentView` — da cui dipende tutta la gerarchia — per il
/// resto dell'interfaccia).
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published var language: AppLanguage = LocalizationStore.language {
        didSet {
            LocalizationStore.language = language
            LocalizationStore.applySystemMenuLanguage()
            AppSettings.shared.saveActiveProfile()
        }
    }

    private init() {}
}

/// Testo di una chiave in una lingua precisa (non quella corrente): serve a misurare le larghezze dei pulsanti in modo
/// che non cambino al cambio di lingua.
func tFor(_ lang: AppLanguage, _ key: String) -> String {
    L.table[key]?[lang] ?? L.table[key]?[.en] ?? key
}

/// Traduce una chiave nella lingua correntemente selezionata. Se la chiave prevede argomenti
/// (`%@`, `%d`, o le forme posizionali `%1$@`/`%2$d`…), passarli qui; altrimenti restituisce il
/// testo cosi com'è. In assenza di lingua o chiave, ripiega sull'inglese e infine sulla chiave
/// stessa, cosi l'interfaccia non mostra mai una stringa vuota.
func t(_ key: String, _ args: CVarArg...) -> String {
    let lang = LocalizationStore.language
    let template = L.table[key]?[lang] ?? L.table[key]?[.en] ?? key
    guard !args.isEmpty else { return template }
    return String(format: template, arguments: args)
}

// MARK: - Tabella traduzioni

private enum L {
    static let table: [String: [AppLanguage: String]] = [

        // Pannello Apple Music
        "settings_confirm_music_changes": [
            .it: "Chiedi conferma prima di aggiungere a Music", .en: "Ask before adding to Music"
        ],
        "settings_confirm_music_changes_hint": [
            .it: "Prima di aggiungere brani alla libreria di Music (file trascinati dal Finder, brani di una libreria esterna salvati in una playlist di Music) viene chiesta una conferma. Se è spento, i brani si aggiungono senza chiedere.",
            .en: "Before songs are added to your Music library (files dragged from Finder, songs of an external library saved into a Music playlist) a confirmation is asked. When off, songs are added without asking."
        ],
        "alert_music_add_title": [
            .it: "Aggiungere a Music?", .en: "Add to Music?"
        ],
        "alert_music_add_message_drop": [
            .it: "%d brani non sono nella libreria di Music. Puoi aggiungerli a Music (compariranno anche lì) oppure inviarli solo all'orologio, senza toccare la libreria.",
            .en: "%d songs are not in your Music library. You can add them to Music (they will appear there too) or send them only to the watch, leaving the library untouched."
        ],
        "alert_music_add_message_custom": [
            .it: "%d brani della Custom Playlist non sono nella libreria di Music. Salvando la playlist in Music verrebbero aggiunti anche alla libreria: puoi aggiungerli oppure salvare la playlist senza questi brani.",
            .en: "%d songs of the Custom Playlist are not in your Music library. Saving the playlist to Music would add them to the library too: you can add them, or save the playlist without them."
        ],
        "alert_music_add_message_playlist": [
            .it: "Verrà creata la playlist «%@» nella cartella «≡♪ Music Manager» di Music. Vuoi continuare?",
            .en: "The playlist “%@” will be created in the “≡♪ Music Manager” folder of Music. Do you want to continue?"
        ],
        "button_save_to_music_short": [
            .it: "Salva in Music", .en: "Save to Music"
        ],
        "button_add_to_music": [
            .it: "Aggiungi a Music", .en: "Add to Music"
        ],
        "button_watch_only": [
            .it: "Solo sull'orologio", .en: "Only to the watch"
        ],
        "button_save_without_them": [
            .it: "Salva senza questi brani", .en: "Save without them"
        ],
        "settings_show_only_transferable": [
            .it: "Mostra solo i brani trasferibili", .en: "Show only transferable songs"
        ],
        "settings_show_only_transferable_hint": [
            .it: "Nasconde in Music i brani che non si possono trasferire (es. solo in cloud, protetti) e le playlist che ne restano senza.",
            .en: "Hides songs that cannot be transferred (e.g. cloud-only, protected) in Music, and playlists left with none."
        ],
        "settings_text_size": [
            .it: "Dimensione testo negli elenchi", .en: "Text size in list"
        ],
        "settings_text_size_xs": [.it: "Molto piccolo", .en: "Extra small"],
        "settings_text_size_medium": [.it: "Medio", .en: "Medium"],
        "settings_text_size_large": [.it: "Grande", .en: "Large"],
        "settings_text_size_hint": [
            .it: "Cambia la prima riga di ogni voce: titolo di playlist, artista, album e brano. Le righe secondarie, le icone e i pannelli restano come sono.",
            .en: "Changes the first line of each item: playlist, artist, album and song titles. Secondary lines, icons and panels stay as they are."
        ],
        "settings_text_size_sample": [
            .it: "Blue in Green", .en: "Blue in Green"
        ],
        "settings_opacity_sample_search": [
            .it: "Cerca", .en: "Search"
        ],
        "settings_volume_music": [
            .it: "Musica su dischi esterni e schede SD (sperimentale)",
            .en: "Music on external drives and SD cards (experimental)"
        ],
        "settings_volume_music_hint": [
            .it: "Per i dispositivi Garmin visti come disco (archiviazione di massa), le schede SD e le immagini disco: accanto a Espelli compare Connetti, che apre il volume come un dispositivo (catalogo, invio, playlist, eliminazione nella cartella Music). Vale solo per i volumi che dichiarano la musica in GarminDevice.xml. Sul volume non c'è il Cestino: le eliminazioni sono definitive. Durata e numero di traccia si ricavano dalla libreria Music.",
            .en: "For Garmin devices seen as a disk (mass storage), SD cards and disk images: Connect appears next to Eject and opens the volume as a device (catalog, sending, playlists, deleting in the Music folder). Only for volumes that declare music in GarminDevice.xml. There is no Trash on the volume: deletions are permanent. Duration and track number come from the Music library."
        ],
        "settings_library_threads": [ .it: "Thread per leggere la libreria di Music", .en: "Threads to read the Music library" ],
        "settings_library_threads_multi": [ .it: "Multi thread (8)", .en: "Multi thread (8)" ],
        "settings_library_threads_single": [ .it: "Single thread (1)", .en: "Single thread (1)" ],
        "settings_library_threads_hint": [
            .it: "Come si legge la libreria di Music. «Multi thread» (predefinito) fa fino a 8 richieste insieme: è la scelta più veloce. «Single thread» ne fa una alla volta: più lento, ma più leggero per Music; usalo se Music rallenta o si blocca durante la lettura.",
            .en: "How the Music library is read. “Multi thread” (default) makes up to 8 requests at once: the fastest choice. “Single thread” makes one at a time: slower, but lighter for Music; use it if Music slows down or stalls while the library is read."
        ],
        "settings_detailed_log": [ .it: "Registro dettagliato (diagnostica)", .en: "Detailed log (diagnostics)" ],
        "settings_detailed_log_hint": [
            .it: "Scrive nel file di registro anche le righe di diagnostica (per esempio i dettagli del volume AirPlay e dei volumi usati come dispositivo). Può citare nomi di dispositivi e titoli di brani; il file resta sul Mac e non viene inviato a nessuno. Da accendere solo per cercare un problema.",
            .en: "Also writes diagnostic lines to the log file (for example details of AirPlay volume and of volumes used as a device). It may mention device names and song titles; the file stays on this Mac and is not sent anywhere. Turn it on only when looking for a problem."
        ],
        "settings_airplay_audio": [ .it: "AirPlay come audio", .en: "AirPlay as audio" ],
        "settings_airplay_audio_hint": [
            .it: "Attivo di default. L'audio va al dispositivo come a un ampli AirPlay, invece di far riprodurre il file all'Apple TV: il volume resta regolabile e il cursore resta nel pannello AirPlay di sistema. Disattivalo per usare la riproduzione esterna dell'Apple TV. Dopo averlo cambiato, scegli di nuovo il dispositivo dal pulsante AirPlay.",
            .en: "On by default. Audio is sent to the device like to an AirPlay amplifier, instead of having the Apple TV play the file itself: the volume stays adjustable and the slider stays in the system AirPlay panel. Turn it off to use the Apple TV's own external playback. After changing it, choose the device again from the AirPlay button."
        ],
        "settings_show_log":[ .it: "Mostra il file di registro", .en: "Show Log File" ],
        "settings_clean_log": [ .it: "Pulisci il registro", .en: "Clean Log" ],
        "settings_log_cleaned": [ .it: "Registro cancellato", .en: "Log file cleaned" ],
        "settings_tools": [ .it: "Strumenti", .en: "Tools" ],
        "settings_device_file_manager": [ .it: "File Manager del dispositivo", .en: "Device File Manager" ],
        "settings_device_file_manager_hint": [
            .it: "Mostra il pulsante con la cartella accanto a Connetti/Disconnetti, che apre il navigatore dei file del dispositivo: tabella ordinabile, percorso cliccabile, marcature dei file noti e copia dei file sul Mac. Sul dispositivo si legge soltanto: non si modifica nulla.",
            .en: "Shows the folder button next to Connect/Disconnect, which opens the device file browser: sortable table, clickable path, marks on known files and copying files to the Mac. The device is only read: nothing is modified."
        ],
        "settings_check_device_updates": [
            .it: "Controlla gli aggiornamenti di software e mappe del dispositivo", .en: "Check for device Software and Maps updates"
        ],
        "settings_check_device_updates_hint": [
            .it: "Una volta all'apertura dell'app interroga i server Garmin (come fa Garmin Express) per sapere se esiste un aggiornamento per gli orologi registrati, anche a orologio scollegato, usando la copia di GarminDevice.xml salvata sul Mac a ogni collegamento. Se c'è, mostra una finestra e «Upgrade Available» nel pannello. Con lo stesso interruttore l'app chiede a Garmin anche le mappe installate e quelle offerte per il dispositivo (icona della mappa). Attenzione: viene inviato a Garmin il contenuto di GarminDevice.xml (modello, numero di unità e codici di sblocco). Usa un servizio non documentato da Garmin, che potrebbe cambiare o smettere di funzionare; l'app non installa nulla.",
            .en: "Once at app launch it queries Garmin's servers (as Garmin Express does) to find out whether an update exists for your registered watches, even with the watch unplugged, using the copy of GarminDevice.xml saved on this Mac at each connection. If there is one, it shows a dialog and “Upgrade Available” in the panel. The same switch also asks Garmin for the maps installed on and offered for the device (map icon). Note: this sends the contents of GarminDevice.xml (model, unit number and unlock codes) to Garmin. It uses an undocumented Garmin service that may change or stop working; the app installs nothing."
        ],
        "tooltip_update_available": [
            .it: "Disponibile la versione %@", .en: "Version %@ is available"
        ],
        "menu_choose_device_image": [.it: "Scegli l'immagine del prodotto…", .en: "Choose Product Image…"],
        "menu_auto_device_image": [.it: "Usa l'immagine automatica", .en: "Use Automatic Image"],
        "image_picker_title": [.it: "Immagine del prodotto", .en: "Product Image"],
        "image_picker_hint": [
            .it: "Elenco dei prodotti Garmin (Connect IQ Store), aggiornato al massimo ogni 7 giorni. Scegli quello che corrisponde al tuo dispositivo: l'immagine verrà ricordata.",
            .en: "List of Garmin products (Connect IQ Store), refreshed at most every 7 days. Pick the one that matches your device: the image will be remembered."
        ],
        "image_picker_search": [.it: "Cerca per nome o part number", .en: "Search by name or part number"],
        "image_picker_loaded": [
            .it: "%d prodotti caricati", .en: "%d products loaded"
        ],
        "image_picker_empty": [.it: "Elenco non disponibile: serve una connessione a Internet.", .en: "List not available: an Internet connection is needed."],
        "settings_language_note": [
            .it: "Le voci dei menu standard di macOS (File, Modifica, Vista…) seguono la lingua scelta dal prossimo avvio dell'app.",
            .en: "The standard macOS menu names (File, Edit, View…) follow the chosen language from the next launch of the app."
        ],
        "tooltip_routes_only": [
            .it: "Nessuna mappa per questo dispositivo, ma accetta percorsi (corse da seguire).",
            .en: "No maps for this device, but it supports routes (courses to follow)."
        ],
        "tooltip_maps_info": [
            .it: "Mappe del dispositivo: presenti e offerte da Garmin",
            .en: "Device maps: installed and offered by Garmin"
        ],
        "maps_title": [ .it: "Mappe", .en: "Maps" ],
        "maps_installed": [ .it: "Mappe presenti sul dispositivo", .en: "Maps on the device" ],
        "maps_available": [ .it: "Aree offerte da Garmin", .en: "Areas offered by Garmin" ],
        "maps_none_installed": [ .it: "Nessuna mappa installata.", .en: "No maps installed." ],
        "maps_other_region": [ .it: "Altre", .en: "Other" ],
        "maps_update_tooltip": [ .it: "Installata %@, disponibile %@", .en: "Installed %@, available %@" ],
        "maps_updated_tooltip": [ .it: "La mappa è alla versione corrente (%@)", .en: "The map is at the current version (%@)" ],
        "maps_unavailable": [
            .it: "Garmin non ha restituito le informazioni sulle mappe. Controlla la connessione e ricollega il dispositivo.",
            .en: "Garmin did not return the map information. Check your connection and reconnect the device."
        ],
        "maps_disabled_hint": [
            .it: "Per vedere le mappe attiva «Controlla gli aggiornamenti di software e mappe del dispositivo» in Impostazioni → Avanzate: l'app interroga Garmin inviando l'XML del dispositivo (codici di sblocco compresi).",
            .en: "To see the maps, turn on “Check for device Software and Maps updates” in Settings → Advanced: the app queries Garmin sending the device XML (unlock codes included)."
        ],
        "maps_refresh_tooltip": [
            .it: "Ricontrolla le mappe sui server Garmin",
            .en: "Check the maps again on Garmin's servers"
        ],
        "alert_maps_recheck_title": [
            .it: "Controllare le nuove mappe?",
            .en: "Check for new maps?"
        ],
        "alert_maps_recheck_message": [
            .it: "Le mappe del dispositivo sono state controllate %@ giorni fa. Garmin le aggiorna circa ogni 3 mesi: vuoi controllare ora se ce ne sono di nuove?",
            .en: "The device maps were last checked %@ days ago. Garmin updates them about every 3 months: do you want to check now for new ones?"
        ],
        "button_check_now": [
            .it: "Controlla ora",
            .en: "Check Now"
        ],
        "button_later": [
            .it: "Più tardi",
            .en: "Later"
        ],
        "maps_stale_tooltip": [
            .it: "Ultimo controllo %@ giorni fa: ricontrolla per sapere se ci sono aggiornamenti.",
            .en: "Last checked %@ days ago: check again to see if there are updates."
        ],
        "alert_maps_changed_title": [
            .it: "Mappe cambiate sul dispositivo",
            .en: "Maps changed on the device"
        ],
        "alert_maps_changed_message": [
            .it: "Le mappe presenti sul dispositivo non corrispondono più all'ultimo controllo (ne è stata aggiunta, rimossa o aggiornata qualcuna). Vuoi controllare ora i server Garmin per aggiornare l'elenco?",
            .en: "The maps on the device no longer match the last check (some were added, removed or updated). Do you want to check Garmin's servers now to refresh the list?"
        ],
        "maps_checked_today": [
            .it: "Checked Today",
            .en: "Checked Today"
        ],
        "maps_checked_days": [
            .it: "Checked %@ days ago",
            .en: "Checked %@ days ago"
        ],
        "maps_footer_title": [
            .it: "Attenzione:",
            .en: "Attention:"
        ],
        "maps_footer": [
            .it: "Questa finestra serve solo a consultare le mappe. Per aggiungerle, aggiornarle o rimuoverle usa Garmin Express o le funzioni del dispositivo: Music Manager non gestisce le mappe.",
            .en: "This window is for viewing maps only. To add, update or remove them, use Garmin Express or the device's own features: Music Manager does not manage maps."
        ],
        "tooltip_software_updated": [
            .it: "Il software del dispositivo è aggiornato", .en: "The device software is up to date"
        ],
        "tooltip_reload_library": [
            .it: "Ricarica la libreria", .en: "Reload library"
        ],
        "search_placeholder": [
            .it: "Cerca", .en: "Search"
        ],
        "button_select": [
            .it: "Seleziona", .en: "Select"
        ],
        "button_send_to_watch": [
            .it: "Invia all'orologio", .en: "Send to watch"
        ],
        // Pulsante di conferma della finestra di controllo prima dell'invio (il titolo dice già «Invio al dispositivo»).
        "button_proceed": [.it: "Procedi", .en: "Proceed"],
        "button_to_device": [
            .it: "Al dispositivo", .en: "To Device"
        ],
        "button_send_to_playlist": [
            .it: "A Custom", .en: "To Custom"
        ],
        "button_clear_selection": [
            .it: "Pulisci selezione", .en: "Clear Selection"
        ],
        "no_playlists": [
            .it: "Nessuna Playlist Presente", .en: "No Playlists Found"
        ],
        "device_no_playlists": [
            .it: "Nessuna Playlist Trovata", .en: "No Playlist Found"
        ],
        "device_no_artists": [
            .it: "Nessun Artista Trovato", .en: "No Artists Found"
        ],
        "device_no_albums": [
            .it: "Nessun Album Trovato", .en: "No Albums Found"
        ],
        "device_no_songs": [
            .it: "Nessun Brano Trovato", .en: "No Songs Found"
        ],
        "no_results": [
            .it: "Nessun risultato", .en: "No results"
        ],
        "menu_find_similar": [
            .it: "Trova simili", .en: "Find Similar"
        ],
        "similar_title": [
            .it: "Simili a «%@»", .en: "Similar to “%@”"
        ],
        "similar_n_tracks": [
            .it: "%d brani", .en: "%d tracks"
        ],
        "similar_caption": [
            .it: "Punteggio da playlist in comune, genere, artista e album. Click per scegliere, doppio click per ascoltare.",
            .en: "Score from shared playlists, genre, artist and album. Click to choose, double-click to listen."
        ],
        "similar_caption_extra": [
            .it: "Punteggio da playlist in comune, genere, artista, album, anno e BPM (dove presenti). Click per scegliere, doppio click per ascoltare.",
            .en: "Score from shared playlists, genre, artist, album, year and BPM (where available). Click to choose, double-click to listen."
        ],
        "similar_never_played": [
            .it: "Mai ascoltato", .en: "Never played"
        ],
        "similar_played_n": [
            .it: "Ascoltato %d volte", .en: "Played %d times"
        ],
        "similar_footnote": [
            .it: "Come si calcola: ogni brano ottiene punti per le playlist in comune con quelli di partenza (fino a 6), lo stesso artista (4), il genere (fino a 3), lo stesso album (1) e, dove presenti, l'anno vicino (fino a 1,5) e i BPM vicini (fino a 2). La percentuale è il punteggio rispetto al massimo ottenibile; il colore della barra va dal verde (più affine dell'elenco) al rosso (meno affine). Al massimo 3 brani per artista (2 per quello di partenza). A pari punteggio vengono prima i brani meno ascoltati.",
            .en: "How it is calculated: each track earns points for playlists shared with the starting tracks (up to 6), same artist (4), genre (up to 3), same album (1) and, where available, close year (up to 1.5) and close BPM (up to 2). The percentage is the score relative to the maximum achievable; the bar colour goes from green (most similar in the list) to red (least similar). At most 3 tracks per artist (2 for the starting artist). Ties are broken in favour of the least played tracks."
        ],
        "similar_empty": [
            .it: "Nessun brano simile trovato.", .en: "No similar tracks found."
        ],
        "similar_selected_count": [
            .it: "%d scelti su %d", .en: "%d chosen of %d"
        ],
        "similar_send_custom": [
            .it: "Invia a Custom", .en: "Send to Custom"
        ],
        "similar_score_help": [
            .it: "Punteggio %@ su un massimo di %@", .en: "Score %@ out of a maximum of %@"
        ],
        "alert_tracks_only_title": [
            .it: "Inviare solo i brani?", .en: "Send only the tracks?"
        ],
        "alert_tracks_only_message": [
            .it: "Hai scelto solo alcuni brani di una playlist: verranno inviati al dispositivo i soli brani, la playlist da cui provengono non sarà creata.",
            .en: "You selected only some tracks of a playlist: only the tracks will be sent to the device, the playlist they come from will not be created."
        ],
        "alert_tracks_only_send": [
            .it: "Invia i brani", .en: "Send Tracks"
        ],
        "alert_partial_playlist_title": [
            .it: "Playlist scelta solo in parte", .en: "Playlist only partly selected"
        ],
        "alert_partial_playlist_message": [
            .it: "Una playlist scelta solo in parte (o insieme ad altri brani) non può essere inviata al dispositivo come playlist. Puoi aggiungere i brani scelti alla Custom Playlist, rivederli e inviarli da lì.",
            .en: "A playlist that is only partly selected (or mixed with other tracks) can't be sent to the device as a playlist. You can add the selected tracks to the Custom Playlist, review them and send them from there."
        ],
        "alert_partial_playlist_custom": [
            .it: "Aggiungi alla Custom Playlist", .en: "Add to Custom Playlist"
        ],
        "alert_empty_library_title": [
            .it: "La libreria di Music è vuota", .en: "The Music library is empty"
        ],
        "alert_empty_library_message": [
            .it: "Aggiungi dei brani in Music prima di usare Music Manager.",
            .en: "Add some tracks in Music before using Music Manager."
        ],
        "empty_apple_music": [
            .it: "Nessun elemento.\nSe la libreria è vuota, controlla di aver concesso l'accesso a Musica.", .en: "No items.\nIf the library is empty, check that you've granted access to Music."
        ],
        "empty_device_music": [
            .it: "Nessun brano trovato nella cartella Music del dispositivo.", .en: "No tracks found in the device's Music folder."
        ],
        "n_playlists_selected": [
            .it: "%d playlist", .en: "%d playlists"
        ],
        "n_playlists_selected_time": [
            .it: "%1$d playlist per un totale di %2$@", .en: "%1$d playlists for a total of %2$@"
        ],
        "n_playlist_selected_one": [.it: "1 playlist", .en: "1 playlist"],
        "n_playlist_selected_time_one": [.it: "1 playlist per un totale di %@", .en: "1 playlist for a total of %@"],
        "n_songs_selected": [
            .it: "%d brani", .en: "%d songs"
        ],
        "n_songs_selected_time": [
            .it: "%1$d brani per un totale di %2$@", .en: "%1$d songs for a total of %2$@"
        ],
        "n_song_selected_one": [.it: "1 brano", .en: "1 song"],
        "n_song_selected_time_one": [.it: "1 brano per un totale di %@", .en: "1 song for a total of %@"],
        "n_artists_selected": [.it: "%d artisti", .en: "%d artists"],
        "n_artist_selected_one": [.it: "1 artista", .en: "1 artist"],
        "n_albums_selected": [.it: "%d album", .en: "%d albums"],
        "n_album_selected_one": [.it: "1 album", .en: "1 album"],
        "n_selected_time": [
            .it: "%1$d selezionati, %2$@", .en: "%1$d selected, %2$@"
        ],
        "n_without_cover": [
            .it: "%d senza copertina", .en: "%d without cover"
        ],
        "button_ok": [
            .it: "OK", .en: "OK"
        ],
        "alert_drop_audio_title": [
            .it: "File non caricabili", .en: "Files that cannot be loaded"
        ],
        "alert_drop_audio_unsupported": [
            .it: "Questi file hanno un formato non accettato dal dispositivo e non possono essere caricati:\n\n%@\n\nFormati accettati: %@.",
            .en: "These files are in a format the device does not accept and cannot be loaded:\n\n%@\n\nAccepted formats: %@."
        ],
        "alert_drop_audio_none": [
            .it: "Nessuno dei file trascinati è un file audio.", .en: "None of the dropped files is an audio file."
        ],
        "alert_drop_audio_ignored": [
            .it: "File non audio ignorati: %d.", .en: "Non-audio files ignored: %d."
        ],
        "status_drop_no_device": [
            .it: "Per importare file audio serve un dispositivo collegato.", .en: "A connected device is required to import audio files."
        ],
        "drop_field_title": [.it: "titolo", .en: "title"],
        "drop_field_artist": [.it: "artista", .en: "artist"],
        "drop_field_album": [.it: "album", .en: "album"],
        "drop_field_album_artist": [.it: "artista album", .en: "album artist"],
        "drop_field_composer": [.it: "compositore", .en: "composer"],
        "drop_field_genre": [.it: "genere", .en: "genre"],
        "genre_all": [.it: "Tutti i generi", .en: "All Genres"],
        "genre_none": [.it: "Senza genere", .en: "No Genre"],
        "tooltip_genre_filter": [.it: "Mostra solo i brani di un genere musicale (Brani, Album e Artisti; non le Playlist).", .en: "Show only the tracks of one genre (Songs, Albums and Artists; not Playlists)."],
        "drop_field_year": [.it: "anno", .en: "year"],
        "drop_field_track": [.it: "traccia", .en: "track"],
        "drop_field_disc": [.it: "numero disco", .en: "disc number"],
        "drop_of": [.it: "di", .en: "of"],
        "drop_compilation": [
            .it: "L'album è una compilation di brani di vari artisti", .en: "Album is a compilation of songs by various artists"
        ],
        "drop_apply_album": [
            .it: "Usa questa copertina per altri %d file dell'album", .en: "Use this cover for %d more files of this album"
        ],
        "drop_field_file": [.it: "file", .en: "file"],
        "drop_no_cover": [.it: "Nessuna copertina", .en: "No cover"],
        "drop_in_library": [
            .it: "Già in Music: si userà il file di Music — %@", .en: "Already in Music: the Music file will be used — %@"
        ],
        "drop_not_in_library": [
            .it: "Non risulta nella libreria Music", .en: "Not found in the Music library"
        ],
        "alert_drop_send_title": [
            .it: "Invio al dispositivo", .en: "Send to device"
        ],
        "alert_drop_send_message": [
            .it: "File da trasferire: %d. Già in Music (si usano quelli della libreria, nessuna copia nuova): %d. Da aggiungere alla libreria di Music: %d.\n\nTutti i file entreranno nella playlist «Direct Copy» sul dispositivo; i brani già presenti sul dispositivo non vengono ricopiati. Si aprirà il riepilogo dell'invio.",
            .en: "Files to transfer: %d. Already in Music (the library versions are used, no new copy): %d. To be added to the Music library: %d.\n\nAll files will be listed in the “Direct Copy” playlist on the device; songs already on the device are not copied again. The send summary will open."
        ],
        "alert_drop_send_message_ask": [
            .it: "File da trasferire: %d. Già in Music (si usano quelli della libreria, nessuna copia nuova): %d. Non presenti in Music: %d.\n\nTutti i file entreranno nella playlist «Direct Copy» sul dispositivo; i brani già presenti sul dispositivo non vengono ricopiati. Si aprirà il riepilogo dell'invio.",
            .en: "Files to transfer: %d. Already in Music (the library versions are used, no new copy): %d. Not in Music: %d.\n\nAll files will be listed in the “Direct Copy” playlist on the device; songs already on the device are not copied again. The send summary will open."
        ],
        "alert_drop_send_blocked": [
            .it: "%d file sono già in Music ma non trasferibili da lì (solo in cloud o protetti): si userà il file trascinato, senza aggiungerlo a Music.",
            .en: "%d files are already in Music but cannot be transferred from there (cloud-only or protected): the dropped file will be used, without adding it to Music."
        ],
        "drop_in_cloud": [
            .it: "Già in Music ma non trasferibile da lì (cloud/protetto): si userà questo file",
            .en: "Already in Music but not transferable from there (cloud/protected): this file will be used"
        ],
        "status_drop_already_listed": [
            .it: "Tutti i file trascinati sono già nella playlist «Direct Copy» del dispositivo: niente da aggiungere.",
            .en: "All dropped files are already in the “Direct Copy” playlist on the device: nothing to add."
        ],
        "drop_continue": [.it: "Invia", .en: "Send"],
        "status_drop_adding": [
            .it: "Aggiunta a Music %d di %d: %@", .en: "Adding to Music %d of %d: %@"
        ],
        "status_drop_not_added": [
            .it: "File non aggiunti a Music: %d (%@)", .en: "Files not added to Music: %d (%@)"
        ],
        "drop_progress": [.it: "File %d di %d", .en: "File %d of %d"],
        "n_selected": [
            .it: "%d selezionati", .en: "%d selected"
        ],

        // Pannello dispositivo
        "device_default_name": [
            .it: "Dispositivo Garmin", .en: "Garmin Device"
        ],
        "button_connect": [
            .it: "Connetti", .en: "Connect"
        ],
        "button_disconnect": [
            .it: "Disconnetti", .en: "Disconnect"
        ],
        "label_storage": [
            .it: "Memoria", .en: "Storage"
        ],
        "storage_free_of_total": [
            .it: "%1$@ liberi di %2$@", .en: "%1$@ free of %2$@"
        ],
        "search_in_music": [
            .it: "Cerca in Music", .en: "Search in Music"
        ],
        "search_in_device": [
            .it: "Cerca nel dispositivo", .en: "Search on the device"
        ],
        "search_switch_panel": [
            .it: "Cambia il pannello in cui cercare", .en: "Switch the panel to search in"
        ],
        "tooltip_eject_disk": [
            .it: "Espelli in sicurezza il disco del dispositivo", .en: "Safely eject the device's disk"
        ],
        "tooltip_eject_unavailable": [
            .it: "Disponibile solo con un disco rilevato e non connesso", .en: "Only available for a detected disk that is not connected"
        ],
        "tooltip_connect_device": [
            .it: "Connetti il dispositivo e leggi la sua musica", .en: "Connect the device and read its music"
        ],
        "tooltip_disconnect_device": [
            .it: "Disconnetti il dispositivo (resta collegato al Mac)", .en: "Disconnect the device (it stays plugged in)"
        ],
        "tooltip_storage_menu": [
            .it: "Memoria del dispositivo da gestire (interna o scheda SD)", .en: "Device storage to manage (internal or SD card)"
        ],
        "tooltip_search_clear": [
            .it: "Azzera la ricerca", .en: "Clear the search"
        ],
        "tooltip_notices_unread": [
            .it: "Notifiche (%d da leggere)", .en: "Notifications (%d unread)"
        ],
        "tooltip_refresh_all": [
            .it: "Aggiorna la libreria e il dispositivo", .en: "Refresh the library and the device"
        ],
        "tooltip_refresh_device": [
            .it: "Rilegge il dispositivo", .en: "Re-read the device"
        ],
        "button_delete": [
            .it: "Elimina", .en: "Delete"
        ],
        "button_eject": [
            .it: "Espelli", .en: "Eject"
        ],
        "volume_space": [
            .it: "%@ · %@ liberi su %@", .en: "%@ · %@ free of %@"
        ],
        "volume_info_note": [
            .it: "Rilevato come disco esterno (archiviazione di massa). Per ora solo informazioni: il trasferimento di musica su questi dispositivi non è ancora disponibile.",
            .en: "Detected as an external disk (mass storage). Information only for now: transferring music to these devices is not available yet."
        ],
        "volume_info_note_music": [
            .it: "Rilevato come disco esterno (archiviazione di massa). Sperimentale: premi Connetti per gestire la musica su questo volume (lettura e scrittura).",
            .en: "Detected as an external disk (mass storage). Experimental: press Connect to manage music on this volume (read and write)."
        ],
        "status_volume_ejecting": [
            .it: "Espulsione di %@ in corso…", .en: "Ejecting %@…"
        ],
        "status_volume_ejected": [
            .it: "%@ espulso: puoi scollegare il cavo.", .en: "%@ ejected: you can unplug the cable."
        ],
        "status_library_mounting": [
            .it: "Libreria %@: montaggio del volume di rete in corso…", .en: "Library %@: mounting the network volume…"
        ],
        "status_library_mounted": [
            .it: "Libreria %@: volume di rete montato.", .en: "Library %@: network volume mounted."
        ],
        "status_library_mount_failed": [
            .it: "Non è stato possibile connettersi a %@ dopo 3 tentativi (server spento, rete diversa o credenziali richieste).",
            .en: "Could not connect to %@ after 3 attempts (server off, different network or credentials needed)."
        ],
        "status_library_mount_offline": [
            .it: "Libreria %@: nessuna connessione di rete, volume non montato.", .en: "Library %@: no network connection, volume not mounted."
        ],
        "status_volume_eject_failed": [
            .it: "Impossibile espellere %@: %@", .en: "Could not eject %@: %@"
        ],
        "placeholder_connect_device": [
            .it: "Collega il dispositivo via USB\nSbloccalo e premi «Connetti».", .en: "Connect the device via USB\nUnlock it and press “Connect”."
        ],
        "alert_delete_title": [
            .it: "Eliminare dall'orologio gli elementi selezionati?", .en: "Delete the selected items from the watch?"
        ],
        "alert_delete_playlists_message": [
            .it: "Le playlist selezionate vengono eliminate insieme ai loro brani: verranno eliminati %1$d brani su %2$d. I restanti %3$d fanno parte di altre playlist del dispositivo e non verranno rimossi. L'operazione non si può annullare.",
            .en: "The selected playlists will be deleted together with their songs: %1$d of %2$d songs will be deleted. The remaining %3$d are part of other playlists on the watch and will not be removed. This action can't be undone."
        ],
        "alert_delete_playlists_message_all": [
            .it: "Le playlist selezionate vengono eliminate insieme ai loro %1$d brani. L'operazione non si può annullare.",
            .en: "The selected playlists will be deleted together with their %1$d songs. This action can't be undone."
        ],
        "status_deleted_tracks_kept": [
            .it: "Eliminati %1$d brani; %2$d tenuti perché presenti in altre playlist",
            .en: "Deleted %1$d tracks; %2$d kept because they are in other playlists"
        ],
        "delete_progress_playlist": [
            .it: "Eliminazione del file playlist %1$d di %2$d", .en: "Deleting playlist file %1$d of %2$d"
        ],
        "delete_sheet_tracks_title": [ .it: "Brani da eliminare (%d)", .en: "Songs to delete (%d)" ],
        "delete_sheet_playlists_title": [ .it: "Playlist interessate (%d)", .en: "Affected playlists (%d)" ],
        "delete_sheet_no_playlists": [ .it: "Nessuna playlist del dispositivo contiene questi brani.", .en: "No playlist on the device contains these songs." ],
        "delete_sheet_playlist_update": [ .it: "%1$d → %2$d brani", .en: "%1$d → %2$d songs" ],
        "delete_sheet_playlist_empty": [ .it: "resterà vuota: verrà eliminata", .en: "will be left empty: it will be deleted" ],
        "delete_sheet_what_title": [ .it: "Cosa succede se confermi", .en: "What happens if you confirm" ],
        "delete_sheet_step_tracks": [ .it: "I brani selezionati (%d) vengono eliminati dall'orologio.", .en: "The selected songs (%d) are deleted from the watch." ],
        "delete_sheet_step_folders": [ .it: "Le cartelle di artista e album rimaste vuote vengono rimosse.", .en: "Artist and album folders left empty are removed." ],
        "delete_sheet_step_playlists": [ .it: "Le playlist elencate vengono riscritte senza questi brani.", .en: "The listed playlists are rewritten without these songs." ],
        "delete_sheet_step_emptied": [ .it: "Le playlist che restano vuote (%d) vengono eliminate completamente dal dispositivo.", .en: "Playlists left empty (%d) are completely deleted from the device." ],
        "button_delete_update_playlists": [ .it: "Elimina e aggiorna le playlist", .en: "Delete and update playlists" ],
        "delete_progress_update_playlists": [
            .it: "Aggiornamento playlist %1$d di %2$d", .en: "Updating playlist %1$d of %2$d"
        ],
        "status_deleted_playlists_updated": [
            .it: "%1$d playlist aggiornate, %2$d eliminate perché vuote",
            .en: "%1$d playlists updated, %2$d deleted because empty"
        ],
        "status_deleted_playlists_failed": [
            .it: "%d playlist non aggiornate", .en: "%d playlists not updated"
        ],
        "alert_delete_message": [
            .it: "L'operazione non si può annullare.", .en: "This action can't be undone."
        ],
        "alert_device_update_title": [ .it: "Aggiornamento disponibile", .en: "Update available" ],
        "alert_device_update_footer": [
            .it: "Per installarlo usa Garmin Express: questa app non installa aggiornamenti.",
            .en: "Install it with Garmin Express: this app does not install updates."
        ],
        "update_sheet_hint": [
            .it: "Stato del software dei dispositivi registrati. Passa sul pallino «Upgrade Available» per vedere le novità.",
            .en: "Software status of your registered devices. Hover the “Upgrade Available” badge to see what's new."
        ],
        "button_ignore_update": [ .it: "Ignora questa versione", .en: "Ignore this version" ],
        "update_data_read_on": [ .it: "(dati del dispositivo letti il %@)", .en: "(device data read on %@)" ],
        "button_cancel": [
            .it: "Annulla", .en: "Cancel"
        ],

        // Pannello Impostazioni
        "tooltip_player_shuffle": [
            .it: "Riproduzione casuale", .en: "Shuffle"
        ],
        "tooltip_player_repeat": [
            .it: "Ripeti tutti i brani", .en: "Repeat all"
        ],
        "tooltip_player_queue": [
            .it: "Mostra i brani della playlist", .en: "Show playlist tracks"
        ],
        "queue_played": [
            .it: "Già riprodotti", .en: "Played"
        ],
        "queue_now": [
            .it: "In riproduzione", .en: "Now playing"
        ],
        "queue_next": [
            .it: "Da riprodurre", .en: "Up next"
        ],
        "tooltip_player_volume": [
            .it: "Volume", .en: "Volume"
        ],
        "tooltip_player_output": [
            .it: "Uscita audio: %@", .en: "Audio output: %@"
        ],
        "tooltip_player_airplay": [
            .it: "Uscita audio / AirPlay", .en: "Audio output / AirPlay"
        ],
        "settings_reset_all": [
            .it: "Ripristina tutte le impostazioni", .en: "Reset all settings"
        ],
        "alert_reset_settings_title": [
            .it: "Ripristinare le impostazioni?", .en: "Reset settings?"
        ],
        "alert_reset_settings_message": [
            .it: "Tutte le impostazioni (generali, Aspetto, Artwork) tornano ai valori predefiniti; la lingua segue quella del sistema. Le librerie condivise e la cache delle copertine non vengono toccate.",
            .en: "All settings (general, Appearance, Artwork) go back to their defaults; the language follows the system. Shared libraries and the artwork cache are not affected."
        ],
        "button_reset_settings": [
            .it: "Ripristina", .en: "Reset"
        ],
        "menu_reload_library": [
            .it: "Ricarica libreria", .en: "Reload Library"
        ],
        "textmenu_cut": [
            .it: "Taglia", .en: "Cut"
        ],
        "textmenu_copy": [
            .it: "Copia", .en: "Copy"
        ],
        "textmenu_paste": [
            .it: "Incolla", .en: "Paste"
        ],
        "textmenu_select_all": [
            .it: "Seleziona tutto", .en: "Select All"
        ],
        "menu_save_playlist_file": [
            .it: "Salva su file…", .en: "Save to File…"
        ],
        "button_send": [
            .it: "Invia", .en: "Send"
        ],
        "disc_n_of_m": [
            .it: "Disco %d di %d", .en: "Disc %d of %d"
        ],
        "button_save_to_file": [
            .it: "Salva su File", .en: "Save to File"
        ],
        "button_delete_all": [
            .it: "Cancella Tutto", .en: "Delete All"
        ],
        "button_load_short": [
            .it: "Load", .en: "Load"
        ],
        "button_save_short": [
            .it: "Save", .en: "Save"
        ],
        "menu_load_playlist_file": [
            .it: "Carica da file…", .en: "Load from File…"
        ],
        "button_replace": [
            .it: "Sostituisci", .en: "Replace"
        ],
        "alert_file_overwrite_title": [
            .it: "File già esistente", .en: "File already exists"
        ],
        "status_playlist_completed_by_songs": [
            .it: "Con questi brani la playlist «%@» è completa: verrà inviata anche come playlist (con il suo file .m3u8).",
            .en: "With these songs the playlist “%@” is complete: it will also be sent as a playlist (with its .m3u8 file)."
        ],
        "alert_file_overwrite_message": [
            .it: "Esiste già un file playlist chiamato «%@» nella cartella Custom Lib. Vuoi sostituirlo?",
            .en: "A playlist file named “%@” already exists in the Custom Lib folder. Do you want to replace it?"
        ],
        "status_playlist_saved_file": [
            .it: "Playlist «%@» salvata su file (%d brani).", .en: "Playlist “%@” saved to file (%d tracks)."
        ],
        "status_playlist_saved_file_skipped": [
            .it: "%d brani senza file non sono stati inclusi.", .en: "%d tracks without a file were not included."
        ],
        "status_loading_playlist_file": [
            .it: "Caricamento della playlist «%@»…", .en: "Loading playlist “%@”…"
        ],
        "status_playlist_loaded_file": [
            .it: "Playlist «%@» caricata da file (%d brani).", .en: "Playlist “%@” loaded from file (%d tracks)."
        ],
        "status_playlist_loaded_file_partial": [
            .it: "Playlist «%@» caricata: %d brani su %d (gli altri non sono raggiungibili: volume non montato o file spostati).",
            .en: "Playlist “%@” loaded: %d of %d tracks (the others cannot be reached: volume not mounted or files moved)."
        ],
        "status_playlist_file_empty": [
            .it: "Nessun brano raggiungibile nel file «%@».", .en: "No reachable tracks in file “%@”."
        ],
        "alert_quit_playlist_title": [
            .it: "Salvare la Custom Playlist?", .en: "Save the Custom Playlist?"
        ],
        "alert_quit_playlist_message": [
            .it: "La Custom Playlist contiene dei brani e non è stata salvata. Puoi salvarla su file (cartella Custom Lib) per ricaricarla in seguito, oppure chiudere senza salvarla.",
            .en: "The Custom Playlist contains tracks and has not been saved. You can save it to a file (Custom Lib folder) to load it again later, or quit without saving."
        ],
        "button_quit": [ .it: "Esci", .en: "Quit" ],
        "alert_clear_playlist_title": [
            .it: "Svuotare la playlist?", .en: "Clear the playlist?"
        ],
        "alert_clear_playlist_message": [
            .it: "Tutti i brani verranno tolti dalla Custom Playlist. Puoi prima salvarla su file per ricaricarla in seguito.",
            .en: "All tracks will be removed from the Custom Playlist. You can save it to a file first and load it again later."
        ],
        "tooltip_load_playlist_file": [
            .it: "Carica una playlist salvata in precedenza (file M3U8 nella cartella Musica/MusicManager/Custom Lib).",
            .en: "Load a previously saved playlist (M3U8 file in the Music/MusicManager/Custom Lib folder)."
        ],
        "tooltip_save_playlist_file": [
            .it: "Salva la playlist su file (M3U8) nella cartella Musica/MusicManager/Custom Lib.",
            .en: "Save the playlist to a file (M3U8) in the Music/MusicManager/Custom Lib folder."
        ],
        "tooltip_save_to_music": [
            .it: "Salva la playlist in Music, nella cartella «Music Manager» (le tue altre playlist non vengono toccate).",
            .en: "Save the playlist to Music, inside the “Music Manager” folder (your other playlists are not touched)."
        ],
        "tooltip_clear_selection": [
            .it: "Deseleziona tutti i brani e le playlist", .en: "Deselect all tracks and playlists"
        ],
        "tooltip_send_to_playlist": [
            .it: "Aggiungi la selezione alla Custom Playlist", .en: "Add the selection to the Custom Playlist"
        ],
        "tooltip_send_to_device": [
            .it: "Invia la selezione al dispositivo", .en: "Send the selection to the device"
        ],
        "tooltip_delete_selected": [
            .it: "Elimina dal dispositivo i brani o le playlist selezionati", .en: "Delete the selected tracks or playlists from the device"
        ],
        "tooltip_delete_all_music": [
            .it: "Elimina tutta la musica dal dispositivo", .en: "Delete all music from the device"
        ],
        "tooltip_clear_playlist": [
            .it: "Svuota la playlist: prima chiede se confermare, salvarla su file oppure annullare.",
            .en: "Clear the playlist: first asks whether to confirm, save it to a file or cancel."
        ],
        "n_tracks_time": [
            .it: "%1$d brani, %2$@", .en: "%1$d tracks, %2$@"
        ],
        "duration_hour_one": [
            .it: "1 ora", .en: "1 hour"
        ],
        "duration_hours": [
            .it: "%d ore", .en: "%d hours"
        ],
        "duration_minute_one": [
            .it: "1 minuto", .en: "1 minute"
        ],
        "duration_minutes": [
            .it: "%d minuti", .en: "%d minutes"
        ],
        "duration_hours_minutes": [
            .it: "%1$@ e %2$@", .en: "%1$@, %2$@"
        ],
        "alert_file_load_title": [
            .it: "Caricare la playlist salvata", .en: "Load the saved playlist"
        ],
        "alert_file_load_message": [
            .it: "La Custom Playlist contiene già dei brani. Come vuoi caricare «%1$@»? In ogni caso la playlist prenderà il nome «%1$@». Se alcuni brani sono già presenti, potrai scegliere quali aggiungere comunque.\n\n• Sovrascrivi: i brani attuali vengono sostituiti da quelli salvati.\n• Brani attuali in coda: prima la playlist salvata, poi i brani che hai ora.\n• Playlist salvata in coda: prima i brani che hai ora, poi la playlist salvata.",
            .en: "The Custom Playlist already contains tracks. How do you want to load “%1$@”? Either way the playlist will be named “%1$@”. If some tracks are already there, you can choose which ones to add anyway.\n\n• Replace: the current tracks are replaced by the saved ones.\n• Current tracks last: the saved playlist first, then the tracks you have now.\n• Saved playlist last: the tracks you have now first, then the saved playlist."
        ],
        "button_load_replace": [
            .it: "Sovrascrivi", .en: "Replace"
        ],
        "button_load_current_after": [
            .it: "Brani attuali in coda", .en: "Current tracks last"
        ],
        "button_load_saved_after": [
            .it: "Playlist salvata in coda", .en: "Saved playlist last"
        ],
        "settings_appearance": [
            .it: "Aspetto", .en: "Appearance"
        ],
        "settings_appearance_light": [
            .it: "Chiaro", .en: "Light"
        ],
        "settings_appearance_dark": [
            .it: "Scuro", .en: "Dark"
        ],
        "settings_appearance_system": [
            .it: "Sistema", .en: "System"
        ],
        "settings_appearance_hint": [
            .it: "Sistema segue l'impostazione Aspetto di macOS (Impostazioni di Sistema › Aspetto).",
            .en: "System follows the macOS Appearance setting (System Settings › Appearance)."
        ],
        "settings_language": [
            .it: "Lingua", .en: "Language"
        ],
        "settings_default_category": [
            .it: "Elenco iniziale", .en: "Starting list"
        ],
        "settings_default_category_hint": [
            .it: "Scegli quale elenco visualizzare per primo all'apertura dell'app, sia per Music sia per il dispositivo Garmin.",
            .en: "Choose which list is shown first when the app opens, for both Music and the Garmin Device."
        ],
        "artwork_on_device": [
            .it: "Già inviato al dispositivo", .en: "Already sent to the device"
        ],
        "artwork_origin_gmm": [
            .it: "Copertina memorizzata nella cache di Music Manager", .en: "Cover stored in the Music Manager cache"
        ],
        "settings_window_opacity": [
            .it: "Opacità finestra", .en: "Window opacity"
        ],
        "settings_window_opacity_hint": [
            .it: "Più alta = sfondo più pieno e meno trasparente.",
            .en: "Higher = fuller, less transparent background."
        ],
        "color_blue": [ .it: "Blu", .en: "Blue" ],
        "color_purple": [ .it: "Viola", .en: "Purple" ],
        "color_pink": [ .it: "Rosa", .en: "Pink" ],
        "color_red": [ .it: "Rosso", .en: "Red" ],
        "color_orange": [ .it: "Arancione", .en: "Orange" ],
        "color_yellow": [ .it: "Giallo", .en: "Yellow" ],
        "color_green": [ .it: "Verde", .en: "Green" ],
        "settings_highlight_tone_help": [ .it: "Intensità del colore di selezione: dalla saturazione più tenue alla più viva", .en: "Selection colour intensity: from muted to vivid saturation" ],
        "settings_highlight_primary": [ .it: "Colore di selezione principale: %@", .en: "Primary selected color: %@" ],
        "device_connected_help": [ .it: "Collegato", .en: "Connected" ],
        "color_graphite": [ .it: "Grafite", .en: "Graphite" ],
        "settings_highlight_color": [
            .it: "Colore di selezione", .en: "Selection color"
        ],
        "settings_highlight_color_hint": [
            .it: "Colore di sfondo delle righe selezionate nelle schede Playlist, Artisti, Album e Brani di Music.",
            .en: "Background color for selected rows on Music's Playlists, Artists, Albums and Songs tabs."
        ],
        "settings_lookup_artwork": [
            .it: "Abilita Fix Artwork (copertine online)", .en: "Enable Fix Artwork (online artwork)"
        ],
        "settings_lookup_artwork_hint": [
            .it: "Aggiunge «Fix Artwork» al menu del click destro sui brani: cerca una copertina online, te la mostra accanto all'originale e la usa solo se la confermi. Funziona su file AAC/M4A; viene scritta in una copia al momento dell'invio all'orologio, mai nel file originale in Music.",
            .en: "Adds “Fix Artwork” to the right-click menu on tracks: looks up a cover online, shows it next to the original, and uses it only if you confirm. Works on AAC/M4A files; it's written to a copy when sending to the watch, never to the original file in Music."
        ],
        "alert_enable_artwork_lookup_title": [
            .it: "Attivare Fix Artwork?", .en: "Turn on Fix Artwork?"
        ],
        "alert_enable_artwork_lookup_message": [
            .it: "Quando scegli «Fix Artwork», l'app invierà titolo e artista dei brani selezionati a un servizio online (iTunes Search) per cercare la copertina. Nulla viene modificato senza la tua conferma, e le copertine confermate vengono scritte solo in copie temporanee create al momento dell'invio, mai nei tuoi file originali.",
            .en: "When you choose “Fix Artwork”, the app will send the title and artist of the selected tracks to an online service (iTunes Search) to look up the cover. Nothing is changed without your confirmation, and confirmed covers are only written to temporary copies made at the time of sending, never to your original files."
        ],

        // Menu contestuale (click destro) e finestra Fix Artwork
        "menu_send_to_custom": [
            .it: "Invia a Custom", .en: "Send to Custom"
        ],
        "menu_send_n_to_custom": [
            .it: "Invia %d a Custom", .en: "Send %d to Custom"
        ],
        "menu_send_n_to_device": [
            .it: "Invia %d al dispositivo", .en: "Send %d to Device"
        ],
        "menu_send_to_device": [
            .it: "Invia al dispositivo", .en: "Send to Device"
        ],
        "menu_send_one_to_custom": [
            .it: "Invia «%@» a Custom", .en: "Send “%@” to Custom"
        ],
        "menu_send_one_to_device": [
            .it: "Invia «%@» al dispositivo", .en: "Send “%@” to Device"
        ],
        "tooltip_player_mute": [
            .it: "Muto / Riattiva audio", .en: "Mute / Unmute"
        ],
        "subtitle_transferable": [
            .it: " (%d inviabili)", .en: " (%d transferable)"
        ],
        "menu_n_songs": [
            .it: "%d brani", .en: "%d songs"
        ],
        "menu_one_song": [
            .it: "1 brano", .en: "1 song"
        ],
        "menu_send_group_to_custom": [
            .it: "Invia «%1$@» [%2$@] a Custom", .en: "Send “%1$@” [%2$@] to Custom"
        ],
        "menu_send_group_to_device": [
            .it: "Invia «%1$@» [%2$@] al dispositivo", .en: "Send “%1$@” [%2$@] to Device"
        ],
        "menu_artwork_online_fix": [
            .it: "Fix Artwork online…", .en: "Artwork Online Fix…"
        ],
        "menu_artwork_reload_apple": [
            .it: "Ricarica Artwork da Music", .en: "Artwork reload from Music"
        ],
        "menu_only_without_cover": [
            .it: "Mostra solo brani senza copertina", .en: "Show Only Songs without cover"
        ],
        "fix_artwork_original": [
            .it: "Artwork originale", .en: "Original artwork"
        ],
        "fix_artwork_online": [
            .it: "Artwork online", .en: "Online artwork"
        ],
        "status_refreshing_device": [
            .it: "Aggiornamento dell'elenco del dispositivo…", .en: "Refreshing the device listing…"
        ],
        "status_device_not_responding": [
            .it: "Il dispositivo non risponde: scollegalo e ricollegalo, poi riconnetti.",
            .en: "The device is not responding: unplug and reconnect it, then connect again."
        ],
        "status_refresh_pending": [
            .it: "Il dispositivo è ancora occupato: premi Aggiorna tra qualche istante per vedere l'elenco.",
            .en: "The device is still busy: press Refresh in a moment to see the listing."
        ],
        "status_preparing_files": [
            .it: "Preparazione dei file in locale…", .en: "Preparing files locally…"
        ],
        "status_preparing_file_n": [
            .it: "Preparazione %1$d di %2$d: %3$@", .en: "Preparing %1$d of %2$d: %3$@"
        ],
        "status_export_ready": [
            .it: "File pronti: %1$d brani, %2$d con artwork modificata.",
            .en: "Files ready: %1$d tracks, %2$d with updated artwork."
        ],
        "status_export_cancelled": [
            .it: "Invio al dispositivo annullato.", .en: "Send to device cancelled."
        ],
        "status_export_nothing_prepared": [
            .it: "Nessun file è stato preparato.", .en: "No file could be prepared."
        ],
        "export_dialog_title": [
            .it: "Invio al dispositivo", .en: "Send to device"
        ],
        "export_dialog_summary": [
            .it: "%d brani pronti. Copertine per origine:", .en: "%d tracks ready. Artwork by source:"
        ],
        "export_playlist_label": [
            .it: "Playlist: %@", .en: "Playlist: %@"
        ],
        "export_artwork_file": [
            .it: "File Artwork", .en: "File Artwork"
        ],
        "export_artwork_apple": [
            .it: "Music Artwork", .en: "Music Artwork"
        ],
        "export_artwork_online": [
            .it: "Online Artwork", .en: "Online Artwork"
        ],
        "export_artwork_garmin_cache": [
            .it: "App Cache", .en: "App Cache"
        ],
        "export_artwork_apple_help": [
            .it: "Copertina che arriva direttamente da Apple Music.",
            .en: "Cover that comes directly from Apple Music."
        ],
        "export_artwork_online_help": [
            .it: "Copertina appena scelta con la ricerca online (Fix Artwork) per questo invio.",
            .en: "Cover just chosen with the online search (Fix Artwork) for this send."
        ],
        "export_artwork_cache_help": [
            .it: "Copertina già confermata in precedenza e memorizzata dall'app (cache dell'app).",
            .en: "Cover confirmed earlier and stored by the app (app cache)."
        ],
        "export_artwork_file_help": [
            .it: "Copertina già memorizzata nei metadati del file.",
            .en: "Cover already stored in the file's metadata."
        ],
        "export_artwork_none_help": [
            .it: "Nessuna copertina disponibile: il brano viene inviato senza.",
            .en: "No cover available: the song is sent without one."
        ],
        "export_artwork_none": [
            .it: "No Cover", .en: "No Cover"
        ],
        "settings_artwork_cache_size": [
            .it: "Spazio occupato dalla cache delle copertine: %@", .en: "Space used by the artwork cache: %@"
        ],
        "status_device_unplugged": [
            .it: "Il dispositivo è stato scollegato.", .en: "The device was unplugged."
        ],
        "fix_artwork_still_present": [
            .it: "L'artwork è già presente nella Libreria", .en: "Artwork is still present in the Library"
        ],
        "fix_artwork_none": [
            .it: "Nessuna copertina", .en: "No artwork"
        ],
        "fix_artwork_searching": [
            .it: "Ricerca in corso…", .en: "Searching…"
        ],
        "fix_artwork_not_found": [
            .it: "Nessuna copertina trovata online", .en: "Nothing found online"
        ],
        "fix_artwork_save_failed": [
            .it: "Impossibile salvare la copertina.", .en: "Couldn't save the artwork."
        ],
        "fix_artwork_progress": [
            .it: "Brano %1$d di %2$d", .en: "Song %1$d of %2$d"
        ],
        "button_previous": [
            .it: "Precedente", .en: "Previous"
        ],
        "button_next": [
            .it: "Successivo", .en: "Next"
        ],
        "button_skip_all": [
            .it: "Salta tutti", .en: "Skip All"
        ],
        "button_confirm_clear": [
            .it: "Conferma svuotamento", .en: "Confirm Clear"
        ],
        // Pannello About
        "about_window_title": [
            .it: "Informazioni", .en: "About"
        ],
        "about_menu_item": [
            .it: "Informazioni su %@", .en: "About %@"
        ],
        "about_version": [
            .it: "Versione %1$@ (%2$@)", .en: "Version %1$@ (%2$@)"
        ],
        "about_copyright": [
            .it: "© 2026 Music Manager. Tutti i diritti riservati. Garmin è un marchio di Garmin Ltd.; Apple e Apple Music sono marchi di Apple Inc., registrati negli Stati Uniti e in altri paesi.",
            .en: "© 2026 Music Manager. All rights reserved. Garmin is a trademark of Garmin Ltd.; Apple and Apple Music are trademarks of Apple Inc., registered in the United States and other countries."
        ],
        "help_save_device_tree": [
            .it: "Salva albero del dispositivo (diagnostica)", .en: "Save Device File Tree (Diagnostics)"
        ],
        "status_device_tree_saving": [ .it: "Lettura dell'albero del dispositivo…", .en: "Reading the device file tree…" ],
        "status_device_tree_saved": [ .it: "Albero del dispositivo salvato: %@", .en: "Device file tree saved: %@" ],
        "status_device_tree_failed": [
            .it: "Lettura dell'albero del dispositivo non riuscita o troppo lunga.", .en: "Reading the device file tree failed or took too long."
        ],
        "help_save_device_xml": [
            .it: "Salva GarminDevice.xml (diagnostica)", .en: "Save GarminDevice.xml (Diagnostics)"
        ],
        "status_device_xml_saving": [ .it: "Lettura di GarminDevice.xml…", .en: "Reading GarminDevice.xml…" ],
        "status_device_xml_saved": [ .it: "GarminDevice.xml salvato: %@", .en: "GarminDevice.xml saved: %@" ],
        "status_device_xml_failed": [
            .it: "GarminDevice.xml non trovato o non leggibile.", .en: "GarminDevice.xml not found or unreadable."
        ],
        "artwork_group_on_device": [
            .it: "Tutti i brani trasferibili sono già sul dispositivo", .en: "All transferable tracks are already on the device"
        ],
        "tooltip_device_files": [ .it: "Sfoglia i file del dispositivo (sola lettura)", .en: "Browse the device files (read-only)" ],
        "device_files_title": [ .it: "File del dispositivo", .en: "Device files" ],
        "device_files_back": [ .it: "Cartella superiore", .en: "Parent folder" ],
        "device_files_empty": [ .it: "Cartella vuota", .en: "Empty folder" ],
        "device_files_failed": [ .it: "Il dispositivo non risponde: riprova con «Aggiorna».", .en: "The device is not responding: try Refresh." ],
        "device_files_items": [ .it: "%d elementi", .en: "%d items" ],
        "device_files_readonly_note": [
            .it: "Solo lettura: il dispositivo non viene modificato. Doppio clic per aprire una cartella.",
            .en: "Read-only: the device is never modified. Double-click to open a folder."
        ],
        "device_files_col_name": [ .it: "Nome", .en: "Name" ],
        "device_files_col_kind": [ .it: "Tipo", .en: "Kind" ],
        "device_files_col_size": [ .it: "Dimensione", .en: "Size" ],
        "device_files_col_modified": [ .it: "Modificato", .en: "Modified" ],
        "device_files_kind_folder": [ .it: "Cartella", .en: "Folder" ],
        "device_files_kind_file": [ .it: "File", .en: "File" ],
        "device_files_root": [ .it: "Radice della memoria", .en: "Storage root" ],
        "device_files_copy_path": [ .it: "Copia percorso", .en: "Copy Path" ],
        "device_files_copy_to_mac": [ .it: "Copia sul Mac…", .en: "Copy to Mac…" ],
        "device_files_copy_here": [ .it: "Copia qui", .en: "Copy Here" ],
        "device_files_copy_panel_message": [
            .it: "Scegli la cartella del Mac in cui copiare %d file. Il dispositivo non viene modificato.",
            .en: "Choose the folder on your Mac where to copy %d file(s). The device is not modified."
        ],
        "device_files_copying": [ .it: "Copia in corso…", .en: "Copying…" ],
        "device_files_copied": [ .it: "Copiati %d file sul Mac", .en: "Copied %d file(s) to the Mac" ],
        "device_files_copied_failed": [
            .it: "Copiati %d file sul Mac, %d non riusciti", .en: "Copied %d file(s) to the Mac, %d failed"
        ],
        "help_copy_diagnostics": [
            .it: "Copia informazioni di diagnostica", .en: "Copy Diagnostic Information"
        ],
        "help_send_feedback": [
            .it: "Invia feedback…", .en: "Send Feedback…"
        ],
        "help_show_log": [
            .it: "Mostra il registro nel Finder", .en: "Show Log in Finder"
        ],
        "help_licenses": [
            .it: "Licenze di terze parti…", .en: "Third-Party Licenses…"
        ],
        "status_diagnostics_copied": [
            .it: "Informazioni di diagnostica copiate negli appunti: incollale nel messaggio di feedback (non contengono titoli né nomi della tua libreria).",
            .en: "Diagnostic information copied to the clipboard: paste it into your feedback (it contains no titles or names from your library)."
        ],
        "status_feedback_not_configured": [
            .it: "Diagnostica copiata negli appunti. L'indirizzo dei feedback non è ancora impostato in questa versione: apri una Issue su GitHub (github.com/RickyDive/musicmanager) e incolla il testo.",
            .en: "Diagnostics copied to the clipboard. The feedback address is not set in this build: open an Issue on GitHub (github.com/RickyDive/musicmanager) and paste the text."
        ],
        "welcome_title": [
            .it: "Benvenuto in Music Manager", .en: "Welcome to Music Manager"
        ],
        "welcome_message": [
            .it: "Grazie per aver scelto Music Manager.\n\n• Per leggere la libreria e creare playlist l'app chiederà il permesso di accedere a Music e di controllarla.\n• Non elimina brani dalla libreria di Music.\n• Le funzioni che inviano dati a Garmin (aggiornamenti software e mappe) sono spente: si attivano in Impostazioni ▸ Avanzate.\n• Se qualcosa non va: menu Aiuto ▸ Copia informazioni di diagnostica, poi Aiuto ▸ Invia feedback.",
            .en: "Thank you for choosing Music Manager.\n\n• To read your library and create playlists the app will ask for permission to access and control Music.\n• It does not delete tracks from your Music library.\n• Features that send data to Garmin (software updates and maps) are off: you can turn them on in Settings ▸ Advanced.\n• If something goes wrong: Help menu ▸ Copy Diagnostic Information, then Help ▸ Send Feedback."
        ],
        "about_legal_button": [
            .it: "Note legali…", .en: "Legal Notices…"
        ],
        "about_legal_title": [
            .it: "Note legali", .en: "Legal Notices"
        ],
        "about_legal_text": [
            .it: "Music Manager non è affiliato, sponsorizzato né approvato da Garmin Ltd. o da Apple Inc. Garmin, Apple, Apple Music e iTunes sono marchi dei rispettivi proprietari.\n\nMusic Manager è software libero, distribuito con licenza GNU GPL v3.0 (© 2026 Riccardo Colaiori, cr.developer). Il codice sorgente è su github.com/RickyDive/musicmanager.\n\nIl trasferimento verso l'orologio usa le librerie libmtp e libusb (LGPL), incluse nell'app come librerie separate (Aiuto ▸ Licenze di terze parti). La libreria musicale viene letta tramite il framework iTunesLibrary di Apple; le librerie condivise in rete vengono lette solo da un file XML esportato e da una cartella montata.",
            .en: "Music Manager is not affiliated with, sponsored or endorsed by Garmin Ltd. or Apple Inc. Garmin, Apple, Apple Music and iTunes are trademarks of their respective owners.\n\nMusic Manager is free software, released under the GNU GPL v3.0 (© 2026 Riccardo Colaiori, cr.developer). The source code is at github.com/RickyDive/musicmanager.\n\nTransfers to the watch use the libmtp and libusb libraries (LGPL), included in the app as separate libraries (Help ▸ Third-Party Licenses). The music library is read through Apple's iTunesLibrary framework; network-shared libraries are read only from an exported XML file and a mounted folder."
        ],
        "alert_random_to_manual_title": [
            .it: "Tornare all'ordine Manuale?", .en: "Go back to Manual order?"
        ],
        "alert_random_to_manual_message": [
            .it: "Vuoi tenere l'ordine casuale attuale come nuovo ordine Manuale, oppure ripristinare l'ordine Manuale precedente?",
            .en: "Do you want to keep the current random order as the new Manual order, or restore the previous Manual order?"
        ],
        "button_keep_random_as_manual": [
            .it: "Mantieni ordine casuale", .en: "Keep Random Order"
        ],
        "button_restore_previous_manual": [
            .it: "Ripristina Manuale precedente", .en: "Restore Previous Manual"
        ],
        "status_opening_music": [
            .it: "Apertura di Musica in corso…", .en: "Opening Music…"
        ],
        "status_music_not_started": [
            .it: "Musica non si è avviata.", .en: "Music did not start."
        ],
        "status_music_opened": [
            .it: "Musica aperta in secondo piano.", .en: "Music opened in the background."
        ],
        "button_confirm": [
            .it: "Conferma", .en: "Confirm"
        ],
        "status_fix_artwork_none_eligible": [
            .it: "Fix Artwork funziona solo su brani AAC/M4A trasferibili: nessuno tra quelli selezionati.",
            .en: "Fix Artwork only works on transferable AAC/M4A tracks: none among the selected ones."
        ],
        "status_fix_artwork_skipped_unsupported": [
            .it: "%d brani selezionati ignorati (Fix Artwork funziona solo su AAC/M4A).",
            .en: "%d selected tracks ignored (Fix Artwork only works on AAC/M4A)."
        ],
        "status_fix_artwork_done": [
            .it: "Copertine confermate: %d. Verranno inserite nei brani al prossimo invio all'orologio.",
            .en: "Artwork confirmed for %d track(s). It will be added when you next send them to the watch."
        ],
        "artwork_not_applied": [
            .it: "Copertina confermata ma non applicata: %@", .en: "Confirmed artwork not applied: %@"
        ],
        "artwork_reason_no_session": [
            .it: "esportazione non disponibile per questo file", .en: "export not available for this file"
        ],
        "artwork_reason_not_in_output": [
            .it: "la copertina non risulta nel file prodotto", .en: "the artwork isn't present in the exported file"
        ],
        "artwork_not_applied_restored": [
            .it: "Copertina non applicata (%@): brano inviato senza la nuova copertina",
            .en: "Artwork not applied (%@): track sent without the new artwork"
        ],
        "error_upload_not_verified": [
            .it: "il file non risulta sul dispositivo dopo l'invio", .en: "the file isn't on the device after sending"
        ],
        "button_skip_tracks": [
            .it: "Salta i brani", .en: "Skip Tracks"
        ],
        "transfer_note_artwork_applied": [
            .it: "Artwork aggiornato", .en: "Artwork updated"
        ],
        "status_fix_artwork_none_confirmed": [
            .it: "Fix Artwork: nessuna copertina confermata.", .en: "Fix Artwork: no artwork confirmed."
        ],
        "button_enable": [
            .it: "Attiva", .en: "Enable"
        ],
        "button_clear_artwork_cache": [
            .it: "Svuota cache copertine", .en: "Clear artwork cache"
        ],
        "status_artwork_cache_cleared": [
            .it: "Cache svuotata.", .en: "Cache cleared."
        ],

        // Mini player (Apple Music)
        "player_no_track": [
            .it: "Nessun brano in riproduzione\nFai doppio click su un brano per ascoltarlo",
            .en: "No track playing\nDouble-click a track to listen to it"
        ],
        "tooltip_player_previous": [
            .it: "Brano precedente", .en: "Previous track"
        ],
        "tooltip_player_play": [
            .it: "Riproduci", .en: "Play"
        ],
        "tooltip_player_pause": [
            .it: "Pausa", .en: "Pause"
        ],
        "tooltip_player_next": [
            .it: "Brano successivo", .en: "Next track"
        ],

        // Categorie del CatalogBrowser
        "category_songs": [
            .it: "Brani", .en: "Songs"
        ],
        "category_albums": [
            .it: "Album", .en: "Albums"
        ],
        "category_artists": [
            .it: "Artisti", .en: "Artists"
        ],
        "category_playlists": [
            .it: "Playlist", .en: "Playlists"
        ],
        "category_custom_playlist": [
            .it: "Custom", .en: "Custom"
        ],

        // Custom Playlist
        "sort_by_label": [
            .it: "Ordina per", .en: "Sort by"
        ],
        "sort_by_manual": [
            .it: "Manuale", .en: "Manual"
        ],
        "sort_by_track_name": [
            .it: "Titolo brano", .en: "Track Name"
        ],
        "sort_by_artist": [
            .it: "Artista", .en: "Artist"
        ],
        "sort_by_album": [
            .it: "Album", .en: "Album"
        ],
        "sort_by_random": [
            .it: "Casuale", .en: "Random"
        ],
        "custom_playlist_name_placeholder": [
            .it: "Nome della playlist", .en: "Playlist name"
        ],
        "custom_playlist_empty_hint": [
            .it: "Seleziona dei brani nelle schede Playlist, Artisti, Album o Brani e usa «Invia alla Playlist» per aggiungerli qui.",
            .en: "Select tracks on the Playlists, Artists, Albums or Songs tabs and use “Send to Playlist” to add them here."
        ],
        "button_clear_custom_playlist": [
            .it: "Svuota", .en: "Clear"
        ],
        "button_save_to_apple_music": [
            .it: "Salva in Musica", .en: "Save to Music"
        ],
        "tooltip_remove_from_custom_playlist": [
            .it: "Rimuovi dalla playlist", .en: "Remove from playlist"
        ],
        "alert_duplicate_tracks_title": [
            .it: "Brani già presenti nella playlist", .en: "Tracks already in the playlist"
        ],
        "alert_duplicate_tracks_message": [
            .it: "Questi brani risultano già presenti in questa playlist. Vuoi aggiungerli comunque?\n\n%@",
            .en: "These tracks are already in this playlist. Add them anyway?\n\n%@"
        ],
        "n_more_tracks": [
            .it: "…e altri %d", .en: "…and %d more"
        ],
        "button_add_anyway": [
            .it: "Aggiungi comunque", .en: "Add anyway"
        ],
        "duplicates_panel_message": [
            .it: "Questi brani sono già nella playlist. Spunta quelli da aggiungere comunque: gli altri vengono saltati.",
            .en: "These tracks are already in the playlist. Tick the ones to add anyway: the others are skipped."
        ],
        "duplicates_select_all": [
            .it: "Seleziona tutti", .en: "Select all"
        ],
        "duplicates_select_none": [
            .it: "Deseleziona tutti", .en: "Select none"
        ],
        "duplicates_add_count": [
            .it: "Aggiungi comunque (%d)", .en: "Add anyway (%d)"
        ],
        "status_custom_playlist_name_required": [
            .it: "Assegna un nome alla playlist prima di continuare.", .en: "Give the playlist a name before continuing."
        ],
        "status_saving_to_apple_music": [
            .it: "Salvataggio di «%@» in Music…", .en: "Saving “%@” to Music…"
        ],
        "status_saved_to_apple_music": [
            .it: "Playlist «%@» salvata in Music.", .en: "Playlist “%@” saved to Music."
        ],
        "status_saved_to_apple_music_partial": [
            .it: "Playlist «%@» salvata in Music, ma solo %d brani su %d sono stati aggiunti.",
            .en: "Playlist “%@” saved to Music, but only %d of %d tracks were added."
        ],
        "alert_apple_music_exists_title": [
            .it: "Playlist già esistente in Music", .en: "Playlist already exists in Music"
        ],
        "alert_apple_music_exists_message": [
            .it: "Nella cartella «Music Manager» di Music esiste già una playlist chiamata «%@». Vuoi sostituirla del tutto con quella attuale, oppure aggiungere questi brani a quella già esistente?",
            .en: "A playlist named “%@” already exists in the “Music Manager” folder in Music. Do you want to replace it entirely with this one, or add these tracks to the existing one?"
        ],
        "button_replace_playlist": [
            .it: "Sostituisci", .en: "Replace"
        ],
        "button_add_to_playlist": [
            .it: "Aggiungi", .en: "Add"
        ],
        "alert_apple_music_duplicates_title": [
            .it: "Brani già presenti nella playlist", .en: "Tracks already in the playlist"
        ],
        "alert_apple_music_duplicates_message": [
            .it: "Questi brani risultano già presenti in questa playlist di Music. Vuoi aggiungerli comunque o saltarli?\n\n%@",
            .en: "These tracks are already in this Music playlist. Add them anyway or skip them?\n\n%@"
        ],
        "nickname_prompt_title": [
            .it: "Nuovo dispositivo", .en: "New device"
        ],
        "nickname_prompt_message": [
            .it: "Hai collegato per la prima volta «%@». Vuoi dargli un nickname per riconoscerlo la prossima volta?",
            .en: "You have connected “%@” for the first time. Would you like to give it a nickname so you can recognize it next time?"
        ],
        "nickname_prompt_placeholder": [
            .it: "Nickname", .en: "Nickname"
        ],
        "settings_devices": [
            .it: "Dispositivi", .en: "Devices"
        ],
        "device_col_nickname": [
            .it: "Nickname", .en: "Nickname"
        ],
        "device_col_model": [
            .it: "Model", .en: "Model"
        ],
        "device_col_serial": [
            .it: "Serial Number",
            .en: "Serial Number"
        ],
        "device_col_maps": [
            .it: "Maps",
            .en: "Maps"
        ],
        "device_col_software": [
            .it: "Software Version", .en: "Software Version"
        ],
        "button_forget_devices": [
            .it: "Forget Devices", .en: "Forget Devices"
        ],
        "alert_forget_devices_title": [
            .it: "Dimenticare tutti i dispositivi?", .en: "Forget all devices?"
        ],
        "alert_forget_devices_message": [
            .it: "Nickname e dati dei dispositivi memorizzati vengono cancellati. Al prossimo collegamento verrà riproposto il nickname.",
            .en: "Nicknames and data of the stored devices will be deleted. The nickname will be asked again the next time you connect."
        ],
        "devices_hint": [
            .it: "I dispositivi si memorizzano al primo collegamento; la versione software si aggiorna a ogni collegamento. Solo il Nickname è modificabile.",
            .en: "Devices are stored at the first connection; the software version is updated at every connection. Only the Nickname can be edited."
        ],
        "button_skip": [
            .it: "Salta", .en: "Skip"
        ],
        "button_ignore": [.it: "Ignora", .en: "Ignore"],
        "button_back": [.it: "Indietro", .en: "Back"],
        "alert_fix_ok_title": [
            .it: "Non tutte le copertine sono state scelte",
            .en: "Not all the covers have been chosen"
        ],
        "alert_fix_ok_not_chosen": [
            .it: "Brani con una copertina online trovata ma non scelta: %d.",
            .en: "Songs with an online cover found but not chosen: %d."
        ],
        "alert_fix_ok_unchecked": [
            .it: "Brani non controllati: %d.",
            .en: "Songs not checked: %d."
        ],
        "alert_load_full_playlist_title": [
            .it: "Caricare tutta la playlist?", .en: "Load the whole playlist?"
        ],
        "alert_load_full_playlist_message": [
            .it: "Vuoi che la Custom Playlist contenga anche tutti gli altri brani già presenti in «%@» su Music, per comodità di modifica?",
            .en: "Do you want the Custom Playlist to also contain all the other tracks already in “%@” on Music, for easier editing?"
        ],
        "alert_fix_album_title": [
            .it: "Altri brani dello stesso album", .en: "Other songs from the same album"
        ],
        "alert_fix_album_message": [
            .it: "Nell'album «%2$@» ci sono altri %1$d brani senza copertina. Vuoi usare la stessa copertina anche per loro?",
            .en: "The album “%2$@” has %1$d more songs without a cover. Do you want to use the same cover for them too?"
        ],
        "alert_fix_album_message_one": [
            .it: "Nell'album «%@» c'è un altro brano senza copertina. Vuoi usare la stessa copertina anche per lui?",
            .en: "The album “%@” has 1 more song without a cover. Do you want to use the same cover for it too?"
        ],
        "button_continue": [.it: "Continua", .en: "Continue"],
        "alert_stop_send_title": [.it: "Interrompere l'invio?", .en: "Stop sending?"],
        "alert_stop_send_message": [
            .it: "L'invio prosegue fino alla fine del file in corso, poi si ferma. I file non ancora trasferiti e le playlist non completate non saranno inviati.",
            .en: "The transfer will finish the file in progress and then stop. Files not yet transferred and playlists that are not complete will not be sent."
        ],
        "transfer_stopping": [.it: "Interruzione dopo il file in corso…", .en: "Stopping after the current file…"],
        "transfer_stopped_note": [
            .it: "Invio interrotto prima del completamento: non tutti i file sono stati trasferiti e le playlist non completate non sono state inviate.",
            .en: "Send stopped before completion: not all files were transferred, and playlists that were not complete were not sent."
        ],
        "status_send_stopped": [.it: "Invio interrotto prima del completamento.", .en: "Send stopped before completion."],
        "button_yes": [
            .it: "Sì", .en: "Yes"
        ],
        "button_no": [
            .it: "No", .en: "No"
        ],
        "export_device_only": [
            .it: "Solo device", .en: "Device only"
        ],
        "button_edit_in_custom": [
            .it: "Edit in Custom", .en: "Edit in Custom"
        ],
        "menu_edit_in_custom": [
            .it: "Edit in Custom", .en: "Edit in Custom"
        ],
        "tooltip_edit_in_custom": [
            .it: "Importa questa playlist nella Custom Playlist per modificarla e rinviarla al dispositivo",
            .en: "Import this playlist into the Custom Playlist to edit it and send it back to the device"
        ],
        "tooltip_device_only_track": [
            .it: "Brano presente solo sul dispositivo (non nella libreria Music): non si copia, resta il file già sul device",
            .en: "Track only on the device (not in the Music library): it is not copied, the file already on the device is used"
        ],
        "device_only_missing_note": [
            .it: "Non più presente sul dispositivo: escluso dalla playlist", .en: "No longer on the device: left out of the playlist"
        ],
        "alert_device_load_title": [
            .it: "Importare la playlist del dispositivo", .en: "Import the device playlist"
        ],
        "alert_device_load_message": [
            .it: "La Custom Playlist contiene già dei brani. Come vuoi importare «%1$@»? In ogni caso la playlist prenderà il nome «%1$@». Se alcuni brani sono già presenti, potrai scegliere quali aggiungere comunque.\n\n• Playlist del device per prima: prima la playlist del device, poi i brani che hai ora.\n• Brani attuali per primi: prima i brani che hai ora, poi la playlist del device.\n• Sovrascrivi: i brani attuali vengono sostituiti da quelli della playlist del device.",
            .en: "The Custom Playlist already contains tracks. How do you want to import “%1$@”? Either way the playlist will be named “%1$@”. If some tracks are already there, you can choose which ones to add anyway.\n\n• Playlist First: the device playlist first, then the tracks you have now.\n• Current Tracks First: the current tracks first, then the device playlist.\n• Replace: the current tracks are replaced by those of the device playlist."
        ],
        "button_load_current_after_device": [
            .it: "Playlist del device per prima", .en: "Playlist First"
        ],
        "button_load_saved_after_device": [
            .it: "Brani attuali per primi", .en: "Current Tracks First"
        ],
        "status_device_playlist_empty": [
            .it: "La playlist «%@» del dispositivo non contiene brani.", .en: "The device playlist “%@” has no tracks."
        ],
        "status_device_playlist_imported": [
            .it: "Playlist «%@» importata dal dispositivo: %d brani (%d in libreria, %d solo sul device).",
            .en: "Playlist “%@” imported from the device: %d tracks (%d in the library, %d device only)."
        ],
        "custom_playlist_copy_suffix": [
            .it: "_copy", .en: "_copy"
        ],
        "alert_clear_custom_playlist_title": [
            .it: "Svuotare la Custom Playlist?", .en: "Empty the Custom Playlist?"
        ],
        "alert_clear_custom_playlist_message": [
            .it: "La Custom Playlist contiene già dei brani. Vuoi svuotarla prima di inviarle l'intera playlist «%@», oppure aggiungerla a quelli già presenti?",
            .en: "The Custom Playlist already contains tracks. Do you want to empty it before sending the whole “%@” playlist, or add it to what's already there?"
        ],
        "button_empty_and_send": [
            .it: "Svuota e invia", .en: "Empty and send"
        ],
        "button_append_without_clearing": [
            .it: "Aggiungi senza svuotare", .en: "Add without emptying"
        ],

        // Messaggi di stato (AppViewModel)
        "status_no_device": [
            .it: "Nessun dispositivo collegato", .en: "No device connected"
        ],
        "artwork_origin_own": [
            .it: "Copertina presente nel brano", .en: "Cover present in the track"
        ],
        "artwork_origin_cache": [
            .it: "Copertina solo dalla cache di Musica: verrà scritta nel file inviato all'orologio (serve Musica aperta)",
            .en: "Cover only from the Music cache: it will be written into the file sent to the watch (Music must be open)"
        ],
        "settings_tab_general": [
            .it: "Generale", .en: "General"
        ],
        "settings_tab_appearance": [
            .it: "Aspetto", .en: "Appearance"
        ],
        "settings_tab_artwork": [
            .it: "Artwork", .en: "Artwork"
        ],
        "settings_tab_advanced": [
            .it: "Avanzate", .en: "Advanced"
        ],
        "settings_playlist_types": [
            .it: "Playlist di Music", .en: "Music playlists"
        ],
        "settings_playlist_types_all": [
            .it: "Mostra tutte", .en: "Show all"
        ],
        "settings_playlist_types_regular": [
            .it: "Solo normali (senza smart e Genius)", .en: "Regular only (no smart or Genius)"
        ],
        "settings_playlist_types_smart_genius": [
            .it: "Solo smart o Genius", .en: "Smart or Genius only"
        ],
        "settings_playlist_types_hint": [
            .it: "Filtra l'elenco Playlist per tipo. Le playlist create da te e quelle di Music aggiunte alla libreria sono entrambe «normali». Nelle librerie di altre reti salvate prima di questa versione il tipo non è noto (valgono come normali) finché la libreria non viene riletta dal suo file XML.",
            .en: "Filters the Playlist list by type. Playlists you made and Music playlists added to the library are both “regular”. In libraries from other networks saved before this version the type is unknown (they count as regular) until the library is re-read from its XML file."
        ],
        "settings_auto_apple_artwork": [
            .it: "Carica automaticamente le Artwork da Music", .en: "Load artwork from Music automatically"
        ],
        "settings_auto_apple_artwork_hint": [
            .it: "Se attivo, le copertine mancanti si caricano da sole espandendo una playlist, un artista o un album e selezionando i brani. Se spento, si chiedono con il click destro («Carica Artwork da Music»).",
            .en: "When on, missing artwork loads by itself when you expand a playlist, artist or album and when you select songs. When off, request it with right-click (“Load artwork from Music”)."
        ],
        "music_prompt_title": [
            .it: "Aprire Music?", .en: "Open Music?"
        ],
        "music_prompt_open": [
            .it: "Apri Music", .en: "Open Music"
        ],
        "music_prompt_no": [
            .it: "No", .en: "No"
        ],
        "music_prompt_manual_message": [
            .it: "Music è chiusa: per recuperare le Artwork va aperta. Verrà avviata in secondo piano, senza coprire Music Manager.",
            .en: "Music is not running: it must be open to retrieve the artwork. It will start in the background, without covering Music Manager."
        ],
        "music_prompt_startup_message": [
            .it: "Il recupero automatico delle Artwork è attivo, ma Music è chiusa. Vuoi aprirla (in secondo piano, senza coprire Music Manager)?\n\nSe rispondi No, il recupero automatico verrà disattivato in Impostazioni ▸ Artwork: potrai comunque richiederlo a mano con il click destro.",
            .en: "Automatic artwork retrieval is on, but Music is not running. Do you want to open it (in the background, without covering Music Manager)?\n\nIf you answer No, automatic retrieval will be turned off in Settings ▸ Artwork: you can still request it by hand with right-click."
        ],
        "purchased_track_help": [
            .it: "Brano acquistato su iTunes Store: la riproduzione sul Garmin non è garantita (possibile DRM).",
            .en: "Track purchased on the iTunes Store: playback on the Garmin is not guaranteed (possible DRM)."
        ],
        "purchased_group_help": [
            .it: "Contiene %d brani acquistati su iTunes Store: la riproduzione sul Garmin non è garantita (possibile DRM).",
            .en: "Contains %d tracks purchased on the iTunes Store: playback on the Garmin is not guaranteed (possible DRM)."
        ],
        "settings_propose_shared_artwork": [
            .it: "Proponi sempre la ricerca degli Artwork per i brani sprovvisti",
            .en: "Always offer to search artwork for tracks without it"
        ],
        "settings_propose_shared_artwork_hint": [
            .it: "Inviando all'orologio o alla Custom Playlist brani senza copertina (libreria locale, condivisa o su unità esterna), chiede se cercarla online e apre il pannello Artwork. Richiede «Cerca copertine mancanti online» attivo.",
            .en: "When sending tracks without artwork (local, shared or external-drive library) to the watch or the Custom Playlist, asks whether to search it online and opens the Artwork panel. Requires the online artwork search to be on."
        ],
        "artwork_proposal_title": [
            .it: "Copertine mancanti", .en: "Missing artwork"
        ],
        "artwork_proposal_message": [
            .it: "%d brani non hanno la copertina. Vuoi cercarla online? Si aprirà il pannello Artwork; al termine l'invio riprende.",
            .en: "%d tracks have no artwork. Do you want to search for it online? The Artwork panel will open; when you are done the send continues."
        ],
        "artwork_proposal_search": [
            .it: "Cerca online", .en: "Search online"
        ],
        "artwork_proposal_continue": [
            .it: "Continua senza", .en: "Continue without"
        ],
        "menu_go_to_album": [
            .it: "Vai all'Album", .en: "Go to Album"
        ],
        "menu_go_to_artist": [
            .it: "Vai all'Artista", .en: "Go to Artist"
        ],
        "menu_show_in_playlist": [
            .it: "Mostra in playlist", .en: "Show in playlist"
        ],
        "menu_show_in_playlist_more": [
            .it: "…e altre %d playlist", .en: "…and %d more playlists"
        ],
        "tooltip_in_playlist": [
            .it: "Brano inserito in almeno una playlist", .en: "Track included in at least one playlist"
        ],
        "artwork_loading_notice": [
            .it: "Caricamento delle copertine da Music…", .en: "Loading artwork from Music…"
        ],
        "artwork_loading_notice_drive": [
            .it: "Lettura delle copertine dall'unità esterna…", .en: "Reading artwork from the external drive…"
        ],
        "artwork_loading_notice_shared": [
            .it: "Lettura delle copertine dalla libreria condivisa…", .en: "Reading artwork from the shared library…"
        ],
        "library_unavailable": [
            .it: "non disponibile", .en: "unavailable"
        ],
        "settings_drive_libraries": [
            .it: "Librerie su Dispositivi Esterni", .en: "External Drive Libraries"
        ],
        "drive_add": [
            .it: "Aggiungi cartella…", .en: "Add Folder…"
        ],
        "drive_hint": [
            .it: "Una cartella con file audio su un disco o una chiavetta: l'app crea un indice con i soli brani che il tuo Garmin può ricevere. I tuoi file non vengono mai modificati. Se non hai ancora collegato un Garmin, il catalogo usa i formati comuni (MP3, M4A, AAC) e si rifà da solo quando ne colleghi uno.", .en: "A folder of audio files on a drive or USB stick: the app builds an index with only the tracks your Garmin can receive. Your files are never modified. If you have not connected a Garmin yet, the catalog uses the common formats (MP3, M4A, AAC) and is rebuilt when you connect one."
        ],
        "drive_pick_title": [
            .it: "Cartella con i file audio", .en: "Folder with the audio files"
        ],
        "drive_pick_message": [
            .it: "Scegli la cartella dell'unità esterna che contiene la musica (anche in sottocartelle).", .en: "Choose the folder on the external drive that contains the music (subfolders included)."
        ],
        "drive_generic_device": [
            .it: "Garmin generico", .en: "Generic Garmin"
        ],
        "drive_no_device_title": [
            .it: "Nessun dispositivo registrato", .en: "No registered device"
        ],
        "drive_no_device_message": [
            .it: "Music Manager serve a inviare musica a un Garmin: per creare il catalogo di un'unità esterna collega almeno una volta un dispositivo che accetta musica, poi riprova.", .en: "Music Manager sends music to a Garmin: to build the catalog of an external drive, connect a device that accepts music at least once, then try again."
        ],
        "drive_setup_title": [
            .it: "Nuova libreria su unità esterna", .en: "New external drive library"
        ],
        "drive_setup_connected": [
            .it: "È collegato «%@»: verrà creato un catalogo con i brani compatibili con questo dispositivo (formati: %@).", .en: "“%@” is connected: a catalog will be created with the tracks compatible with this device (formats: %@)."
        ],
        "drive_setup_single": [
            .it: "Verrà creato un catalogo con i brani compatibili con «%@» (formati: %@).", .en: "A catalog will be created with the tracks compatible with “%@” (formats: %@)."
        ],
        "drive_setup_pick": [
            .it: "Nessun dispositivo collegato. Scegli il dispositivo per cui creare il catalogo dei brani compatibili:", .en: "No device connected. Choose the device to build the catalog of compatible tracks for:"
        ],
        "drive_col_device": [
            .it: "Dispositivo", .en: "Device"
        ],
        "drive_col_formats": [
            .it: "Formati audio supportati", .en: "Supported audio formats"
        ],
        "drive_setup_note": [
            .it: "La musica non viene copiata né modificata: si crea solo un indice. Le copertine mancanti si possono cercare online come per le altre librerie.", .en: "Music is neither copied nor modified: only an index is created. Missing artwork can be searched online as for the other libraries."
        ],
        "drive_create": [
            .it: "Crea catalogo", .en: "Create Catalog"
        ],
        "drive_row_info": [
            .it: "%@ · %d brani", .en: "%@ · %d tracks"
        ],
        "drive_rescan_help": [
            .it: "Rilegge la cartella (solo i file nuovi o cambiati)", .en: "Rescan the folder (new or changed files only)"
        ],
        "drive_remove_title": [
            .it: "Rimuovere la libreria?", .en: "Remove the library?"
        ],
        "drive_remove_message": [
            .it: "La libreria «%@» verrà tolta dall'elenco e il suo indice cancellato. I file sull'unità non vengono toccati.", .en: "The library “%@” will be removed from the list and its index deleted. Files on the drive are not touched."
        ],
        "drive_phase_scanning": [
            .it: "Ricerca dei file audio…", .en: "Looking for audio files…"
        ],
        "drive_phase_reading": [
            .it: "Lettura dei brani: %d di %d", .en: "Reading tracks: %d of %d"
        ],
        "drive_status_reading": [
            .it: "Apertura della libreria su unità esterna…", .en: "Opening the external drive library…"
        ],
        "drive_err_unavailable": [
            .it: "La libreria «%@» non è disponibile: collega l'unità.", .en: "Library “%@” is not available: connect the drive."
        ],
        "drive_rescan_title": [
            .it: "Rifare il catalogo?", .en: "Rebuild the catalog?"
        ],
        "drive_rescan_message": [
            .it: "Il catalogo «%@» è stato creato per «%@», ma ora è collegato «%@», con formati diversi. Vuoi ricrearlo per questo dispositivo?", .en: "The catalog “%@” was built for “%@”, but “%@” is connected now, with different formats. Rebuild it for this device?"
        ],
        "drive_rescan_for": [
            .it: "Ricrea per %@", .en: "Rebuild for %@"
        ],
        "drive_keep": [
            .it: "Mantieni", .en: "Keep"
        ],
        "drive_eject_help": [
            .it: "Espelli l'unità (si torna alla libreria locale)", .en: "Eject the drive (back to the local library)"
        ],
        "drive_ejected": [
            .it: "Unità della libreria «%@» espulsa: puoi scollegarla.", .en: "Drive of library “%@” ejected: you can unplug it."
        ],
        "drive_eject_failed": [
            .it: "Impossibile espellere l'unità della libreria «%@»: %@", .en: "Cannot eject the drive of library “%@”: %@"
        ],
        "drive_disconnected_status": [
            .it: "L'unità della libreria «%@» è stata scollegata: si torna alla libreria locale.", .en: "The drive of library “%@” was disconnected: back to the local library."
        ],
        "menu_settings_help": [
            .it: "Impostazioni", .en: "Settings"
        ],
        "notices_title": [
            .it: "Notifiche", .en: "Notifications"
        ],
        "notices_empty": [
            .it: "Nessuna notifica", .en: "No notifications"
        ],
        "notices_clear": [
            .it: "Svuota", .en: "Clear"
        ],
        "tooltip_save_to_music_drive": [
            .it: "Non disponibile con una libreria su unità esterna: i suoi brani non hanno legami con Music", .en: "Not available with an external drive library: its songs have no link to Music"
        ],
        "drive_eject_used_by": [
            .it: "Programmi che usano l'unità: %@.", .en: "Programs using the drive: %@."
        ],
        "drive_ejecting": [
            .it: "Espulsione dell'unità della libreria «%@»…", .en: "Ejecting the drive of library “%@”…"
        ],
        "library_unreachable": [
            .it: "non raggiungibile", .en: "unreachable"
        ],
        "library_unreachable_status": [
            .it: "La libreria «%@» non è raggiungibile: controlla la connessione al server.",
            .en: "Library “%@” cannot be reached: check the connection to the server."
        ],
        "remote_library_changed_status": [
            .it: "La libreria «%@» è cambiata sul server: premi Aggiorna per rileggerla.",
            .en: "Library “%@” has changed on the server: press Refresh to read it again."
        ],
        "alert_remove_library_title": [
            .it: "Rimuovere la libreria?", .en: "Remove the library?"
        ],
        "alert_remove_library_message": [
            .it: "La libreria condivisa «%@» verrà tolta dall'elenco. I file sul server non vengono toccati.",
            .en: "The shared library “%@” will be removed from the list. Files on the server are not touched."
        ],
        "button_remove": [
            .it: "Rimuovi", .en: "Remove"
        ],
        "library_local": [
            .it: "Locale", .en: "Local Library"
        ],
        "library_menu_help": [
            .it: "Libreria da consultare: locale o remota (file XML)", .en: "Library to browse: local or remote (XML file)"
        ],
        "library_none_found": [
            .it: "Nessuna libreria remota: aggiungila in Impostazioni", .en: "No remote library: add one in Settings"
        ],
        "settings_remote_libraries": [
            .it: "Librerie Remote", .en: "Remote Libraries"
        ],
        "remote_col_nickname": [
            .it: "Nickname", .en: "Nickname"
        ],
        "settings_mount_at_launch": [
            .it: "Montaggio automatico", .en: "Mount automatically"
        ],
        "settings_mount_at_launch_help": [
            .it: "Acceso: all'apertura Music Manager prova a montare i volumi di rete delle librerie remote (può richiedere tempo con reti lente). Spento: all'apertura si controlla solo se le librerie sono raggiungibili; il volume si monta quando scegli la libreria.",
            .en: "On: when it opens, Music Manager tries to mount the network volumes of the remote libraries (it can take time on slow networks). Off: at launch it only checks whether the libraries are reachable; the volume is mounted when you choose the library."
        ],
        "status_remote_libraries_searching": [
            .it: "Music Manager sta cercando le tue Librerie Remote: se non sei sulla rete di casa o la connessione è lenta, può richiedere tempo…",
            .en: "Music Manager is looking for your Remote Libraries: if you are not on your home network or the connection is slow, it may take a while…"
        ],
        "library_reachable_not_mounted": [
            .it: "«%@» è raggiungibile ma non montata: si monta quando la scegli dal selettore delle librerie.",
            .en: "“%@” is reachable but not mounted: it is mounted when you choose it in the library picker."
        ],
        "alert_mount_library_title": [
            .it: "Connessione a una risorsa di rete", .en: "Connecting to a network resource"
        ],
        "alert_mount_library_message": [
            .it: "Ti stai connettendo a una risorsa di rete: la libreria «%@» non è ancora montata. Music Manager la monterà e la aprirà; se la rete è lenta o instabile può richiedere tempo.\n\nVuoi continuare?",
            .en: "You are connecting to a network resource: library “%@” is not mounted yet. Music Manager will mount and open it; on a slow or unstable network it may take a while.\n\nDo you want to continue?"
        ],
        "button_connect_library": [
            .it: "Connetti", .en: "Connect"
        ],
        "library_name_placeholder": [
            .it: "Dai un nome alla libreria", .en: "Give the library a name"
        ],
        "library_name_required": [
            .it: "Il nome è obbligatorio: scrivilo e premi Invio. Con «−» puoi annullare l'aggiunta.",
            .en: "A name is required: type it and press Return. Use “−” to cancel the addition."
        ],
        "remote_col_path": [
            .it: "Percorso", .en: "Path"
        ],
        "remote_choose_button": [
            .it: "Scegli file XML…", .en: "Choose XML file…"
        ],
        "remote_add": [
            .it: "Aggiungi libreria", .en: "Add library"
        ],
        "remote_max_hint": [
            .it: "Massimo %d librerie", .en: "Up to %d libraries"
        ],
        "remote_choose_xml_help": [
            .it: "Sfoglia e scegli il file XML della libreria", .en: "Browse and choose the library XML file"
        ],
        "remote_remove_help": [
            .it: "Rimuovi la libreria", .en: "Remove the library"
        ],
        "remote_hint": [
            .it: "Il file XML si esporta da Musica sull'altro Mac (File ▸ Libreria ▸ Esporta libreria…); i file audio devono essere raggiungibili da questo Mac (cartella condivisa montata). Il nome compare nel selettore delle librerie della finestra principale.",
            .en: "Export the XML file from Music on the other Mac (File ▸ Library ▸ Export Library…); the audio files must be reachable from this Mac (mounted shared folder). The nickname appears in the library picker of the main window."
        ],
        "remote_default_nickname": [
            .it: "Libreria %d", .en: "Library %d"
        ],
        "remote_phase_reading": [
            .it: "Lettura del file XML (la prima volta può richiedere tempo)…", .en: "Reading the XML file (the first time can take a while)…"
        ],
        "remote_playback_loading": [
            .it: "Caricamento dal server remoto…", .en: "Loading from the remote server…"
        ],
        "remote_playback_timeout_status": [
            .it: "Il brano non è partito entro %d secondi: connessione verso la libreria remota troppo lenta.",
            .en: "The track did not start within %d seconds: the connection to the remote library is too slow."
        ],
        "remote_playback_restored_status": [
            .it: "Riproduzione ripristinata sulle librerie remote.", .en: "Playback restored on remote libraries."
        ],
        "remote_playback_started_status": [
            .it: "In riproduzione dalla libreria remota: «%@».", .en: "Playing from the remote library: “%@”."
        ],
        "remote_playback_disabled_status": [
            .it: "Riproduzione dalle librerie remote disattivata fino alla chiusura dell'app.",
            .en: "Playback from remote libraries is turned off until the app is closed."
        ],
        "alert_remote_playback_title": [
            .it: "Ascolto dalla rete non riuscito", .en: "Network playback failed"
        ],
        "alert_remote_playback_message": [
            .it: "Gli ultimi %d brani non sono partiti entro %d secondi. Non è un errore dell'app: i file si trovano su un'altra rete e la connessione è troppo lenta per ascoltarli in anteprima. Puoi sfogliare la libreria e inviare i brani al dispositivo, ma l'invio sarà lento.\n\nVuoi disattivare la riproduzione dalle librerie remote fino alla chiusura dell'app? Il resto dell'app non cambia.",
            .en: "The last %d tracks did not start within %d seconds. This is not an app error: the files are on another network and the connection is too slow to preview them. You can still browse the library and send tracks to the device, but sending will be slow.\n\nTurn off playback from remote libraries until the app is closed? Everything else keeps working."
        ],
        "alert_remote_playback_off_title": [
            .it: "Riproduzione dalla rete disattivata", .en: "Network playback is off"
        ],
        "alert_remote_playback_off_message": [
            .it: "Hai disattivato l'ascolto dalle librerie remote perché la connessione era troppo lenta. Vuoi riattivarlo e riprovare?",
            .en: "You turned off playback from remote libraries because the connection was too slow. Turn it back on and try again?"
        ],
        "button_disable_remote_playback": [
            .it: "Disattiva riproduzione", .en: "Turn off playback"
        ],
        "button_keep_remote_playback": [
            .it: "Mantieni attiva", .en: "Keep on"
        ],
        "button_enable_remote_playback": [
            .it: "Riattiva e riprova", .en: "Turn on and retry"
        ],
        "quit_disconnecting_network_title": [
            .it: "Disconnessione dalle risorse di rete…", .en: "Disconnecting from network resources…"
        ],
        "quit_disconnecting_network_message": [
            .it: "Music Manager sta chiudendo le librerie remote. L'app si chiuderà da sola tra pochi secondi.",
            .en: "Music Manager is closing the remote libraries. The app will quit by itself in a few seconds."
        ],
        "remote_phase_copying": [
            .it: "Copia dell'XML: %@ di %@ MB (%@)", .en: "Copying the XML: %@ of %@ MB (%@)"
        ],
        "remote_err_stalled": [
            .it: "Trasferimento dell'XML interrotto: nessun dato ricevuto da %d secondi. Controlla la connessione (VPN, rete) e riprova.",
            .en: "XML transfer stopped: no data received for %d seconds. Check the connection (VPN, network) and try again."
        ],
        "remote_phase_processing": [
            .it: "Elaborazione dei brani…", .en: "Processing tracks…"
        ],
        "remote_phase_processing_took": [
            .it: "XML letto in %d s. Elaborazione dei brani…", .en: "XML read in %d s. Processing tracks…"
        ],
        "remote_err_missing_file": [
            .it: "File XML non trovato: %@", .en: "XML file not found: %@"
        ],
        "external_pick_xml_title": [
            .it: "Libreria di Musica (file XML)", .en: "Music library (XML file)"
        ],
        "external_pick_xml_message": [
            .it: "Scegli il file XML della libreria esportato dall'altro Mac (cartella condivisa montata).",
            .en: "Choose the library XML file exported from the other Mac (mounted shared folder)."
        ],
        "external_pick_media_title": [
            .it: "Cartella dei brani", .en: "Music files folder"
        ],
        "external_pick_media_message": [
            .it: "Scegli la cartella montata che contiene i file audio (di solito «Media»).",
            .en: "Choose the mounted folder that contains the audio files (usually “Media”)."
        ],
        "external_status_reading": [
            .it: "Lettura del file XML della libreria…", .en: "Reading the library XML file…"
        ],
        "external_cancelled": [
            .it: "Apertura della libreria annullata: cartella dei brani non scelta.",
            .en: "Opening the library cancelled: no music folder chosen."
        ],
        "external_err_unreadable": [
            .it: "File XML della libreria non leggibile.", .en: "The library XML file could not be read."
        ],
        "status_loading_library": [
            .it: "Lettura libreria Musica…", .en: "Reading Music library…"
        ],
        "status_library_loaded": [
            .it: "Libreria: %1$d brani (%2$d trasferibili), %3$d playlist", .en: "Library: %1$d tracks (%2$d transferable), %3$d playlists"
        ],
        "status_select_track": [
            .it: "Seleziona almeno un brano trasferibile", .en: "Select at least one transferable track"
        ],
        "status_preparing": [
            .it: "Preparazione…", .en: "Preparing…"
        ],
        "status_sending": [
            .it: "Invio %1$d/%2$d: %3$@", .en: "Sending %1$d/%2$d: %3$@"
        ],
        "status_sent_tracks": [
            .it: "Inviati e verificati %1$d brani su %2$@ (Music\\Artista\\Album)", .en: "Sent and verified %1$d tracks to %2$@ (Music\\Artist\\Album)"
        ],
        "status_sent_tracks_with_failures": [
            .it: "Inviati e verificati %1$d brani su %3$@ (Music\\Artista\\Album) (%2$d non riusciti: riprova per quei brani)", .en: "Sent and verified %1$d tracks to %3$@ (Music\\Artist\\Album) (%2$d failed: retry for those tracks)"
        ],
        "status_connecting": [
            .it: "Connessione al dispositivo…", .en: "Connecting to device…"
        ],
        "status_reading_device_music": [
            .it: "Lettura musica dal dispositivo…", .en: "Reading music from device…"
        ],
        "delete_progress_title": [
            .it: "Eliminazione dal dispositivo", .en: "Deleting from the device"
        ],
        "delete_progress_empty_title": [
            .it: "Svuotamento della cartella Music del dispositivo", .en: "Emptying the Music folder on the device"
        ],
        "delete_progress_item": [
            .it: "Eliminazione %1$d di %2$d: %3$@", .en: "Deleting %1$d of %2$d: %3$@"
        ],
        "delete_progress_counting": [
            .it: "Lettura del contenuto…", .en: "Reading the contents…"
        ],
        "delete_progress_cleanup": [
            .it: "Pulizia delle cartelle vuote…", .en: "Removing empty folders…"
        ],
        "delete_progress_refresh": [
            .it: "Aggiornamento dell'elenco…", .en: "Refreshing the list…"
        ],
        "status_device_connected": [
            .it: "Dispositivo connesso", .en: "Device connected"
        ],
        "device_playlists_one": [
            .it: "1 Playlist", .en: "1 Playlist"
        ],
        "device_playlists_many": [
            .it: "%d Playlist", .en: "%d Playlists"
        ],
        "device_counts_rest": [
            .it: "%1$d Artisti · %2$d Album · %3$d Brani · Durata totale: %4$@",
            .en: "%1$d Artists · %2$d Albums · %3$d Songs · Total Running Time: %4$@"
        ],
        "device_time_estimated": [
            .it: "(stimato)", .en: "(estimated)"
        ],
        "device_no_music": [
            .it: "Nessuna musica nel dispositivo", .en: "No music on your device"
        ],
        "device_no_music_capsule": [
            .it: "Musica non supportata", .en: "Music not supported"
        ],
        "tooltip_device_not_music_capable": [
            .it: "GarminDevice.xml non dichiara formati musicali: questo dispositivo non supporta la musica. Invio e cancellazione sono disattivati.",
            .en: "GarminDevice.xml declares no music formats: this device does not support music. Sending and deleting are disabled."
        ],
        "status_device_not_music_capable": [
            .it: "Questo dispositivo non supporta la musica: operazione non disponibile.",
            .en: "This device does not support music: operation not available."
        ],
        "error_read_only_device": [
            .it: "Dispositivo in sola lettura (non supporta la musica).", .en: "Read-only device (it does not support music)."
        ],
        "status_disconnected": [
            .it: "Dispositivo scollegato", .en: "Device disconnected"
        ],
        "status_reading": [
            .it: "Lettura…", .en: "Reading…"
        ],
        "status_refreshing": [
            .it: "Aggiornamento…", .en: "Refreshing…"
        ],
        "status_deleting": [
            .it: "Eliminazione…", .en: "Deleting…"
        ],
        "status_deleted_tracks": [
            .it: "Eliminati %d brani", .en: "Deleted %d tracks"
        ],
        "status_playlist_empty": [
            .it: "La playlist «%@» non contiene brani trasferibili", .en: "The playlist “%@” has no transferable tracks"
        ],
        "status_preparing_playlist": [
            .it: "Preparazione playlist «%@»…", .en: "Preparing playlist “%@”…"
        ],
        "status_playlist_not_found": [
            .it: "Playlist «%@» non trovata in Musica (rinominata o eliminata?)", .en: "Playlist “%@” not found in Music (renamed or deleted?)"
        ],
        "status_playlist_verification_failed": [
            .it: "Playlist «%1$@»: trasferiti e verificati %2$d di %3$d brani. File .m3u8 non creato: riprova per i brani mancanti.", .en: "Playlist “%1$@”: transferred and verified %2$d of %3$d tracks. .m3u8 file not created: retry for the missing tracks."
        ],
        "status_playlist_file_not_verified": [
            .it: "Playlist «%@»: i brani sono stati trasferiti, ma il file .m3u8 non risulta scritto correttamente sul dispositivo dopo 3 tentativi. Riprova l'invio della playlist.",
            .en: "Playlist “%@”: the tracks were transferred, but the .m3u8 file could not be verified on the device after 3 attempts. Send the playlist again."
        ],
        "status_playlist_not_listed": [
            .it: "Il file della playlist «%@» c'è sul dispositivo ma non compare ancora nell'elenco: premi Aggiorna tra qualche istante.",
            .en: "The “%@” playlist file is on the device but does not show in the list yet: press Refresh in a moment."
        ],
        "status_playlist_count_mismatch": [
            .it: "Nell'elenco risultano %1$d brani su %2$d: premi Aggiorna tra qualche istante.",
            .en: "The list shows %1$d of %2$d tracks: press Refresh in a moment."
        ],
        "status_creating_playlist_file": [
            .it: "Creazione file playlist…", .en: "Creating playlist file…"
        ],
        "status_playlist_sent": [
            .it: "Playlist %1$@ inviata a %3$@: %2$d brani + file .m3u8", .en: "Playlist %1$@ sent to %3$@: %2$d tracks + .m3u8 file"
        ],
        "unknown": [
            .it: "Sconosciuto", .en: "Unknown"
        ],
        "default_playlist_name": [
            .it: "Playlist", .en: "Playlist"
        ],

        // Errori MTP (MTPService)
        "error_no_device": [
            .it: "Nessun dispositivo MTP trovato. Controlla il cavo, sblocca l'orologio e verifica che la modalità USB sia MTP.", .en: "No MTP device found. Check the cable, unlock the watch and make sure USB mode is set to MTP."
        ],
        "error_cannot_open": [
            .it: "Impossibile aprire il dispositivo. Chiudi Garmin Connect, Garmin Express, Acquisizione Immagine, OpenMTP, Android File Transfer o altre app che lo stanno usando e riprova.", .en: "Couldn't open the device. Quit Garmin Connect, Garmin Express, Image Capture, OpenMTP, Android File Transfer or any other app using it, then try again."
        ],
        "error_not_connected": [
            .it: "Dispositivo non connesso.", .en: "Device not connected."
        ],
        "error_download_failed": [
            .it: "Download fallito: %@", .en: "Download failed: %@"
        ],
        "error_out_of_memory": [
            .it: "Memoria insufficiente", .en: "Out of memory"
        ],
        "error_upload_failed": [
            .it: "Upload di %1$@ fallito: %2$@", .en: "Upload of %1$@ failed: %2$@"
        ],
        "error_folder_create_failed": [
            .it: "Creazione cartella fallita: %@", .en: "Couldn't create folder: %@"
        ],
        "error_delete_failed": [
            .it: "Eliminazione fallita: %@", .en: "Deletion failed: %@"
        ],
        "error_unknown": [
            .it: "errore sconosciuto", .en: "unknown error"
        ],
        "unknown_artist": [
            .it: "Artista sconosciuto", .en: "Unknown artist"
        ],
        "unknown_album": [
            .it: "Album sconosciuto", .en: "Unknown album"
        ],
        "various_artists": [
            .it: "Artisti vari", .en: "Various artists"
        ],
        "n_albums_songs": [
            .it: "%1$d album / %2$d brani", .en: "%1$d albums / %2$d songs"
        ],
        "compilations": [
            .it: "Compilation", .en: "Compilations"
        ],
        "n_tracks": [
            .it: "%d brani", .en: "%d tracks"
        ],

        // Motivi di non trasferibilità (MusicLibraryService)
        "reason_drm": [
            .it: "Protetto da DRM", .en: "DRM protected"
        ],
        "reason_cloud_only": [
            .it: "Solo in cloud", .en: "Cloud only"
        ],
        "alert_remote_library_title": [
            .it: "Libreria su un'altra rete", .en: "Library on another network"
        ],
        "alert_remote_library_message": [
            .it: "La libreria «%@» si trova su un'altra rete: ti stai collegando da remoto.\n\nL'apertura dell'elenco usa la copia già salvata, ma ascoltare i brani o copiarli sul dispositivo potrebbe essere molto lento (o non riuscire, se il server non è raggiungibile).\n\nVuoi accedere alla libreria?",
            .en: "Library “%@” is on a different network: you are connecting remotely.\n\nThe list opens from the copy already saved, but playing songs or copying them to the device may be very slow (or fail if the server cannot be reached).\n\nDo you want to open the library?"
        ],
        "remote_network_title": [
            .it: "Rete della libreria (MAC del router)", .en: "Library network (router MAC)"
        ],
        "remote_network_hint": [
            .it: "MAC del router della rete in cui questa libreria è «locale». In un'altra rete la libreria risulta «remota». Vuoto = nessuna rete nota.", .en: "MAC address of the router of the network where this library is “local”. On any other network the library is “remote”. Empty = no known network."
        ],
        "remote_network_use_current": [
            .it: "Usa la rete attuale", .en: "Use current network"
        ],
        "remote_network_clear": [
            .it: "Rimuovi", .en: "Remove"
        ],
        "remote_network_save": [
            .it: "Salva", .en: "Save"
        ],
        "remote_network_invalid": [
            .it: "MAC non valido: servono 12 cifre esadecimali (es. aa:bb:cc:dd:ee:ff).", .en: "Invalid MAC: 12 hex digits needed (e.g. aa:bb:cc:dd:ee:ff)."
        ],
        "remote_network_none_found": [
            .it: "Nessun router riconosciuto nella rete attuale.", .en: "No router found on the current network."
        ],
        "remote_network_help_set": [
            .it: "Rete della libreria: %@ (clic per modificare)", .en: "Library network: %@ (click to edit)"
        ],
        "remote_network_offline_help": [
            .it: "Non disponibile senza connessione di rete", .en: "Not available while offline"
        ],
        "remote_network_help_unset": [
            .it: "Nessuna rete nota: clic per impostare il MAC del router", .en: "No known network: click to set the router MAC"
        ],
        "remote_network_current": [
            .it: "Rete attuale (router rilevato): %@", .en: "Current network (router detected): %@"
        ],
        "remote_network_current_none": [
            .it: "Rete attuale: router non rilevato dall'app.", .en: "Current network: router not detected by the app."
        ],
        "library_other_network": [
            .it: "altra rete", .en: "other network"
        ],
        "reason_hires": [
            .it: "Hi-Res", .en: "Hi-Res"
        ],
        "reason_file_unavailable": [
            .it: "File non disponibile", .en: "File unavailable"
        ],
        "reason_unsupported_format": [
            .it: "Formato .%@ non supportato", .en: "Format .%@ not supported"
        ],

        // Finestra di riepilogo del trasferimento
        "button_close": [
            .it: "Chiudi", .en: "Close"
        ],
        "transfer_dialog_title_tracks": [
            .it: "Trasferimento brani", .en: "Track transfer"
        ],
        "transfer_dialog_title_playlist": [
            .it: "Trasferimento playlist «%@»", .en: "Transferring playlist “%@”"
        ],
        "transfer_summary_total_header": [
            .it: "Totale di tutte le playlist", .en: "Total, all playlists"
        ],
        "transfer_playlist_transferring": [
            .it: "Trasferimento…", .en: "Transferring"
        ],
        "transfer_playlist_partial": [
            .it: "Parziale", .en: "Partially"
        ],
        "transfer_playlist_check": [
            .it: "Da controllare", .en: "Check"
        ],
        "transfer_playlist_detail": [
            .it: "%d copiati · %d già presenti · %d errori", .en: "%d copied · %d already present · %d errors"
        ],
        "transfer_status_pending": [
            .it: "In attesa", .en: "Pending"
        ],
        "transfer_status_transferred": [
            .it: "Trasferito", .en: "Transferred"
        ],
        "transfer_status_skipped": [
            .it: "Già presente", .en: "Already present"
        ],
        "transfer_status_error": [
            .it: "Errore", .en: "Error"
        ],
        "transfer_summary_selected": [
            .it: "Brani selezionati", .en: "Selected tracks"
        ],
        "alert_playlist_removal_title": [.it: "Playlist selezionata", .en: "Selected playlist"],
        // Messaggio composto: «Attenzione: stai togliendo <soggetto> presente in <playlist>. Se procedi, …».
        "alert_playlist_removal_lead": [
            .it: "Attenzione: stai togliendo %1$@ presente in %2$@.", .en: "Warning: you are removing %1$@, which is in %2$@."
        ],
        "alert_playlist_removal_lead_plural": [
            .it: "Attenzione: stai togliendo %1$@ presenti in %2$@.", .en: "Warning: you are removing %1$@, which are in %2$@."
        ],
        "alert_playlist_removal_in_one": [
            .it: "una playlist selezionata (%@)", .en: "a selected playlist (%@)"
        ],
        "alert_playlist_removal_in_many": [
            .it: "playlist selezionate (%@)", .en: "selected playlists (%@)"
        ],
        "alert_playlist_removal_tail_one": [
            .it: "Se procedi, la playlist non sarà inviata.", .en: "If you continue, the playlist will not be sent."
        ],
        "alert_playlist_removal_tail_many": [
            .it: "Se procedi, le playlist non saranno inviate.", .en: "If you continue, the playlists will not be sent."
        ],
        "alert_playlist_removal_artist_one": [.it: "l'artista «%@»", .en: "the artist “%@”"],
        "alert_playlist_removal_artists_many": [.it: "%d artisti", .en: "%d artists"],
        "alert_playlist_removal_album_one": [.it: "l'album «%@»", .en: "the album “%@”"],
        "alert_playlist_removal_albums_many": [.it: "%d album", .en: "%d albums"],
        "alert_playlist_removal_song_one": [.it: "il brano «%@»", .en: "the song “%@”"],
        "alert_playlist_removal_songs_many": [.it: "%d brani", .en: "%d songs"],
        "transfer_summary_total_header_mixed": [.it: "Totale", .en: "Total"],
        "transfer_other_songs": [.it: "Brani singoli", .en: "Single songs"],
        "transfer_summary_selected_playlists": [
            .it: "Brani nelle playlist scelte", .en: "Tracks in the selected playlists"
        ],
        "transfer_summary_transferred": [
            .it: "Brani copiati", .en: "Copied tracks"
        ],
        "transfer_summary_skipped": [
            .it: "Già presenti (non copiati)", .en: "Already present (not copied)"
        ],
        "transfer_summary_error": [
            .it: "Brani in errore", .en: "Tracks with errors"
        ],
        "transfer_status_processing": [
            .it: "In corso…", .en: "In progress…"
        ],

        // Pulsante Seleziona/Deseleziona
        "button_deselect": [
            .it: "Deseleziona", .en: "Deselect"
        ],

        // Barra della memoria
        "storage_tip": [ .it: "%@ %@", .en: "%@ %@" ],
        "storage_legend_free": [ .it: "Spazio libero", .en: "Free Space" ],
        "storage_legend_free_short": [ .it: "Libero", .en: "Free" ],
        "storage_legend_system": [
            .it: "Sistema", .en: "System"
        ],
        "storage_legend_data": [
            .it: "Dati", .en: "Data"
        ],
        "storage_legend_services": [
            .it: "Servizi", .en: "Services"
        ],
        "storage_system_help": [
            .it: "Stima: sistema e firmware del dispositivo e spazio occupato non classificabile",
            .en: "Estimate: the device's system and firmware, plus used space that can't be classified"
        ],
        "storage_data_help": [
            .it: "Attività, file di sistema dell'utente e altri dati nella cartella Garmin (mappe escluse)",
            .en: "Activities, user system files and other data in the Garmin folder (maps excluded)"
        ],
        "storage_services_help": [
            .it: "Brani scaricati dai servizi di streaming (Amazon Music, Deezer, Spotify…), come dichiarato dal dispositivo",
            .en: "Tracks downloaded by streaming services (Amazon Music, Deezer, Spotify…), as reported by the device"
        ],
        "storage_legend_used": [
            .it: "Spazio occupato", .en: "Space used"
        ],
        "storage_legend_maps": [
            .it: "Mappe", .en: "Maps"
        ],
        "storage_pending_exceeds": [
            .it: "I brani selezionati superano lo spazio libero del dispositivo",
            .en: "The selected tracks exceed the free space on the device"
        ],
        "storage_legend_music": [
            .it: "Music", .en: "Music"
        ],

        // Conferma di chiusura con dispositivo connesso
        "alert_quit_device_connected_title": [
            .it: "%@ è ancora connesso. Chiudere comunque il programma?",
            .en: "%@ is still connected. Close the app anyway?"
        ],
        "alert_quit_device_connected_message": [
            .it: "È consigliabile disconnettere il dispositivo prima di scollegarlo fisicamente dal Mac.",
            .en: "It's best to disconnect the device before physically unplugging it from the Mac."
        ],
        "alert_quit_disconnect_title": [
            .it: "Disconnettere anche il dispositivo?",
            .en: "Also disconnect the device?"
        ],
        "alert_quit_disconnect_message": [
            .it: "Si può scollegare l'orologio dal Mac in sicurezza solo dopo averlo disconnesso.",
            .en: "It's safe to unplug the watch from the Mac only after it has been disconnected."
        ],
        "button_disconnect_and_quit": [
            .it: "Disconnetti e chiudi", .en: "Disconnect and quit"
        ],
        "button_quit_without_disconnecting": [
            .it: "Chiudi comunque", .en: "Close Anyway"
        ],

        // Svuota cartella Music
        "button_empty_music_folder": [
            .it: "Svuota cartella Music del dispositivo", .en: "Empty the device's Music folder"
        ],
        "alert_empty_music_title": [
            .it: "Eliminare tutto il contenuto musicale?", .en: "Delete all music content?"
        ],
        "alert_empty_music_message": [
            .it: "Si sta per eliminare tutto il contenuto musicale su %@. Questa operazione non si può annullare.",
            .en: "You are about to delete all the music content on %@. This action can't be undone."
        ],
        "status_emptying_music": [
            .it: "Svuotamento della cartella Music del dispositivo %@…", .en: "Emptying the Music folder on the device %@…"
        ],
        "status_music_emptied": [
            .it: "Cartella Music del dispositivo %@ svuotata (la libreria di Music non è stata toccata)", .en: "Music folder on the device %@ emptied (your Music library was not touched)"
        ],

        // Invio playlist parzialmente riuscito (non blocca più la generazione del file)
        "status_playlist_sent_partial": [
            .it: "Playlist «%1$@» inviata: %2$d di %3$d brani referenziati (controlla gli errori nella finestra di trasferimento)", .en: "Playlist “%1$@” sent: %2$d of %3$d tracks referenced (check the errors in the transfer window)"
        ],
    ]
}

/// Messaggio dell'avviso «tolto un brano di una playlist scelta per intero» (`AppViewModel.checkPlaylistRemoval`, per le altre
/// schede, e `CatalogBrowser`, per la scheda Playlist): «Attenzione: stai togliendo <soggetto> presente in <playlist>. Se procedi, …».
func playlistRemovalMessage(subject: String, plural: Bool, playlists: [String]) -> String {
    let one = playlists.count == 1
    let names = playlists.joined(separator: ", ")
    let lead = t(plural ? "alert_playlist_removal_lead_plural" : "alert_playlist_removal_lead",
                 subject, t(one ? "alert_playlist_removal_in_one" : "alert_playlist_removal_in_many", names))
    return lead + " " + t(one ? "alert_playlist_removal_tail_one" : "alert_playlist_removal_tail_many")
}
