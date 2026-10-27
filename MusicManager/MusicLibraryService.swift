import Foundation
import AppKit
import AVFoundation
import iTunesLibrary

struct LocalTrack: Identifiable, Hashable, Sendable, Codable {
    /// Formati che l'app sa preparare per il Garmin.
    static let appExtensions: Set<String> = ["mp3", "m4a", "aac"]
    /// Formati dichiarati dal dispositivo collegato in `GarminDevice.xml` (nil = sconosciuti o nessun
    /// dispositivo). Si imposta solo dal Main Actor, alla connessione.
    nonisolated(unsafe) static var deviceExtensions: Set<String>?
    /// Formati davvero inviabili: quelli dell'app che il dispositivo dichiara di accettare.
    static var supportedExtensions: Set<String> {
        guard let deviceExtensions else { return appExtensions }
        return appExtensions.intersection(deviceExtensions)
    }

    let id: String
    let title: String
    let artist: String
    let album: String
    var url: URL?
    let fileSize: Int
    let isDRMProtected: Bool
    let isCloud: Bool
    /// Acquistato su iTunes Store (opzionale per leggere senza problemi le cache salvate prima). Può avere o
    /// no il DRM: se è ancora protetto è già bloccato (`isDRMProtected`); gli altri si segnalano con
    /// un'icona perché la riproduzione sul Garmin non è garantita.
    var isPurchasedStored: Bool?
    var isPurchased: Bool { isPurchasedStored ?? false }
    /// Apple Lossless (ALAC, in .m4a): nel catalogo compare come «Hi-Res» e, come i brani solo cloud, non si
    /// invia né all'orologio né alla Custom Playlist (opzionale per leggere senza problemi le cache vecchie).
    var isLosslessStored: Bool?
    var isLossless: Bool { isLosslessStored ?? false }

    /// Formati senza perdita che l'app mostra ma non invia: il nome del formato è l'etichetta di blocco a destra della riga.
    nonisolated static let losslessLabels: Set<String> = ["ALAC", "FLAC", "WAV", "AIFF"]
    /// Estensioni senza perdita da indicizzare nelle unità esterne (oltre ai formati del dispositivo), per mostrarle bloccate.
    nonisolated static let losslessExtensions: Set<String> = ["flac", "wav", "aif", "aiff"]
    /// Nome del formato di un brano senza perdita: dall'estensione del file; per gli altri (m4a o file non noto) è ALAC.
    var losslessLabel: String {
        switch url?.pathExtension.lowercased() ?? "" {
        case "flac": return "FLAC"
        case "wav": return "WAV"
        case "aif", "aiff": return "AIFF"
        default: return "ALAC"
        }
    }

    /// Riconosce l'Apple Lossless dal tipo di file di Musica («Apple Lossless audio file», in italiano «File audio
    /// Apple Lossless») oppure, se il tipo manca, dal bitrate: AAC e MP3 non superano i 320 kbps, un ALAC sta in
    /// genere oltre i 600.
    static func looksLossless(kind: String, bitRateKbps: Int) -> Bool {
        let k = kind.lowercased()
        if k.contains("lossless") || k.contains("alac") { return true }
        return bitRateKbps > 400
    }
    /// Durata in secondi, 0 se sconosciuta.
    let duration: TimeInterval
    /// Numero di traccia nell'album (0 se sconosciuto). Usato solo per ordinare la Custom
    /// Playlist per Album mantenendo l'ordine corretto dei brani dello stesso album.
    let trackNumber: Int
    /// Artista dell'album (vuoto se Musica non lo indica) e tag "Compilation" dell'album.
    var albumArtist: String
    var isCompilation: Bool
    /// Numero del disco (0 se sconosciuto): per ordinare gli album in più dischi.
    var discNumber: Int
    /// Numero di dischi dell'album secondo Musica (0 se sconosciuto).
    var discCount: Int
    /// Genere musicale come lo scrive Musica (opzionale: le copie salvate prima non lo hanno).
    var genreStored: String?
    var genre: String { genreStored ?? "" }
    /// Anno e battiti al minuto come li scrive Musica (opzionali: le copie salvate prima non li hanno; 0 = sconosciuto).
    /// Servono a «Trova simili».
    var yearStored: Int?
    var bpmStored: Int?
    var year: Int { yearStored ?? 0 }
    var bpm: Int { bpmStored ?? 0 }
    /// Numero di riproduzioni registrato da Musica (nil = dato non disponibile: copie salvate prima). Serve a «Trova simili»
    /// per ordinare a parità di punteggio (prima i meno ascoltati).
    var playCountStored: Int?
    var playCount: Int { playCountStored ?? 0 }
    /// Non-nil per un brano presente solo sul dispositivo (importato da una playlist del device): percorso relativo alla
    /// cartella Music (Artista/Album/file). Non ha file locale (`url` nil) e non va copiato: si inserisce solo nella playlist.
    var devicePath: String?
    var isDeviceOnly: Bool { devicePath != nil }

    /// Costruttore esplicito (non quello automatico): con il parametro in più il linker non
    /// trovava il simbolo del costruttore automatico chiamato da un altro file.
    init(id: String, title: String, artist: String, album: String, url: URL?, fileSize: Int,
         isDRMProtected: Bool, isCloud: Bool, duration: TimeInterval, trackNumber: Int,
         albumArtist: String = "", isCompilation: Bool = false,
         discNumber: Int = 0, discCount: Int = 0, isPurchased: Bool = false, isLossless: Bool = false,
         genre: String = "", year: Int = 0, bpm: Int = 0, playCount: Int = -1) {
        self.genreStored = genre.isEmpty ? nil : genre
        self.yearStored = year > 0 ? year : nil
        self.bpmStored = bpm > 0 ? bpm : nil
        self.playCountStored = playCount >= 0 ? playCount : nil
        self.isPurchasedStored = isPurchased
        self.isLosslessStored = isLossless
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.url = url
        self.fileSize = fileSize
        self.isDRMProtected = isDRMProtected
        self.isCloud = isCloud
        self.duration = duration
        self.trackNumber = trackNumber
        self.albumArtist = albumArtist
        self.isCompilation = isCompilation
        self.discNumber = discNumber
        self.discCount = discCount
    }

    /// Motivo per cui il brano non si può copiare sull'orologio (nil se trasferibile).
    var blockedReason: String? {
        if devicePath != nil { return nil }   // già sul dispositivo: niente da trasferire
        if isDRMProtected { return t("reason_drm") }
        if isCloud { return t("reason_cloud_only") }
        if isLossless { return losslessLabel }
        guard let url else { return t("reason_file_unavailable") }
        if !Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
            return t("reason_unsupported_format", url.pathExtension)
        }
        return nil
    }

    var isTransferable: Bool { blockedReason == nil }
}

/// Tipo di una playlist di Musica: normale, smart (regole automatiche) o Genius.
enum PlaylistKind: String, Sendable, Codable {
    case regular, smart, genius
}

struct PlaylistInfo: Sendable, Codable {
    let id: String
    let name: String
    let trackIDs: [String]
    /// Opzionale: le copie salvate prima che esistesse non lo hanno (valgono come playlist normali).
    var kind: PlaylistKind? = nil
}

struct LibraryCatalog: Sendable {
    let tracks: [LocalTrack]
    let playlists: [PlaylistInfo]
}

