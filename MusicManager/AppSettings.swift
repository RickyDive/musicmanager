import Foundation
import SwiftUI
import AppKit
import Network

/// Impostazioni dell'app persistite tra un avvio e l'altro: quale scheda (Playlist/Album/
/// Artisti/Brani) mostrare per prima all'apertura, sia per la libreria Apple Music sia per il
/// dispositivo Garmin. Segue lo stesso pattern di `LocalizationManager`: un singleton MainActor/
/// ObservableObject cosi la finestra Impostazioni si aggiorna in diretta.
/// Una libreria remota: file XML di Musica esportato dall'altro Mac, con i file audio su una cartella montata.
struct RemoteLibraryConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Nome mostrato nel selettore delle librerie della finestra principale.
    var nickname = ""
    /// Percorso completo del file XML.
    var path = ""
    /// Cartella montata che corrisponde al «Music Folder» dell'XML (si ricava da sola, o si chiede una volta).
    var mediaPath = ""
    /// Indirizzo di rete completo del file con l'IP del computer che lo condivide (es. `smb://192.168.1.20/Musica/Libreria.xml`),
    /// ricavato dal volume montato; nil se il volume è locale o non ancora risolto. Opzionale per leggere le impostazioni vecchie.
    var networkAddress: String? = nil
    /// Segnalibro (bookmark) del file XML e della cartella dei brani: ricorda server, condivisione e percorso, e permette
    /// di ritrovare i file anche se il nome del volume cambia (es. `MacSSD-1`) e di rimontare la condivisione se non è
    /// collegata. Il percorso testuale (`path`/`mediaPath`) resta come ripiego e per la visualizzazione.
    var bookmark: Data? = nil
    var mediaBookmark: Data? = nil
    /// Identificativo della rete (MAC del router) in cui la libreria è «locale»: si memorizza quando la si aggiunge o
    /// la si apre per la prima volta. In una rete diversa (altra casa, VPN, hotspot) la libreria è «remota».
    var homeNetwork: String? = nil
    /// Nome con cui il sistema si è collegato davvero al server (es. `MacMini-ServerM2-2.local`: può differire dal nome
    /// del computer mostrato in Finder). Si ricava dal volume montato e si aggiorna a ogni montaggio; la sonda di rete lo prova per primo.
    var serverHost: String? = nil

    /// Usabile nel selettore: serve un nome e un file.
    var isUsable: Bool { !nickname.trimmingCharacters(in: .whitespaces).isEmpty && !path.isEmpty }
}

