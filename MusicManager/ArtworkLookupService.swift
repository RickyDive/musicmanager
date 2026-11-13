// Music Manager
// Copyright (C) 2026 Riccardo Colaiori
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import AppKit

/// Mercato (paese dello store di Apple) usato dalle ricerche online di copertine e miniature. Scelta globale, non per utente: le copertine
/// in cache sono comuni a tutti gli utenti e non devono mescolare risultati di mercati diversi. Chiave vuota = automatico (regione del Mac).
enum ArtworkStore {
    nonisolated static let defaultsKey = "artwork_store_country"

    /// Codice scelto nelle Impostazioni ("" = automatico).
    nonisolated static var chosenCode: String { UserDefaults.standard.string(forKey: defaultsKey) ?? "" }

    /// Regione del Mac, se è un codice paese di due lettere; altrimenti US.
    nonisolated static var automaticCode: String {
        let code = (Locale.current.region?.identifier ?? "").uppercased()
        return code.count == 2 ? code : "US"
    }

    /// Mercato da cui parte la ricerca.
    nonisolated static var primary: String {
        let code = chosenCode.uppercased()
        return code.count == 2 ? code : automaticCode
    }

    /// Mercati da provare, in ordine: quello scelto e poi gli Stati Uniti.
    nonisolated static var searchCountries: [String] { primary == "US" ? ["US"] : [primary, "US"] }