/// Legge la libreria dell'app Musica tramite il framework iTunesLibrary.
///
/// Tiene in cache gli oggetti `ITLibMediaItem` dopo il caricamento: servono per recuperare l'artwork
/// su richiesta (una copertina per volta, quando una riga diventa visibile) senza rileggere tutta la
/// libreria. Gli oggetti iTunesLibrary non sono Sendable e restano chiusi qui dentro: si toccano **solo**
/// su una coda seriale dedicata (`queue`), mai sul thread principale. Con Musica aperta e librerie grandi
/// ogni accesso a iTunesLibrary può richiedere molto tempo e sul thread principale bloccherebbe l'app
/// (cursore di attesa, «non risponde»).
final class MusicLibraryService: @unchecked Sendable {
    private var itemsByID: [String: ITLibMediaItem] = [:]
    private let queue = DispatchQueue(label: "MusicManager.iTunesLibrary", qos: .userInitiated)

    /// Esegue il lavoro sulla coda seriale di iTunesLibrary, senza bloccare il chiamante.
    ///
    /// Con Musica **chiusa** iTunesLibrary non deve contattarla (legge il database su disco) ed è veloce,
    /// ma ha bisogno del thread principale (run loop): su una coda GCD semplice la libreria non si
    /// caricava. In quel caso il lavoro gira quindi sul main thread, come prima del refactor. Con Musica
    /// **aperta** (lenta con librerie grandi) si usa la coda in background per non bloccare l'interfaccia.
    /// Un lock protegge `itemsByID`, perché i due percorsi possono alternarsi.
    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let useMain = !AppleMusicScripting.isMusicRunning
        return try await withCheckedThrowingContinuation { cont in
            let target = useMain ? DispatchQueue.main : queue
            target.async { cont.resume(with: Result { try work() }) }
        }
    }

    private let itemsLock = NSLock()
    private func setItems(_ items: [String: ITLibMediaItem]) { itemsLock.lock(); itemsByID = items; itemsLock.unlock() }
    private func item(_ id: String) -> ITLibMediaItem? { itemsLock.lock(); defer { itemsLock.unlock() }; return itemsByID[id] }

    func loadCatalog() async throws -> LibraryCatalog {
        try await onQueue { try self.loadCatalogSync() }
    }

    private func loadCatalogSync() throws -> LibraryCatalog {
        let library = try ITLibrary(apiVersion: "1.1")
        let songItems = library.allMediaItems.filter { $0.mediaKind == .kindSong }

        setItems(Dictionary(uniqueKeysWithValues: songItems.map { ($0.persistentID.stringValue, $0) }))

        // Ogni brano richiede una risposta sincrona del servizio di Musica (`item.location`): con un servizio lento (anche 40 ms a
        // richiesta) 1000 brani in fila durano quasi un minuto. Le richieste si fanno quindi in parallelo, a gruppi, mantenendo
        // l'ordine originale. `parallelRead = false` torna alla lettura in fila.
        // 2.2: i percorsi trovati alla lettura precedente si riusano senza interrogare il servizio di Musica (basta
        // controllare che il file esista ancora); solo per gli altri brani si chiede `item.location`.
        let pathCache = PathCache.load()
        let readStart = Date()
        let tracks = Self.makeTracks(from: songItems, pathCache: pathCache).sortedForLibrary()
        var freshPaths: [String: String] = [:]
        for track in tracks { if let path = track.url?.path { freshPaths[track.id] = path } }
        if freshPaths != pathCache { PathCache.save(freshPaths) }
        if AppLog.detailed {
            let noPath = tracks.filter { $0.url == nil }.count
            let hits = tracks.filter { pathCache[$0.id] != nil && $0.url?.path == pathCache[$0.id] }.count
            AppLog.debug("Libreria: \(tracks.count) brani letti in \(String(format: "%.1f", Date().timeIntervalSince(readStart))) s (\(Self.parallelRead ? "thread: \(Self.readThreads)" : "in fila")); percorsi dalla copia salvata: \(hits); senza percorso: \(noPath)")
        }

        // Solo playlist create dall'utente: esclude libreria principale, cartelle e
        // playlist di sistema (distinguishedKind diverso da "none", cioè rawValue != 0).
        let playlists: [PlaylistInfo] = library.allPlaylists
            .filter { !$0.isMaster && $0.distinguishedKind.rawValue == 0 && $0.kind != .folder }
            .map { pl in
                PlaylistInfo(
                    id: pl.persistentID.stringValue,
                    name: pl.name,
                    trackIDs: pl.items.filter { $0.mediaKind == .kindSong }.map { $0.persistentID.stringValue },
                    kind: pl.kind == .smart ? .smart : ((pl.kind == .genius || pl.kind == .geniusMix) ? .genius : .regular)
                )
            }
            .filter { !$0.trackIDs.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return LibraryCatalog(tracks: tracks, playlists: playlists)
    }

    /// Rilegge una playlist direttamente da iTunesLibrary al momento dell'invio, invece di usare
    /// l'istantanea caricata l'ultima volta in questa app: cosi il file generato riflette sempre
    /// il contenuto attuale della playlist in Musica, anche se nel frattempo è stata modificata
    /// (brani aggiunti o rimossi). Restituisce nil se la playlist non esiste più (rinominata
    /// tramite un ID diverso, non è questo il caso, oppure eliminata).
    func currentPlaylistTracks(playlistID: String) async throws -> (name: String, tracks: [LocalTrack])? {
        try await onQueue { try self.currentPlaylistTracksSync(playlistID: playlistID) }
    }

    private func currentPlaylistTracksSync(playlistID: String) throws -> (name: String, tracks: [LocalTrack])? {
        let freshLibrary = try ITLibrary(apiVersion: "1.1")
        guard let playlist = freshLibrary.allPlaylists.first(where: { $0.persistentID.stringValue == playlistID }) else {
            return nil
        }
        let items = playlist.items.filter { $0.mediaKind == .kindSong }
        itemsLock.lock()
        for item in items { itemsByID[item.persistentID.stringValue] = item }   // aggiorna cache artwork
        itemsLock.unlock()
        return (playlist.name, items.map { Self.makeTrack(from: $0) })
    }

    /// Brano acquistato su iTunes Store: dalla proprietà `isPurchased` di iTunesLibrary se esiste, altrimenti
    /// dalla descrizione del tipo di file («Purchased AAC audio file» / «File audio AAC acquistato»).
    private static func purchasedFlag(_ item: ITLibMediaItem) -> Bool {
        if item.responds(to: NSSelectorFromString("isPurchased")),
           let value = item.value(forKey: "purchased") as? Bool, value { return true }
        let kind = (item.kind ?? "").lowercased()
        return kind.contains("purchased") || kind.contains("acquistat")
    }

    /// Lettura dei brani in parallelo (vedi `loadCatalogSync`). Mettere `false` per tornare alla lettura in fila.
    private static let parallelRead = true

    /// Risultati scritti da più thread, ognuno nella propria posizione: il lucchetto protegge l'array.
    private final class TrackSlots: @unchecked Sendable {
        private var slots: [LocalTrack?]
        private let lock = NSLock()
        init(count: Int) { slots = Array(repeating: nil, count: count) }
        func set(_ track: LocalTrack, at index: Int) { lock.lock(); slots[index] = track; lock.unlock() }
        var all: [LocalTrack] { lock.lock(); defer { lock.unlock() }; return slots.compactMap { $0 } }
    }

    /// Contatore condiviso tra i lavoratori: restituisce 0, 1, 2... finché non si raggiunge il limite.
    private final class NextIndex: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func take(limit: Int) -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard value < limit else { return nil }
            defer { value += 1 }
            return value
        }
    }

    /// Thread per la lettura: 1 se l'utente ha scelto «Single thread», altrimenti 8.
    private static var readThreads: Int {
        UserDefaults.standard.integer(forKey: AppSettings.libraryReadThreadsKey) == 1 ? 1 : 8
    }

    private static func makeTracks(from items: [ITLibMediaItem], pathCache: [String: String] = [:]) -> [LocalTrack] {
        guard parallelRead, items.count > 16 else { return items.map { makeTrack(from: $0, pathCache: pathCache) } }
        let result = TrackSlots(count: items.count)
        // Opzione «Thread per leggere la libreria» (Impostazioni ▸ Avanzate): «Single thread» = 1 lavoratore (una richiesta alla
        // volta); altrimenti «Multi thread» = 8 lavoratori che prelevano il brano successivo da un contatore comune.
        let threads = Self.readThreads
        let next = NextIndex()
        DispatchQueue.concurrentPerform(iterations: min(threads, items.count)) { _ in
            while let index = next.take(limit: items.count) {
                result.set(makeTrack(from: items[index], pathCache: pathCache), at: index)
            }
        }
        return result.all
    }

    /// Copia dei percorsi dei file (ID del brano → percorso) letti da Musica, salvata in Application Support. Evita la
    /// richiesta `item.location` (una per brano, sincrona verso il servizio di Musica) all'avvio successivo. Se il file non
    /// esiste più la voce non vale e si torna a chiedere a Musica.
    private enum PathCache {
        static var file: URL {
            AppFolders.base.appendingPathComponent("Library", isDirectory: true).appendingPathComponent("paths-v1.json")
        }
        static func load() -> [String: String] {
            guard let data = try? Data(contentsOf: file),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return dict
        }
        static func save(_ dict: [String: String]) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(dict) { try? data.write(to: file, options: .atomic) }
        }
    }

    private static func makeTrack(from item: ITLibMediaItem) -> LocalTrack { makeTrack(from: item, pathCache: [:]) }

    private static func makeTrack(from item: ITLibMediaItem, pathCache: [String: String]) -> LocalTrack {
        let trackID = item.persistentID.stringValue
        let location: URL?
        if let cached = pathCache[trackID], FileManager.default.fileExists(atPath: cached) {
            location = URL(fileURLWithPath: cached)
        } else {
            location = item.location
        }
        return LocalTrack(
            id: trackID,
            title: item.title,
            artist: item.artist?.name ?? t("unknown_artist"),
            album: item.album.title ?? "",
            url: location,
            fileSize: Int(item.fileSize),
            isDRMProtected: item.isDRMProtected,
            isCloud: item.isCloud,
            duration: TimeInterval(item.totalTime) / 1000.0,
            trackNumber: item.trackNumber,
            albumArtist: item.album.albumArtist ?? "",
            isCompilation: item.album.isCompilation,
            discNumber: item.album.discNumber,
            discCount: item.album.discCount,
            isPurchased: purchasedFlag(item),
            isLossless: LocalTrack.looksLossless(kind: item.kind ?? "", bitRateKbps: Int(item.bitrate)),
            genre: item.genre,
            year: item.year,
            bpm: item.beatsPerMinute,
            playCount: item.playCount
        )
    }

    /// Copertina già in cache in iTunesLibrary per un brano, come dati PNG. Nil se Musica non ne
    /// ha una salvata localmente per quel brano: capita spesso per file importati manualmente,
    /// anche se il file stesso contiene una copertina incorporata (vedi `embeddedArtwork`).
    func cachedArtwork(for trackID: String) async -> Data? {
        (try? await onQueue { self.cachedArtworkSync(trackID) }) ?? nil
    }

    private func cachedArtworkSync(_ trackID: String) -> Data? {
        guard let image = item(trackID)?.artwork?.image else { return nil }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Legge la copertina incorporata direttamente nel file audio (tag ID3 per mp3, atom "covr"
    /// per m4a/aac), senza passare dalla cache di iTunesLibrary. Funzione statica e non isolata
    /// al Main Actor apposta, cosi la lettura del file può girare su un thread in background senza
    /// bloccare l'interfaccia mentre si scorre l'elenco. Usa le API asincrone `load(_:)` di
    /// AVFoundation (le controparti sincrone `commonMetadata`/`dataValue` sono deprecate da
    /// macOS 13).
    nonisolated static func embeddedArtwork(at url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyArtwork {
            // do/catch invece di "try? + if let": `load(.dataValue)` restituisce `Data` non
            // opzionale (il type-checker lo confermava con un errore sul binding condizionale),
            // quindi è il caso di errore — non un valore nil — a significare "nessun dato qui".
            do {
                return try await item.load(.dataValue)
            } catch {
                continue
            }
        }
        return nil
    }
}

// MARK: - Libreria da file XML (cartella condivisa montata)

/// Contenuto dell'XML già letto: i percorsi dei file sono ancora quelli del computer sorgente. Si legge l'XML una
/// sola volta (può essere molto grande) e poi si associa alla cartella montata con `catalog(mediaFolder:)`.
struct ExternalParsed: Sendable, Codable {
    struct Entry: Sendable, Codable {
        let track: LocalTrack
        /// Percorso del file sul computer sorgente (nil se il brano non ha un file, es. solo cloud).
        let path: String?
    }
    let sourceFolder: String
    let entries: [Entry]
    let playlists: [PlaylistInfo]

    /// Bit rate in kbps da un valore dell'XML. Music scrive i kbps (es. 256); alcuni strumenti di terze parti scrivono i bit al
    /// secondo (es. 256000), che altrimenti farebbe passare ogni brano per Lossless («Hi-Res», non trasferibile).
    nonisolated static func kbps(_ value: Any?) -> Int {
        let raw = (value as? Int) ?? Int((value as? Double) ?? 0)
        return raw >= 8000 ? raw / 1000 : raw
    }

    /// Percorso relativo di un brano rispetto al «Music Folder» del sorgente.
    nonisolated func relativePath(of entry: Entry) -> String? {
        guard let p = entry.path, !sourceFolder.isEmpty, p.hasPrefix(sourceFolder) else { return nil }
        return String(p.dropFirst(sourceFolder.count))
    }

    /// Cartelle candidate dei file audio, vicino all'XML (la cartella «Media» è accanto al file della libreria).
    nonisolated static func candidateMediaFolders(xml: URL) -> [URL] {
        let dir = xml.deletingLastPathComponent()
        return [dir.appendingPathComponent("Media"),
                dir.appendingPathComponent("Media.localized"),
                dir.appendingPathComponent("iTunes Media"),
                dir.deletingLastPathComponent().appendingPathComponent("Media"),
                dir]
    }

    /// Vero se in questa cartella si trovano i file dei primi brani.
    nonisolated func matches(mediaFolder: URL) -> Bool {
        var checked = 0
        for e in entries {
            guard let rel = relativePath(of: e) else { continue }
            if FileManager.default.fileExists(atPath: mediaFolder.appendingPathComponent(rel).path) { return true }
            checked += 1
            if checked >= 15 { break }
        }
        return false
    }

    /// Brani e playlist con gli URL dei file riportati sulla cartella montata. Con `verify` si controlla che ogni
    /// file esista (lento su una condivisione di rete): quelli mancanti restano senza file.
    nonisolated func catalog(mediaFolder: URL, verify: Bool = false) -> LibraryCatalog {
        var tracks: [LocalTrack] = []
        tracks.reserveCapacity(entries.count)
        // Percorso base come testo e URL creati con isDirectory esplicito: `appendingPathComponent(_:)` senza
        // `isDirectory` interroga il file system per ogni brano (su una condivisione di rete = una richiesta di rete
        // a brano, minuti di attesa).
        let base = mediaFolder.path.hasSuffix("/") ? mediaFolder.path : mediaFolder.path + "/"
        for e in entries {
            var track = e.track
            var shown = e.path ?? ""
            if let rel = relativePath(of: e) {
                shown = base + rel
                let u = URL(fileURLWithPath: shown, isDirectory: false)
                if !verify || FileManager.default.fileExists(atPath: shown) { track.url = u }
            }
            tracks.append(track)
        }
        return LibraryCatalog(tracks: tracks.sortedForLibrary(), playlists: playlists)
    }

    // MARK: Cache

    /// Copia compatta dell'XML già letto (in Application Support): finché il file XML non cambia (stessa
    /// dimensione e data di modifica) le aperture successive la rileggono in un attimo invece di rifare la
    /// lettura completa, che per un XML da decine di MB richiede molto.
    private struct CacheFile: Codable {
        let size: Int
        let modified: Double
        let parsed: ExternalParsed
    }

    nonisolated private static func cacheURL(for xml: URL) -> URL? {
        // Hash stabile del percorso (hashValue cambia a ogni avvio).
        var h: UInt64 = 5381
        for b in xml.path.utf8 { h = (h &* 33) &+ UInt64(b) }
        return AppFolders.externalLibrary.appendingPathComponent("external-library-v4-\(String(h, radix: 16)).json")
    }

    /// Cancella la copia compatta di una libreria esterna (quando la si toglie dalle Impostazioni).
    nonisolated static func removeCache(forXMLPath path: String) {
        guard !path.isEmpty, let cache = cacheURL(for: URL(fileURLWithPath: path)) else { return }
        try? FileManager.default.removeItem(at: cache)
    }

    nonisolated private static func signature(of xml: URL) -> (size: Int, modified: Double)? {
        guard let v = try? xml.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize, let date = v.contentModificationDate else { return nil }
        return (size, date.timeIntervalSince1970)
    }

    /// La copia compatta salvata in precedenza, senza controllare se l'XML è cambiato (e senza nemmeno aprirlo:
    /// l'XML può trovarsi su un volume non montato). Nil se non esiste ancora.
    nonisolated static func readCachedOnly(xml: URL) -> ExternalParsed? { readCachedOnlyWithSignature(xml: xml)?.parsed }

    /// Come `readCachedOnly`, ma restituisce anche dimensione e data dell'XML al momento in cui la copia è stata salvata
    /// (per accorgersi, dopo l'apertura, che l'XML sul server è cambiato).
    nonisolated static func readCachedOnlyWithSignature(xml: URL) -> (parsed: ExternalParsed, size: Int, modified: Double)? {
        guard let cache = cacheURL(for: xml), let data = try? Data(contentsOf: cache),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data) else { return nil }
        return (file.parsed, file.size, file.modified)
    }

    /// Dimensione e data attuali dell'XML (nil se non si raggiunge: volume non montato, file assente).
    nonisolated static func currentSignature(of xml: URL) -> (size: Int, modified: Double)? { signature(of: xml) }

    /// La copia compatta, solo se è ancora valida per l'XML attuale (stessa dimensione e data). Nil altrimenti.
    nonisolated static func readValidCache(xml: URL) -> ExternalParsed? {
        guard let sig = signature(of: xml), let cache = cacheURL(for: xml), let data = try? Data(contentsOf: cache),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.size == sig.size, file.modified == sig.modified else { return nil }
        return file.parsed
    }

    /// Dimensione dell'XML (per l'avanzamento della copia).
    nonisolated static func fileSize(of xml: URL) -> Int64 { Int64(signature(of: xml)?.size ?? 0) }

    /// Legge da una copia locale dell'XML e salva la copia compatta con la firma (dimensione e data) dell'XML ORIGINALE.
    nonisolated static func read(localCopy: URL, original xml: URL) throws -> ExternalParsed {
        let sig = signature(of: xml)
        let parsed = try read(xml: localCopy)
        if let sig, let cache = cacheURL(for: xml) {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(CacheFile(size: sig.size, modified: sig.modified, parsed: parsed)) {
                try? data.write(to: cache, options: .atomic)
            }
        }
        return parsed
    }

    /// Come `read`, ma usa e aggiorna la cache. `fromCache` dice se è stata usata.
    nonisolated static func readUsingCache(xml: URL) throws -> (parsed: ExternalParsed, fromCache: Bool) {
        let sig = signature(of: xml)
        let cache = cacheURL(for: xml)
        if let sig, let cache, let data = try? Data(contentsOf: cache),
           let file = try? JSONDecoder().decode(CacheFile.self, from: data),
           file.size == sig.size, file.modified == sig.modified {
            return (file.parsed, true)
        }
        let parsed = try read(xml: xml)
        if let sig, let cache {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(CacheFile(size: sig.size, modified: sig.modified, parsed: parsed)) {
                try? data.write(to: cache, options: .atomic)
            }
        }
        return (parsed, false)
    }

    enum LoadError: LocalizedError {
        case unreadable
        var errorDescription: String? { t("external_err_unreadable") }
    }

    /// Legge l'XML (plist) di Musica/iTunes: brani (`Tracks`) e playlist (`Playlists`, senza Master, cartelle e
    /// playlist di sistema).
    nonisolated static func read(xml: URL, idPrefix: String = "ext:") throws -> ExternalParsed {
        guard let data = try? Data(contentsOf: xml, options: .mappedIfSafe),
              let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let tracksDict = root["Tracks"] as? [String: Any] else { throw LoadError.unreadable }
        var sourceFolder = ""
        if let s = root["Music Folder"] as? String, let u = URL(string: s) {
            sourceFolder = u.path.hasSuffix("/") ? u.path : u.path + "/"
        }

        var entries: [Entry] = []
        var idByTrackID: [Int: String] = [:]
        for (_, value) in tracksDict {
            guard let d = value as? [String: Any], let trackID = d["Track ID"] as? Int else { continue }
            // Solo musica: video, film, serie TV e podcast restano fuori.
            if (d["Has Video"] as? Bool) == true || (d["Movie"] as? Bool) == true
                || (d["TV Show"] as? Bool) == true || (d["Podcast"] as? Bool) == true { continue }

            var path: String?
            if let loc = d["Location"] as? String, let u = URL(string: loc) { path = u.path }
            let id = idPrefix + ((d["Persistent ID"] as? String) ?? String(trackID))
            idByTrackID[trackID] = id
            let artist = (d["Artist"] as? String) ?? ""
            // Tipo di file («Purchased AAC audio file», «Protected AAC audio file»…) come ripiego per i flag.
            let kind = ((d["Kind"] as? String) ?? "").lowercased()
            let isProtected = (d["Protected"] as? Bool) == true || kind.contains("protected") || kind.contains("protett")
            let isPurchased = (d["Purchased"] as? Bool) == true || kind.contains("purchased") || kind.contains("acquistat")
            let track = LocalTrack(
                id: id,
                title: (d["Name"] as? String) ?? "",
                artist: artist.isEmpty ? t("unknown_artist") : artist,
                album: (d["Album"] as? String) ?? "",
                url: nil,
                fileSize: (d["Size"] as? Int) ?? 0,
                isDRMProtected: isProtected,
                isCloud: d["Location"] == nil,
                duration: TimeInterval((d["Total Time"] as? Int) ?? 0) / 1000.0,
                trackNumber: (d["Track Number"] as? Int) ?? 0,
                albumArtist: (d["Album Artist"] as? String) ?? "",
                isCompilation: (d["Compilation"] as? Bool) == true,
                discNumber: (d["Disc Number"] as? Int) ?? 0,
                discCount: (d["Disc Count"] as? Int) ?? 0,
                isPurchased: isPurchased,
                isLossless: LocalTrack.looksLossless(kind: (d["Kind"] as? String) ?? "", bitRateKbps: Self.kbps(d["Bit Rate"])),
                genre: (d["Genre"] as? String) ?? "",
                year: (d["Year"] as? Int) ?? 0,
                bpm: (d["BPM"] as? Int) ?? 0,
                playCount: (d["Play Count"] as? Int) ?? 0)
            entries.append(Entry(track: track, path: path))
        }

        var playlists: [PlaylistInfo] = []
        for pl in (root["Playlists"] as? [[String: Any]]) ?? [] {
            if (pl["Master"] as? Bool) == true || (pl["Folder"] as? Bool) == true { continue }
            if let kind = pl["Distinguished Kind"] as? Int, kind != 0 { continue }
            let ids = ((pl["Playlist Items"] as? [[String: Any]]) ?? [])
                .compactMap { ($0["Track ID"] as? Int).flatMap { idByTrackID[$0] } }
            guard !ids.isEmpty else { continue }
            let pid = (pl["Playlist Persistent ID"] as? String) ?? String((pl["Playlist ID"] as? Int) ?? 0)
            // L'XML segna le playlist smart con «Smart Info»; per le Genius si cerca la chiave «Genius» (se manca, valgono come normali).
            let kind: PlaylistKind = pl["Smart Info"] != nil ? .smart : ((pl["Genius"] as? Bool) == true ? .genius : .regular)
            playlists.append(PlaylistInfo(id: idPrefix + pid, name: (pl["Name"] as? String) ?? "", trackIDs: ids, kind: kind))
        }
        playlists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ExternalParsed(sourceFolder: sourceFolder, entries: entries, playlists: playlists)
    }
}