/// Una libreria «Unità esterna» (2.2): una cartella di file audio su un disco o una chiavetta, con un indice
/// JSON proprio (vedi `DriveLibraryService`). Contiene solo i brani nei formati accettati dal dispositivo Garmin scelto.
struct DriveLibraryConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Nome mostrato nel selettore delle librerie.
    var nickname = ""
    /// Cartella radice e relativo segnalibro (ritrova la cartella anche se il volume cambia nome).
    var path = ""
    var bookmark: Data? = nil
    /// Dispositivo per cui è stato creato il catalogo (Global ID, nome mostrato) e formati usati per filtrare i file.
    var deviceID = ""
    var deviceName = ""
    var extensions: [String] = []
    /// Brani e data dell'ultima scansione (per l'elenco nelle Impostazioni).
    var trackCount = 0
    var scannedAt: Date? = nil
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: Librerie remote (globali: non dipendono dal dispositivo collegato)

    /// Quali playlist di Apple Music mostrare, per tipo. Salvato a parte (vale per ogni dispositivo).
    enum PlaylistTypeFilter: String, CaseIterable, Identifiable {
        case all, regularOnly, smartOrGenius
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return t("settings_playlist_types_all")
            case .regularOnly: return t("settings_playlist_types_regular")
            case .smartOrGenius: return t("settings_playlist_types_smart_genius")
            }
        }
        func shows(_ kind: PlaylistKind?) -> Bool {
            switch self {
            case .all: return true
            case .regularOnly: return (kind ?? .regular) == .regular
            case .smartOrGenius: return (kind ?? .regular) != .regular   // 2.0.1: solo smart o Genius
            }
        }
    }
    private static let playlistTypeFilterKey = "playlist_type_filter"

    /// Colori fissi proposti per le righe selezionate (nome del testo, esadecimale RRGGBB).
    nonisolated static let highlightSwatches: [(nameKey: String, hex: String)] = [
        ("color_blue", "3478F6"), ("color_purple", "9B54A5"), ("color_pink", "E4569B"), ("color_red", "F05F5A"),
        ("color_orange", "EB8836"), ("color_yellow", "FBCB43"), ("color_green", "73B955"), ("color_graphite", "8E8E8E")
    ]

    /// Colore di selezione per uno dei colori fissi, con il 72 % di opacità: più saturo del vecchio 35 %, che su sfondo scuro sbiadiva tutti i colori.
    static func highlightColor(forSwatch hex: String) -> Color {
        Color(hex: hex + "B8") ?? Color.accentColor.opacity(0.72)
    }

    private static let showOnlyTransferableKey = "show_only_transferable"
    private static let checkDeviceUpdatesKey = "check_device_updates"
    private static let showDeviceFileManagerKey = "show_device_file_manager"
    private static let manageMusicOnVolumesKey = "manage_music_on_volumes"
    private static let detailedLogKey = "detailed_log"
    private static let airPlayAsAudioKey = "airplay_as_audio"
    private static let confirmMusicChangesKey = "confirm_music_changes"
    private static let mountRemoteAtLaunchKey = "mount_remote_libraries_at_launch"
    private static let listTextSizeKey = "list_text_size_5"
    private static let knownDevicesKey = "known_devices"

    /// Dispositivo Garmin già collegato almeno una volta, riconosciuto dal Global ID.
    struct KnownDevice: Codable, Identifiable, Equatable {
        /// Global ID (campo `Id` di GarminDevice.xml).
        var id: String
        /// Nome scelto dall'utente; vuoto = si mostra il nome del dispositivo.
        var nickname = ""
        var model = ""
        /// Come mostrata nel pannello (es. «6.49»); si aggiorna a ogni collegamento.
        var softwareVersion = ""
        /// Capacità della memoria interna in byte.
        var memoryBytes: UInt64 = 0
        /// «ID Unit» (part number).
        var unitID = ""
        /// Numero di serie di produzione (dal servizio Garmin `unit-info`); opzionale per leggere i dati salvati prima.
        var serialNumber: String? = nil
        /// Garmin ha restituito informazioni sulle mappe del dispositivo (nil = mai verificato).
        var hasMaps: Bool? = nil
        /// Esito dell'ultimo controllo del software: true = aggiornato, false = da aggiornare, nil = non controllato.
        var softwareUpToDate: Bool? = nil
        /// Immagine del prodotto scelta a mano dall'utente (indirizzo dell'elenco Garmin); nil = automatica.
        var imageURL: String? = nil
    }

    /// Global ID dei dispositivi collegati in questo momento (via MTP o come volume); lo aggiorna `AppViewModel`.
    /// Serve alla tabella Devices per il pallino verde «collegato».
    @Published var connectedDeviceIDs: Set<String> = []

    /// Dispositivi memorizzati (Impostazioni → Avanzate → Devices).
    @Published var knownDevices: [KnownDevice] {
        didSet {
            if let data = try? JSONEncoder().encode(knownDevices) {
                UserDefaults.standard.set(data, forKey: Self.knownDevicesKey)
            }
        }
    }

    /// Memorizza un dispositivo collegato o ne aggiorna i dati (modello, versione software, memoria, ID Unit; il nickname
    /// non si tocca). Vero se il dispositivo era sconosciuto, cioè va proposto il nickname.
    @discardableResult
    func recordConnectedDevice(id: String, model: String, softwareVersion: String, memoryBytes: UInt64, unitID: String) -> Bool {
        if let i = knownDevices.firstIndex(where: { $0.id == id }) {
            var d = knownDevices[i]
            d.model = model.isEmpty ? d.model : model
            if !softwareVersion.isEmpty, softwareVersion != d.softwareVersion { d.softwareUpToDate = nil }
            d.softwareVersion = softwareVersion.isEmpty ? d.softwareVersion : softwareVersion
            d.memoryBytes = memoryBytes > 0 ? memoryBytes : d.memoryBytes
            d.unitID = unitID.isEmpty ? d.unitID : unitID
            if d != knownDevices[i] { knownDevices[i] = d }
            return false
        }
        knownDevices.append(KnownDevice(id: id, nickname: "", model: model, softwareVersion: softwareVersion,
                                        memoryBytes: memoryBytes, unitID: unitID))
        return true
    }

    /// Le mappe Garmin escono circa ogni 3 mesi: dopo tanti giorni dall'ultimo controllo se ne propone uno nuovo.
    nonisolated static let mapsRecheckDays = 90

    /// Giorni trascorsi dall'ultimo controllo delle mappe (nil se non c'è un Maps.json leggibile).
    func daysSinceMapsCheck(forDevice id: String) -> Int? {
        guard let stored = DeviceXMLStore.loadMaps(forDevice: id) else { return nil }
        if stored.installed.isEmpty && (stored.available ?? []).isEmpty { return nil }   // dispositivo senza mappe: nessun ricontrollo da proporre
        return Calendar.current.dateComponents([.day], from: stored.checkedAt, to: Date()).day
    }

    /// Memorizza su file (Devices/DeviceXML/<id>/Maps.json) mappe installate e offerte con la data del controllo.
    /// Le mappe si leggono sempre e solo da questo file; Garmin si interroga alla prima connessione o a richiesta.
    func setMaps(_ catalog: GarminMapsCatalog, forDevice id: String) {
        DeviceXMLStore.saveMaps(catalog, forDevice: id)   // anche vuoto: si ricorda che Garmin non offre mappe, senza richiederle a ogni collegamento
        setHasMaps(!catalog.isEmpty, forDevice: id)
    }

    /// Vero se per il dispositivo non c'è ancora un Maps.json leggibile.
    func mapsMissing(forDevice id: String) -> Bool {
        DeviceXMLStore.loadMaps(forDevice: id) == nil
    }

    func storedMaps(forDevice id: String?) -> (catalog: GarminMapsCatalog, checkedAt: Date)? {
        guard let id, let stored = DeviceXMLStore.loadMaps(forDevice: id) else { return nil }
        return (GarminMapsCatalog(installed: stored.installed, available: stored.available ?? []), stored.checkedAt)
    }

    func setHasMaps(_ value: Bool, forDevice id: String) {
        guard let i = knownDevices.firstIndex(where: { $0.id == id }), knownDevices[i].hasMaps != value else { return }
        knownDevices[i].hasMaps = value
    }

    func setSoftwareUpToDate(_ value: Bool, forDevice id: String) {
        guard let i = knownDevices.firstIndex(where: { $0.id == id }), knownDevices[i].softwareUpToDate != value else { return }
        knownDevices[i].softwareUpToDate = value
    }

    func imageOverride(forDevice id: String?) -> String? {
        guard let id else { return nil }
        return knownDevices.first { $0.id == id }?.imageURL
    }

    func setImageOverride(_ value: String?, forDevice id: String) {
        guard let i = knownDevices.firstIndex(where: { $0.id == id }), knownDevices[i].imageURL != value else { return }
        knownDevices[i].imageURL = value
    }

    func setSerialNumber(_ serial: String, forDevice id: String) {
        guard let i = knownDevices.firstIndex(where: { $0.id == id }), knownDevices[i].serialNumber != serial else { return }
        knownDevices[i].serialNumber = serial
    }

    func serialNumber(forDevice id: String?) -> String? {
        guard let id else { return nil }
        return knownDevices.first { $0.id == id }?.serialNumber
    }

    func setNickname(_ nickname: String, forDevice id: String) {
        guard let i = knownDevices.firstIndex(where: { $0.id == id }) else { return }
        knownDevices[i].nickname = nickname
    }

    func nickname(forDevice id: String?) -> String {
        guard let id else { return "" }
        return knownDevices.first { $0.id == id }?.nickname.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Predefinito di «mostra solo i brani trasferibili» nel pannello Apple Music (acceso se non è mai stato scelto).
    @Published var showOnlyTransferable: Bool {
        didSet { UserDefaults.standard.set(showOnlyTransferable, forKey: Self.showOnlyTransferableKey) }
    }

    /// Controllo della disponibilità di un aggiornamento software del dispositivo sui server Garmin, una sola volta
    /// per avvio dell'app. Spento di default: invia a Garmin il contenuto di GarminDevice.xml (vedi `GarminUpdateService`).
    @Published var checkDeviceUpdates: Bool {
        didSet { UserDefaults.standard.set(checkDeviceUpdates, forKey: Self.checkDeviceUpdatesKey) }
    }

    /// Mostra il pulsante del file manager del dispositivo (navigatore dei file in sola lettura, 2.1 Beta 3). Spento di default (si attiva in Impostazioni ▸ Avanzate).
    @Published var showDeviceFileManager: Bool {
        didSet { UserDefaults.standard.set(showDeviceFileManager, forKey: Self.showDeviceFileManagerKey) }
    }

    /// Gestione della musica sui dispositivi visti come disco (archiviazione di massa, scheda SD, immagine disco): accanto a
    /// «Espelli» compare «Connetti», che apre il volume come un dispositivo (2.1 Beta 3, sperimentale). Spento di default.
    @Published var manageMusicOnVolumes: Bool {
        didSet { UserDefaults.standard.set(manageMusicOnVolumes, forKey: Self.manageMusicOnVolumesKey) }
    }

    /// AirPlay «come audio» (2.1 Beta 3, sperimentale): il player non usa la «riproduzione esterna» (l'Apple TV riceve il file e lo
    /// riproduce da sé) ma manda l'audio al dispositivo come fa con un ampli AirPlay. Serve a provare se così il volume dell'Apple TV
    /// resta regolabile (il cursore del pannello AirPlay di sistema sparisce con la riproduzione esterna). Acceso di default (2.1 Beta 3).
    @Published var airPlayAsAudio: Bool {
        didSet { UserDefaults.standard.set(airPlayAsAudio, forKey: Self.airPlayAsAudioKey) }
    }

    /// Chiede conferma prima di aggiungere brani alla libreria di Music (file trascinati dal Finder, brani di una libreria esterna
    /// che si salvano in una playlist di Music). Acceso di default (2.2); spento = si aggiunge senza chiedere.
    /// Montaggio automatico all'avvio dei volumi di rete delle librerie remote. Spento di default: con reti lente o assenti
    /// appesantisce la partenza; spento, all'avvio si fa solo un sondaggio leggero e il volume si monta alla scelta della libreria.
    @Published var mountRemoteLibrariesAtLaunch: Bool {
        didSet { UserDefaults.standard.set(mountRemoteLibrariesAtLaunch, forKey: Self.mountRemoteAtLaunchKey) }
    }

    @Published var confirmBeforeMusicChanges: Bool {
        didSet { UserDefaults.standard.set(confirmBeforeMusicChanges, forKey: Self.confirmMusicChangesKey) }
    }

    /// Registro dettagliato (2.1 Beta 3): oltre agli eventi di sempre scrive le righe di diagnostica (`AppLog.debug`), per esempio
    /// i dettagli del volume AirPlay o dei volumi usati come dispositivo. Spento di default; il file resta sul Mac.
    @Published var detailedLog: Bool {
        didSet {
            UserDefaults.standard.set(detailedLog, forKey: Self.detailedLogKey)
            AppLog.detailed = detailedLog
            AppLog.write("Log level: " + (detailedLog ? "detailed" : "normal"), force: true)
        }
    }

    /// Thread usati per leggere la libreria di Music (2.2): 8 = «Multi thread» (predefinito), 1 = «Single thread» (una
    /// richiesta alla volta, utile se Music rallenta durante la lettura). Altri valori salvati prima tornano a 8.
    nonisolated static let libraryReadThreadsKey = "library_read_threads"
    @Published var libraryReadThreads: Int {
        didSet { UserDefaults.standard.set(libraryReadThreads, forKey: Self.libraryReadThreadsKey) }
    }

    /// Dimensione del testo della prima riga degli elenchi (titolo di playlist/artista/album/brano). Medio = quella di sempre.
    enum ListTextSize: Int, CaseIterable, Identifiable {
        case extraSmall = 0, small = 1, medium = 2, large = 3, extraLarge = 4
        var id: Int { rawValue }
        /// Corpo del testo in punti (macOS: il testo normale è 13 pt). Sul cursore compaiono solo tre nomi:
        /// Extra small (la prima posizione), Medium (la centrale) e Large (l'ultima).
        var points: CGFloat {
            switch self {
            case .extraSmall: return 10
            case .small: return 11.5
            case .medium: return 13
            case .large: return 14.5
            case .extraLarge: return 16
            }
        }
    }

    @Published var listTextSize: ListTextSize {
        didSet { UserDefaults.standard.set(listTextSize.rawValue, forKey: Self.listTextSizeKey) }
    }

    @Published var playlistTypeFilter: PlaylistTypeFilter {
        didSet { UserDefaults.standard.set(playlistTypeFilter.rawValue, forKey: Self.playlistTypeFilterKey) }
    }

    static let maxDriveLibraries = 3
    private static let driveLibrariesKey = "drive_libraries"

    /// Librerie «Unità esterna» (2.2). Tolta una libreria si cancella anche il suo indice.
    @Published var driveLibraries: [DriveLibraryConfig] {
        didSet {
            for removed in oldValue where !driveLibraries.contains(where: { $0.id == removed.id }) {
                DriveLibraryService.removeIndex(removed.id)
            }
            if let data = try? JSONEncoder().encode(driveLibraries) {
                UserDefaults.standard.set(data, forKey: Self.driveLibrariesKey)
            }
        }
    }

    /// Aggiorna una libreria «Unità esterna» per id (se esiste ancora).
    func updateDriveLibrary(_ id: UUID, _ change: (inout DriveLibraryConfig) -> Void) {
        guard let i = driveLibraries.firstIndex(where: { $0.id == id }) else { return }
        change(&driveLibraries[i])
    }

    static let maxRemoteLibraries = 3
    private static let remoteLibrariesKey = "remote_libraries"

    @Published var remoteLibraries: [RemoteLibraryConfig] {
        didSet {
            // Libreria tolta: si cancella anche la sua copia compatta in «External Library» (salvo se un'altra libreria
            // usa lo stesso file XML).
            let remaining = Set(remoteLibraries.map(\.path))
            for removed in oldValue where !remoteLibraries.contains(where: { $0.id == removed.id }) && !remaining.contains(removed.path) {
                ExternalParsed.removeCache(forXMLPath: removed.path)
            }
            if let data = try? JSONEncoder().encode(remoteLibraries) {
                UserDefaults.standard.set(data, forKey: Self.remoteLibrariesKey)
            }
        }
    }

    /// Ricava (in background, la risoluzione del nome può richiedere tempo) l'indirizzo di rete completo con IP
    /// della libreria `id` e lo salva. Per un volume locale resta nil e nell'elenco si vede il percorso.
    func refreshNetworkAddress(for id: UUID) {
        guard let cfg = remoteLibraries.first(where: { $0.id == id }), !cfg.path.isEmpty else { return }
        let path = cfg.path
        let bookmark = cfg.bookmark
        Task { [weak self] in
            let (address, host) = await Task.detached(priority: .utility) { () -> (String?, String?) in
                // Due condivisioni con lo stesso nome («MacSSD» su Milano e su Mare) prendono punti di montaggio diversi a ogni
                // montaggio (/Volumes/MacSSD, /Volumes/MacSSD-1): il percorso salvato può essere quello vecchio, o di un'altra libreria.
                // Il segnalibro dà il punto attuale (senza montare nulla).
                let current = bookmark.flatMap { FileBookmark.resolve($0, mounting: false)?.url.path } ?? path
                let target = FileManager.default.fileExists(atPath: current) ? current : path
                return (NetworkAddress.resolve(path: target), NetworkAddress.serverHost(forPath: target))
            }.value
            guard let self, let i = self.remoteLibraries.firstIndex(where: { $0.id == id }),
                  self.remoteLibraries[i].path == path else { return }
            // Mai si cancella un indirizzo già noto: se il volume non è montato o il percorso è vecchio la risoluzione dà nil
            // e l'indirizzo smb:// va conservato (serve per rimontare la libreria).
            if let address, self.remoteLibraries[i].networkAddress != address { self.remoteLibraries[i].networkAddress = address }
            if let host, self.remoteLibraries[i].serverHost != host { self.remoteLibraries[i].serverHost = host }
        }
    }

    /// Memorizza la rete corrente (MAC del router) come rete «di casa» della libreria `id`, se ne è disponibile una.
    func refreshHomeNetwork(for id: UUID) {
        Task { [weak self] in
            guard let network = await Task.detached(priority: .utility, operation: { NetworkIdentity.currentRouterID() }).value,
                  let self, let i = self.remoteLibraries.firstIndex(where: { $0.id == id }) else { return }
            self.remoteLibraries[i].homeNetwork = network
        }
    }

    func setHomeNetwork(_ network: String, for id: UUID) {
        guard let i = remoteLibraries.firstIndex(where: { $0.id == id }), remoteLibraries[i].homeNetwork == nil else { return }
        remoteLibraries[i].homeNetwork = network
    }

    /// Aggiorna cartella dei brani (percorso e, se noto, segnalibro) di una libreria remota.
    func setMediaLocation(path: String, bookmark: Data?, for id: UUID) {
        guard let i = remoteLibraries.firstIndex(where: { $0.id == id }) else { return }
        if remoteLibraries[i].mediaPath != path { remoteLibraries[i].mediaPath = path }
        if let bookmark { remoteLibraries[i].mediaBookmark = bookmark }
    }

    /// Aggiorna il file XML (percorso e, se noto, segnalibro) di una libreria remota.
    func setXMLLocation(path: String, bookmark: Data?, for id: UUID) {
        guard let i = remoteLibraries.firstIndex(where: { $0.id == id }) else { return }
        if remoteLibraries[i].path != path {
            remoteLibraries[i].path = path
            // Il punto di montaggio cambia (MacSSD → MacSSD-1) ma il server è lo stesso: l'indirizzo smb:// resta, si aggiorna soltanto.
            refreshNetworkAddress(for: id)
        }
        if let bookmark { remoteLibraries[i].bookmark = bookmark }
    }

    /// Insieme delle impostazioni dell'applicazione: sono tutte globali (lingua, aspetto, colore di selezione, opacità,
    /// elenco iniziale, opzioni Artwork), uguali per ogni dispositivo. Dalla 2.1 Beta 2 non esistono più profili per dispositivo.
    struct Profile: Codable, Equatable {
        var appearance: String
        var language: String
        var defaultCategory: String
        var highlightColor: String
        var lookupMissingArtworkOnline: Bool
        /// Opacità dello sfondo della finestra principale (0 = tutto vetro, 1 = pieno). Opzionale per
        /// leggere senza problemi i profili salvati prima che esistesse.
        var windowOpacity: Double? = nil
        /// Caricamento automatico delle copertine da Apple Music (espandendo gruppi / selezionando brani).
        /// Opzionale per leggere i profili salvati prima; assente = attivo.
        var autoLoadAppleArtwork: Bool? = nil
        /// Per i brani senza copertina di una libreria condivisa, proporre la ricerca online prima di inviarli
        /// all'orologio o alla Custom Playlist. Opzionale (profili vecchi); assente = attivo.
        var proposeSharedArtworkSearch: Bool? = nil

        /// Predefiniti: Aspetto Sistema, Lingua del sistema (italiano se il sistema è in italiano, altrimenti English), Elenco iniziale Playlist, Colore di selezione
        /// Tint (colore di sistema, 35 % di opacità), Fix Artwork disattivato.
        static var defaults: Profile {
            Profile(appearance: Appearance.system.rawValue,
                    language: AppLanguage.systemDefault.rawValue,
                    defaultCategory: CatalogCategory.playlists.rawValue,
                    highlightColor: Color.accentColor.opacity(0.35).toHex(),
                    lookupMissingArtworkOnline: false,
                    windowOpacity: AppSettings.defaultWindowOpacity,
                    autoLoadAppleArtwork: true,
                    proposeSharedArtworkSearch: true)
        }
    }

    /// Chiave dei vecchi profili per dispositivo (fino alla 2.1 Beta 1): non si usa più, si cancella all'avvio.
    private static let obsoleteProfilesKey = "device_settings_profiles"
    /// Le impostazioni globali dell'app. Si salvano a ogni modifica e si applicano all'apertura dell'app.
    private static let generalKey = "general_settings_profile"

    private static func loadGeneralProfile() -> Profile {
        guard let data = UserDefaults.standard.data(forKey: generalKey),
              let profile = try? JSONDecoder().decode(Profile.self, from: data) else { return .defaults }
        return profile
    }
    private var isApplying = false

    /// Aspetto dell'intera applicazione (finestre, Impostazioni, finestre di dialogo): chiaro, scuro
    /// oppure "Sistema", che segue l'impostazione Aspetto di macOS. Applicato a `NSApp.appearance`
    /// (nil = segue il sistema), così cambia tutto e non solo la finestra principale.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return t("settings_appearance_system")
            case .light: return t("settings_appearance_light")
            case .dark: return t("settings_appearance_dark")
            }
        }

        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    @Published var appearance: Appearance {
        didSet {
            applyAppearance()
            saveActiveProfile()
        }
    }

    /// Applica l'aspetto scelto a tutta l'app. Richiamata a ogni cambio e all'avvio.
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
        // Allinea il wrapper della lingua a quella caricata all'avvio (se fosse stato creato prima).
        if LocalizationManager.shared.language != LocalizationStore.language {
            LocalizationManager.shared.language = LocalizationStore.language
        }
    }

    @Published var defaultCategory: CatalogCategory {
        didSet { saveActiveProfile() }
    }

    /// Colore di sfondo delle righe selezionate nelle schede Playlist/Artisti/Album/Brani di Apple
    /// Music, scelto in Impostazioni con un `ColorPicker`. `Color` non si salva direttamente in
    /// `UserDefaults`: si converte in una stringa esadecimale (vedi l'estensione più sotto).
    @Published var highlightColor: Color {
        didSet { saveActiveProfile() }
    }

    /// Se attivo, il menu contestuale (click destro) sui brani offre "Fix Artwork" (finestra
    /// `FixArtworkView`: cerca online una copertina, la mostra accanto all'originale e la
    /// memorizza solo se l'utente conferma), e agli invii all'orologio si applicano le copertine già
    /// confermate scrivendole in una copia temporanea del file, mai nell'originale della libreria.
    /// Spento di default: la ricerca comporta chiamate di rete verso un servizio esterno con
    /// titolo/artista dei brani, quindi va acceso esplicitamente dall'utente (vedi l'alert di
    /// spiegazione in `SettingsView`, mostrato la prima volta che si accende).
    @Published var lookupMissingArtworkOnline: Bool {
        didSet { saveActiveProfile() }
    }

    /// Se attivo, le copertine di Apple Music si caricano da sole (vedi `AppViewModel.loadMissingArtwork`);
    /// altrimenti si chiedono dal menu contestuale (click destro).
    @Published var autoLoadAppleArtwork: Bool {
        didSet { saveActiveProfile() }
    }

    /// Se attivo (e Fix Artwork online è attivo), inviando all'orologio o alla Custom Playlist brani di una
    /// libreria condivisa senza copertina, l'app propone la ricerca online e apre il pannello Artwork.
    @Published var proposeSharedArtworkSearch: Bool {
        didSet { saveActiveProfile() }
    }

    /// Opacità predefinita dello sfondo della finestra principale.
    nonisolated static let defaultWindowOpacity = 0.45

    /// Quanto è "pieno" lo sfondo della finestra principale: 0 = solo materiale traslucido (come
    /// prima), 1 = colore di finestra opaco. Si regola in Impostazioni con un cursore.
    @Published var windowOpacity: Double {
        didSet { saveActiveProfile() }
    }

    /// All'apertura: il profilo generale salvato (o i predefiniti la prima volta); collegando un dispositivo
    /// si passa al suo profilo.
    private init() {
        let d = Self.loadGeneralProfile()
        // Lingua: si imposta l'archivio globale (non il wrapper, che richiamerebbe `shared` durante l'init).
        LocalizationStore.language = AppLanguage(rawValue: d.language) ?? .systemDefault
        LocalizationStore.applySystemMenuLanguage()
        UserDefaults.standard.removeObject(forKey: Self.obsoleteProfilesKey)   // i profili per dispositivo non esistono più
        appearance = Appearance(rawValue: d.appearance) ?? .system
        defaultCategory = CatalogCategory(rawValue: d.defaultCategory) ?? .playlists
        highlightColor = Color(hex: d.highlightColor) ?? Color.accentColor.opacity(0.35)
        lookupMissingArtworkOnline = d.lookupMissingArtworkOnline
        windowOpacity = d.windowOpacity ?? Self.defaultWindowOpacity
        autoLoadAppleArtwork = d.autoLoadAppleArtwork ?? true
        proposeSharedArtworkSearch = d.proposeSharedArtworkSearch ?? true
        playlistTypeFilter = PlaylistTypeFilter(rawValue: UserDefaults.standard.string(forKey: Self.playlistTypeFilterKey) ?? "") ?? .all
        showOnlyTransferable = UserDefaults.standard.object(forKey: Self.showOnlyTransferableKey) as? Bool ?? true
        checkDeviceUpdates = UserDefaults.standard.object(forKey: Self.checkDeviceUpdatesKey) as? Bool ?? false
        showDeviceFileManager = UserDefaults.standard.object(forKey: Self.showDeviceFileManagerKey) as? Bool ?? false
        manageMusicOnVolumes = UserDefaults.standard.object(forKey: Self.manageMusicOnVolumesKey) as? Bool ?? false
        airPlayAsAudio = UserDefaults.standard.object(forKey: Self.airPlayAsAudioKey) as? Bool ?? true
        confirmBeforeMusicChanges = UserDefaults.standard.object(forKey: Self.confirmMusicChangesKey) as? Bool ?? true
        mountRemoteLibrariesAtLaunch = UserDefaults.standard.object(forKey: Self.mountRemoteAtLaunchKey) as? Bool ?? false
        libraryReadThreads = (UserDefaults.standard.object(forKey: Self.libraryReadThreadsKey) as? Int) == 1 ? 1 : 8
        let savedDetailedLog = UserDefaults.standard.object(forKey: Self.detailedLogKey) as? Bool ?? false
        detailedLog = savedDetailedLog
        AppLog.detailed = savedDetailedLog
        listTextSize = (UserDefaults.standard.object(forKey: Self.listTextSizeKey) as? Int).flatMap(ListTextSize.init(rawValue:)) ?? .medium
        if let data = UserDefaults.standard.data(forKey: Self.knownDevicesKey),
           let saved = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            knownDevices = saved
        } else {
            knownDevices = []
        }
        if let data = UserDefaults.standard.data(forKey: Self.remoteLibrariesKey),
           let saved = try? JSONDecoder().decode([RemoteLibraryConfig].self, from: data) {
            remoteLibraries = Array(saved.prefix(Self.maxRemoteLibraries))
        } else {
            remoteLibraries = []
        }
        if let data = UserDefaults.standard.data(forKey: Self.driveLibrariesKey),
           let saved = try? JSONDecoder().decode([DriveLibraryConfig].self, from: data) {
            driveLibraries = Array(saved.prefix(Self.maxDriveLibraries))
        } else {
            driveLibraries = []
        }
    }

    // MARK: Impostazioni globali

    private var currentProfile: Profile {
        Profile(appearance: appearance.rawValue,
                language: LocalizationManager.shared.language.rawValue,
                defaultCategory: defaultCategory.rawValue,
                highlightColor: highlightColor.toHex(),
                lookupMissingArtworkOnline: lookupMissingArtworkOnline,
                windowOpacity: windowOpacity,
                autoLoadAppleArtwork: autoLoadAppleArtwork,
                proposeSharedArtworkSearch: proposeSharedArtworkSearch)
    }

    /// Applica le impostazioni senza salvarle (le modifiche ai singoli valori non devono riscriverle).
    private func apply(_ p: Profile) {
        isApplying = true
        LocalizationManager.shared.language = AppLanguage(rawValue: p.language) ?? .systemDefault
        defaultCategory = CatalogCategory(rawValue: p.defaultCategory) ?? .playlists
        lookupMissingArtworkOnline = p.lookupMissingArtworkOnline
        autoLoadAppleArtwork = p.autoLoadAppleArtwork ?? true
        proposeSharedArtworkSearch = p.proposeSharedArtworkSearch ?? true
        appearance = Appearance(rawValue: p.appearance) ?? .system
        highlightColor = Color(hex: p.highlightColor) ?? Color.accentColor.opacity(0.35)
        windowOpacity = p.windowOpacity ?? Self.defaultWindowOpacity
        isApplying = false
        applyAppearance()
    }

    /// Riporta tutte le impostazioni ai valori predefiniti (lingua = quella del sistema). Non tocca le librerie
    /// condivise, i dispositivi memorizzati né la cache delle copertine.
    func resetAllSettings() {
        UserDefaults.standard.removeObject(forKey: Self.generalKey)
        playlistTypeFilter = .all
        showOnlyTransferable = true
        checkDeviceUpdates = false
        showDeviceFileManager = false
        manageMusicOnVolumes = false
        detailedLog = false
        libraryReadThreads = 8
        airPlayAsAudio = true
        confirmBeforeMusicChanges = true
        mountRemoteLibrariesAtLaunch = false
        listTextSize = .medium
        apply(.defaults)
        saveActiveProfile()
    }

    /// Salva i valori correnti: tutte le impostazioni dell'app sono globali, un solo profilo.
    func saveActiveProfile() {
        guard !isApplying else { return }
        if let data = try? JSONEncoder().encode(currentProfile) {
            UserDefaults.standard.set(data, forKey: Self.generalKey)
        }
    }
}