    /// Nome del paese nella lingua del Mac («Italia»).
    nonisolated static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// Paesi proponibili nel menu (codici di due lettere), in ordine alfabetico per nome.
    nonisolated static var selectableCountries: [(code: String, name: String)] {
        Locale.Region.isoRegions.map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .map { ($0, displayName($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

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
        let cleanAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Con l'album noto: la discografia dell'artista (l'indice di ricerca dei brani non contiene tutto lo store, il catalogo
        // dell'artista sì). Poche richieste e la copertina è proprio quella dell'album. Mercato scelto, poi Stati Uniti.
        // Tutte le edizioni con lo stesso nome (originale, Remastered, Deluxe…): ognuna è una copertina fra cui scegliere.
        if !cleanAlbum.isEmpty {
            for url in await discographyAlbumURLs(artist: artist, album: cleanAlbum) where seenURLs.insert(url).inserted {
                scored.append((url, 4, true, order))
                order += 1
            }
        }

        // 2) Ricerche per brano, solo se l'album non è stato trovato: «artista titolo», «titolo album», solo «titolo» ripulito.
        // In ogni giro si cerca nel mercato scelto e si passa agli Stati Uniti solo se il primo non ha dato risultati accettati.
        for round in 0..<3 {
            if scored.contains(where: { $0.albumMatch }) { break }
            let term: String
            switch round {
            case 0: term = "\(artist) \(title)"
            case 1:
                if cleanAlbum.isEmpty { continue }
                term = "\(title) \(cleanAlbum)"
            default:
                // Solo il titolo, ripulito da diciture fra parentesi e punteggiatura: con molte parole (o con «?», virgolette,
                // parentesi) l'API non trova nulla; i risultati si filtrano comunque per artista, titolo, album e durata.
                let simple = Self.simplifiedTerm(title)
                if simple.isEmpty || simple == "\(artist) \(title)" { continue }
                term = simple
            }
            for country in ArtworkStore.searchCountries {
                guard let response = await fetch(term: term, country: country) else {
                    AppLog.debug("Fix Artwork online: ricerca «\(term)» [\(country)]: nessuna risposta")
                    continue
                }
                AppLog.debug("Fix Artwork online: ricerca «\(term)» [\(country)] (album richiesto «\(cleanAlbum)»): \(response.results.count) risultati")
                let before = scored.count
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
                if scored.count > before { break }   // mercato scelto con risultati: non serve l'altro
                if !response.results.isEmpty {
                    let sample = response.results.prefix(4).map { "«\($0.artistName ?? "")» — «\($0.trackName ?? "")» — «\($0.collectionName ?? "")»" }.joined(separator: "; ")
                    AppLog.debug("Fix Artwork online:   nessun risultato accettato su \(response.results.count); primi: \(sample)")
                }
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

    // MARK: - Discografia dell'artista

    /// Memoria della sessione: artista (per paese e nome) → `artistId`, artisti non trovati, album di un artista per paese.
    private var artistIDs: [String: Int] = [:]
    private var artistsNotFound: Set<String> = []
    private var discographies: [String: [ITunesSearchResponse.Result]] = [:]

    /// Copertina dell'album cercata nella discografia dell'artista: 1) ricerca dell'artista (`entity=musicArtist`) e scelta di quello con lo
    /// stesso nome; 2) `lookup?id=…&entity=album` con tutti i suoi album; 3) l'album con lo stesso nome (`albumsMatch`). Mercato scelto
    /// e poi Stati Uniti (riusando l'`artistId` già trovato). La discografia di un artista si legge una volta sola per sessione.
    private func discographyAlbumURLs(artist: String, album: String) async -> [URL] {
        // Nomi da provare, dal più completo al più breve: «Earth, Wind & Fire» è un solo artista (non «Earth»); «A feat. B» si riduce ad «A»;
        // solo in ultimo il primo nome prima di «&», «,», «/».
        let candidates = Self.artistNameCandidates(artist)
        guard !candidates.isEmpty else { return [] }
        let primary = candidates[0]
        var knownID: Int?
        var knownName = primary
        for country in ArtworkStore.searchCountries {
            if knownID == nil {
                for name in candidates {
                    if let id = await artistID(named: name, country: country) { knownID = id; knownName = name; break }
                }
            }
            guard let id = knownID, let albums = await albums(ofArtist: id, country: country) else { continue }
            let named = albums.filter { $0.collectionName != nil }
            // Confronto rigido: l'album omonimo dell'artista («Earth, Wind & Fire») non deve coincidere con «Earth, Wind & Fire - Greatest Hits Live».
            var exact = named.filter { Self.albumsMatchStrict($0.collectionName ?? "", album) }
            // Prima il titolo identico, poi le edizioni (stabile: l'ordine dello store resta a parità).
            exact = exact.filter { Self.normalized($0.collectionName ?? "") == Self.normalized(album) }
                + exact.filter { Self.normalized($0.collectionName ?? "") != Self.normalized(album) }
            let urls = exact.compactMap { $0.artworkUrl100 }.compactMap { Self.highResolutionURL(from: $0) }
            if !urls.isEmpty {
                AppLog.debug("Fix Artwork online: discografia [\(country)]: \(urls.count) album «\(exact.compactMap(\.collectionName).joined(separator: "», «"))» trovati tra \(named.count) album di «\(knownName)»")
                return urls
            }
            AppLog.debug("Fix Artwork online: discografia [\(country)]: nessun album «\(album)» tra \(named.count) album di «\(knownName)»")
        }
        return []
    }

    private func artistID(named primary: String, country: String) async -> Int? {
        let nameKey = Self.artistKey(primary)
        guard !nameKey.isEmpty else { return nil }
        let key = "\(country)|\(nameKey)"
        if let id = artistIDs[key] { return id }
        if artistsNotFound.contains(key) { return nil }
        guard var search = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        search.queryItems = [
            URLQueryItem(name: "term", value: primary),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = search.url, let found = await fetch(url: url) else { return nil }
        if let id = found.results.first(where: { Self.artistKey($0.artistName ?? "") == nameKey })?.artistId {
            artistIDs[key] = id
            return id
        }
        AppLog.debug("Fix Artwork online: discografia [\(country)]: artista «\(primary)» non trovato")
        artistsNotFound.insert(key)
        return nil
    }

    private func albums(ofArtist id: Int, country: String) async -> [ITunesSearchResponse.Result]? {
        let key = "\(country)|\(id)"
        if let cached = discographies[key] { return cached }
        guard var lookup = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
        lookup.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "200"),
        ]
        guard let url = lookup.url, let response = await fetch(url: url) else { return nil }
        discographies[key] = response.results
        return response.results
    }

    /// Chiave del nome di un artista: solo lettere e cifre, minuscole e senza accenti («Earth, Wind & Fire» = «Earth Wind & Fire»).
    private static func artistKey(_ name: String) -> String {
        normalized(name).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { String($0) }.joined()
    }

    /// Nomi con cui cercare l'artista di un brano: il nome intero; senza i collaboratori («feat.», «ft.», «with»…); infine il primo nome
    /// prima di «&», «,», «/». Senza duplicati.
    private static func artistNameCandidates(_ artist: String) -> [String] {
        let full = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return [] }
        var withoutGuests = full
        for sep in [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " with "] {
            if let r = withoutGuests.range(of: sep, options: .caseInsensitive) { withoutGuests = String(withoutGuests[..<r.lowerBound]) }
        }
        var result: [String] = []
        for name in [full, withoutGuests.trimmingCharacters(in: .whitespacesAndNewlines), primaryArtist(full)] {
            if !name.isEmpty, !result.contains(where: { artistKey($0) == artistKey(name) }) { result.append(name) }
        }
        return result
    }

    /// Primo artista di un elenco («A & B», «A, B», «A feat. B»…).
    private static func primaryArtist(_ artist: String) -> String {
        var t = artist
        for sep in [" & ", ",", ";", "/", " feat. ", " feat ", " ft. ", " ft ", " featuring ", " with ", " x "] {
            t = t.replacingOccurrences(of: sep, with: "|", options: .caseInsensitive)
        }
        return (t.components(separatedBy: "|").first ?? t).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Titolo ripulito per una ricerca breve: senza gruppi fra «()» e «[]», senza il suffisso dopo « - » e con la punteggiatura ridotta a spazi.
    private static func simplifiedTerm(_ title: String) -> String {
        let core = coreTitle(normalized(title))
        let cleaned = core.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func fetch(url: URL) async -> ITunesSearchResponse? {
        await throttle()
        guard let data = try? await session.data(from: url).0 else { return nil }
        return try? JSONDecoder().decode(ITunesSearchResponse.self, from: data)
    }

    private func fetch(term: String, country: String) async -> ITunesSearchResponse? {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "country", value: country),
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
            // Punti e apostrofi si tolgono senza lasciare uno spazio: «L.A.» = «LA», «That's» = «Thats» (anche con l'apostrofo tipografico).
            let core = coreTitle(normalized(s)).replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "\u{2019}", with: "")
            let cleaned = core.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            return String(cleaned).components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let ka = key(a), kb = key(b)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        if ka == kb { return true }
        if Set(ka.components(separatedBy: " ")) == Set(kb.components(separatedBy: " ")) { return true }
        return ka.count >= 6 && kb.count >= 6 && (ka.contains(kb) || kb.contains(ka))
    }

    /// Come `albumsMatch` ma senza il confronto per inclusione e togliendo il suffisso dopo « - » solo se è una dicitura di versione
    /// («Remastered», «Deluxe Edition»…), non un sottotitolo («Greatest Hits Live»).
    private static func albumsMatchStrict(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            var t = normalized(s)
            for (open, close) in [("(", ")"), ("[", "]")] {
                while let x = t.range(of: open), let y = t.range(of: close, range: x.upperBound..<t.endIndex) {
                    t.removeSubrange(x.lowerBound..<y.upperBound)
                }
            }
            if let dash = t.range(of: " - ") {
                let suffix = String(t[dash.upperBound...])
                let versionWords = ["remaster", "deluxe", "edition", "expanded", "anniversary", "bonus", "version", "reissue", "mono", "stereo"]
                if versionWords.contains(where: { suffix.contains($0) }) { t = String(t[..<dash.lowerBound]) }
            }
            t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            let cleaned = t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            var words = String(cleaned).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // Articolo iniziale ignorato: «The Best of…» = «Best of…», «Il meglio di…» = «Meglio di…» (solo se resta almeno una parola).
            if words.count > 1, ["the", "a", "an", "il", "lo", "la", "i", "gli", "le", "l", "el", "los", "las", "les", "le", "der", "die", "das"].contains(words[0]) { words.removeFirst() }
            return words.joined(separator: " ")
        }
        let ka = key(a), kb = key(b)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        return ka == kb || Set(ka.components(separatedBy: " ")) == Set(kb.components(separatedBy: " "))
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
        let artistId: Int?
    }
}