// MARK: - Gestione delle librerie remote (Impostazioni ▸ Remote Libraries)

/// Fase della lettura di una libreria remota (mostrata come riga di stato nelle Impostazioni).
struct RemoteLoadProgress: Identifiable, Equatable {
    let id = UUID()
    var nickname: String
    /// Vero se la lettura è partita dalle Impostazioni (la finestra compare lì, non nella principale).
    var inSettings: Bool
    var phase: String
    /// Copia dell'XML in corso (librerie di rete): byte copiati e totali. Con il totale > 0 la capsula mostra l'anello verde.
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var isCopying: Bool { bytesTotal > 0 }
    var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
}

/// Stato condiviso tra la copia dell'XML e il suo controllo (ultimo dato ricevuto, annullamento).
private final class CopyState: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var cancelled = false
    private var finished = false
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    func idle() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    /// Vero solo la prima volta: chi arriva primo (fine copia, errore o blocco) decide l'esito.
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if finished { return false }; finished = true; return true }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}

@MainActor
final class RemoteLibraryManager: ObservableObject {
    static let shared = RemoteLibraryManager()
    private init() {}

    @Published var progress: RemoteLoadProgress?

    /// Dimensione e data dell'XML registrate nella copia compatta usata all'apertura di ogni libreria remota.
    private var cacheSignatures: [UUID: (size: Int, modified: Double)] = [:]

