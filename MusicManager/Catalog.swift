import Foundation

/// Ordine delle schede: Playlist, Artisti, Album, Brani (richiesto esplicitamente, uguale sia per
/// Apple Music sia per il dispositivo Garmin, dato che entrambi i pannelli usano CatalogBrowser).
/// "Custom Playlist" (la playlist creata a mano, vedi CatalogBrowser) esiste solo lato Apple Music:
/// non fa parte di `browsable`, cosi non compare né nell'elenco schede del dispositivo né nella
/// scelta "scheda di apertura predefinita" del pannello Impostazioni.
enum CatalogCategory: String, CaseIterable, Identifiable, Hashable {
    case playlists, artists, albums, songs, customPlaylist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlists: return t("category_playlists")
        case .artists: return t("category_artists")
        case .albums: return t("category_albums")
        case .songs: return t("category_songs")
        case .customPlaylist: return t("category_custom_playlist")
        }
    }

    /// Icona della scheda (SF Symbols): la stessa del mini player quando si riproduce da quella sorgente.
    var iconName: String {
        switch self {
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .songs: return "music.note"
        case .customPlaylist: return "square.and.pencil"
        }
    }

    static var browsable: [CatalogCategory] { [.playlists, .artists, .albums, .songs] }
}

/// Un brano visualizzabile sia per la libreria Apple Music sia per il dispositivo Garmin.
protocol CatalogTrack: Identifiable, Hashable {
    var title: String { get }
    var artist: String { get }
    var album: String { get }
    var trailingText: String? { get }
    var warning: String? { get }
    /// Durata in secondi; 0 se sconosciuta.
    var duration: TimeInterval { get }
    /// Artista dell'album (può essere vuoto: allora vale l'artista del brano). Serve alla scheda Artisti.
    var albumArtist: String { get }
    /// true se l'album è una compilation (tag "Compilation"): finisce sotto la voce unica "Compilations".
    var isCompilation: Bool { get }
    /// Numero di traccia nell'album (0 se sconosciuto): ordina i brani dentro l'album.
    var trackNumber: Int { get }
    /// Numero del disco (0 se sconosciuto).
    var discNumber: Int { get }
    /// Numero di dischi dell'album secondo la sorgente (0 se sconosciuto).
    var discCount: Int { get }
    /// true se il brano è stato acquistato su iTunes Store (possibile DRM: riproduzione sul Garmin non garantita).
    var isPurchased: Bool { get }
    /// true se il brano è presente solo sul dispositivo (importato da una playlist del device nella Custom Playlist).
    var isDeviceOnly: Bool { get }
    /// Genere musicale (vuoto se sconosciuto). Serve al filtro per genere delle librerie Apple Music e remote.
    var genre: String { get }
    /// Dimensione del file in byte (0 se sconosciuta). Serve al totale in GB della Custom Playlist.
    var sizeInBytes: Int64 { get }
}

extension CatalogTrack {
    var sizeInBytes: Int64 { 0 }
    var genre: String { "" }
    var isPurchased: Bool { false }
    var isDeviceOnly: Bool { false }
    var albumArtist: String { artist }
    var isCompilation: Bool { false }
    var trackNumber: Int { 0 }
    var discNumber: Int { 0 }
    var discCount: Int { 0 }
}

/// Ordine dei brani dentro un album: disco, numero di traccia (i senza numero in fondo), poi titolo.
func inAlbumOrder<T: CatalogTrack>(_ a: T, _ b: T) -> Bool {
    let da = max(a.discNumber, 1), db = max(b.discNumber, 1)
    if da != db { return da < db }
    let na = a.trackNumber > 0 ? a.trackNumber : Int.max
    let nb = b.trackNumber > 0 ? b.trackNumber : Int.max
    if na != nb { return na < nb }
    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
}

struct TrackGroup<Track: CatalogTrack>: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    /// Tutti i brani del gruppo (con i sottogruppi: la somma dei brani di tutti gli album).
    let tracks: [Track]
    /// Sottogruppi (scheda Artisti: gli album dell'artista, con i loro brani). Vuoto negli altri gruppi.
    var subgroups: [TrackGroup<Track>] = []
}