extension Color {
    /// Ricostruisce un colore da una stringa esadecimale RRGGBBAA salvata da `toHex()`. Restituisce
    /// nil se la stringa non è valida (es. prima installazione, nessun valore salvato).
    init?(hex: String) {
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value), hex.count == 8 else { return nil }
        let r = Double((value & 0xFF000000) >> 24) / 255
        let g = Double((value & 0x00FF0000) >> 16) / 255
        let b = Double((value & 0x0000FF00) >> 8) / 255
        let a = Double(value & 0x000000FF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Converte il colore in una stringa esadecimale RRGGBBAA, per poterlo salvare in
    /// `UserDefaults` (che non supporta `Color` direttamente).
    func toHex() -> String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = UInt64(round(nsColor.redComponent * 255))
        let g = UInt64(round(nsColor.greenComponent * 255))
        let b = UInt64(round(nsColor.blueComponent * 255))
        let a = UInt64(round(nsColor.alphaComponent * 255))
        return String(format: "%02X%02X%02X%02X", r, g, b, a)
    }
}


/// Ricava l'indirizzo di rete di un file su un volume montato (SMB, AFP, NFS, WebDAV) con l'IP del server al posto
/// del nome: dal punto di montaggio (`statfs`) si legge «da dove» è montato il volume e il nome del server si risolve in IP.
/// Stato di raggiungibilità delle librerie condivise configurate: per quelle su un volume di rete si prova a
/// collegarsi al server (porta SMB/AFP/NFS) con un breve tempo massimo; per le altre si controlla che il file esista.
/// Si aggiorna all'avvio, a ogni cambio di rete, quando si aprono le Impostazioni e ogni 30 secondi. Finché non è
/// noto, una libreria non risulta mai «non raggiungibile» (nulla viene bloccato senza motivo).
@MainActor
final class LibraryReachability: ObservableObject {
    static let shared = LibraryReachability()
    @Published private(set) var reachable: [UUID: Bool] = [:]
    /// Libreria con il file XML leggibile adesso (volume montato). Calcolato fuori dal thread principale insieme alla sonda.
    @Published private(set) var mounted: [UUID: Bool] = [:]
    /// Falso quando il Mac non ha nessuna connessione di rete (aggiornato dal monitor di rete).
    @Published private(set) var isOnline = true
    /// Diagnosi dell'ultima verifica per libreria (file presente / server che risponde), per il tooltip.
    @Published private(set) var details: [UUID: String] = [:]
    private var loop: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    /// Vero solo se si è verificato che la libreria non risponde.
    func isUnreachable(_ id: UUID) -> Bool { reachable[id] == false }
    func isMounted(_ id: UUID) -> Bool { mounted[id] == true }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if self?.isOnline ?? true { await self?.refresh() }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    /// Chiamato a ogni cambio di rete. Offline: tutte le librerie con server di rete risultano non raggiungibili subito.
    /// Di nuovo online: subito dopo il ritorno la rete non è ancora pronta (DNS, SMB), quindi la verifica si ripete a
    /// distanza (2, 5, 10, 20 s) finché tutte le librerie rispondono: prima ne risultava attiva solo qualcuna.
    func pathChanged(online: Bool) {
        isOnline = online
        retryTask?.cancel()
        guard online else {
            var all: [UUID: Bool] = [:]
            for cfg in AppSettings.shared.remoteLibraries.filter(\.isUsable) { all[cfg.id] = false }
            reachable = all
            return
        }
        retryTask = Task { [weak self] in
            for delay in [2, 5, 10, 20] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                if Task.isCancelled { return }
                await self?.refresh()
                if let self, !self.reachable.values.contains(false) { return }
            }
        }
    }

    /// Vero se il server della libreria risponde sulla porta (o il file è già leggibile): una sola verifica, senza aggiornare lo stato.
    func serverResponds(_ cfg: RemoteLibraryConfig) async -> Bool {
        await Self.check(cfg).0
    }

    func refresh() async {
        let libraries = AppSettings.shared.remoteLibraries.filter(\.isUsable)
        var result: [UUID: Bool] = [:]
        var texts: [UUID: String] = [:]
        var mountedNow: [UUID: Bool] = [:]
        await withTaskGroup(of: (UUID, Bool, String, Bool).self) { group in
            for cfg in libraries { group.addTask { let r = await Self.check(cfg); return (cfg.id, r.0, r.1, r.2) } }
            for await (id, ok, text, isMounted) in group { result[id] = ok; texts[id] = text; mountedNow[id] = isMounted }
        }
        if mountedNow != mounted { mounted = mountedNow }
        if result != reachable { reachable = result }
        if texts != details { details = texts }
    }

    /// Raggiungibile se il file della libreria è leggibile (volume montato) **oppure** il server risponde sulla porta
    /// (il volume si rimonta da solo alla scelta). Prima contava solo la sonda TCP: se l'indirizzo non era un host
    /// utilizzabile (nome Bonjour, spazi) la libreria risultava «non raggiungibile» pur essendo montata.
    /// Restituisce anche un testo di diagnosi, mostrato nel tooltip dell'icona in Impostazioni.
    nonisolated private static func check(_ cfg: RemoteLibraryConfig) async -> (Bool, String, Bool) {
        let fileOK = FileManager.default.fileExists(atPath: cfg.path)
        let fileText = "file: " + (fileOK ? "presente" : "assente")
        // Volume locale (nessun indirizzo di rete): basta che il file ci sia.
        guard let address = cfg.networkAddress, let schemeRange = address.range(of: "://") else {
            return (fileOK, fileText, fileOK)
        }
        let scheme = String(address[..<schemeRange.lowerBound])
        let rest = address[schemeRange.upperBound...]
        let host = String(rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
        guard !host.isEmpty else { return (fileOK, fileText, fileOK) }
        // Con il file già leggibile non serve provare la rete.
        if fileOK { return (true, fileText, true) }
        let (hosts, ports) = hostsAndPorts(cfg, scheme: scheme, host: host)
        for candidate in hosts {
            for port in ports {
                if await probe(host: candidate, port: port) { return (true, fileText + "; \(candidate):\(port) risponde", false) }
            }
        }
        return (false, fileText + "; \(host) non risponde su porta " + ports.map(String.init).joined(separator: "/"), false)
    }

    /// Nomi da provare e porte del protocollo. Nomi Bonjour / del Mac: «MacMini ServerM2» (con spazi) non si risolve come tale
    /// in rete, ma il Mac risponde come «MacMini-ServerM2-2.local» (nome vero salvato in `serverHost`); un nome semplice si prova
    /// anche con «.local».
    nonisolated private static func hostsAndPorts(_ cfg: RemoteLibraryConfig, scheme: String, host: String) -> ([String], [UInt16]) {
        let ports: [UInt16]
        switch scheme {
        case "smb": ports = [445, 139]
        case "afp": ports = [548]
        case "nfs": ports = [2049]
        default: ports = [80, 443]
        }
        var hosts: [String] = []
        for h in [cfg.serverHost, host].compactMap({ $0 }) where !h.isEmpty && !hosts.contains(h) { hosts.append(h) }
        if host.contains(" ") || !host.contains(".") {
            let bonjour = host.replacingOccurrences(of: " ", with: "-") + (host.hasSuffix(".local") ? "" : ".local")
            if !hosts.contains(bonjour) { hosts.append(bonjour) }
        }
        return (hosts, ports)
    }

    /// Il nome del server che risponde davvero (primo dei candidati con la porta aperta), o nil. Serve a montare con quel nome
    /// e non con quello mostrato dal Finder, che può non risolversi (e far attendere il sistema oltre 2 minuti).
    func respondingHost(_ cfg: RemoteLibraryConfig) async -> String? {
        guard let address = cfg.networkAddress, let schemeRange = address.range(of: "://") else { return nil }
        let scheme = String(address[..<schemeRange.lowerBound])
        let host = String(address[schemeRange.upperBound...].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
        guard !host.isEmpty else { return nil }
        let (hosts, ports) = Self.hostsAndPorts(cfg, scheme: scheme, host: host)
        for candidate in hosts {
            for port in ports {
                if await Self.probe(host: candidate, port: port) { return candidate }
            }
        }
        return nil
    }

    /// Un tentativo di connessione TCP con tempo massimo di 2,5 secondi (`.waiting` non è un errore: la rete può ancora ripartire).
    nonisolated private static func probe(host: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        return await withCheckedContinuation { cont in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "MusicManager.reachability", qos: .utility)
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { ok in
                guard once.first() else { return }
                connection.cancel()
                cont.resume(returning: ok)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2.5) { finish(false) }
        }
    }
}