    /// Vero se la libreria è stata aperta dalla copia salvata e l'XML sul server ora ha dimensione o data diverse
    /// (la libreria è cambiata). Non copia né legge l'XML: solo i suoi attributi, e solo se il volume è già montato.
    func sourceChangedSinceCache(_ cfg: RemoteLibraryConfig) async -> Bool {
        guard let saved = cacheSignatures[cfg.id] else { return false }
        let path = cfg.path
        let bookmark = cfg.bookmark
        let current: (size: Int, modified: Double)? = await Task.detached(priority: .utility) {
            let url = bookmark.flatMap { FileBookmark.resolve($0, mounting: false)?.url } ?? URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ExternalParsed.currentSignature(of: url)
        }.value
        guard let current else { return false }
        return current.size != saved.size || abs(current.modified - saved.modified) > 0.5
    }

    enum ManagerError: LocalizedError {
        case missingFile(String)
        case noMediaFolder
        case stalled(Int)
        var errorDescription: String? {
            switch self {
            case .stalled(let s): return t("remote_err_stalled", s)
            case .missingFile(let p): return t("remote_err_missing_file", p)
            case .noMediaFolder: return t("external_cancelled")
            }
        }
    }

    private static func megabytes(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_000_000) }

    /// Copia l'XML in un file temporaneo locale a blocchi, mostrando l'avanzamento in MB (e la velocità), poi lo elabora.
    /// Se per `stallSeconds` non arriva alcun dato, la lettura si interrompe con un errore chiaro.
    private func readCopyingXML(_ xml: URL) async throws -> ExternalParsed {
        let total = await Task.detached { ExternalParsed.fileSize(of: xml) }.value
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mm-xml-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let state = CopyState()
        let started = Date()
        let stallSeconds = 90
        progress?.bytesTotal = total
        progress?.bytesDone = 0

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    guard let input = try? FileHandle(forReadingFrom: xml) else { throw ManagerError.missingFile(xml.path) }
                    FileManager.default.createFile(atPath: tmp.path, contents: nil)
                    let output = try FileHandle(forWritingTo: tmp)
                    defer { try? input.close(); try? output.close() }
                    var done: Int64 = 0
                    var lastPublished = Date.distantPast
                    while !state.isCancelled {
                        let chunk = try input.read(upToCount: 512 * 1024) ?? Data()
                        if chunk.isEmpty { break }
                        try output.write(contentsOf: chunk)
                        done += Int64(chunk.count)
                        state.touch()
                        if Date().timeIntervalSince(lastPublished) > 0.25 {
                            lastPublished = Date()
                            let d = done
                            await MainActor.run { self?.publishCopy(done: d, since: started) }
                        }
                    }
                    let d = done
                    await MainActor.run { self?.publishCopy(done: d, since: started) }
                    if state.claim() { cont.resume() }
                } catch {
                    if state.claim() { cont.resume(throwing: error) }
                }
            }
            Task.detached {
                while !state.isFinished {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if !state.isFinished, state.idle() > Double(stallSeconds) {
                        state.cancel()
                        if state.claim() { cont.resume(throwing: ManagerError.stalled(stallSeconds)) }
                        return
                    }
                }
            }
        }

        progress?.bytesTotal = 0
        progress?.phase = t("remote_phase_processing")
        await Task.yield()
        return try await Task.detached(priority: .userInitiated) { try ExternalParsed.read(localCopy: tmp, original: xml) }.value
    }

    private func publishCopy(done: Int64, since start: Date) {
        guard progress != nil else { return }
        progress?.bytesDone = done
        let elapsed = max(Date().timeIntervalSince(start), 0.5)
        let rate = Double(done) / elapsed
        let speed = rate >= 1_000_000 ? String(format: "%.1f MB/s", rate / 1_000_000) : String(format: "%.0f KB/s", rate / 1000)
        progress?.phase = t("remote_phase_copying", Self.megabytes(done), Self.megabytes(progress?.bytesTotal ?? 0), speed)
    }

    /// Legge una libreria remota. `verify`: controlla l'esistenza di ogni file (lento, per la prima aggiunta).
    /// `preferCache`: usa la copia compatta già salvata (senza rileggere l'XML né controllare se è cambiato);
    /// l'XML si legge solo se la copia non c'è ancora.
    func load(_ cfg: RemoteLibraryConfig, verify: Bool, inSettings: Bool, preferCache: Bool = false) async throws -> LibraryCatalog {
        let pathURL = URL(fileURLWithPath: cfg.path)
        progress = RemoteLoadProgress(nickname: cfg.nickname, inSettings: inSettings, phase: t("remote_phase_reading"))
        defer { progress = nil }
        await Task.yield()

        var cached: ExternalParsed?
        var readStart: Date?
        if preferCache {
            let found = await Task.detached(priority: .userInitiated) { ExternalParsed.readCachedOnlyWithSignature(xml: pathURL) }.value
            cached = found?.parsed
            if let found { cacheSignatures[cfg.id] = (found.size, found.modified) } else { cacheSignatures[cfg.id] = nil }
        }
        // File XML: se c'è il segnalibro si ritrova anche con il volume rinominato o smontato (il sistema lo rimonta);
        // altrimenti vale il percorso salvato. Con la copia compatta l'XML non serve e non si tocca la rete.
        let xml: URL
        if cached == nil, let data = cfg.bookmark,
           let found = await Task.detached(priority: .userInitiated, operation: { FileBookmark.resolve(data) }).value {
            xml = found.url
            if found.url.path != cfg.path || found.stale {
                var renewed: Data?
                if found.stale { renewed = await Task.detached { FileBookmark.make(for: found.url) }.value }
                AppSettings.shared.setXMLLocation(path: found.url.path, bookmark: renewed, for: cfg.id)
            }
        } else {
            xml = pathURL
        }
        let parsed: ExternalParsed
        if let cached {
            parsed = cached
        } else {
            guard FileManager.default.fileExists(atPath: xml.path) else { throw ManagerError.missingFile(cfg.path) }
            // Librerie salvate prima dei segnalibri: se ne crea uno ora.
            if cfg.bookmark == nil, let made = await Task.detached(operation: { FileBookmark.make(for: xml) }).value {
                AppSettings.shared.setXMLLocation(path: xml.path, bookmark: made, for: cfg.id)
            }
            readStart = Date()
            if let valid = await Task.detached(priority: .userInitiated, operation: { ExternalParsed.readValidCache(xml: xml) }).value {
                parsed = valid
            } else {
                parsed = try await readCopyingXML(xml)
            }
        }

        // Cartella dei file: prima il segnalibro (ritrova e, se serve, rimonta il volume), poi il percorso
        // memorizzato (con la copia compatta si usa senza controlli), poi le candidate vicino all'XML, poi si chiede.
        var media: URL?
        var savedMedia: URL? = cfg.mediaPath.isEmpty ? nil : URL(fileURLWithPath: cfg.mediaPath, isDirectory: true)
        var mediaStale = false
        if let data = cfg.mediaBookmark,
           let found = await Task.detached(priority: .userInitiated, operation: { FileBookmark.resolve(data) }).value {
            savedMedia = URL(fileURLWithPath: found.url.path, isDirectory: true)
            mediaStale = found.stale
        }
        if let saved = savedMedia {
            if cached != nil {
                media = saved
            } else if await Task.detached(operation: { parsed.matches(mediaFolder: saved) }).value {
                media = saved
            }
        }
        if media == nil {
            for candidate in ExternalParsed.candidateMediaFolders(xml: xml)
            where FileManager.default.fileExists(atPath: candidate.path) {
                if await Task.detached(operation: { parsed.matches(mediaFolder: candidate) }).value { media = candidate; break }
            }
        }
        if media == nil {
            // La finestra di avanzamento si nasconde mentre si sceglie la cartella.
            let saved = progress
            progress = nil
            let q = NSOpenPanel()
            q.title = t("external_pick_media_title")
            q.message = t("external_pick_media_message")
            q.canChooseFiles = false
            q.canChooseDirectories = true
            let ok = q.runModal() == .OK
            progress = saved
            guard ok, let folder = q.url else { throw ManagerError.noMediaFolder }
            media = folder
        }
        guard let media else { throw ManagerError.noMediaFolder }
        // Percorso e segnalibro della cartella: si aggiornano se cambiati o mancanti (il segnalibro si crea solo
        // se il volume è raggiungibile).
        if media.path != cfg.mediaPath || cfg.mediaBookmark == nil || mediaStale {
            let made = await Task.detached(operation: { FileBookmark.make(for: media) }).value
            AppSettings.shared.setMediaLocation(path: media.path, bookmark: made, for: cfg.id)
        }

        // Dopo una lettura vera dell'XML si indica quanto è durata (utile per capire dove va il tempo).
        if let readStart {
            progress?.phase = t("remote_phase_processing_took", Int(Date().timeIntervalSince(readStart).rounded()))
        } else {
            progress?.phase = t("remote_phase_processing")
        }
        let catalog = await Task.detached(priority: .userInitiated) {
            parsed.catalog(mediaFolder: media, verify: verify)
        }.value
        return catalog
    }
}

