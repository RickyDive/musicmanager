import SwiftUI
import Combine
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Network

/// Esito del tentativo di caricare un file, usato sia per decidere cosa mettere nel file
/// playlist sia per popolare la finestra di riepilogo del trasferimento.
private enum UploadOutcome {
    case transferred
    case skipped
    case failed
    /// Il file con la copertina confermata non è stato caricato, ma il brano è stato comunque
    /// messo sul dispositivo nella sua versione originale (senza la copertina nuova): cosi un
    /// problema con la copertina non fa mai sparire il brano dall'orologio.
    case transferredWithoutArtwork
}

/// Da dove viene la copertina di un brano nel riepilogo di invio.
enum ExportArtworkSource {
    /// Già nel brano (file/libreria di Apple Music): si invia com'è.
    case file
    /// Recuperata ora dalla cache di Apple Music e scritta nella copia da inviare.
    case apple
    /// Recuperata dalla cache di GMM (confermata in Fix Artwork o salvata in un invio precedente).
    case garminCache
    /// Scelta online in Fix Artwork da quando l'app è aperta (le confermate prima restano «Garmin Cache»).
    case online
    /// Nessuna copertina trovata.
    case none
    /// Brano già sul dispositivo (playlist importata dal device): non si copia nulla, resta com'è.
    case deviceOnly
}

/// Riepilogo mostrato prima dell'invio al dispositivo: i file sono già pronti in locale (TEMP) e
/// per ciascuno si vede se ha un artwork modificato.
struct DeviceExportPlan: Identifiable {
    struct Item: Identifiable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let artworkModified: Bool
        var artworkSource: ExportArtworkSource = .none
        /// Problema emerso nella preparazione (copertina non applicata, copia non riuscita...).
        var problem: String?
    }

    let id = UUID()
    let playlistName: String?
    let folderPath: String
    let items: [Item]

    /// Quanti brani per origine della copertina (riepilogo prima dell'invio): scritta ora da Apple / dalla cache
    /// Garmin, già nel file, oppure mancante.
    func count(of source: ExportArtworkSource) -> Int { items.filter { $0.artworkSource == source }.count }
}

/// Avanzamento di un'eliminazione sul dispositivo, mostrato in una finestra senza pulsanti
/// (`DeletionProgressView`) finché l'operazione non finisce. `total` = 0 → avanzamento indeterminato.
/// Avvio di un brano di una libreria di rete in corso (il file arriva dal server remoto: può richiedere tempo).
struct RemotePlaybackLoading: Equatable {
    let trackID: String
    let title: String
    let since: Date
}

/// Memoria residua dell'app (MB), solo per il registro di diagnostica.
enum ProcessMemory {
    static var residentMB: Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }
}

struct DeletionProgress: Identifiable {
    let id = UUID()
    var title: String
    var current = 0
    var total = 0
    var detail = ""
}

/// Garantisce che una continuazione venga ripresa una sola volta (dal risultato o dal timeout).
private final class TimeoutGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

    func finish(_ value: T?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// Esegue `operation` e restituisce il suo risultato, oppure `nil` se non risponde entro
/// `seconds`. Una chiamata USB/MTP bloccata non si può interrompere: qui la si "abbandona" (resta
/// in coda sull'actor MTP) e si restituisce subito il controllo, cosi l'app non resta appesa e la
/// finestra di trasferimento può chiudersi con un messaggio chiaro.
private func withTimeout<T: Sendable>(_ seconds: Double,
                                      _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = TimeoutGate<T>(continuation)
        Task.detached { gate.finish(await operation()) }
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            gate.finish(nil)
        }
    }
}

/// Un brano proposto da «Trova simili», con il punteggio di somiglianza.
struct SimilarResult: Identifiable {
    let track: LocalTrack
    let score: Double
    var id: String { track.id }
}

/// Richiesta di «Trova simili» (apre la finestra con l'elenco ordinato per punteggio).
struct SimilarRequest: Identifiable {
    let id = UUID()
    /// Nome mostrato nel titolo («Simili a …»): il brano, l'album, l'artista o il numero di brani di partenza.
    let title: String
    let results: [SimilarResult]
    /// Punteggio massimo ottenibile con i dati dei brani di partenza (fondo scala della barra).
    let maxScore: Double
    let usesYear: Bool
    let usesBPM: Bool
}

/// Tipo di una notifica del centro notifiche (dedotto dal simbolo all'inizio del messaggio di stato).
enum NoticeKind: Equatable {
    case info, success, warning, error

    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

/// Formattazione dei messaggi di stato: i nomi si evidenziano con i marcatori `<b>…</b>` (scelti apposta al posto del
/// Markdown, che rovinerebbe nomi con `*` o `_`). `bold` ripulisce il nome da eventuali marcatori; `attributed` li
/// converte in grassetto per la capsula e per la cronologia; `plain` li toglie (log, tooltip).
enum NoticeFormat {
    static func bold(_ name: String) -> String {
        "<b>" + name.replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: "") + "</b>"
    }

    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: "")
    }

    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, chunk) in text.components(separatedBy: "<b>").enumerated() {
            if index == 0 {
                result += AttributedString(plain(chunk))
                continue
            }
            let parts = chunk.components(separatedBy: "</b>")
            var boldPart = AttributedString(parts[0])
            boldPart.inlinePresentationIntent = .stronglyEmphasized
            result += boldPart
            if parts.count > 1 { result += AttributedString(plain(parts.dropFirst().joined(separator: "</b>"))) }
        }
        return result
    }
}

/// Una voce della cronologia delle notifiche (campanella nella barra del titolo).
struct NoticeEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
    let kind: NoticeKind
}

@MainActor
final class AppViewModel: ObservableObject {
    private let mtp = MTPService()
    private let library = MusicLibraryService()
    /// Ricerca online delle copertine, usata solo dalla finestra "Fix Artwork" (vedi
    /// `startFixArtwork()`), mai in background durante un invio.
    private let artworkLookup = ArtworkLookupService()
    /// Finestra "Fix Artwork" aperta dal menu contestuale (click destro) sui brani selezionati.
    var fixArtworkCompletion: (() -> Void)?
    /// «Vai ad album/artista» e «Mostra in playlist» dal menu del miniplayer: la elabora `CatalogBrowser`.
    @Published var externalReveal: ExternalRevealRequest?
    @Published var fixArtworkSession: FixArtworkSession?
    /// Aumenta ogni volta che una copertina viene confermata in Fix Artwork o applicata durante un
    /// invio: gli elenchi (Apple Music e dispositivo) lo ricevono e ricaricano le miniature, cosi
    /// la copertina nuova compare subito sul brano e sull'album.
    @Published var exportPlan: DeviceExportPlan?
    /// Finestra di avanzamento delle eliminazioni sul dispositivo (nil = nessuna in corso).
    @Published var deletionProgress: DeletionProgress?
    /// Brano di una libreria di rete in avvio (capsula: anello verde + «Caricamento dal server remoto…»).
    @Published var remotePlaybackLoading: RemotePlaybackLoading?
    /// Riproduzione dalle librerie di rete disattivata (solo fino alla chiusura dell'app) dopo un avvio troppo lento.
    @Published var remotePlaybackDisabled = false
    /// Secondi di attesa prima di dichiarare la rete troppo lenta per ascoltare il brano.
    /// Avvii falliti di seguito (si azzera quando un brano parte): al terzo si propone di disattivare la riproduzione da rete.
    private var remotePlaybackFailures = 0
    private static let remotePlaybackMaxFailures = 3
    private static let remotePlaybackTimeoutSeconds: UInt64 = 20
    @Published private(set) var artworkRevision = 0 {
        // Dopo una copertina confermata/applicata l'origine mostrata va ricalcolata.
        didSet { artworkOrigins = [:] }
    }
    /// Cambia a ogni catalogo del dispositivo riletto: le miniature lato dispositivo si ricaricano
    /// SOLO a quel punto (non a ogni copertina applicata durante un invio, che avrebbe accodato
    /// decine di letture MTP davanti all'aggiornamento dell'elenco).
    @Published private(set) var deviceArtworkRevision = 0

    /// Riferimento debole all'unica istanza in vita (ce n'è sempre una sola, creata da
    /// ContentView): serve ad AppDelegate per sapere, alla chiusura del programma, se un
    /// dispositivo è connesso e per poterlo disconnettere, senza dover far risalire lo stato
    /// fino alla scena dell'app.
    static weak var current: AppViewModel?

    // MARK: Dispositivo
    @Published var device: MTPDeviceInfo?
    /// Global ID di un dispositivo appena riconosciuto per la prima volta: finché non è nil si propone il nickname.
    @Published var nicknamePromptDeviceID: String?

    /// Nome mostrato accanto all'icona dell'orologio: il nickname scelto, altrimenti il nome del dispositivo.
    var deviceTitle: String {
        let nick = AppSettings.shared.nickname(forDevice: deviceXMLInfo?.id)
        return nick.isEmpty ? (device?.friendlyName ?? t("device_default_name")) : nick
    }

    /// Nome per i messaggi: il nickname scelto; se manca il modello (da GarminDevice.xml); poi il nome MTP.
    var deviceNameForAlerts: String {
        let nick = AppSettings.shared.nickname(forDevice: deviceXMLInfo?.id).trimmingCharacters(in: .whitespaces)
        if !nick.isEmpty { return nick }
        if let model = deviceXMLInfo?.description, !model.isEmpty { return model }
        return device?.friendlyName ?? t("device_default_name")
    }

    /// Modello come scritto in GarminDevice.xml (o, in mancanza, dal nome MTP).
    var deviceModelText: String? { deviceXMLInfo?.description }

    /// Controllo opzionale (Settings) dell'aggiornamento software: una sola volta per avvio, in background.
    private func startSoftwareUpdateCheck(deviceID: String, xml: Data, installed: String?, persist: Bool) {
        guard AppSettings.shared.checkDeviceUpdates else { return }
        if let known = softwareUpdateResults[deviceID], softwareUpdateResultVersion[deviceID] == (installed ?? "") { softwareUpdateStatus = known; return }
        if softwareUpdateResultVersion[deviceID] == nil {
            guard !softwareUpdateChecked else { return }
            softwareUpdateChecked = true
        }
        Task { [weak self] in
            let result = await GarminUpdateService.check(deviceXML: xml, installedVersion: installed)
            guard let self, let result else { return }
            self.softwareUpdateResults[deviceID] = result
            self.softwareUpdateResultVersion[deviceID] = installed ?? ""
            if self.deviceXMLInfo?.id == deviceID { self.softwareUpdateStatus = result }
            guard persist else { return }   // dispositivo senza musica: solo l'etichetta nel pannello, nessun avviso
            AppSettings.shared.setSoftwareUpToDate(result == .upToDate, forDevice: deviceID)
            self.addUpdateNotice(deviceID: deviceID, status: result, installed: installed, readDate: Date())
        }
    }

    // MARK: Controllo aggiornamenti all'apertura (dai file GarminDevice.xml memorizzati)

    /// Aggiornamento disponibile da proporre all'utente nella finestra di dialogo.
    struct DeviceUpdateNotice: Identifiable, Equatable {
        let id: String          // Global ID
        let name: String        // nickname, altrimenti modello
        let installed: String?
        let version: String
        let notes: String?
        let readDate: Date?     // quando l'XML è stato letto dal dispositivo
    }
    /// Non vuoto = la finestra «Aggiornamento disponibile» è aperta.
    @Published var pendingUpdateNotices: [DeviceUpdateNotice] = []
    private var notifiedUpdates = Set<String>()   // «id|versione» già proposti in questo avvio
    private static let ignoredUpdatesKey = "ignored_update_versions"