enum NetworkAddress {
    /// Nil se il file sta su un volume locale. Può bloccare (risoluzione DNS): da chiamare fuori dal thread principale.
    nonisolated static func resolve(path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        func text<T>(_ value: T) -> String {
            withUnsafeBytes(of: value) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
        }
        let fsType = text(fs.f_fstypename)
        let from = text(fs.f_mntfromname)
        let mountPoint = text(fs.f_mntonname)

        var host = ""
        var share = ""
        if from.hasPrefix("//") {
            // «//utente@server/condivisione» (SMB, AFP, WebDAV): si toglie l'eventuale utente.
            var rest = String(from.dropFirst(2))
            if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
            let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            host = parts.first.map(String.init) ?? ""
            share = parts.count > 1 ? String(parts[1]) : ""
        } else if let colon = from.firstIndex(of: ":"), fsType == "nfs" {
            // NFS: «server:/esportazione».
            host = String(from[..<colon])
            share = String(from[from.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            return nil
        }
        host = host.removingPercentEncoding ?? host
        share = share.removingPercentEncoding ?? share
        // Nome Bonjour («Server._smb._tcp.local»): resta solo il nome.
        if let bonjour = host.components(separatedBy: "._").first { host = bonjour }
        guard !host.isEmpty else { return nil }

        let scheme = ["smbfs": "smb", "afpfs": "afp", "nfs": "nfs", "webdav": "http"][fsType] ?? fsType
        let relative = path.hasPrefix(mountPoint) ? String(path.dropFirst(mountPoint.count)) : ""
        let shareAndPath = (share.isEmpty ? "" : "/" + share) + relative
        // Il nome si risolve in IP provando alcune varianti (con «.local», minuscolo); se il DNS non risponde, si
        // ricorre alla connessione SMB/AFP già aperta verso il server (porta 445/139/548), se è una sola.
        // «MacMini at Sea» è il nome del servizio Bonjour (con spazi), non un nome di computer: si provano anche le
        // forme che macOS usa per il nome host («MacMini-at-Sea.local»).
        let dashed = host.replacingOccurrences(of: " ", with: "-")
        // Per SMB si chiede al sistema il nome vero del server (può essere «MacMini-ServerM2-2.local»): si prova per primo.
        let actual = scheme == "smb" ? smbServerName(mountPoint: mountPoint) : nil
        let candidates = ([actual].compactMap { $0 } + [host, host.lowercased(), dashed + ".local", dashed.lowercased() + ".local"])
            .filter { !$0.isEmpty }
        var address: String?
        for name in candidates { if let found = ip(forHost: name) { address = found; break } }
        if address == nil, scheme == "smb" || scheme == "afp" { address = establishedPeerIP(ports: scheme == "smb" ? [445, 139] : [548]) }
        return "\(scheme)://\(address ?? host)\(shareAndPath)"
    }

    /// Nome vero del server di un volume SMB montato (colonna SERVER_NAME di `smbutil statshares -m`); nil se non disponibile.
    nonisolated static func smbServerName(mountPoint: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        process.arguments = ["statshares", "-m", mountPoint]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") where line.contains("SERVER_NAME") {
            if let last = line.split(separator: " ", omittingEmptySubsequences: true).last, last != "SERVER_NAME" { return String(last) }
        }
        return nil
    }

    /// Nome vero del server per il file indicato (volume SMB montato), per la sonda di rete. Fuori dal thread principale.
    nonisolated static func serverHost(forPath path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let mountPoint = withUnsafeBytes(of: fs.f_mntonname) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let fsType = withUnsafeBytes(of: fs.f_fstypename) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return fsType == "smbfs" ? smbServerName(mountPoint: mountPoint) : nil
    }

    /// IP del server della connessione di file sharing già stabilita (`netstat`): usato solo se il nome non si
    /// risolve. Vale solo se c'è un unico server collegato su quelle porte, altrimenti nil (non si può sapere quale).
    private nonisolated static func establishedPeerIP(ports: [Int]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-an", "-p", "tcp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var peers = Set<String>()
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") where line.contains("ESTABLISHED") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            // L'indirizzo remoto è la colonna prima dello stato (es. 192.168.1.20.445).
            guard let stateIndex = cols.firstIndex(where: { $0 == "ESTABLISHED" }), stateIndex >= 1 else { continue }
            let foreign = String(cols[stateIndex - 1])
            guard let dot = foreign.lastIndex(of: "."), let port = Int(foreign[foreign.index(after: dot)...]),
                  ports.contains(port) else { continue }
            peers.insert(String(foreign[..<dot]))
        }
        return peers.count == 1 ? peers.first : nil
    }