// MARK: - Librerie «Unità esterna» (2.2)

/// Indice JSON di una cartella di file audio su un'unità esterna: un elemento per file, con i tag letti una volta sola.
/// Contiene solo i file nei formati accettati dal dispositivo Garmin scelto. I file dell'utente non si modificano mai.
struct DriveIndex: Codable, Sendable {
    struct Item: Codable, Sendable {
        var rel: String              // percorso relativo alla cartella radice
        var size: Int
        var modified: Double         // data di modifica del file (per la rilettura incrementale)
        var title: String
        var artist: String
        var album: String
        var albumArtist: String
        var duration: Double
        var trackNumber: Int
        var discNumber: Int
        var genre: String
        var year: Int
        var lossless: Bool
        var protected: Bool
    }
    struct PlaylistEntry: Codable, Sendable {
        var name: String
        var rels: [String]
    }
    var version = 1
    var deviceID: String
    var extensions: [String]
    var items: [Item]
    var playlists: [PlaylistEntry]
}

enum DriveLibraryError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let name): return t("drive_err_unavailable", name)
        }
    }
}

/// Un dispositivo registrato tra cui scegliere per quale creare il catalogo.
struct DriveDeviceChoice: Identifiable, Equatable {
    let id: String
    let name: String
    /// Formati inviabili: quelli dichiarati dal dispositivo (GarminDevice.xml) che l'app sa preparare.
    let extensions: [String]
    let connected: Bool
    var formatsText: String { extensions.map { $0.uppercased() }.joined(separator: ", ") }
}