    private func ignoredUpdateVersion(_ id: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.ignoredUpdatesKey) as? [String: String])?[id]
    }

    /// Chiude la finestra.
    func closeUpdateSheet() {
        pendingUpdateNotices = []
    }

    /// «Ignora questa versione»: per i dispositivi della finestra non si ripropone la stessa versione (una successiva sì).
    func ignorePendingUpdates() {
        var d = (UserDefaults.standard.dictionary(forKey: Self.ignoredUpdatesKey) as? [String: String]) ?? [:]
        for n in pendingUpdateNotices { d[n.id] = n.version }
        UserDefaults.standard.set(d, forKey: Self.ignoredUpdatesKey)
        closeUpdateSheet()
    }

    /// Aggiunge alla finestra un aggiornamento disponibile, salvo se già proposto o ignorato.
    private func addUpdateNotice(deviceID: String, status: SoftwareUpdateStatus, installed: String?, readDate: Date?) {
        guard case let .available(version, notes) = status else { return }
        guard ignoredUpdateVersion(deviceID) != version, notifiedUpdates.insert("\(deviceID)|\(version)").inserted else { return }
        let known = AppSettings.shared.knownDevices.first { $0.id == deviceID }
        let nick = known?.nickname.trimmingCharacters(in: .whitespaces) ?? ""
        let name = nick.isEmpty ? ((known?.model.isEmpty == false ? known?.model : nil) ?? deviceID) : nick
        pendingUpdateNotices.append(DeviceUpdateNotice(id: deviceID, name: name, installed: installed, version: version,
                                                       notes: notes, readDate: readDate))
    }

    /// Riga della tabella nella finestra: un dispositivo registrato con l'esito del controllo (nil = non controllato).
    struct DeviceUpdateRow: Identifiable, Equatable {
        let id: String
        let name: String
        let installed: String?
        let status: SoftwareUpdateStatus?
        let readDate: Date?
    }
    /// Tutti i dispositivi registrati con l'esito dell'ultimo controllo: la tabella della finestra «Aggiornamento disponibile».
    var updateRows: [DeviceUpdateRow] {
        return AppSettings.shared.knownDevices.map { d in
            let nick = d.nickname.trimmingCharacters(in: .whitespaces)
            return DeviceUpdateRow(id: d.id, name: nick.isEmpty ? (d.model.isEmpty ? d.id : d.model) : nick,
                                   installed: d.softwareVersion.isEmpty ? nil : d.softwareVersion,
                                   status: softwareUpdateResults[d.id], readDate: DeviceXMLStore.load(forDevice: d.id)?.date)
        }
    }

    /// Una volta all'apertura, se l'opzione è accesa, controlla ogni dispositivo registrato usando la copia locale di
    /// GarminDevice.xml (anche a dispositivo scollegato) e propone la finestra se c'è un aggiornamento. Gira in background.

    private func startLaunchUpdateCheck() {
        guard AppSettings.shared.checkDeviceUpdates else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // l'avvio dell'app ha la precedenza
            guard let self else { return }
            for known in AppSettings.shared.knownDevices {
                guard let stored = DeviceXMLStore.load(forDevice: known.id) else { continue }
                let raw = DeviceImageService.modelInfo(fromXML: stored.xml).softwareVersion
                let installed = Self.formattedSoftwareVersion(raw) ?? (known.softwareVersion.isEmpty ? nil : known.softwareVersion)
                guard let result = await GarminUpdateService.check(deviceXML: stored.xml, installedVersion: installed) else { continue }
                self.softwareUpdateResults[known.id] = result
                self.softwareUpdateResultVersion[known.id] = installed ?? ""
                AppSettings.shared.setSoftwareUpToDate(result == .upToDate, forDevice: known.id)
                if self.deviceXMLInfo?.id == known.id { self.softwareUpdateStatus = result }
                self.addUpdateNotice(deviceID: known.id, status: result, installed: installed, readDate: stored.date)
            }
        }
    }

    func confirmDeviceNickname(_ nickname: String) {
        if let id = nicknamePromptDeviceID {
            AppSettings.shared.setNickname(nickname.trimmingCharacters(in: .whitespaces), forDevice: id)
        }
        nicknamePromptDeviceID = nil
    }

    /// Versione software come numero con due decimali: «649» → «6.49»; se non è numerico resta com'è.
    static func formattedSoftwareVersion(_ raw: String?) -> String? {
        guard let raw, let n = Int(raw.trimmingCharacters(in: .whitespaces)) else { return raw }
        return "\(n / 100).\(String(format: "%02d", n % 100))"
    }
    /// Immagine del prodotto Garmin connesso (vedi `DeviceImageService`); nil finché non è pronta
    /// o se non disponibile: il riquadro mostra allora l'icona predefinita.
    @Published var deviceImage: NSImage?
    /// Dati letti da `GarminDevice.xml` (part number, versione software, Id globale, nome mostrato),
    /// per il pannello Device; nil finché non sono letti o senza dispositivo.
    @Published var deviceXMLInfo: DeviceImageService.ModelInfo?
    /// Formati e funzioni multimediali dichiarati da `GarminDevice.xml` (nil = sconosciuti: non si blocca nulla).
    @Published private(set) var deviceMedia: DeviceImageService.MediaCapabilities?
    /// Dispositivo collegato che non supporta la musica: le info restano visibili, ma ogni scrittura è disattivata.
    var isDeviceReadOnly: Bool { device != nil && deviceMedia?.isMusicCapable == false }

    /// Da chiamare all'inizio di ogni operazione che scrive sul dispositivo: se è in sola lettura
    /// avvisa nella barra di stato e restituisce false.
    private func ensureDeviceWritable() -> Bool {
        guard isDeviceReadOnly else { return true }
        status = "⚠️ " + t("status_device_not_music_capable")
        return false
    }

    /// Azzera capacità e formati del dispositivo (scollegamento o nuova connessione).
    private func resetDeviceMedia() {
        deviceMedia = nil
        LocalTrack.deviceExtensions = nil
    }
    /// Esito del controllo aggiornamenti software (nil = non eseguito, spento o fallito: nessuna etichetta).
    @Published var softwareUpdateStatus: SoftwareUpdateStatus?
    /// Il controllo si esegue una sola volta per avvio dell'app; l'esito resta per i ricollegamenti successivi.
    private var softwareUpdateChecked = false
    private var softwareUpdateResults: [String: SoftwareUpdateStatus] = [:]
    /// Versione installata con cui si è ottenuto l'esito in memoria: se cambia (altro GarminDevice.xml, aggiornamento) si ricontrolla.
    private var softwareUpdateResultVersion: [String: String] = [:]
    /// Numero di serie di produzione del dispositivo collegato (servizio Garmin `unit-info`); nil se non noto.
    @Published var deviceSerial: String?
    /// Vero quando Garmin ha restituito le informazioni sulle mappe del dispositivo collegato (chiamata
    /// `maps/universal/update`): nel pannello Device compare l'icona del mondo. Per ora la chiamata non c'è ancora.
    @Published var deviceMapsAvailable = false
    /// Vero se il dispositivo collegato è memorizzato (ha musica). Uno senza musica si mostra solo da collegato:
    /// i suoi dati restano in memoria (nessun file, nessun avviso all'apertura).
    private var deviceIsRegistered = false
    private var deviceXMLData: Data?
    private var deviceMemoryMaps: [String: (catalog: GarminMapsCatalog, checkedAt: Date)] = [:]
    /// Garmin non offre mappe per il dispositivo, ma il dispositivo accetta percorsi (es. Forerunner 255): icona dei percorsi.
    @Published var deviceRoutesOnly = false
    /// Catalogo delle mappe di Garmin per il dispositivo collegato (nil = non richiesto, spento o fallito).
    @Published var deviceMaps: GarminMapsCatalog?
    /// Motivo per cui le mappe non sono state ottenute (mostrato nella finestra Mappe).
    @Published var deviceMapsError: String?
    /// Giorni dall'ultimo controllo delle mappe, se superano `mapsRecheckDays`: attiva la proposta di ricontrollo (nil = nessuna).
    @Published var mapsRecheckProposalDays: Int?
    private var mapsRecheckProposed: Set<String> = []
    /// Le mappe sul dispositivo non corrispondono più a Maps.json (es. aggiunte con Garmin Express): attiva la proposta di controllo.
    @Published var mapsChangedProposal = false
    private var mapsChangedProposed: Set<String> = []
    /// Data del controllo da cui provengono `deviceMaps` (mostrata come «Checked Today»).
    @Published var deviceMapsCheckedAt: Date?
    @Published var selectedStorageID: UInt32 = 0

    // Dispositivo - barra dello spazio (solo memoria interna)
    @Published var garminFolderSize: UInt64 = 0
    @Published var mapsSize: UInt64 = 0
    /// Spazio dei servizi di streaming (somma di MediaCacheSize in GarminDevice.xml), 0 se non ce ne sono.
    @Published var servicesSize: UInt64 = 0
    @Published var isLoadingStorageBreakdown = false

    // Dispositivo - vista Musica
    @Published var deviceCategory: CatalogCategory = .playlists
    @Published var deviceTracks: [DeviceTrack] = [] {
        didSet { rebuildDeviceFileIndex(); updatePendingTransferBytes(); deviceSummaryCache = nil }
    }
    @Published var devicePlaylists: [TrackGroup<DeviceTrack>] = [] {
        didSet { devicePlaylistNames = Set(devicePlaylists.map { $0.title.lowercased() }) }
    }
    /// Nomi (minuscoli) delle playlist presenti sul dispositivo, per l'icona "già inviata".
    private var devicePlaylistNames: Set<String> = []
    @Published var selectedDeviceTrackIDs = Set<UInt32>()

    // MARK: Libreria Apple Music
    @Published var appleCategory: CatalogCategory = .playlists {
        didSet { if appleCategory != oldValue { updatePendingTransferBytes() } }   // nella Custom la barra mostra la sua dimensione
    }
    @Published var tracks: [LocalTrack] = [] {
        didSet { deviceSummaryCache = nil }   // le durate mancanti sul dispositivo si ricavano dalla libreria
    }
    @Published var playlists: [TrackGroup<LocalTrack>] = [] {
        didSet { rebuildPlaylistMembership() }
    }
    /// Indice «id brano → playlist che lo contengono (id, titolo)», ricostruito a ogni cambio delle playlist.
    /// Serve all'icona «in playlist» e al menu «Mostra in playlist» del pannello Apple Music.
    private var playlistMembership: [String: [(id: String, title: String)]] = [:]
    private func rebuildPlaylistMembership() {
        var index: [String: [(id: String, title: String)]] = [:]
        for group in playlists {
            var seen = Set<String>()
            for track in group.tracks where seen.insert(track.id).inserted {
                index[track.id, default: []].append((id: group.id, title: group.title))
            }
        }
        for key in index.keys { index[key]?.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }
        playlistMembership = index
    }
    // MARK: - Trova simili

    /// Finestra «Trova simili» aperta (nil = chiusa).
    @Published var similarRequest: SimilarRequest?

    private static func similarKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Calcola i brani della libreria più simili a quelli di partenza e apre la finestra con i risultati.
    /// Punteggio (somma): playlist in comune (fino a 6; una playlist piccola pesa più di una grande), stesso genere (3, in
    /// proporzione ai brani di partenza con quel genere), stesso artista (4), stesso album (1), anno vicino (fino a 1,5) e
    /// BPM vicino (fino a 2): anno e BPM contano solo se i brani di partenza e il candidato li hanno.
    func findSimilar(to seeds: [LocalTrack]) {
        guard !seeds.isEmpty else { return }
        let seedIDs = Set(seeds.map(\.id))
        let count = Double(seeds.count)

        // Titolo della finestra.
        let title: String
        if seeds.count == 1 { title = seeds[0].title }
        else if Set(seeds.map { Self.similarKey($0.album) }).count == 1, !seeds[0].album.isEmpty { title = seeds[0].album }
        else if Set(seeds.map { Self.similarKey($0.artist) }).count == 1 { title = seeds[0].artist }
        else { title = t("similar_n_tracks", seeds.count) }

        // Dati dei brani di partenza.
        var genreCount: [String: Int] = [:]
        for s in seeds { let g = Self.similarKey(s.genre); if !g.isEmpty { genreCount[g, default: 0] += 1 } }
        var artistKeys = Set<String>()
        var albumKeys = Set<String>()
        for s in seeds {
            for a in [s.artist, s.albumArtist] where !a.isEmpty { artistKeys.insert(Self.similarKey(a)) }
            if !s.album.isEmpty { albumKeys.insert(Self.similarKey(s.album)) }
        }
        let years = seeds.map(\.year).filter { $0 > 0 }.sorted()
        let medianYear: Int? = years.isEmpty ? nil : years[years.count / 2]
        let bpms = seeds.map(\.bpm).filter { $0 > 0 }
        let meanBPM: Double? = bpms.isEmpty ? nil : Double(bpms.reduce(0, +)) / Double(bpms.count)
        var seedsInPlaylist: [String: Int] = [:]
        for s in seeds { for p in playlistMembership[s.id] ?? [] { seedsInPlaylist[p.id, default: 0] += 1 } }
        var playlistSize: [String: Int] = [:]
        for g in playlists { playlistSize[g.id] = g.tracks.count }

        let maxScore = (seedsInPlaylist.isEmpty ? 0 : 6) + (genreCount.isEmpty ? 0 : 3) + 4 + 1
            + (medianYear == nil ? 0 : 1.5) + (meanBPM == nil ? 0 : 2)

        var results: [SimilarResult] = []
        for c in tracks where !seedIDs.contains(c.id) && !c.isDeviceOnly && c.isTransferable {
            var score = 0.0
            // Playlist in comune.
            var pl = 0.0
            for p in playlistMembership[c.id] ?? [] {
                guard let n = seedsInPlaylist[p.id] else { continue }
                let size = Double(max(1, playlistSize[p.id] ?? 1))
                pl += 3 * min(1, 20 / size) * min(1, Double(n) / Double(min(seeds.count, 3)))
            }
            score += min(pl, 6)
            // Genere.
            if let n = genreCount[Self.similarKey(c.genre)] { score += 3 * Double(n) / count }
            // Artista e album.
            if artistKeys.contains(Self.similarKey(c.artist)) || (!c.albumArtist.isEmpty && artistKeys.contains(Self.similarKey(c.albumArtist))) { score += 4 }
            if !c.album.isEmpty, albumKeys.contains(Self.similarKey(c.album)) { score += 1 }
            // Anno e BPM.
            if c.year > 0, let y = medianYear {
                let d = abs(c.year - y)
                score += d <= 2 ? 1.5 : (d <= 5 ? 1.0 : (d <= 10 ? 0.5 : 0))
            }
            if c.bpm > 0, let b = meanBPM {
                let d = abs(Double(c.bpm) - b)
                score += d <= 5 ? 2 : (d <= 10 ? 1.5 : (d <= 20 ? 0.75 : 0))
            }
            if score >= 1 { results.append(SimilarResult(track: c, score: score)) }
        }
        // A parità di punteggio (confronto al centesimo) passano prima i brani meno ascoltati, poi l'ordine alfabetico:
        // tra brani ugualmente simili si propongono quelli ancora da scoprire.
        results.sort {
            let a = Int(($0.score * 100).rounded()), b = Int(($1.score * 100).rounded())
            if a != b { return a > b }
            if $0.track.playCount != $1.track.playCount { return $0.track.playCount < $1.track.playCount }
            return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
        }
        // Varietà: al massimo 3 brani per artista (2 per l'artista dei brani di partenza, che già pesa +4 nel punteggio),
        // altrimenti i primi 30 risultati possono venire quasi tutti dallo stesso artista. Si scorre in ordine di punteggio.
        var perArtist: [String: Int] = [:]
        var varied: [SimilarResult] = []
        for r in results {
            let key = Self.similarKey(r.track.albumArtist.isEmpty ? r.track.artist : r.track.albumArtist)
            if !key.isEmpty {
                let isSeedArtist = artistKeys.contains(key) || artistKeys.contains(Self.similarKey(r.track.artist))
                if perArtist[key, default: 0] >= (isSeedArtist ? 2 : 3) { continue }
                perArtist[key, default: 0] += 1
            }
            varied.append(r)
            if varied.count == 30 { break }
        }
        similarRequest = SimilarRequest(title: title, results: varied, maxScore: maxScore,
                                        usesYear: medianYear != nil, usesBPM: meanBPM != nil)
    }

    /// «OK» nella finestra «Trova simili»: i brani scelti si sommano alla selezione già fatta. Contano come scelti dalla
    /// scheda Brani (non dalla scheda attiva), così non scatta il controllo sulle playlist all'invio.
    func addToSelection(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let before = selectionSources
        selectedTrackIDs.formUnion(ids)
        selectionSources = before.union([.songs])
    }

    /// «Invia a Custom» nella finestra «Trova simili»: stesse regole di «Invia alla Playlist» (copertine online per le
    /// librerie condivise, duplicati, svuotamento) ma sui brani scelti nella finestra, senza toccare la selezione.
    func addTracksToCustomPlaylist(_ list: [LocalTrack]) {
        let picked = albumOrdered(list.filter { $0.isTransferable })
        guard !picked.isEmpty else { return }
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.applyTracksToCustomPlaylist(picked, originPlaylistTitle: nil, renameToCopy: self.customPlaylistEntries.isEmpty)
        }
        Task { [weak self] in
            guard let self else { return }
            if self.isRemoteNetworkLibraryActive { await self.loadArtworkNow(picked) }
            let remote = picked   // anche la libreria locale
            guard !remote.isEmpty, AppSettings.shared.proposeSharedArtworkSearch, AppSettings.shared.lookupMissingArtworkOnline else {
                apply(); return
            }
            let asked = await self.askArtworkSearchIfNeeded(for: remote, proceed: apply)
            if !asked { apply() }
        }
    }

    /// Playlist (id, titolo) che contengono il brano; vuoto se non sta in nessuna.
    func playlistsContaining(_ track: LocalTrack) -> [(id: String, title: String)] {
        playlistMembership[track.id] ?? []
    }
    /// Schede da cui arrivano i brani della selezione corrente (la scheda attiva quando un brano viene aggiunto): serve a
    /// distinguere una scelta fatta solo nella scheda Playlist da una mista (Playlist + Brani/Album/Artisti). Si azzera
    /// quando la selezione si svuota; togliere brani non la riduce (resta prudente).
    private(set) var selectionSources = Set<CatalogCategory>()
    @Published var selectedTrackIDs = Set<String>() {
        didSet {
            if selectedTrackIDs.isEmpty { selectionSources = [] }
            else if !selectedTrackIDs.subtracting(oldValue).isEmpty { selectionSources.insert(appleCategory) }
            updatePendingTransferBytes()
            if !restoringSelection { checkPlaylistRemoval(previous: oldValue) }
            // Ricorda l'ultima playlist diventata interamente selezionata (tipicamente con
            // "Select" sulla sua intestazione): serve a riconoscere l'invio di una playlist intera
            // anche se nella selezione sono rimasti altri brani scelti prima.
            if selectedTrackIDs.isEmpty { lastFullySelectedPlaylistID = nil }
            let added = selectedTrackIDs.subtracting(oldValue)
            guard !added.isEmpty else { return }
            // Solo dalla scheda Playlist: «Seleziona tutto» in Artisti/Album/Brani include per forza qualche playlist intera
            // senza che l'utente l'abbia scelta, e darebbe alla Custom il nome di una playlist a caso.
            guard appleCategory == .playlists else { return }
            let full = visiblePlaylists.filter { g in
                let ids = Set(g.tracks.map(\.id))
                return !ids.isEmpty && ids.isSubset(of: selectedTrackIDs) && !ids.isSubset(of: oldValue)
            }
            if let best = full.max(by: { $0.tracks.count < $1.tracks.count }) { lastFullySelectedPlaylistID = best.id }
        }
    }
    /// Avviso mostrato quando da un'altra scheda si toglie un brano di una playlist scelta per intero (vedi `checkPlaylistRemoval`).
    struct PlaylistRemovalPrompt {
        /// Cosa si sta togliendo, già nella lingua corrente («l'artista «X»», «l'album «Y»», «il brano «Z»», «3 brani»…).
        let subject: String
        let subjectIsPlural: Bool
        /// Playlist scelte per intero che contengono ciò che si toglie.
        let titles: [String]
        let playlistIDs: Set<String>
        /// Stato da ripristinare con «Annulla».
        let previousSelection: Set<String>
        let previousPlaylistIDs: [String]
    }
    @Published var playlistRemovalPrompt: PlaylistRemovalPrompt?
    private var restoringSelection = false

    /// Chiamata a ogni cambio di `selectedTrackIDs`. Una playlist scelta per intero resta tale finché tutti i suoi brani sono
    /// selezionati. Se da un'altra scheda (Brani, Album, Artisti) si toglie qualcuno dei suoi brani lasciandone altri, si chiede
    /// conferma: «Conferma» toglie il brano e la playlist non viene più inviata come playlist (niente .m3u8); «Annulla»
    /// ripristina selezione e playlist. Se si tolgono tutti i suoi brani, o la selezione si svuota, la playlist esce senza
    /// domande. Nella scheda Playlist non si chiede nulla: la scelta per righe aggiorna da sola l'elenco delle playlist.
    private func checkPlaylistRemoval(previous: Set<String>) {
        guard !selectedApplePlaylistIDs.isEmpty else { return }
        if selectedTrackIDs.isEmpty { selectedApplePlaylistIDs = []; return }
        let removed = previous.subtracting(selectedTrackIDs)
        guard !removed.isEmpty, appleCategory != .playlists else { return }
        let originalIDs = selectedApplePlaylistIDs
        var gone = Set<String>()
        var partialIDs = Set<String>()
        var titles: [String] = []
        for id in originalIDs {
            guard let group = visiblePlaylists.first(where: { $0.id == id }) ?? playlists.first(where: { $0.id == id }) else { continue }
            let ids = Set(group.tracks.filter(\.isTransferable).map(\.id))
            guard !ids.isDisjoint(with: removed) else { continue }
            if ids.isDisjoint(with: selectedTrackIDs) { gone.insert(id) } else { partialIDs.insert(id); titles.append(group.title) }
        }
        selectedApplePlaylistIDs.removeAll { gone.contains($0) }
        guard !partialIDs.isEmpty else { return }
        let (subject, plural) = removalSubject(removed: removed)
        playlistRemovalPrompt = PlaylistRemovalPrompt(subject: subject, subjectIsPlural: plural, titles: titles, playlistIDs: partialIDs,
                                                      previousSelection: previous, previousPlaylistIDs: originalIDs)
    }

    /// Descrive ciò che l'utente sta togliendo, secondo la scheda: nella scheda Artisti l'artista (o gli artisti), in Album
    /// l'album (o gli album), purché non resti selezionato nessun altro brano dello stesso artista/album; altrimenti, e in
    /// Brani, il brano (o «N brani»).
    private func removalSubject(removed: Set<String>) -> (String, Bool) {
        let universe = tracks.filter { selectedTrackIDs.contains($0.id) || removed.contains($0.id) }
        func wholly(_ groups: [TrackGroup<LocalTrack>]) -> [TrackGroup<LocalTrack>]? {
            let touched = groups.filter { g in g.tracks.contains { removed.contains($0.id) } }
            guard !touched.isEmpty, touched.allSatisfy({ g in !g.tracks.contains { selectedTrackIDs.contains($0.id) } }) else { return nil }
            return touched
        }
        switch appleCategory {
        case .artists:
            if let groups = wholly(universe.groupedByAlbumArtist()) {
                return groups.count == 1 ? (t("alert_playlist_removal_artist_one", groups[0].title), false)
                                         : (t("alert_playlist_removal_artists_many", groups.count), true)
            }
        case .albums:
            if let groups = wholly(universe.groupedByAlbum()) {
                return groups.count == 1 ? (t("alert_playlist_removal_album_one", groups[0].title), false)
                                         : (t("alert_playlist_removal_albums_many", groups.count), true)
            }
        default:
            break
        }
        let picked = universe.filter { removed.contains($0.id) }
        if picked.count == 1 { return (t("alert_playlist_removal_song_one", picked[0].title), false) }
        return (t("alert_playlist_removal_songs_many", max(picked.count, removed.count)), true)
    }

    /// «Conferma»: il brano resta tolto e le playlist coinvolte non si inviano più come playlist.
    func confirmPlaylistRemoval() {
        guard let prompt = playlistRemovalPrompt else { return }
        selectedApplePlaylistIDs.removeAll { prompt.playlistIDs.contains($0) }
        playlistRemovalPrompt = nil
    }

    /// «Annulla»: si ripristinano la selezione e le playlist scelte per intero.
    func cancelPlaylistRemoval() {
        guard let prompt = playlistRemovalPrompt else { return }
        restoringSelection = true
        selectedTrackIDs = prompt.previousSelection
        restoringSelection = false
        selectedApplePlaylistIDs = prompt.previousPlaylistIDs
        playlistRemovalPrompt = nil
    }

    /// Id della playlist scelta per intero dalla sua riga nella scheda Playlist (nil se la scelta è
    /// parziale o mista). Impostata da `CatalogBrowser` (`wholePlaylistSelection`).
    var wholePlaylistSelectionID: String?
    /// Id delle playlist scelte per intero nella scheda Playlist (anche più di una). Impostata da `CatalogBrowser`
    /// (`onSelectedPlaylistsChange`): serve all'invio di più playlist insieme, ciascuna con il proprio file .m3u8.
    var selectedApplePlaylistIDs: [String] = []
    /// Brani senza copertina col filtro «senza copertina» attivo (nil = filtro spento); per la riga di stato.
    @Published var coverFilterCount: Int?
    /// Playlist (nome + brani) da inviare insieme, preparate in TEMP in attesa della conferma d'invio.
    private var stagedPlaylists: [(name: String, tracks: [LocalTrack])] = []
    private var lastFullySelectedPlaylistID: String?
    /// Segue l'impostazione «Mostra solo i brani trasferibili» (Impostazioni → Generale).
    @Published var showOnlyTransferable = AppSettings.shared.showOnlyTransferable
    private var transferableObserver: AnyCancellable?
    private var localTracks: [LocalTrack] = [] {
        didSet {
            titleIndexCache = nil; libraryNameMapCache = nil
            // Libreria (ri)caricata a dispositivo già letto: durata e numeri di traccia dal file in Music si applicano ora.
            if device != nil, let raw = lastRawDeviceCatalog { applyDeviceCatalog(raw, keepSelection: true) }
        }
    }
    /// Ultimo elenco letto dal dispositivo, prima di arricchirlo con i dati della libreria Music.
    private var lastRawDeviceCatalog: DeviceCatalog?
    /// Brani di Music per titolo normalizzato (per riconoscere i file trascinati senza scorrere tutta la libreria).
    private var titleIndexCache: [String: [LocalTrack]]?
    private var localPlaylists: [TrackGroup<LocalTrack>] = []
    private var localPlaylistKinds: [String: PlaylistKind] = [:]
    /// Tutte le playlist della libreria a schermo (prima del filtro per tipo di Impostazioni) e il loro tipo.
    private var allPlaylists: [TrackGroup<LocalTrack>] = []
    private var allPlaylistKinds: [String: PlaylistKind] = [:]
    private var playlistTypeObserver: AnyCancellable?

    /// Imposta le playlist della libreria a schermo applicando il filtro per tipo (Impostazioni → Generale).
    private func setPlaylists(_ groups: [TrackGroup<LocalTrack>], kinds: [String: PlaylistKind]) {
        allPlaylists = groups
        allPlaylistKinds = kinds
        applyPlaylistTypeFilter()
    }

    private func applyPlaylistTypeFilter() {
        let filter = AppSettings.shared.playlistTypeFilter
        playlists = allPlaylists.filter { filter.shows(allPlaylistKinds[$0.id]) }
    }
    /// Libreria letta da un file XML con i file su una cartella montata (nil = non attiva); nome mostrato nel menu.
    @Published var externalLibraryName: String?
    /// Libreria remota attiva (id della voce in Impostazioni ▸ Remote Libraries).
    @Published var externalLibraryID: UUID?
    /// true quando la libreria letta da Musica non contiene nessun brano: l'app mostra un avviso.
    @Published var showEmptyLibraryAlert = false
    /// Invio dalla scheda Playlist con una scelta parziale o mista (non una o più playlist intere): avviso e proposta di
    /// passare dalla Custom Playlist (vedi `sendSelectedTracksToDevice`).
    @Published var showPartialPlaylistSendAlert = false
    /// Brani scelti solo dalla scheda Playlist, senza una playlist intera: conferma dell'invio dei soli brani
    /// (la playlist di origine non viene creata sul dispositivo).
    @Published var showTracksOnlyFromPlaylistAlert = false

    // MARK: Stato
    @Published var status = t("status_no_device") { didSet { AppLog.write(NoticeFormat.plain(status)); recordNotice(status) } }
    /// Centro notifiche: cronologia degli ultimi messaggi di stato (max 100), numero di avvisi/errori non letti
    /// (puntino sulla campanella) e ultimo messaggio, mostrato per qualche secondo al centro della barra del titolo.
    @Published var notices: [NoticeEntry] = []
    @Published var unreadIssues = 0 { didSet { if unreadIssues == 0 { unreadHasError = false } } }
    /// Tra gli avvisi non letti c'è almeno un errore: il puntino della campanella è rosso (altrimenti arancione).
    @Published var unreadHasError = false
    /// Ricerca della barra del titolo: un testo per pannello (Music, Custom Playlist, Device) e il pannello
    /// su cui agisce. Senza dispositivo si cerca sempre in Music (`effectiveSearchTarget`).
    enum SearchTarget { case music, device }
    @Published var musicSearch = ""
    @Published var customPlaylistSearch = ""
    @Published var deviceSearch = ""
    @Published var searchTarget: SearchTarget = .music
    var effectiveSearchTarget: SearchTarget { device != nil ? searchTarget : .music }
    var isSearchFilterActive: Bool { !musicSearch.isEmpty || !customPlaylistSearch.isEmpty || !deviceSearch.isEmpty }
    @Published var toast: NoticeEntry?

    /// Aggiunge il messaggio di stato alla cronologia. Uguale al precedente: ignorato. Durante un'operazione
    /// (isBusy) gli aggiornamenti di avanzamento ravvicinati sostituiscono la voce precedente invece di accumularsi.
    private func recordNotice(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let table: [(String, NoticeKind)] = [("⚠️", .warning), ("⚠", .warning), ("❌", .error), ("🚫", .error),
                                              ("✅", .success), ("ℹ️", .info), ("ℹ", .info)]
        var kind = NoticeKind.info
        var body = text
        for (prefix, k) in table where text.hasPrefix(prefix) {
            kind = k
            body = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        guard !body.isEmpty, notices.last?.text != body else { return }
        let entry = NoticeEntry(date: Date(), text: body, kind: kind)
        if isBusy, kind == .info, let last = notices.last, last.kind == .info,
           entry.date.timeIntervalSince(last.date) < 2 {
            notices[notices.count - 1] = entry
        } else {
            notices.append(entry)
            if notices.count > 100 { notices.removeFirst(notices.count - 100) }
        }
        if kind == .warning || kind == .error { unreadIssues += 1 }
        if kind == .error { unreadHasError = true }
        toast = entry
    }
    @Published var isBusy = false {
        didSet { if !isBusy { progress = nil } }
    }
    /// Dove si svolge l'operazione in corso, per mostrare la rotellina solo nel posto giusto: `.library` (lettura delle librerie,
    /// salvataggio in Musica) = capsula in alto e pulsante Aggiorna; `.device` (connessione, invio, eliminazione…) = capsula
    /// e pannello del dispositivo. Il pulsante Aggiorna gira anche durante tutto «Aggiorna» (`refreshAllRunning`).
    enum BusyScope { case library, device }
    @Published var busyScope: BusyScope = .device
    @Published var refreshAllRunning = false
    var libraryBusy: Bool { isBusy && busyScope == .library }
    var deviceBusy: Bool { isBusy && busyScope == .device }
    /// Avanzamento (0…1) dell'operazione in corso con un conteggio «n di N» (preparazione, invio, aggiunta): l'anello
    /// nella capsula della barra del titolo. nil = operazione senza avanzamento misurabile (rotellina).
    @Published var progress: Double?
    /// Finestra di riepilogo del trasferimento in corso (o appena concluso). Nil quando non c'è
    /// nulla da mostrare. Si aggiorna in diretta man mano che ogni brano viene processato.
    @Published var transferReport: TransferReport?
    /// «Cancel» confermato nella finestra di trasferimento: l'invio finisce il file in corso e si ferma (i cicli di invio lo
    /// controllano all'inizio di ogni brano). `transferWasStopped`: l'invio si è concluso perché interrotto.
    @Published var transferStopRequested = false
    @Published var transferWasStopped = false
    func requestTransferStop() { transferStopRequested = true }
    /// Vero mentre si scrive il file playlist (.m3u8) e si verifica il risultato: da lì in poi «Cancel» non ha più effetto
    /// (non c'è un altro file dopo cui fermarsi), quindi il pulsante resta disattivato fino alla fine di quella playlist.
    @Published var transferStopLocked = false

    // MARK: Mini player (Apple Music)
    /// Motore di riproduzione: le sue proprietà (tempo corrente, durata, in riproduzione) sono
    /// osservate direttamente dal mini player, cosi si aggiornano senza passare da AppViewModel.
    let player = PlayerService()
    /// Ogni cambio di brano o di copertina si pubblica anche al sistema ("In riproduzione": Apple TV, Centro di Controllo, tasti multimediali).
    @Published var playerTrack: LocalTrack? { didSet { publishNowPlaying() } }
    @Published var playerArtwork: NSImage? { didSet { publishNowPlaying() } }
    private func publishNowPlaying() {
        player.setNowPlaying(title: playerTrack?.title, artist: playerTrack?.artist,
                             album: playerTrack?.album, artwork: playerArtwork)
    }
    /// Gli altri brani del contesto in cui si è fatto doppio click (l'intero elenco Brani, oppure
    /// l'album/artista/playlist aperti): usati dai pulsanti avanti/indietro del mini player.
    private var playerQueue: [LocalTrack] = []
    /// Nome della playlist da cui si sta riproducendo (nil se si riproduce da Brani/Album/Artisti):
    /// solo in quel caso il mini player mostra il nome, l'elenco brani, casuale e ripetizione.
    @Published private(set) var playbackSource: PlaybackSource?
    var playbackPlaylistName: String? { playbackSource?.name }
    /// Ordine effettivo di riproduzione (quello della playlist, o mischiato con "casuale") e
    /// posizione del brano corrente: i brani prima sono "già riprodotti", dopo "da riprodurre".
    @Published private(set) var playOrder: [LocalTrack] = []
    @Published private(set) var playOrderPos = 0
    /// Riproduzione casuale / ripetizione ciclica: valgono solo riproducendo da una playlist.
    @Published var isShuffleOn = false {
        didSet { if isShuffleOn != oldValue { rebuildPlayOrder(keeping: playerTrack) } }
    }
    @Published var isRepeatOn = false

    /// Le due viste partono sempre dalla scheda scelta nelle Impostazioni (Playlist di default).
    /// Rileva lo scollegamento USB del dispositivo (vedi `USBRemovalWatcher`).
    private var usbWatcher: USBRemovalWatcher?
    /// Controllo periodico in background che connette da solo un Garmin appena collegato.
    private var autoConnectTask: Task<Void, Never>?
    /// Vero mentre la connessione automatica è in corso (evita due tentativi sovrapposti).
    private var isAutoConnecting = false
    /// Vero se l'utente ha premuto "Disconnetti" con l'orologio ancora attaccato: finché non lo si
    /// stacca fisicamente la connessione automatica non deve ripartire da sola.
    private var userDisconnected = false

    // MARK: Rete corrente (per distinguere librerie condivise «locali» e «remote»)

    /// MAC del router della rete attuale (nil = non ancora letto, oppure nessuna rete / MAC non ricavabile: in quel caso nessuna libreria viene bloccata).
    @Published var networkID: String?
    /// Vero dopo la prima lettura della rete: finché non è fatta non si giudica nessuna libreria «remota».
    @Published private(set) var networkChecked = false
    private let networkMonitor = NWPathMonitor()

    enum LibraryLocality { case local, remote, unknown }

    /// Locale se la rete attuale è quella in cui la libreria è stata aggiunta; remota se è un'altra (altra casa, VPN,
    /// hotspot del telefono): per ora non utilizzabile. Sconosciuta se la rete della libreria non è ancora nota.
    func locality(of cfg: RemoteLibraryConfig) -> LibraryLocality {
        // Se la rete attuale non si riconosce (nessun MAC rilevato) non si può giudicare: la libreria non si blocca.
        guard networkChecked, let home = cfg.homeNetwork, let current = networkID else { return .unknown }
        return home == current ? .local : .remote
    }

    /// Vero se la libreria aperta è una libreria di un'altra rete (raggiungibile, per esempio via VPN). Lì le copertine
    /// si trovano nei file sul volume montato, lontano: non si caricano da sole, ma solo per i brani inviati
    /// alla Custom Playlist o al dispositivo.
    var isRemoteNetworkLibraryActive: Bool {
        // 2.2: vale per ogni libreria esterna (anche sulla stessa rete): i file stanno su un disco di rete e leggere le
        // copertine mentre si sfoglia il catalogo richiede molti secondi. Si leggono solo per i brani del controllo e dell'invio.
        // 2.2: una libreria «Unità esterna» (chiavetta o disco locale) è veloce: le copertine si leggono dai file
        // mentre si sfoglia, come nella libreria locale.
        externalLibraryID != nil && !isDriveLibraryActive
    }

    private func refreshNetworkID() {
        Task { [weak self] in
            // Piccola attesa: dopo un cambio di rete la tabella ARP si riempie con un breve ritardo.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let id = await Task.detached(priority: .utility, operation: { NetworkIdentity.currentRouterID() }).value
            guard let self else { return }
            if self.networkID != id { self.networkID = id }
            self.networkChecked = true
        }
    }

    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.refreshNetworkID()
                // Offline: librerie subito non raggiungibili; online: verifica con ripetizioni (vedi LibraryReachability).
                LibraryReachability.shared.pathChanged(online: online)
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "MusicManager.network", qos: .utility))
        refreshNetworkID()
    }

    /// Tiene aggiornato `AppSettings.connectedDeviceIDs` (pallino verde nella tabella Devices) con i dispositivi collegati.
    private var connectedDevicesCancellable: AnyCancellable?

    /// All'apertura: per ogni libreria remota (Impostazioni) il cui file non è raggiungibile perché il volume di rete non è montato,
    /// prova a montarlo (segnalibro, poi indirizzo `smb://…` della condivisione) e notifica l'esito. Attende qualche secondo
    /// l'avvio della rete; senza rete segnala subito che non si può montare.
    private func mountRemoteLibrariesAtLaunch() {
        // Montaggio automatico spento (predefinito): all'avvio resta solo il sondaggio leggero di `LibraryReachability`
        // (pallino verde vuoto = raggiungibile ma non montata); il volume si monta alla scelta della libreria.
        guard AppSettings.shared.mountRemoteLibrariesAtLaunch else { return }
        // Per ora solo SMB (altri protocolli e volumi esterni: se ne riparla dopo la risposta sulla richiesta di un utente).
        let libs = AppSettings.shared.remoteLibraries.filter { $0.isUsable && ($0.networkAddress?.lowercased().hasPrefix("smb://") ?? false) }
        guard !libs.isEmpty else { return }
        status = t("status_remote_libraries_searching")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // la rete (DNS, SMB) non è pronta subito all'avvio
            for cfg in libs {
                guard let self else { return }
                if await Self.fileExists(cfg.path) {
                    // Già montata: si aggiorna il nome vero del server (e l'indirizzo) per le volte in cui non lo sarà.
                    AppSettings.shared.refreshNetworkAddress(for: cfg.id)
                    continue
                }
                _ = await self.mountRemoteLibrary(cfg)
            }
        }
    }

    /// Volumi di rete in corso di montaggio (evita un secondo montaggio della stessa libreria).
    private var mountingLibraryIDs = Set<UUID>()

    /// Monta il volume di una libreria remota (sia all'avvio sia alla scelta dal selettore): al massimo 3 tentativi a 5 s di
    /// distanza, e solo se il server risponde (con il server spento o su un'altra rete il sistema mostrerebbe da solo la sua
    /// finestra d'errore). Notifica l'esito nella riga di stato. Vero se la libreria è raggiungibile.
    private func mountRemoteLibrary(_ cfg: RemoteLibraryConfig) async -> Bool {
        guard mountingLibraryIDs.insert(cfg.id).inserted else { return false }
        defer { mountingLibraryIDs.remove(cfg.id) }
        let name = NoticeFormat.bold(cfg.nickname)
        guard LibraryReachability.shared.isOnline else {
            status = "⚠️ " + t("status_library_mount_offline", name)
            return false
        }
        var ok = false
        for attempt in 1...3 {
            status = t("status_library_mounting", name)
            let probeStart = Date()
            let responding = await LibraryReachability.shared.respondingHost(cfg)
            AppLog.debug("Montaggio «\(cfg.nickname)» tentativo \(attempt): indirizzo salvato \(cfg.networkAddress ?? "—"), serverHost \(cfg.serverHost ?? "—"); sonda: \(responding ?? "nessuna risposta") in \(String(format: "%.1f", Date().timeIntervalSince(probeStart))) s")
            if let host = responding {
                let mountStart = Date()
                ok = await mountLibraryVolume(cfg, host: host)
                AppLog.debug("Montaggio «\(cfg.nickname)» tentativo \(attempt): \(ok ? "riuscito" : "non riuscito") dopo \(String(format: "%.1f", Date().timeIntervalSince(mountStart))) s")
                if ok { break }
            }
            // Senza risposta del server non si prova nulla (nemmeno il segnalibro): il sistema aspetterebbe oltre 2 minuti
            // e poi mostrerebbe il suo errore, con l'app ferma su «mounting».
            if attempt < 3 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        }
        if ok { AppSettings.shared.refreshNetworkAddress(for: cfg.id) }
        status = ok ? "✅ " + t("status_library_mounted", name) : "❌ " + t("status_library_mount_failed", name)
        await LibraryReachability.shared.refresh()   // il pallino passa subito a «montata»
        return ok
    }

    /// Volumi di rete montati da questa app in questa sessione: alla chiusura vengono smontati (quelli già montati prima no).
    private var volumesMountedByApp = Set<URL>()

    private func noteVolumeMountedByApp(path: String) async {
        let volume = await Task.detached(priority: .utility) {
            try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey]).volume
        }.value
        if let volume, volume.path.hasPrefix("/Volumes/") { volumesMountedByApp.insert(volume) }
    }

    /// Vero se in questa sessione si è davvero usata una libreria di rete (aperta o ascoltata): solo allora, all'uscita, si mostra
    /// il messaggio «disconnessione dalle risorse di rete» (se i volumi sono stati solo montati, lo smontaggio è silenzioso).
    private(set) var networkLibraryUsedThisSession = false

    /// Volumi di rete già montati all'avvio dell'app (origine, es. «//utente@server/MacSSD»): quelli non sono dell'app e restano.
    private let launchNetworkMountSources: Set<String> = Set(AppViewModel.networkMounts().map(\.from))

    /// Volumi di rete montati ora (SMB, AFP, NFS, WebDAV): origine e punto di montaggio. Legge solo la tabella dei montaggi del
    /// sistema, senza toccare la rete.
    nonisolated static func networkMounts() -> [(from: String, mountPoint: String)] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        func text<T>(_ value: T) -> String {
            withUnsafeBytes(of: value) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        }
        var result: [(from: String, mountPoint: String)] = []
        for i in 0..<Int(count) {
            let fs = buffer[i]
            guard ["smbfs", "afpfs", "nfs", "webdav"].contains(text(fs.f_fstypename)) else { continue }
            result.append((text(fs.f_mntfromname), text(fs.f_mntonname)))
        }
        return result
    }

    /// Vero se c'è qualcosa da smontare all'uscita: un volume montato dall'app, oppure un volume di rete comparso dopo l'avvio.
    var hasVolumesMountedByApp: Bool {
        !volumesMountedByApp.isEmpty || Self.networkMounts().contains { !launchNetworkMountSources.contains($0.from) }
    }

    /// Alla chiusura dell'app: smonta i volumi di rete che l'app stessa ha montato (anche quelli rimontati dal sistema aprendo i
    /// segnalibri di una libreria), cioè i volumi delle librerie remote che non erano già montati all'avvio. Non forza nulla:
    /// se un volume è occupato si riprova qualche volta e poi si lascia com'è; si smette di aspettare dopo 9 s in tutto.
    func unmountVolumesMountedByApp() async {
        player.stop()   // rilascia i file di rete aperti dal player
        let recorded = Array(volumesMountedByApp)
        volumesMountedByApp = []
        let libraries = AppSettings.shared.remoteLibraries
        let launchSources = launchNetworkMountSources
        let lines = await withTimeout(9) { () -> [String] in
            var mounts = Self.networkMounts().filter { !launchSources.contains($0.from) }
            // Volume di ogni libreria remota (file XML e cartella dei brani), con il percorso attuale dal segnalibro.
            var targets = Set(recorded.map(\.path))
            for lib in libraries {
                for (path, bookmark) in [(lib.path, lib.bookmark), (lib.mediaPath, lib.mediaBookmark)] where !path.isEmpty {
                    let current = bookmark.flatMap { FileBookmark.resolve($0, mounting: false)?.url.path } ?? path
                    if let m = mounts.filter({ current == $0.mountPoint || current.hasPrefix($0.mountPoint + "/") })
                        .max(by: { $0.mountPoint.count < $1.mountPoint.count }) {
                        targets.insert(m.mountPoint)
                    }
                }
            }
            mounts = mounts.filter { targets.contains($0.mountPoint) }
            let paths = Set(mounts.map(\.mountPoint)).union(targets.filter { $0.hasPrefix("/Volumes/") })
            let sources = Dictionary(mounts.map { ($0.mountPoint, $0.from) }, uniquingKeysWith: { a, _ in a })
            var out: [String] = []
            await withTaskGroup(of: String.self) { group in
                for path in paths {
                    let from = sources[path] ?? "?"
                    group.addTask {
                        // Il player rilascia i file in modo asincrono: se il volume è occupato (OSStatus -47) si riprova
                        // più volte. Se resta occupato (per esempio aperto nel Finder) non si forza nulla.
                        var lastError = ""
                        for attempt in 1...4 {
                            do {
                                try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
                                return "\(path) (\(from)): smontato" + (attempt > 1 ? " al tentativo \(attempt)" : "")
                            } catch {
                                lastError = error.localizedDescription
                                if attempt < 4 { try? await Task.sleep(nanoseconds: 600_000_000) }
                            }
                        }
                        return "\(path) (\(from)): non smontato (\(lastError))"
                    }
                }
                for await line in group { out.append(line) }
            }
            return out
        }
        AppLog.debug("Uscita: smontaggio dei volumi di rete — " + (lines.map { $0.isEmpty ? "nessuno" : $0.joined(separator: "; ") } ?? "tempo scaduto (9 s)"))
    }

    /// Prova a montare il volume di una libreria remota: prima con il segnalibro (il sistema rimonta da solo), poi aprendo l'indirizzo
    /// della condivisione senza portare Finder in primo piano; attende fino a 20 s che il file compaia. Vero se la libreria è raggiungibile.
    /// `host` è il nome del server che ha risposto alla sonda: si monta con quello (non con il nome mostrato dal Finder).
    private func mountLibraryVolume(_ cfg: RemoteLibraryConfig, host respondingHost: String) async -> Bool {
        if let data = cfg.bookmark {
            let resolved = await Task.detached(priority: .utility) { FileBookmark.resolve(data, mounting: false)?.url.path }.value
            if let path = resolved, await Self.fileExists(path) { return true }
        }
        // Indirizzo con spazi nel nome del server («smb://MacMini ServerM2/…»): `URLComponents` lo rifiuta, si codifica a parte.
        // Il nome del server è quello che ha risposto (senza spazi): sostituisce quello dell'indirizzo salvato, che il sistema potrebbe non risolvere.
        let encodedAddress: String? = cfg.networkAddress.flatMap { address -> String? in
            guard let r = address.range(of: "://") else { return address }
            let rest = address[r.upperBound...]
            let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let tail = parts.count > 1 ? "/" + parts[1] : ""
            let encodedHost = respondingHost.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? respondingHost
            // La parte dopo il server si codifica solo se contiene caratteri non validi (spazi): se è già codificata resta com'è.
            let encodedTail = URLComponents(string: address) == nil
                ? (tail.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tail) : tail
            return String(address[..<r.upperBound]) + encodedHost + encodedTail
        }
        // Se la condivisione era già montata (dall'utente o dal sistema) non è «nostra»: alla chiusura non va smontata.
        let alreadyMounted = await Self.fileExists(cfg.path)
        if let address = encodedAddress, var comps = URLComponents(string: address) {
            // Dal file alla condivisione: schema://host/Condivisione
            let share = comps.path.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            comps.path = share.isEmpty ? "" : "/" + share
            comps.query = nil
            if let url = comps.url {
                let open = NSWorkspace.OpenConfiguration()
                open.activates = false
                let openStart = Date()
                AppLog.debug("Montaggio «\(cfg.nickname)»: apro \(url.absoluteString)")
                _ = try? await NSWorkspace.shared.open(url, configuration: open)
                AppLog.debug("Montaggio «\(cfg.nickname)»: la richiesta al sistema è tornata dopo \(String(format: "%.1f", Date().timeIntervalSince(openStart))) s")
            }
        }
        for _ in 0..<20 {
            if await Self.fileExists(cfg.path) {
                if !alreadyMounted { await noteVolumeMountedByApp(path: cfg.path) }
                return true
            }
            if let data = cfg.bookmark,
               let path = await Task.detached(priority: .utility, operation: { FileBookmark.resolve(data, mounting: false)?.url.path }).value,
               await Self.fileExists(path) {
                if !alreadyMounted { await noteVolumeMountedByApp(path: path) }
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Controllo dell'esistenza di un file fuori dal thread principale (su un volume di rete in difficoltà può bloccare).
    nonisolated private static func fileExists(_ path: String) async -> Bool {
        await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: path) }.value
    }

    init() {
        NotificationCenter.default.addObserver(forName: ArtworkCache.didClearNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.artworkRevision += 1 }   // azzera le origini memorizzate (didSet)
        }
        connectedDevicesCancellable = Publishers.CombineLatest3($device, $deviceXMLInfo, $volumeDevices)
            .map { device, info, volumes -> Set<String> in
                var ids = Set<String>()
                if device != nil, let id = info?.id, !id.isEmpty { ids.insert(id) }
                for volume in volumes { if let id = volume.info.id, !id.isEmpty { ids.insert(id) } }
                return ids
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { AppSettings.shared.connectedDeviceIDs = $0 }
        MenuState.shared.attach(self)   // i menu osservano solo isBusy / dispositivo / Custom Playlist vuota
        AppFolders.migrateLegacyFolders()   // sposta nelle nuove cartelle i dati delle versioni precedenti
        startNetworkMonitor()
        LibraryReachability.shared.start()
        mountRemoteLibrariesAtLaunch()
        startAutoConnectLoop()
        startLaunchUpdateCheck()
        usbWatcher = USBRemovalWatcher(
            isConnected: { [weak self] in self?.device != nil },
            onRemoved: { [weak self] in self?.handleDeviceRemoved() })
        startVolumeWatcher()
        let startingCategory = AppSettings.shared.defaultCategory
        appleCategory = startingCategory
        deviceCategory = startingCategory

        // Quando un brano finisce da solo (non per pausa manuale), passa automaticamente al
        // successivo nella coda corrente, se c'è.
        player.onFinished = { [weak self] in self?.advanceQueue(auto: true) }
        // Tasti multimediali / Centro di Controllo / Apple TV: avanti e indietro come i pulsanti del mini player.
        player.onNext = { [weak self] in self?.playNextInQueue() }
        player.onPrevious = { [weak self] in self?.playPreviousInQueue() }

        // Cambiando il filtro per tipo in Impostazioni l'elenco Playlist si aggiorna subito.
        playlistTypeObserver = AppSettings.shared.$playlistTypeFilter.dropFirst().sink { [weak self] _ in
            // `$` emette prima che il valore cambi: si applica un attimo dopo, leggendo il valore già aggiornato.
            Task { @MainActor [weak self] in self?.applyPlaylistTypeFilter() }
        }

        transferableObserver = AppSettings.shared.$showOnlyTransferable.dropFirst().sink { [weak self] value in
            Task { @MainActor [weak self] in self?.showOnlyTransferable = value }
        }

        Self.current = self
    }

    var visibleTracks: [LocalTrack] {
        showOnlyTransferable ? tracks.filter(\.isTransferable) : tracks
    }

    var visiblePlaylists: [TrackGroup<LocalTrack>] {
        guard showOnlyTransferable else { return playlists }
        return playlists.compactMap { g in
            let ok = g.tracks.filter(\.isTransferable)
            return ok.isEmpty ? nil : TrackGroup(id: g.id, title: g.title, subtitle: playlistSubtitle(ok), tracks: ok)
        }
    }

    /// Playlist del dispositivo scelte per intero con il quadrato di spunta (id dei gruppi), impostate da
    /// `CatalogBrowser`: l'eliminazione le rimuove insieme ai loro brani.
    var selectedDevicePlaylistIDs: [String] = []

    /// Id dei file playlist da eliminare con la selezione (solo nella scheda Playlist del dispositivo).
    var selectedDevicePlaylistFileIDs: [UInt32] {
        guard deviceCategory == .playlists else { return [] }
        return selectedDevicePlaylistIDs.compactMap { Self.rawDevicePlaylistFileID(from: $0) }
    }

    var hasDeviceSelection: Bool { !selectedDeviceTrackIDs.isEmpty }

    /// Testo della barra in basso con il pannello Apple Music. L'ultima riga è sempre «N brani per un totale di …» (brani
    /// contati una volta sola); sopra, secondo la scheda: playlist (da 2 in su, sommate per intero), artisti o album
    /// presenti nella selezione (raggruppati come nelle rispettive schede). Senza selezione: «0 selezionati».
    var selectionSummaryText: String {
        let ids = selectedTrackIDs
        guard !ids.isEmpty else { return t("n_selected", 0) }
        let picked = tracks.filter { ids.contains($0.id) }
        let time = totalTimeText(picked.reduce(0) { $0 + $1.duration })
        let songs: String
        if ids.count == 1 {
            songs = time.isEmpty ? t("n_song_selected_one") : t("n_song_selected_time_one", time)
        } else {
            songs = time.isEmpty ? t("n_songs_selected", ids.count) : t("n_songs_selected_time", ids.count, time)
        }
        switch appleCategory {
        case .playlists:
            // Playlist scelte per intero: i brani si contano una volta sola, le playlist si sommano. Con UNA sola playlist
            // la riga delle playlist compare solo se ci sono anche altri brani scelti (es. una seconda playlist presa in parte).
            let groups = selectedApplePlaylistIDs.compactMap { id in
                visiblePlaylists.first(where: { $0.id == id }) ?? playlists.first(where: { $0.id == id })
            }
            guard !groups.isEmpty else { return songs }
            if groups.count == 1 {
                let only = Set(groups[0].tracks.filter(\.isTransferable).map(\.id))
                if only == ids { return songs }
            }
            let playlistTime = totalTimeText(groups.reduce(0) { $0 + $1.tracks.reduce(0) { $0 + $1.duration } })
            let first: String
            if groups.count == 1 {
                first = playlistTime.isEmpty ? t("n_playlist_selected_one") : t("n_playlist_selected_time_one", playlistTime)
            } else {
                first = playlistTime.isEmpty ? t("n_playlists_selected", groups.count) : t("n_playlists_selected_time", groups.count, playlistTime)
            }
            return first + "\n" + songs
        case .artists:
            let n = picked.groupedByAlbumArtist().count
            return (n == 1 ? t("n_artist_selected_one") : t("n_artists_selected", n)) + "\n" + songs
        case .albums:
            let n = picked.groupedByAlbum().count
            return (n == 1 ? t("n_album_selected_one") : t("n_albums_selected", n)) + "\n" + songs
        default:
            return songs
        }
    }

    /// Come sopra, per la selezione sul dispositivo.
    var deviceSelectionSummaryText: String {
        let ids = selectedDeviceTrackIDs
        let seconds = ids.isEmpty ? 0 : deviceTracks.reduce(0) { ids.contains($1.id) ? $0 + $1.duration : $0 }
        let time = totalTimeText(seconds)
        return time.isEmpty ? t("n_selected", ids.count) : t("n_selected_time", ids.count, time)
    }

    /// Dimensione totale della cartella Music: calcolata dai brani già letti, senza bisogno di
    /// un'altra scansione del dispositivo (si aggiorna da sola a ogni refresh del catalogo).
    /// Spazio che occuperebbero sul dispositivo i brani selezionati in Apple Music (solo quelli
    /// trasferibili e non già presenti: stesso nome file, e stesso artista se il dispositivo lo
    /// espone). È una stima sulle dimensioni dei file originali: una copertina aggiunta all'invio
    /// pesa qualche decina di KB in più. Mostrata nella barra dello spazio (`StorageBarView`).
    @Published private(set) var pendingTransferBytes: UInt64 = 0

    /// Indice dei file presenti sul dispositivo: nome file (minuscolo) → artisti. Ricostruito a ogni
    /// cambio di `deviceTracks`, così il controllo per riga (`isOnDevice`) è immediato.
    private var deviceFileIndex: [String: Set<String>] = [:]

    private func rebuildDeviceFileIndex() {
        var index: [String: Set<String>] = [:]
        for d in deviceTracks { index[d.filename.lowercased(), default: []].insert(d.artist.lowercased()) }
        deviceFileIndex = index
    }

    /// Numeri del riepilogo del pannello dispositivo (artisti, album, durata totale).
    struct DeviceSummary {
        var artists = 0
        var albums = 0
        var seconds: TimeInterval = 0
        /// Falso se per qualche brano la durata non si è potuta ricavare (il totale è allora parziale).
        var complete = true
    }
    private var deviceSummaryCache: DeviceSummary?

    /// Riepilogo del dispositivo, calcolato una volta e conservato finché cambiano i brani del dispositivo o della
    /// libreria (il pannello si ridisegna spesso: prima artisti, album e durate si ricalcolavano a ogni ridisegno).
    /// Il dispositivo spesso non espone la durata via MTP (resta 0): in quel caso si usa quella del brano omonimo della
    /// libreria Apple Music (stesso nome file e stesso artista, oppure unico candidato con quel nome file).
    var deviceSummary: DeviceSummary {
        if let cached = deviceSummaryCache { return cached }
        var summary = DeviceSummary()
        summary.artists = Set(deviceTracks.map { $0.artist.lowercased() }).count
        summary.albums = Set(deviceTracks.map { $0.album.lowercased() + "|" + $0.artist.lowercased() }).count
        var byFile: [String: [LocalTrack]] = [:]
        if deviceTracks.contains(where: { $0.duration <= 0 }) {
            for t in tracks where t.duration > 0 {
                if let name = t.url?.lastPathComponent.lowercased() { byFile[name, default: []].append(t) }
            }
        }
        for d in deviceTracks {
            if d.duration > 0 { summary.seconds += d.duration; continue }
            let candidates = byFile[d.filename.lowercased()] ?? []
            let artist = d.artist.lowercased()
            if let m = candidates.first(where: { $0.artist.lowercased() == artist }) ?? (candidates.count == 1 ? candidates[0] : nil) {
                summary.seconds += m.duration
            } else {
                summary.complete = false
            }
        }
        deviceSummaryCache = summary
        return summary
    }

    /// Vero se il brano risulta già sul dispositivo: stesso nome file e stesso artista (o artista
    /// vuoto sul dispositivo). Stessa logica "delta" dell'invio; serve all'icona "inviato" negli
    /// elenchi e al calcolo dello spazio da occupare.
    func isOnDevice(_ track: LocalTrack) -> Bool {
        guard device != nil, let name = track.url?.lastPathComponent.lowercased(),
              let artists = deviceFileIndex[name] else { return false }
        return artists.contains(track.artist.lowercased()) || artists.contains("")
    }

    /// Vero se una playlist di Apple Music risulta già sul dispositivo: un file playlist con lo stesso
    /// nome (anche dopo la pulizia dei caratteri non ammessi nei nomi file, come all'invio).
    func isPlaylistOnDevice(_ group: TrackGroup<LocalTrack>) -> Bool {
        guard device != nil else { return false }
        return devicePlaylistNames.contains(group.title.lowercased())
            || devicePlaylistNames.contains(Self.sanitizedFilename(group.title).lowercased())
    }

    private func updatePendingTransferBytes() {
        // Nella scheda Custom la barra mostra solo lo spazio della Custom Playlist (brani non ancora sul dispositivo), non la selezione delle altre schede.
        if appleCategory == .customPlaylist {
            var total: UInt64 = 0
            if device != nil {
                for entry in customPlaylistEntries {
                    let track = entry.track
                    if !track.isTransferable || track.isDeviceOnly || isOnDevice(track) { continue }
                    total += UInt64(max(0, track.fileSize))
                }
            }
            if total != pendingTransferBytes { pendingTransferBytes = total }
            return
        }
        guard device != nil, !selectedTrackIDs.isEmpty else {
            if pendingTransferBytes != 0 { pendingTransferBytes = 0 }
            return
        }
        var total: UInt64 = 0
        for track in tracks where selectedTrackIDs.contains(track.id) && track.isTransferable {
            if isOnDevice(track) { continue }
            total += UInt64(max(0, track.fileSize))
        }
        if total != pendingTransferBytes { pendingTransferBytes = total }
    }

    var musicFolderSize: UInt64 { deviceTracks.reduce(0) { $0 + $1.size } }

    /// true se la memoria attualmente selezionata è quella interna (euristica sul nome riportato
    /// dal dispositivo, dato che libmtp non espone un flag esplicito "interna/esterna").
    var isSelectedStorageInternal: Bool {
        guard let storage = device?.storages.first(where: { $0.id == selectedStorageID }) else { return false }
        if device?.storages.count == 1 { return true }
        return storage.name.localizedCaseInsensitiveContains("intern")
    }

    /// Vero quando i brani selezionati (non ancora sul dispositivo) superano lo spazio libero della memoria interna
    /// selezionata: stessa condizione che colora di rosso la barra della memoria. Blocca l'invio.
    var pendingExceedsFreeSpace: Bool {
        // 2.2: il blocco vale anche per le memorie esterne (scheda SD, volume) quando riportano capacità e spazio libero.
        guard pendingTransferBytes > 0,
              let storage = device?.storages.first(where: { $0.id == selectedStorageID }),
              isSelectedStorageInternal || storage.capacity > 0 else { return false }
        return pendingTransferBytes > storage.free
    }

    // MARK: - Wrapper errori / busy

    private func perform(_ message: String, scope: BusyScope = .device, _ work: () async throws -> Void) async {
        // Task.yield() prima di toccare qualunque @Published: se questa funzione viene chiamata
        // da un .task che parte nello stesso istante in cui la vista appare (es. il
        // caricamento della libreria all'avvio), questo garantisce che isBusy/status vengano
        // modificati DOPO che l'aggiornamento della vista in corso si è concluso, mai durante
        // (causa più comune dell'avviso innocuo ma rumoroso "Publishing changes from within
        // view updates").
        await Task.yield()
        busyScope = scope
        isBusy = true
        status = message
        do {
            try await work()
        } catch {
            // Trasferimento dell'XML remoto interrotto: errore (rosso), non semplice avviso.
            if case RemoteLibraryManager.ManagerError.stalled = error {
                status = "❌ " + error.localizedDescription
            } else {
                status = "⚠️ " + error.localizedDescription
            }
        }
        isBusy = false
    }

    // MARK: - Finestra di riepilogo trasferimento

    private func updateTransferStatus(_ id: String, to newStatus: TransferItemResult.Status) {
        guard var report = transferReport, let idx = report.items.firstIndex(where: { $0.id == id }) else { return }
        report.items[idx].status = newStatus
        transferReport = report
    }

    private func updateTransferNote(_ id: String, _ note: String, isWarning: Bool) {
        guard var report = transferReport, let idx = report.items.firstIndex(where: { $0.id == id }) else { return }
        report.items[idx].note = note
        report.items[idx].noteIsWarning = isWarning
        transferReport = report
    }

    func closeTransferReport() {
        transferReport = nil
        // Chiusa la finestra di trasferimento, i file di appoggio non servono più.
        Self.clearExportStagingFolder()
    }

    // MARK: - Libreria Apple Music

    /// Data dell'ultima lettura della libreria locale (serve a non rileggerla di continuo).
    private var lastLibraryLoad = Date.distantPast

    /// Quando l'app torna in primo piano la libreria locale si rilegge in silenzio, così l'elenco in memoria riflette sempre
    /// Music (brani aggiunti o tolti nel frattempo). Non parte se l'app è occupata, se è a schermo una libreria remota o se
    /// l'ultima lettura è di pochi secondi fa.
    func refreshLibraryIfNeeded() async {
        guard !isBusy, externalLibraryName == nil, externalLibraryID == nil, !localTracks.isEmpty,
              Date().timeIntervalSince(lastLibraryLoad) > 5 else { return }
        await loadLibrary(silent: true)
    }

    func loadLibrary(reloadRemote: Bool = false, silent: Bool = false) async {
        if silent {
            do {
                let start = Date()
                lastLibraryLoad = start   // subito: due «ritorni nell'app» ravvicinati non avviano due letture insieme
                let catalog = try await library.loadCatalog()
                // Nel frattempo l'app può essere diventata occupata o aver cambiato libreria: in tal caso si scarta.
                guard !isBusy, externalLibraryName == nil, externalLibraryID == nil else { return }
                lastLibraryLoad = Date()
                let changed = catalog.tracks.count != localTracks.count
                AppLog.debug("Libreria: riletta al ritorno nell'app in \(String(format: "%.1f", Date().timeIntervalSince(start))) s — \(catalog.tracks.count) brani\(changed ? " (cambiati)" : "")")
                guard changed || Set(catalog.tracks.map(\.id)) != Set(localTracks.map(\.id)) else { return }
                let byID = Dictionary(catalog.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                localTracks = catalog.tracks
                localPlaylists = catalog.playlists.map { info in
                    let items = info.trackIDs.compactMap { byID[$0] }
                    return TrackGroup(id: "playlist:\(info.id)", title: info.name,
                                      subtitle: playlistSubtitle(items), tracks: items)
                }
                localPlaylistKinds = Dictionary(catalog.playlists.map { ("playlist:\($0.id)", $0.kind ?? .regular) },
                                                uniquingKeysWith: { a, _ in a })
                tracks = localTracks
                setPlaylists(localPlaylists, kinds: localPlaylistKinds)
            } catch {
                AppLog.debug("Libreria: rilettura al ritorno nell'app non riuscita: \(error.localizedDescription)")
            }
            return
        }
        lastLibraryLoad = Date()
        await perform(t("status_loading_library"), scope: .library) {
            // MusicLibraryService legge iTunesLibrary su una propria coda seriale (mai sul thread principale):
            // con Musica aperta e librerie grandi la lettura è lenta e altrimenti bloccherebbe l'app.
            let loadStart = Date()
            let musicWasRunning = AppleMusicScripting.isMusicRunning
            AppLog.debug("Libreria: lettura iniziata (Musica \(musicWasRunning ? "aperta" : "chiusa"))")
            let catalog = try await library.loadCatalog()
            AppLog.debug("Libreria: lettura finita in \(String(format: "%.1f", Date().timeIntervalSince(loadStart))) s — \(catalog.tracks.count) brani, \(catalog.playlists.count) playlist")

            cancelAlbumArtworkTasks()
            artworkOrigins = [:]
            musicArtworkStore = [:]
            musicOrigins = [:]
            let byID = Dictionary(catalog.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            localTracks = catalog.tracks
            localPlaylists = catalog.playlists.map { info in
                let items = info.trackIDs.compactMap { byID[$0] }
                return TrackGroup(id: "playlist:\(info.id)", title: info.name,
                                  subtitle: playlistSubtitle(items), tracks: items)
            }
            localPlaylistKinds = Dictionary(catalog.playlists.map { ("playlist:\($0.id)", $0.kind ?? .regular) },
                                            uniquingKeysWith: { a, _ in a })
            // Con una libreria remota a schermo gli elenchi restano i suoi.
            guard externalLibraryName == nil else { return }
            tracks = localTracks
            setPlaylists(localPlaylists, kinds: localPlaylistKinds)
            let ok = catalog.tracks.filter(\.isTransferable).count
            status = t("status_library_loaded", catalog.tracks.count, ok, catalog.playlists.count)
            // Nessun brano in Musica: avviso con le istruzioni (vedi l'alert in `ContentView`).
            if catalog.tracks.isEmpty { showEmptyLibraryAlert = true }
        }
        AppLog.debug("Avvio: controllo apertura Musica (recupero copertine \(AppSettings.shared.autoLoadAppleArtwork ? "attivo" : "spento"), Musica \(AppleMusicScripting.isMusicRunning ? "aperta" : "chiusa"))")
        checkAutoArtworkAtStartup()
        if reloadRemote, let id = externalLibraryID,
           let cfg = AppSettings.shared.remoteLibraries.first(where: { $0.id == id }) {
            await selectRemoteLibrary(cfg, refresh: true)
        }
        if reloadRemote, let id = externalLibraryID,
           let cfg = AppSettings.shared.driveLibraries.first(where: { $0.id == id }) {
            await selectDriveLibrary(cfg, rescan: true)
        }
    }

    // MARK: - Librerie remote (file XML)

    /// Torna alla libreria locale di Musica (lasciando la libreria remota attiva, se c'è).
    func showLocalLibrary() async {
        guard externalLibraryName != nil else { return }
        let switchStart = Date()
        let memoryBefore = ProcessMemory.residentMB
        externalLibraryName = nil
        externalLibraryID = nil
        selectedTrackIDs = []
        let cancelled = cancelAlbumArtworkTasks()
        artworkOrigins = [:]
        musicArtworkStore = [:]
        musicOrigins = [:]
        artworkRevision += 1
        tracks = localTracks
        setPlaylists(localPlaylists, kinds: localPlaylistKinds)
        let ok = tracks.filter(\.isTransferable).count
        status = t("status_library_loaded", tracks.count, ok, playlists.count)
        AppLog.debug("Ritorno alla libreria locale in \(String(format: "%.2f", Date().timeIntervalSince(switchStart))) s; ricerche copertine annullate: \(cancelled); memoria dell'app: \(memoryBefore) → \(ProcessMemory.residentMB) MB")
    }

    /// Libreria di un'altra rete in attesa della conferma dell'utente (alert Sì/No in `ContentView`).
    @Published var pendingRemoteNetworkLibrary: RemoteLibraryConfig?

    /// Scelta dal menu: una libreria della rete locale (o di rete sconosciuta) si apre subito; una di un'altra rete
    /// (altra casa, VPN, hotspot) chiede prima conferma, avvisando che tutto potrebbe essere lento.
    func requestRemoteLibrary(_ cfg: RemoteLibraryConfig) async {
        if LibraryReachability.shared.isUnreachable(cfg.id) {
            status = "⚠️ " + t("library_unreachable_status", cfg.nickname)
            return
        }
        // Libreria su un volume di rete raggiungibile ma non montato: prima una conferma («Ti stai connettendo a una risorsa di
        // rete…», potrebbe essere una scelta fatta per errore), poi il montaggio con l'avanzamento nella riga di stato.
        if cfg.networkAddress?.lowercased().hasPrefix("smb://") ?? false, !(await Self.fileExists(cfg.path)) {
            try? await Task.sleep(nanoseconds: 300_000_000)   // il menu si sta chiudendo
            let model = QuitDialogModel(
                title: t("alert_mount_library_title"), message: t("alert_mount_library_message", cfg.nickname),
                buttons: [QuitDialogButton(title: t("button_connect_library"), kind: .primary),
                          QuitDialogButton(title: t("button_cancel"), isCancel: true)])
            guard DialogPresenter.run(model) == 0 else { return }
            guard await mountRemoteLibrary(cfg) else { return }
            await selectRemoteLibrary(cfg)   // la conferma data vale anche per l'avviso «altra rete»
            return
        }
        if locality(of: cfg) == .remote {
            pendingRemoteNetworkLibrary = cfg
        } else {
            await selectRemoteLibrary(cfg)
        }
    }

    /// «Sì»: apre la libreria dell'altra rete. «No»: non cambia nulla, resta la libreria in uso.
    func confirmRemoteNetworkLibrary() {
        guard let cfg = pendingRemoteNetworkLibrary else { return }
        pendingRemoteNetworkLibrary = nil
        Task { await selectRemoteLibrary(cfg) }
    }

    func declineRemoteNetworkLibrary() { pendingRemoteNetworkLibrary = nil }

    /// Mostra una delle librerie remote configurate in Impostazioni (file XML + cartella montata).
    /// Di norma usa la copia compatta già salvata (apertura immediata); con `refresh` rilegge l'XML se è cambiato.
    func selectRemoteLibrary(_ cfg: RemoteLibraryConfig, refresh: Bool = false) async {
        // Server non raggiungibile: la libreria non si apre (nel menu risulta già disattivata).
        if LibraryReachability.shared.isUnreachable(cfg.id) {
            status = "⚠️ " + t("library_unreachable_status", cfg.nickname)
            return
        }
        remotePlaybackFailures = 0
        if remotePlaybackDisabled { status = "✅ " + t("remote_playback_restored_status") }
        remotePlaybackDisabled = false   // la disattivazione vale per la libreria in uso: scegliendone un'altra si riattiva
        await perform(t("external_status_reading"), scope: .library) {
            let catalog = try await RemoteLibraryManager.shared.load(cfg, verify: false, inSettings: false,
                                                                    preferCache: !refresh)
            networkLibraryUsedThisSession = true
            // Librerie salvate prima: la rete in cui si è aperta con successo diventa la sua rete «di casa».
            if cfg.homeNetwork == nil, let network = networkID { AppSettings.shared.setHomeNetwork(network, for: cfg.id) }
            let byID = Dictionary(catalog.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            externalLibraryName = cfg.nickname
            externalLibraryID = cfg.id
            selectedTrackIDs = []
            cancelAlbumArtworkTasks()
            artworkOrigins = [:]
            musicArtworkStore = [:]
            musicOrigins = [:]
            artworkRevision += 1
            tracks = catalog.tracks
            setPlaylists(catalog.playlists.map { info in
                let items = info.trackIDs.compactMap { byID[$0] }
                return TrackGroup(id: "playlist:\(info.id)", title: info.name,
                                  subtitle: playlistSubtitle(items), tracks: items)
            }, kinds: Dictionary(catalog.playlists.map { ("playlist:\($0.id)", $0.kind ?? .regular) },
                                 uniquingKeysWith: { a, _ in a }))
            let ok = catalog.tracks.filter(\.isTransferable).count
            status = t("status_library_loaded", catalog.tracks.count, ok, catalog.playlists.count)
        }
        // Aperta dalla copia salvata: se l'XML sul server è cambiato nel frattempo, si avvisa (non si rilegge da soli).
        if !refresh {
            Task { [weak self] in
                guard await RemoteLibraryManager.shared.sourceChangedSinceCache(cfg), let self, self.externalLibraryID == cfg.id else { return }
                self.status = "⚠️ " + t("remote_library_changed_status", cfg.nickname)
            }
        }
    }

    // MARK: - Librerie «Unità esterna» (2.2)

    /// Libreria «Unità esterna» il cui catalogo è stato creato per un altro dispositivo, con formati diversi da quello
    /// collegato ora: si propone di rifarlo (alert in `ContentView`). `driveRescanTarget` è il dispositivo collegato.
    struct DriveRescanProposal: Identifiable {
        let library: DriveLibraryConfig
        let target: DriveDeviceChoice
        var id: UUID { library.id }
    }
    @Published var driveRescanProposal: DriveRescanProposal?

    /// Vero se la libreria a schermo è una libreria «Unità esterna».
    var isDriveLibraryActive: Bool {
        externalLibraryID.map { id in AppSettings.shared.driveLibraries.contains { $0.id == id } } ?? false
    }

    /// Apre una libreria «Unità esterna» dal suo indice (senza rileggere i file). Con `rescan` (o se manca l'indice) fa
    /// prima una scansione incrementale della cartella.
    func selectDriveLibrary(_ cfg: DriveLibraryConfig, rescan: Bool = false) async {
        guard DriveLibraryService.rootURL(cfg) != nil else {
            status = "⚠️ " + t("drive_err_unavailable", cfg.nickname)
            return
        }
        await perform(t("drive_status_reading"), scope: .library) {
            if rescan || DriveLibraryService.loadIndex(cfg.id) == nil {
                try await DriveLibraryManager.shared.scan(cfg) { [weak self] text in self?.status = text }
            }
            guard let catalog = await DriveLibraryManager.shared.catalog(for: cfg) else {
                throw DriveLibraryError.unavailable(cfg.nickname)
            }
            let byID = Dictionary(catalog.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            externalLibraryName = cfg.nickname
            externalLibraryID = cfg.id
            selectedTrackIDs = []
            cancelAlbumArtworkTasks()
            artworkOrigins = [:]
            musicArtworkStore = [:]
            musicOrigins = [:]
            artworkRevision += 1
            tracks = catalog.tracks
            setPlaylists(catalog.playlists.map { info in
                let items = info.trackIDs.compactMap { byID[$0] }
                return TrackGroup(id: "playlist:\(info.id)", title: info.name,
                                  subtitle: playlistSubtitle(items), tracks: items)
            }, kinds: Dictionary(catalog.playlists.map { ("playlist:\($0.id)", $0.kind ?? .regular) },
                                 uniquingKeysWith: { a, _ in a }))
            let ok = catalog.tracks.filter(\.isTransferable).count
            status = t("status_library_loaded", catalog.tracks.count, ok, catalog.playlists.count)
        }
        // Dispositivo collegato diverso da quello del catalogo e con formati diversi: si propone di rifarlo.
        let connected = DriveLibraryManager.shared.deviceChoices().first(where: \.connected)
        if let connected, connected.id != cfg.deviceID, Set(connected.extensions) != Set(cfg.extensions),
           externalLibraryID == cfg.id {
            driveRescanProposal = DriveRescanProposal(library: cfg, target: connected)
        }
    }

    /// «Ricrea per [dispositivo]»: il catalogo passa al dispositivo collegato e si rifà la scansione.
    func confirmDriveRescan() {
        guard let proposal = driveRescanProposal else { return }
        driveRescanProposal = nil
        AppSettings.shared.updateDriveLibrary(proposal.library.id) {
            $0.deviceID = proposal.target.id
            $0.deviceName = proposal.target.name
            $0.extensions = proposal.target.extensions
        }
        guard let updated = AppSettings.shared.driveLibraries.first(where: { $0.id == proposal.library.id }) else { return }
        Task { await selectDriveLibrary(updated, rescan: true) }
    }

    func declineDriveRescan() { driveRescanProposal = nil }

    /// Volume su cui sta la libreria «Unità esterna» a schermo (nil se non è una libreria esterna, se è sul disco di avvio o
    /// se l'unità non è collegata). Serve al pulsante «Espelli».
    var driveLibraryVolumeURL: URL? {
        guard let id = externalLibraryID, let cfg = AppSettings.shared.driveLibraries.first(where: { $0.id == id }),
              let root = DriveLibraryService.rootURL(cfg),
              let volume = (try? root.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              volume.path != "/", root.path.hasPrefix("/Volumes/") else { return nil }
        return volume
    }

    /// «Espelli»: ferma l'eventuale riproduzione di un brano dell'unità (tiene il file aperto) e smonta l'unità in modo sicuro.
    /// Solo se l'espulsione riesce si torna alla libreria locale; se il sistema la rifiuta (unità in uso) si resta nella libreria
    /// e la barra di stato dice il motivo.
    func ejectDriveLibrary() async {
        guard !isBusy, let volume = driveLibraryVolumeURL, let id = externalLibraryID,
              let name = externalLibraryName else { return }
        var stoppedPlayback = false
        if let playing = playerTrack, playing.id.hasPrefix("ext:drive-\(id.uuidString):") {
            stoppedPlayback = true
            player.stop()
            playerTrack = nil
            playerArtwork = nil
            playbackSource = nil
            playOrder = []
            playOrderPos = 0
        }
        // L'errore «occupato» (-47) può durare un attimo dopo aver fermato il lettore: si riprova qualche volta.
        // Dopo uno stop del lettore il file si libera con un po' di ritardo: si aspetta fino a circa 5 secondi.
        status = t("drive_ejecting", name)
        let attempts = stoppedPlayback ? 8 : 3
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                lastError = nil
                break
            } catch {
                lastError = error
                if attempt < attempts - 1 { try? await Task.sleep(nanoseconds: 700_000_000) }
            }
        }
        if let error = lastError {
            // Si cerca chi tiene aperti file dell'unità (le app dell'utente; i servizi di sistema possono non comparire).
            let users = await Task.detached(priority: .utility) { Self.processesUsing(volume: volume) }.value
            AppLog.write("Espulsione di «\(name)» rifiutata: \(error.localizedDescription). Programmi con file aperti: \(users.isEmpty ? "nessuno visibile" : users.joined(separator: ", "))")
            status = "⚠️ " + t("drive_eject_failed", name, error.localizedDescription)
                + (users.isEmpty ? "" : " " + t("drive_eject_used_by", users.joined(separator: ", ")))
            return
        }
        await showLocalLibrary()
        status = t("drive_ejected", name)
    }

    /// Nomi dei programmi (dell'utente) che hanno file aperti sul volume, ricavati con `lsof`. Vuoto se non se ne vedono.
    nonisolated private static func processesUsing(volume: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-F", "c", volume.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let names = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("c") }.map { String($0.dropFirst()) }
        return Array(Set(names)).sorted()
    }

    /// Controlla che l'unità della libreria «Unità esterna» a schermo sia ancora collegata (la si chiama quando un volume
    /// si smonta e quando l'app torna in primo piano). Se è sparita (cavo tolto, unità espulsa dal Finder) torna alla
    /// libreria locale con un avviso: i file non ci sono più e un invio fallirebbe.
    func checkDriveLibraryStillAvailable() async {
        guard !isBusy, isDriveLibraryActive, let id = externalLibraryID,
              let cfg = AppSettings.shared.driveLibraries.first(where: { $0.id == id }),
              DriveLibraryService.rootURL(cfg) == nil else { return }
        await showLocalLibrary()
        status = "⚠️ " + t("drive_disconnected_status", cfg.nickname)
    }

    /// Copertina dell'album per un brano di Apple Music (per il CatalogBrowser del pannello sinistro).
    /// Prova prima la cache di iTunesLibrary (istantanea); se assente, legge la copertina
    /// incorporata nel file stesso, su un thread in background per non bloccare lo scorrimento.
    ///
    /// Se Fix Artwork è attivo e per il brano c'è una copertina **confermata** (vedi
    /// `ArtworkCache`), mostra quella al posto dell'originale: è cosi che, dopo "Confirm", la
    /// copertina nuova compare subito sul brano e sull'album negli elenchi (vedi `artworkRevision`).
    ///
    /// **Scorrendo gli elenchi NON si interroga Musica** (lento con librerie grandi): si usano solo le
    /// copertine confermate, quelle già caricate con «Carica Artwork da Apple Music» e quelle incorporate
    /// nel file. Le altre si caricano su richiesta con `loadMissingArtwork(for:)`.
    func appleArtwork(for track: LocalTrack) async -> Data? {
        await appleArtworkResolved(for: track, fromMusic: false).data
    }

    /// Copertine già lette da Musica con il caricamento esplicito: miniature JPEG (non gli originali, per
    /// non occupare memoria), per album (artista|album) o, senza album, per brano.
    private var musicArtworkStore: [String: Data] = [:]
    /// Origine (propria / cache di Musica) delle copertine in `musicArtworkStore`, per brano. Non si azzera
    /// con `artworkRevision`, a differenza di `artworkOrigins`.
    private var musicOrigins: [String: ArtworkOrigin] = [:]

    private func storeKey(_ track: LocalTrack) -> String {
        track.album.isEmpty ? "t|" + track.id : "a|" + track.album.lowercased() + "|" + track.artist.lowercased()
    }

    /// Riduce una copertina a una miniatura JPEG (lato massimo 200 px).
    nonisolated private static func thumbnailJPEG(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, 200 / max(image.size.width, image.size.height))
        let w = max(1, Int((image.size.width * scale).rounded())), h = max(1, Int((image.size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    /// Vero se per il brano c'è già una copertina (confermata, caricata da Musica o incorporata).
    private func hasArtworkAlready(_ track: LocalTrack) -> Bool {
        if musicArtworkStore[storeKey(track)] != nil { return true }
        switch artworkOrigins[track.id] {
        case .some(.own), .some(.gmmCache), .some(.musicCache): return true
        default: return false
        }
    }

    /// Brani in attesa di caricamento copertina (il più recente in testa) e flag del ciclo di lettura.
    private var artworkQueue: [LocalTrack] = []
    private var artworkRunnerActive = false

    // MARK: Apple Music chiusa: richiesta di apertura

    enum MusicLaunchPrompt { case manual, startup }
    /// Domanda mostrata all'utente (nil = nessuna): «manual» dopo una richiesta dal click destro, «startup»
    /// all'apertura di GMM con il recupero automatico attivo.
    @Published var musicPrompt: MusicLaunchPrompt?
    private var pendingManualArtwork: [LocalTrack] = []
    private var didCheckAutoArtworkAtStartup = false

    /// All'apertura di GMM: con il recupero automatico attivo e Musica chiusa, chiede se aprirla.
    private func checkAutoArtworkAtStartup() {
        guard !didCheckAutoArtworkAtStartup else { return }
        didCheckAutoArtworkAtStartup = true
        if AppSettings.shared.autoLoadAppleArtwork && !AppleMusicScripting.isMusicRunning {
            musicPrompt = .startup
        }
    }

    /// Risposta alla domanda: se sì apre Musica in secondo piano (e, per una richiesta manuale, avvia il
    /// recupero); se no, nel caso «startup» spegne il recupero automatico per non richiederlo ancora.
    func answerMusicPrompt(open: Bool) {
        guard let prompt = musicPrompt else { return }
        musicPrompt = nil
        let pending = pendingManualArtwork
        pendingManualArtwork = []
        switch prompt {
        case .manual:
            guard open else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.launchMusicInBackground()
                self.enqueueArtwork(pending)
            }
        case .startup:
            if open {
                Task { [weak self] in await self?.launchMusicInBackground() }
            } else {
                AppSettings.shared.autoLoadAppleArtwork = false
            }
        }
    }

    /// Avvia Apple Music senza portarla in primo piano (nascosta, senza attivarla) e aspetta che sia pronta.
    private func launchMusicInBackground() async {
        guard !AppleMusicScripting.isMusicRunning,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else { return }
        status = t("status_opening_music")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            status = "⚠️ " + error.localizedDescription
            return
        }
        for _ in 0..<40 where !AppleMusicScripting.isMusicRunning {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard AppleMusicScripting.isMusicRunning else {
            status = "⚠️ " + t("status_music_not_started")
            return
        }
        // Un momento perché Musica carichi la libreria prima delle richieste.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        status = t("status_music_opened")
    }

    /// Chiamata dall'elenco (espansione di gruppi o selezione = `manual` falso; voce del click destro =
    /// `manual` vero). Una richiesta manuale con Musica chiusa chiede prima se aprirla.
    func loadMissingArtwork(for list: [LocalTrack], manual: Bool = false) {
        // Libreria di un'altra rete: nessun caricamento automatico (solo su richiesta esplicita).
        if !manual, isRemoteNetworkLibraryActive { return }
        // I brani di una libreria condivisa («ext:») non esistono in Musica: le copertine si leggono dai loro file, quindi
        // non serve (né si chiede) aprire Musica.
        let needsMusic = list.contains { !$0.id.hasPrefix("ext:") }
        if manual && needsMusic && !AppleMusicScripting.isMusicRunning {
            guard musicPrompt == nil else { return }
            pendingManualArtwork = list
            musicPrompt = .manual
            return
        }
        enqueueArtwork(list)
    }

    /// Carica da Musica le copertine mancanti dei brani indicati. Le richieste si accodano (le ultime hanno
    /// la precedenza) e un solo ciclo le esegue, mostrando l'avviso di caricamento; le miniature si
    /// aggiornano a gruppi.
    private func enqueueArtwork(_ list: [LocalTrack]) {
        let queued = Set(artworkQueue.map(\.id))
        let todo = list.filter { !hasArtworkAlready($0) && !queued.contains($0.id) }
        guard !todo.isEmpty else { return }
        artworkQueue.insert(contentsOf: todo, at: 0)
        guard !artworkRunnerActive else { return }
        artworkRunnerActive = true
        Task { [weak self] in
            guard let self else { return }
            await self.beginArtworkLoad()
            var done = 0
            while !self.artworkQueue.isEmpty {
                let track = self.artworkQueue.removeFirst()
                if !self.hasArtworkAlready(track) { _ = await self.appleArtworkResolved(for: track, fromMusic: true) }
                done += 1
                if done % 25 == 0 { self.artworkRevision += 1 }
            }
            self.artworkRevision += 1
            self.artworkRunnerActive = false
            self.endArtworkLoad()
        }
    }

    /// Origine della copertina mostrata per ogni brano (memorizzata per non rifare le ricerche).
    private var artworkOrigins: [String: ArtworkOrigin] = [:]

    /// Come `appleArtwork`, ma dice anche da dove viene la copertina (vedi `ArtworkOrigin`).
    /// Priorità dell'origine: 1. copertina nel brano (`.own`), 2. cache di Musica (`.musicCache`), 3. cache di GMM
    /// (`.gmmCache`, copertina confermata dalla ricerca online), altrimenti nessuna.
    func appleArtworkResolved(for track: LocalTrack, fromMusic: Bool = true) async -> (data: Data?, origin: ArtworkOrigin) {
        let found = await appleArtworkResolvedWithoutGMM(for: track, fromMusic: fromMusic)
        if found.origin != .none { return found }
        if AppSettings.shared.lookupMissingArtworkOnline,
           let confirmed = ArtworkCache.confirmedImage(
               forKey: ArtworkCache.key(artist: track.artist, title: track.title, album: track.album)) {
            artworkOrigins[track.id] = .gmmCache
            return (confirmed, .gmmCache)
        }
        return found
    }

    /// Cerca la copertina nel brano e nella cache di Musica (non nella cache di GMM: la aggiunge `appleArtworkResolved`).
    private func appleArtworkResolvedWithoutGMM(for track: LocalTrack, fromMusic: Bool) async -> (data: Data?, origin: ArtworkOrigin) {
        // Libreria di un'altra rete: scorrendo gli elenchi non si leggono i file (lenti da lontano). Si usa solo ciò che è
        // già stato caricato (invio alla Custom Playlist o al dispositivo); il resto resta senza copertina.
        if !fromMusic, track.id.hasPrefix("ext:"), isRemoteNetworkLibraryActive {
            if let stored = musicArtworkStore[storeKey(track)] {
                let origin = musicOrigins[track.id] ?? .own
                artworkOrigins[track.id] = origin
                return (stored, origin)
            }
            return (nil, .none)   // senza memorizzarlo: una lettura esplicita successiva deve poter avvenire
        }
        // Percorso economico (elenchi che scorrono): mai Musica, a meno che sia chiusa (allora è veloce).
        if !fromMusic && AppleMusicScripting.isMusicRunning {
            if let stored = musicArtworkStore[storeKey(track)] {
                let origin = musicOrigins[track.id] ?? .musicCache
                artworkOrigins[track.id] = origin
                return (stored, origin)
            }
            if let url = track.url,
               let own = await Task.detached(priority: .utility, operation: {
                   await MusicLibraryService.embeddedArtwork(at: url)
               }).value {
                artworkOrigins[track.id] = .own
                return (own, .own)
            }
            artworkOrigins[track.id] = ArtworkOrigin.none
            return (nil, .none)
        }
        if let own = await originalArtwork(for: track) {
            artworkOrigins[track.id] = .own
            await remember(track, data: own, origin: .own)
            return (own, .own)
        }
        // Il brano non ha una copertina propria (né in Musica né nel file): si usa quella dell'album,
        // cioè di un altro brano dello stesso album e artista, oppure quella della cache di Musica.
        if let cached = await albumArtwork(for: track) {
            artworkOrigins[track.id] = .musicCache
            await remember(track, data: cached, origin: .musicCache)
            return (cached, .musicCache)
        }
        artworkOrigins[track.id] = ArtworkOrigin.none
        return (nil, .none)
    }

    /// Conserva (come miniatura) una copertina letta da Musica, per non rileggerla scorrendo gli elenchi.
    private func remember(_ track: LocalTrack, data: Data, origin: ArtworkOrigin) async {
        let key = storeKey(track)
        musicOrigins[track.id] = origin
        guard musicArtworkStore[key] == nil else { return }
        let thumb = await Task.detached(priority: .utility) { Self.thumbnailJPEG(data) }.value
        if let thumb { musicArtworkStore[key] = thumb }
    }

    // MARK: Avviso "caricamento copertine"

    /// Vero mentre si leggono copertine da Musica (con Musica aperta): la vista mostra un piccolo avviso.
    @Published private(set) var isLoadingArtwork = false
    private var artworkLoadingCount = 0
    private var artworkHideTask: Task<Void, Never>?

    private func beginArtworkLoad() async {
        artworkLoadingCount += 1
        artworkHideTask?.cancel()
        artworkHideTask = nil
        if !isLoadingArtwork {
            isLoadingArtwork = true
            // Un attimo per far disegnare l'avviso prima che la lettura (sincrona) occupi il thread principale.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func endArtworkLoad() {
        artworkLoadingCount = max(0, artworkLoadingCount - 1)
        guard artworkLoadingCount == 0 else { return }
        // L'avviso resta ancora un momento, per non lampeggiare tra una richiesta e l'altra.
        artworkHideTask?.cancel()
        artworkHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self, self.artworkLoadingCount == 0 else { return }
            self.isLoadingArtwork = false
        }
    }

    /// Origine della copertina di un brano, per l'icona negli elenchi.
    func artworkOrigin(for track: LocalTrack) async -> ArtworkOrigin {
        if let known = artworkOrigins[track.id] { return known }
        return await appleArtworkResolved(for: track, fromMusic: false).origin
    }

    /// Ricerche di copertina "d'album" già avviate o concluse, per chiave album (artista|album) o, senza
    /// album, per brano: evita di rifare le ricerche (e le chiamate a Musica) a ogni riga che compare.
    private var albumArtworkTasks: [String: Task<Data?, Never>] = [:]

    /// Cambiando libreria le ricerche di copertina ancora in corso (anche su file di rete lenti) vanno fermate: prima si
    /// dimenticavano soltanto e continuavano a leggere in background. Restituisce quante ne ha annullate.
    @discardableResult
    private func cancelAlbumArtworkTasks() -> Int {
        let running = albumArtworkTasks.count
        albumArtworkTasks.values.forEach { $0.cancel() }
        albumArtworkTasks = [:]
        return running
    }

    /// Copertina per un brano che non ne ha una propria: (1) quella di un brano "fratello" (stesso
    /// album e artista) che ce l'ha, (2) altrimenti quella che Musica stessa mostra per il brano,
    /// letta via AppleScript (usa la cache locale delle copertine di Musica; solo se Musica è aperta).
    private func albumArtwork(for track: LocalTrack) async -> Data? {
        let key = track.album.isEmpty
            ? "id|" + track.id
            : track.album.lowercased() + "|" + track.artist.lowercased()
        if let running = albumArtworkTasks[key] { return await running.value }
        let siblings = track.album.isEmpty ? [] : tracks.filter {
            $0.id != track.id && $0.album.caseInsensitiveCompare(track.album) == .orderedSame
                && $0.artist.caseInsensitiveCompare(track.artist) == .orderedSame
        }
        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            for sibling in siblings.prefix(12) {
                if Task.isCancelled { return nil }
                if let data = await self.originalArtwork(for: sibling) { return data }
            }
            if Task.isCancelled { return nil }
            // Un brano di libreria condivisa non esiste in Musica: niente richiesta ad AppleScript.
            if track.id.hasPrefix("ext:") { return nil }
            return await AppleMusicScripting.artwork(forTrackID: track.id)
        }
        albumArtworkTasks[key] = task
        let result = await task.value
        // Senza risultato e con Musica chiusa il tentativo non vale: alla prossima apertura di Musica
        // (e al prossimo aggiornamento degli elenchi) si riprova.
        if result == nil, !AppleMusicScripting.isMusicRunning {
            albumArtworkTasks[key] = nil
            artworkOrigins[track.id] = nil
        }
        return result
    }

    /// La copertina vera del brano in Apple Music, ignorando quelle confermate in Fix Artwork: è
    /// quella mostrata come "Artwork originale" nella finestra Fix Artwork.
    func originalArtwork(for track: LocalTrack) async -> Data? {
        // Brani di librerie condivise: non sono nella libreria di Musica, si legge solo il file.
        if !track.id.hasPrefix("ext:"), let cached = await library.cachedArtwork(for: track.id) { return cached }
        guard let url = track.url else { return nil }
        return await Task.detached(priority: .utility) {
            await MusicLibraryService.embeddedArtwork(at: url)
        }.value
    }

    /// Avvia la riproduzione di un brano scelto con un doppio click nell'elenco Apple Music,
    /// tenendo come "coda" gli altri brani dello stesso contesto (vedi `CatalogBrowser.onPlay`)
    /// per i pulsanti avanti/indietro.
    func play(_ track: LocalTrack, queue: [LocalTrack], source: PlaybackSource? = nil) {
        playerQueue = queue
        playbackSource = source
        rebuildPlayOrder(keeping: track)
        startPlayback(track)
    }

    /// Casuale vale solo da playlist.
    private var effectiveShuffle: Bool { isShuffleOn && playbackPlaylistName != nil }

    /// Ricostruisce l'ordine di riproduzione: quello della coda, oppure mischiato (con il brano
    /// corrente per primo) se "casuale" è attivo da playlist.
    private func rebuildPlayOrder(keeping current: LocalTrack?) {
        guard !playerQueue.isEmpty else { playOrder = []; playOrderPos = 0; return }
        if effectiveShuffle {
            var order = playerQueue.filter { $0.id != current?.id }.shuffled()
            if let current, playerQueue.contains(where: { $0.id == current.id }) { order.insert(current, at: 0) }
            playOrder = order
            playOrderPos = 0
        } else {
            playOrder = playerQueue
            playOrderPos = playerQueue.firstIndex(where: { $0.id == current?.id }) ?? 0
        }
    }

    /// Salta a un brano dell'elenco mostrato nel balloon della playlist.
    func jumpToQueuePosition(_ index: Int) {
        guard playOrder.indices.contains(index) else { return }
        playOrderPos = index
        startPlayback(playOrder[index])
    }

    func togglePlayPause() {
        player.togglePlayPause()
    }

    func seekPlayer(to time: TimeInterval) {
        player.seek(to: time)
    }

    func playNextInQueue() { advanceQueue(auto: false) }

    /// Passa al brano successivo. `auto` = il brano è finito da solo: da playlist, senza
    /// ripetizione, alla fine dell'ultimo brano la riproduzione si ferma; altrimenti si riparte
    /// dall'inizio (con "casuale" l'ordine viene rimischiato).
    private func advanceQueue(auto: Bool) {
        guard !playOrder.isEmpty else { return }
        var pos = playOrderPos + 1
        if pos >= playOrder.count {
            if auto, playbackPlaylistName != nil, !isRepeatOn {
                player.stop()
                playerTrack = nil
                playerArtwork = nil
                playbackSource = nil
                playOrder = []
                playOrderPos = 0
                return
            }
            if effectiveShuffle { playOrder = playerQueue.shuffled() }
            pos = 0
        }
        playOrderPos = pos
        startPlayback(playOrder[pos])
    }

    func playPreviousInQueue() {
        guard !playOrder.isEmpty else { return }
        playOrderPos = (playOrderPos - 1 + playOrder.count) % playOrder.count
        startPlayback(playOrder[playOrderPos])
    }

    private func startPlayback(_ track: LocalTrack) {
        guard let url = track.url else {
            status = "⚠️ " + t("reason_file_unavailable")
            return
        }
        // Brano su volume montato (libreria condivisa di rete): il mini player mostra subito il brano scelto e il
        // file viene aperto in background, senza bloccare l'interfaccia durante la lettura di rete.
        if PlayerService.isOnMountedVolume(url) {
            let isRemote = isRemoteNetworkLibraryActive
            if isRemote, remotePlaybackDisabled {
                Task { [weak self] in await self?.offerEnableRemotePlayback(track) }
                return
            }
            player.stop()
            playerTrack = track
            loadPlayerArtwork(for: track)
            guard isRemote else {
                Task { [weak self] in
                    do {
                        try await self?.player.playPrepared(url: url)
                    } catch {
                        guard let self, self.playerTrack?.id == track.id else { return }
                        self.status = "⚠️ " + error.localizedDescription
                    }
                }
                return
            }
            // Libreria di rete: l'avvio dipende dalla velocità della connessione. Si mostra l'attesa (capsula) e, se il brano non parte
            // entro il tempo massimo, si avvisa e si offre di disattivare la riproduzione da rete (senza toccare il resto dell'app).
            networkLibraryUsedThisSession = true
            remotePlaybackLoading = RemotePlaybackLoading(trackID: track.id, title: track.title, since: Date())
            let work = Task { [weak self] in try await self?.player.playPrepared(url: url) }
            let watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.remotePlaybackTimeoutSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self, self.remotePlaybackLoading?.trackID == track.id else { return }
                self.remotePlaybackLoading = nil
                self.player.stop()   // il risultato tardivo della preparazione viene ignorato
                await self.offerDisableRemotePlayback(track)
            }
            Task { [weak self] in
                do {
                    try await work.value
                    watchdog.cancel()
                    if let self, self.remotePlaybackLoading?.trackID == track.id {
                        // Dopo uno o più insuccessi il messaggio rosso resterebbe nella capsula: lo sostituisce l'esito positivo.
                        if self.remotePlaybackFailures > 0 { self.status = "✅ " + t("remote_playback_started_status", track.title) }
                        self.remotePlaybackFailures = 0
                    }
                    if self?.remotePlaybackLoading?.trackID == track.id { self?.remotePlaybackLoading = nil }
                } catch {
                    watchdog.cancel()
                    guard let self, self.remotePlaybackLoading?.trackID == track.id else { return }
                    self.remotePlaybackLoading = nil
                    self.status = "❌ " + error.localizedDescription
                }
            }
            return
        }
        do {
            try player.play(url: url)
            playerTrack = track
            loadPlayerArtwork(for: track)
        } catch {
            status = "⚠️ " + error.localizedDescription
        }
    }

    /// Il brano non è partito in tempo: spiega che dipende dalla rete e propone di disattivare (temporaneamente) la riproduzione da rete.
    private func offerDisableRemotePlayback(_ track: LocalTrack) async {
        status = "❌ " + t("remote_playback_timeout_status", Int(Self.remotePlaybackTimeoutSeconds))
        remotePlaybackFailures += 1
        // Primi tentativi falliti: solo l'errore nella capsula (la connessione può tornare buona subito dopo).
        guard remotePlaybackFailures >= Self.remotePlaybackMaxFailures else { return }
        let count = remotePlaybackFailures
        remotePlaybackFailures = 0   // scegliendo «Mantieni attiva» si riparte da zero
        try? await Task.sleep(nanoseconds: 300_000_000)
        let model = QuitDialogModel(
            title: t("alert_remote_playback_title"),
            message: t("alert_remote_playback_message", count, Int(Self.remotePlaybackTimeoutSeconds)),
            buttons: [QuitDialogButton(title: t("button_disable_remote_playback"), kind: .primary),
                      QuitDialogButton(title: t("button_keep_remote_playback"), isCancel: true)])
        if DialogPresenter.run(model) == 0 {
            remotePlaybackDisabled = true
            player.stop()
            playerTrack = nil
            status = "ℹ️ " + t("remote_playback_disabled_status")
        }
    }

    /// Riproduzione da rete disattivata: al doppio click si chiede se riattivarla.
    private func offerEnableRemotePlayback(_ track: LocalTrack) async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let model = QuitDialogModel(
            title: t("alert_remote_playback_off_title"), message: t("alert_remote_playback_off_message"),
            buttons: [QuitDialogButton(title: t("button_enable_remote_playback"), kind: .primary),
                      QuitDialogButton(title: t("button_cancel"), isCancel: true)])
        guard DialogPresenter.run(model) == 0 else { return }
        remotePlaybackDisabled = false
        remotePlaybackFailures = 0
        status = "✅ " + t("remote_playback_restored_status")
        startPlayback(track)
    }

    private func loadPlayerArtwork(for track: LocalTrack) {
        playerArtwork = nil
        Task { [weak self] in
            guard let data = await self?.appleArtworkResolved(for: track, fromMusic: true).data else { return }
            await MainActor.run { if self?.playerTrack?.id == track.id { self?.playerArtwork = NSImage(data: data) } }
        }
    }

    /// "Send to device" sui brani selezionati: prima di toccare il dispositivo prepara in locale
    /// tutti i file in `~/Music/MusicManager/TEMP` e apre la finestra di riepilogo
    /// (`DeviceExportView`), che indica da subito quali hanno un artwork modificato; l'invio vero e
    /// proprio parte solo da lì (`confirmDeviceExport`).
    func sendSelectedTracksToDevice(skipArtworkCheck: Bool = false, confirmedPartialPlaylist: Bool = false) async {
        guard ensureDeviceWritable() else { return }
        // Spazio insufficiente (barra rossa): il pulsante è già disattivato; qui si copre anche il menu contestuale.
        if pendingExceedsFreeSpace {
            status = "⚠️ " + t("storage_pending_exceeds")
            return
        }
        // Libreria di un'altra rete: l'Apple Artwork dei brani scelti si legge ora (non scorrendo gli elenchi); poi il
        // controllo normale propone la ricerca online per quelli rimasti senza copertina.
        if isRemoteNetworkLibraryActive {
            await loadArtworkNow(tracks.filter { selectedTrackIDs.contains($0.id) && $0.isTransferable })
        }
        // Playlist scelte per intero (una o più, in QUALUNQUE scheda ci si trovi: il browser le tiene aggiornate finché tutte le
        // loro righe restano selezionate): ognuna viene inviata con il proprio file .m3u8. Gli altri brani scelti (da Brani,
        // Album, Artisti, o di playlist prese solo in parte) non entrano in nessuna playlist e si copiano come brani sciolti.
        // I brani in comune tra le playlist si copiano una volta sola.
        if !selectedApplePlaylistIDs.isEmpty {
            let groups = selectedApplePlaylistIDs.compactMap { id in
                visiblePlaylists.first(where: { $0.id == id }) ?? playlists.first(where: { $0.id == id })
            }
            let inPlaylists = Set(groups.flatMap { $0.tracks.filter(\.isTransferable).map(\.id) })
            if !groups.isEmpty, !inPlaylists.isEmpty, inPlaylists.isSubset(of: selectedTrackIDs) {
                let extras = tracks.filter { selectedTrackIDs.contains($0.id) && $0.isTransferable && !inPlaylists.contains($0.id) }
                let all = groups.flatMap { $0.tracks.filter(\.isTransferable) } + extras
                if !skipArtworkCheck, await askArtworkSearchIfNeeded(for: all, proceed: { [weak self] in
                    Task { await self?.sendSelectedTracksToDevice(skipArtworkCheck: true) }
                }) { return }
                if groups.count == 1, extras.isEmpty {
                    await sendPlaylistToDevice(groups[0])
                } else {
                    await sendPlaylistsToDevice(groups, extras: extras)
                }
                return
            }
        }
        // Selezione che contiene brani scelti nella scheda Playlist ma non è una playlist intera (o più playlist intere): una
        // playlist presa solo in parte non si può inviare come playlist. Prima di toccare il dispositivo: se la scelta viene solo
        // dalla scheda Playlist si chiede conferma di inviare i soli brani; se è mista (Playlist + Brani/Album/Artisti) si
        // propone la Custom Playlist, che applica le sue regole di aggiunta e controllo (duplicati, svuotamento, copertine).
        if !confirmedPartialPlaylist, !selectedTrackIDs.isEmpty, selectionSources.contains(.playlists) {
            if selectionSources == [.playlists] { showTracksOnlyFromPlaylistAlert = true }   // solo dalla scheda Playlist: si chiede conferma
            else { showPartialPlaylistSendAlert = true }                                      // mista: si propone la Custom Playlist
            return
        }
        let items = tracks.filter { selectedTrackIDs.contains($0.id) && $0.isTransferable }
        guard !items.isEmpty else {
            status = t("status_select_track")
            return
        }
        if !skipArtworkCheck, await askArtworkSearchIfNeeded(for: items, proceed: { [weak self] in
            Task { await self?.sendSelectedTracksToDevice(skipArtworkCheck: true, confirmedPartialPlaylist: true) }
        }) { return }
        await perform(t("status_preparing_files")) {
            try await prepareExportBody(items: items, playlistName: nil)
        }
    }

    /// «Invia all'orologio» dal menu della copertina del mini player: invia solo i brani indicati (il brano in ascolto),
    /// senza passare dalla selezione. Stessi controlli dell'invio normale: dispositivo scrivibile, spazio libero,
    /// copertine (librerie in rete e ricerca online), poi la finestra di riepilogo.
    func sendTracksToDevice(_ list: [LocalTrack], skipArtworkCheck: Bool = false) async {
        guard ensureDeviceWritable() else { return }
        let items = list.filter { $0.isTransferable }
        guard !items.isEmpty else {
            status = t("status_select_track")
            return
        }
        if let storage = device?.storages.first(where: { $0.id == selectedStorageID }), isSelectedStorageInternal || storage.capacity > 0 {
            var needed: UInt64 = 0
            for track in items where !isOnDevice(track) { needed += UInt64(max(0, track.fileSize)) }
            if needed > storage.free {
                status = "⚠️ " + t("storage_pending_exceeds")
                return
            }
        }
        if isRemoteNetworkLibraryActive { await loadArtworkNow(items) }
        if !skipArtworkCheck, await askArtworkSearchIfNeeded(for: items, proceed: { [weak self] in
            Task { await self?.sendTracksToDevice(items, skipArtworkCheck: true) }
        }) { return }
        await perform(t("status_preparing_files")) {
            try await prepareExportBody(items: items, playlistName: nil)
        }
    }

    // MARK: - File trascinati dal Finder (Direct Copy)

    private static func normalizedForMatch(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Brano della libreria Music che coincide con un file trascinato: stesso titolo e, se i tag lo riportano, stesso
    /// artista (senza maiuscole/accenti).
    func libraryMatch(for info: DroppedTrackInfo) -> LocalTrack? {
        let title = Self.normalizedForMatch(info.displayTitle)
        guard !title.isEmpty else { return nil }
        if titleIndexCache == nil {
            titleIndexCache = Dictionary(grouping: localTracks) { Self.normalizedForMatch($0.title) }
        }
        let artist = Self.normalizedForMatch(info.artist)
        // Il file del brano deve esistere ancora: se l'utente ha tolto il brano da Music (e il file) mentre l'app è aperta,
        // l'elenco in memoria è vecchio e non va usato (si tratterebbe il file trascinato come «da aggiungere»).
        return titleIndexCache?[title]?.first {
            (artist.isEmpty || Self.normalizedForMatch($0.artist) == artist)
                && ($0.url == nil || FileManager.default.fileExists(atPath: $0.url!.path))
        }
    }

    /// Vero se il file trascinato è già in Music ma il brano non è trasferibile (solo cloud, protetto).
    func isLibraryMatchBlocked(for info: DroppedTrackInfo) -> Bool {
        guard let match = libraryMatch(for: info) else { return false }
        return !match.isTransferable
    }

    private static func jpegData(from data: Data) -> Data? {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    /// «Send to Device» del pannello di importazione: 1. i file già in Music si sostituiscono coi brani della libreria
    /// ; 2. gli altri si aggiungono a Music con i dati compilati nel pannello; 3. le copertine scelte
    /// nel pannello diventano «confermate»; 4. si compone la playlist «Direct Copy» e si apre il normale riepilogo
    /// dell'invio (stesso di Music), da cui parte il trasferimento.
    func sendDroppedFiles(_ infos: [DroppedTrackInfo]) async {
        guard ensureDeviceWritable() else { return }
        guard device != nil else { status = "⚠️ " + t("status_drop_no_device"); return }
        guard !infos.isEmpty else { return }

        // Playlist «Direct Copy» già sul dispositivo: si legge, e i file già in elenco (stesso titolo e artista) si saltano
        // del tutto; gli altri si aggiungeranno in coda e la playlist si reinvia modificata.
        let existingPlaylist = devicePlaylists.first { Self.normalizedForMatch($0.title) == "direct copy" }
        func listKey(_ title: String, _ artist: String) -> String {
            Self.normalizedForMatch(title) + "|" + Self.normalizedForMatch(artist)
        }
        let existingKeys = Set((existingPlaylist?.tracks ?? []).map { listKey($0.title, $0.artist) })
        let infos = infos.filter { !existingKeys.contains(listKey($0.displayTitle, $0.artist)) }
        guard !infos.isEmpty else {
            status = t("status_drop_already_listed")
            return
        }

        // Un brano già in Music non si aggiunge mai: si usa quello della libreria. Se in Music non è trasferibile (solo
        // cloud, protetto...) ma si ha il file, si trasferisce il file trascinato con i dati (artista/album/titolo) del
        // brano di Music, senza aggiungerlo alla libreria: finisce comunque nella playlist «Direct Copy».
        var entries: [(info: DroppedTrackInfo, track: LocalTrack?)] = []
        var toAdd: [Int] = []
        var problems: [String] = []
        for info in infos {
            if let match = libraryMatch(for: info) {
                if match.isTransferable {
                    entries.append((info, match))
                } else {
                    let size = ((try? FileManager.default.attributesOfItem(atPath: info.url.path))?[.size] as? Int) ?? 0
                    entries.append((info, LocalTrack(id: "drop:" + info.id.uuidString, title: match.title, artist: match.artist,
                                                     album: match.album, url: info.url, fileSize: size,
                                                     isDRMProtected: false, isCloud: false, duration: match.duration,
                                                     trackNumber: match.trackNumber, albumArtist: match.albumArtist,
                                                     isCompilation: match.isCompilation, discNumber: match.discNumber,
                                                     discCount: match.discCount)))
                }
            } else {
                toAdd.append(entries.count)
                entries.append((info, nil))
            }
        }

        AppLog.debug("Drop: \(infos.count) file, già in Music: \(entries.count - toAdd.count), da aggiungere: \(toAdd.count); conferma attiva: \(AppSettings.shared.confirmBeforeMusicChanges)")
        // 2. File da aggiungere a Music (solo quelli non presenti in libreria). Con «Chiedi conferma prima di aggiungere a Music»
        // (Impostazioni ▸ Generale) si chiede prima: «Solo sull'orologio» usa il file trascinato così com'è, senza toccare Music.
        if !toAdd.isEmpty {
            switch await askBeforeAddingToMusic(context: .dropped, titles: toAdd.map { entries[$0].info.displayTitle }) {
            case .cancel:
                return
            case .skip:
                for i in toAdd {
                    let info = entries[i].info
                    let size = ((try? FileManager.default.attributesOfItem(atPath: info.url.path))?[.size] as? Int) ?? 0
                    entries[i].track = LocalTrack(
                        id: "drop:" + info.id.uuidString, title: info.displayTitle,
                        artist: info.artist.isEmpty ? t("unknown_artist") : info.artist, album: info.album,
                        url: info.url, fileSize: size, isDRMProtected: false, isCloud: false, duration: info.duration,
                        trackNumber: Int(info.track) ?? 0, albumArtist: info.albumArtist, isCompilation: info.compilation,
                        discNumber: Int(info.disc) ?? 0, discCount: Int(info.discTotal) ?? 0,
                        genre: info.genre, year: Int(info.year) ?? 0)
                }
                toAdd = []
            case .add:
                break
            }
        }
        if !toAdd.isEmpty {
            if !AppleMusicScripting.isMusicRunning { await launchMusicInBackground() }
            guard AppleMusicScripting.isMusicRunning else { status = "⚠️ " + t("status_music_not_started"); return }
            var addedIDs: [Int: String] = [:]
            for (n, i) in toAdd.enumerated() {
                let info = entries[i].info
                status = t("status_drop_adding", n + 1, toAdd.count, info.displayTitle)
                progress = Double(n) / Double(max(toAdd.count, 1))
                // Si impostano solo i dati mancanti nel file e compilati nel pannello.
                func value(_ key: String, _ text: String) -> String { info.locked.contains(key) ? "" : text }
                var fields = AppleMusicScripting.NewTrackFields()
                fields.name = value("title", info.title)
                fields.artist = value("artist", info.artist)
                fields.album = value("album", info.album)
                fields.albumArtist = value("albumArtist", info.albumArtist)
                fields.composer = value("composer", info.composer)
                fields.genre = value("genre", info.genre)
                fields.year = value("year", info.year)
                fields.trackNumber = value("track", info.track)
                fields.trackCount = value("trackTotal", info.trackTotal)
                fields.discNumber = value("disc", info.disc)
                fields.discCount = value("discTotal", info.discTotal)
                fields.compilation = info.compilation && !info.locked.contains("compilation")
                let url = info.url
                let fieldsCopy = fields
                // Copertina scelta nel pannello: la imposta Music stessa sul brano appena aggiunto (vedi sotto).
                var artworkFile: URL?
                if info.coverChanged, let art = info.artwork, let jpeg = Self.jpegData(from: art) {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gmm-cover-\(UUID().uuidString).jpg")
                    if (try? jpeg.write(to: tmp)) != nil { artworkFile = tmp }
                }
                let artworkURL = artworkFile
                defer { if let artworkURL { try? FileManager.default.removeItem(at: artworkURL) } }
                do {
                    let hex = try await Task.detached {
                        try AppleMusicScripting.addFileToLibrary(url, fields: fieldsCopy, artworkFile: artworkURL)
                    }.value
                    if let hex, let number = UInt64(hex, radix: 16) {
                        addedIDs[i] = String(number)
                    } else {
                        problems.append(info.displayTitle)
                    }
                } catch {
                    problems.append("\(info.displayTitle): \(error.localizedDescription)")
                }
            }
            // Rilettura della libreria: i nuovi brani possono comparire con un po' di ritardo.
            if !addedIDs.isEmpty {
                let wanted = Set(addedIDs.values)
                for _ in 0..<6 {
                    await loadLibrary()
                    if wanted.isSubset(of: Set(localTracks.map(\.id))) { break }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                for (i, id) in addedIDs {
                    if let track = localTracks.first(where: { $0.id == id }) {
                        entries[i].track = track
                    } else {
                        problems.append(entries[i].info.displayTitle)
                    }
                }
            }
        }

        // 3. Copertine scelte per i brani NON aggiunti a Music (già in libreria, o file usato al posto di un brano in cloud):
        // confermate, così vengono scritte nel file inviato (solo AAC/M4A). Per i brani aggiunti ha provveduto Music.
        let addedSet = Set(toAdd)
        for (i, entry) in entries.enumerated() where !addedSet.contains(i) {
            guard let track = entry.track, entry.info.coverChanged, let art = entry.info.artwork,
                  let jpeg = Self.jpegData(from: art) else { continue }
            _ = ArtworkCache.storeConfirmed(key: ArtworkCache.key(artist: track.artist, title: track.title, album: track.album),
                                            imageData: jpeg, chosenOnline: false)   // scelta nel pannello di importazione, non online
        }
        artworkRevision += 1

        // 4. Playlist «Direct Copy» e riepilogo dell'invio.
        var seen = Set<String>()
        let final = entries.compactMap(\.track).filter { $0.isTransferable && seen.insert($0.id).inserted }
        guard !final.isEmpty else {
            status = "⚠️ " + t("status_drop_not_added", problems.count, problems.joined(separator: "; "))
            return
        }
        // Playlist già sul dispositivo: prima i suoi brani (solo nell'elenco, senza ricopiarli), poi i nuovi.
        var allItems = final
        if let existingPlaylist {
            let current: [LocalTrack] = existingPlaylist.tracks.map { d in
                var only = LocalTrack(id: "device:\(d.id)", title: d.title, artist: d.artist, album: d.album, url: nil,
                                      fileSize: Int(d.size), isDRMProtected: false, isCloud: false,
                                      duration: d.duration, trackNumber: 0)
                only.devicePath = d.relativePath
                return only
            }
            allItems = current + final
        }
        let sendItems = allItems
        await perform(t("status_preparing_files")) {
            try await prepareExportBody(items: sendItems, playlistName: "Direct Copy")
        }
        if !problems.isEmpty {
            status = "⚠️ " + t("status_drop_not_added", problems.count, problems.joined(separator: "; "))
        }
    }

    /// Invio vero e proprio dei brani (file già preparati in TEMP) al dispositivo.
    private func runSendTracksToDevice(_ items: [LocalTrack]) async {
        transferReport = TransferReport(
            title: t("transfer_dialog_title_tracks"),
            items: items.map { TransferItemResult(id: $0.id, title: $0.title, artist: $0.artist) }
        )

        await perform(t("status_preparing")) {
            let musicFolder = try await mtp.ensureFolder(named: "Music",
                                                         parentID: mtpRootParent,
                                                         storageID: selectedStorageID)
            var folderCache: [String: UInt32] = [:]
            var existingCache: [UInt32: Set<String>] = [:]
            var okCount = 0
            var failCount = 0
            for (i, track) in items.enumerated() {
                if transferStopRequested { break }   // «Cancel» confermato: si ferma dopo il file in corso
                guard let url = track.url else {
                    updateTransferStatus(track.id, to: .error)
                    failCount += 1
                    continue
                }
                updateTransferStatus(track.id, to: .processing)
                status = t("status_sending", i + 1, items.count, track.title)
                progress = Double(i) / Double(max(items.count, 1))
                let targetFolder = try await ensureArtistAlbumFolder(artist: track.artist, album: track.album,
                                                                     musicFolderID: musicFolder, cache: &folderCache)
                let resolved = await stagedOrResolved(for: track, originalURL: url)
                defer { if let dir = resolved.tempDirectory { try? FileManager.default.removeItem(at: dir) } }
                if let warning = resolved.warning { updateTransferNote(track.id, warning, isWarning: true) }
                        let uploadURL = resolved.url
                let outcome = try await uploadIfNeededAndVerify(from: uploadURL,
                                                                storageID: selectedStorageID,
                                                                parentID: targetFolder,
                                                                forceOverwrite: resolved.overwriteKey != nil,
                                                                existingCache: &existingCache)
                switch outcome {
                case .transferred:
                    recordArtworkApplied(resolved, trackID: track.id)
                    updateTransferStatus(track.id, to: .transferred)
                    okCount += 1
                case .transferredWithoutArtwork:
                    updateTransferNote(track.id, t("artwork_not_applied_restored", lastUploadError ?? "?"), isWarning: true)
                    updateTransferStatus(track.id, to: .transferred)
                    okCount += 1
                case .skipped:
                    updateTransferStatus(track.id, to: .skipped)
                    okCount += 1
                case .failed:
                    if let error = lastUploadError { updateTransferNote(track.id, error, isWarning: true) }
                    updateTransferStatus(track.id, to: .error)
                    failCount += 1
                }
            }
            status = t("status_refreshing_device")
            // Alcuni dispositivi impiegano un istante ad aggiornare il proprio elenco interno
            // dopo una scrittura: una breve pausa prima di rileggere evita di mostrare conteggi
            // non aggiornati (lo stesso motivo per cui un refresh manuale, poco dopo, li corregge).
            try? await Task.sleep(nanoseconds: 500_000_000)
            let refreshed = await reloadDeviceBounded()
            status = failCount == 0
                ? t("status_sent_tracks", okCount, NoticeFormat.bold(deviceNameForAlerts))
                : t("status_sent_tracks_with_failures", okCount, failCount, NoticeFormat.bold(deviceNameForAlerts))
            if !refreshed { status += " " + t("status_refresh_pending") }
        }
    }

    /// Trova, creando se necessario, la cartella `Music/<Artista>/<Album>` sul dispositivo.
    /// `cache` evita di rileggere ripetutamente il dispositivo per artisti/album già incontrati
    /// nella stessa operazione di invio.
    private func ensureArtistAlbumFolder(artist: String, album: String, musicFolderID: UInt32,
                                          cache: inout [String: UInt32]) async throws -> UInt32 {
        let artistName = Self.sanitizedFilename(artist.isEmpty ? t("unknown") : artist)
        let albumName = Self.sanitizedFilename(album.isEmpty ? t("unknown") : album)
        rememberDeviceNames(artist: artist, album: album)

        let artistID: UInt32
        if let cached = cache["a:\(artistName)"] {
            artistID = cached
        } else {
            artistID = try await mtp.ensureFolder(named: artistName, parentID: musicFolderID, storageID: selectedStorageID)
            cache["a:\(artistName)"] = artistID
        }

        let albumKey = "al:\(artistName)/\(albumName)"
        if let cached = cache[albumKey] { return cached }
        let albumID = try await mtp.ensureFolder(named: albumName, parentID: artistID, storageID: selectedStorageID)
        cache[albumKey] = albumID
        return albumID
    }

    /// Se la funzione Fix Artwork è attiva (Impostazioni), il file è AAC/M4A e l'utente ha già
    /// **confermato** una copertina per questo brano nella finestra Fix Artwork (`ArtworkCache`),
    /// la scrive in una copia temporanea con lo stesso nome dell'originale (`ArtworkExporter`), da
    /// inviare al dispositivo al posto del file vero — l'originale della libreria Apple Music non
    /// viene mai aperto in scrittura. Nessuna ricerca di rete e nessuna scelta automatica qui: se
    /// non c'è una copertina confermata, o l'esportazione fallisce in qualunque punto, restituisce
    /// semplicemente il file originale (questa funzione non deve mai poter bloccare o far fallire
    /// un invio).
    ///
    /// `overwriteKey` è non-nil solo quando la copertina confermata non è ancora mai arrivata sul
    /// dispositivo: il chiamante deve allora sostituire un eventuale file già presente con lo
    /// stesso nome (altrimenti la logica "delta" lo salterebbe) e, a trasferimento riuscito,
    /// segnarla come presente con `ArtworkCache.markPushedToDevice`. Una volta presente, gli invii
    /// successivi tornano alla normale logica "delta" (un brano già sull'orologio non si ricopia).
    /// Il chiamante, se riceve una cartella temporanea, deve eliminarla a fine utilizzo (vedi i due
    /// punti di invio più sotto, entrambi con un `defer` per questo).
    private func resolvedUpload(for track: LocalTrack, originalURL: URL) async -> ResolvedUpload {
        guard AppSettings.shared.lookupMissingArtworkOnline else { return ResolvedUpload(url: originalURL) }
        let ext = originalURL.pathExtension.lowercased()
        guard ext == "m4a" || ext == "aac" else { return ResolvedUpload(url: originalURL) }

        let key = ArtworkCache.key(artist: track.artist, title: track.title, album: track.album)
        // Vero se la copertina è stata presa dalla cache di Apple Music proprio in questa chiamata.
        var recoveredFromAppleNow = false
        if ArtworkCache.confirmedImage(forKey: key) == nil {
            // Nessuna copertina confermata: se il brano ha solo quella della cache di Musica (o di un
            // brano dello stesso album), la si tratta come una copertina trovata online e confermata.
            let resolved = await appleArtworkResolved(for: track)
            if resolved.origin == .musicCache, let data = resolved.data,
               let jpeg = ArtworkLookupService.compressedJPEG(from: data) {
                ArtworkCache.storeConfirmed(key: key, imageData: jpeg, fromApple: true)
                recoveredFromAppleNow = true
            }
        }
        guard let artwork = ArtworkCache.confirmedImage(forKey: key) else { return ResolvedUpload(url: originalURL) }

        switch await ArtworkExporter.exportWithArtwork(sourceURL: originalURL, artworkData: artwork) {
        case .failure(let error):
            // Copertina confermata ma non scrivibile nel file: si invia l'originale, e il motivo
            // compare sotto il brano nella finestra di trasferimento (non resta un fallimento muto).
            return ResolvedUpload(url: originalURL, warning: t("artwork_not_applied", error.reason))
        case .success(let exported):
            let needsOverwrite = !ArtworkCache.isPushedToDevice(key: key)
            return ResolvedUpload(url: exported.fileURL, tempDirectory: exported.tempDirectory,
                                  overwriteKey: needsOverwrite ? key : nil, isEnriched: true,
                                  isAppleArtwork: recoveredFromAppleNow)
        }
    }

    // MARK: - Preparazione in locale ("TEMP") e invio al dispositivo

    /// Cartella di appoggio con i file pronti per il dispositivo: audio (con le copertine già
    /// scritte) nella struttura `Artista/Album/` e il file `.m3u8` della playlist nella radice.
    /// Viene svuotata a ogni nuova preparazione.
    static var exportStagingFolder: URL {
        localExportFolder.appendingPathComponent("TEMP", isDirectory: true)
    }

    /// File preparati in TEMP in attesa di conferma nella finestra di riepilogo.
    private var stagedUploads: [String: ResolvedUpload] = [:]
    private var stagedTracks: [LocalTrack] = []

    /// Per i brani preparati in TEMP restituisce il file in TEMP; altrimenti lo prepara al volo
    /// (non dovrebbe succedere: l'invio parte solo dopo la preparazione).
    private func stagedOrResolved(for track: LocalTrack, originalURL: URL) async -> ResolvedUpload {
        if let staged = stagedUploads[track.id] { return staged }
        return await resolvedUpload(for: track, originalURL: originalURL)
    }

    /// Prepara in locale tutti i file (audio e `.m3u8`) senza toccare il dispositivo e apre la
    /// finestra di riepilogo. Gira già dentro `perform(...)`.
    private func prepareExportBody(items: [LocalTrack], playlistName: String?,
                                   playlists: [(name: String, tracks: [LocalTrack])] = []) async throws {
        let fm = FileManager.default
        let base = Self.exportStagingFolder
        if fm.fileExists(atPath: base.path) { try fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        var staged: [String: ResolvedUpload] = [:]
        var stagedList: [LocalTrack] = []
        var planItems: [DeviceExportPlan.Item] = []
        var relativePaths: [String] = []
        // Percorso relativo di ogni brano preparato (per i file .m3u8 di più playlist).
        var relativeByTrack: [String: String] = [:]

        for (i, track) in items.enumerated() {
            // Brano presente solo sul dispositivo: nessun file da preparare, entra nella playlist col suo percorso. Si
            // controlla che sia ancora sul dispositivo; se non c'è più, resta fuori e il riepilogo lo segnala.
            if let devicePath = track.devicePath {
                let present = deviceFileExists(relativePath: devicePath)
                planItems.append(DeviceExportPlan.Item(id: track.id, title: track.title, artist: track.artist,
                                                       album: track.album, artworkModified: false,
                                                       artworkSource: .deviceOnly,
                                                       problem: present ? nil : t("device_only_missing_note")))
                if present {
                    stagedList.append(track)
                    relativePaths.append(devicePath)
                    relativeByTrack[track.id] = devicePath
                }
                continue
            }
            guard let url = track.url else { continue }
            status = t("status_preparing_file_n", i + 1, items.count, track.title)
            progress = Double(i) / Double(max(items.count, 1))

            let artistName = Self.sanitizedFilename(track.artist.isEmpty ? t("unknown") : track.artist)
            let albumName = Self.sanitizedFilename(track.album.isEmpty ? t("unknown") : track.album)
            let folder = base.appendingPathComponent(artistName, isDirectory: true)
                .appendingPathComponent(albumName, isDirectory: true)
            let destination = folder.appendingPathComponent(url.lastPathComponent)

            let resolved = await resolvedUpload(for: track, originalURL: url)
            defer { if let dir = resolved.tempDirectory { try? fm.removeItem(at: dir) } }

            // Origine della copertina per il riepilogo: scritta ora da cache Apple / da cache GMM, oppure
            // già nel brano, oppure nessuna.
            let artworkSource: ExportArtworkSource
            if resolved.isEnriched {
                let cacheKey = ArtworkCache.key(artist: track.artist, title: track.title, album: track.album)
                artworkSource = resolved.isAppleArtwork ? .apple
                    : (ArtworkCache.chosenOnlineThisSession.contains(cacheKey) ? .online : .garminCache)
            } else {
                artworkSource = (await originalArtwork(for: track)) != nil ? .file : .none
            }

            if resolved.isEnriched {
                // Artwork online confermata: il file con la copertina scritta va in TEMP e da lì
                // verrà inviato al dispositivo.
                do {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    try fm.copyItem(at: resolved.url, to: destination)
                } catch {
                    planItems.append(DeviceExportPlan.Item(id: track.id, title: track.title, artist: track.artist,
                                                           album: track.album, artworkModified: false,
                                                           artworkSource: artworkSource,
                                                           problem: error.localizedDescription))
                    continue
                }
                staged[track.id] = ResolvedUpload(url: destination, tempDirectory: nil,
                                                  overwriteKey: resolved.overwriteKey,
                                                  warning: resolved.warning, isEnriched: true,
                                                  isAppleArtwork: resolved.isAppleArtwork)
            } else {
                // Artwork di Apple Music (o nessuna): si invia l'originale così com'è, direttamente
                // da Apple Music, senza copie.
                staged[track.id] = ResolvedUpload(url: url, tempDirectory: nil,
                                                  overwriteKey: nil, warning: resolved.warning, isEnriched: false)
            }
            stagedList.append(track)
            relativePaths.append("\(artistName)/\(albumName)/\(url.lastPathComponent)")
            relativeByTrack[track.id] = "\(artistName)/\(albumName)/\(url.lastPathComponent)"
            planItems.append(DeviceExportPlan.Item(id: track.id, title: track.title, artist: track.artist,
                                                   album: track.album, artworkModified: resolved.isEnriched,
                                                   artworkSource: artworkSource,
                                                   problem: resolved.warning))
        }

        // File playlist (stesso formato di "Salva in cartella"): serve da controllo, l'invio al
        // dispositivo lo ricrea con gli stessi percorsi.
        if !playlists.isEmpty {
            // Più playlist: un file .m3u8 per ciascuna, con i soli suoi brani.
            for list in playlists {
                let paths = list.tracks.compactMap { relativeByTrack[$0.id] }
                guard !paths.isEmpty else { continue }
                let fileURL = base.appendingPathComponent("\(Self.sanitizedFilename(list.name)).m3u8")
                try (paths.joined(separator: "\r\n") + "\r\n").write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } else if let playlistName, !relativePaths.isEmpty {
            let fileURL = base.appendingPathComponent("\(Self.sanitizedFilename(playlistName)).m3u8")
            let content = relativePaths.joined(separator: "\r\n") + "\r\n"
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        guard !stagedList.isEmpty else {
            status = t("status_export_nothing_prepared")
            return
        }
        stagedUploads = staged
        stagedTracks = stagedList
        // Playlist da inviare insieme: solo i loro brani effettivamente preparati.
        stagedPlaylists = playlists.map { list in
            (list.name, list.tracks.filter { relativeByTrack[$0.id] != nil })
        }
        let modified = planItems.filter(\.artworkModified).count
        let displayPath = (base.path as NSString).abbreviatingWithTildeInPath
        exportPlan = DeviceExportPlan(playlistName: playlistName, folderPath: displayPath, items: planItems)
        status = t("status_export_ready", stagedList.count, modified)
    }

    /// "Invia" nella finestra di riepilogo: parte il trasferimento dei file preparati.
    func confirmDeviceExport() async {
        guard ensureDeviceWritable() else { return }
        guard let plan = exportPlan else { return }
        let items = stagedTracks
        let name = plan.playlistName
        exportPlan = nil
        // «Online Artwork» vale solo per l'invio che segue la ricerca online: dal successivo le stesse copertine sono «Garmin Cache».
        ArtworkCache.chosenOnlineThisSession.removeAll()
        transferStopRequested = false
        transferWasStopped = false
        // Una pausa perché la finestra di riepilogo si chiuda prima che si apra quella di invio.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let multi = stagedPlaylists
        // Brani preparati che non stanno in nessuna playlist dell'invio (scelti da altre schede): si copiano come brani sciolti.
        let inLists = Set(multi.flatMap { $0.tracks.map(\.id) })
        let extras = items.filter { !inLists.contains($0.id) }
        if multi.count >= 2 || (!multi.isEmpty && !extras.isEmpty) {
            // Più playlist: ciascuna con il proprio file .m3u8 (prima i brani, poi il file).
            // Un solo `perform` per l'intero ciclo: `isBusy` resta acceso fino alla fine dell'ultima playlist, così il
            // pulsante «Chiudi» della finestra di trasferimento non si riattiva tra una playlist e la successiva.
            await perform(t("status_preparing_playlist", multi.first?.name ?? "")) {
                let plannedTotal = multi.reduce(0) { $0 + $1.tracks.count } + extras.count
                for list in multi where !list.tracks.isEmpty {
                    if transferStopRequested { break }
                    status = t("status_preparing_playlist", list.name)
                    do {
                        try await sendTracksAsPlaylist(name: list.name, items: list.tracks, multiple: true, plannedTotal: plannedTotal,
                                                       hasOtherSongs: !extras.isEmpty)
                    } catch {
                        // Una playlist in errore non ferma le altre: l'errore resta nello stato e si passa oltre.
                        status = "⚠️ " + error.localizedDescription
                    }
                }
                // Ultima voce dell'elenco: i brani sciolti, copiati senza file playlist.
                if !extras.isEmpty, !transferStopRequested {
                    status = t("status_preparing_files")
                    do {
                        try await sendTracksAsPlaylist(name: t("transfer_other_songs"), items: extras, multiple: true, plannedTotal: plannedTotal,
                                                       hasOtherSongs: true, withPlaylistFile: false)
                    } catch {
                        status = "⚠️ " + error.localizedDescription
                    }
                }
            }
        } else if let name {
            await perform(t("status_preparing_playlist", name)) {
                try await sendTracksAsPlaylist(name: name, items: items)
            }
        } else {
            // `runSendTracksToDevice` apre già il proprio `perform`.
            await runSendTracksToDevice(items)
        }
        stagedUploads = [:]
        stagedTracks = []
        stagedPlaylists = []
        // Invio interrotto dall'utente: la selezione resta, per poterla modificare e rifare l'invio.
        if transferStopRequested {
            transferWasStopped = true
            status = "⚠️ " + t("status_send_stopped")
        }
        // Invio concluso (brani, playlist o più playlist): la selezione ha fatto il suo lavoro e si svuota in tutte le schede,
        // così si riparte puliti. Se l'operazione è fallita per intero (stato con ⚠️) si lascia, per poter riprovare; gli
        // esiti dei singoli brani restano nel riepilogo del trasferimento.
        if !status.hasPrefix("⚠️") { clearSelection() }
    }

    /// Svuota `~/Music/MusicManager/TEMP` (file di appoggio per l'invio al dispositivo).
    static func clearExportStagingFolder() {
        try? FileManager.default.removeItem(at: exportStagingFolder)
    }

    func cancelDeviceExport() {
        Self.clearExportStagingFolder()
        exportPlan = nil
        stagedUploads = [:]
        stagedTracks = []
        stagedPlaylists = []
        status = t("status_export_cancelled")
    }

    /// Esito di `resolvedUpload`: quale file inviare davvero e cosa fare prima/dopo l'invio.
    private struct ResolvedUpload {
        let url: URL
        /// Cartella temporanea da eliminare a fine invio (nil se si invia l'originale).
        var tempDirectory: URL? = nil
        /// Non-nil se la copertina confermata non è ancora mai arrivata sul dispositivo (vedi sopra).
        var overwriteKey: String? = nil
        /// Motivo per cui una copertina confermata non è stata applicata, da mostrare nella
        /// finestra di trasferimento.
        var warning: String? = nil
        /// Vero se il file contiene una copertina scritta da questa app (cioè con artwork modificato).
        var isEnriched = false
        /// Vero se la copertina scritta viene da Apple Music e non da una ricerca online.
        var isAppleArtwork = false
    }

    /// A trasferimento riuscito di un file con copertina applicata: segna la copertina come
    /// presente sul dispositivo, scrive "Artwork aggiornato" sotto il brano nella finestra di
    /// trasferimento e fa ricaricare le miniature negli elenchi.
    private func recordArtworkApplied(_ resolved: ResolvedUpload, trackID: String) {
        if let key = resolved.overwriteKey { ArtworkCache.markPushedToDevice(key: key) }
        guard resolved.isEnriched else { return }
        updateTransferNote(trackID, t("transfer_note_artwork_applied"), isWarning: false)
        artworkRevision += 1
    }

    /// Apre la finestra "Fix Artwork" sui brani selezionati (voce del menu contestuale, visibile
    /// solo con la funzione attiva in Impostazioni). Considera solo i brani AAC/M4A trasferibili: è
    /// l'unico formato in cui l'app sa scrivere una copertina (vedi `ArtworkExporter`); gli altri
    /// vengono ignorati, con una nota nella barra di stato. La ricerca online parte solo quando
    /// l'utente arriva su un brano nella finestra, e nulla viene memorizzato senza "Confirm".
    func startFixArtwork(for override: [LocalTrack]? = nil, then followUp: (() -> Void)? = nil) {
        guard ensureDeviceWritable() else { return }
        let selected = override ?? tracks.filter { selectedTrackIDs.contains($0.id) }
        let eligible = selected.filter { track in
            guard track.isTransferable, let ext = track.url?.pathExtension.lowercased() else { return false }
            return ext == "m4a" || ext == "aac"
        }
        guard !eligible.isEmpty else {
            status = t("status_fix_artwork_none_eligible")
            return
        }
        if eligible.count < selected.count {
            status = t("status_fix_artwork_skipped_unsupported", selected.count - eligible.count)
        }

        let lookup = artworkLookup
        fixArtworkSession = FixArtworkSession(
            tracks: eligible,
            // "Artwork originale": quella vera, non una già confermata (vedi `originalArtwork`).
            fetchOriginal: { [weak self] track in await self?.originalArtwork(for: track) },
            fetchOnline: { track in
                await lookup.search(artist: track.artist, title: track.title, durationSeconds: track.duration)
            },
            // Dopo ogni "Confirm": gli elenchi ricaricano le miniature, cosi la copertina nuova
            // compare subito sul brano e sull'album.
            onConfirmed: { [weak self] in self?.artworkRevision += 1 },
            // Altri brani dello stesso album (e artista), AAC/M4A, senza copertina propria né confermata:
            // dopo il «Confirm» si propone di dare loro la stessa copertina.
            siblings: { [weak self] track in
                guard let self else { return [] }
                // Stesso album = stesso titolo e stesso artista DELL'ALBUM (se manca, quello del brano): un brano con ospiti
                // («Earth, Wind & Fire Feat. The Emotions») resta nell'album, e le compilation con artisti diversi si riconoscono.
                func albumOwner(_ t: LocalTrack) -> String { t.albumArtist.isEmpty ? t.artist : t.albumArtist }
                return self.tracks.filter { other in
                    guard other.id != track.id, other.isTransferable,
                          other.album.caseInsensitiveCompare(track.album) == .orderedSame,
                          albumOwner(other).caseInsensitiveCompare(albumOwner(track)) == .orderedSame,
                          let ext = other.url?.pathExtension.lowercased(), ext == "m4a" || ext == "aac"
                    else { return false }
                    let key = ArtworkCache.key(artist: other.artist, title: other.title, album: other.album)
                    return ArtworkCache.confirmedImage(forKey: key) == nil && !self.hasArtworkAlready(other)
                }
            },
            onFinish: { [weak self] confirmedCount in
                guard let self else { return }
                // Il seguito si esegue a pannello chiuso (`completeFixArtwork`), così le finestre successive non si annidano.
                self.fixArtworkCompletion = { [weak self] in
                guard let self else { return }
                self.status = confirmedCount > 0
                    ? t("status_fix_artwork_done", confirmedCount)
                    : t("status_fix_artwork_none_confirmed")
                // Copertine trovate e confermate: la selezione non serve più (come «Pulisci selezione»), ma solo se la ricerca era
                // stata aperta da sola. Se riprende un'azione (invio, Custom Playlist) la selezione serve ancora: svuotarla qui
                // faceva ripartire l'azione senza brani, e l'invio si fermava senza copiare nulla.
                if confirmedCount > 0, followUp == nil { self.clearSelection() }
                // Azione che aveva fatto proporre la ricerca (es. «Invia alla Playlist»): riprende da sola alla chiusura
                // del pannello (anche se la copertina era già confermata in passato e quindi non risulta «nuova»).
                followUp?()
                }
            })
    }

    /// Chiamata da ContentView quando il pannello Fix Artwork si è chiuso: libera la sessione ed esegue il seguito.
    func completeFixArtwork() {
        let completion = fixArtworkCompletion
        fixArtworkCompletion = nil
        fixArtworkSession = nil
        completion?()
    }

    /// Carica un file nella cartella indicata, evitando di ricopiare brani già presenti (il
    /// "delta"): se nella cartella esiste già un file con lo stesso nome, non lo tocca → `.skipped`.
    /// Altrimenti lo carica e controlla che risulti presente sul dispositivo subito dopo, con un
    /// secondo tentativo in caso di esito negativo, prima di arrendersi → `.transferred`/`.failed`.
    /// Non confronta le dimensioni (vedi `MTPService.fileExists`): un confronto stretto produce
    /// falsi negativi su alcuni dispositivi anche per file perfettamente corretti.
    ///
    /// `forceOverwrite`: unica eccezione alla logica "delta" sopra, per i brani con la copertina
    /// online confermata (file preparato in TEMP, stesso nome dell'originale) non ancora arrivati
    /// sul dispositivo con quella copertina: se il brano c'è già, si elimina la versione vecchia
    /// (una sola volta) e si carica quella nuova con un solo tentativo, senza riletture né
    /// verifiche successive, per non impegnare il dispositivo. L'esito dell'ultimo errore resta in
    /// `lastUploadError`, per mostrarlo sotto il brano nella finestra di trasferimento.
    private func uploadIfNeededAndVerify(from url: URL,
                                          storageID: UInt32, parentID: UInt32,
                                          forceOverwrite: Bool = false,
                                          existingCache: inout [UInt32: Set<String>]) async throws -> UploadOutcome {
        lastUploadError = nil
        let filename = url.lastPathComponent
        let key = filename.lowercased()

        if existingCache[parentID] == nil {
            let items = (try? await mtp.list(storageID: storageID, parentID: parentID)) ?? []
            existingCache[parentID] = Set(items.filter { !$0.isFolder }.map { $0.name.lowercased() })
        }

        if existingCache[parentID]?.contains(key) == true {
            guard forceOverwrite else { return .skipped }
            // Sostituzione di un brano già sul dispositivo con la versione con la copertina nuova:
            // si elimina la vecchia (per ID) una volta sola, senza riletture ripetute, e si carica
            // quella preparata in TEMP.
            let items = (try? await mtp.list(storageID: storageID, parentID: parentID)) ?? []
            if let existing = items.first(where: { !$0.isFolder && $0.name.caseInsensitiveCompare(filename) == .orderedSame }) {
                do {
                    try await mtp.delete(itemID: existing.id)
                } catch {
                    // Eliminazione non riuscita: la versione precedente resta com'è sul dispositivo.
                    lastUploadError = error.localizedDescription
                    return .failed
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            existingCache[parentID]?.remove(key)
        }

        if forceOverwrite {
            // File con copertina nuova: un solo tentativo, nessuna verifica o ripetizione che
            // impegni ancora il dispositivo (l'esito si vede nell'elenco aggiornato a fine invio).
            do {
                try await mtp.upload(from: url, storageID: storageID, parentID: parentID)
                existingCache[parentID]?.insert(key)
                return .transferred
            } catch {
                lastUploadError = error.localizedDescription
                return .failed
            }
        }

        if await uploadAndVerify(url, storageID: storageID, parentID: parentID) {
            existingCache[parentID]?.insert(key)
            return .transferred
        }
        return .failed
    }

    /// Ultimo errore incontrato da `uploadIfNeededAndVerify` (nil se non ce n'è stato nessuno).
    private var lastUploadError: String?

    /// Carica un file e verifica che risulti presente sul dispositivo: fino a 3 tentativi, con una
    /// pausa di un secondo tra l'uno e l'altro (un dispositivo appena occupato da un'altra
    /// operazione, per esempio un'eliminazione, spesso accetta il secondo tentativo).
    private func uploadAndVerify(_ url: URL, storageID: UInt32, parentID: UInt32) async -> Bool {
        let filename = url.lastPathComponent
        for attempt in 1...3 {
            do {
                try await mtp.upload(from: url, storageID: storageID, parentID: parentID)
                if await mtp.fileExists(named: filename, storageID: storageID, parentID: parentID) { return true }
                lastUploadError = t("error_upload_not_verified")
            } catch {
                lastUploadError = error.localizedDescription
            }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        return false
    }

    // MARK: - Dispositivo

    func connect() async {
        await connect(silentIfNoDevice: false)
    }

    /// Chiamata all'avvio dell'app (vedi `ContentView`): se un dispositivo Garmin risulta già
    /// collegato via USB, lo connette da sola, senza bisogno di staccare e riattaccare il cavo o
    /// premere "Connetti" a mano. Non fa nulla se un dispositivo è già connesso (es. l'app era già
    /// partita con uno collegato e questa venisse richiamata una seconda volta).
    func connectIfDeviceAlreadyPresent() async {
        guard device == nil else { return }
        await connect(silentIfNoDevice: true)
    }

    /// Logica comune a `connect()` (pulsante "Connetti", esplicito) e
    /// `connectIfDeviceAlreadyPresent()` (automatico all'avvio): l'unica differenza è cosa succede
    /// se non si trova nessun dispositivo. Un click su "Connetti" a vuoto è un errore da segnalare
    /// (`MTPError.noDevice`, mostrato con l'avviso "⚠️" come qualunque altro errore); lo stesso
    /// esito all'avvio è invece il caso normale quando l'orologio non è collegato, e non deve
    /// mostrare nessun avviso: lo stato resta semplicemente quello iniziale "Nessun dispositivo".
    private func connect(silentIfNoDevice: Bool) async {
        await Task.yield()
        busyScope = .device
        isBusy = true
        status = t("status_connecting")
        do {
            let info = try await mtp.connect()
            device = info
            selectedStorageID = info.storages.first?.id ?? 0
            status = t("status_reading_device_music")
            try await reloadDevice()
            await loadStorageBreakdown()
            status = t("status_device_connected")
            Task { await loadDeviceImage() }
        } catch MTPError.noDevice where silentIfNoDevice {
            status = t("status_no_device")
        } catch {
            status = "⚠️ " + error.localizedDescription
        }
        isBusy = false
    }

    /// Volume aperto come dispositivo (Impostazioni ▸ Avanzate ▸ musica su dischi e schede SD, 2.1 Beta 3, sperimentale).
    /// Nil = dispositivo MTP normale oppure nessun dispositivo.
    @Published var connectedVolumeURL: URL?

    /// Apre un volume Garmin (disco esterno, scheda SD, immagine disco) come se fosse un dispositivo: da qui in poi catalogo,
    /// invio, playlist ed eliminazione usano le cartelle del volume (vedi `MTPService.connectVolume`).
    func connectVolume(_ volume: VolumeDevice) async {
        await Task.yield()
        busyScope = .device
        isBusy = true
        status = t("status_connecting")
        do {
            let info = try await mtp.connectVolume(root: volume.url, name: volume.name,
                                                   model: volume.info.description ?? "")
            connectedVolumeURL = volume.url
            userDisconnected = false
            device = info
            selectedStorageID = info.storages.first?.id ?? 0
            status = t("status_reading_device_music")
            try await reloadDevice()
            await loadStorageBreakdown()
            status = t("status_device_connected")
            AppLog.debug("Volume come dispositivo: connesso — \(deviceTracks.count) brani, \(devicePlaylists.count) playlist, memorie: \(info.storages.map { "\($0.name) libero \($0.free) di \($0.capacity)" })")
            Task { await loadDeviceImage() }
        } catch {
            AppLog.debug("Volume come dispositivo: connessione fallita — \(error.localizedDescription)")
            connectedVolumeURL = nil
            device = nil
            deviceTracks = []
            devicePlaylists = []
            await mtp.disconnect()
            status = "⚠️ " + error.localizedDescription
        }
        isBusy = false
    }

    /// Legge il modello da `GarminDevice.xml` (o, in mancanza, dal nome MTP) e recupera l'immagine del
    /// prodotto; in background, senza bloccare l'interfaccia. In caso di errore resta l'icona predefinita.
    private func loadDeviceImage() async {
        deviceImage = nil
        deviceXMLInfo = nil
        resetDeviceMedia()
        softwareUpdateStatus = nil
        deviceSerial = nil
        deviceIsRegistered = false
        deviceXMLData = nil
        deviceMapsAvailable = false
        deviceRoutesOnly = false
        deviceMaps = nil
        deviceMapsError = nil
        deviceMapsCheckedAt = nil
        guard let info = device else { return }
        let mtp = self.mtp
        let storageIDs = info.storages.map(\.id)
        let xml = await withTimeout(20) { await mtp.readGarminDeviceXML(storageIDs: storageIDs) } ?? nil
        var model = xml.map { DeviceImageService.modelInfo(fromXML: $0) } ?? DeviceImageService.ModelInfo()
        if model.description == nil {
            model.description = info.model.isEmpty ? info.friendlyName : info.model
        }
        if device != nil {
            deviceXMLInfo = model
            // Formati e capacità musicali: si usa quanto dichiara il dispositivo (nil = file mancante: nessun blocco).
            let media = xml.flatMap { DeviceImageService.mediaCapabilities(fromXML: $0) }
            deviceMedia = media
            LocalTrack.deviceExtensions = media.flatMap { $0.isMusicCapable ? $0.trackExtensions : nil }
            await mtp.setWriteLocked(media?.isMusicCapable == false)
            objectWillChange.send()   // i brani «inviabili» dipendono dai formati appena letti
            // Global ID noto: carica (o crea) le impostazioni specifiche di questo dispositivo.
            if let id = model.id, !id.isEmpty {
                // Un dispositivo senza musica non si registra (nessuna impostazione dedicata, nessun nickname).
                deviceIsRegistered = media?.isMusicCapable != false
                deviceXMLData = xml
                if media?.isMusicCapable != false {
                    // Dispositivo memorizzato (dati aggiornati a ogni collegamento) o nuovo (si propone il nickname).
                    let isNew = AppSettings.shared.recordConnectedDevice(
                        id: id, model: model.description ?? "",
                        softwareVersion: Self.formattedSoftwareVersion(model.softwareVersion) ?? "",
                        memoryBytes: info.storages.first?.capacity ?? 0, unitID: model.partNumber ?? "")
                    if isNew { nicknamePromptDeviceID = id }
                    // Copia locale di GarminDevice.xml (solo dispositivi registrati), per i controlli a dispositivo scollegato.
                    if let xml { DeviceXMLStore.save(xml, forDevice: id) }
                }
                // Numero di serie: subito quello già memorizzato; quello nuovo arriva dalla chiamata a Garmin più sotto.
                deviceSerial = AppSettings.shared.serialNumber(forDevice: id)
                if let xml { startSoftwareUpdateCheck(deviceID: id, xml: xml, installed: Self.formattedSoftwareVersion(model.softwareVersion), persist: deviceIsRegistered) }
            }
        }
        // Informazioni dell'unità da Garmin (solo l'ID dell'unità): numero di serie e immagine ufficiale del prodotto.
        var unitInfo: GarminUnitInfo?
        if let id = model.id, !id.isEmpty {
            unitInfo = await GarminUnitInfoService.fetch(unitID: id)
            if device != nil, deviceXMLInfo?.id == id, let serial = unitInfo?.serialNumber {
                deviceSerial = serial
                AppSettings.shared.setSerialNumber(serial, forDevice: id)
            }
        }
        // Mappe: Garmin si interroga solo alla prima connessione (nessun Maps.json) o a richiesta dell'utente; poi si
        // legge sempre il file. Il controllo richiede l'opzione «controlla aggiornamenti» (invia l'XML a Garmin).
        if let id = model.id {
            if AppSettings.shared.checkDeviceUpdates, let xml,
               deviceIsRegistered ? AppSettings.shared.mapsMissing(forDevice: id) : (deviceMemoryMaps[id] == nil) {
                await fetchMaps(deviceID: id, xml: xml)
            }
            if device != nil, deviceXMLInfo?.id == id { loadStoredMaps(deviceID: id) }
            // Mappe cambiate sul dispositivo (confronto locale XML ↔ Maps.json): si propone il controllo, senza chiamare Garmin.
            var proposedChange = false
            if AppSettings.shared.checkDeviceUpdates, deviceIsRegistered, device != nil, deviceXMLInfo?.id == id, let xml,
               let stored = DeviceXMLStore.loadMaps(forDevice: id),
               GarminMapsService.mapsChanged(since: stored, xml: xml),
               mapsChangedProposed.insert(id).inserted {
                mapsChangedProposal = true
                proposedChange = true
            }
            // Controllo vecchio di oltre 3 mesi: si propone (una volta per avvio e per dispositivo) di verificare le novità.
            if AppSettings.shared.checkDeviceUpdates, deviceIsRegistered, device != nil, deviceXMLInfo?.id == id,
               let days = AppSettings.shared.daysSinceMapsCheck(forDevice: id), days > AppSettings.mapsRecheckDays,
               !proposedChange, mapsRecheckProposed.insert(id).inserted {
                mapsRecheckProposalDays = days
            }
        }
        if device != nil {
            deviceMapsAvailable = deviceMaps.map { !$0.isEmpty } ?? false
            deviceRoutesOnly = (deviceMaps?.isEmpty == true) && (xml.map { DeviceImageService.supportsCourses(fromXML: $0) } ?? false)
        }
        deviceGraphicURL = unitInfo?.graphicURL
        let image = await DeviceImageService.image(forModel: model, graphicURL: unitInfo?.graphicURL,
                                                   overrideURL: imageOverrideURL(deviceID: model.id, registered: deviceIsRegistered))
        if device != nil { deviceImage = image }
    }

    /// Legge Maps.json del dispositivo collegato: unica sorgente dei dati mostrati nel pannello Mappe.
    func loadStoredMaps(deviceID: String) {
        if deviceIsRegistered, let stored = AppSettings.shared.storedMaps(forDevice: deviceID) {
            AppSettings.shared.setHasMaps(!stored.catalog.isEmpty, forDevice: deviceID)   // allinea i dati salvati prima della correzione
            deviceMaps = stored.catalog
            deviceMapsCheckedAt = stored.checkedAt
            deviceMapsError = nil
        } else if !deviceIsRegistered, let memory = deviceMemoryMaps[deviceID] {
            deviceMaps = memory.catalog
            deviceMapsCheckedAt = memory.checkedAt
            deviceMapsError = nil
        } else {
            deviceMaps = nil
            deviceMapsCheckedAt = nil
        }
    }

    /// Interroga Garmin per le mappe del dispositivo e riscrive Maps.json (data compresa); poi rilegge il file.
    private func fetchMaps(deviceID: String, xml: Data) async {
        let result = await GarminMapsService.fetch(deviceXML: xml)
        guard device != nil, deviceXMLInfo?.id == deviceID else { return }
        if let catalog = result.catalog {
            if deviceIsRegistered {
                AppSettings.shared.setMaps(catalog, forDevice: deviceID)
            } else {
                deviceMemoryMaps[deviceID] = (catalog, Date())   // dispositivo senza musica: nessun file su disco
            }
            loadStoredMaps(deviceID: deviceID)
            deviceMapsAvailable = !catalog.isEmpty
        } else if deviceMaps == nil {
            // Un controllo fallito non cancella i dati già mostrati.
            deviceMapsError = result.error
        }
    }

    /// Chiamata dal globo del pannello: rilegge Maps.json; se il file manca (e l'opzione è accesa) lo crea interrogando Garmin.
    func ensureDeviceMaps() async {
        guard let id = deviceXMLInfo?.id else { return }
        loadStoredMaps(deviceID: id)
        guard deviceMaps == nil, AppSettings.shared.checkDeviceUpdates,
              let xml = deviceXMLData ?? DeviceXMLStore.load(forDevice: id)?.xml else { return }
        await fetchMaps(deviceID: id, xml: xml)
    }

    /// «Controlla ora» dalla proposta di ricontrollo.
    func acceptMapsRecheck() {
        mapsRecheckProposalDays = nil
        mapsChangedProposal = false
        Task { await refreshDeviceMaps() }
    }

    /// Controllo forzato (pulsante nel pannello Mappe): ricontatta Garmin e aggiorna Maps.json e la data.
    func refreshDeviceMaps() async {
        guard AppSettings.shared.checkDeviceUpdates, let id = deviceXMLInfo?.id,
              let xml = deviceXMLData ?? DeviceXMLStore.load(forDevice: id)?.xml else { return }
        await fetchMaps(deviceID: id, xml: xml)
    }

    /// Ogni 5 secondi (2.0.1; prima 20) controlla (con una lettura leggera del bus USB, senza toccare l'orologio)
    /// se un Garmin è collegato e, se non lo si è già connesso, lo connette in automatico. Gira in
    /// background e non usa `isBusy`: la parte Apple Music dell'app resta sempre utilizzabile.
    private func startAutoConnectLoop() {
        autoConnectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                await self.autoConnectTick()
            }
        }
    }

    private func autoConnectTick() async {
        guard device == nil, !isAutoConnecting else { return }
        guard USBRemovalWatcher.isGarminPresent() else {
            // Orologio fisicamente staccato: la prossima volta che si collega, connessione automatica.
            userDisconnected = false
            return
        }
        guard !userDisconnected, !isBusy else { return }

        isAutoConnecting = true
        defer { isAutoConnecting = false }
        do {
            let info = try await mtp.connect()
            // Nel frattempo l'utente potrebbe aver connesso a mano o avviato altro: non si interferisce.
            guard device == nil else { return }
            device = info
            selectedStorageID = info.storages.first?.id ?? 0
            try await reloadDevice()
            await loadStorageBreakdown()
            if !isBusy {
                status = t("status_device_connected")
            }
            Task { await loadDeviceImage() }
        } catch {
            // Tentativo silenzioso: se fallisce si riprova al prossimo giro (tra 5 secondi).
            if device != nil {
                let mtp = self.mtp
                Task.detached { await mtp.disconnect() }
                device = nil
                deviceTracks = []
                devicePlaylists = []
            }
        }
    }

    // MARK: - Dispositivi Garmin come volume (2.1 Beta 2, fase 1: solo riconoscimento)

    /// Dispositivi Garmin montati come disco esterno (archiviazione di massa), non MTP.
    @Published var volumeDevices: [VolumeDevice] = []
    private var volumeObservers: [NSObjectProtocol] = []
    private var volumeScanTask: Task<Void, Never>?
    private var volumeCheckObserver: AnyCancellable?

    /// Rilegge i volumi quando se ne monta, smonta o rinomina uno, e una volta all'avvio.
    func startVolumeWatcher() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                                          NSWorkspace.didRenameVolumeNotification]
        volumeObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshVolumeDevices()
                    Task { await self?.checkDriveLibraryStillAvailable() }
                }
            }
        }
        refreshVolumeDevices(after: 0.3)
        // Opzione «controlla aggiornamenti» accesa o spenta mentre un volume Garmin è collegato: si aggiorna subito.
        volumeCheckObserver = AppSettings.shared.$checkDeviceUpdates.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.loadVolumeDeviceDetails() }
        }
    }

    /// Scansione dei volumi in background (un disco lento non deve fermare l'interfaccia). Il ritardo lascia
    /// al volume appena montato il tempo di diventare leggibile; richieste ravvicinate si annullano a vicenda.
    func refreshVolumeDevices(after delay: Double = 1.0) {
        volumeScanTask?.cancel()
        volumeScanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .utility) { VolumeDeviceScanner.scan() }.value
            guard !Task.isCancelled, let self else { return }
            // Volume aperto come dispositivo e poi smontato (espulso da Finder, scheda tolta): come uno scollegamento.
            if let url = self.connectedVolumeURL, !found.contains(where: { $0.url == url }) {
                self.handleDeviceRemoved()
            }
            if found != self.volumeDevices {
                self.volumeDevices = found
                self.loadVolumeDeviceImage()
                self.loadVolumeDeviceDetails()
            }
        }
    }

    /// Immagine del prodotto del volume Garmin mostrato (stessa ricerca del dispositivo MTP: part number, poi nome del modello).
    @Published var volumeDeviceImage: NSImage?
    private var volumeImageKey: String?

    private func loadVolumeDeviceImage() {
        guard let volume = volumeDevices.first else {
            volumeDeviceImage = nil
            volumeImageKey = nil
            return
        }
        let key = volume.info.partNumber ?? volume.info.description ?? volume.id
        guard key != volumeImageKey else { return }
        volumeImageKey = key
        volumeDeviceImage = nil
        let info = volume.info
        let music = volume.isMusicCapable
        Task { [weak self] in
            let chosen = self?.imageOverrideURL(deviceID: info.id, registered: music)
            // Come per il dispositivo MTP: con l'ID dell'unità si chiede a Garmin l'immagine ufficiale del prodotto; senza, si
            // usava solo la ricerca per modello e l'immagine cambiava (quella sbagliata) dopo «Connect».
            var graphicURL: URL?
            if let id = info.id, !id.isEmpty { graphicURL = await GarminUnitInfoService.fetch(unitID: id)?.graphicURL }
            let image = await DeviceImageService.image(forModel: info, graphicURL: graphicURL, overrideURL: chosen)
            guard let self, self.volumeImageKey == key else { return }
            self.volumeDeviceImage = image
        }
    }

    // MARK: Fase 1b: aggiornamenti software e mappe dei dispositivi a volume (stesso interruttore opzionale delle Impostazioni)

    @Published var volumeSoftwareStatus: SoftwareUpdateStatus?
    @Published var volumeMapsAvailable = false
    @Published var volumeRoutesOnly = false
    /// Numero di serie del dispositivo a volume (da Garmin con il solo ID dell'unità, come per i dispositivi MTP).
    @Published var volumeSerial: String?
    @Published var volumeMaps: GarminMapsCatalog?
    @Published var volumeMapsCheckedAt: Date?
    @Published var volumeMapsError: String?

    /// Vero se il pannello mostra un dispositivo a volume (nessun dispositivo MTP collegato).
    var showingVolumeDevice: Bool { device == nil && !volumeDevices.isEmpty }

    private func resetVolumeDetails() {
        volumeSoftwareStatus = nil
        volumeMapsAvailable = false
        volumeRoutesOnly = false
        volumeSerial = nil
        volumeMaps = nil
        volumeMapsCheckedAt = nil
        volumeMapsError = nil
    }

    /// Mappe dei dispositivi a volume NON memorizzati (senza musica): restano in memoria fino alla chiusura dell'app.
    private var volumeMemoryMaps: [String: (catalog: GarminMapsCatalog, checkedAt: Date)] = [:]

    /// Per il volume Garmin mostrato, se l'opzione «software e mappe» è accesa, controlla aggiornamento software e mappe in
    /// background. Solo un dispositivo con musica viene memorizzato (con la copia di GarminDevice.xml, così il controllo
    /// all'apertura funziona anche a disco scollegato); uno senza musica si mostra solo mentre è collegato: niente
    /// registrazione, niente file su disco, nessun avviso all'apertura. Senza l'opzione non si contatta Garmin per software e mappe.
    func loadVolumeDeviceDetails() {
        resetVolumeDetails()
        guard let volume = volumeDevices.first, let id = volume.info.id, !id.isEmpty else { return }
        let persist = volume.isMusicCapable
        loadVolumeStoredMaps(deviceID: id)
        // Numero di serie: subito quello memorizzato; poi (come per i dispositivi MTP) lo si chiede a Garmin con il solo ID dell'unità.
        volumeSerial = persist ? AppSettings.shared.serialNumber(forDevice: id) : nil
        Task { [weak self] in
            let serial = await GarminUnitInfoService.fetch(unitID: id)?.serialNumber
            guard let self, let serial, self.volumeDevices.first?.info.id == id else { return }
            self.volumeSerial = serial
            if persist { AppSettings.shared.setSerialNumber(serial, forDevice: id) }   // salva solo se il dispositivo è memorizzato
        }
        guard AppSettings.shared.checkDeviceUpdates else { return }
        let installed = Self.formattedSoftwareVersion(volume.info.softwareVersion)
        if persist {
            // Registrazione senza proposta di nickname; il file XML serve al controllo all'apertura dell'app.
            AppSettings.shared.recordConnectedDevice(id: id, model: volume.info.description ?? "", softwareVersion: installed ?? "",
                                                     memoryBytes: UInt64(max(volume.totalBytes, 0)), unitID: volume.info.partNumber ?? "")
            DeviceXMLStore.save(volume.xml, forDevice: id)
        }
        let xml = volume.xml
        if let known = softwareUpdateResults[id], softwareUpdateResultVersion[id] == (installed ?? "") {
            volumeSoftwareStatus = known
        } else {
            Task { [weak self] in
                let result = await GarminUpdateService.check(deviceXML: xml, installedVersion: installed)
                guard let self, let result else { return }
                self.softwareUpdateResults[id] = result
                self.softwareUpdateResultVersion[id] = installed ?? ""
                if self.volumeDevices.first?.info.id == id { self.volumeSoftwareStatus = result }
                if persist {
                    AppSettings.shared.setSoftwareUpToDate(result == .upToDate, forDevice: id)
                    self.addUpdateNotice(deviceID: id, status: result, installed: installed, readDate: Date())
                }
            }
        }
        if persist ? AppSettings.shared.mapsMissing(forDevice: id) : (volumeMemoryMaps[id] == nil) {
            Task { [weak self] in await self?.fetchVolumeMaps(deviceID: id, xml: xml) }
        }
    }

    private func applyVolumeMaps(_ catalog: GarminMapsCatalog, checkedAt: Date) {
        volumeMaps = catalog
        volumeMapsCheckedAt = checkedAt
        volumeMapsError = nil
        volumeMapsAvailable = !catalog.isEmpty
        volumeRoutesOnly = catalog.isEmpty && (volumeDevices.first.map { DeviceImageService.supportsCourses(fromXML: $0.xml) } ?? false)
    }

    private func loadVolumeStoredMaps(deviceID: String) {
        let persist = volumeDevices.first?.isMusicCapable ?? false
        if persist, let stored = AppSettings.shared.storedMaps(forDevice: deviceID) {
            applyVolumeMaps(stored.catalog, checkedAt: stored.checkedAt)
        } else if !persist, let memory = volumeMemoryMaps[deviceID] {
            applyVolumeMaps(memory.catalog, checkedAt: memory.checkedAt)
        } else {
            volumeMaps = nil
            volumeMapsCheckedAt = nil
            volumeMapsAvailable = false
            volumeRoutesOnly = false
        }
    }

    private func fetchVolumeMaps(deviceID: String, xml: Data) async {
        let result = await GarminMapsService.fetch(deviceXML: xml)
        guard volumeDevices.first?.info.id == deviceID else { return }
        if let catalog = result.catalog {
            if volumeDevices.first?.isMusicCapable == true {
                AppSettings.shared.setMaps(catalog, forDevice: deviceID)
            } else {
                volumeMemoryMaps[deviceID] = (catalog, Date())   // dispositivo non memorizzato: nessun file su disco
            }
            loadVolumeStoredMaps(deviceID: deviceID)
        } else if volumeMaps == nil {
            volumeMapsError = result.error
        }
    }

    /// Dalla mappa: rilegge i dati (Maps.json, o la memoria per un dispositivo non memorizzato); se mancano (e l'opzione è accesa) interroga Garmin.
    func ensureVolumeMaps() async {
        guard let volume = volumeDevices.first, let id = volume.info.id else { return }
        loadVolumeStoredMaps(deviceID: id)
        guard volumeMaps == nil, AppSettings.shared.checkDeviceUpdates else { return }
        await fetchVolumeMaps(deviceID: id, xml: volume.xml)
    }

    /// «Controlla ora» nel pannello Mappe.
    func refreshVolumeMaps() async {
        guard AppSettings.shared.checkDeviceUpdates, let volume = volumeDevices.first, let id = volume.info.id else { return }
        await fetchVolumeMaps(deviceID: id, xml: volume.xml)
    }

    // MARK: Scelta manuale dell'immagine del prodotto

    /// Immagine scelta dall'utente per dispositivi non memorizzati (senza musica): vale solo fino alla chiusura dell'app.
    private var imageOverrideMemory: [String: String] = [:]
    private var deviceGraphicURL: URL?

    private func imageOverrideURL(deviceID: String?, registered: Bool) -> URL? {
        guard let deviceID, !deviceID.isEmpty else { return nil }
        let text = registered ? AppSettings.shared.imageOverride(forDevice: deviceID) : imageOverrideMemory[deviceID]
        return text.flatMap { URL(string: $0) }
    }

    /// Global ID del dispositivo di cui il pannello mostra l'immagine (MTP collegato, altrimenti volume).
    var imageDeviceID: String? { device != nil ? deviceXMLInfo?.id : volumeDevices.first?.info.id }

    /// Vero se il dispositivo mostrato ha un'immagine scelta a mano.
    var hasImageOverride: Bool {
        guard let id = imageDeviceID else { return false }
        return imageOverrideURL(deviceID: id, registered: device != nil ? deviceIsRegistered : (volumeDevices.first?.isMusicCapable ?? false)) != nil
    }

    /// Imposta (o, con nil, toglie) l'immagine scelta a mano per il dispositivo mostrato e la ricarica.
    func chooseDeviceImage(_ url: URL?) {
        guard let id = imageDeviceID, !id.isEmpty else { return }
        if device != nil {
            if deviceIsRegistered { AppSettings.shared.setImageOverride(url?.absoluteString, forDevice: id) }
            else { imageOverrideMemory[id] = url?.absoluteString }
            guard let model = deviceXMLInfo else { return }
            let graphic = deviceGraphicURL
            Task { [weak self] in
                let image = await DeviceImageService.image(forModel: model, graphicURL: graphic, overrideURL: url)
                guard let self, self.device != nil, self.deviceXMLInfo?.id == id else { return }
                self.deviceImage = image
            }
        } else if let volume = volumeDevices.first {
            if volume.isMusicCapable { AppSettings.shared.setImageOverride(url?.absoluteString, forDevice: id) }
            else { imageOverrideMemory[id] = url?.absoluteString }
            volumeImageKey = nil
            loadVolumeDeviceImage()
        }
    }

    /// Smonta ed espelle il volume in modo sicuro (scarica le scritture in sospeso prima di rimuovere il cavo).
    func ejectVolume(_ volume: VolumeDevice) {
        let name = volume.info.description ?? volume.name
        let url = volume.url
        status = t("status_volume_ejecting", name)
        AppLog.debug("Espelli volume: richiesta per \(url.path)")
        Task { [weak self] in
            let error: Error? = await withCheckedContinuation { continuation in
                FileManager.default.unmountVolume(at: url, options: [.allPartitionsAndEjectDisk]) { continuation.resume(returning: $0) }
            }
            if let error {
                let ns = error as NSError
                AppLog.debug("Espelli volume: errore \(ns.domain) \(ns.code) — \(ns.localizedDescription); causa: \(String(describing: ns.userInfo[NSUnderlyingErrorKey])); ancora montato: \(FileManager.default.fileExists(atPath: url.path))")
            } else {
                AppLog.debug("Espelli volume: riuscito per \(url.path); ancora montato: \(FileManager.default.fileExists(atPath: url.path))")
            }
            if let error {
                self?.status = "⚠️ " + t("status_volume_eject_failed", name, error.localizedDescription)
            } else {
                self?.status = t("status_volume_ejected", name)
            }
            self?.refreshVolumeDevices(after: 0.3)
        }
    }

    /// Il dispositivo è stato staccato dalla porta USB: si azzera subito lo stato dell'app (senza
    /// aspettare l'actor MTP, che potrebbe essere fermo su una chiamata che non tornerà) e si chiede
    /// in background di rilasciare la sessione. Non annulla un'eventuale operazione in corso: quella
    /// terminerà da sola con un errore ora che il dispositivo non c'è più.
    func handleDeviceRemoved() {
        guard device != nil else { return }
        let mtp = self.mtp
        Task.detached { await mtp.disconnect() }
        connectedVolumeURL = nil
        device = nil
        deviceImage = nil
        deviceXMLInfo = nil
        resetDeviceMedia()
        softwareUpdateStatus = nil
        deviceSerial = nil
        deviceIsRegistered = false
        deviceXMLData = nil
        deviceMapsAvailable = false
        deviceRoutesOnly = false
        deviceMaps = nil
        deviceMapsError = nil
        deviceMapsCheckedAt = nil
        deviceTracks = []
        devicePlaylists = []
        selectedDeviceTrackIDs = []
        garminFolderSize = 0
        mapsSize = 0
        servicesSize = 0
        exportPlan = nil
        status = t("status_device_unplugged")
    }

    func disconnect() async {
        userDisconnected = true
        await mtp.disconnect()
        connectedVolumeURL = nil
        device = nil
        deviceImage = nil
        deviceXMLInfo = nil
        resetDeviceMedia()
        softwareUpdateStatus = nil
        deviceSerial = nil
        deviceIsRegistered = false
        deviceXMLData = nil
        deviceMapsAvailable = false
        deviceRoutesOnly = false
        deviceMaps = nil
        deviceMapsError = nil
        deviceMapsCheckedAt = nil
        deviceTracks = []
        devicePlaylists = []
        selectedDeviceTrackIDs = []
        garminFolderSize = 0
        mapsSize = 0
        servicesSize = 0
        status = t("status_disconnected")
    }

    func changeStorage(to id: UInt32) async {
        selectedStorageID = id
        await perform(t("status_reading")) {
            try await reloadDevice()
            await loadStorageBreakdown()
        }
    }

    /// Pulsante «Aggiorna» della barra del titolo: rilegge la libreria attiva (Music, unità esterna, XML o rete) e, se c'è
    /// un dispositivo con musica connesso, anche il dispositivo. In sequenza, perché entrambe le operazioni usano `isBusy`.
    func refreshAll() async {
        guard !isBusy else { return }
        refreshAllRunning = true
        defer { refreshAllRunning = false }
        await loadLibrary(reloadRemote: true)
        if device != nil, !isDeviceReadOnly { await refresh() }
    }

    func refresh() async {
        await perform(t("status_refreshing")) {
            try await reloadDevice()
            status = t("status_device_connected")
        }
    }

    /// Calcola la ripartizione dello spazio (cartella Garmin e mappe) per la memoria interna.
    /// Operazione potenzialmente lenta: la si esegue solo alla connessione o al cambio memoria,
    /// non a ogni refresh, e solo se la memoria selezionata è quella interna.
    private func loadStorageBreakdown() async {
        guard isSelectedStorageInternal else { garminFolderSize = 0; mapsSize = 0; servicesSize = 0; return }
        isLoadingStorageBreakdown = true
        let (g, m) = await mtp.garminAndMapsSize(storageID: selectedStorageID)
        // Servizi di streaming: dimensione dichiarata dall'orologio in GarminDevice.xml (sola lettura).
        let mtpService = self.mtp
        let storageIDs = device?.storages.map(\.id) ?? []
        let xml = await withTimeout(20) { await mtpService.readGarminDeviceXML(storageIDs: storageIDs) } ?? nil
        servicesSize = xml.map { DeviceImageService.streamingServicesBytes(fromXML: $0) } ?? 0
        garminFolderSize = g
        mapsSize = m
        isLoadingStorageBreakdown = false
    }

    /// Ricarica il catalogo musicale del dispositivo.
    private func reloadDevice() async throws {
        try await reloadDeviceCatalog()
    }

    private func reloadDeviceCatalog() async throws {
        let catalog = try await mtp.loadMusicCatalog(storageID: selectedStorageID)
        applyDeviceCatalog(catalog)
        // Volume aperto come dispositivo: lo spazio libero cambia a ogni invio o eliminazione, quindi si rilegge qui.
        if connectedVolumeURL != nil, let current = device, let fresh = await mtp.volumeStorages() {
            device = MTPDeviceInfo(friendlyName: current.friendlyName, manufacturer: current.manufacturer,
                                   model: current.model, nickname: current.nickname, storages: fresh)
        }
    }

    // MARK: - Nomi originali di artisti e album sul dispositivo (2.0.1)

    /// Sul dispositivo le cartelle hanno nomi «ripuliti» dai caratteri non ammessi (AC/DC → AC_DC) e il dispositivo
    /// non espone artista e album dei brani: li si ricava dal nome delle cartelle. Per mostrare il nome vero si
    /// ricorda, per ogni nome ripulito, l'originale: da ciò che si è inviato (memorizzato) e dalla libreria Music.
    private var libraryNameMapCache: [String: String]?
    private static let deviceNameMapKey = "device_original_names"

    private static func nameMapKey(_ kind: String, _ sanitized: String) -> String { kind + ":" + sanitized.lowercased() }

    private func rememberDeviceNames(artist: String, album: String) {
        var map = UserDefaults.standard.dictionary(forKey: Self.deviceNameMapKey) as? [String: String] ?? [:]
        var changed = false
        for (kind, original) in [("a", artist), ("l", album)] {
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let clean = Self.sanitizedFilename(trimmed)
            if clean != trimmed, map[Self.nameMapKey(kind, clean)] != trimmed {
                map[Self.nameMapKey(kind, clean)] = trimmed
                changed = true
            }
        }
        if changed { UserDefaults.standard.set(map, forKey: Self.deviceNameMapKey) }
    }

    private func originalNameMap() -> [String: String] {
        if libraryNameMapCache == nil {
            var map: [String: String] = [:]
            for track in localTracks {
                for (kind, original) in [("a", track.artist), ("l", track.album)] {
                    let trimmed = original.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    let clean = Self.sanitizedFilename(trimmed)
                    if clean != trimmed { map[Self.nameMapKey(kind, clean)] = trimmed }
                }
            }
            libraryNameMapCache = map
        }
        let stored = UserDefaults.standard.dictionary(forKey: Self.deviceNameMapKey) as? [String: String] ?? [:]
        return (libraryNameMapCache ?? [:]).merging(stored) { library, _ in library }
    }

    private func applyDeviceCatalog(_ rawCatalog: DeviceCatalog, keepSelection: Bool = false) {
        lastRawDeviceCatalog = rawCatalog
        let names = originalNameMap()
        // Durata e numero di traccia che il dispositivo non espone: si ricavano dallo stesso file nella libreria Music
        // (stesso nome file e artista, come per «già inviato»; con l'album se coincide). Così l'elenco del dispositivo
        // si presenta come quello di Music (numeri di traccia, durata in minuti).
        typealias Info = (title: String, duration: TimeInterval, trackNumber: Int, discNumber: Int, discCount: Int,
                          albumArtist: String, isCompilation: Bool)
        var libraryInfo: [String: Info] = [:]
        var byFile: [String: Info] = [:]        // solo nome file: vale se è unico in tutta la libreria
        var ambiguousFiles = Set<String>()
        for lt in localTracks {
            guard let file = lt.url?.lastPathComponent.lowercased() else { continue }
            let info: Info = (title: lt.title, duration: lt.duration, trackNumber: lt.trackNumber, discNumber: lt.discNumber, discCount: lt.discCount,
                               albumArtist: lt.albumArtist, isCompilation: lt.isCompilation)
            // L'artista sul dispositivo può essere il nome della cartella (caratteri non ammessi sostituiti: «AC/DC» → «AC_DC»).
            for artist in [lt.artist.lowercased(), Self.sanitizedFilename(lt.artist).lowercased()] {
                libraryInfo[file + "|" + artist + "|" + lt.album.lowercased()] = info
                if libraryInfo[file + "|" + artist] == nil { libraryInfo[file + "|" + artist] = info }
            }
            if byFile[file] != nil { ambiguousFiles.insert(file) } else { byFile[file] = info }
        }
        let fixed = rawCatalog.tracks.map { d -> DeviceTrack in
            let artist = names[Self.nameMapKey("a", d.artist)] ?? d.artist
            let album = names[Self.nameMapKey("l", d.album)] ?? d.album
            var title = d.title
            var duration = d.duration
            var number = d.trackNumber
            var disc = d.discNumber
            var discs = d.discCount
            var albumArtist = d.albumArtist
            var isCompilation = d.isCompilation
            let file = d.filename.lowercased()
            var lookup: Info?
            for a in [artist, d.artist] where lookup == nil {
                lookup = libraryInfo[file + "|" + a.lowercased() + "|" + album.lowercased()] ?? libraryInfo[file + "|" + a.lowercased()]
            }
            if lookup == nil, !ambiguousFiles.contains(file) { lookup = byFile[file] }
            if let info = lookup {
                if duration <= 0 { duration = info.duration }
                if number <= 0 { number = info.trackNumber }
                // Il dispositivo non conosce il disco: si prende dalla libreria (ordine e intestazioni «Disco n di m»).
                if disc <= 0 { disc = info.discNumber }
                if discs <= 0 { discs = info.discCount }
                // Artista dell'album e compilation dalla libreria: i brani di un album con artisti diversi restano un solo album.
                albumArtist = info.albumArtist
                isCompilation = info.isCompilation
                // Senza metadati il titolo era il nome del file («07 Titolo.m4a»): si usa quello della libreria.
                if title == (d.filename as NSString).deletingPathExtension, !info.title.isEmpty { title = info.title }
            }
            guard artist != d.artist || album != d.album || title != d.title || duration != d.duration || number != d.trackNumber || disc != d.discNumber || discs != d.discCount
                    || albumArtist != d.albumArtist || isCompilation != d.isCompilation else { return d }
            return DeviceTrack(id: d.id, title: title, artist: artist, album: album, filename: d.filename,
                               size: d.size, duration: duration, folderIDPath: d.folderIDPath,
                               folderNames: d.folderNames, trackNumber: number, discNumber: disc, discCount: discs,
                               albumArtist: albumArtist, isCompilation: isCompilation)
        }
        let catalog = DeviceCatalog(tracks: fixed, playlists: rawCatalog.playlists)
        deviceTracks = catalog.tracks
        let byID = Dictionary(catalog.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        devicePlaylists = catalog.playlists.map { pl in
            let items = pl.trackIDs.compactMap { byID[$0] }
            return TrackGroup(id: "devplaylist:\(pl.id)", title: pl.name,
                              subtitle: playlistSubtitle(items), tracks: items)
        }
        if !keepSelection {
            selectedDeviceTrackIDs = []
            deviceArtworkRevision += 1
        }
    }

    /// Come `reloadDevice()`, ma con un tempo massimo (90 s per il
    /// catalogo): a fine invio il dispositivo può restare occupato a elaborare i file appena
    /// ricevuti (soprattutto quelli con copertina) e non rispondere; senza limite l'app resta
    /// appesa con la finestra di trasferimento non chiudibile. Restituisce false se non risponde
    /// (l'elenco resta quello di prima: un "aggiorna" manuale, poco dopo, lo corregge).
    private func reloadDeviceBounded() async -> Bool {
        let mtp = self.mtp
        let storageID = selectedStorageID
        let loaded: DeviceCatalog?? = await withTimeout(90) { try? await mtp.loadMusicCatalog(storageID: storageID) }
        guard let loadedOuter = loaded, let catalog = loadedOuter else { return false }
        applyDeviceCatalog(catalog)
        return true
    }

    /// Copertina, se disponibile, per un brano letto dal dispositivo Garmin (best effort: molti
    /// dispositivi non espongono questa proprietà MTP, in quel caso restituisce sempre nil).
    ///
    /// Se il dispositivo non la espone (il caso più comune) ma l'app ha caricato proprio su quel
    /// dispositivo una versione con una copertina confermata in Fix Artwork (`pushedToDevice`),
    /// mostra quella: è la copertina che è stata effettivamente scritta nel file inviato.
    func deviceArtwork(for track: DeviceTrack) async -> Data? {
        if let data = await mtp.artwork(forItemID: track.id) { return data }
        guard AppSettings.shared.lookupMissingArtworkOnline else { return nil }
        let key = ArtworkCache.key(artist: track.artist, title: track.title, album: track.album)
        return ArtworkCache.isPushedToDevice(key: key) ? ArtworkCache.confirmedImage(forKey: key) : nil
    }

    // MARK: - Azioni sulla selezione del dispositivo

    /// Brani da eliminare e brani tenuti per l'eliminazione corrente. Prima di eliminare i brani di una
    /// playlist si controlla che non facciano parte anche di altre playlist del dispositivo (non scelte):
    /// quelli si tengono, per non romperle.
    var deviceDeletionPlan: (items: [DeviceTrack], kept: Int) {
        var items = deviceTracks.filter { selectedDeviceTrackIDs.contains($0.id) }
        var kept = 0
        if !selectedDevicePlaylistFileIDs.isEmpty {
            let chosen = Set(selectedDevicePlaylistIDs)
            var usedElsewhere = Set<UInt32>()
            for g in devicePlaylists where !chosen.contains(g.id) {
                for t in g.tracks { usedElsewhere.insert(t.id) }
            }
            let before = items.count
            items = items.filter { !usedElsewhere.contains($0.id) }
            kept = before - items.count
        }
        return (items, kept)
    }

    /// Playlist del dispositivo toccate dall'eliminazione dei soli brani selezionati: quante tracce sono
    /// incluse in playlist, i nomi delle playlist coinvolte e quelle che resterebbero vuote (verrebbero eliminate).
    /// Le playlist scelte per intero con la spunta sono escluse: vengono già eliminate a parte.
    var deviceDeletionPlaylistImpact: (trackCount: Int, affected: [TrackGroup<DeviceTrack>], emptied: [TrackGroup<DeviceTrack>]) {
        let deleted = Set(deviceDeletionPlan.items.map(\.id))
        guard !deleted.isEmpty else { return (0, [], []) }
        let chosen = Set(selectedDevicePlaylistIDs)
        var affected: [TrackGroup<DeviceTrack>] = []
        var emptied: [TrackGroup<DeviceTrack>] = []
        var hit = Set<UInt32>()
        for g in devicePlaylists where !chosen.contains(g.id) {
            let inside = g.tracks.filter { deleted.contains($0.id) }
            guard !inside.isEmpty else { continue }
            affected.append(g)
            for t in inside { hit.insert(t.id) }
            if inside.count == g.tracks.count { emptied.append(g) }
        }
        return (hit.count, affected, emptied)
    }

    /// Elimina la selezione. Con `updatePlaylists` i file playlist del dispositivo che contenevano i brani
    /// eliminati vengono riscritti senza di loro (e quelli che restano vuoti eliminati); altrimenti restano com'erano.
    func deleteSelection(updatePlaylists: Bool = true) async {
        guard ensureDeviceWritable() else { return }
        let plan = deviceDeletionPlan
        // Playlist da aggiornare, calcolate prima dell'eliminazione (dopo, l'elenco cambierebbe).
        let impact: (trackCount: Int, affected: [TrackGroup<DeviceTrack>], emptied: [TrackGroup<DeviceTrack>]) =
            updatePlaylists ? deviceDeletionPlaylistImpact : (0, [], [])
        let deletedIDs = Set(plan.items.map(\.id))
        let rawPlaylists = Dictionary((lastRawDeviceCatalog?.playlists ?? []).map { ($0.id, $0) },
                                      uniquingKeysWith: { a, _ in a })
        let items = plan.items
        // Playlist scelte per intero: si elimina anche il loro file playlist, alla fine.
        let playlistFileIDs = selectedDevicePlaylistFileIDs
        let keptCount = plan.kept
        guard !items.isEmpty || !playlistFileIDs.isEmpty else { return }
        let total = items.count + playlistFileIDs.count
        await perform(t("status_deleting")) {
            // Una breve pausa: la conferma (alert) deve chiudersi prima che si apra la finestra.
            try? await Task.sleep(nanoseconds: 300_000_000)
            deletionProgress = DeletionProgress(title: t("delete_progress_title"), total: total)
            defer { deletionProgress = nil }
            // Solo i brani che vengono davvero eliminati compaiono nell'avanzamento.
            for (i, item) in items.enumerated() {
                deletionProgress?.current = i
                deletionProgress?.detail = t("delete_progress_item", i + 1, total, item.title)
                try await mtp.delete(itemID: item.id)
            }
            for (j, fileID) in playlistFileIDs.enumerated() {
                deletionProgress?.current = items.count + j
                deletionProgress?.detail = t("delete_progress_playlist", j + 1, playlistFileIDs.count)
                try? await mtp.delete(itemID: fileID)
            }
            // 2.1 Beta 2: i file playlist che citavano i brani eliminati vengono riscritti senza di loro;
            // se non resta nessun brano, il file playlist viene eliminato.
            var updatedPlaylists = 0, removedPlaylists = 0, failedPlaylists = 0
            // Playlist riscritte ma non verificate dal controllo del file: l'esito si giudica dopo, rileggendo il dispositivo.
            var unverified: [(name: String, count: Int)] = []
            let mtp = self.mtp
            let storageID = selectedStorageID
            for (k, g) in impact.affected.enumerated() {
                deletionProgress?.detail = t("delete_progress_update_playlists", k + 1, impact.affected.count)
                guard let fileID = Self.rawDevicePlaylistFileID(from: g.id), let raw = rawPlaylists[fileID] else {
                    failedPlaylists += 1
                    continue
                }
                let remaining = g.tracks.filter { !deletedIDs.contains($0.id) }
                if remaining.isEmpty {
                    if (try? await mtp.delete(itemID: fileID)) != nil { removedPlaylists += 1 } else { failedPlaylists += 1 }
                    continue
                }
                let paths = remaining.map(\.relativePath)
                let name = raw.name
                let parentID = raw.parentID
                // Il file si ricrea da zero (come negli invii): prima si elimina il vecchio, poi si carica e si verifica il nuovo.
                guard (try? await mtp.delete(itemID: fileID)) != nil else { failedPlaylists += 1; continue }
                let ok: Bool? = await withTimeout(180) {
                    await mtp.uploadPlaylistVerified(name: name, filenames: paths, storageID: storageID, parentID: parentID)
                }
                if ok == true { updatedPlaylists += 1 } else { unverified.append((name, remaining.count)) }
            }
            deletionProgress?.current = total
            deletionProgress?.detail = t("delete_progress_cleanup")
            await cleanupEmptyFolders(parentChains: items.map(\.folderIDPath))
            deletionProgress?.detail = t("delete_progress_refresh")
            try await reloadDevice()
            for u in unverified {
                if let g = devicePlaylists.first(where: { $0.title.caseInsensitiveCompare(u.name) == .orderedSame }), g.tracks.count == u.count {
                    updatedPlaylists += 1
                } else {
                    failedPlaylists += 1
                    AppLog.write("Playlist «\(u.name)» not updated: expected \(u.count) tracks after reload")
                }
            }
            var message = keptCount > 0
                ? t("status_deleted_tracks_kept", items.count, keptCount)
                : t("status_deleted_tracks", items.count)
            if updatedPlaylists + removedPlaylists > 0 {
                message += " · " + t("status_deleted_playlists_updated", updatedPlaylists, removedPlaylists)
            }
            if failedPlaylists > 0 { message += " · ⚠️ " + t("status_deleted_playlists_failed", failedPlaylists) }
            status = message
            selectedDevicePlaylistIDs = []
        }
    }

    /// 2.1 Beta 3 (diagnostica, sola lettura): salva l'albero completo del dispositivo in un file di testo nella cartella
    /// dei registri (`~/Library/Logs/MusicManager/DeviceTree-<data>.txt`) e lo mostra nel Finder. Per capire dove salvano i
    /// dati i servizi di streaming: si salva prima e dopo un download e si confrontano i due file.
    func saveDeviceTree() async {
        guard let info = device else { status = "⚠️ " + t("status_no_device"); return }
        let mtp = self.mtp
        let storages = info.storages
        await perform(t("status_device_tree_saving")) {
            let text: String?? = await withTimeout(300) { try? await mtp.dumpTree(storages: storages) }
            guard let outer = text, let tree = outer else {
                status = "⚠️ " + t("status_device_tree_failed")
                return
            }
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
            let url = AppLog.fileURL.deletingLastPathComponent().appendingPathComponent("DeviceTree-\(df.string(from: Date())).txt")
            do {
                try tree.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                status = t("status_device_tree_saved", url.lastPathComponent)
            } catch {
                status = "⚠️ " + error.localizedDescription
            }
        }
    }

    /// 2.1 Beta 3 (diagnostica, sola lettura): salva una copia di `GarminDevice.xml` letta ora dal dispositivo, come
    /// `GarminDevice-<data>.xml` nella cartella dei registri, e la mostra nel Finder. Serve a confrontare i valori
    /// (es. `MediaCacheSize` dei servizi di streaming) prima e dopo un'operazione. Non modifica nulla sul dispositivo.
    func saveDeviceXML() async {
        guard let info = device else { status = "⚠️ " + t("status_no_device"); return }
        let mtp = self.mtp
        let storageIDs = info.storages.map(\.id)
        await perform(t("status_device_xml_saving")) {
            let result: Data?? = await withTimeout(30) { await mtp.readGarminDeviceXML(storageIDs: storageIDs) }
            guard let outer = result, let xml = outer else {
                status = "⚠️ " + t("status_device_xml_failed")
                return
            }
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
            let url = AppLog.fileURL.deletingLastPathComponent().appendingPathComponent("GarminDevice-\(df.string(from: Date())).xml")
            do {
                try xml.write(to: url, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                status = t("status_device_xml_saved", url.lastPathComponent)
            } catch {
                status = "⚠️ " + error.localizedDescription
            }
        }
    }

    /// 2.1 Beta 3 (diagnostica, sola lettura): contenuto di una cartella del dispositivo per il navigatore dei file.
    /// Nil se il dispositivo non risponde in tempo. Non modifica nulla.
    func listDeviceFolder(storageID: UInt32, parentID: UInt32) async -> [MTPEntry]? {
        let mtp = self.mtp
        let result: [MTPEntry]?? = await withTimeout(30) { try? await mtp.list(storageID: storageID, parentID: parentID) }
        guard let outer = result, let entries = outer else { return nil }
        return entries
    }

    /// 2.1 Beta 3 (navigatore dei file, sola lettura): le app dell'orologio da GarminDevice.xml, per riconoscere i loro file.
    func loadDeviceAppFileMap() async -> [String: DeviceAppInfo] {
        guard let info = device else { return [:] }
        let mtpService = self.mtp
        let storageIDs = info.storages.map(\.id)
        let xml = await withTimeout(20) { await mtpService.readGarminDeviceXML(storageIDs: storageIDs) } ?? nil
        return xml.map { DeviceImageService.appFileMap(fromXML: $0) } ?? [:]
    }

    /// Navigatore dei file: etichette dei file delle mappe (nome file maiuscolo senza estensione → nome della mappa installata).
    /// Usa i file citati nell'XML e le mappe installate memorizzate in Maps.json (con i loro file, se già registrati).
    func loadDeviceMapFileLabels() async -> [String: String] {
        guard let info = device else { return [:] }
        let mtpService = self.mtp
        let storageIDs = info.storages.map(\.id)
        let xml = await withTimeout(20) { await mtpService.readGarminDeviceXML(storageIDs: storageIDs) } ?? nil
        guard let xml else { return [:] }
        let parts = GarminMapsService.mapFileParts(fromXML: xml)
        let installed = AppSettings.shared.storedMaps(forDevice: deviceXMLInfo?.id)?.catalog.installed ?? []
        var byPart: [String: GarminMapEntry] = [:]
        for e in installed {
            if let p = e.id.split(separator: "|", omittingEmptySubsequences: false).last, !p.isEmpty { byPart[String(p)] = e }
        }
        // 1) Nomi dei file registrati da Garmin per ogni mappa installata (Maps.json aggiornato dopo un nuovo controllo);
        // 2) altrimenti il PartNumber dell'XML; 3) altrimenti «Map data» (file di mappa non attribuibile).
        var byFile: [String: GarminMapEntry] = [:]
        for e in installed { for f in e.files ?? [] { byFile[((f as NSString).deletingPathExtension).uppercased()] = e } }
        var out: [String: String] = [:]
        for (stem, part) in parts {
            // Nome dell'area geografica evitato di proposito: «CourseView Pacific» sta in «Australia & New Zealand».
            out[stem] = (byFile[stem] ?? byPart[part])?.name ?? "Map data"
        }
        for (stem, e) in byFile where out[stem] == nil { out[stem] = e.name }
        return out
    }

    /// 2.1 Beta 3 (navigatore dei file): copia un file dal dispositivo in una cartella del Mac. Legge soltanto: il dispositivo
    /// non viene modificato. Se esiste già un file con lo stesso nome ne aggiunge uno nuovo («nome 2.ext»). Nil se la copia
    /// non riesce o è troppo lunga (il file parziale si elimina).
    func copyDeviceFileToMac(_ entry: MTPEntry, to folder: URL) async -> URL? {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(entry.name)
        if fm.fileExists(atPath: dest.path) {
            let base = (entry.name as NSString).deletingPathExtension
            let ext = (entry.name as NSString).pathExtension
            var n = 2
            repeat {
                dest = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            } while fm.fileExists(atPath: dest.path)
        }
        let mtpService = self.mtp
        let target = dest
        let itemID = entry.id
        let ok = await withTimeout(600) { (try? await mtpService.download(itemID: itemID, to: target)) != nil }
        if ok == true { return target }
        try? fm.removeItem(at: target)
        return nil
    }

    /// Elimina tutto il contenuto della cartella Music sul dispositivo (brani, cartelle
    /// Artista/Album e file playlist), senza eliminare la cartella Music stessa. L'avanzamento è
    /// per elemento di primo livello (cartelle artista e file playlist).
    func emptyMusicFolder() async {
        guard ensureDeviceWritable() else { return }
        await perform(t("status_emptying_music", NoticeFormat.bold(deviceNameForAlerts))) {
            // Una breve pausa: la conferma (alert) deve chiudersi prima che si apra la finestra.
            try? await Task.sleep(nanoseconds: 300_000_000)
            deletionProgress = DeletionProgress(title: t("delete_progress_empty_title"),
                                                detail: t("delete_progress_counting"))
            defer { deletionProgress = nil }
            if let musicID = await mtp.findFolder(named: "Music", parentID: mtpRootParent, storageID: selectedStorageID),
               let entries = try? await mtp.list(storageID: selectedStorageID, parentID: musicID) {
                deletionProgress?.total = entries.count
                for (i, entry) in entries.enumerated() {
                    deletionProgress?.current = i
                    deletionProgress?.detail = t("delete_progress_item", i + 1, entries.count, entry.name)
                    try? await mtp.delete(itemID: entry.id)
                }
                deletionProgress?.current = entries.count
            }
            deletionProgress?.detail = t("delete_progress_refresh")
            try await reloadDevice()
            await loadStorageBreakdown()
            status = t("status_music_emptied", NoticeFormat.bold(deviceNameForAlerts))
        }
    }

    /// Dopo l'eliminazione di brani, rimuove la cartella Album rimasta vuota e, se a sua volta
    /// resta vuota, anche la cartella Artista. Non tocca mai la cartella Music, e non va oltre
    /// questi due livelli anche se ci fossero altre cartelle sopra.
    private func cleanupEmptyFolders(parentChains: [[UInt32]]) async {
        guard !parentChains.isEmpty else { return }
        let musicFolderID = await mtp.findFolder(named: "Music", parentID: mtpRootParent, storageID: selectedStorageID)

        // Per ogni brano eliminato: ultima cartella della catena = Album (o comunque il genitore
        // diretto), penultima = Artista, se presente.
        var albumToArtist: [UInt32: UInt32?] = [:]
        for chain in parentChains {
            guard let album = chain.last else { continue }
            let artist = chain.count >= 2 ? chain[chain.count - 2] : nil
            albumToArtist.updateValue(artist, forKey: album)
        }

        for (albumID, artistID) in albumToArtist {
            guard albumID != musicFolderID else { continue }
            guard let children = try? await mtp.list(storageID: selectedStorageID, parentID: albumID),
                  children.isEmpty else { continue }
            try? await mtp.delete(itemID: albumID)

            guard let artistID, artistID != musicFolderID else { continue }
            if let artistChildren = try? await mtp.list(storageID: selectedStorageID, parentID: artistID),
               artistChildren.isEmpty {
                try? await mtp.delete(itemID: artistID)
            }
        }
    }

    /// Invia una playlist di Apple Music sull'orologio. Prima di tutto rilegge la playlist
    /// direttamente da Musica (non usa la copia già caricata in questa app), cosi il file generato
    /// riflette sempre il contenuto attuale anche se la playlist è stata modificata nel frattempo.
    /// Il file .m3u8 esistente sul dispositivo, se presente, viene sempre eliminato e ricreato da
    /// zero — mai aggiornato "in place". Il file playlist viene sempre generato, referenziando
    /// tutti i brani risultati presenti sul dispositivo (copiati ora o già presenti da prima): un
    /// eventuale singolo brano realmente non trasferibile viene escluso ed evidenziato nella
    /// finestra di riepilogo, senza bloccare gli altri.
    func sendPlaylistToDevice(_ group: TrackGroup<LocalTrack>) async {
        guard ensureDeviceWritable() else { return }
        guard let playlistID = Self.rawPlaylistID(from: group.id) else {
            status = t("status_playlist_empty", group.title)
            return
        }

        await perform(t("status_preparing_playlist", group.title)) {
            // Libreria da file XML: non c'è Musica da rileggere, vale la playlist caricata.
            let fresh: (name: String, tracks: [LocalTrack])
            if externalLibraryName != nil {
                fresh = (group.title, group.tracks)
            } else if let f = try await library.currentPlaylistTracks(playlistID: playlistID) {
                fresh = f
            } else {
                status = t("status_playlist_not_found", group.title)
                return
            }
            let items = fresh.tracks.filter(\.isTransferable)
            guard !items.isEmpty else {
                status = t("status_playlist_empty", fresh.name)
                return
            }
            try await prepareExportBody(items: items, playlistName: fresh.name)
        }
    }

    /// Invio di più playlist insieme: si prepara in TEMP l'insieme dei brani (senza doppioni) e un file .m3u8 per
    /// playlist, si mostra un unico riepilogo e, alla conferma, ogni playlist viene inviata col proprio file
    /// (`sendTracksAsPlaylist`: i brani già copiati dalla playlist precedente risultano «già presenti»).
    func sendPlaylistsToDevice(_ groups: [TrackGroup<LocalTrack>], extras: [LocalTrack] = []) async {
        guard ensureDeviceWritable() else { return }
        let names = groups.map(\.title).joined(separator: ", ")
        await perform(t("status_preparing_playlist", names)) {
            var lists: [(name: String, tracks: [LocalTrack])] = []
            for group in groups {
                guard let playlistID = Self.rawPlaylistID(from: group.id) else { continue }
                // Come per la playlist singola: da Musica si rilegge lo stato attuale; da XML vale la playlist caricata.
                let fresh: (name: String, tracks: [LocalTrack])
                if externalLibraryName != nil {
                    fresh = (group.title, group.tracks)
                } else if let f = try await library.currentPlaylistTracks(playlistID: playlistID) {
                    fresh = f
                } else {
                    continue
                }
                let items = fresh.tracks.filter(\.isTransferable)
                if !items.isEmpty { lists.append((fresh.name, items)) }
            }
            guard !lists.isEmpty || !extras.isEmpty else {
                status = t("status_select_track")
                return
            }
            // Insieme dei brani senza ripetizioni, nell'ordine delle playlist; in coda i brani sciolti (nessuna playlist).
            var seen = Set<String>()
            let union = (lists.flatMap(\.tracks) + extras).filter { seen.insert($0.id).inserted }
            try await prepareExportBody(items: union, playlistName: lists.isEmpty ? nil : lists.map(\.name).joined(separator: ", "), playlists: lists)
        }
    }

    /// Crea/aggiorna il file .m3u8 sul dispositivo con questo nome, copiando prima gli eventuali
    /// brani mancanti. Il chiamante ha già filtrato `items` ai soli brani trasferibili e
    /// verificato che non siano vuoti; qui dentro gira già all'interno di `perform(...)`.
    /// `withPlaylistFile: false`: brani sciolti di un invio misto (playlist + altri brani) — si copiano come in un invio normale,
    /// senza creare né eliminare file playlist; `hasOtherSongs` adatta le diciture dei totali nella finestra.
    private func sendTracksAsPlaylist(name: String, items: [LocalTrack], multiple: Bool = false, plannedTotal: Int? = nil,
                                      hasOtherSongs: Bool = false, withPlaylistFile: Bool = true) async throws {
        var report = TransferReport(
            title: withPlaylistFile ? t("transfer_dialog_title_playlist", name) : t("transfer_dialog_title_tracks"),
            items: items.map { TransferItemResult(id: $0.id, title: $0.title, artist: $0.artist) },
            playlistName: name,
            isMultiple: multiple,
            plannedTotal: multiple ? plannedTotal : nil,
            includesOtherSongs: hasOtherSongs
        )
        // Invio di più playlist: la finestra è ancora aperta con il rapporto della precedente. Lo si archivia nell'elenco
        // (con il suo esito) e si conserva l'identificativo, così la finestra non si chiude e non si riapre.
        if multiple, let previous = transferReport, previous.isMultiple, let done = previous.summary {
            report.id = previous.id
            report.history = previous.history + [done]
        }
        transferReport = report

        let musicFolder = try await mtp.ensureFolder(named: "Music",
                                                     parentID: mtpRootParent,
                                                     storageID: selectedStorageID)
        let playlistFileName = Self.sanitizedFilename(name)

        var folderCache: [String: UInt32] = [:]
        var existingCache: [UInt32: Set<String>] = [:]
        var relativePaths: [String] = []

        var interrupted = false
        for (i, track) in items.enumerated() {
            // «Cancel» confermato: si ferma dopo il file in corso; la playlist non completata non viene creata.
            if transferStopRequested { interrupted = true; break }
            // Brano solo sul dispositivo: nessuna copia. Si ricontrolla la presenza (potrebbe essere stato eliminato dopo
            // l'import); se c'è, entra nel file playlist col suo percorso, altrimenti si segnala e resta fuori.
            if let devicePath = track.devicePath {
                updateTransferStatus(track.id, to: .processing)
                if deviceFileExists(relativePath: devicePath) {
                    updateTransferStatus(track.id, to: .skipped)
                    relativePaths.append(devicePath)
                } else {
                    updateTransferNote(track.id, t("device_only_missing_note"), isWarning: true)
                    updateTransferStatus(track.id, to: .error)
                }
                continue
            }
            guard let url = track.url else { updateTransferStatus(track.id, to: .error); continue }
            updateTransferStatus(track.id, to: .processing)
            status = t("status_sending", i + 1, items.count, track.title)
                progress = Double(i) / Double(max(items.count, 1))
            let artistName = Self.sanitizedFilename(track.artist.isEmpty ? t("unknown") : track.artist)
            let albumName = Self.sanitizedFilename(track.album.isEmpty ? t("unknown") : track.album)
            let targetFolder = try await ensureArtistAlbumFolder(artist: track.artist, album: track.album,
                                                                 musicFolderID: musicFolder, cache: &folderCache)
            let resolved = await stagedOrResolved(for: track, originalURL: url)
            defer { if let dir = resolved.tempDirectory { try? FileManager.default.removeItem(at: dir) } }
            if let warning = resolved.warning { updateTransferNote(track.id, warning, isWarning: true) }
                let uploadURL = resolved.url
            let outcome = try await uploadIfNeededAndVerify(from: uploadURL,
                                                            storageID: selectedStorageID,
                                                            parentID: targetFolder,
                                                            forceOverwrite: resolved.overwriteKey != nil,
                                                            existingCache: &existingCache)
            switch outcome {
            case .transferred:
                recordArtworkApplied(resolved, trackID: track.id)
                updateTransferStatus(track.id, to: .transferred)
                relativePaths.append("\(artistName)/\(albumName)/\(url.lastPathComponent)")
            case .transferredWithoutArtwork:
                updateTransferNote(track.id, t("artwork_not_applied_restored", lastUploadError ?? "?"), isWarning: true)
                updateTransferStatus(track.id, to: .transferred)
                relativePaths.append("\(artistName)/\(albumName)/\(url.lastPathComponent)")
            case .skipped:
                updateTransferStatus(track.id, to: .skipped)
                relativePaths.append("\(artistName)/\(albumName)/\(url.lastPathComponent)")
            case .failed:
                if let error = lastUploadError { updateTransferNote(track.id, error, isWarning: true) }
                updateTransferStatus(track.id, to: .error)
            }
        }

        // Invio interrotto a metà: i brani già copiati restano; la playlist (non completa) non si crea né si tocca quella esistente.
        if interrupted {
            _ = await reloadDeviceBounded()
            status = "⚠️ " + t("status_send_stopped")
            return
        }

        // Brani sciolti di un invio misto: niente file playlist; si aggiorna l'elenco del dispositivo e basta.
        if !withPlaylistFile {
            status = t("status_refreshing_device")
            try? await Task.sleep(nanoseconds: 500_000_000)
            let refreshed = await reloadDeviceBounded()
            let failed = items.count - relativePaths.count
            status = failed == 0
                ? t("status_sent_tracks", relativePaths.count, NoticeFormat.bold(deviceNameForAlerts))
                : t("status_sent_tracks_with_failures", relativePaths.count, failed, NoticeFormat.bold(deviceNameForAlerts))
            if !refreshed { status += " " + t("status_refresh_pending") }
            return
        }

        // Il file .m3u8 si genera sempre, con tutti i brani risultati presenti: non si blocca
        // più l'intera operazione per un singolo brano in errore, cosi non serve un secondo
        // tentativo per gli altri che sono comunque andati a buon fine.
        guard !relativePaths.isEmpty else {
            _ = await reloadDeviceBounded()
            status = t("status_playlist_verification_failed", name, 0, items.count)
            return
        }

        // Da qui in poi i file audio sono copiati: «Cancel» non serve più finché la playlist non è scritta e verificata.
        transferStopLocked = true
        defer { transferStopLocked = false }
        // Elimina un eventuale file playlist già esistente: viene sempre ricreato da zero (solo ora che l'invio è completo).
        await mtp.deleteExistingPlaylistFile(named: playlistFileName, storageID: selectedStorageID, parentID: musicFolder)

        status = t("status_creating_playlist_file")
        // Con un tempo massimo (come la verifica): se il dispositivo non risponde non si resta appesi.
        let mtp = self.mtp
        let storageID = selectedStorageID
        let paths = relativePaths
        // 2.0.1: il file si verifica subito dopo la scrittura (presente, riscaricabile, stesso contenuto) e, se manca
        // o è incompleto, si ricrea (fino a 3 tentativi).
        let playlistUploaded: Bool? = await withTimeout(180) {
            await mtp.uploadPlaylistVerified(name: playlistFileName, filenames: paths,
                                             storageID: storageID, parentID: musicFolder)
        }
        guard let uploaded = playlistUploaded else {
            status = t("status_device_not_responding")
            return
        }
        guard uploaded else {
            _ = await reloadDeviceBounded()
            status = t("status_playlist_file_not_verified", name)
            return
        }
        // Alcuni dispositivi impiegano un istante ad aggiornare il proprio elenco interno dopo una scrittura:
        // si rilegge più volte, con pause crescenti, finché la playlist compare con il numero di brani atteso.
        var refreshed = false
        var listed = false
        var found = 0
        for attempt in 0..<4 {
            try? await Task.sleep(nanoseconds: UInt64(attempt == 0 ? 700_000_000 : 1_500_000_000))
            refreshed = await reloadDeviceBounded()
            guard refreshed else { continue }
            if let group = devicePlaylists.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
                listed = true
                found = group.tracks.count
                if found == relativePaths.count { break }
            }
        }
        status = relativePaths.count == items.count
            ? t("status_playlist_sent", NoticeFormat.bold(name), relativePaths.count, NoticeFormat.bold(deviceNameForAlerts))
            : t("status_playlist_sent_partial", name, relativePaths.count, items.count)
        if refreshed && !listed {
            status += " " + t("status_playlist_not_listed", name)
        } else if listed && found != relativePaths.count {
            status += " " + t("status_playlist_count_mismatch", found, relativePaths.count)
        }
        if !refreshed { status += " " + t("status_refresh_pending") }
    }

    /// Invia la Custom Playlist (creata a mano nella scheda omonima, popolata dal pulsante "Invia
    /// alla Playlist" sulla selezione corrente delle altre schede) sull'orologio, con lo stesso
    /// meccanismo (file .m3u8 ricreato da zero, con lo stesso controllo di verifica) usato per le
    /// playlist di Apple Music.
    func sendCustomPlaylistToDevice(skipArtworkCheck: Bool = false) async {
        guard ensureDeviceWritable() else { return }
        let name = customPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            status = t("status_custom_playlist_name_required")
            return
        }
        let items = customPlaylistEntries.map(\.track).filter(\.isTransferable)
        guard !items.isEmpty else {
            status = t("status_playlist_empty", name)
            return
        }
        // Precontrollo: se mancano copertine (di qualunque brano) si propone la ricerca online; l'invio riprende
        // (con la sua conferma) solo dopo l'eventuale associazione delle copertine, o con «Continua senza».
        // I brani solo sul dispositivo non hanno file locale: restano fuori dal controllo.
        if !skipArtworkCheck, await askArtworkSearchIfNeeded(for: items.filter { !$0.isDeviceOnly }, allTracks: true, proceed: { [weak self] in
            Task { await self?.sendCustomPlaylistToDevice(skipArtworkCheck: true) }
        }) { return }
        await perform(t("status_preparing_playlist", name)) {
            try await prepareExportBody(items: items, playlistName: name)
        }
    }

    // MARK: - Modifica di una playlist del dispositivo (Edit in Custom)

    /// Vero se il file con questo percorso (relativo alla cartella Music) è nell'ultimo catalogo letto dal dispositivo.
    private func deviceFileExists(relativePath: String) -> Bool {
        let wanted = relativePath.lowercased()
        return deviceTracks.contains { $0.relativePath.lowercased() == wanted }
    }

    /// Importa nella Custom Playlist una playlist del dispositivo (menu / pulsante «Edit in Custom»). La Custom prende il
    /// nome della playlist del device. Ogni brano è abbinato per titolo + artista (senza maiuscole né accenti; con più
    /// corrispondenze vince quello con lo stesso album) a un brano trasferibile della libreria in uso; se non c'è (o in
    /// libreria è bloccato: DRM, solo cloud, Hi-Res) resta «solo device» e si usa il file già sul dispositivo.
    func editDevicePlaylistInCustom(_ group: TrackGroup<DeviceTrack>) {
        func norm(_ text: String) -> String {
            text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var index: [String: [LocalTrack]] = [:]
        for track in tracks where track.isTransferable && !track.isDeviceOnly {
            index[norm(track.title) + "|" + norm(track.artist), default: []].append(track)
        }
        let converted: [LocalTrack] = group.tracks.map { d in
            let candidates = index[norm(d.title) + "|" + norm(d.artist)] ?? []
            if let match = candidates.first(where: { norm($0.album) == norm(d.album) }) ?? candidates.first {
                return match
            }
            var only = LocalTrack(id: "device:\(d.id)", title: d.title, artist: d.artist, album: d.album, url: nil,
                                  fileSize: Int(d.size), isDRMProtected: false, isCloud: false,
                                  duration: d.duration, trackNumber: 0)
            only.devicePath = d.relativePath
            return only
        }
        guard !converted.isEmpty else {
            status = t("status_device_playlist_empty", group.title)
            return
        }
        let deviceOnly = converted.filter(\.isDeviceOnly).count
        status = t("status_device_playlist_imported", group.title, converted.count, converted.count - deviceOnly, deviceOnly)
        appleCategory = .customPlaylist
        if customPlaylistEntries.isEmpty {
            customPlaylistEntries = converted.map { CustomPlaylistEntry(track: $0) }
            customPlaylistName = group.title
            customPlaylistSortOption = .manual
            customPlaylistManualOrder = []
        } else {
            // Custom Playlist già con dei brani: stessa scelta del caricamento da file (alert in `ContentView`).
            pendingFileLoad = PendingFileLoad(name: group.title, tracks: converted, fromDevice: true)
        }
    }

    // MARK: - Custom Playlist

    @Published var customPlaylistName: String = ""
    @Published var customPlaylistEntries: [CustomPlaylistEntry<LocalTrack>] = [] {
        didSet { if appleCategory == .customPlaylist { updatePendingTransferBytes() } }
    }
    /// Brani risultati già presenti nella Custom Playlist dopo un click su "Invia alla Playlist":
    /// in attesa di conferma (vedi l'alert in `ContentView`) prima di aggiungerli comunque.
    @Published var pendingCustomPlaylistDuplicates: [LocalTrack]?

    /// In attesa della scelta "Svuota e invia"/"Aggiungi senza svuotare" quando "Invia alla
    /// Playlist" ha rilevato che la selezione è un'intera playlist di Apple Music E la Custom
    /// Playlist contiene già degli elementi (vedi l'alert in `ContentView`). Tiene già i brani
    /// nell'ordine della playlist di origine, pronti per essere applicati con
    /// `applyTracksToCustomPlaylist` non appena l'utente risponde.
    struct PendingWholePlaylistSend {
        let playlistTitle: String
        let tracks: [LocalTrack]
    }
    @Published var pendingWholePlaylistSend: PendingWholePlaylistSend?

    /// Mantiene i brani di uno stesso album uniti e nell'ordine disco / numero di traccia (anche se l'album
    /// è selezionato solo in parte); gli album restano nell'ordine in cui compaiono nell'elenco. Senza
    /// questo, i brani selezionati da «Brani» arrivano in ordine alfabetico e l'ordine dell'album si perde.
    private func albumOrdered(_ list: [LocalTrack]) -> [LocalTrack] {
        var order: [String] = []
        var groups: [String: [LocalTrack]] = [:]
        for track in list {
            let key = track.album.isEmpty
                ? "t|" + track.id
                : track.album.lowercased() + "|" + (track.albumArtist.isEmpty ? track.artist : track.albumArtist).lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(track)
        }
        return order.flatMap { key in (groups[key] ?? []).sorted(by: inAlbumOrder) }
    }

    /// Aggiunge l'intera selezione corrente (presa da una qualunque delle schede Playlist/Artisti/
    /// Album/Brani, condivisa tra tutte) alla Custom Playlist con un unico click.
    ///
    /// Se la selezione corrisponde esattamente (stessi brani, indipendentemente da come sono stati
    /// selezionati) a un'intera playlist di Apple Music — il caso tipico di "Seleziona" sull'
    /// intestazione di una playlist nella scheda Playlist — i brani vengono aggiunti nell'ordine di
    /// quella playlist di origine, non nell'ordine (alfabetico per artista/album/titolo) dell'
    /// elenco "Brani", e la Custom Playlist prende il nome dell'originale + "_copy" (se era vuota
    /// o viene svuotata; altrimenti il nome attuale resta). Se in quel caso la Custom
    /// Playlist contiene già degli elementi, prima di procedere si chiede se svuotarla oppure
    /// aggiungere questi brani a quelli già presenti (vedi `pendingWholePlaylistSend`), invece di
    /// mescolarli senza preavviso.
    func addSelectedTracksToCustomPlaylist() {
        guard !selectedTrackIDs.isEmpty else { return }
        // Libreria di un'altra rete: l'Apple Artwork non si carica da sola. Si legge ora, solo per i brani che entrano
        // nella Custom Playlist; poi segue il flusso normale (con la proposta di ricerca online per quelli senza copertina).
        if isRemoteNetworkLibraryActive {
            let picked = tracks.filter { selectedTrackIDs.contains($0.id) && $0.isTransferable }
            Task { [weak self] in
                guard let self else { return }
                await self.loadArtworkNow(picked)
                self.continueAddSelectedTracksToCustomPlaylist()
            }
            return
        }
        continueAddSelectedTracksToCustomPlaylist()
    }

    /// Legge subito (con l'avviso di caricamento) le copertine dei brani indicati, se non già note.
    private func loadArtworkNow(_ list: [LocalTrack]) async {
        let todo = list.filter { !hasArtworkAlready($0) }
        guard !todo.isEmpty else { return }
        await beginArtworkLoad()
        // Più letture insieme (a gruppi di 6): su un disco di rete ogni file ha un'attesa, in parallelo si sovrappongono.
        var index = 0
        while index < todo.count {
            let chunk = Array(todo[index..<min(index + 6, todo.count)])
            await withTaskGroup(of: Void.self) { group in
                for track in chunk {
                    group.addTask { @MainActor [weak self] in
                        _ = await self?.appleArtworkResolved(for: track, fromMusic: true)
                    }
                }
            }
            index += 6
        }
        artworkRevision += 1
        endArtworkLoad()
    }

    private func continueAddSelectedTracksToCustomPlaylist() {
        guard !selectedTrackIDs.isEmpty else { return }
        // Brani di una libreria condivisa senza copertina: prima si propone la ricerca online.
        let remote = tracks.filter { selectedTrackIDs.contains($0.id) && $0.isTransferable }   // anche la libreria locale
        guard !remote.isEmpty, AppSettings.shared.proposeSharedArtworkSearch,
              AppSettings.shared.lookupMissingArtworkOnline else {
            addSelectedTracksToCustomPlaylistNow()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let asked = await self.askArtworkSearchIfNeeded(for: remote) { [weak self] in
                self?.addSelectedTracksToCustomPlaylistNow()
            }
            if !asked { self.addSelectedTracksToCustomPlaylistNow() }
        }
    }

    private func addSelectedTracksToCustomPlaylistNow() {
        guard !selectedTrackIDs.isEmpty else { return }
        // Con "Solo trasferibili" attivo l'intestazione di una playlist seleziona solo i brani
        // visibili (non l'intera playlist): si confronta quindi la selezione con la playlist così
        // come appare (`visiblePlaylists`), poi con quella completa. L'ordine dei brani è sempre
        // quello originale della playlist.
        var matchedPlaylist = visiblePlaylists.first { Set($0.tracks.map(\.id)) == selectedTrackIDs }
            ?? playlists.first { Set($0.tracks.map(\.id)) == selectedTrackIDs }
        var selected = matchedPlaylist?.tracks ?? albumOrdered(tracks.filter { selectedTrackIDs.contains($0.id) })
        // Selezione = playlist intera + altri brani rimasti selezionati: la playlist (nel suo
        // ordine) viene prima, gli altri brani seguono.
        if matchedPlaylist == nil, let id = lastFullySelectedPlaylistID,
           let g = visiblePlaylists.first(where: { $0.id == id }),
           Set(g.tracks.map(\.id)).isSubset(of: selectedTrackIDs) {
            let inPlaylist = Set(g.tracks.map(\.id))
            matchedPlaylist = g
            selected = g.tracks + albumOrdered(tracks.filter { selectedTrackIDs.contains($0.id) && !inPlaylist.contains($0.id) })
        }
        guard !selected.isEmpty else { return }

        if let matchedPlaylist, !customPlaylistEntries.isEmpty {
            pendingWholePlaylistSend = PendingWholePlaylistSend(playlistTitle: matchedPlaylist.title, tracks: selected)
            return
        }

        applyTracksToCustomPlaylist(selected, originPlaylistTitle: matchedPlaylist?.title,
                                    renameToCopy: customPlaylistEntries.isEmpty)
        // Invio concluso: si azzerano tutte le selezioni, così la stessa selezione non può essere
        // inviata una seconda volta (né accumularsi con la prossima).
        selectedTrackIDs = []
    }

    /// Logica di aggiunta effettiva alla Custom Playlist (fresh/duplicati, più l'eventuale
    /// richiesta del nome se i brani provengono da un'intera playlist): fattorizzata per essere
    /// condivisa tra l'invio diretto e le due risposte dell'alert "Svuotare prima?" sotto.
    private func applyTracksToCustomPlaylist(_ selected: [LocalTrack], originPlaylistTitle: String?, renameToCopy: Bool = false,
                                             copySuffix: Bool = true) {
        var seenIDs = Set(customPlaylistEntries.map { $0.track.id })
        var fresh: [LocalTrack] = []
        var duplicates: [LocalTrack] = []
        for track in selected {
            if seenIDs.contains(track.id) {
                duplicates.append(track)
            } else {
                fresh.append(track)
                seenIDs.insert(track.id)
            }
        }
        if !fresh.isEmpty {
            customPlaylistEntries.append(contentsOf: fresh.map { CustomPlaylistEntry(track: $0) })
        }
        if !duplicates.isEmpty {
            pendingCustomPlaylistDuplicates = duplicates
        }
        // Playlist inviata per intero: la radice dell'albero prende il nome dell'originale + "_copy"
        // quando la Custom era vuota (o è stata appena svuotata); in caso di accodamento a una
        // lista già popolata il nome attuale resta, salvo che sia vuoto.
        if let originPlaylistTitle, renameToCopy || customPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty {
            customPlaylistName = originPlaylistTitle + (copySuffix ? t("custom_playlist_copy_suffix") : "")
        }
    }

    /// L'utente ha scelto di svuotare prima la Custom Playlist (stesso effetto di "Svuota
    /// playlist"): la azzera e la ripopola da zero con l'intera playlist inviata, senza che siano
    /// possibili duplicati.
    func confirmClearAndSendWholePlaylist() {
        guard let pending = pendingWholePlaylistSend else { return }
        pendingWholePlaylistSend = nil
        customPlaylistEntries = []
        customPlaylistSortOption = .manual
        customPlaylistManualOrder = []
        applyTracksToCustomPlaylist(pending.tracks, originPlaylistTitle: pending.playlistTitle, renameToCopy: true)
        selectedTrackIDs = []
    }

    /// L'utente ha scelto di non svuotare: aggiunge comunque i brani della playlist a quelli già
    /// presenti, con la consueta gestione dei duplicati. Poi deseleziona la playlist di origine
    /// (ha già fatto il suo lavoro) e passa alla scheda Custom Playlist, cosi l'utente vede subito
    /// il risultato — i brani appena aggiunti insieme a quelli già presenti — invece di restare
    /// sulla scheda Playlist con la selezione ancora attiva.
    func confirmAppendWholePlaylistWithoutClearing() {
        guard let pending = pendingWholePlaylistSend else { return }
        pendingWholePlaylistSend = nil
        // Accodamento a una Custom già popolata: il nome resta quello scelto dall'utente (o vuoto), mai «playlist_copy».
        applyTracksToCustomPlaylist(pending.tracks, originPlaylistTitle: nil)
        selectedTrackIDs = []
        appleCategory = .customPlaylist
    }

    /// L'utente ha annullato: non tocca la Custom Playlist.
    func cancelWholePlaylistSend() {
        pendingWholePlaylistSend = nil
    }

    /// Aggiunge comunque alla Custom Playlist i brani lasciati in sospeso perché già presenti.
    func confirmAddPendingDuplicatesToCustomPlaylist() {
        guard let duplicates = pendingCustomPlaylistDuplicates else { return }
        customPlaylistEntries.append(contentsOf: duplicates.map { CustomPlaylistEntry(track: $0) })
        pendingCustomPlaylistDuplicates = nil
    }

    /// Aggiunge in fondo alla Custom Playlist solo i duplicati scelti nel pannello (gli altri vengono saltati).
    func addChosenDuplicatesToCustomPlaylist(_ chosen: [LocalTrack]) {
        customPlaylistEntries.append(contentsOf: chosen.map { CustomPlaylistEntry(track: $0) })
        pendingCustomPlaylistDuplicates = nil
    }

    /// Scarta i brani lasciati in sospeso perché già presenti, senza aggiungerli una seconda volta.
    func cancelPendingCustomPlaylistDuplicates() {
        pendingCustomPlaylistDuplicates = nil
    }

    /// Svuota la selezione corrente (condivisa tra le schede Playlist/Artisti/Album/Brani).
    func clearSelection() {
        selectedTrackIDs = []
    }

    /// «Pulisci selezione» del pannello Device: svuota la selezione dei brani (e, di riflesso, delle playlist scelte).
    func clearDeviceSelection() {
        selectedDeviceTrackIDs = []
    }

    /// Criterio di ordinamento attualmente attivo per la Custom Playlist, mostrato dal Picker
    /// "Ordina per" (`CustomPlaylistConfig.sortOption`). Tenuto qui (non come `@State` locale in
    /// `CatalogBrowser`) cosi resta coerente anche quando cambia da fuori, es. "Svuota playlist"
    /// lo riporta a "Manuale".
    @Published private(set) var customPlaylistSortOption: CustomPlaylistSortOption = .manual
    /// Ultimo ordine manuale noto della Custom Playlist (ID delle righe), salvato subito prima di
    /// passare da "Manuale" a un ordinamento automatico: permette di recuperarlo scegliendo di
    /// nuovo "Manuale" nel menu, invece di restare bloccati sull'ultimo ordinamento automatico
    /// applicato. Non si aggiorna mentre si trascinano le righe in modalità manuale: a quel punto
    /// `customPlaylistEntries` stesso È già l'ordine manuale corrente, non serve una copia.
    private var customPlaylistManualOrder: [UUID] = []

    /// Pacchetto di stato/azioni passato a `CatalogBrowser` per la scheda "Custom Playlist": letto
    /// da `ContentView.musicPane` a ogni ridisegno, cosi riflette sempre lo stato corrente.
    var customPlaylistConfig: CustomPlaylistConfig<LocalTrack> {
        CustomPlaylistConfig(
            name: customPlaylistName,
            onNameChange: { [weak self] in self?.customPlaylistName = $0 },
            entries: customPlaylistEntries,
            onRemove: { [weak self] id in
                self?.customPlaylistEntries.removeAll { $0.id == id }
            },
            onMove: { [weak self] source, destination in
                self?.customPlaylistEntries.move(fromOffsets: source, toOffset: destination)
            },
            sortOption: customPlaylistSortOption,
            onSort: { [weak self] option in
                self?.sortCustomPlaylist(by: option)
            },
            onClear: { [weak self] in
                // Prima di svuotare si chiede conferma (alert in `ContentView`).
                self?.pendingClearCustomPlaylist = true
            },
            onSendToWatch: { [weak self] in Task { await self?.sendCustomPlaylistToDevice() } },
            onSaveToAppleMusic: { [weak self] in Task { await self?.saveCustomPlaylistToAppleMusic() } },
            isBusy: isBusy
        )
    }

    /// «Svuota playlist» premuto: in attesa di «Conferma» / «Salva su file» / «Annulla».
    @Published var pendingClearCustomPlaylist = false

    /// Svuota davvero la Custom Playlist (elenco, nome e ordinamento).
    func clearCustomPlaylist() {
        pendingClearCustomPlaylist = false
        customPlaylistEntries = []
        customPlaylistName = ""
        customPlaylistSortOption = .manual
        customPlaylistManualOrder = []
    }

    /// «Salva su file»: salva la playlist e, solo se il salvataggio riesce, la svuota. Senza nome (o se il file
    /// esiste già e si annulla) non viene cancellato nulla.
    func saveCustomPlaylistToFileThenClear() {
        pendingClearCustomPlaylist = false
        saveCustomPlaylistToFile(thenClear: true)
    }

    /// Riordina tutta la Custom Playlist secondo il criterio scelto nel menu "Ordina per".
    /// Ordinando per Album, i brani dello stesso album restano nell'ordine del loro numero di
    /// traccia (`trackNumber`), invece che in un ordine arbitrario. Passando da "Manuale" a un
    /// ordinamento automatico, l'ordine manuale attuale viene prima salvato in
    /// `customPlaylistManualOrder`; scegliendo di nuovo "Manuale" lo recupera (i brani aggiunti nel
    /// frattempo, non presenti in quell'ordine salvato, vengono accodati in fondo invece di andare
    /// persi).
    private func sortCustomPlaylist(by option: CustomPlaylistSortOption) {
        // Dal «Casuale» a «Manuale»: prima si chiede se tenere l'ordine casuale attuale come manuale o ripristinare
        // il Manuale precedente (alert in `ContentView`). Finché non risponde, il menu resta su «Casuale».
        if option == .manual, customPlaylistSortOption == .random {
            pendingRandomToManual = true
            return
        }
        switch option {
        case .manual:
            if !customPlaylistManualOrder.isEmpty {
                let byID = Dictionary(uniqueKeysWithValues: customPlaylistEntries.map { ($0.id, $0) })
                var restored = customPlaylistManualOrder.compactMap { byID[$0] }
                let restoredIDs = Set(restored.map(\.id))
                restored += customPlaylistEntries.filter { !restoredIDs.contains($0.id) }
                customPlaylistEntries = restored
            }
        case .trackName:
            saveManualOrderIfNeeded()
            customPlaylistEntries.sort {
                $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
            }
        case .artist:
            saveManualOrderIfNeeded()
            customPlaylistEntries.sort {
                $0.track.artist.localizedCaseInsensitiveCompare($1.track.artist) == .orderedAscending
            }
        case .album:
            saveManualOrderIfNeeded()
            customPlaylistEntries.sort { a, b in
                let albumOrder = a.track.album.localizedCaseInsensitiveCompare(b.track.album)
                if albumOrder != .orderedSame { return albumOrder == .orderedAscending }
                return a.track.trackNumber < b.track.trackNumber
            }
        case .random:
            // Mischia a caso i brani; l'ordine manuale precedente resta recuperabile scegliendo di nuovo «Manuale».
            saveManualOrderIfNeeded()
            customPlaylistEntries.shuffle()
        }
        customPlaylistSortOption = option
    }

    /// In attesa della scelta dopo il passaggio da «Casuale» a «Manuale» (alert in `ContentView`).
    @Published var pendingRandomToManual = false

    /// «Mantieni l'ordine casuale»: l'ordine attuale diventa il nuovo ordine manuale.
    func keepRandomOrderAsManual() {
        pendingRandomToManual = false
        customPlaylistSortOption = .manual
        customPlaylistManualOrder = []   // al prossimo ordinamento automatico si salverà l'ordine attuale
    }

    /// «Ripristina il Manuale precedente»: riporta l'ordine manuale salvato prima del «Casuale».
    func restorePreviousManualOrder() {
        pendingRandomToManual = false
        sortCustomPlaylistRestoringManual()
    }

    private func sortCustomPlaylistRestoringManual() {
        if !customPlaylistManualOrder.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: customPlaylistEntries.map { ($0.id, $0) })
            var restored = customPlaylistManualOrder.compactMap { byID[$0] }
            let restoredIDs = Set(restored.map(\.id))
            restored += customPlaylistEntries.filter { !restoredIDs.contains($0.id) }
            customPlaylistEntries = restored
        }
        customPlaylistSortOption = .manual
    }

    /// Salva l'ordine attuale come "ultimo ordine manuale noto", ma solo se l'ordinamento
    /// attualmente attivo è ancora "Manuale": se è già un ordinamento automatico (es. si passa da
    /// Titolo ad Artista), l'ordine attuale non è manuale e non va salvato sopra quello buono.
    private func saveManualOrderIfNeeded() {
        guard customPlaylistSortOption == .manual else { return }
        customPlaylistManualOrder = customPlaylistEntries.map(\.id)
    }

    /// In attesa della scelta "Sostituisci"/"Aggiungi" quando si salva la Custom Playlist in Apple
    /// Music con un nome già usato da una playlist esistente (vedi l'alert in `ContentView`).
    /// Tiene i brani (non solo gli URL) cosi l'eventuale alert sui duplicati può mostrarne titolo
    /// e artista, non solo un conteggio.
    struct SaveToAppleMusicConflict {
        let name: String
        let tracks: [LocalTrack]
    }
    @Published var pendingSaveToAppleMusicConflict: SaveToAppleMusicConflict?

    /// In attesa della conferma "Aggiungi comunque"/"Salta" per i brani risultati già presenti
    /// nella playlist di Apple Music scelta, dopo che l'utente ha scelto "Aggiungi" (non
    /// "Sostituisci") sul conflitto di nome sopra.
    struct SaveToAppleMusicDuplicates {
        let name: String
        /// Solo i brani NON già presenti nella playlist esistente.
        let freshTracks: [LocalTrack]
        /// Solo i brani risultati già presenti: mostrati nell'alert (titolo e artista), non solo
        /// contati, cosi l'utente sa esattamente quali brani sta per duplicare.
        let duplicateTracks: [LocalTrack]
        /// Tutti i brani scelti per l'aggiunta, compresi quelli già presenti: usato se l'utente
        /// sceglie "Aggiungi comunque".
        var allTracks: [LocalTrack] { freshTracks + duplicateTracks }
    }
    @Published var pendingSaveToAppleMusicDuplicates: SaveToAppleMusicDuplicates?

    /// In attesa della conferma "Sì"/"No" per caricare nella Custom Playlist, per comodità di
    /// successiva modifica, tutti i brani della playlist di Apple Music in cui si sono appena
    /// aggiunti dei brani (non solo quelli appena aggiunti: anche quelli già presenti da prima).
    /// Proposto solo dopo un'aggiunta riuscita a una playlist già esistente, non dopo una
    /// creazione da zero o una sostituzione (in quei due casi la Custom Playlist coincide già con
    /// l'intero contenuto della playlist in Apple Music).
    struct SaveToAppleMusicLoadFullPlaylistPrompt {
        let name: String
        let tracks: [LocalTrack]
    }
    @Published var pendingLoadFullAppleMusicPlaylist: SaveToAppleMusicLoadFullPlaylistPrompt?

    // MARK: - Domanda prima di aggiungere a Music (2.2)

    /// Chiede se aggiungere a Music i brani indicati (per titolo). Senza «Chiedi conferma» in Impostazioni, o senza brani, risponde subito
    /// «aggiungi». La domanda è un pannello nostro (`DialogPresenter`), largo quanto serve e con l'elenco dei titoli scorrevole.
    func askBeforeAddingToMusic(context: MusicAddContext, titles: [String]) async -> MusicAddAnswer {
        guard AppSettings.shared.confirmBeforeMusicChanges, !titles.isEmpty else { return .add }
        // Un attimo di pausa: il pannello di importazione si sta chiudendo.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let model: QuitDialogModel
        switch context {
        case .createPlaylist:
            model = QuitDialogModel(
                title: t("alert_music_add_title"), message: t("alert_music_add_message_playlist", titles.first ?? ""),
                buttons: [QuitDialogButton(title: t("button_save_to_music_short"), kind: .primary),
                          QuitDialogButton(title: t("button_cancel"), isCancel: true)])
        case .customPlaylist:
            model = QuitDialogModel(
                title: t("alert_music_add_title"), message: t("alert_music_add_message_custom", titles.count),
                buttons: [QuitDialogButton(title: t("button_add_to_music"), kind: .primary),
                          QuitDialogButton(title: t("button_save_without_them")),
                          QuitDialogButton(title: t("button_cancel"), isCancel: true)])
            model.items = titles
        case .dropped:
            model = QuitDialogModel(
                title: t("alert_music_add_title"), message: t("alert_music_add_message_drop", titles.count),
                buttons: [QuitDialogButton(title: t("button_add_to_music"), kind: .primary),
                          QuitDialogButton(title: t("button_watch_only")),
                          QuitDialogButton(title: t("button_cancel"), isCancel: true)])
            model.items = titles
        }
        let choice = DialogPresenter.run(model)
        if context == .createPlaylist { return choice == 0 ? .add : .cancel }
        switch choice {
        case 0: return .add
        case 1: return .skip
        default: return .cancel
        }
    }

    /// Dopo un'aggiunta riuscita a una playlist già esistente: se la ritrova tra quelle appena
    /// ricaricate da Musica, propone di caricarne tutto il contenuto nella Custom Playlist (vedi
    /// `pendingLoadFullAppleMusicPlaylist`). Se non la ritrova (caso raro: rinominata o rimossa
    /// nel frattempo) non propone nulla.
    private func offerToLoadFullAppleMusicPlaylistIntoCustom(named name: String) {
        guard let group = playlists.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        pendingLoadFullAppleMusicPlaylist = SaveToAppleMusicLoadFullPlaylistPrompt(name: name, tracks: group.tracks)
    }

    /// L'utente ha confermato: sostituisce il contenuto della Custom Playlist con tutti i brani
    /// risultati nella playlist di Apple Music (comodo per poi modificarla, es. riordinarla, senza
    /// dover ricostruire a mano l'elenco completo).
    func confirmLoadFullAppleMusicPlaylistIntoCustom() {
        guard let pending = pendingLoadFullAppleMusicPlaylist else { return }
        pendingLoadFullAppleMusicPlaylist = nil
        customPlaylistEntries = pending.tracks.map { CustomPlaylistEntry(track: $0) }
    }

    /// L'utente ha rifiutato: la Custom Playlist resta com'era, senza caricare il resto del
    /// contenuto della playlist di Apple Music.
    func declineLoadFullAppleMusicPlaylistIntoCustom() {
        pendingLoadFullAppleMusicPlaylist = nil
    }

    /// Sostituisce i brani di librerie esterne («ext:») già presenti in Music (stesso titolo, artista e album, file esistente)
    /// con i brani della libreria locale. Gli altri restano come sono.
    func replacingExternalWithLibrary(_ list: [LocalTrack]) -> [LocalTrack] {
        guard list.contains(where: { $0.isOutsideMusicLibrary }) else { return list }
        let norm = Self.normalizedForMatch
        let byTitle = Dictionary(grouping: localTracks) { norm($0.title) }
        return list.map { track in
            guard track.isOutsideMusicLibrary,
                  let found = byTitle[norm(track.title)]?.first(where: {
                      norm($0.artist) == norm(track.artist)
                          && (track.album.isEmpty || $0.album.isEmpty || norm($0.album) == norm(track.album))
                          && ($0.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
                  }) else { return track }
            return found
        }
    }

    /// Dopo un salvataggio in Music (la libreria è appena stata riletta): i brani esterni della Custom Playlist che ora sono in
    /// Music passano ai percorsi della libreria locale e, se esiste già il file `.m3u8` con il nome della playlist, si riscrive
    /// con i percorsi corretti (niente più riferimenti a /Volumes per i brani copiati in Music).
    func syncCustomPlaylistReferences(afterSavingTo name: String) {
        let before = customPlaylistEntries.map(\.track)
        let after = replacingExternalWithLibrary(before)
        let changed = zip(before, after).filter { $0.id != $1.id }.count
        // Diagnostica: per ogni brano esterno, dove è finito in Music (o perché non si è trovato).
        for (old, new) in zip(before, after) where old.isOutsideMusicLibrary {
            if new.id != old.id {
                AppLog.debug("Custom ▸ Music: «\(old.title)» trovato in libreria: \(new.url?.path ?? "senza file")")
            } else {
                AppLog.debug("Custom ▸ Music: «\(old.title)» NON trovato in libreria (artista «\(old.artist)», album «\(old.album)»)")
            }
        }
        guard changed > 0 else { return }
        customPlaylistEntries = after.map { CustomPlaylistEntry(track: $0) }
        AppLog.debug("Custom Playlist: \(changed) brani esterni ora in Music; riferimenti aggiornati")
        let cleaned = name.trimmingCharacters(in: .whitespaces)
        if cleaned == customPlaylistName.trimmingCharacters(in: .whitespaces),
           FileManager.default.fileExists(atPath: customPlaylistFileURL(cleaned).path) {
            let keepStatus = status   // il messaggio del salvataggio in Music resta quello mostrato
            saveCustomPlaylistToFile(overwrite: true)
            status = keepStatus
            AppLog.write("Custom Playlist file «\(cleaned)» updated with the Music library paths.")
        }
    }

    /// Salva la Custom Playlist in Apple Musica, cosi resta anche li e non solo sull'orologio.
    /// Controlla Musica via Apple Event (AppleScript): vedi `AppleMusicScripting`. Se non esiste
    /// già una playlist con questo nome la crea direttamente; se esiste già, chiede prima se
    /// sostituirla del tutto o aggiungere questi brani a quella esistente (vedi
    /// `pendingSaveToAppleMusicConflict`, con l'alert in `ContentView`).
    func saveCustomPlaylistToAppleMusic() async {
        let name = customPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            status = t("status_custom_playlist_name_required")
            return
        }
        var candidates = customPlaylistEntries.map(\.track).filter { $0.url != nil }
        // Un brano di una libreria esterna che nel frattempo è stato aggiunto a Music (stesso titolo, artista e album) si
        // sostituisce con quello della libreria: non è più «esterno», quindi non si chiede di nuovo di aggiungerlo e finisce
        // nella playlist per ID, senza duplicati.
        candidates = replacingExternalWithLibrary(candidates)
        // Brani di una libreria esterna («ext:»): non sono in Music e salvare la playlist li aggiungerebbe alla libreria.
        let outside = candidates.filter { $0.isOutsideMusicLibrary }
        if !outside.isEmpty {
            switch await askBeforeAddingToMusic(context: .customPlaylist, titles: outside.map(\.title)) {
            case .cancel: return
            case .skip: candidates = candidates.filter { !$0.isOutsideMusicLibrary }
            case .add: break
            }
        }
        let tracks = candidates
        AppLog.debug("Salva in Music «\(name)»: \(tracks.count) brani, esterni (ext:): \(outside.count); conferma attiva: \(AppSettings.shared.confirmBeforeMusicChanges)")
        guard !tracks.isEmpty else {
            status = t("status_playlist_empty", name)
            return
        }
        // Nessun brano esterno da aggiungere: se la playlist non esiste ancora, la sua creazione in Music è comunque una modifica.
        // (Se esiste già, segue la domanda «sostituire o aggiungere?», senza una conferma in più.)
        if outside.isEmpty, AppSettings.shared.confirmBeforeMusicChanges {
            let exists = (try? AppleMusicScripting.playlistExists(named: name)) ?? false
            AppLog.debug("Salva in Music: la playlist «\(name)» esiste già: \(exists)")
            if !exists, await askBeforeAddingToMusic(context: .createPlaylist, titles: [name]) != .add { return }
        }
        await perform(t("status_saving_to_apple_music", name), scope: .library) {
            if try AppleMusicScripting.playlistExists(named: name) {
                pendingSaveToAppleMusicConflict = SaveToAppleMusicConflict(name: name, tracks: tracks)
            } else {
                let added = try AppleMusicScripting.createPlaylist(named: name, tracks: tracks)
                status = savedToMusicStatus(name, added: added, expected: tracks.count)
                // Ricarica la libreria: cosi la playlist appena salvata compare subito nella
                // scheda Playlist di Apple Music, senza bisogno di un refresh manuale.
                await loadLibrary()
                syncCustomPlaylistReferences(afterSavingTo: name)
            }
        }
    }

    // MARK: - Custom Playlist su file (M3U8)

    /// Cartella dei file playlist: «Musica/MusicManager/Custom Lib» nella cartella dell'utente.
    static var customLibFolder: URL {
        (FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music"))
            .appendingPathComponent("MusicManager", isDirectory: true)
            .appendingPathComponent("Custom Lib", isDirectory: true)
    }

    /// Nome della playlist il cui file esiste già: in attesa di «Sostituisci» / «Annulla» (alert in `ContentView`).
    @Published var pendingFileOverwriteName: String?

    private func customPlaylistFileURL(_ name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return Self.customLibFolder.appendingPathComponent(safe + ".m3u8")
    }

    /// Salva la Custom Playlist (nell'ordine attuale) come file M3U8: un'intestazione e, per ogni brano, il
    /// percorso completo del file. Vale anche per i brani di librerie condivise (percorso sul volume montato).
    /// I brani senza file (solo cloud) non hanno percorso e restano fuori.
    func saveCustomPlaylistToFile(overwrite: Bool = false, thenClear: Bool = false) {
        let name = customPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            status = t("status_custom_playlist_name_required")
            return
        }
        let paths = customPlaylistEntries.compactMap { $0.track.url?.path }
        guard !paths.isEmpty else {
            status = t("status_playlist_empty", name)
            return
        }
        let file = customPlaylistFileURL(name)
        if !overwrite, FileManager.default.fileExists(atPath: file.path) {
            clearAfterFileSave = thenClear
            pendingFileOverwriteName = name
            return
        }
        do {
            try FileManager.default.createDirectory(at: Self.customLibFolder, withIntermediateDirectories: true)
            try ("#EXTM3U\n" + paths.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            let skipped = customPlaylistEntries.count - paths.count
            status = t("status_playlist_saved_file", name, paths.count)
                + (skipped > 0 ? " " + t("status_playlist_saved_file_skipped", skipped) : "")
            if thenClear { clearCustomPlaylist() }
        } catch {
            status = "⚠️ " + error.localizedDescription
        }
    }

    // MARK: Uscita dall'app con una Custom Playlist compilata

    /// Vero se la Custom Playlist contiene dei brani (alla chiusura dell'app si chiede se salvarla).
    var customPlaylistHasContent: Bool { !customPlaylistEntries.isEmpty }

    /// Vero se esiste già il file playlist con questo nome in Custom Lib.
    func customPlaylistFileExists(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: customPlaylistFileURL(name.trimmingCharacters(in: .whitespaces)).path)
    }

    /// Scrive subito il file M3U8 della Custom Playlist con questo nome (usato dalla domanda alla chiusura dell'app,
    /// dove non si può passare dagli alert di SwiftUI). Restituisce nil se è andato a buon fine, altrimenti il motivo.
    func saveCustomPlaylistFileNow(named rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return t("status_custom_playlist_name_required") }
        let paths = customPlaylistEntries.compactMap { $0.track.url?.path }
        guard !paths.isEmpty else { return t("status_playlist_empty", name) }
        do {
            try FileManager.default.createDirectory(at: Self.customLibFolder, withIntermediateDirectories: true)
            try ("#EXTM3U\n" + paths.joined(separator: "\n") + "\n")
                .write(to: customPlaylistFileURL(name), atomically: true, encoding: .utf8)
            customPlaylistName = name
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Dopo il salvataggio su file da «Svuota playlist → Salva su file»: svuotare la playlist una volta salvata.
    private var clearAfterFileSave = false

    func confirmFileOverwrite() {
        pendingFileOverwriteName = nil
        let thenClear = clearAfterFileSave
        clearAfterFileSave = false
        saveCustomPlaylistToFile(overwrite: true, thenClear: thenClear)
    }

    /// Annullando la sostituzione non si salva e, se si veniva da «Svuota playlist», non si svuota.
    func cancelFileOverwrite() {
        pendingFileOverwriteName = nil
        clearAfterFileSave = false
    }

    /// Sceglie un file M3U8/M3U (si apre nella cartella Custom Lib) e ne carica i brani nella Custom Playlist. Un
    /// brano già presente nella libreria in uso è quello della libreria; gli altri si leggono dal file (titolo,
    /// artista, album, durata). I file non raggiungibili (es. volume condiviso non montato) vengono saltati e
    /// contati nel messaggio finale. Se la Custom Playlist non è vuota si chiede prima se svuotarla.
    func loadCustomPlaylistFromFile() {
        try? FileManager.default.createDirectory(at: Self.customLibFolder, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["m3u8", "m3u"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.customLibFolder
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let name = file.deletingPathExtension().lastPathComponent
        let known = Dictionary((localTracks + tracks).compactMap { track in track.url.map { ($0.path, track) } },
                               uniquingKeysWith: { a, _ in a })
        Task {
            await self.perform(t("status_loading_playlist_file", name)) {
                let text = try String(contentsOf: file, encoding: .utf8)
                let folder = file.deletingLastPathComponent()
                let paths = text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                    .map { $0.hasPrefix("/") ? $0 : folder.appendingPathComponent($0).path }
                let result = await Task.detached(priority: .userInitiated) { () -> ([LocalTrack], Int) in
                    var found: [LocalTrack] = []
                    var missing = 0
                    for path in paths {
                        if let track = known[path] { found.append(track); continue }
                        guard FileManager.default.fileExists(atPath: path) else { missing += 1; continue }
                        found.append(await Self.trackFromFile(URL(fileURLWithPath: path)))
                    }
                    return (found, missing)
                }.value
                let (loaded, missing) = result
                if missing > 0 {
                    // Controllo all'apertura: i file non trovati si elencano nel registro (per esempio un volume non montato).
                    let gone = paths.filter { known[$0] == nil && !FileManager.default.fileExists(atPath: $0) }
                    AppLog.write("Playlist file «\(name)»: \(missing) of \(paths.count) files not found: " + gone.prefix(20).map { "«\($0)»" }.joined(separator: ", ") + (gone.count > 20 ? ", …" : ""))
                }
                guard !loaded.isEmpty else {
                    status = t("status_playlist_file_empty", name)
                    return
                }
                if customPlaylistEntries.isEmpty {
                    applyTracksToCustomPlaylist(loaded, originPlaylistTitle: name, renameToCopy: true, copySuffix: false)
                } else {
                    // Custom Playlist già con dei brani: si chiede come unire (alert in `ContentView`).
                    pendingFileLoad = PendingFileLoad(name: name, tracks: loaded)
                }
                appleCategory = .customPlaylist
                status = missing == 0
                    ? t("status_playlist_loaded_file", name, loaded.count)
                    : t("status_playlist_loaded_file_partial", name, loaded.count, loaded.count + missing)
            }
        }
    }

    /// Playlist caricata da file in attesa della scelta su come unirla ai brani già presenti nella Custom Playlist.
    struct PendingFileLoad {
        let name: String
        let tracks: [LocalTrack]
        /// Vero se viene da «Edit in Custom» di una playlist del dispositivo (cambiano solo i testi dell'alert).
        var fromDevice = false
    }
    @Published var pendingFileLoad: PendingFileLoad?

    enum FileLoadChoice {
        /// Sostituisce i brani attuali con quelli del file.
        case replace
        /// Prima la playlist salvata, poi i brani attualmente presenti.
        case currentAfterSaved
        /// Prima i brani attualmente presenti, poi la playlist salvata.
        case savedAfterCurrent
    }

    /// Applica la scelta dell'utente. In tutti i casi il nome della Custom Playlist diventa quello del file e
    /// l'ordinamento torna «Manuale». I brani del file già presenti nella Custom (stesso id o stesso file) o ripetuti nel file
    /// non si aggiungono subito: si chiede «Aggiungere comunque / Saltare» con lo stesso avviso degli altri duplicati
    /// (se si aggiungono, vanno in fondo). I brani già presenti prima del caricamento restano come sono.
    func resolveFileLoad(_ choice: FileLoadChoice) {
        guard let pending = pendingFileLoad else { return }
        pendingFileLoad = nil
        let current = choice == .replace ? [] : customPlaylistEntries
        var seen = Set<String>()
        for entry in current {
            seen.insert(entry.track.id)
            if let path = entry.track.url?.path { seen.insert(path) }
        }
        var fresh: [CustomPlaylistEntry<LocalTrack>] = []
        var duplicates: [LocalTrack] = []
        for track in pending.tracks {
            let path = track.url?.path
            if seen.contains(track.id) || (path.map { seen.contains($0) } ?? false) {
                duplicates.append(track)
                continue
            }
            seen.insert(track.id)
            if let path { seen.insert(path) }
            fresh.append(CustomPlaylistEntry(track: track))
        }
        switch choice {
        case .replace: customPlaylistEntries = fresh
        case .currentAfterSaved: customPlaylistEntries = fresh + current
        case .savedAfterCurrent: customPlaylistEntries = current + fresh
        }
        customPlaylistName = pending.name
        customPlaylistSortOption = .manual
        customPlaylistManualOrder = []
        if !duplicates.isEmpty { pendingCustomPlaylistDuplicates = duplicates }
    }

    func cancelFileLoad() { pendingFileLoad = nil }

    /// Costruisce un brano a partire dal solo file (titolo, artista, album e durata dai metadati incorporati).
    nonisolated private static func trackFromFile(_ url: URL) async -> LocalTrack {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        var album = ""
        var duration: TimeInterval = 0
        if let d = try? await asset.load(.duration), d.isNumeric { duration = d.seconds }
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey,
                      let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                switch key {
                case .commonKeyTitle: title = value
                case .commonKeyArtist: artist = value
                case .commonKeyAlbumName: album = value
                default: break
                }
            }
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        return LocalTrack(id: "file:" + url.path, title: title, artist: artist, album: album, url: url,
                          fileSize: size, isDRMProtected: false, isCloud: false, duration: duration, trackNumber: 0)
    }

    // MARK: Proposta di ricerca copertine per i brani delle librerie condivise

    /// Domanda in sospeso: brani senza copertina e azione da riprendere se si sceglie «Continua senza».
    struct ArtworkProposal {
        let missing: [LocalTrack]
        let proceed: () -> Void
    }
    enum ArtworkProposalAnswer { case search, continueAnyway, cancel }
    @Published var artworkProposal: ArtworkProposal?

    /// Brani in m4a/aac senza copertina, né propria né già confermata (sono i soli in cui l'app sa scrivere una copertina).
    /// Con `allTracks` falso (invii da selezione, «Invia alla Playlist») conta ogni brano (libreria locale, condivisa o su
    /// unità esterna: dal 2.2 anche la locale) e solo se l'impostazione di proposta è attiva; con `allTracks` vero (invio della Custom Playlist al
    /// Device) conta ogni brano, locale o condiviso, e basta che la ricerca online sia abilitata. «Senza copertina»
    /// vuol dire quella che verrebbe davvero scritta: propria, confermata, dell'album o della cache di Musica.
    private func missingArtwork(in items: [LocalTrack], allTracks: Bool) async -> [LocalTrack] {
        guard AppSettings.shared.lookupMissingArtworkOnline else { return [] }
        if !allTracks && !AppSettings.shared.proposeSharedArtworkSearch { return [] }
        var missing: [LocalTrack] = []
        for track in items {
            guard track.isTransferable, let ext = track.url?.pathExtension.lowercased(), ext == "m4a" || ext == "aac" else { continue }
            // Brani della libreria locale di Musica (non «ext:») senza copertina: controllati come nell'invio della Custom.
            if allTracks || !track.id.hasPrefix("ext:") {
                if await appleArtworkResolved(for: track).origin == .none { missing.append(track) }
            } else {
                let key = ArtworkCache.key(artist: track.artist, title: track.title, album: track.album)
                if ArtworkCache.confirmedImage(forKey: key) != nil { continue }
                if artworkOrigins[track.id] == .own { continue }   // già letta (es. caricata all'invio): niente seconda lettura
                if await originalArtwork(for: track) == nil { missing.append(track) }
            }
        }
        return missing
    }

    /// Vero se ha mostrato la domanda (l'azione riprende, se l'utente lo sceglie, con `proceed`).
    private func askArtworkSearchIfNeeded(for items: [LocalTrack], allTracks: Bool = false, proceed: @escaping () -> Void) async -> Bool {
        let missing = await missingArtwork(in: items, allTracks: allTracks)
        guard !missing.isEmpty else { return false }
        artworkProposal = ArtworkProposal(missing: missing, proceed: proceed)
        return true
    }

    /// «Cerca online» apre il pannello Artwork sui brani senza copertina; a pannello chiuso
    /// l'azione riprende da sola (`proceed`);
    /// «Continua senza» riprende l'azione così com'è; annullando non succede nulla.
    func answerArtworkProposal(_ answer: ArtworkProposalAnswer) {
        guard let proposal = artworkProposal else { return }
        artworkProposal = nil
        switch answer {
        case .search: startFixArtwork(for: proposal.missing, then: proposal.proceed)
        case .continueAnyway: proposal.proceed()
        case .cancel: break
        }
    }

    /// Messaggio dopo il salvataggio in Musica: segnala se qualche brano non è stato aggiunto.
    private func savedToMusicStatus(_ name: String, added: Int, expected: Int) -> String {
        added >= expected
            ? t("status_saved_to_apple_music", name)
            : "⚠️ " + t("status_saved_to_apple_music_partial", name, added, expected)
    }

    /// L'utente ha scelto "Sostituisci": elimina del tutto la playlist esistente e la ricrea da
    /// zero con il contenuto attuale della Custom Playlist.
    func confirmReplaceAppleMusicPlaylist() {
        guard let conflict = pendingSaveToAppleMusicConflict else { return }
        pendingSaveToAppleMusicConflict = nil
        Task {
            await perform(t("status_saving_to_apple_music", conflict.name), scope: .library) {
                try AppleMusicScripting.deletePlaylist(named: conflict.name)
                let added = try AppleMusicScripting.createPlaylist(named: conflict.name, tracks: conflict.tracks)
                status = savedToMusicStatus(conflict.name, added: added, expected: conflict.tracks.count)
                await loadLibrary()
                syncCustomPlaylistReferences(afterSavingTo: conflict.name)
            }
        }
    }

    /// L'utente ha scelto "Aggiungi" (non sostituire): controlla quali brani sono già nella
    /// playlist esistente, per chiedere conferma solo su quelli, mostrandoli per nome (vedi
    /// `pendingSaveToAppleMusicDuplicates`). Se nessuno risulta già presente, aggiunge
    /// direttamente senza chiedere altro.
    func confirmAddToExistingAppleMusicPlaylist() {
        guard let conflict = pendingSaveToAppleMusicConflict else { return }
        pendingSaveToAppleMusicConflict = nil
        Task {
            await perform(t("status_saving_to_apple_music", conflict.name), scope: .library) {
                let existingPaths = Set(((try? AppleMusicScripting.existingTrackPaths(inPlaylistNamed: conflict.name)) ?? [])
                    .map { $0.lowercased() })
                var fresh: [LocalTrack] = []
                var duplicates: [LocalTrack] = []
                for track in conflict.tracks {
                    if let path = track.url?.path, existingPaths.contains(path.lowercased()) {
                        duplicates.append(track)
                    } else {
                        fresh.append(track)
                    }
                }
                if !duplicates.isEmpty {
                    pendingSaveToAppleMusicDuplicates = SaveToAppleMusicDuplicates(
                        name: conflict.name, freshTracks: fresh, duplicateTracks: duplicates)
                } else {
                    let added = try AppleMusicScripting.addTracks(fresh, toPlaylistNamed: conflict.name)
                    status = savedToMusicStatus(conflict.name, added: added, expected: fresh.count)
                    await loadLibrary()
                    syncCustomPlaylistReferences(afterSavingTo: conflict.name)
                    offerToLoadFullAppleMusicPlaylistIntoCustom(named: conflict.name)
                }
            }
        }
    }

    /// Annulla la richiesta "Sostituisci"/"Aggiungi": non fa nulla sulla playlist esistente.
    func cancelSaveToAppleMusicConflict() {
        pendingSaveToAppleMusicConflict = nil
    }

    /// L'utente ha confermato di voler aggiungere comunque anche i brani già presenti: aggiunge
    /// tutti i brani scelti, duplicati compresi (Musica stessa permette lo stesso brano più volte
    /// nella stessa playlist).
    func confirmAddAppleMusicDuplicatesAnyway() {
        guard let pending = pendingSaveToAppleMusicDuplicates else { return }
        pendingSaveToAppleMusicDuplicates = nil
        Task {
            await perform(t("status_saving_to_apple_music", pending.name), scope: .library) {
                let added = try AppleMusicScripting.addTracks(pending.allTracks, toPlaylistNamed: pending.name)
                status = savedToMusicStatus(pending.name, added: added, expected: pending.allTracks.count)
                await loadLibrary()
                syncCustomPlaylistReferences(afterSavingTo: pending.name)
                offerToLoadFullAppleMusicPlaylistIntoCustom(named: pending.name)
            }
        }
    }

    /// L'utente ha scelto di saltare i duplicati: aggiunge solo i brani non già presenti.
    func skipAppleMusicDuplicatesAndAddFresh() {
        guard let pending = pendingSaveToAppleMusicDuplicates else { return }
        pendingSaveToAppleMusicDuplicates = nil
        guard !pending.freshTracks.isEmpty else { return }
        Task {
            await perform(t("status_saving_to_apple_music", pending.name), scope: .library) {
                let added = try AppleMusicScripting.addTracks(pending.freshTracks, toPlaylistNamed: pending.name)
                status = savedToMusicStatus(pending.name, added: added, expected: pending.freshTracks.count)
                await loadLibrary()
                syncCustomPlaylistReferences(afterSavingTo: pending.name)
                offerToLoadFullAppleMusicPlaylistIntoCustom(named: pending.name)
            }
        }
    }

    /// Annulla la richiesta di conferma sui duplicati: non aggiunge nessun brano.
    func cancelAppleMusicDuplicates() {
        pendingSaveToAppleMusicDuplicates = nil
    }

    /// Estrae l'ID reale della playlist Apple Music dall'identificativo usato per la riga nel
    /// CatalogBrowser (con prefisso "playlist:", vedi `loadLibrary`).
    private static func rawPlaylistID(from groupID: String) -> String? {
        let prefix = "playlist:"
        guard groupID.hasPrefix(prefix) else { return nil }
        return String(groupID.dropFirst(prefix.count))
    }

    /// Estrae l'ID oggetto MTP del file playlist dall'identificativo usato per la riga nel
    /// CatalogBrowser lato dispositivo (con prefisso "devplaylist:", vedi `reloadDeviceCatalog`).
    private static func rawDevicePlaylistFileID(from groupID: String) -> UInt32? {
        let prefix = "devplaylist:"
        guard groupID.hasPrefix(prefix) else { return nil }
        return UInt32(groupID.dropFirst(prefix.count))
    }

    private static func sanitizedFilename(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = s.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? t("default_playlist_name") : cleaned
    }
}

// MARK: - Cartella di lavoro locale

extension AppViewModel {
    /// Radice dei file di lavoro: `~/Music/MusicManager` (contiene `TEMP` per i file preparati prima
    /// dell'invio e `Custom Lib` per le playlist salvate su file).
    static var localExportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("MusicManager", isDirectory: true)
    }
}


/// Da dove nasce la richiesta di aggiungere brani a Music.
enum MusicAddContext { case dropped, customPlaylist, createPlaylist }
/// Scelte dell'alert: aggiungere, procedere senza aggiungere («solo orologio» o «salva senza»), annullare.
enum MusicAddAnswer { case add, skip, cancel }


extension LocalTrack {
    /// Brano che non è nella libreria di Music: di una libreria esterna («ext:») o letto da un file `.m3u8` («file:»).
    var isOutsideMusicLibrary: Bool { id.hasPrefix("ext:") || id.hasPrefix("file:") }
}