    /// IPv4 del nome (preferita, più leggibile); se è già un indirizzo lo lascia com'è.
    private nonisolated static func ip(forHost host: String) -> String? {
        var buf4 = in_addr(), buf6 = in6_addr()
        if inet_pton(AF_INET, host, &buf4) == 1 || inet_pton(AF_INET6, host, &buf6) == 1 { return host }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var chosen: UnsafeMutablePointer<addrinfo>? = nil
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let c = cursor {
            if c.pointee.ai_family == AF_INET { chosen = c; break }
            if chosen == nil { chosen = c }
            cursor = c.pointee.ai_next
        }
        guard let info = chosen else { return nil }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &name, socklen_t(name.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: name)
    }
}


/// Segnalibri di file o cartelle (come gli alias del Finder). Creare o risolvere un segnalibro può toccare la rete e,
/// se il volume non è montato, il sistema prova a rimontarlo (può chiedere le credenziali): da usare fuori dal main thread.
enum FileBookmark {
    nonisolated static func make(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Posizione attuale del file/cartella e se il segnalibro è «vecchio» (conviene rifarlo). Nil se non si ritrova.
    /// `mounting: false` non fa rimontare il volume al sistema e non mostra finestre: serve nel montaggio all'avvio, dove il
    /// segnalibro ritrova il server con il nome vecchio («MacMini ServerM2») e il sistema può restare bloccato oltre un minuto.
    nonisolated static func resolve(_ data: Data, mounting: Bool = true) -> (url: URL, stale: Bool)? {
        var stale = false
        let options: URL.BookmarkResolutionOptions = mounting ? [] : [.withoutMounting, .withoutUI]
        guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
}


/// Identifica la rete a cui il Mac è collegato dal MAC del router (gateway predefinito sull'interfaccia fisica `enX`):
/// stabile per ogni rete, non richiede permessi. Una VPN (interfaccia `utunX`) o un hotspot del telefono hanno un altro
/// router, quindi risultano reti diverse.
enum NetworkIdentity {
    /// Nil se non c'è rete o non si ricava il MAC. Lancia piccoli comandi di sistema: fuori dal main thread.
    nonisolated static func currentRouterID() -> String? {
        for gateway in gatewayCandidates() {
            if let mac = macAddress(of: gateway) { return mac }
        }
        return nil
    }

    /// Testo di diagnosi per capire perché il MAC non viene ricavato (comandi non eseguibili, gateway non trovato,
    /// ARP vuoto…). Mostrato nella finestrella del MAC quando la rilevazione fallisce.
    nonisolated static func diagnose() -> String {
        var lines: [String] = []
        let table = run("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        lines.append("netstat: " + (table == nil ? "non eseguibile" : "ok (\(table!.split(separator: "\n").count) righe)"))
        let route = run("/sbin/route", ["-n", "get", "default"])
        lines.append("route: " + (route == nil ? "non eseguibile" : "ok"))
        let gateways = gatewayCandidates()
        lines.append("gateway: " + (gateways.isEmpty ? "nessuno" : gateways.joined(separator: ", ")))
        for gw in gateways {
            lines.append("sonda rete locale verso \(gw):80: " + touchLocalNetwork(gw))
            let all = run("/usr/sbin/arp", ["-an"])
            let row = all?.split(separator: "\n").first(where: { $0.contains("(\(gw))") }).map(String.init)
            let detailed = runDetailed("/usr/sbin/arp", ["-an"])
            lines.append("arp: uscita \(detailed.map { String($0.status) } ?? "n/d"), errori: \(detailed?.error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160) ?? "")")
            let routeLine = run("/usr/sbin/netstat", ["-rn", "-f", "inet"])?.split(separator: "\n").first(where: { $0.hasPrefix(gw) }).map(String.init)
            lines.append("netstat, riga del gateway: " + (routeLine ?? "assente"))
            lines.append("tabella ARP letta dal sistema: \(arpTableNative().count) voci")
            lines.append("arp -an \(gw): " + (all == nil ? "non eseguibile" : (row ?? "nessuna riga (\(all!.split(separator: "\n").count) voci in tabella)")))
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func isIPv4(_ s: String) -> Bool {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        return p.count == 4 && p.allSatisfy { Int($0) != nil }
    }
    private nonisolated static func isPhysicalInterface(_ s: String) -> Bool {
        s.hasPrefix("en") && s.dropFirst(2).allSatisfy(\.isNumber) && s.count > 2
    }

    /// Gateway predefiniti su interfaccia fisica (`enX`), non su tunnel VPN (`utunX`): prima dalla tabella di
    /// routing, poi da `route get default`.
    private nonisolated static func gatewayCandidates() -> [String] {
        var found: [String] = []
        if let table = run("/usr/sbin/netstat", ["-rn", "-f", "inet"]) {
            for line in table.split(separator: "\n") {
                let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard cols.first == "default", cols.contains(where: isPhysicalInterface),
                      let gw = cols.dropFirst().first(where: isIPv4) else { continue }
                if !found.contains(gw) { found.append(gw) }
            }
        }
        if let route = run("/sbin/route", ["-n", "get", "default"]) {
            var gw: String?, iface: String?
            for line in route.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("gateway:") { gw = t.dropFirst(8).trimmingCharacters(in: .whitespaces) }
                if t.hasPrefix("interface:") { iface = t.dropFirst(10).trimmingCharacters(in: .whitespaces) }
            }
            if let gw, let iface, isPhysicalInterface(iface), isIPv4(gw), !found.contains(gw) { found.append(gw) }
        }
        return found
    }

    /// MAC di un indirizzo IP dalla tabella ARP; se il gateway non c'è ancora si fa un ping e si riprova.
    private nonisolated static func macAddress(of ip: String) -> String? {
        // Prima la tabella ARP letta direttamente dal sistema (nessun processo esterno), poi `arp`.
        func lookup() -> String? {
            if let native = arpTableNative()[ip] { return native }
            return lookupViaCommand() ?? macFromRoutingTable(ip)
        }
        // Si legge tutta la tabella (`arp -an`) e si cerca la riga del gateway: `arp -n <ip>` non trova le voci
        // «ifscope» (quelle del gateway predefinito) e risponde «no entry» anche se la riga c'è.
        func lookupViaCommand() -> String? {
            guard let out = run("/usr/sbin/arp", ["-an"]) else { return nil }
            for line in out.split(separator: "\n") where line.contains("(\(ip))") {
                guard let range = line.range(of: "([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}", options: .regularExpression) else { continue }
                let parts = line[range].split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }
                if parts.count == 6 { return parts.joined(separator: ":").lowercased() }
            }
            return nil
        }
        if let mac = lookup() { return mac }
        // Tabella vuota o senza il gateway: si prova a «toccare» il router dall'app (crea la voce ARP e, la prima
        // volta, fa comparire la richiesta di accesso alla rete locale di macOS) e si riprova.
        _ = touchLocalNetwork(ip)
        return lookup()
    }

    /// Il MAC del gateway compare anche nella tabella di routing (`netstat -rn`, riga «192.168.18.1  b4:fc:… UHLWIir en0»):
    /// terza fonte, se le altre due non lo mostrano.
    nonisolated static func macFromRoutingTable(_ ip: String) -> String? {
        guard let table = run("/usr/sbin/netstat", ["-rn", "-f", "inet"]) else { return nil }
        for line in table.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.first == ip, cols.count > 1 else { continue }
            for col in cols.dropFirst() {
                guard let range = col.range(of: "^([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}$", options: .regularExpression) else { continue }
                let parts = col[range].split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }
                if parts.count == 6 { return parts.joined(separator: ":").lowercased() }
            }
        }
        return nil
    }

    /// Tabella ARP (IP → MAC) letta con `sysctl` (come fa `arp`), senza lanciare processi. Voce = messaggio di routing
    /// `rt_msghdr` (92 byte) + `sockaddr_inarp` (16 byte, l'IP sta nei byte 4–7) + `sockaddr_dl` (MAC dopo `sdl_nlen` byte).
    nonisolated static func arpTableNative() -> [String: String] {
        var mib: [Int32] = [4, 17, 0, 2, 2, 0x400]   // CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }
        var table: [String: String] = [:]
        var offset = 0
        let header = 92
        while offset + header + 16 + 8 <= length {
            let messageLength = Int(buffer[offset]) | (Int(buffer[offset + 1]) << 8)
            if messageLength <= 0 { break }
            let sin = offset + header
            let ip = "\(buffer[sin + 4]).\(buffer[sin + 5]).\(buffer[sin + 6]).\(buffer[sin + 7])"
            let sdl = sin + 16
            if sdl + 8 <= offset + messageLength {
                let nameLength = Int(buffer[sdl + 5]), addressLength = Int(buffer[sdl + 6])
                let start = sdl + 8 + nameLength
                if addressLength == 6, start + 6 <= length {
                    table[ip] = (0..<6).map { String(format: "%02x", buffer[start + $0]) }.joined(separator: ":")
                }
            }
            offset += messageLength
        }
        return table
    }

    /// Prova una connessione al router (porta 80) per un secondo e mezzo. Restituisce lo stato (per la diagnosi).
    @discardableResult
    nonisolated static func touchLocalNetwork(_ host: String) -> String {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 80, using: .tcp)
        let done = DispatchSemaphore(value: 0)
        // Esito scritto dal gestore di stato (altra coda) e letto qui: scatola con lock, così non si modifica una `var` catturata.
        final class Outcome: @unchecked Sendable {
            private let lock = NSLock()
            private var text = "nessuna risposta"
            func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
            func get() -> String { lock.lock(); defer { lock.unlock() }; return text }
        }
        let outcome = Outcome()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: outcome.set("connessione riuscita"); done.signal()
            case .failed(let e): outcome.set("fallita (\(e))"); done.signal()
            case .waiting(let e): outcome.set("in attesa (\(e))"); done.signal()
            default: break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
        _ = done.wait(timeout: .now() + 1.5)
        connection.cancel()
        return outcome.get()
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> String? {
        runDetailed(tool, arguments)?.output
    }

    /// Esegue un comando e restituisce uscita, errori e codice di uscita (nil se non si riesce a lanciarlo).
    private nonisolated static func runDetailed(_ tool: String, _ arguments: [String]) -> (output: String, error: String, status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", String(data: errData, encoding: .utf8) ?? "", process.terminationStatus)
    }
}