enum DriveLibraryService {
    /// Importazione delle playlist `.m3u` / `.m3u8` trovate nella cartella: SPENTA per ora (i riferimenti dei file possono
    /// puntare altrove, per esempio al disco del Mac, e dare risultati ingannevoli). Il codice resta per un uso futuro.
    nonisolated static let importPlaylists = false

    nonisolated static func indexURL(_ id: UUID) -> URL {
        AppFolders.externalLibrary.appendingPathComponent("drive-index-\(id.uuidString).json")
    }

    nonisolated static func loadIndex(_ id: UUID) -> DriveIndex? {
        guard let data = try? Data(contentsOf: indexURL(id)) else { return nil }
        return try? JSONDecoder().decode(DriveIndex.self, from: data)
    }

    nonisolated static func saveIndex(_ index: DriveIndex, for id: UUID) {
        let url = indexURL(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: url, options: .atomic) }
    }

    nonisolated static func removeIndex(_ id: UUID) {
        try? FileManager.default.removeItem(at: indexURL(id))
    }

    /// Cartella radice attuale: prima il segnalibro (ritrova la cartella anche se il volume cambia nome), poi il percorso
    /// salvato. Nil se non è raggiungibile (unità scollegata).
    nonisolated static func rootURL(_ cfg: DriveLibraryConfig) -> URL? {
        var candidates: [String] = []
        if let data = cfg.bookmark, let found = FileBookmark.resolve(data) { candidates.append(found.url.path) }
        candidates.append(cfg.path)
        for path in candidates where !path.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }

    private struct Found: Sendable {
        let rel: String
        let size: Int
        let modified: Double
    }

    /// Elenco dei file audio (nei formati ammessi) e delle playlist della cartella. Funzione non asincrona: l'enumeratore
    /// dei file non si può usare in un contesto async.
    nonisolated private static func walk(root: URL, rootPath: String, extensions: Set<String>) -> ([Found], [URL]) {
        var found: [Found] = []
        var listFiles: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], []) }
        for case let url as URL in walker {
            let ext = url.pathExtension.lowercased()
            let isList = ext == "m3u" || ext == "m3u8"
            guard isList || extensions.contains(ext), !url.lastPathComponent.hasPrefix("._") else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  url.path.hasPrefix(rootPath) else { continue }
            if isList { listFiles.append(url); continue }
            found.append(Found(rel: String(url.path.dropFirst(rootPath.count)), size: values.fileSize ?? 0,
                               modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return (found, listFiles)
    }

    /// Scansiona la cartella: elenca i file nei formati ammessi, rilegge i tag solo dei file nuovi o cambiati (stessa
    /// dimensione e data = si riusa l'indice precedente) e importa in sola lettura le playlist `.m3u` / `.m3u8`.
    /// `progress` riceve (letti, totale) a ogni gruppo di file.
    nonisolated static func scan(root: URL, extensions: Set<String>, previous: DriveIndex?, deviceID: String,
                                 progress: @escaping @Sendable (Int, Int) -> Void) async -> DriveIndex {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        // Oltre ai formati del dispositivo si indicizzano FLAC, WAV e AIFF, che compaiono bloccati con il nome del formato.
        let (found, listFiles) = walk(root: root, rootPath: rootPath, extensions: extensions.union(LocalTrack.losslessExtensions))
        let previousByRel = Dictionary((previous?.items ?? []).map { ($0.rel, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [DriveIndex.Item] = []
        var todo: [Found] = []
        for f in found {
            if let old = previousByRel[f.rel], old.size == f.size, old.modified == f.modified { items.append(old) } else { todo.append(f) }
        }
        let total = found.count
        var done = items.count
        progress(done, total)

        // Lettura dei tag: qualche file alla volta (su una chiavetta troppi accessi insieme non aiutano).
        var pending = todo.makeIterator()
        await withTaskGroup(of: DriveIndex.Item.self) { group in
            for _ in 0..<min(6, todo.count) {
                if let f = pending.next() { group.addTask { await readItem(root: root, found: f) } }
            }
            for await item in group {
                items.append(item)
                done += 1
                if done % 25 == 0 || done == total { progress(done, total) }
                if let f = pending.next() { group.addTask { await readItem(root: root, found: f) } }
            }
        }
        items.sort { $0.rel.localizedCaseInsensitiveCompare($1.rel) == .orderedAscending }
        let playlists = importPlaylists ? parsePlaylists(listFiles, rootPath: rootPath, known: Set(items.map(\.rel))) : []
        return DriveIndex(deviceID: deviceID, extensions: extensions.sorted(), items: items, playlists: playlists)
    }

    /// Legge i tag di un file (titolo, artista, album, durata, numero di traccia e disco, genere, anno, Lossless, DRM).
    nonisolated private static func readItem(root: URL, found f: Found) async -> DriveIndex.Item {
        let url = root.appendingPathComponent(f.rel, isDirectory: false)
        let asset = AVURLAsset(url: url)
        var item = DriveIndex.Item(rel: f.rel, size: f.size, modified: f.modified,
                                   title: url.deletingPathExtension().lastPathComponent, artist: "", album: "",
                                   albumArtist: "", duration: 0, trackNumber: 0, discNumber: 0, genre: "", year: 0,
                                   lossless: false, protected: false)
        if let d = try? await asset.load(.duration), d.isNumeric { item.duration = d.seconds }
        item.protected = (try? await asset.load(.hasProtectedContent)) ?? false
        if let metadata = try? await asset.load(.metadata) {
            for entry in metadata {
                let raw = (entry.identifier?.rawValue ?? "").lowercased()   // es. «id3/trck», «itsk/trkn»
                let text = (try? await entry.load(.stringValue)) ?? nil
                if let key = entry.commonKey {
                    switch key {
                    case .commonKeyTitle: if let v = text, !v.isEmpty { item.title = v }
                    case .commonKeyArtist: if let v = text, !v.isEmpty { item.artist = v }
                    case .commonKeyAlbumName: if let v = text, !v.isEmpty { item.album = v }
                    case .commonKeyType: if let v = text, !v.isEmpty, item.genre.isEmpty { item.genre = v }
                    default: break
                    }
                }
                if raw.hasSuffix("/tpe2") || raw.hasSuffix("/aart"), let v = text, !v.isEmpty { item.albumArtist = v }
                if raw.hasSuffix("/trck") || raw.hasSuffix("/trkn") { item.trackNumber = await number(entry, text: text) ?? item.trackNumber }
                if raw.hasSuffix("/tpos") || raw.hasSuffix("/disk") { item.discNumber = await number(entry, text: text) ?? item.discNumber }
                if raw.hasSuffix("/tyer") || raw.hasSuffix("/tdrc") || raw.contains("day"), item.year == 0,
                   let v = text, let y = Int(v.prefix(4)), y > 1000 { item.year = y }
            }
        }
        // FLAC, WAV e AIFF sono senza perdita per definizione; senza tag (frequente con WAV) artista e album si ricavano
        // dalle cartelle (Artista/Album/brano), il titolo resta il nome del file.
        let ext = url.pathExtension.lowercased()
        if LocalTrack.losslessExtensions.contains(ext) {
            item.lossless = true
            let parts = f.rel.split(separator: "/").map(String.init)
            if item.artist.isEmpty, item.album.isEmpty {
                if parts.count >= 3 { item.artist = parts[parts.count - 3]; item.album = parts[parts.count - 2] }
                else if parts.count == 2 { item.album = parts[0] }
            }
        }
        // Apple Lossless dentro un .m4a: si riconosce dal formato audio ('alac'); non si invia al Garmin.
        if url.pathExtension.lowercased() == "m4a",
           let track = (try? await asset.loadTracks(withMediaType: .audio))?.first,
           let formats = try? await track.load(.formatDescriptions), let first = formats.first {
            item.lossless = CMFormatDescriptionGetMediaSubType(first) == 0x616C6163
        }
        return item
    }

    /// Numero da un tag: testo «3/12», numero o i 4 byte del tag iTunes «trkn»/«disk» (2 byte a zero, poi il numero).
    nonisolated private static func number(_ entry: AVMetadataItem, text: String?) async -> Int? {
        if let text, let n = Int(text.split(separator: "/").first.map(String.init) ?? "") { return n }
        if let n = (try? await entry.load(.numberValue)) ?? nil { return n.intValue }
        if let data = (try? await entry.load(.dataValue)) ?? nil, data.count >= 4 {
            return Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
        }
        return nil
    }

    /// Playlist `.m3u` / `.m3u8` della cartella, in sola lettura: si tengono i percorsi che portano a file dell'indice
    /// (assoluti, relativi alla playlist, o scritti da un altro computer: in tal caso si cerca per nome file, se unico).
    nonisolated private static func parsePlaylists(_ lists: [URL], rootPath: String, known: Set<String>) -> [DriveIndex.PlaylistEntry] {
        var byName: [String: [String]] = [:]
        for rel in known { byName[(rel as NSString).lastPathComponent.lowercased(), default: []].append(rel) }
        var result: [DriveIndex.PlaylistEntry] = []
        for url in lists {
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let folder = url.deletingLastPathComponent()
            var rels: [String] = []
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                var path: String
                if line.hasPrefix("file://"), let u = URL(string: line) { path = u.path }
                else if line.hasPrefix("/") { path = line }
                else { path = folder.appendingPathComponent(line).standardized.path }
                path = path.precomposedStringWithCanonicalMapping
                if path.hasPrefix(rootPath), known.contains(String(path.dropFirst(rootPath.count))) {
                    rels.append(String(path.dropFirst(rootPath.count)))
                } else if let candidates = byName[(path as NSString).lastPathComponent.lowercased()], candidates.count == 1 {
                    rels.append(candidates[0])
                }
            }
            if !rels.isEmpty { result.append(DriveIndex.PlaylistEntry(name: url.deletingPathExtension().lastPathComponent, rels: rels)) }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Brani e playlist per l'app: gli id iniziano per «ext:» (come le altre librerie esterne), con il codice della libreria.
    nonisolated static func catalog(index: DriveIndex, libraryID: UUID, root: URL) -> LibraryCatalog {
        let prefix = "ext:drive-\(libraryID.uuidString):"
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let tracks = index.items.map { it in
            LocalTrack(id: prefix + it.rel, title: it.title,
                       artist: it.artist.isEmpty ? t("unknown_artist") : it.artist, album: it.album,
                       url: URL(fileURLWithPath: base + it.rel, isDirectory: false), fileSize: it.size,
                       isDRMProtected: it.protected, isCloud: false, duration: it.duration,
                       trackNumber: it.trackNumber, albumArtist: it.albumArtist, isCompilation: false,
                       discNumber: it.discNumber, discCount: 0, isPurchased: false, isLossless: it.lossless,
                       genre: it.genre, year: it.year)
        }
        let playlists = (importPlaylists ? index.playlists : []).map {
            PlaylistInfo(id: prefix + "pl:" + $0.name, name: $0.name, trackIDs: $0.rels.map { prefix + $0 }, kind: .regular)
        }
        return LibraryCatalog(tracks: tracks.sortedForLibrary(), playlists: playlists)
    }
}

/// Gestione delle librerie «Unità esterna»: scelta del dispositivo, scansione e catalogo.
@MainActor
final class DriveLibraryManager: ObservableObject {
    static let shared = DriveLibraryManager()
    private init() {}

    /// Fase della scansione in corso (riga di stato nelle Impostazioni); nil = nessuna scansione.
    @Published var progress: String?

    /// Dispositivi registrati che accettano musica, con i formati inviabili (da GarminDevice.xml salvato al collegamento).
    func deviceChoices() -> [DriveDeviceChoice] {
        let connected = AppSettings.shared.connectedDeviceIDs
        var why: [String] = []
        let choices: [DriveDeviceChoice] = AppSettings.shared.knownDevices.compactMap { known in
            let label = known.model.isEmpty ? known.id : known.model
            guard let stored = DeviceXMLStore.load(forDevice: known.id) else { why.append("\(label): copia di GarminDevice.xml assente"); return nil }
            guard let media = DeviceImageService.mediaCapabilities(fromXML: stored.xml) else { why.append("\(label): XML senza informazioni sui supporti"); return nil }
            guard media.isMusicCapable else { why.append("\(label): non accetta musica secondo l'XML"); return nil }
            let formats = media.trackExtensions.intersection(LocalTrack.appExtensions).sorted()
            guard !formats.isEmpty else { why.append("\(label): nessun formato inviabile (XML: \(media.trackExtensions.sorted().joined(separator: ",")))"); return nil }
            let nick = known.nickname.trimmingCharacters(in: .whitespaces)
            return DriveDeviceChoice(id: known.id, name: nick.isEmpty ? (known.model.isEmpty ? known.id : known.model) : nick,
                                     extensions: formats, connected: connected.contains(known.id))
        }
        if choices.isEmpty {
            AppLog.debug("Unità esterna: nessun dispositivo utilizzabile (registrati: \(AppSettings.shared.knownDevices.count)) — " +
                         (why.isEmpty ? "nessun dispositivo registrato" : why.joined(separator: "; ")) + ": si usa il profilo «Garmin generico»")
            // Nessun Garmin ancora registrato (o nessuno utilizzabile): si può comunque configurare l'unità con i formati che l'app
            // sa preparare. Quando poi si collega un Garmin con formati diversi, l'app propone di rifare il catalogo.
            return [DriveDeviceChoice(id: "", name: t("drive_generic_device"),
                                      extensions: LocalTrack.appExtensions.sorted(), connected: false)]
        }
        return choices
    }

    /// Dispositivo da usare senza chiedere: quello collegato; altrimenti l'unico registrato. Nil = bisogna scegliere (o non c'è).
    func automaticDevice(in choices: [DriveDeviceChoice]) -> DriveDeviceChoice? {
        if let connected = choices.first(where: \.connected) { return connected }
        return choices.count == 1 ? choices[0] : nil
    }

    /// Scansiona la cartella (in modo incrementale se c'è già un indice) e salva l'indice. `report` riceve il testo di avanzamento.
    @discardableResult
    func scan(_ cfg: DriveLibraryConfig, report: (@MainActor @Sendable (String) -> Void)? = nil) async throws -> DriveIndex {
        guard let root = DriveLibraryService.rootURL(cfg) else { throw DriveLibraryError.unavailable(cfg.nickname) }
        let start = Date()
        let previous = DriveLibraryService.loadIndex(cfg.id)
        progress = t("drive_phase_scanning")
        report?(t("drive_phase_scanning"))
        defer { progress = nil }
        let index = await DriveLibraryService.scan(root: root, extensions: Set(cfg.extensions), previous: previous,
                                                   deviceID: cfg.deviceID) { done, total in
            Task { @MainActor in
                let text = t("drive_phase_reading", done, total)
                DriveLibraryManager.shared.progress = text
                report?(text)
            }
        }
        DriveLibraryService.saveIndex(index, for: cfg.id)
        AppSettings.shared.updateDriveLibrary(cfg.id) { $0.trackCount = index.items.count; $0.scannedAt = Date() }
        AppLog.debug("Unità esterna «\(cfg.nickname)»: \(index.items.count) brani, \(index.playlists.count) playlist in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        return index
    }

    /// Catalogo dall'indice salvato (nil se manca l'indice o l'unità non è collegata).
    func catalog(for cfg: DriveLibraryConfig) async -> LibraryCatalog? {
        guard let root = DriveLibraryService.rootURL(cfg), let index = DriveLibraryService.loadIndex(cfg.id) else { return nil }
        let id = cfg.id
        return await Task.detached(priority: .userInitiated) {
            DriveLibraryService.catalog(index: index, libraryID: id, root: root)
        }.value
    }
}
