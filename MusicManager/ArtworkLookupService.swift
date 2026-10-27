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
    private static let maxCandidates = 5

    /// Restituisce i dati JPEG di tutte le copertine diverse trovate per questo brano (la stessa
    /// canzone compare spesso su album, singoli e raccolte diversi, ciascuno con la sua copertina),
    /// nell'ordine proposto dal servizio; array vuoto se non è stata trovata nessuna copertina
    /// abbastanza simile.
    func search(artist: String, title: String, durationSeconds: TimeInterval) async -> [Data] {
        let urls = await findCandidateURLs(artist: artist, title: title, durationSeconds: durationSeconds)
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

    private func findCandidateURLs(artist: String, title: String, durationSeconds: TimeInterval) async -> [URL] {
        let term = "\(artist) \(title)"
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let url = components.url else { return [] }

        await throttle()
        guard let data = try? await session.data(from: url).0,
              let response = try? JSONDecoder().decode(ITunesSearchResponse.self, from: data) else {
            return []
        }

        let normalizedArtist = Self.normalized(artist)
        let normalizedTitle = Self.normalized(title)

        var urls: [URL] = []
        for result in response.results {
            guard Self.normalized(result.artistName ?? "") == normalizedArtist,
                  Self.normalized(result.trackName ?? "") == normalizedTitle else { continue }
            if durationSeconds > 0, let millis = result.trackTimeMillis {
                let candidateDuration = TimeInterval(millis) / 1000
                guard abs(candidateDuration - durationSeconds) <= Self.durationToleranceSeconds else { continue }
            }
            guard let artworkUrl100 = result.artworkUrl100,
                  let highRes = Self.highResolutionURL(from: artworkUrl100),
                  !urls.contains(highRes) else { continue }
            urls.append(highRes)
            if urls.count >= Self.maxCandidates { break }
        }
        return urls
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
    }
}