/// Formatta una durata in secondi come "m:ss" o "h:mm:ss". Stringa vuota se <= 0.
func formatDuration(_ seconds: TimeInterval) -> String {
    guard seconds > 0 else { return "" }
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

/// Sottotitolo condiviso per le playlist: numero di brani ed eventuale durata totale.
/// Usato ovunque venga creato o rifiltrato un TrackGroup di playlist, cosi il formato resta identico.
func playlistSubtitle<T: CatalogTrack>(_ tracks: [T]) -> String {
    // Stesso formato e stesse regole ore/minuti (singolare/plurale) della Custom Playlist.
    customPlaylistSummary(tracks)
}

/// Riepilogo della Custom Playlist come nell'app Musica di Apple: «N brani, X ore e Y minuti» (senza secondi;
/// solo i minuti sotto l'ora, solo le ore se i minuti sono zero). Il totale si arrotonda al minuto più vicino, con
/// un minimo di 1 minuto se la playlist ha una durata.
func customPlaylistSummary<T: CatalogTrack>(_ tracks: [T]) -> String {
    let count = tracks.count
    let seconds = tracks.reduce(0) { $0 + $1.duration }
    let timeText = totalTimeText(seconds)
    return timeText.isEmpty ? t("n_tracks", count) : t("n_tracks_time", count, timeText)
}

/// Durata totale in lettere («1 ora e 5 minuti», «45 minuti», «2 ore»), senza secondi, arrotondata al minuto più vicino
/// (minimo 1 minuto). Stringa vuota se la durata è zero. Condivisa da Custom Playlist, sottotitoli e barra di selezione.
func totalTimeText(_ seconds: TimeInterval) -> String {
    guard seconds > 0 else { return "" }
    let totalMinutes = max(1, Int((seconds / 60).rounded()))
    let h = totalMinutes / 60
    let m = totalMinutes % 60
    let hoursText = h == 1 ? t("duration_hour_one") : t("duration_hours", h)
    let minutesText = m == 1 ? t("duration_minute_one") : t("duration_minutes", m)
    let timeText: String
    if h > 0 && m > 0 { timeText = t("duration_hours_minutes", hoursText, minutesText) }
    else if h > 0 { timeText = hoursText }
    else { timeText = minutesText }
    return timeText
}

/// Elenco testuale (una riga per brano, "Titolo — Artista") per mostrare nel corpo di un alert
/// quali brani risultano duplicati, invece di un semplice conteggio. Tagliato a `limit` righe con
/// un "e altri N" finale, cosi un alert non diventa enorme con decine di brani.
func duplicateTracksListText<T: CatalogTrack>(_ tracks: [T], limit: Int = 8) -> String {
    let shown = tracks.prefix(limit).map { "\($0.title) — \($0.artist)" }
    var lines = shown.joined(separator: "\n")
    if tracks.count > limit {
        lines += "\n" + t("n_more_tracks", tracks.count - limit)
    }
    return lines
}

extension Array where Element: CatalogTrack {
    /// Ordine "di libreria" (artista, poi album, poi titolo) usato come ordine di base dei dati.
    func sortedForLibrary() -> [Element] {
        sorted { a, b in
            let keysA = [a.artist, a.album, a.title]
            let keysB = [b.artist, b.album, b.title]
            for (x, y) in zip(keysA, keysB) {
                let r = x.localizedCaseInsensitiveCompare(y)
                if r != .orderedSame { return r == .orderedAscending }
            }
            return false
        }
    }

    /// Ordine alfabetico per titolo del brano, per la scheda "Brani".
    func sortedAlphabeticallyByTitle() -> [Element] {
        sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Scheda Album: un gruppo per album **e artista dell'album** (due album con lo stesso nome ma di artisti
    /// diversi restano separati); le compilation si raggruppano per solo nome. Brani in ordine di disco e traccia.
    func groupedByAlbum() -> [TrackGroup<Element>] {
        func albumName(_ track: Element) -> String { track.album.isEmpty ? t("unknown_album") : track.album }
        func albumArtist(_ track: Element) -> String {
            let a = track.albumArtist.trimmingCharacters(in: .whitespaces)
            return a.isEmpty ? track.artist : a
        }
        return Dictionary(grouping: self) { track -> String in
            track.isCompilation ? "compilation\u{1}\(albumName(track))" : "\(albumName(track))\u{1}\(albumArtist(track))"
        }
        .map { key, tracks in
            let first = tracks[0]
            let subtitle = first.isCompilation ? t("various_artists") : albumArtist(first)
            return TrackGroup(id: "album:\(key)", title: albumName(first), subtitle: subtitle,
                              tracks: tracks.sorted(by: inAlbumOrder))
        }
        .sorted {
            let r = $0.title.localizedCaseInsensitiveCompare($1.title)
            return r == .orderedSame ? $0.subtitle.localizedCaseInsensitiveCompare($1.subtitle) == .orderedAscending
                                     : r == .orderedAscending
        }
    }

    /// Scheda Artisti: Artista dell'album → Album → Brani dell'album. Le compilation (tag "Compilation")
    /// stanno tutte sotto un'unica voce "Compilations", in cima, con i loro album e brani.
    func groupedByAlbumArtist() -> [TrackGroup<Element>] {
        func albums(_ tracks: [Element], idPrefix: String, subtitle: ([Element]) -> String) -> [TrackGroup<Element>] {
            Dictionary(grouping: tracks) { $0.album.isEmpty ? t("unknown_album") : $0.album }
                .map { name, items in
                    TrackGroup(id: "\(idPrefix)|album:\(name)", title: name, subtitle: subtitle(items),
                               tracks: items.sorted(by: inAlbumOrder))
                }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }

        var result: [TrackGroup<Element>] = Dictionary(grouping: filter { !$0.isCompilation }) { track -> String in
            let albumArtist = track.albumArtist.trimmingCharacters(in: .whitespaces)
            if !albumArtist.isEmpty { return albumArtist }
            return track.artist.isEmpty ? t("unknown_artist") : track.artist
        }
        .map { name, items in
            let subs = albums(items, idPrefix: "artist:\(name)") { playlistSubtitle($0) }
            return TrackGroup(id: "artist:\(name)", title: name, subtitle: t("n_albums_songs", subs.count, subs.flatMap(\.tracks).count),
                              tracks: subs.flatMap(\.tracks), subgroups: subs)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let compilationTracks = filter(\.isCompilation)
        if !compilationTracks.isEmpty {
            let subs = albums(compilationTracks, idPrefix: "compilations") { items in
                let artists = Set(items.map(\.artist))
                return artists.count == 1 ? (artists.first ?? "") : t("various_artists")
            }
            result.insert(TrackGroup(id: "compilations", title: t("compilations"), subtitle: t("n_albums_songs", subs.count, subs.flatMap(\.tracks).count),
                                     tracks: subs.flatMap(\.tracks), subgroups: subs), at: 0)
        }
        return result
    }
}

private func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

extension LocalTrack: CatalogTrack {
    /// Niente dimensione in MB negli elenchi Apple Music: al suo posto c'è l'icona della copertina.
    var trailingText: String? { nil }
    var warning: String? { blockedReason }
    var sizeInBytes: Int64 { Int64(max(0, fileSize)) }
}

extension DeviceTrack: CatalogTrack {
    /// Niente dimensione in MB nemmeno sul dispositivo: nella riga c'è la durata (come negli elenchi Music).
    var trailingText: String? { nil }
    var warning: String? { nil }
    var sizeInBytes: Int64 { Int64(clamping: size) }
}

/// Sorgente da cui si sta riproducendo con un doppio click su un gruppo (o su un suo brano): una
/// playlist, un artista o un album. Serve al mini player (nome, elenco, casuale, ripetizione) e
/// all'elenco (apertura automatica e scorrimento fino al brano in corso).
struct PlaybackSource: Equatable {
    let name: String
    let category: CatalogCategory

    /// Icona mostrata accanto al nome nel mini player.
    var iconName: String { category.iconName }
}


/// Da dove viene la copertina mostrata per un brano di Apple Music.
enum ArtworkOrigin {
    /// Il brano ha la sua copertina (nel file o nella libreria).
    case own
    /// Solo dalla cache di Musica (o da un brano dello stesso album): il file non la contiene.
    case musicCache
    /// Copertina memorizzata nella cache di GMM (confermata in Fix Artwork, oppure salvata all'invio
    /// di un brano con copertina da Apple Music): vedi `ArtworkCache`.
    case gmmCache
    /// Nessuna copertina disponibile.
    case none
}
