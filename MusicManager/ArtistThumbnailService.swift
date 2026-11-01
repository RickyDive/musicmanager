import Foundation
import CryptoKit

/// Scarica e mette in cache la miniatura di un artista da Apple Music.
/// Flusso: iTunes Search API -> pagina artista -> meta og:image -> download.
///
/// 2.3 Beta 3: integrato nell'app (modulo fornito dall'utente) con queste aggiunte rispetto all'originale:
/// - cartella `~/Library/Application Support/MusicManager/Cache/ArtistsMiniature` (`AppFolders.artistsMiniature`), con le sole
///   miniature JPEG, un file per artista e dimensione;
/// - nome del file con un'impronta del nome: i nomi non latini (che prima davano tutti lo stesso nome file) non si sovrascrivono;
/// - si accetta solo il risultato di ricerca con lo stesso nome dell'artista (meglio il riquadro vuoto che la foto di un omonimo);
/// - **coda di richieste** con tre lavoratori: le righe visibili passano davanti (`thumbnail(for:)`), il resto dell'elenco si
///   scarica in sottofondo (`enqueueBackground`, vedi `interleaved` per l'ordine a cinque blocchi);
/// - **limite di frequenza**: al massimo 18 ricerche al minuto (Apple ne consente circa 20) e almeno 0,7 s tra due ricerche; se il
///   servizio rifiuta (HTTP 403/429) la coda si ferma da sola (1, 2, 4… fino a 10 minuti) e riparte senza perdere nulla;
/// - memoria degli artisti senza miniatura: quelli non trovati su Apple Music si ricordano per 15 giorni anche dopo la chiusura
///   dell'app (file `Cache/ArtistsNotFound.json`), così le aperture successive non ripetono le ricerche inutili.
actor ArtistThumbnailService {
    static let shared = ArtistThumbnailService()

    /// Notifica inviata quando una miniatura nuova è sul disco (`userInfo["name"]` = nome dell'artista): le righe vuote la rileggono.
    static let didArriveNotification = Notification.Name("ArtistThumbnailDidArrive")

    /// Ordine di scaricamento «a blocchi»: l'elenco è diviso in `blocks` parti uguali e si procede dal primo di ciascuna a turno
    /// (con 100 artisti e 5 blocchi: 1, 21, 41, 61, 81, 2, 22, …), così la lista si popola in modo omogeneo e non solo dall'inizio.
    nonisolated static func interleaved(_ names: [String], blocks: Int = 5) -> [String] {
        guard names.count > blocks, blocks > 1 else { return names }
        let size = (names.count + blocks - 1) / blocks
        var result: [String] = []
        result.reserveCapacity(names.count)
        for i in 0..<size {
            for b in 0..<blocks {
                let index = b * size + i
                if index < names.count { result.append(names[index]) }
            }
        }
        return result
    }

    private struct Job: Hashable {
        let name: String
        let size: Int
    }

    private enum Outcome {
        case done(Data?)
        case retry
    }

    private let session: URLSession
    private let cacheDir: URL
    private let country = "it"

    /// Artisti senza miniatura per un errore in questa sessione (immagine non scaricabile): si riprova dopo un'ora.
    private var misses: [String: Date] = [:]
    /// Artisti non trovati su Apple Music (o con pagina senza immagine): ricordati su disco per 15 giorni.
    private var notFound: [String: Date] = [:]
    private let notFoundDays: Double = 15
    private let notFoundFile = AppFolders.artistsNotFound

    // Coda: le richieste delle righe visibili (la più recente in testa) e l'elenco in sottofondo.
    private var urgent: [Job] = []
    private var background: [Job] = []
    private var waiters: [Job: [CheckedContinuation<Data?, Never>]] = [:]
    private var workers = 0
    private let maxWorkers = 3

    // Frequenza delle ricerche.
    private let searchGap: TimeInterval = 0.7
    private let maxSearchesPerMinute = 18
    private var searchSlots: [Date] = []
    private var blockedUntil = Date.distantPast
    private var consecutiveBlocks = 0
    private var consecutiveFailures = 0

    init(session: URLSession = .shared) {
        self.session = session
        cacheDir = AppFolders.artistsMiniature
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        loadNotFound()
    }

    // MARK: - Interfaccia

    /// Solo la lettura dal disco, senza rete: dati JPEG già salvati (nil se mancano).
    func cachedThumbnail(for artist: String, size: Int = 200) -> Data? {
        try? Data(contentsOf: file(for: artist, size: size))
    }

    /// Restituisce i dati JPEG della miniatura (nil se non trovata). La richiesta passa in testa alla coda.
    /// Con NSImage(data:) su macOS o UIImage(data:) su iOS diventa un'immagine.
    func thumbnail(for artist: String, size: Int = 200, country: String = "it") async -> Data? {
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let cached = cachedThumbnail(for: name, size: size) { return cached }
        if isKnownMissing(identity(name)) { return nil }

        let job = Job(name: name, size: size)
        return await withCheckedContinuation { continuation in
            waiters[job, default: []].append(continuation)
            urgent.removeAll { $0 == job }
            urgent.insert(job, at: 0)
            // Scorrendo in fretta le richieste si accumulano: oltre 60 si lasciano le più vecchie al sottofondo.
            while urgent.count > 60 {
                let dropped = urgent.removeLast()
                resolve(dropped, with: nil)
                background.append(dropped)
            }
            startWorkers()
        }
    }

    /// Sostituisce l'elenco in sottofondo (già nell'ordine voluto, vedi `interleaved`). Chi ha già la miniatura o è tra i
    /// «non trovati» viene saltato senza richieste.
    func enqueueBackground(_ artists: [String], size: Int = 100) {
        background = artists.map { Job(name: $0.trimmingCharacters(in: .whitespacesAndNewlines), size: size) }
            .filter { !$0.name.isEmpty }
        if !background.isEmpty {
            AppLog.debug("Miniature artisti: \(background.count) artisti da controllare in sottofondo")
        }
        startWorkers()
    }

    // MARK: - Lavoratori

    private func startWorkers() {
        while workers < maxWorkers, !urgent.isEmpty || !background.isEmpty {
            workers += 1
            Task { await self.workerLoop() }
        }
    }

    private func nextJob() -> Job? {
        if !urgent.isEmpty { return urgent.removeFirst() }
        if !background.isEmpty { return background.removeFirst() }
        return nil
    }

    private func workerLoop() async {
        while let job = nextJob() {
            switch await process(job) {
            case .done(let data):
                resolve(job, with: data)
                if data != nil {
                    NotificationCenter.default.post(name: Self.didArriveNotification, object: nil, userInfo: ["name": job.name])
                }
            case .retry:
                // Pausa o rete assente: la richiesta resta in coda (in testa) e si riprova.
                if waiters[job] != nil { urgent.insert(job, at: 0) } else { background.insert(job, at: 0) }
            }
        }
        workers -= 1
    }

    private func resolve(_ job: Job, with data: Data?) {
        if let list = waiters.removeValue(forKey: job) {
            for continuation in list { continuation.resume(returning: data) }
        }
    }

    // MARK: - Una richiesta

    private func process(_ job: Job) async -> Outcome {
        let artist = job.name, size = job.size
        let key = identity(artist)
        // Già sul disco: solo chi aspetta (una riga) ne legge il contenuto.
        if FileManager.default.fileExists(atPath: file(for: artist, size: size).path) {
            return .done(waiters[job] != nil ? cachedThumbnail(for: artist, size: size) : nil)
        }
        if isKnownMissing(key) { return .done(nil) }

        // Pausa dopo un rifiuto del servizio.
        if Date() < blockedUntil { return await pauseThenRetry() }

        // Distanza e frequenza massima delle ricerche.
        let slot = reserveSearchSlot()
        let wait = slot.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        if Date() < blockedUntil { return await pauseThenRetry() }

        let t0 = Date()
        let search = await artistPageURL(for: artist)
        let tSearch = Date().timeIntervalSince(t0)
        switch search {
        case .rateLimited(let status):
            return blockService(status: status)
        case .failed:
            return noteFailure()
        case .notFound, .noImage:
            consecutiveFailures = 0
            rememberNotFound(key)
            return .done(nil)
        case .found(let pageURL):
            consecutiveFailures = 0
            let t1 = Date()
            let imageURL: URL
            switch await ogImageURL(from: pageURL, size: size) {
            case .rateLimited(let status): return blockService(status: status)
            case .failed: return noteFailure()
            case .noImage, .notFound:
                rememberNotFound(key)
                return .done(nil)
            case .found(let url): imageURL = url
            }
            let tPage = Date().timeIntervalSince(t1)
            let t2 = Date()
            guard let (data, response) = try? await session.data(from: imageURL),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count > 500, data.prefix(2) == Data([0xFF, 0xD8])   // JPEG vero
            else {
                misses[key] = Date()
                return .done(nil)
            }
            consecutiveBlocks = 0
            try? data.write(to: file(for: artist, size: size), options: .atomic)
            if notFound.removeValue(forKey: key) != nil { saveNotFound() }
            AppLog.debug(String(format: "Miniatura artista «%@»: ricerca %.2f s, pagina %.2f s, immagine %.2f s (%d byte)",
                                artist, tSearch, tPage, Date().timeIntervalSince(t2), data.count))
            return .done(data)
        }
    }

    /// Attende la fine della pausa e chiede di riprovare.
    private func pauseThenRetry() async -> Outcome {
        let wait = max(blockedUntil.timeIntervalSinceNow, 0.5)
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        return .retry
    }

    /// Il servizio ha rifiutato (403/429): tutta la coda si ferma 1, 2, 4… minuti (al massimo 10) e poi riparte da sola.
    private func blockService(status: Int) -> Outcome {
        consecutiveBlocks += 1
        let pause = min(60.0 * pow(2.0, Double(consecutiveBlocks - 1)), 600)
        blockedUntil = Date().addingTimeInterval(pause)
        AppLog.debug("Miniature artisti: Apple ha risposto HTTP \(status), coda in pausa per \(Int(pause)) s (in coda: \(urgent.count + background.count))")
        return .retry
    }

    /// Errore di rete o risposta illeggibile: dopo tre di fila si aspetta mezzo minuto; altrimenti l'artista si salta (si riprova alla prossima occasione).
    private func noteFailure() -> Outcome {
        consecutiveFailures += 1
        if consecutiveFailures >= 3 {
            consecutiveFailures = 0
            blockedUntil = Date().addingTimeInterval(30)
            AppLog.debug("Miniature artisti: rete o servizio non raggiungibili, coda in pausa per 30 s")
            return .retry
        }
        return .done(nil)
    }

    /// Prenota il momento della prossima ricerca: almeno `searchGap` dopo la precedente e non più di `maxSearchesPerMinute` al minuto.
    private func reserveSearchSlot() -> Date {
        var slot = max(Date(), (searchSlots.last ?? .distantPast).addingTimeInterval(searchGap))
        if searchSlots.count >= maxSearchesPerMinute {
            slot = max(slot, searchSlots[searchSlots.count - maxSearchesPerMinute].addingTimeInterval(60))
        }
        searchSlots.append(slot)
        if searchSlots.count > 60 { searchSlots.removeFirst(searchSlots.count - 60) }
        return slot
    }

    private func isKnownMissing(_ key: String) -> Bool {
        if let when = notFound[key], Date().timeIntervalSince(when) < notFoundDays * 86_400 { return true }
        if let when = misses[key], Date().timeIntervalSince(when) < 3600 { return true }
        return false
    }

    // MARK: - «Non trovati» su disco

    private func loadNotFound() {
        guard let data = try? Data(contentsOf: notFoundFile),
              let stored = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        let limit = Date().addingTimeInterval(-notFoundDays * 86_400)
        notFound = stored.mapValues { Date(timeIntervalSince1970: $0) }.filter { $0.value > limit }
    }

    private func saveNotFound() {
        let stored = notFound.mapValues { $0.timeIntervalSince1970 }
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: notFoundFile, options: .atomic) }
    }

    private func rememberNotFound(_ key: String) {
        notFound[key] = Date()
        saveNotFound()
    }

    // MARK: - Passi di rete

    private struct SearchResponse: Decodable {
        struct Item: Decodable { let artistName: String?; let artistLinkUrl: String? }
        let results: [Item]
    }

    private enum Step { case found(URL), noImage, notFound, rateLimited(Int), failed }

    private func artistPageURL(for artist: String) async -> Step {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = c.url, let (data, response) = try? await session.data(from: url) else { return .failed }
        if let status = (response as? HTTPURLResponse)?.statusCode {
            if status == 403 || status == 429 { return .rateLimited(status) }
            if status != 200 { return .failed }
        }
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return .failed }
        let wanted = cacheKey(artist)
        guard !wanted.isEmpty,
              let item = decoded.results.first(where: { cacheKey($0.artistName ?? "") == wanted }),
              let link = item.artistLinkUrl, let page = URL(string: link)
        else { return .notFound }
        return .found(page)
    }

    private func ogImageURL(from pageURL: URL, size: Int) async -> Step {
        var req = URLRequest(url: pageURL)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        // Il tag og:image sta nell'intestazione della pagina: bastano i primi byte (se il server ignora l'intervallo, risponde per intero).
        req.setValue("bytes=0-120000", forHTTPHeaderField: "Range")
        guard let (data, response) = try? await session.data(for: req) else { return .failed }
        if let status = (response as? HTTPURLResponse)?.statusCode {
            if status == 403 || status == 429 { return .rateLimited(status) }
            if !(200...299).contains(status) { return .failed }
        }
        let html = String(decoding: data, as: UTF8.self)   // tollera un carattere spezzato in fondo
        guard let regex = try? NSRegularExpression(pattern: #"<meta property="og:image" content="([^"]+)""#) else { return .failed }

        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1
        else { return .noImage }   // pagina letta, ma senza immagine

        let raw = ns.substring(with: match.range(at: 1))
        // Sostituisce la dimensione nell'URL (es. 1200x630wp-60.jpg -> 200x200bb.jpg)
        let resized = raw.replacingOccurrences(
            of: #"/\d+x\d+[a-z\-0-9]*\.(jpg|png|webp)"#,
            with: "/\(size)x\(size)bb.jpg",
            options: .regularExpression
        )
        guard let url = URL(string: resized) else { return .noImage }
        return .found(url)
    }

    // MARK: - Nomi

    /// Nome normalizzato (minuscolo, senza accenti, solo lettere e cifre — di qualunque alfabeto — separate da «_»).
    private func cacheKey(_ artist: String) -> String {
        artist.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// Identità dell'artista: nome leggibile + impronta del nome originale (distingue anche i nomi non latini).
    private func identity(_ artist: String) -> String {
        let digest = SHA256.hash(data: Data(artist.lowercased().utf8))
        let hash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(String(cacheKey(artist).prefix(40)))_\(hash)"
    }

    /// File della miniatura: identità dell'artista + dimensione.
    private func file(for artist: String, size: Int) -> URL {
        cacheDir.appendingPathComponent("\(identity(artist))_\(size).jpg")
    }
}
