import Foundation
import AppKit

/// Cerca online una copertina per un brano, usando l'API di ricerca pubblica di iTunes (nessuna
/// chiave richiesta): dato artista/titolo, interroga il servizio, sceglie il candidato migliore
/// tra i risultati e scarica/ridimensiona l'immagine. Un actor (non MainActor) perché fa solo rete
/// e calcoli, mai interfaccia.
///
/// Viene chiamata solo dalla finestra "Fix Artwork" (`FixArtworkSession`), cioè su richiesta
/// esplicita dell'utente e mostrando subito il risultato: non gira più in background durante gli
/// invii. Non lancia mai errori verso il chiamante: qualunque problema (rete assente, timeout,
/// risposta malformata, nessun candidato convincente) si traduce semplicemente in `nil`.
actor ArtworkLookupService {
    /// Tolleranza, in secondi, tra la durata del brano locale e quella riportata dal candidato
    /// trovato online: oltre questa soglia il candidato viene scartato anche se titolo e artista
    /// sembrano corrispondere, perché è probabile che sia una versione diversa dello stesso brano
    /// (live, remix, edit radiofonico...), con una copertina diversa da quella giusta.
    private static let durationToleranceSeconds: TimeInterval = 4

    /// Pausa minima tra una richiesta di rete reale e la successiva: un piccolo riguardo verso un
    /// servizio pubblico senza chiave né limiti dichiarati esplicitamente, non una necessità tecnica.
    private static let minimumRequestInterval: TimeInterval = 0.3

    private var lastRequestAt: Date?

    /// Sessione con timeout brevi (invece dei 60 secondi predefiniti di `URLSession.shared`): se il
    /// servizio non risponde, la finestra Fix Artwork mostra "nessuna copertina trovata" in pochi
    /// secondi invece di restare in attesa a lungo.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    /// Numero massimo di copertine diverse proposte per un brano.
    private static let maxCandidates = 10   // 2.3 Beta 2: prima 5

    /// Restituisce i dati JPEG di tutte le copertine diverse trovate per questo brano (la stessa
    /// canzone compare spesso su album, singoli e raccolte diversi, ciascuno con la sua copertina),
    /// nell'ordine proposto dal servizio; array vuoto se non è stata trovata nessuna copertina
    /// abbastanza simile.
    func search(artist: String, title: String, durationSeconds: TimeInterval, album: String = "") async -> [Data] {
        let urls = await findCandidateURLs(artist: artist, title: title, album: album, durationSeconds: durationSeconds)
        guard !urls.isEmpty else { return [] }

        // Download in parallelo, poi riordino secondo l'ordine originale dei risultati.
        var downloaded: [Int: Data] = [:]
        await withTaskGroup(of: (Int, Data?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { (index, await self.downloadAndCompress(url)) }
            }
            for await (index, data) in group {
                if let data { downloaded[index] = data }
            }
        }
        // Scarta anche immagini identiche (stessa copertina con URL diversi).
        var seen = Set<Data>()
        var result: [Data] = []
        for index in urls.indices {
            guard let data = downloaded[index], seen.insert(data).inserted else { continue }
            result.append(data)
        }
        return result
    }

    // MARK: - Ricerca testuale

    /// 2.3 Beta 2: confronto più tollerante, con punteggio. Un risultato passa se la durata coincide (entro 4 s, controllo che resta)
    /// e il titolo coincide **anche togliendo le diciture di versione** («(End Title)», «[Remastered]», «- Remastered 2011»…) e
    /// l'artista coincide **in modo largo** (uno contenuto nell'altro, o almeno un artista in comune fra quelli separati da «&», «,»,
    /// «feat.»…), oppure l'album coincide. I risultati con titolo e artista esatti vengono proposti per primi.
    private func findCandidateURLs(artist: String, title: String, album: String, durationSeconds: TimeInterval) async -> [URL] {
        var scored: [(url: URL, score: Int, albumMatch: Bool, order: Int)] = []
        var seenURLs = Set<URL>()
        var order = 0

        // Prima ricerca: «artista titolo». Seconda (solo se i risultati sono pochi e c'è l'album): «titolo album», che trova i casi in
        // cui l'artista del brano non coincide con quello del servizio (colonne sonore, raccolte).
        var terms = ["\(artist) \(title)"]
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        for round in 0..<2 {
            if round == 1 {
                // Se nessun risultato è dell'album del brano (tipico delle raccolte), si cerca anche «titolo album».
                guard !scored.contains(where: { $0.albumMatch }), !cleanAlbum.isEmpty else { break }
                terms.append("\(title) \(cleanAlbum)")
            }
            guard let response = await fetch(term: terms[round]) else { continue }
            AppLog.debug("Fix Artwork online: ricerca «\(terms[round])» (album richiesto «\(cleanAlbum)»): \(response.results.count) risultati")
            for result in response.results {
                guard let matched = Self.score(result, artist: artist, title: title, album: cleanAlbum) else { continue }
                AppLog.debug("Fix Artwork online:   accettato «\(result.artistName ?? "")» — «\(result.trackName ?? "")» — album «\(result.collectionName ?? "")», punteggio \(matched.score), album coincide: \(matched.albumMatch ? "sì" : "no")")
                if durationSeconds > 0, let millis = result.trackTimeMillis {
                    let candidateDuration = TimeInterval(millis) / 1000
                    guard abs(candidateDuration - durationSeconds) <= Self.durationToleranceSeconds else { continue }
                }
                guard let artworkUrl100 = result.artworkUrl100,
                      let highRes = Self.highResolutionURL(from: artworkUrl100),
                      seenURLs.insert(highRes).inserted else { continue }
                scored.append((highRes, matched.score, matched.albumMatch, order))
                order += 1
            }
        }
        // Prima le copertine dell'ALBUM del brano (raccolte, colonne sonore: è quella che si vuole di solito), poi per sicurezza del
        // confronto, a parità l'ordine del servizio.
        scored.sort {
            if $0.albumMatch != $1.albumMatch { return $0.albumMatch }
            return $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order
        }
        return scored.prefix(Self.maxCandidates).map { $0.url }
    }

    private func fetch(term: String) async -> ITunesSearchResponse? {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "50"),   // 2.3 Beta 2: prima 25
        ]
        guard let url = components.url else { return nil }
        await throttle()
        guard let data = try? await session.data(from: url).0 else { return nil }
        return try? JSONDecoder().decode(ITunesSearchResponse.self, from: data)
    }

    /// Punteggio di un risultato: 4 = artista e titolo esatti; 3 = titolo senza diciture di versione e artista largo, con l'album
    /// uguale; 2 = titolo senza diciture e artista largo; 1 = titolo senza diciture e album uguale (artista diverso). nil = scartato.
    private static func score(_ result: ITunesSearchResponse.Result, artist: String, title: String, album: String) -> (score: Int, albumMatch: Bool)? {
        let resultArtist = normalized(result.artistName ?? "")
        let resultTitle = normalized(result.trackName ?? "")
        let wantedArtist = normalized(artist)
        let wantedTitle = normalized(title)
        let albumMatches = albumsMatch(result.collectionName ?? "", album)
        if resultArtist == wantedArtist, resultTitle == wantedTitle { return (4, albumMatches) }
        guard coreTitle(resultTitle) == coreTitle(wantedTitle), !coreTitle(wantedTitle).isEmpty else { return nil }
        let artistMatches = artistsMatch(resultArtist, wantedArtist)
        switch (artistMatches, albumMatches) {
        case (true, true): return (3, true)
        case (true, false): return (2, false)
        case (false, true): return (1, true)
        default: return nil
        }
    }

    /// Album compatibili: uguali ignorando maiuscole, accenti, punteggiatura e simboli («®», «™»), diciture di versione fra parentesi
    /// e ordine delle parole, oppure uno contenuto nell'altro (almeno 6 caratteri).
    private static func albumsMatch(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            let core = coreTitle(normalized(s))
            let cleaned = core.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            return String(cleaned).components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let ka = key(a), kb = key(b)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        if ka == kb { return true }
        if Set(ka.components(separatedBy: " ")) == Set(kb.components(separatedBy: " ")) { return true }
        return ka.count >= 6 && kb.count >= 6 && (ka.contains(kb) || kb.contains(ka))
    }

    /// Titolo senza le diciture di versione: toglie ogni gruppo fra «()» e «[]» e il suffisso dopo « - » (es. «- Remastered 2011»).
    private static func coreTitle(_ normalizedTitle: String) -> String {
        var t = normalizedTitle
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let a = t.range(of: open), let b = t.range(of: close, range: a.upperBound..<t.endIndex) {
                t.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        if let dash = t.range(of: " - ") { t = String(t[..<dash.lowerBound]) }
        return t.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Artisti compatibili: uguali, uno contenuto nell'altro, o almeno un nome in comune fra quelli separati da «&», «,», «;», «/»,
    /// «feat.», «ft.», «featuring», «with», «and».
    private static func artistsMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        if a.count >= 3, b.count >= 3, a.contains(b) || b.contains(a) { return true }
        func names(_ s: String) -> Set<String> {
            var t = s
            for sep in [" & ", ",", ";", "/", " feat. ", " feat ", " ft. ", " ft ", " featuring ", " with ", " and ", " x "] {
                t = t.replacingOccurrences(of: sep, with: "|")
            }
            return Set(t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 })
        }
        return !names(a).isDisjoint(with: names(b))
    }

    /// Normalizza una stringa per il confronto: minuscolo, spazi ridotti, senza accenti/diacritici
    /// (cosi "Beyoncé" e "Beyonce" si considerano uguali).
    private static func normalized(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// L'API di ricerca di iTunes restituisce sempre un URL a bassa risoluzione (tipicamente
    /// "100x100bb"): sostituendo quella porzione del percorso con una dimensione maggiore si ottiene
    /// la stessa immagine a risoluzione più alta, una tecnica documentata informalmente ma stabile.
    private static func highResolutionURL(from artworkUrl100: String) -> URL? {
        let upgraded = artworkUrl100.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return URL(string: upgraded)
    }

    private func throttle() async {
        if let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            let remaining = Self.minimumRequestInterval - elapsed
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
    }

    // MARK: - Download e compressione

    /// Scarica l'immagine e la ricodifica come JPEG, limitandone il lato maggiore a 600 punti: le
    /// copertine servono solo per lo schermo di un orologio, non serve portare sul dispositivo (e
    /// occupare spazio per) immagini ad alta risoluzione pensate per uno schermo di computer.
    private func downloadAndCompress(_ url: URL) async -> Data? {
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        return Self.compressedJPEG(from: data)
    }

    /// Ricodifica i dati di un'immagine come JPEG con il lato maggiore limitato a 600 punti (usata
    /// anche per le copertine lette dalla cache di Musica, che prima dell'invio vanno ridimensionate).
    static func compressedJPEG(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }

        let maxSide: CGFloat = 600
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let targetSize = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1)
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

/// Sottoinsieme minimo della risposta di `https://itunes.apple.com/search`: solo i campi usati qui.
private struct ITunesSearchResponse: Decodable {
    let results: [Result]

    struct Result: Decodable {
        let artistName: String?
        let trackName: String?
        let trackTimeMillis: Int?
        let artworkUrl100: String?
        let collectionName: String?
    }
}
