import SwiftUI
import AppKit

/// Vista riutilizzabile: Brani / Album / Artisti / Playlist (+ Custom Playlist lato Apple Music)
/// con ricerca e selezione multipla.
/// Richiesta di «vai a» arrivata da fuori dell'elenco (menu del miniplayer): scheda di destinazione, brano e, per le playlist, l'id.
struct ExternalRevealRequest: Equatable {
    let trackID: String
    let target: CatalogCategory
    var playlistID: String? = nil
    let id = UUID()
}

/// Memoria degli elenchi derivati (brani ordinati, album, artisti): ordinarli e raggrupparli per decine di migliaia di brani
/// costa secondi, e prima si rifaceva a OGNI aggiornamento della vista (cambio scheda, selezione di un brano, ricerca…) per tutte
/// le schede già aperte. Ora si ricalcola solo se cambiano i brani, il filtro per genere o il testo cercato.
/// Classe (non `@Published`): scrivere qui durante il calcolo della vista non provoca altri aggiornamenti.
final class CatalogDerivedCache<Track: CatalogTrack> {
    var songsKey: String?
    var songs: [Track] = []
    var albumsKey: String?
    var albums: [TrackGroup<Track>] = []
    var artistsKey: String?
    var artists: [TrackGroup<Track>] = []
}

struct CatalogBrowser<Track: CatalogTrack>: View {
    /// Finestra stretta: schede senza testo (vedi `compactPane`).
    @Environment(\.compactPane) private var compactPane
    /// Azione extra mostrata solo sulle righe di playlist (es. "Invia all'orologio").
    struct PlaylistAction {
        let title: String
        let perform: (TrackGroup<Track>) -> Void
    }

    /// Azioni del menu contestuale (click destro) sulle righe delle schede Playlist/Artisti/Album/
    /// Brani. Le voci "Select/Deselect" e "Clear all selections" le gestisce il browser stesso (agiscono
    /// sulla selezione); le altre agiscono sulla selezione corrente tramite queste closure, che sono
    /// le stesse dei pulsanti in fondo al pannello — cosi i controlli (duplicati, svuotamento della
    /// Custom Playlist...) sono identici. Nil per non offrire nessun menu (es. lato dispositivo).
    struct RowMenu {
        /// Vero solo con un dispositivo connesso: altrimenti "Send to watch" non compare.
        let canSendToDevice: Bool
        /// Vero solo con la funzione Fix Artwork attiva in Impostazioni: altrimenti non compare.
        let canFixArtwork: Bool
        /// Operazione già in corso: disabilita le voci che avviano un'azione.
        let isBusy: Bool
        let sendToDevice: () -> Void
        let sendToPlaylist: () -> Void
        let fixArtwork: () -> Void
        /// «Trova simili» sui brani indicati (nil = voce non offerta).
        var findSimilar: (([Track]) -> Void)? = nil
    }

    let tracks: [Track]
    let playlists: [TrackGroup<Track>]
    let emptyMessage: String
    @Binding var category: CatalogCategory
    /// Schede già visitate (le loro liste restano in vita per conservare la posizione di scorrimento).
    @State private var visitedCategories: Set<CatalogCategory> = []
    /// Elenchi già calcolati (vedi `CatalogDerivedCache`).
    @State private var derived = CatalogDerivedCache<Track>()
    /// Ultimo brano cliccato nella scheda Brani: punto di partenza della selezione con Maiusc (shift-click).
    @State private var songAnchorID: Track.ID?
    /// Ultima riga o intestazione cliccata nelle schede Album/Artisti/Playlist (chiave di `rangeEntries`): punto di partenza del Maiusc+clic.
    @State private var groupAnchorKey: String?
    /// Selezione a trascinamento nella scheda Brani: stato del gesto in corso (vedi `SongDragSelector`).
    @State private var songDrag: (anchor: Int, selecting: Bool, base: Set<Track.ID>)?
    @Binding var selection: Set<Track.ID>
    var playlistAction: PlaylistAction? = nil
    var rowMenu: RowMenu? = nil
    /// Chiamata quando la scelta nella scheda Playlist coincide con UNA playlist intera (id del gruppo)
    /// o smette di coincidere (nil).
    var onWholePlaylistChange: ((String?) -> Void)? = nil
    /// Cambia ogni volta che una copertina viene confermata o applicata (vedi
    /// `AppViewModel.artworkRevision`): le miniature ricaricano la propria immagine, cosi la
    /// copertina nuova compare subito nell'elenco, sul brano e sull'album.
    var artworkRevision: Int = 0
    /// Recupera la copertina di un brano (dati immagine grezzi), se disponibile. Nil per non
    /// mostrare nessuna miniatura (es. se la fonte non supporta le copertine).
    var artworkProvider: ((Track) async -> Data?)? = nil
    /// Se presente, a destra di ogni brano compare l'icona dell'origine della copertina (al posto
    /// della dimensione del file).
    var artworkOriginProvider: ((Track) async -> ArtworkOrigin)? = nil
    /// Chiamata quando compaiono brani che potrebbero non avere ancora la copertina: si espande un
    /// gruppo (playlist, artista, album) o si selezionano dei brani. Chi la riceve carica quelle mancanti.
    var onRequestArtwork: (([Track], _ manual: Bool) -> Void)? = nil
    var coverFilterCountHandler: ((Int?) -> Void)? = nil
    var dropOverlayActive = false
    /// Se presente, i brani già presenti sul dispositivo mostrano l'icona "inviato all'orologio".
    var isOnDeviceCheck: ((Track) -> Bool)? = nil
    /// Come sopra, per le intestazioni di playlist (file playlist già sul dispositivo).
    /// Se vero, nella scheda Playlist i singoli brani non si selezionano: si sceglie solo la playlist intera
    /// (lato dispositivo, dove una playlist si elimina insieme ai suoi brani).
    var disablesTrackSelectionInPlaylists = false
    /// Chiamata quando cambia l'insieme delle playlist scelte per intero nella scheda Playlist (id dei gruppi).
    var onSelectedPlaylistsChange: (([String]) -> Void)? = nil
    /// Chiamata (con il titolo) quando scegliendo un brano alla volta le righe di una playlist diventano tutte scelte:
    /// la playlist conta come intera e verrà inviata anche come playlist (con il suo .m3u8).
    var onPlaylistCompletedBySongs: ((String) -> Void)? = nil
    /// «Edit in Custom» sulle playlist (solo pannello del dispositivo): importa la playlist nella Custom Playlist.
    var onEditPlaylist: ((TrackGroup<Track>) -> Void)? = nil
    var isPlaylistOnDeviceCheck: ((TrackGroup<Track>) -> Bool)? = nil
    /// Se presente, nelle schede Brani/Album/Artisti i brani inseriti in almeno una playlist mostrano l'icona
    /// `music.note.list` e il menu contestuale offre «Mostra in playlist» (elenco delle playlist che li contengono).
    var playlistsContainingTrack: ((Track) -> [(id: String, title: String)])? = nil
    /// Doppio click su un brano: riceve il brano e la "coda" (gli altri brani dello stesso
    /// contesto in cui si trova — l'intero elenco Brani, oppure il contenuto dell'album, artista
    /// o playlist aperti) da usare per i pulsanti avanti/indietro del mini player. Nil per non
    /// avere nessuna azione sul doppio click (es. lato dispositivo, dove non c'è un player).
    var onPlay: ((Track, [Track], PlaybackSource?) -> Void)? = nil
    /// Brano attualmente caricato nel mini player: la sua riga (e l'intestazione del gruppo che lo
    /// contiene) mostra l'altoparlante azzurro. Nil se nessun brano è in riproduzione.
    var playingTrackID: Track.ID? = nil
    /// Motore di riproduzione: serve all'indicatore animato (play/pausa) del brano in corso.
    var player: PlayerService? = nil
    /// Sorgente (playlist, artista o album) da cui si sta riproducendo: nella scheda corrispondente
    /// quel gruppo viene aperto automaticamente e la lista scorre fino al brano in corso.
    var playingSource: PlaybackSource? = nil
    /// Gruppi (playlist/artisti/album) aperti nelle liste a gruppi, per poterne aprire uno da codice.
    @State private var expandedGroups: Set<String> = []
    /// Schede mostrate nel selettore: `CatalogCategory.browsable` (senza "Custom Playlist") per il
    /// dispositivo, più "Custom Playlist" per Apple Music (vedi `customPlaylist`).
    var availableCategories: [CatalogCategory] = CatalogCategory.browsable
    /// Stato e azioni della scheda "Custom Playlist": nil per non offrirla affatto (es. lato
    /// dispositivo).
    var customPlaylist: CustomPlaylistConfig<Track>? = nil
    /// Contenuto che il pannello vuole in cima alla zona trasparente (titolo, mini player...), sopra
    /// il selettore delle schede; e barra dei pulsanti in fondo. Si impostano con `topAccessory` /
    /// `bottomBar`: l'elenco scorre sotto entrambe (Liquid Glass, vedi `glassBars`).
    var topAccessoryView: AnyView? = nil
    var bottomBarView: AnyView? = nil
    /// Controlli del pannello che stanno sulla STESSA riga della ricerca, a destra: la ricerca si
    /// restringe fino al primo di essi. Si imposta con `searchAccessory`.
    var searchAccessoryView: AnyView? = nil
    /// Disattiva schede, ricerca e controlli del pannello (dispositivo senza musica).
    var controlsAreDisabled = false
    /// Vista allineata a destra sulla riga delle schede (es. il selettore della libreria).
    var categoryAccessoryView: AnyView? = nil
    /// Ricerca nella barra del titolo: se presente, il testo sta nel view model e il pannello non ha più il suo campo.
    var externalSearch: Binding<String>? = nil
    var externalCustomSearch: Binding<String>? = nil
    @State private var localSearch = ""
    private var search: String {
        get { externalSearch?.wrappedValue ?? localSearch }
        nonmutating set { if let externalSearch { externalSearch.wrappedValue = newValue } else { localSearch = newValue } }
    }
    private var searchBinding: Binding<String> { Binding(get: { search }, set: { search = $0 }) }
    /// Filtro per genere musicale (menu accanto alla ricerca), attivo solo se il pannello lo abilita con `genreFilter()`.
    /// Nil = tutti i generi; la chiave è il genere senza maiuscole/spazi ("" = brani senza genere).
    var genreFilterEnabled = false
    /// Posizionamento da tastiera solo sulla prima lettera (librerie remote e su unità esterne, dove ogni scorrimento è lento).
    var typeAheadFirstLetterOnly = false
    @State private var genreKey: String?
    @State private var genreList: [GenreEntry] = []
    struct GenreEntry: Hashable { let key: String; let name: String; let count: Int }
    /// Ricerca della Custom Playlist: indipendente da quella di Playlist/Artisti/Album/Brani e valida solo dentro la Custom.
    @State private var localCustomSearch = ""
    private var customSearch: String {
        get { externalCustomSearch?.wrappedValue ?? localCustomSearch }
        nonmutating set { if let externalCustomSearch { externalCustomSearch.wrappedValue = newValue } else { localCustomSearch = newValue } }
    }
    private var customSearchBinding: Binding<String> { Binding(get: { customSearch }, set: { customSearch = $0 }) }
    /// Ricerca «a digitazione» negli elenchi (Brani, Album, Artisti): testo digitato finora, istante dell'ultimo tasto e
    /// contatore che annulla il timer di azzeramento.
    @State private var typeAheadText = ""
    @State private var typeAheadLast = Date.distantPast
    @State private var typeAheadGeneration = 0
    /// Ultimo tasto intercettato da AppKit (la `List` di macOS è una tabella AppKit: `onKeyPress` di SwiftUI non riceve i tasti).
    @State private var typeAheadEvent: TypeAheadEvent?
    @State private var typeAheadMonitor = TypeAheadMonitor()
    /// Richiesta «Vai all'album / all'artista» dalla scheda Brani: la scheda di arrivo apre i gruppi e scorre al brano.
    struct RevealRequest: Equatable {
        let trackID: Track.ID
        /// Se presente, la richiesta riguarda la scheda Playlist: id della playlist da aprire («Mostra in playlist»).
        var playlistID: String? = nil
        let id = UUID()
    }
    @State private var revealRequest: RevealRequest?
    /// Richieste «vai a» dal miniplayer (vedi `ExternalRevealRequest`).
    var externalRevealBinding: Binding<ExternalRevealRequest?>? = nil
    /// Riga (id di scorrimento) evidenziata per un attimo dopo «Mostra in playlist»; indipendente dalla selezione.
    @State private var flashRowID: String?
    /// Accesso alla tabella AppKit della lista Playlist, per scorrere a una riga annidata (vedi `ListScrollHandle`).
    @State private var scrollHandle = ListScrollHandle()
    /// Lettera in sovrimpressione accanto al cursore di scorrimento (Brani, Album, Artisti): un tracker per elenco.
    @State private var songsLetters = ScrollLetterTracker()
    /// Filtro della scheda Brani «Mostra solo brani senza copertina» (voce del menu contestuale).
    @State private var onlyWithoutCover = false
    /// Esito della scansione delle copertine per brano: true = senza copertina.
    @State private var coverScan: [Track.ID: Bool] = [:]
    @State private var coverScanTask: Task<Void, Never>?
    @State private var isScanningCovers = false
    @State private var albumsLetters = ScrollLetterTracker()
    @State private var artistsLetters = ScrollLetterTracker()
    /// Selezione nativa (indipendente da `selection`) della scheda Custom Playlist: deve essere la
    /// selezione VERA della List (non una copia tenuta a mano), perché solo cosi trascinando una
    /// riga selezionata il riordino nativo (`.onMove`) sposta insieme tutte le righe selezionate,
    /// non solo quella toccata. Colorata con `AppSettings.highlightColor` via `.listRowBackground`
    /// invece dell'evidenziazione blu di sistema, come nelle altre schede.
    @State private var customPlaylistSelection = Set<UUID>()
    /// Riga radice della Custom Playlist aperta/chiusa.
    @State private var customExpanded = true
    /// Colore di sfondo delle righe selezionate (scelto in Impostazioni con un color picker).
    @ObservedObject private var settings = AppSettings.shared

    init(tracks: [Track],
         playlists: [TrackGroup<Track>],
         category: Binding<CatalogCategory>,
         selection: Binding<Set<Track.ID>>,
         emptyMessage: String,
         playlistAction: PlaylistAction? = nil,
         rowMenu: RowMenu? = nil,
         artworkRevision: Int = 0,
         artworkProvider: ((Track) async -> Data?)? = nil,
         artworkOriginProvider: ((Track) async -> ArtworkOrigin)? = nil,
         onPlay: ((Track, [Track], PlaybackSource?) -> Void)? = nil,
         playingTrackID: Track.ID? = nil,
         player: PlayerService? = nil,
         playingSource: PlaybackSource? = nil,
         availableCategories: [CatalogCategory] = CatalogCategory.browsable,
         customPlaylist: CustomPlaylistConfig<Track>? = nil) {
        self.tracks = tracks
        self.playlists = playlists
        self.emptyMessage = emptyMessage
        self._category = category
        self._selection = selection
        self.playlistAction = playlistAction
        self.rowMenu = rowMenu
        self.artworkRevision = artworkRevision
        self.artworkProvider = artworkProvider
        self.artworkOriginProvider = artworkOriginProvider
        self.onPlay = onPlay
        self.playingTrackID = playingTrackID
        self.player = player
        self.playingSource = playingSource
        self.availableCategories = availableCategories
        self.customPlaylist = customPlaylist
    }

    func externalReveal(_ binding: Binding<ExternalRevealRequest?>) -> Self {
        var copy = self
        copy.externalRevealBinding = binding
        return copy
    }

    /// Esegue una richiesta del miniplayer: stessa procedura delle voci del menu sui brani.
    private func handleExternalReveal(_ request: ExternalRevealRequest?) {
        guard let request else { return }
        externalRevealBinding?.wrappedValue = nil
        guard let track = tracks.first(where: { "\($0.id)" == request.trackID }) else { return }
        if let playlistID = request.playlistID { revealInPlaylist(track, playlistID: playlistID) }
        else { reveal(track, in: request.target) }
    }

    func controlsDisabled(_ disabled: Bool) -> Self {
        var copy = self
        copy.controlsAreDisabled = disabled
        return copy
    }

    func trackSelectionInPlaylistsDisabled() -> Self {
        var copy = self
        copy.disablesTrackSelectionInPlaylists = true
        return copy
    }

    func onEditPlaylist(_ handler: @escaping (TrackGroup<Track>) -> Void) -> Self {
        var copy = self
        copy.onEditPlaylist = handler
        return copy
    }

    func onSelectedPlaylistsChange(_ handler: @escaping ([String]) -> Void) -> Self {
        var copy = self
        copy.onSelectedPlaylistsChange = handler
        return copy
    }

    func onPlaylistCompletedBySongs(_ handler: @escaping (String) -> Void) -> Self {
        var copy = self
        copy.onPlaylistCompletedBySongs = handler
        return copy
    }

    func onPlaylistDeviceCheck(_ check: @escaping (TrackGroup<Track>) -> Bool) -> Self {
        var copy = self
        copy.isPlaylistOnDeviceCheck = check
        return copy
    }

    func onPlaylistMembership(_ lookup: @escaping (Track) -> [(id: String, title: String)]) -> Self {
        var copy = self
        copy.playlistsContainingTrack = lookup
        return copy
    }

    func onDeviceCheck(_ check: @escaping (Track) -> Bool) -> Self {
        var copy = self
        copy.isOnDeviceCheck = check
        return copy
    }

    func wholePlaylistSelection(_ handler: @escaping (String?) -> Void) -> Self {
        var copy = self
        copy.onWholePlaylistChange = handler
        return copy
    }

    /// Quanti brani risultano senza copertina mentre il filtro «senza copertina» è attivo (nil = filtro spento).
    /// Copre l'elenco (non le barre) con un velo grigio e un simbolo: trascinamento di file sul pannello.
    func dropOverlay(_ active: Bool) -> Self {
        var copy = self
        copy.dropOverlayActive = active
        return copy
    }

    func onCoverFilterCount(_ handler: @escaping (Int?) -> Void) -> Self {
        var copy = self
        copy.coverFilterCountHandler = handler
        return copy
    }

    func onRequestArtwork(_ handler: @escaping ([Track], _ manual: Bool) -> Void) -> Self {
        var copy = self
        copy.onRequestArtwork = handler
        return copy
    }

    func topAccessory<V: View>(@ViewBuilder _ view: () -> V) -> Self {
        var copy = self
        copy.topAccessoryView = AnyView(view())
        return copy
    }

    /// La ricerca sta nella barra del titolo: il testo (e quello della Custom Playlist, se c'è) arriva da fuori.
    func toolbarSearch(_ text: Binding<String>, custom: Binding<String>? = nil) -> Self {
        var copy = self
        copy.externalSearch = text
        copy.externalCustomSearch = custom
        return copy
    }

    /// Posizionamento da tastiera solo sulla prima lettera digitata (le altre, entro il secondo, sono ignorate).
    func typeAheadFirstLetterOnly(_ value: Bool) -> Self {
        var copy = self
        copy.typeAheadFirstLetterOnly = value
        return copy
    }

    /// Abilita il menu «Genere» accanto alla ricerca (usa `CatalogTrack.genre`).
    func genreFilter() -> Self {
        var copy = self
        copy.genreFilterEnabled = true
        return copy
    }

    func searchAccessory<V: View>(@ViewBuilder _ view: () -> V) -> Self {
        var copy = self
        copy.searchAccessoryView = AnyView(view())
        return copy
    }

    func categoryAccessory<V: View>(@ViewBuilder _ view: () -> V) -> Self {
        var copy = self
        copy.categoryAccessoryView = AnyView(view())
        return copy
    }

    func bottomBar<V: View>(@ViewBuilder _ view: () -> V) -> Self {
        var copy = self
        copy.bottomBarView = AnyView(view())
        return copy
    }

    var body: some View {
        // L'elenco è la vista principale (a tutta altezza); selettore, ricerca e l'eventuale
        // contenuto del pannello stanno nella barra trasparente in alto, i pulsanti in quella in basso.
        content
            .onChange(of: externalRevealBinding?.wrappedValue) { _, new in handleExternalReveal(new) }
            .overlay {
                if dropOverlayActive {
                    ZStack {
                        Rectangle().fill(Color(white: 0.5).opacity(0.88))
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(.white.opacity(0.9))
                            // Oscillazione ripetuta con 1 secondo di pausa, direzione predefinita.
                            .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 1.0)), isActive: dropOverlayActive)
                    }
                    .allowsHitTesting(false)
                }
            }
            // Selezionando dei brani (clic) si caricano le loro copertine mancanti; una selezione enorme
            // (es. «seleziona tutto») è ignorata, per non avviare letture lunghissime.
            .onChange(of: selection) { old, new in
                // Scegliendo un brano si tenta soltanto il caricamento della copertina da Music (se attivo in
                // Impostazioni). Fix Artwork (ricerca online) NON si apre da solo: resta nel menu del click destro.
                if onlyWithoutCover { return }
                guard settings.autoLoadAppleArtwork, let request = onRequestArtwork else { return }
                let added = new.subtracting(old)
                guard !added.isEmpty, added.count <= 60 else { return }
                request(tracks.filter { added.contains($0.id) }, false)
            }
            .glassBars {
                VStack(alignment: .leading, spacing: 2) {
                    if let topAccessoryView { topAccessoryView }
                    controls
                }
            } bottom: {
                if let bottomBarView { bottomBarView }
            }
            // Tolto un brano da una playlist scelta per intero (scheda Playlist): la playlist non verrà più inviata come playlist.
            .alert(t("alert_playlist_removal_title"), isPresented: Binding(
                get: { pendingRowRemoval != nil },
                set: { _ in }   // la chiusura la gestiscono i due pulsanti
            )) {
                Button(t("button_confirm")) { pendingRowRemoval = nil }
                Button(t("button_cancel"), role: .cancel) {
                    if let pending = pendingRowRemoval { playlistPicks = pending.previousPicks }
                    pendingRowRemoval = nil
                }
            } message: {
                if let pending = pendingRowRemoval {
                    Text(playlistRemovalMessage(subject: pending.subject, plural: pending.plural, playlists: pending.titles))
                }
            }
    }

    /// Larghezza di ogni scheda del selettore: quella della dicitura più lunga fra tutte le schede
    /// (nella lingua corrente, di norma "Custom Playlist") più il margine interno.
    private static var categorySegmentWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = CatalogCategory.allCases
            .map { ($0.title as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        // + margine interno + icona (con il suo spazio) a sinistra della dicitura
        return ceil(widest) + 17 + 17
    }

    /// Barra delle schede con icona + dicitura. Costruita a mano (non con il `Picker` segmentato):
    /// su macOS il controllo a segmenti di sistema ignora l'icona delle `Label`. Allineata a sinistra,
    /// ogni scheda larga quanto la più lunga: stessa misura in Apple Music (5 schede) e nel Device (4).
    private var categoryBar: some View {
        let width = compactPane ? 38 : Self.categorySegmentWidth
        return HStack(spacing: 0) {
            ForEach(availableCategories) { c in
                // "Custom" non è una vista della libreria come le altre quattro: un piccolo
                // distacco (spazio + sottile separatore) la stacca dal gruppo.
                if c == .customPlaylist, c != availableCategories.first {
                    Rectangle()
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 8)
                }
                Button { category = c } label: {
                    HStack(spacing: 5) {
                        Image(systemName: c.iconName)
                        if !compactPane { Text(c.title).lineLimit(1) }
                    }
                    .help(c.title)
                    .frame(width: width, height: 24)
                    .background(category == c ? Color.primary.opacity(0.14) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(category == c ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }

    /// Selettore delle schede + ricerca (o nome/ordinamento nella Custom Playlist).
    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Schede e filtro genere si disattivano (dispositivo senza musica); il controllo a destra
                // (`categoryAccessory`: libreria, Eject, Connetti…) resta sempre attivo.
                Group {
                    categoryBar
                    // Filtro per genere: attaccato a destra delle schede (Custom compresa), non più sulla riga della ricerca.
                    if genreFilterEnabled, category != .customPlaylist, !genreList.isEmpty { genreMenu }
                    // Ordinamento della Custom Playlist: stesso tipo di pulsante del filtro genere, subito dopo le schede.
                    if category == .customPlaylist, let customPlaylist { sortMenu(customPlaylist) }
                }
                .disabled(controlsAreDisabled)
                Spacer(minLength: 4)
                if let categoryAccessoryView { categoryAccessoryView.fixedSize() }
            }

            // Ricerca + (a destra) i controlli del pannello: la ricerca occupa lo spazio che resta.
            // Nella Custom Playlist il menu "Ordina per" sta tra la ricerca e i controlli.
            HStack(spacing: 10) {
                // Due testi separati: quello delle schede del catalogo (condiviso, segue il cambio di scheda) e quello della Custom.
                if externalSearch == nil {
                    GlassSearchField(prompt: t("search_placeholder"), text: category == .customPlaylist ? customSearchBinding : searchBinding)
                        .id(category == .customPlaylist)   // campo nuovo al passaggio catalogo ↔ Custom: niente testo residuo
                }
                if let searchAccessoryView { searchAccessoryView.fixedSize() }
            }
            .disabled(controlsAreDisabled)
        }
        .onAppear { rebuildGenres() }
        .onChange(of: tracks.count) { _, _ in rebuildGenres() }
        .onChange(of: tracks.last?.id) { _, _ in rebuildGenres() }
    }

    // MARK: Filtro per genere

    private static func genreKey(of track: Track) -> String {
        track.genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Elenco dei generi presenti con il numero di brani; se il genere scelto non esiste più (altra libreria) il filtro si azzera.
    private func rebuildGenres() {
        guard genreFilterEnabled else { return }
        var counts: [String: (name: String, count: Int)] = [:]
        for track in tracks {
            let key = Self.genreKey(of: track)
            if var entry = counts[key] { entry.count += 1; counts[key] = entry }
            else { counts[key] = (track.genre.trimmingCharacters(in: .whitespacesAndNewlines), 1) }
        }
        genreList = counts.map { GenreEntry(key: $0.key, name: $0.value.name, count: $0.value.count) }
            .sorted {
                if ($0.key.isEmpty) != ($1.key.isEmpty) { return !$0.key.isEmpty }   // «senza genere» in fondo
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        if let genreKey, !genreList.contains(where: { $0.key == genreKey }) { self.genreKey = nil }
    }

    /// «Ordina per» della Custom Playlist come pulsante a menu con icona (come il filtro genere): grigia con l'ordine manuale,
    /// blu quando la playlist è ordinata (criterio nel tooltip e con la spunta nel menu). Prima era un menu a tendina con etichetta.
    private func sortMenu(_ customPlaylist: CustomPlaylistConfig<Track>) -> some View {
        let current = customPlaylist.sortOption
        return Menu {
            ForEach(CustomPlaylistSortOption.allCases.filter { $0 != .random }) { option in
                Toggle(option.title, isOn: Binding(get: { current == option }, set: { _ in customPlaylist.onSort(option) }))
            }
            Divider()
            Toggle(CustomPlaylistSortOption.random.title,
                   isOn: Binding(get: { current == .random }, set: { _ in customPlaylist.onSort(.random) }))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(current == .manual ? Color.secondary : Color.blue)
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .help(current == .manual ? t("sort_by_label") : t("sort_by_label") + ": " + current.title)
    }

    private var genreMenu: some View {
        let active = genreList.first { $0.key == genreKey }
        return Menu {
            // Toggle: nei menu di macOS è l'unico modo affidabile per avere la spunta sulla voce scelta.
            Toggle(t("genre_all"), isOn: Binding(get: { genreKey == nil }, set: { _ in genreKey = nil }))
            Divider()
            ForEach(genreList, id: \.key) { entry in
                let title = (entry.key.isEmpty ? t("genre_none") : entry.name) + " (\(entry.count))"
                Toggle(title, isOn: Binding(get: { genreKey == entry.key }, set: { _ in genreKey = entry.key }))
            }
        } label: {
            HStack(spacing: 4) {
                // Sempre la stessa icona (senza riempimento): grigia senza filtro, blu con il filtro applicato.
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(active == nil ? Color.secondary : Color.blue)
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(category == .playlists)
        // Solo l'icona (le descrizioni lunghe spingevano gli altri controlli fuori dal pannello): con il filtro attivo il tooltip
        // riporta solo il genere scelto; nel menu la voce scelta ha la spunta.
        .help(active.map { $0.key.isEmpty ? t("genre_none") : $0.name } ?? t("tooltip_genre_filter"))
    }

    /// Brani che passano il filtro per genere (tutti se non è attivo).
    private var scopedTracks: [Track] {
        guard let genreKey else { return tracks }
        return tracks.filter { Self.genreKey(of: $0) == genreKey }
    }

    // MARK: Contenuto

    /// Schede già aperte: le loro liste restano in vita (nascoste) cambiando scheda, così al ritorno
    /// la posizione di scorrimento è quella di prima (utile dopo «Vai all'Album/Artista»).
    private func isLive(_ c: CatalogCategory) -> Bool { category == c || visitedCategories.contains(c) }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if isLive(.songs) {
                songsList
                    .opacity(category == .songs ? 1 : 0)
                    .allowsHitTesting(category == .songs)
                    .accessibilityHidden(category != .songs)
            }
            if isLive(.albums) {
                groupList(filteredAlbums, listCategory: .albums, showArtwork: true)
                    .opacity(category == .albums ? 1 : 0)
                    .allowsHitTesting(category == .albums)
                    .accessibilityHidden(category != .albums)
            }
            if isLive(.artists) {
                groupList(filteredArtists, listCategory: .artists)
                    .opacity(category == .artists ? 1 : 0)
                    .allowsHitTesting(category == .artists)
                    .accessibilityHidden(category != .artists)
            }
            if isLive(.playlists) {
                groupList(filteredPlaylists, listCategory: .playlists, isPlaylists: true)
                    .opacity(category == .playlists ? 1 : 0)
                    .allowsHitTesting(category == .playlists)
                    .accessibilityHidden(category != .playlists)
            }
            if category == .customPlaylist, let customPlaylist {
                customPlaylistView(customPlaylist)
            }
        }
        .onAppear {
            visitedCategories.insert(category)
            typeAheadMonitor.enabled = [.songs, .albums, .artists].contains(category)
            typeAheadMonitor.hasText = !typeAheadText.isEmpty
            typeAheadMonitor.firstLetterOnly = typeAheadFirstLetterOnly
            let monitor = typeAheadMonitor
            typeAheadMonitor.install { kind, characters in
                monitor.counter += 1
                typeAheadEvent = TypeAheadEvent(id: monitor.counter, kind: kind, characters: characters)
            }
        }
        .onDisappear { typeAheadMonitor.remove() }
        .onChange(of: typeAheadText) { _, text in typeAheadMonitor.hasText = !text.isEmpty }
        .onChange(of: typeAheadFirstLetterOnly) { _, value in typeAheadMonitor.firstLetterOnly = value }
        .onChange(of: category) { _, new in
            visitedCategories.insert(new)
            typeAheadText = ""
            typeAheadMonitor.text = ""
            typeAheadMonitor.enabled = [.songs, .albums, .artists].contains(new)
        }
    }

    @ViewBuilder
    private var songsList: some View {
            let items = sortedFilteredSongs
            ScrollViewReader { proxy in
            // Lista SENZA selezione nativa: la selezione la gestiamo noi (click sulla riga = seleziona/deseleziona il brano,
            // si somma alle altre; un click fuori dalle righe non la azzera). Il colore di selezione è già disegnato a mano.
            List {
            GlassInsetRow(edge: .top)
            ForEach(items) { track in
                // Scritta "Select"/"Deseleziona" esplicita a destra del brano, cosi non serve
                // conoscere il comando/shift-click per selezionare più brani da inviare
                // all'orologio o aggiungere alla Custom Playlist: è lo stesso schema già usato per
                // i gruppi (Album/Artisti/Playlist).
                trackRow(track) {
                    // Brano non selezionabile (es. solo nel cloud): il riquadro resta invisibile, per mantenere
                    // l'incolonnamento, e non risponde al click.
                    SelectToggleIcon(state: selection.contains(track.id) ? .all : .none, hidden: track.warning != nil) {
                        toggleSelection(track.id)
                    }
                }
                // Nell'elenco Brani le righe non sono annidate in un gruppo: senza questo margine l'altoparlante del
                // brano in riproduzione, che sta a sinistra del titolo, verrebbe tagliato dal bordo della riga.
                .padding(.leading, 18)
                .tag(track.id)
                .selectionDisabled(track.warning != nil)
                .contentShape(Rectangle())
                // simultaneousGesture (non onTapGesture): cosi il doppio click per avviare la
                // riproduzione non "consuma" il click, e il click singolo continua a selezionare
                // la riga nella List come sempre (serve per "Invia all'orologio").
                // Click singolo: come il riquadro a destra, inverte la selezione del brano (senza toccare gli altri).
                // Il doppio click si riconosce a mano (`ClickTracker`): con `TapGesture(count: 2)` accanto al click
                // singolo, la selezione cambia la riga dopo il primo click e il secondo non veniva più contato.
                .simultaneousGesture(TapGesture().onEnded {
                    if NSEvent.modifierFlags.contains(.shift), let anchorID = songAnchorID,
                       let a = items.firstIndex(where: { $0.id == anchorID }), let b = items.firstIndex(where: { $0.id == track.id }) {
                        // Maiusc + click: tutti i brani tra l'ultimo cliccato e questo, con lo stesso stato (selezionati o no) dell'ultimo cliccato.
                        let ids = items[min(a, b)...max(a, b)].filter { $0.warning == nil }.map(\.id)
                        if selection.contains(anchorID) { selection.formUnion(ids) } else { selection.subtract(ids) }
                        return
                    }
                    if track.warning == nil { toggleSelection(track.id) }
                    songAnchorID = track.id
                    if ClickTracker.isDouble("s:\(track.id)") { onPlay?(track, items, nil) }
                })
                // Sfondo evidenziato (colore scelto in Impostazioni) quando il brano è selezionato.
                .listRowBackground(selection.contains(track.id) ? rowHighlight(settings.highlightColor) : nil)
                .contextMenu {
                    contextMenuItems(isSelected: selection.contains(track.id), artworkTracks: { tracks.filter { selection.contains($0.id) || $0.id == track.id } }, goTo: track, membershipTrack: track, similarSeeds: [track], full: true, focusTrack: track, sendIDs: { menuSendIDs(for: track) }) { if track.warning == nil { toggleSelection(track.id) } }
                }
            }
            GlassInsetRow(edge: .bottom)
            }
            .listStyle(.inset)
            // Trascinamento col tasto premuto: seleziona (o deseleziona, se si parte da un brano già selezionato) le righe
            // tra quella di partenza e quella sotto il cursore; la lista scorre da sola ai bordi. Gestito sulla tabella AppKit.
            .background(SongDragSelector(onDrag: { anchor, current in dragSelectSongs(anchor: anchor, current: current, items: items) },
                                         onEnd: { songDrag = nil }))
            .background(HideNativeSelection())   // la selezione si vede solo col colore scelto, non col blu di sistema
        .scrollContentBackground(.hidden)
            .background {
                ScrollLetterLocator(tracker: songsLetters, rowCounts: [items.count + 2]) { row, _ in
                    guard !items.isEmpty else { return nil }
                    return Self.initial(of: items[max(0, min(row - 1, items.count - 1))].title)
                }
            }
            .overlay { ScrollLetterBubble(model: songsLetters.model, typed: typeAheadText) }
            .overlay { emptyOverlay(items.isEmpty && !isScanningCovers) }
            .overlay(alignment: .top) {
                if isScanningCovers { ProgressView().controlSize(.small).padding(8) }
            }
            .onChange(of: onlyWithoutCover) { _, _ in rescanCovers() }
            .onChange(of: tracks.count) { _, _ in if onlyWithoutCover { rescanCovers() } }
            // Una copertina caricata/confermata: si ricontrollano solo i brani ancora «senza» e il filtro si riapplica
            // (il brano che ora ha la copertina esce dall'elenco, il conteggio scende).
            .onChange(of: artworkRevision) { _, _ in if onlyWithoutCover { rescanCovers(incremental: true) } }
            .onChange(of: withoutCoverCount) { _, new in coverFilterCountHandler?(new) }
            .onChange(of: typeAheadEvent) { _, event in
                guard category == .songs, let event else { return }
                handleTypeAhead(event, entries: items.map { ($0.id, $0.title) }, rowOffset: Self.typeAheadSongRowOffset, proxy: proxy)
            }
            }
    }

    /// Posizionamento da tastiera: digitando alcune lettere la lista scorre fino alla voce che inizia così (o più simile:
    /// quella con più caratteri iniziali in comune). Non cambia la selezione. Un secondo di pausa azzera il testo digitato;
    /// Esc e Cancella lo azzerano / ne tolgono l'ultima lettera. Maiuscole e accenti sono ignorati.
    /// I tasti arrivano da `TypeAheadMonitor` (AppKit), che decide già quali intercettare.
    private func handleTypeAhead<ID: Hashable>(_ event: TypeAheadEvent, entries: [(ID, String)], rowOffset: Int, proxy: ScrollViewProxy) {
        var typed = typeAheadText
        switch event.kind {
        case .escape:
            typeAheadText = ""
            typeAheadMonitor.text = ""
            return
        case .delete, .character:
            typed = event.characters   // il testo completo lo compone `TypeAheadMonitor` al momento del tasto
        }
        typeAheadLast = Date()
        typeAheadText = typed
        scheduleTypeAheadReset()
        scrollToBestMatch(entries, text: typed, rowOffset: rowOffset, proxy: proxy)
    }

    private func scheduleTypeAheadReset() {
        typeAheadGeneration += 1
        let generation = typeAheadGeneration
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if generation == typeAheadGeneration { typeAheadText = ""; typeAheadMonitor.text = "" }
        }
    }

    /// Scorre in modo che la voce trovata resti visibile sotto i pannelli sovrapposti alla lista (stessa tecnica di
    /// «Vai all'Album/Artista»): si porta in cima la voce che sta `rowOffset` posizioni prima.
    private func scrollToBestMatch<ID: Hashable>(_ entries: [(ID, String)], text: String, rowOffset: Int, proxy: ScrollViewProxy) {
        func norm(_ text: String) -> String {
            text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
        }
        let typed = Array(norm(text))
        guard !typed.isEmpty else { return }
        var bestIndex: Int?
        var bestLength = 0
        for (index, (_, title)) in entries.enumerated() {
            let candidate = Array(norm(title))
            var n = 0
            while n < typed.count, n < candidate.count, candidate[n] == typed[n] { n += 1 }
            if n > bestLength {
                bestLength = n
                bestIndex = index
                if n == typed.count { break }   // prima voce che inizia con tutto il testo digitato
            }
        }
        if let bestIndex { proxy.scrollTo(entries[max(0, bestIndex - rowOffset)].0, anchor: .top) }
    }

    /// Aggiorna la selezione durante il trascinamento nella scheda Brani. `anchor`/`current`: indici nell'elenco.
    private func dragSelectSongs(anchor: Int, current: Int, items: [Track]) {
        guard !items.isEmpty else { return }
        if songDrag == nil {
            let a = max(0, min(anchor, items.count - 1))
            songDrag = (a, !selection.contains(items[a].id), selection)
            songAnchorID = items[a].id
        }
        guard let drag = songDrag else { return }
        let c = max(0, min(current, items.count - 1))
        let range = items[min(drag.anchor, c)...max(drag.anchor, c)].filter { $0.warning == nil }.map(\.id)
        selection = drag.selecting ? drag.base.union(range) : drag.base.subtracting(range)
    }

    private func toggleSelection(_ id: Track.ID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    // MARK: Selezione a intervallo (Maiusc + clic) nelle schede a gruppi

    /// Riga visibile di una scheda a gruppi: intestazione (`track == nil`) o brano di un gruppo aperto.
    private struct RangeEntry {
        let key: String
        let group: TrackGroup<Track>
        let track: Track?
    }

    private func currentGroups() -> [TrackGroup<Track>] {
        switch category {
        case .albums: return filteredAlbums
        case .artists: return filteredArtists
        case .playlists: return filteredPlaylists
        default: return []
        }
    }

    /// Righe nell'ordine in cui compaiono: intestazione del gruppo, poi (se aperto) i suoi brani o i suoi album con i relativi brani.
    private func rangeEntries(_ groups: [TrackGroup<Track>], isPlaylists: Bool) -> [RangeEntry] {
        let rowsSelectable = !(isPlaylists && disablesTrackSelectionInPlaylists)
        var out: [RangeEntry] = []
        for g in groups {
            out.append(RangeEntry(key: "g:\(g.id)", group: g, track: nil))
            guard expandedGroups.contains(g.id) else { continue }
            if g.subgroups.isEmpty {
                if rowsSelectable { for t in g.tracks { out.append(RangeEntry(key: rowScrollID(g.id, t.id), group: g, track: t)) } }
            } else {
                for a in g.subgroups {
                    out.append(RangeEntry(key: "g:\(a.id)", group: a, track: nil))
                    guard expandedGroups.contains(a.id) else { continue }
                    for t in a.tracks { out.append(RangeEntry(key: rowScrollID(a.id, t.id), group: a, track: t)) }
                }
            }
        }
        return out
    }

    /// Da chiamare dopo il clic su un'intestazione (`track == nil`) o su un brano. Con Maiusc premuto e un punto di
    /// partenza valido applica a tutte le righe tra le due lo stato del punto di partenza e restituisce true
    /// (il chiamante non deve invertire la selezione). Altrimenti memorizza la riga come nuovo punto di partenza.
    private func handleRangeClick(group: TrackGroup<Track>, track: Track?, isPlaylists: Bool) -> Bool {
        let key = track.map { rowScrollID(group.id, $0.id) } ?? "g:\(group.id)"
        if NSEvent.modifierFlags.contains(.shift), let anchorKey = groupAnchorKey {
            let entries = rangeEntries(currentGroups(), isPlaylists: isPlaylists)
            if let a = entries.firstIndex(where: { $0.key == anchorKey }), let b = entries.firstIndex(where: { $0.key == key }) {
                let anchor = entries[a]
                let selecting: Bool
                if let t = anchor.track { selecting = isPicked(anchor.group, t, isPlaylists) }
                else { selecting = isGroupFullySelected(anchor.group, isPlaylists) }
                for e in entries[min(a, b)...max(a, b)] {
                    let tracks = e.track.map { [$0] } ?? selectableTracks(e.group)
                    for t in tracks where t.warning == nil {
                        if isPlaylists {
                            let k = pickKey(e.group, t)
                            if selecting { playlistPicks.insert(k) } else { playlistPicks.remove(k) }
                        } else if selecting { selection.insert(t.id) } else { selection.remove(t.id) }
                    }
                }
                return true
            }
        }
        groupAnchorKey = key
        return false
    }

    private func groupList(_ groups: [TrackGroup<Track>], listCategory: CatalogCategory, isPlaylists: Bool = false, showArtwork: Bool = false) -> some View {
        let isActive = category == listCategory
        return ScrollViewReader { proxy in
        // Come nei Brani: lista SENZA selezione nativa; seleziona solo la spunta o il click sulla riga (che inverte lo stesso stato).
        List {
            GlassInsetRow(edge: .top)
            ForEach(groups) { group in
                DisclosureGroup(isExpanded: expandedBinding(group.id)) {
                    if group.subgroups.isEmpty {
                        albumTrackRows(group, isPlaylists: isPlaylists, numbered: listCategory == .albums)
                    } else {
                        // Scheda Artisti: Artista → Album → Brani dell'album.
                        ForEach(group.subgroups) { album in
                            DisclosureGroup(isExpanded: expandedBinding(album.id)) {
                                albumTrackRows(album, isPlaylists: false, numbered: true)
                            } label: {
                                albumHeader(album)
                            }
                            .listRowBackground(isGroupFullySelected(album, false) ? rowHighlight(settings.highlightColor) : nil)
                        }
                    }
                } label: {
                    HStack {
                        // Selezione a sinistra (vuota = invisibile, solo ingombro), stato: tutto / parziale.
                        let selectedCount = group.tracks.filter { isPicked(group, $0, isPlaylists) }.count
                        SelectToggleIcon(state: isGroupFullySelected(group, isPlaylists) ? .all
                                         : (selectedCount > 0 ? .partial : .none), isGroup: true) {
                            toggleGroupSelection(group, isPlaylists)
                        }
                        if showArtwork, let first = group.tracks.first {
                            ArtworkThumbnail(track: first, provider: artworkProvider, version: artworkRevision, size: 32,
                                             placeholderSymbol: "music.quarternote.3")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title).font(.system(size: settings.listTextSize.points)).fontWeight(.medium).lineLimit(1)
                            Text(subtitleText(group)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        purchasedBadge(group.tracks)
                        // Nessun conteggio a destra: playlist e artisti lo riportano già nel sottotitolo.
                        if isPlaylists, let action = playlistAction {
                            Button(action.title) { action.perform(group) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                        // Playlist del dispositivo: porta la playlist nella Custom per modificarla.
                        if isPlaylists, let edit = onEditPlaylist {
                            Button { edit(group) } label: {
                                Label(t("button_edit_in_custom"), systemImage: "square.and.pencil")
                                    .labelStyle(.titleAndIcon)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help(t("tooltip_edit_in_custom"))
                        }
                        // Ultima colonna a destra: playlist già inviata (freccia verde). Spazio fisso, per l'allineamento
                        // con i brani; presente solo nelle liste che conoscono lo stato «sul dispositivo».
                        if isPlaylistOnDeviceCheck != nil || isOnDeviceCheck != nil {
                            Group {
                                if isPlaylists, let onDevice = isPlaylistOnDeviceCheck, onDevice(group) {
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(statusIconGreen)
                                        .help(t("artwork_on_device"))
                                } else if !isPlaylists, isGroupOnDevice(group.tracks) {
                                    // Album (scheda Album) o artista: tutti i suoi brani trasferibili sono già sul dispositivo.
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(statusIconGreen)
                                        .help(t("artwork_group_on_device"))
                                } else {
                                    Color.clear
                                }
                            }
                            .font(.system(size: 14))
                            .frame(width: 24, alignment: .center)
                        }
                    }
                    // Doppio click sull'intestazione di una playlist: riproduce tutti i suoi brani,
                    // dal primo, nell'ordine in cui la playlist li propone (i pulsanti dentro la riga
                    // gestiscono i propri click).
                    .contentShape(Rectangle())
                    // Click singolo sull'intestazione: come la spunta, inverte la selezione dell'intero gruppo;
                    // il secondo click ravvicinato avvia la riproduzione (vedi `ClickTracker`).
                    .simultaneousGesture(TapGesture().onEnded {
                        if handleRangeClick(group: group, track: nil, isPlaylists: isPlaylists) { return }
                        toggleGroupSelection(group, isPlaylists)
                        if ClickTracker.isDouble("g:\(group.id)"), let first = group.tracks.first {
                            onPlay?(first, group.tracks, PlaybackSource(name: group.title, category: category))
                        }
                    })
                    // Click destro sull'intestazione: Select/Deselect agisce sull'intero gruppo.
                    .contextMenu {
                        contextMenuItems(isSelected: isGroupFullySelected(group, isPlaylists), artworkTracks: { group.tracks }, groupName: group.title, sendIDs: { menuSendIDs(forGroup: group) }) { toggleGroupSelection(group, isPlaylists) }
                        if isPlaylists, let edit = onEditPlaylist {
                            Button { edit(group) } label: {
                                Label(t("menu_edit_in_custom"), systemImage: "square.and.pencil")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
                // Sfondo evidenziato sull'intestazione quando tutti i brani del gruppo sono
                // selezionati (stesso colore delle righe singole).
                .listRowBackground(isGroupFullySelected(group, isPlaylists) ? rowHighlight(settings.highlightColor) : nil)
            }
            GlassInsetRow(edge: .bottom)
        }
        .listStyle(.inset)
        .background(HideNativeSelection())   // la selezione si vede solo col colore scelto, non col blu di sistema
        .scrollContentBackground(.hidden)
        .background { if isPlaylists { ListScrollLocator(handle: scrollHandle) } }
        .background {
            if listCategory == .albums || listCategory == .artists {
                let tracker = listCategory == .albums ? albumsLetters : artistsLetters
                // Righe della tabella con i gruppi aperti: margine in alto e in basso, intestazioni e, se aperti, i loro brani
                // (per gli artisti anche gli album). Con un numero di righe diverso si ripiega su una stima.
                let rowsOf: (TrackGroup<Track>) -> Int = { g in
                    guard expandedGroups.contains(g.id) else { return 1 }
                    if g.subgroups.isEmpty { return 1 + g.tracks.count }
                    return 1 + g.subgroups.reduce(0) { $0 + 1 + (expandedGroups.contains($1.id) ? $1.tracks.count : 0) }
                }
                let flatTotal = 2 + groups.reduce(0) { $0 + rowsOf($1) }
                ScrollLetterLocator(tracker: tracker, rowCounts: [flatTotal, groups.count + 2]) { row, numberOfRows in
                    guard !groups.isEmpty else { return nil }
                    var index = 0
                    if numberOfRows == flatTotal {
                        var first = 1
                        index = groups.count - 1
                        for (i, g) in groups.enumerated() {
                            let n = rowsOf(g)
                            if row < first + n { index = i; break }
                            first += n
                        }
                    } else if numberOfRows == groups.count + 2 {
                        index = row - 1
                    } else if numberOfRows > 0 {
                        index = Int(Double(row) / Double(numberOfRows) * Double(groups.count))
                    }
                    return Self.initial(of: groups[max(0, min(index, groups.count - 1))].title)
                }
            }
        }
        .overlay {
            if listCategory == .albums { ScrollLetterBubble(model: albumsLetters.model, typed: typeAheadText) }
            else if listCategory == .artists { ScrollLetterBubble(model: artistsLetters.model, typed: typeAheadText) }
        }
        .overlay { emptyOverlay(groups.isEmpty, message: isPlaylists ? (playlists.isEmpty ? t("no_playlists") : t("no_results")) : emptyMessage) }
        .onChange(of: typeAheadEvent) { _, event in
            // Solo Album e Artisti, e solo nell'elenco visibile (le altre schede restano in vita, nascoste).
            guard isActive, listCategory == .albums || listCategory == .artists, let event else { return }
            handleTypeAhead(event, entries: groups.map { ($0.id, $0.title) }, rowOffset: Self.revealRowOffset, proxy: proxy)
        }
        // Il gruppo in riproduzione (playlist, artista o album) si apre da solo, così si vedono i suoi brani e quello in corso.
        // e la lista scorre fino al brano in corso (utile con playlist lunghe).
        .onAppear {
            guard isActive else { return }
            expandPlayingGroup(in: groups, proxy: proxy)
            if isPlaylists { reconcilePlaylistPicks() }
            performReveal(in: groups, proxy: proxy)
        }
        .onChange(of: revealRequest) { _, new in if new != nil, isActive { performReveal(in: groups, proxy: proxy) } }
        .onChange(of: category) { _, _ in if isActive, revealRequest != nil { performReveal(in: groups, proxy: proxy) } }
        // Playlist: la selezione è per riga (playlist + brano), non per brano (vedi `playlistPicks`).
        .onChange(of: playlistPicks) { old, new in
            guard isPlaylists else { return }
            // Righe ricostruite dalla selezione (scelta fatta altrove): le playlist intere restano quelle già scelte dall'utente.
            if let rebuilt = reconciledPicks, rebuilt == new { reconciledPicks = nil; return }
            reconciledPicks = nil
            syncPicksToSelection()
            warnIfWholePlaylistBecamePartial(from: old, to: new)
            noticeIfPlaylistCompletedBySongs(from: old, to: new)
        }
        .onChange(of: selection) { _, _ in if isPlaylists { reconcilePlaylistPicks() } }
        .onChange(of: playingSource) { _, _ in if isActive { expandPlayingGroup(in: groups, proxy: proxy) } }
        // Espandendo un gruppo si caricano le copertine mancanti di ciò che compare: i brani di una
        // playlist o di un album, gli album di un artista (un brano per album basta per la miniatura).
        .onChange(of: category) { groupAnchorKey = nil }
        .onChange(of: expandedGroups) { old, new in
            guard isActive, settings.autoLoadAppleArtwork, !onlyWithoutCover, let request = onRequestArtwork else { return }
            for id in new.subtracting(old) {
                for group in groups {
                    if group.id == id {
                        request(group.subgroups.isEmpty ? group.tracks : group.subgroups.compactMap { $0.tracks.first }, false)
                    } else if let album = group.subgroups.first(where: { $0.id == id }) {
                        request(album.tracks, false)
                    }
                }
            }
        }
        }
    }

    /// Icona sull'intestazione di un gruppo (playlist, artista, album) che contiene brani acquistati su iTunes Store.
    @ViewBuilder
    private func purchasedBadge(_ list: [Track]) -> some View {
        let n = list.filter(\.isPurchased).count
        if n > 0 {
            Image(systemName: "bag")
                .foregroundStyle(Color.statusNeutral)
                .help(t("purchased_group_help", n))
        }
    }

    private func rowScrollID(_ groupID: String, _ trackID: Track.ID) -> String { "\(groupID)#\(trackID)" }

    /// Riga di un brano dentro un gruppo (playlist, album, artista o album di un artista).
    /// Oggetto di "secondo livello": ha anche lui il proprio quadrato di selezione, indipendente da
    /// quello dell'intestazione, così la selezione multipla può prendere singoli brani da dentro un gruppo.
    @ViewBuilder
    private func groupTrackRow(_ group: TrackGroup<Track>, _ track: Track, isPlaylists: Bool, numbered: Bool = false) -> some View {
        // Oggetto di "secondo livello" (il brano dentro l'album/artista/playlist):
        // ha anche lui il proprio Select/Deseleziona, indipendente da quello
        // dell'intestazione — cosi la selezione multipla può prendere singoli
        // brani da dentro un gruppo, non solo il gruppo intero.
        trackRow(track, number: numbered ? trackNumberLabel(track, in: group) : nil, insideAlbum: numbered) {
            // Playlist del dispositivo: nessuna selezione dei singoli brani (si sceglie solo la playlist).
            if !(isPlaylists && disablesTrackSelectionInPlaylists) {
                // Brano non selezionabile (es. solo nel cloud): riquadro invisibile, stesso incolonnamento.
                SelectToggleIcon(state: isPicked(group, track, isPlaylists) ? .all : .none, hidden: track.warning != nil) {
                    toggleRow(group, track, isPlaylists)
                }
            }
        }
        .tag(isPlaylists ? pickKey(group, track) : "\(track.id)")
        .selectionDisabled((isPlaylists && disablesTrackSelectionInPlaylists) || track.warning != nil)
        // Identificativo per lo scorrimento automatico (lo stesso brano può stare in più gruppi).
        .id(rowScrollID(group.id, track.id))
        .contentShape(Rectangle())
        // Click singolo sulla riga: come la spunta (non per i brani non selezionabili né nelle playlist del dispositivo);
        // il secondo click ravvicinato avvia la riproduzione (vedi `ClickTracker`).
        .simultaneousGesture(TapGesture().onEnded {
            if !(isPlaylists && disablesTrackSelectionInPlaylists), handleRangeClick(group: group, track: track, isPlaylists: isPlaylists) { return }
            if track.warning == nil, !(isPlaylists && disablesTrackSelectionInPlaylists) { toggleRow(group, track, isPlaylists) }
            if ClickTracker.isDouble("r:\(rowScrollID(group.id, track.id))") {
                onPlay?(track, group.tracks, PlaybackSource(name: group.title, category: category))
            }
        })
        .listRowBackground(isPicked(group, track, isPlaylists) ? rowHighlight(settings.highlightColor)
                           : (flashRowID == rowScrollID(group.id, track.id) ? rowHighlight(Color.yellow.opacity(0.4)) : nil))
        .contextMenu {
            contextMenuItems(isSelected: isPicked(group, track, isPlaylists), artworkTracks: { group.tracks }, goTo: track, membershipTrack: isPlaylists ? nil : track, similarSeeds: [track], full: true, focusTrack: track, sendIDs: { menuSendIDs(for: track) }) { toggleRow(group, track, isPlaylists) }
        }
    }

    /// Etichetta del numero di traccia dentro un album: "5" con un solo disco, "Disco/Traccia" (es. "2/05")
    /// solo se l'album ha più di un disco; nil se nessun brano dell'album ha il numero (es. il dispositivo):
    /// resta la copertina.
    /// Brani di un gruppo. Se è un album con più dischi, prima dei brani di ogni disco c'è una riga d'intestazione
    /// «Disco 1 di n» (non selezionabile) e i brani riportano solo il numero di traccia (01, 02…).
    @ViewBuilder
    private func albumTrackRows(_ album: TrackGroup<Track>, isPlaylists: Bool, numbered: Bool) -> some View {
        let discs = Set(album.tracks.map { max($0.discNumber, 1) })
        let totalDiscs = max(album.tracks.map(\.discCount).max() ?? 0, discs.count)
        if numbered && !isPlaylists && (discs.count > 1 || totalDiscs > 1) {
            ForEach(album.tracks) { track in
                let disc = max(track.discNumber, 1)
                if album.tracks.first(where: { max($0.discNumber, 1) == disc })?.id == track.id {
                    Text(t("disc_n_of_m", disc, totalDiscs))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 34)   // sotto la colonna di selezione, allineata al numero di traccia
                        .padding(.top, 4)
                        .selectionDisabled(true)
                        .listRowSeparator(.hidden)
                }
                groupTrackRow(album, track, isPlaylists: isPlaylists, numbered: numbered)
            }
        } else {
            ForEach(album.tracks) { track in
                groupTrackRow(album, track, isPlaylists: isPlaylists, numbered: numbered)
            }
        }
    }

    private func trackNumberLabel(_ track: Track, in album: TrackGroup<Track>) -> String? {
        guard album.tracks.contains(where: { $0.trackNumber > 0 }) else { return nil }
        let multiDisc = Set(album.tracks.map { max($0.discNumber, 1) }).count > 1
            || album.tracks.contains { $0.discCount > 1 }
        guard multiDisc else { return track.trackNumber > 0 ? "\(track.trackNumber)" : "–" }
        // Più dischi: il disco è nell'intestazione «Disco n di m» sopra i suoi brani, qui solo la traccia (01, 02…).
        return track.trackNumber > 0 ? String(format: "%02d", track.trackNumber) : "–"
    }

    /// Intestazione di un album dentro un artista (scheda Artisti): copertina, titolo, quadrato di selezione.
    private func albumHeader(_ album: TrackGroup<Track>) -> some View {
        HStack {
            let selectedCount = album.tracks.filter { isPicked(album, $0, false) }.count
            SelectToggleIcon(state: isGroupFullySelected(album, false) ? .all
                             : (selectedCount > 0 ? .partial : .none), isGroup: true) {
                toggleGroupSelection(album, false)
            }
            if let first = album.tracks.first {
                ArtworkThumbnail(track: first, provider: artworkProvider, version: artworkRevision, size: 28,
                                 placeholderSymbol: "music.quarternote.3")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).font(.system(size: settings.listTextSize.points)).lineLimit(1)
                Text(subtitleText(album)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            purchasedBadge(album.tracks)
            // Nessun conteggio a destra: il numero di brani è già nel sottotitolo.
            // Colonna a destra (come nelle altre righe): freccia verde se tutti i brani trasferibili dell'album
            // sono già sul dispositivo (2.1 Beta 3), altrimenti vuota.
            if isPlaylistOnDeviceCheck != nil || isOnDeviceCheck != nil {
                Group {
                    if isGroupOnDevice(album.tracks) {
                        Image(systemName: "arrow.right.circle")
                            .foregroundStyle(statusIconGreen)
                            .help(t("artwork_group_on_device"))
                    } else {
                        Color.clear
                    }
                }
                .font(.system(size: 14))
                .frame(width: 24, alignment: .center)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if handleRangeClick(group: album, track: nil, isPlaylists: false) { return }
            toggleGroupSelection(album, false)
            if ClickTracker.isDouble("a:\(album.id)"), let first = album.tracks.first {
                onPlay?(first, album.tracks, PlaybackSource(name: album.title, category: category))
            }
        })
        .contextMenu {
            contextMenuItems(isSelected: isGroupFullySelected(album, false), artworkTracks: { album.tracks }, groupName: album.title, sendIDs: { menuSendIDs(forGroup: album) }) { toggleGroupSelection(album, false) }
        }
    }


    /// Vero se un album o un artista è già per intero sul dispositivo (2.1 Beta 3, logica A): tutti i brani con
    /// «sul dispositivo» vero. Esclusi dal conteggio i brani non trasferibili (con avviso: DRM, solo cloud, Hi-Res);
    /// i brani «solo sul dispositivo» contano come presenti. Senza brani trasferibili, falso. Solo negli elenchi
    /// che mostrano la colonna (Apple Music), come le righe dei brani.
    private func isGroupOnDevice(_ tracks: [Track]) -> Bool {
        guard artworkOriginProvider != nil, let onDevice = isOnDeviceCheck else { return false }
        var found = false
        for track in tracks where track.warning == nil {
            if !(track.isDeviceOnly || onDevice(track)) { return false }
            found = true
        }
        return found
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedGroups.contains(id) },
                set: { if $0 { expandedGroups.insert(id) } else { expandedGroups.remove(id) } })
    }

    /// Passa alla scheda Album o Artisti per mostrare il brano scelto nella scheda Brani.
    private func reveal(_ track: Track, in target: CatalogCategory) {
        search = ""   // un filtro di ricerca potrebbe nascondere il brano
        revealRequest = RevealRequest(trackID: track.id)
        category = target
    }

    /// Numero massimo di playlist elencate nel sottomenu «Mostra in playlist».
    private static var membershipMenuLimit: Int { 15 }

    /// Iniziale mostrata accanto al cursore di scorrimento: la prima lettera del titolo senza accenti, maiuscola; «#» per
    /// numeri e simboli.
    private static func initial(of title: String) -> String {
        let folded = title.trimmingCharacters(in: .whitespaces)
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
        guard let c = folded.first, c.isLetter else { return "#" }
        return String(c).uppercased()
    }

    /// Passa alla scheda Playlist, apre la playlist scelta e scorre fino al brano, evidenziandolo per un attimo.
    private func revealInPlaylist(_ track: Track, playlistID: String) {
        search = ""   // un filtro di ricerca potrebbe nascondere la playlist
        revealRequest = RevealRequest(trackID: track.id, playlistID: playlistID)
        category = .playlists
    }

    /// Apre la playlist richiesta e scorre fino al brano (stessa tecnica di `expandPlayingGroup`: prima il gruppo
    /// di primo livello, poi la riga, con ripetizioni perché l'apertura cambia l'altezza della lista).
    private func performRevealInPlaylist(_ request: RevealRequest, in groups: [TrackGroup<Track>], proxy: ScrollViewProxy) {
        guard let playlistID = request.playlistID,
              let index = groups.firstIndex(where: { $0.id == playlistID }) else { return }
        let group = groups[index]
        expandedGroups.insert(group.id)
        let scrollTop = groups[max(0, index - Self.revealRowOffset)].id
        let target = rowScrollID(group.id, request.trackID)
        let trackIndex = group.tracks.firstIndex { $0.id == request.trackID } ?? 0
        // Le righe annidate in un DisclosureGroup aperto da codice non sono raggiungibili con `scrollTo` per id: si
        // scorre la tabella AppKit fino alla riga del brano. Le righe non ancora mostrate hanno un'altezza stimata, quindi
        // si procede per passi: ci si avvicina alla posizione stimata e si riprova finché la riga del brano è davvero
        // presente nella vista (allora la si porta al centro).
        let scrollToTrack: @MainActor () -> ListScrollHandle.Result = {
            var rowsBefore = 1
            var flatTotal = 2
            for (i, g) in groups.enumerated() {
                let n = 1 + (expandedGroups.contains(g.id) ? g.tracks.count : 0)
                if i < index { rowsBefore += n }
                flatTotal += n
            }
            return scrollHandle.scroll(flatRow: rowsBefore + 1 + trackIndex, flatTotal: flatTotal,
                                       blockRow: 1 + index, blockTotal: groups.count + 2,
                                       childIndex: trackIndex, childCount: group.tracks.count)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation { proxy.scrollTo(scrollTop, anchor: .top) }
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let result = scrollToTrack()
                if result == .failed { withAnimation { proxy.scrollTo(target, anchor: .center) } }
                if result != .moved { break }
            }
            flashRowID = target
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if flashRowID == target { withAnimation { flashRowID = nil } }
        }
    }

    /// Apre i gruppi che contengono il brano richiesto (album; oppure artista e album) e scorre fino a lui.
    private func performReveal(in groups: [TrackGroup<Track>], proxy: ScrollViewProxy) {
        guard let request = revealRequest else { return }
        revealRequest = nil
        if request.playlistID != nil {
            performRevealInPlaylist(request, in: groups, proxy: proxy)
            return
        }
        var holder: TrackGroup<Track>?
        var topIndex = 0
        for (index, group) in groups.enumerated() {
            topIndex = index
            if group.subgroups.isEmpty {
                if category == .albums, group.tracks.contains(where: { $0.id == request.trackID }) {
                    expandedGroups.insert(group.id)
                    holder = group
                    break
                }
            } else if let album = group.subgroups.first(where: { $0.tracks.contains { $0.id == request.trackID } }) {
                expandedGroups.insert(group.id)
                expandedGroups.insert(album.id)
                holder = album
                break
            }
        }
        guard holder != nil else { return }
        // I pannelli sovrapposti alla lista coprono le prime righe: si scorre fino a un gruppo che sta 8
        // posizioni prima di quello cercato, così questo si ferma sotto i pannelli e non dietro di essi.
        let scrollTop = groups[max(0, topIndex - Self.revealRowOffset)].id
        // Le righe annidate dentro i gruppi aperti da codice non sono raggiungibili con `scrollTo` (la List non
        // le conosce come proprie righe): si scorre fino al gruppo di primo livello (album, o artista), con la
        // sua identità naturale nella ForEach, ripetendo perché l'apertura cambia l'altezza della lista.
        Task { @MainActor in
            for delay in [300_000_000, 500_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                withAnimation { proxy.scrollTo(scrollTop, anchor: .top) }
            }
        }
    }

    /// Righe di scostamento sopra il risultato di "Vai all'Album/Artista" (pannelli sovrapposti alla lista).
    private static var revealRowOffset: Int { 8 }
    /// Come sopra per l'elenco Brani (righe più basse di quelle di Album/Artisti, quindi più righe per coprire lo stesso spazio).
    private static var typeAheadSongRowOffset: Int { 12 }

    private func expandPlayingGroup(in groups: [TrackGroup<Track>], proxy: ScrollViewProxy) {
        guard let source = playingSource, source.category == category else { return }
        // Il gruppo in riproduzione può essere di primo livello (artista, album, playlist) oppure un album
        // dentro un artista (scheda Artisti): si aprono tutti i livelli fino al brano.
        var found: TrackGroup<Track>?
        if let group = groups.first(where: { $0.title == source.name }) {
            expandedGroups.insert(group.id)
            found = group
        } else {
            for group in groups {
                if let album = group.subgroups.first(where: { $0.title == source.name }) {
                    expandedGroups.insert(group.id)
                    expandedGroups.insert(album.id)
                    found = album
                    break
                }
            }
        }
        guard var holder = found, let playingTrackID = playingTrackID else { return }
        if !holder.subgroups.isEmpty,
           let album = holder.subgroups.first(where: { $0.tracks.contains { $0.id == playingTrackID } }) {
            expandedGroups.insert(album.id)
            holder = album
        }
        let target = rowScrollID(holder.id, playingTrackID)
        // Piccolo ritardo: il gruppo deve prima aprirsi e creare le sue righe.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation { proxy.scrollTo(target, anchor: .center) }
        }
    }

    // MARK: Selezione per riga nella scheda Playlist
    //
    // Lo stesso brano può stare in più playlist. La selezione condivisa col resto dell'app
    // (`selection`) è fatta di ID di brano, ma nella scheda Playlist ciò che l'utente sceglie è una
    // riga precisa (playlist + brano): `playlistPicks`. Così scegliere una playlist non evidenzia né
    // seleziona le altre che contengono gli stessi brani.

    /// Righe scelte nella scheda Playlist, chiave "idPlaylist␁idBrano".
    @State private var playlistPicks: Set<String> = []
    /// Righe ricostruite da `reconcilePlaylistPicks`: il cambio di `playlistPicks` che ne segue non deve ricalcolare le playlist intere.
    @State private var reconciledPicks: Set<String>? = nil
    @State private var pendingRowRemoval: RowRemoval? = nil

    private func pickKey(_ group: TrackGroup<Track>, _ track: Track) -> String {
        "\(group.id)\u{1}\(track.id)"
    }

    private func isPicked(_ group: TrackGroup<Track>, _ track: Track, _ isPlaylists: Bool) -> Bool {
        isPlaylists ? playlistPicks.contains(pickKey(group, track)) : selection.contains(track.id)
    }

    private func toggleRow(_ group: TrackGroup<Track>, _ track: Track, _ isPlaylists: Bool) {
        guard track.warning == nil else { return }
        guard isPlaylists else { toggleSelection(track.id); return }
        let key = pickKey(group, track)
        if playlistPicks.contains(key) { playlistPicks.remove(key) } else { playlistPicks.insert(key) }
    }

    /// Brani del gruppo che si possono scegliere (esclusi quelli non trasferibili, es. solo nel cloud).
    private func selectableTracks(_ group: TrackGroup<Track>) -> [Track] {
        group.tracks.filter { $0.warning == nil }
    }

    private func isGroupFullySelected(_ group: TrackGroup<Track>, _ isPlaylists: Bool) -> Bool {
        let tracks = selectableTracks(group)
        return !tracks.isEmpty && tracks.allSatisfy { isPicked(group, $0, isPlaylists) }
    }

    private func toggleGroupSelection(_ group: TrackGroup<Track>, _ isPlaylists: Bool) {
        let tracks = selectableTracks(group)
        if isPlaylists {
            let keys = tracks.map { pickKey(group, $0) }
            if isGroupFullySelected(group, true) { playlistPicks.subtract(keys) } else { playlistPicks.formUnion(keys) }
        } else if isGroupFullySelected(group, false) {
            selection.subtract(tracks.map(\.id))
        } else {
            selection.formUnion(tracks.map(\.id))
        }
    }

    /// Selezione nativa della `List` a gruppi. Nella scheda Playlist sono le righe (`playlistPicks`);
    /// nelle altre i brani, mantenendo quelli selezionati ma non visibili (filtri, altre schede).
    private func groupSelectionBinding(_ groups: [TrackGroup<Track>], isPlaylists: Bool) -> Binding<Set<String>> {
        if isPlaylists { return $playlistPicks }
        return Binding(
            get: { Set(selection.map { "\($0)" }) },
            set: { newValue in
                var visible: [String: Track.ID] = [:]
                for g in groups { for t in g.tracks { visible["\(t.id)"] = t.id } }
                let kept = selection.subtracting(Set(visible.values))
                selection = kept.union(newValue.compactMap { visible[$0] })
            })
    }

    /// Righe scelte → selezione condivisa (ID di brano) e, se è scelta esattamente UNA playlist
    /// intera, la comunica (serve all'invio: playlist intera = brani + file .m3u8).
    private func syncPicksToSelection() {
        var ids = Set<Track.ID>()
        var inPlaylists = Set<Track.ID>()
        for g in playlists { for t in g.tracks {
            inPlaylists.insert(t.id)
            if playlistPicks.contains(pickKey(g, t)) { ids.insert(t.id) }
        } }
        // I brani scelti altrove (es. dalla scheda Brani) e che non stanno in nessuna playlist restano selezionati;
        // quelli che stanno nelle playlist seguono le righe scelte qui.
        let merged = selection.subtracting(inPlaylists).union(ids)
        if selection != merged { selection = merged }
        var whole: String? = nil
        if !playlistPicks.isEmpty {
            for g in playlists {
                let keys = Set(selectableTracks(g).map { pickKey(g, $0) })
                if !keys.isEmpty, keys == playlistPicks { whole = g.id; break }
            }
        }
        onWholePlaylistChange?(whole)
        // Playlist scelte per intero (tutte le loro righe), per l'eliminazione lato dispositivo.
        let full = playlists.filter { g in
            let keys = Set(selectableTracks(g).map { pickKey(g, $0) })
            return !keys.isEmpty && keys.isSubset(of: playlistPicks)
        }.map(\.id)
        onSelectedPlaylistsChange?(full)
    }

    /// Avviso (scheda Playlist) quando da una playlist scelta per intero si toglie qualche brano lasciandone altri: «Conferma»
    /// lascia le cose come sono (la playlist non conta più come intera, quindi niente .m3u8); «Annulla» ripristina le righe.
    /// Nessun avviso se si parte scegliendo singoli brani, se si toglie tutta la playlist o se si svuota la selezione.
    private struct RowRemoval {
        let previousPicks: Set<String>
        let subject: String
        let plural: Bool
        let titles: [String]
    }

    /// Informa (barra di stato, senza interrompere) quando l'ultima riga scelta a mano completa una playlist: da quel momento
    /// la playlist risulta scelta per intero e l'invio crea anche il suo file .m3u8. Nessun avviso per «Seleziona» sull'intestazione
    /// (aggiunge tutte le righe insieme) né quando la playlist era già intera.
    private func noticeIfPlaylistCompletedBySongs(from old: Set<String>, to new: Set<String>) {
        let added = new.subtracting(old)
        guard added.count == 1 else { return }
        for g in playlists {
            let keys = Set(selectableTracks(g).map { pickKey(g, $0) })
            guard keys.count > 1, keys.isSubset(of: new), !keys.isSubset(of: old), !keys.isDisjoint(with: added) else { continue }
            onPlaylistCompletedBySongs?(g.title)
            return
        }
    }

    private func warnIfWholePlaylistBecamePartial(from old: Set<String>, to new: Set<String>) {
        var titles: [String] = []
        var removedTitles: [String: String] = [:]
        for g in playlists {
            let keys = Set(selectableTracks(g).map { pickKey(g, $0) })
            guard !keys.isEmpty, keys.isSubset(of: old), !keys.isSubset(of: new), !keys.isDisjoint(with: new) else { continue }
            titles.append(g.title)
            for trk in selectableTracks(g) where !new.contains(pickKey(g, trk)) { removedTitles["\(trk.id)"] = trk.title }
        }
        guard !titles.isEmpty else { return }
        let subject = removedTitles.count == 1 ? t("alert_playlist_removal_song_one", removedTitles.values.first ?? "")
                                               : t("alert_playlist_removal_songs_many", removedTitles.count)
        pendingRowRemoval = RowRemoval(previousPicks: old, subject: subject, plural: removedTitles.count != 1, titles: titles)
    }

    /// Selezione cambiata da fuori (svuotata, scelta in un'altra scheda): riallinea le righe scelte. Le playlist scelte per
    /// intero NON si toccano qui (salvo selezione vuota): le comunica solo l'azione dell'utente nella scheda Playlist e le
    /// aggiorna il view model quando la selezione cambia altrove (`AppViewModel.selectedTrackIDs`, con l'avviso di rimozione).
    private func reconcilePlaylistPicks() {
        var ids = Set<Track.ID>()
        for g in playlists { for t in g.tracks where playlistPicks.contains(pickKey(g, t)) { ids.insert(t.id) } }
        guard ids != selection else { return }
        if selection.isEmpty {
            playlistPicks = []
            onWholePlaylistChange?(nil)
            onSelectedPlaylistsChange?([])
            return
        }
        var rebuilt = Set<String>()
        for g in playlists { for t in g.tracks where selection.contains(t.id) { rebuilt.insert(pickKey(g, t)) } }
        if rebuilt != playlistPicks {
            reconciledPicks = rebuilt
            playlistPicks = rebuilt
        }
    }

    /// Menu del click destro. Su un brano: menu completo (Send to Custom, Send to Device, Artwork Online Fix, filtro «senza copertina»,
    /// Go to Album/Artist, Find Similar, Show in playlist). Su playlist, artista o album: solo i due invii, riferiti a quell'elemento.
    /// Gli invii sostituiscono la selezione con l'elemento cliccato (brano, oppure la selezione se il brano ne fa parte).
    @ViewBuilder
    private func contextMenuItems(isSelected: Bool, artworkTracks: @escaping () -> [Track], goTo: Track? = nil, membershipTrack: Track? = nil, similarSeeds: [Track]? = nil, full: Bool = false, focusTrack: Track? = nil, groupName: String? = nil, sendIDs: @escaping () -> Set<Track.ID>, toggle: @escaping () -> Void) -> some View {
        if let menu = rowMenu {
            // Invio: agisce sull'elemento cliccato (brano, o gruppo intero), non sulla selezione precedente.
            // La selezione viene sostituita da quell'elemento e poi si usano le stesse azioni dei pulsanti in basso.
            let ids = sendIDs()
            // Brano cliccato dentro una selezione di più brani: due righe per azione (tutta la selezione / solo il brano).
            let focusID: Track.ID? = (full && ids.count > 1) ? focusTrack.map(\.id) : nil
            let focusName: String = {
                guard let title = focusTrack?.title else { return "" }
                return title.count > 15 ? String(title.prefix(15)) + "…" : title
            }()

            Button {
                selection = sendIDs()
                menu.sendToPlaylist()
            } label: {
                Label(groupName != nil ? t("menu_send_group_to_custom", groupLabel(groupName), songsText(ids.count))
                        : (ids.count > 1 ? t("menu_send_n_to_custom", ids.count) : t("menu_send_to_custom")),
                      systemImage: "tray.and.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(ids.isEmpty || menu.isBusy)
            if let focusID {
                Button {
                    selection = [focusID]
                    menu.sendToPlaylist()
                } label: {
                    Label(t("menu_send_one_to_custom", focusName), systemImage: "tray.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(menu.isBusy)
            }

            // Sempre presenti; non attive senza dispositivo connesso (o in sola lettura).
            Button {
                selection = sendIDs()
                menu.sendToDevice()
            } label: {
                Label(groupName != nil ? t("menu_send_group_to_device", groupLabel(groupName), songsText(ids.count))
                        : (ids.count > 1 ? t("menu_send_n_to_device", ids.count) : t("menu_send_to_device")),
                      systemImage: "arrow.right.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(ids.isEmpty || menu.isBusy || !menu.canSendToDevice)
            if let focusID {
                Button {
                    selection = [focusID]
                    menu.sendToDevice()
                } label: {
                    Label(t("menu_send_one_to_device", focusName), systemImage: "arrow.right.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(menu.isBusy || !menu.canSendToDevice)
            }

            // Menu completo solo su un brano; su playlist, artista, album solo i due invii.
            if full {
                Divider()

                // Artwork: ricerca online (solo con la funzione attiva in Impostazioni), sempre disponibile
                // (serve anche quando la copertina mostrata non è quella giusta).
                if menu.canFixArtwork {
                    Button {
                        selection = sendIDs()
                        menu.fixArtwork()
                    } label: {
                        Label(t("menu_artwork_online_fix"), systemImage: "waveform.badge.magnifyingglass")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(ids.isEmpty || menu.isBusy)
                }
                // Solo scheda Brani: filtro «Mostra solo brani senza copertina» (spunta a sinistra = filtro attivo).
                if category == .songs, artworkOriginProvider != nil {
                    Toggle(isOn: $onlyWithoutCover) {
                        Label(t("menu_only_without_cover"), systemImage: "photo.badge.exclamationmark").labelStyle(.titleAndIcon)
                    }
                }

                Divider()

                // Salta all'album o all'artista del brano, aprendoli e scorrendo fino a lui.
                if let goTo {
                    Button { reveal(goTo, in: .albums) } label: {
                        Label(t("menu_go_to_album"), systemImage: "music.pages")
                            .labelStyle(.titleAndIcon)
                    }
                    Button { reveal(goTo, in: .artists) } label: {
                        Label(t("menu_go_to_artist"), systemImage: "microphone.dynamic.on.stand")
                            .labelStyle(.titleAndIcon)
                    }
                }
                // «Trova simili»: finestra con i brani della libreria più simili al brano.
                if let similarSeeds, let find = menu.findSimilar {
                    Button { find(similarSeeds) } label: {
                        Label(t("menu_find_similar"), systemImage: "apple.haptics.and.music.note")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(menu.isBusy)
                }
                // «Mostra in playlist»: sottomenu con le playlist che contengono il brano; assente se non ce n'è nessuna.
                if let membershipTrack, let lookup = playlistsContainingTrack {
                    let inPlaylists = lookup(membershipTrack)
                    if !inPlaylists.isEmpty {
                        Divider()
                        Menu {
                            ForEach(Array(inPlaylists.prefix(Self.membershipMenuLimit).enumerated()), id: \.offset) { _, entry in
                                Button(entry.title) { revealInPlaylist(membershipTrack, playlistID: entry.id) }
                            }
                            if inPlaylists.count > Self.membershipMenuLimit {
                                Divider()
                                Text(t("menu_show_in_playlist_more", inPlaylists.count - Self.membershipMenuLimit))
                            }
                        } label: {
                            Label(t("menu_show_in_playlist"), systemImage: "music.note.list")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
        }
    }

    /// Sottotitolo di un gruppo; se contiene brani non trasferibili (ALAC, FLAC, solo cloud…) aggiunge quanti sono inviabili.
    private func subtitleText(_ group: TrackGroup<Track>) -> String {
        let blocked = group.tracks.filter { $0.warning != nil }.count
        guard blocked > 0 else { return group.subtitle }
        return group.subtitle + t("subtitle_transferable", group.tracks.count - blocked)
    }

    /// Nome dell'elemento nel menu, tagliato a 15 caratteri.
    private func groupLabel(_ name: String?) -> String {
        let name = name ?? ""
        return name.count > 15 ? String(name.prefix(15)) + "…" : name
    }

    private func songsText(_ count: Int) -> String {
        count == 1 ? t("menu_one_song") : t("menu_n_songs", count)
    }

    /// Brani da inviare dal menu su un brano: la selezione, se il brano ne fa parte; altrimenti solo lui.
    private func menuSendIDs(for track: Track) -> Set<Track.ID> {
        if selection.contains(track.id) { return selection }
        return track.warning == nil ? [track.id] : []
    }

    /// Brani da inviare dal menu su un gruppo (playlist, artista, album): tutti i suoi brani trasferibili.
    private func menuSendIDs(forGroup group: TrackGroup<Track>) -> Set<Track.ID> {
        Set(group.tracks.filter { $0.warning == nil }.map(\.id))
    }

    // MARK: - Scheda "Custom Playlist"

    /// Elenco dei brani già aggiunti (col pulsante "Invia alla Playlist" sulla selezione corrente
    /// di una qualunque delle altre schede), con un pulsante per rimuovere ogni riga. Il nome
    /// della playlist si inserisce nel campo che qui sopra
    /// sostituisce la ricerca (vedi `body`). I pulsanti (svuota, salva in Apple Music, invia
    /// all'orologio) non sono qui: li mostra `ContentView.musicPane`, sulla stessa riga unica in
    /// fondo al pannello usata anche dalle altre schede, invece di avere una seconda riga di
    /// pulsanti solo per la Custom Playlist.
    /// Riordinabile trascinando una riga su o giù (`.onMove`, il riordino nativo delle List su
    /// macOS, con autoscroll ai due estremi gestito da AppKit, la stessa NSTableView dietro ogni
    /// List): se più righe sono selezionate e si trascina una di quelle, **si spostano tutte
    /// insieme** — questo lo fa da solo il meccanismo nativo di `List(selection:)` + `.onMove`,
    /// ma solo se la selezione è quella vera della List, non una copia tenuta a mano. Il binding è
    /// `customPlaylistSelection`, indipendente da `selection` (quella usata dalle altre schede per
    /// "Invia all'orologio"/"Invia alla Playlist"). Niente `.contentShape(Rectangle())` sulla riga
    /// e il doppio click è un `.simultaneousGesture` (non `.gesture`/`.onTapGesture`, che sono
    /// esclusivi e intercettano il click prima che arrivi alla List, spegnendo sia il
    /// click-per-selezionare sia l'avvio del drag): `.simultaneousGesture` esiste apposta per non
    /// competere con l'interazione nativa della riga. Il menu "Ordina per" sta nella riga sopra, a
    /// destra del nome (vedi `body`), e applica un riordino immediato dell'intera playlist secondo
    /// il criterio scelto (Titolo/Artista/Album), oppure recupera l'ultimo ordine manuale noto se
    /// si torna su "Manuale"; dopo resta comunque possibile risistemare a mano trascinando le righe.
    private func customPlaylistView(_ config: CustomPlaylistConfig<Track>) -> some View {
        // Coda di riproduzione: i brani solo sul dispositivo non hanno un file da suonare qui.
        let queue = config.entries.map(\.track).filter { !$0.isDeviceOnly }
        let shown = customQuery.isEmpty ? config.entries : config.entries.filter { matches($0.track, for: customQuery) }
        let listName = config.name.isEmpty ? CatalogCategory.customPlaylist.title : config.name
        let source = PlaybackSource(name: listName, category: .customPlaylist)
        return List(selection: $customPlaylistSelection) {
            GlassInsetRow(edge: .top)
            // Riga radice dell'albero: sempre presente (anche a elenco vuoto), con il nome
            // modificabile al posto del vecchio campo "Name". Non è selezionabile (nessun tag).
            HStack(spacing: 8) {
                Button {
                    withAnimation { customExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(customExpanded ? 90 : 0))
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                Image(systemName: CatalogCategory.customPlaylist.iconName)
                    .foregroundStyle(.secondary)
                TextField(t("custom_playlist_name_placeholder"), text: Binding(
                    get: { config.name },
                    set: { config.onNameChange($0) }
                ))
                .textFieldStyle(.plain)
                .font(.headline)
                // Come l'app Musica: «N brani, X ore e Y minuti» (senza secondi).
                // + dimensione totale dei file in GB («1042 tracks, 78 hours, 7 minutes / 5,3 GB»).
                Text(customPlaylistHeaderText(config.entries.map(\.track)))
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)

            if customExpanded {
                if config.entries.isEmpty {
                    Text(t("custom_playlist_empty_hint"))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 22)
                }
                ForEach(shown) { entry in
                    trackRow(entry.track, selectionOnLeft: false) {
                        Button {
                            config.onRemove(entry.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(t("tooltip_remove_from_custom_playlist"))
                    }
                    .padding(.leading, 22)
                    .tag(entry.id)
                    // Doppio click avvia il brano, con la Custom Playlist stessa (nell'ordine
                    // attuale) come coda e come sorgente per i controlli del mini player.
                    .simultaneousGesture(TapGesture(count: 2).onEnded { if !entry.track.isDeviceOnly { onPlay?(entry.track, queue, source) } })
                    .listRowBackground(customPlaylistSelection.contains(entry.id) ? rowHighlight(settings.highlightColor) : nil)
                }
                // Il riordino è disattivato mentre si filtra con la ricerca (indici non corrispondenti).
                .onMove(perform: customQuery.isEmpty ? { source, destination in
                    config.onMove(source, destination)
                } : nil)
            }
            GlassInsetRow(edge: .bottom)
        }
        .listStyle(.inset)
        .background(HideNativeSelection())   // la selezione si vede solo col colore scelto, non col blu di sistema
        .scrollContentBackground(.hidden)
    }

    /// Artista del brano se diverso da quello dell'album (artista dell'album, o del brano se manca); altrimenti nil.
    private func artistDifferingFromAlbum(_ track: Track) -> String? {
        let artist = track.artist.trimmingCharacters(in: .whitespaces)
        guard !artist.isEmpty else { return nil }
        let albumArtist = track.albumArtist.trimmingCharacters(in: .whitespaces)
        let reference = albumArtist.isEmpty ? artist : albumArtist
        return artist.compare(reference, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ? nil : artist
    }

    private func trackRow(_ track: Track) -> some View {
        trackRow(track, number: nil) { EmptyView() }
    }

    /// Riga di un brano, con un accessorio finale opzionale (es. la scritta "Select"/"Deseleziona")
    /// nello stesso HStack — cosi c'è un solo Spacer a spingere tutto a destra, invece di
    /// annidarne un secondo attorno a questa vista.
    @ViewBuilder
    private func trackRow<Trailing: View>(_ track: Track, number: String? = nil, insideAlbum: Bool = false, selectionOnLeft: Bool = true, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            // Selezione (a sinistra, come le caselle di un elenco): colonna di larghezza fissa, invisibile se non selezionato.
            if selectionOnLeft {
                trailing()
                    .frame(width: 24, alignment: .center)
            }
            if let number {
                // Dentro un album: il numero di traccia al posto della copertina.
                Text(number)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .frame(width: 32)
            } else {
                ArtworkThumbnail(track: track, provider: artworkProvider, version: artworkRevision, size: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.system(size: settings.listTextSize.points)).lineLimit(1)
                if !insideAlbum {
                    HStack(spacing: 6) {
                        Text("\(track.artist) — \(track.album)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if let differing = artistDifferingFromAlbum(track) {
                    // Dentro un album (schede Album e Artisti) l'album e il suo artista sono già nell'intestazione:
                    // sotto il brano resta solo l'artista, e solo se diverso da quello dell'album (raccolte).
                    Text(differing).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let warning = track.warning {
                // Brano non trasferibile (es. solo nel cloud): niente icone né selezione, solo l'avviso
                // in evidenza a destra.
                // «Hi-Res»: capsula gialla piena (#FFC107) con testo nero, più leggibile; gli altri avvisi restano arancioni.
                let isHiRes = LocalTrack.losslessLabels.contains(warning)
                if warning == t("reason_cloud_only") {
                    // «Solo in cloud»: al posto del testo l'icona iCloud (SF Symbols), azzurro; il testo resta nel tooltip.
                    Image(systemName: "icloud")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 86/255, green: 189/255, blue: 228/255)) // azzurro #56BDE4
                        .padding(.horizontal, 4)
                        .help(warning)
                } else {
                Text(warning)
                    .font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(isHiRes ? Color(red: 1.0, green: 0.757, blue: 0.027) : Color.orange.opacity(0.25), in: Capsule())
                    .foregroundStyle(isHiRes ? Color.black : Color.orange)
                }
            } else if let originProvider = artworkOriginProvider {
                // Colonne di icone strette, a 1 pt l'una dall'altra (il resto della riga ha 10 pt di spaziatura).
                HStack(spacing: 1) {
                // Brano acquistato su iTunes Store (non bloccato ma con possibile DRM): icona arancione.
                Group {
                    if track.isPurchased {
                        Image(systemName: "bag")
                            .foregroundStyle(Color.statusNeutral)
                            .help(t("purchased_track_help"))
                    } else {
                        Color.clear
                    }
                }
                .font(.system(size: 14))
                .frame(width: 20)
                ArtworkOriginIcon(track: track, provider: originProvider, version: artworkRevision)
                if !selectionOnLeft, let onDevice = isOnDeviceCheck {
                    // Spazio fisso, così le icone restano allineate anche per i brani non ancora inviati.
                    Group {
                        if track.isDeviceOnly {
                            // Brano solo sul dispositivo: stessa colonna, stessa misura e stesso colore di «già inviato»
                            // (le due condizioni non possono coesistere).
                            Image(systemName: "watch.analog")
                                .foregroundStyle(statusIconGreen)
                                .help(t("tooltip_device_only_track"))
                        } else if onDevice(track) {
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(statusIconGreen)
                                .help(t("artwork_on_device"))
                        } else {
                            Color.clear
                        }
                    }
                    .font(.system(size: 14))
                    .frame(width: 20)
                }
                if category != .playlists, let lookup = playlistsContainingTrack {
                    // Quarta colonna: il brano è inserito in almeno una playlist (quali, lo dice il menu contestuale).
                    // Spazio fisso, per l'allineamento anche dei brani che non stanno in nessuna playlist.
                    Group {
                        if !lookup(track).isEmpty {
                            Image(systemName: "music.note.list")
                                .foregroundStyle(Color.statusNeutral)
                                .help(t("tooltip_in_playlist"))
                        } else {
                            Color.clear
                        }
                    }
                    .font(.system(size: 14))
                    .frame(width: 20)
                }
                }
            } else if let t = track.trailingText {
                Text(t).font(.caption).foregroundStyle(.secondary)
            }
            // Durata del brano: subito a sinistra del riquadro di selezione (cifre a larghezza fissa, allineate a
            // destra, così la colonna resta ordinata).
            // Durata del brano: subito a sinistra del riquadro di selezione.
            durationLabel(track)
            if selectionOnLeft {
                // Ultima colonna a destra (al posto della vecchia selezione): «già sul dispositivo» (freccia) oppure
                // «solo sul dispositivo» (orologio), sempre verdi. Larghezza fissa, anche vuota, per l'incolonnamento.
                if artworkOriginProvider != nil, let onDevice = isOnDeviceCheck {
                    Group {
                        if track.warning != nil {
                            Color.clear
                        } else if track.isDeviceOnly {
                            Image(systemName: "watch.analog")
                                .foregroundStyle(statusIconGreen)
                                .help(t("tooltip_device_only_track"))
                        } else if onDevice(track) {
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(statusIconGreen)
                                .help(t("artwork_on_device"))
                        } else {
                            Color.clear
                        }
                    }
                    .font(.system(size: 14))
                    .frame(width: 24, alignment: .center)
                }
            } else {
                // Accessorio finale (es. rimuovi dalla Custom Playlist): ultimo elemento a destra, colonna fissa.
                trailing()
                    .frame(width: 24, alignment: .center)
            }
        }
        // L'altoparlante del brano in riproduzione sta nel margine sinistro della riga, fuori dal flusso:
        // il titolo non si sposta rispetto agli altri brani.
        .overlay(alignment: .leading) {
            if let playingTrackID, playingTrackID == track.id {
                playingIndicator.offset(x: -15)
            }
        }
    }

    /// Durata del brano (cifre a larghezza fissa, allineate a destra).
    private func durationLabel(_ track: Track) -> some View {
        Text(track.duration > 0 ? formatDuration(track.duration) : "")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .frame(minWidth: 36, alignment: .trailing)
    }

    /// Indicatore del brano caricato nel mini player: altoparlante che in riproduzione pulsa da blu chiaro a
    /// blu scuro, in pausa diventa il simbolo della pausa.
    @ViewBuilder
    private var playingIndicator: some View {
        if let player {
            PlayingIndicatorView(player: player)
        } else {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 13)
        }
    }

    @ViewBuilder
    private func emptyOverlay(_ isEmpty: Bool, message: String? = nil) -> some View {
        if isEmpty {
            Text(deviceEmptyMessage ?? message ?? emptyMessage).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
        }
    }

    /// Lato dispositivo (nessun menu di riga, nessuna Custom Playlist) con il dispositivo senza musica:
    /// una scritta per ogni scheda («No Playlist Found», «No Artists Found»…). Nil altrove o durante una ricerca.
    private var deviceEmptyMessage: String? {
        guard rowMenu == nil, customPlaylist == nil, query.isEmpty, tracks.isEmpty, playlists.isEmpty else { return nil }
        switch category {
        case .playlists: return t("device_no_playlists")
        case .artists: return t("device_no_artists")
        case .albums: return t("device_no_albums")
        case .songs: return t("device_no_songs")
        case .customPlaylist: return nil
        }
    }

    // MARK: Filtri

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    /// Testo cercato nella Custom Playlist (separato da `query`).
    private var customQuery: String { customSearch.trimmingCharacters(in: .whitespaces) }

    private func matches(_ t: Track) -> Bool { matches(t, for: query) }

    private func matches(_ t: Track, for text: String) -> Bool {
        t.title.localizedCaseInsensitiveContains(text)
            || t.artist.localizedCaseInsensitiveContains(text)
            || t.album.localizedCaseInsensitiveContains(text)
    }

    // Ogni scheda cerca solo nel proprio campo: Brani → titolo del brano; Album → nome dell'album; Artisti → nome
    // dell'artista; Playlist → qualsiasi etichetta (titolo del brano, artista, album) oltre al nome della playlist.
    private var filteredSongs: [Track] {
        let scoped = scopedTracks
        let base = query.isEmpty ? scoped : scoped.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return onlyWithoutCover ? base.filter { coverScan[$0.id] == true } : base
    }

    /// Rilegge l'origine della copertina di tutti i brani (stessa via economica delle miniature: mai Musica mentre è
    /// aperta) e tiene quelli senza; i risultati compaiono a blocchi. Si rifà quando si attiva il filtro o cambia il numero
    /// di brani, non a ogni copertina caricata (altrimenti selezionando un brano l'elenco si ricaricherebbe).
    private var withoutCoverCount: Int? {
        onlyWithoutCover ? tracks.reduce(0) { coverScan[$1.id] == true ? $0 + 1 : $0 } : nil
    }

    /// `incremental`: ricontrolla solo i brani non ancora risultati «con copertina», senza indicatore di
    /// avanzamento; non parte se è già in corso una scansione completa (che coprirà comunque la novità).
    private func rescanCovers(incremental: Bool = false) {
        if incremental && isScanningCovers { return }
        coverScanTask?.cancel()
        guard onlyWithoutCover, let provider = artworkOriginProvider else {
            isScanningCovers = false
            return
        }
        let snapshot = incremental ? tracks.filter { coverScan[$0.id] != false } : tracks
        if !incremental { isScanningCovers = true }
        coverScanTask = Task {
            // Si parte dall'esito precedente e lo si aggiorna brano per brano: l'elenco non si svuota né si ricarica
            // durante la scansione (selezionare un brano carica la sua copertina ma non deve far sparire righe).
            var result = coverScan
            for (i, track) in snapshot.enumerated() {
                if Task.isCancelled { return }
                let origin = await provider(track)
                result[track.id] = (origin == ArtworkOrigin.none)
                if !incremental, i % 40 == 39 { coverScan = result }
            }
            if Task.isCancelled { return }
            if result != coverScan { coverScan = result }
            isScanningCovers = false
        }
    }

    /// Chiave che identifica «questi brani, questo genere, questa ricerca»: numero di brani e una campionatura degli id
    /// (circa 64 punti, più l'ultimo), abbastanza per riconoscere un'altra libreria o un aggiornamento dell'elenco senza scorrerlo tutto.
    private var derivedKey: String {
        var hasher = Hasher()
        let n = tracks.count
        hasher.combine(n)
        if n > 0 {
            let step = max(1, n / 64)
            var i = 0
            while i < n { hasher.combine(tracks[i].id); i += step }
            hasher.combine(tracks[n - 1].id)
        }
        return "\(hasher.finalize())|\(genreKey ?? "")|\(query)"
    }

    /// Brani filtrati e in ordine alfabetico per titolo (scheda Brani), in memoria finché non cambia la chiave.
    /// Con «solo senza copertina» il risultato dipende dalla scansione in corso: nessuna memoria.
    private var sortedFilteredSongs: [Track] {
        if onlyWithoutCover { return filteredSongs.sortedAlphabeticallyByTitle() }
        let key = derivedKey
        if derived.songsKey == key { return derived.songs }
        let value = filteredSongs.sortedAlphabeticallyByTitle()
        derived.songsKey = key
        derived.songs = value
        return value
    }

    private var filteredAlbums: [TrackGroup<Track>] {
        let key = derivedKey
        if derived.albumsKey == key { return derived.albums }
        let groups = scopedTracks.groupedByAlbum()
        let value = query.isEmpty ? groups : groups.filter { $0.title.localizedCaseInsensitiveContains(query) }
        derived.albumsKey = key
        derived.albums = value
        return value
    }

    private var filteredArtists: [TrackGroup<Track>] {
        let key = derivedKey
        if derived.artistsKey == key { return derived.artists }
        let groups = scopedTracks.groupedByAlbumArtist()
        let value = query.isEmpty ? groups : groups.filter { $0.title.localizedCaseInsensitiveContains(query) }
        derived.artistsKey = key
        derived.artists = value
        return value
    }

    private var filteredPlaylists: [TrackGroup<Track>] {
        let source = playlists   // il filtro per genere non si applica alle playlist
        guard !query.isEmpty else { return source }
        return source.compactMap { g in
            if g.title.localizedCaseInsensitiveContains(query) { return g }
            let found = g.tracks.filter(matches)
            return found.isEmpty ? nil : TrackGroup(id: g.id, title: g.title, subtitle: playlistSubtitle(found), tracks: found)
        }
    }
}

// MARK: - Custom Playlist: modelli di supporto

/// Un brano aggiunto alla Custom Playlist. Un `id` proprio (non quello del brano) permette allo
/// stesso brano di comparire più di una volta nella stessa playlist (caso confermato tramite
/// l'avviso "già presente, aggiungerlo comunque?"), senza che la List se ne lamenti per ID duplicati.
struct CustomPlaylistEntry<Track: CatalogTrack>: Identifiable {
    let id = UUID()
    let track: Track
}

/// Stato e azioni della scheda "Custom Playlist", passati da chi usa `CatalogBrowser` (qui solo il
/// pannello Apple Music): il browser si occupa solo dell'interfaccia di questa scheda (campo nome,
/// menu ordina per, elenco); il chiamante (AppViewModel) tiene lo stato vero e proprio, implementa
/// le azioni, e popola la playlist dall'esterno (pulsante "Invia alla Playlist" in ContentView
/// sulla selezione corrente di Playlist/Artisti/Album/Brani, col relativo controllo duplicati).
struct CustomPlaylistConfig<Track: CatalogTrack> {
    let name: String
    let onNameChange: (String) -> Void
    let entries: [CustomPlaylistEntry<Track>]
    let onRemove: (CustomPlaylistEntry<Track>.ID) -> Void
    /// Riordina la playlist (drag su/giù nell'elenco): stessa semantica di `onMove(perform:)`.
    let onMove: (IndexSet, Int) -> Void
    /// Criterio attualmente attivo nel menu "Ordina per" (tenuto da chi chiama, non da
    /// `CatalogBrowser`, cosi resta coerente anche quando viene cambiato da fuori, es. uno
    /// "Svuota playlist" che lo riporta a "Manuale").
    let sortOption: CustomPlaylistSortOption
    /// Riordina tutta la playlist secondo il criterio scelto nel menu "Ordina per" (vedi
    /// `CustomPlaylistSortOption`); il risultato resta comunque risistemabile a mano con il drag.
    let onSort: (CustomPlaylistSortOption) -> Void
    let onClear: () -> Void
    let onSendToWatch: () -> Void
    let onSaveToAppleMusic: () -> Void
    let isBusy: Bool
}

/// Criterio del menu "Ordina per" nella scheda Custom Playlist. "Manuale" (scelta predefinita, e
/// prima della lista) lascia l'ordine così com'è, risistemabile solo trascinando le righe; le
/// altre scelte riordinano subito tutta la playlist secondo il criterio scelto. Ordinando per
/// Album, i brani dello stesso album mantengono l'ordine del loro numero di traccia (vedi
/// `AppViewModel.customPlaylistConfig`).
enum CustomPlaylistSortOption: String, CaseIterable, Identifiable {
    case manual, trackName, artist, album, random

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return t("sort_by_manual")
        case .trackName: return t("sort_by_track_name")
        case .artist: return t("sort_by_artist")
        case .album: return t("sort_by_album")
        case .random: return t("sort_by_random")
        }
    }
}

/// Miniatura della copertina per una riga di brano o per l'intestazione di un album.
/// Carica l'immagine in modo asincrono al primo apparire e la mette in cache per la durata
/// della vista; se non c'è alcun provider, o il provider restituisce nil, mostra un segnaposto.
private struct ArtworkThumbnail<Track: CatalogTrack>: View {
    let track: Track
    let provider: ((Track) async -> Data?)?
    /// Numero di revisione delle copertine (vedi `CatalogBrowser.artworkRevision`): quando cambia,
    /// l'immagine viene ricaricata dal provider.
    let version: Int
    var size: CGFloat = 32
    /// Simbolo del segnaposto senza copertina: una nota per i brani, tre note per gli album.
    var placeholderSymbol = "music.note"

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: placeholderSymbol)
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        // Si rilancia sia quando la riga cambia brano sia quando cambia la revisione delle
        // copertine; l'immagine già mostrata resta finché quella nuova non è pronta.
        .task(id: "\(track.id)|\(version)") {
            guard let provider else { return }
            if let data = await provider(track), let img = NSImage(data: data) {
                image = img
            }
        }
    }
}


/// Icona che dice se la copertina è del brano (verde) o arriva solo dalla cache di Musica (grigio scuro).
extension Color {
    /// Colore neutro delle icone di stato informative (acquistato, origine copertina, in playlist): segue il tema ed è
    /// leggibile anche sulla riga selezionata. Il colore resta solo per ciò che conta (già sul dispositivo, avvisi).
    static let statusNeutral = Color.primary.opacity(0.65)
}

struct ArtworkOriginIcon<Track: CatalogTrack>: View {
    let track: Track
    let provider: (Track) async -> ArtworkOrigin
    let version: Int

    @State private var origin: ArtworkOrigin = .none

    var body: some View {
        Group {
            switch origin {
            case .own:
                Image(systemName: "photo.badge.checkmark")
                    .foregroundStyle(Color.statusNeutral)
                    .help(t("artwork_origin_own"))
            case .musicCache:
                Image(systemName: "photo.badge.arrow.down")
                    .foregroundStyle(Color.statusNeutral)
                    .help(t("artwork_origin_cache"))
            case .gmmCache:
                Image(systemName: "externaldrive.badge.checkmark")
                    .foregroundStyle(Color.statusNeutral)
                    .help(t("artwork_origin_gmm"))
            case .none:
                Color.clear
            }
        }
        .font(.system(size: 14))
        .frame(width: 20)
        .task(id: "\(track.id)|\(version)") {
            origin = await provider(track)
        }
    }
}


/// Indicatore di selezione sulla riga (la selezione si fa cliccando la riga; click sull'icona = deseleziona). Colore del testo
/// (nero in chiaro, bianco in scuro, al 85%): sta sopra il colore di evidenziazione scelto dall'utente e il verde non si vedeva.
/// - nessuna selezione: nessuna icona;
/// - brano scelto: `checkmark.rectangle`;
/// - gruppo (Playlist / Album / Artista) scelto in parte: `rectangle.on.rectangle.dashed`;
/// - gruppo scelto per intero: `rectangle.on.rectangle`.
private struct SelectToggleIcon: View {
    enum State { case none, partial, all }
    let state: State
    var hidden = false   // invisibile e non cliccabile, ma occupa lo spazio (incolonnamento)
    /// Intestazione di un gruppo (Playlist / Album / Artista) invece di un brano: cambia l'icona.
    var isGroup = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            switch state {
            case .none:
                Image(systemName: "square").foregroundStyle(.secondary)
            case .partial:
                Image(systemName: "rectangle.on.rectangle.dashed").foregroundStyle(Color.primary.opacity(0.85))
            case .all:
                Image(systemName: isGroup ? "rectangle.on.rectangle" : "checkmark.rectangle").foregroundStyle(Color.primary.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 15))   // 1 pt più delle altre icone di stato (14 pt)
        .frame(width: 24, alignment: .center)   // larghezza uguale per tutti i simboli: le colonne restano allineate
        // Il riquadro vuoto (nulla selezionato) non si disegna: la selezione si fa cliccando la riga, il riquadro è solo
        // un'indicazione di stato (verde se scelto o parziale). Lo spazio resta, così le colonne non si spostano; senza
        // riquadro il click passa alla riga.
        .opacity(hidden || state == .none ? 0 : 1)
        .allowsHitTesting(!(hidden || state == .none))
        .help(hidden || state == .none ? "" : (state == .all ? t("button_deselect") : t("button_select")))
    }
}


/// Altoparlante animato del brano in corso: in riproduzione il colore va avanti e indietro tra blu chiaro e blu
/// scuro; in pausa si ferma e diventa il simbolo della pausa.
struct PlayingIndicatorView: View {
    @ObservedObject var player: PlayerService
    @State private var pulse = false

    private static let light = Color(red: 0.0, green: 0.48, blue: 1.0)   // blu
    private static let dark = Color(red: 0.0, green: 0.30, blue: 0.70)   // blu scuro

    var body: some View {
        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
            .font(.system(size: 12))
            .foregroundStyle(player.isPlaying ? (pulse ? Self.dark : Self.light) : Self.light)
            .frame(width: 13)
            .onAppear { updateAnimation() }
            .onChange(of: player.isPlaying) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        if player.isPlaying {
            pulse = false
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { pulse = false }
        }
    }
}


/// Tasto digitato per il posizionamento negli elenchi.
struct TypeAheadEvent: Equatable {
    enum Kind { case character, delete, escape }
    let id: Int
    let kind: Kind
    let characters: String
}

/// Intercetta i tasti della finestra principale con un monitor locale di AppKit (la `List` di macOS è una tabella
/// AppKit: `onKeyPress` di SwiftUI non riceve i tasti e il sistema emette il suono di errore). Un tasto viene
/// consumato solo se `enabled`, la finestra è quella principale senza fogli aperti, non si sta scrivendo in un campo
/// di testo e il tasto è un carattere stampabile (lo spazio solo dopo la prima lettera; Esc e Cancella solo se c'è
/// già testo digitato). Frecce, Invio, Tab e scorciatoie con ⌘/⌃/⌥ passano invariati.
final class TypeAheadMonitor {
    var enabled = false
    var hasText = false
    var counter = 0
    /// Testo digitato e orario dell'ultimo tasto (orario dell'evento di tastiera, non quello in cui la vista lo elabora):
    /// con una lista grande l'interfaccia può restare occupata a scorrere, e allora i tasti si accumulano o si elaborano in
    /// ritardo. Il testo si compone qui, subito, e alla vista arriva sempre il testo completo.
    var text = ""
    /// Solo la prima lettera: i tasti successivi entro il secondo sono consumati e ignorati.
    var firstLetterOnly = false
    private var lastTime: TimeInterval = 0
    private var token: Any?

    func install(_ handler: @escaping (TypeAheadEvent.Kind, String) -> Void) {
        remove()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.enabled,
                  let window = event.window, window.isMainWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return event }
            let blocked: NSEvent.ModifierFlags = [.command, .control, .option]
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: blocked) else { return event }
            if event.keyCode == 53 {            // Esc
                guard self.hasText || !self.text.isEmpty else { return event }
                self.text = ""
                handler(.escape, "")
                return nil
            }
            if event.keyCode == 51 {            // Cancella
                guard self.hasText || !self.text.isEmpty else { return event }
                if !self.text.isEmpty { self.text.removeLast() }
                self.lastTime = event.timestamp
                handler(.delete, self.text)
                return nil
            }
            guard let characters = event.characters, characters.count == 1,
                  let scalar = characters.unicodeScalars.first else { return event }
            let allowed = CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols)
            guard allowed.contains(scalar) || (scalar == " " && (self.hasText || !self.text.isEmpty)) else { return event }
            if event.timestamp - self.lastTime > 1.0 { self.text = "" }   // pausa di oltre un secondo: si riparte da zero
            if self.firstLetterOnly, !self.text.isEmpty { return nil }    // già posizionati sulla prima lettera
            self.text += characters
            self.lastTime = event.timestamp
            handler(.character, self.text)
            return nil
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    deinit { remove() }
}


// MARK: - Scorrimento a una riga della tabella AppKit

/// Trova la tabella AppKit (NSTableView) dietro la `List` della scheda Playlist e la fa scorrere a una riga. Serve perché
/// `ScrollViewProxy.scrollTo` non raggiunge in modo affidabile i brani dentro le playlist aperte da codice.
@MainActor
final class ListScrollHandle {
    enum Result { case done, moved, failed }
    weak var view: NSView?

    /// Un passo di scorrimento verso un brano. Due possibili strutture della tabella (si riconosce dal numero di righe):
    /// - righe piatte (`flatTotal`): intestazioni e brani sono righe separate, brano alla riga `flatRow`;
    /// - blocchi (`blockTotal`): ogni playlist è una sola riga alta quanto intestazione + brani (`childCount` + 1 parti uguali).
    /// `.moved`: ci si è avvicinati, serve un altro passo; `.done`: il brano è al suo posto; `.failed`: tabella non riconosciuta.
    func scroll(flatRow: Int, flatTotal: Int, blockRow: Int, blockTotal: Int, childIndex: Int, childCount: Int) -> Result {
        guard let view, let root = view.window?.contentView else { return .failed }
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let candidates = Self.scrollViews(in: root, containing: center)
        let matching = candidates.first {
            let n = ($0.documentView as? NSTableView)?.numberOfRows
            return n == flatTotal || n == blockTotal
        }
        guard let scrollView = matching, let table = scrollView.documentView as? NSTableView else { return .failed }
        let clip = scrollView.contentView
        let visibleHeight = clip.bounds.height
        let minY = -scrollView.contentInsets.top
        let maxY = max(minY, table.bounds.height - visibleHeight + scrollView.contentInsets.bottom)
        func originY(centering yCenter: CGFloat) -> CGFloat {
            max(minY, min(yCenter - visibleHeight * 0.55, maxY))
        }
        func move(to y: CGFloat, animated: Bool) {
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
                }
            } else {
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            }
            scrollView.reflectScrolledClipView(clip)
        }
        if table.numberOfRows == flatTotal {
            let row = max(0, min(flatRow, flatTotal - 1))
            if let rowView = table.rowView(atRow: row, makeIfNecessary: false) {
                move(to: originY(centering: rowView.frame.midY), animated: true)
                return .done
            }
            move(to: originY(centering: table.rect(ofRow: row).midY), animated: false)
            return .moved
        }
        // Struttura a blocchi.
        let block = table.rect(ofRow: max(0, min(blockRow, blockTotal - 1)))
        let part = block.height / CGFloat(childCount + 1)
        let y = originY(centering: block.minY + part * (CGFloat(childIndex) + 1.5))
        if abs(clip.bounds.origin.y - y) < 3 { return .done }
        move(to: y, animated: false)
        return .moved
    }

    /// Gli scroll view con tabella visibili che contengono il punto (coordinate della finestra), dal più piccolo.
    fileprivate static func scrollViews(in root: NSView, containing point: NSPoint) -> [NSScrollView] {
        var found: [(NSScrollView, CGFloat)] = []
        func visit(_ v: NSView) {
            if let sv = v as? NSScrollView, sv.documentView is NSTableView, !sv.isHiddenOrHasHiddenAncestor {
                let frame = sv.convert(sv.bounds, to: nil)
                if frame.contains(point) { found.append((sv, frame.width * frame.height)) }
            }
            v.subviews.forEach(visit)
        }
        visit(root)
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

/// Spegne l'evidenziazione di selezione nativa (blu di sistema) della tabella AppKit dietro la `List`: le righe
/// selezionate restano colorate da `.listRowBackground` con il colore scelto in Impostazioni. Messa come sfondo della
/// lista, cerca la tabella risalendo la gerarchia fino al primo antenato che ne contiene una.
/// Riconoscimento del doppio click fatto a mano. `TapGesture(count: 2)` insieme a un click singolo che
/// cambia la selezione non scatta più: dopo il primo click la riga viene ridisegnata e il conteggio riparte.
/// Qui basta il click singolo: se lo stesso elemento riceve due click entro l'intervallo di doppio click
/// di sistema, il secondo è un doppio click.
private enum ClickTracker {
    private static var lastKey = ""
    private static var lastTime: TimeInterval = 0

    /// `true` se questo click è il secondo di un doppio click sullo stesso elemento (`key`).
    static func isDouble(_ key: String) -> Bool {
        // Orario dell'evento del mouse (non di quando il gestore viene eseguito): se il thread principale è occupato a
        // ridisegnare dopo il primo click, il secondo non perde tempo in coda e il doppio click viene riconosciuto lo stesso.
        let now = NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if key == lastKey, now - lastTime <= NSEvent.doubleClickInterval {
            lastKey = ""
            lastTime = 0
            return true
        }
        lastKey = key
        lastTime = now
        return false
    }
}

/// Sfondo di una riga selezionata: rettangolo dagli angoli smussati (come la selezione di sistema) nel colore scelto in Impostazioni.
private func rowHighlight(_ color: Color) -> some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color).padding(.horizontal, 4)
}

private struct HideNativeSelection: NSViewRepresentable {
    final class Coordinator { var done = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard !context.coordinator.done else { return }
        let state = context.coordinator
        // Su un Mac più lento la tabella AppKit può non esistere ancora al primo passaggio: si riprova qualche volta,
        // altrimenti resterebbe visibile la selezione nativa (angoli smussati) sotto quella colorata.
        for delay in [0.0, 0.25, 0.8, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak nsView] in
                guard !state.done else { return }
                var ancestor: NSView? = nsView?.superview
                while let a = ancestor {
                    if let table = Self.firstTable(in: a) {
                        table.selectionHighlightStyle = .none
                        state.done = true
                        return
                    }
                    ancestor = a.superview
                }
            }
        }
    }
    private static func firstTable(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView { return t }
        for sub in view.subviews { if let t = firstTable(in: sub) { return t } }
        return nil
    }
}

/// Vista invisibile messa dietro la lista: registra la propria posizione nel `ListScrollHandle`.
private struct ListScrollLocator: NSViewRepresentable {
    let handle: ListScrollHandle
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        handle.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { handle.view = nsView }
}


// MARK: - Lettera accanto al cursore di scorrimento

/// Stato mostrato dalla lettera: separato da `CatalogBrowser` così, mentre si scorre, si aggiorna solo la lettera e non
/// l'intera lista.
final class ScrollLetterModel: ObservableObject {
    @Published var letter = ""
    @Published var visible = false
    /// Altezza (dall'alto della lista) del centro del cursore di scorrimento: la lettera sta alla stessa altezza.
    @Published var centerY: CGFloat = 0
}

/// Segue lo scorrimento di una lista (tabella AppKit): ad ogni spostamento ricava la voce che sta in cima, sotto i
/// pannelli sovrapposti, e ne comunica l'iniziale; un secondo dopo l'ultimo movimento la lettera sparisce.
@MainActor
final class ScrollLetterTracker {
    let model = ScrollLetterModel()
    weak var view: NSView?
    /// Numeri di righe che la tabella di questa lista può avere (per riconoscerla tra le liste sovrapposte).
    var rowCounts: [Int] = []
    /// (riga, numero di righe della tabella) → lettera.
    var letterForRow: ((Int, Int) -> String?)?
    private weak var observedClip: NSClipView?
    private var observer: NSObjectProtocol?
    private var hideTask: Task<Void, Never>?
    private var lastY: CGFloat = .nan

    func attachSoon() {
        Task { @MainActor [weak self] in self?.attach() }
    }

    private func attach() {
        guard let view, let root = view.window?.contentView else { return }
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let candidates = ListScrollHandle.scrollViews(in: root, containing: center)
        let match = candidates.first { rowCounts.contains(($0.documentView as? NSTableView)?.numberOfRows ?? -1) }
        guard let scrollView = match ?? candidates.first else { return }
        let clip = scrollView.contentView
        if observedClip === clip { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        clip.postsBoundsChangedNotifications = true
        observedClip = clip
        lastY = .nan
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundsChanged() }
        }
    }

    /// Altezza del centro del cursore, dall'alto della vista della lista. Si ricava dalla posizione di scorrimento e dalla
    /// geometria del cursore (guida e proporzione), non dal valore del cursore stesso, che può aggiornarsi dopo.
    /// Senza cursore verticale si usa la parte della lista sotto i pannelli.
    private func knobCenterY(of scrollView: NSScrollView, fraction: CGFloat, fallbackTop: CGFloat) -> CGFloat {
        guard let view else { return 0 }
        func visualTop(_ r: NSRect) -> CGFloat { view.isFlipped ? r.minY : view.bounds.height - r.maxY }
        guard let scroller = scrollView.verticalScroller, !scroller.isHidden else {
            return fallbackTop + fraction * max(0, view.bounds.height - fallbackTop)
        }
        let slot = scroller.convert(scroller.rect(for: .knobSlot), to: view)
        let slotTop = visualTop(slot)
        let slotHeight = slot.height
        let knobHeight = min(slotHeight, max(20, slotHeight * CGFloat(scroller.knobProportion)))
        return slotTop + knobHeight / 2 + fraction * (slotHeight - knobHeight)
    }

    private func boundsChanged() {
        guard let clip = observedClip, let scrollView = clip.superview as? NSScrollView,
              let table = scrollView.documentView as? NSTableView,
              !scrollView.isHiddenOrHasHiddenAncestor, table.numberOfRows > 1 else { return }
        let y = clip.bounds.origin.y
        defer { lastY = y }
        guard !lastY.isNaN, abs(y - lastY) > 0.5 else { return }
        // Voce in cima sotto i pannelli: la riga di margine in alto (la prima) ha l'altezza dei pannelli sovrapposti.
        let inset = table.rect(ofRow: 0).height
        let readY = min(max(y + inset + 4, 0), table.bounds.height - 1)
        let row = max(0, table.row(at: NSPoint(x: table.bounds.midX, y: readY)))
        guard let letter = letterForRow?(row, table.numberOfRows) else { return }
        let minY = -scrollView.contentInsets.top
        let maxY = max(minY, table.bounds.height - clip.bounds.height + scrollView.contentInsets.bottom)
        let fraction = maxY > minY ? max(0, min(1, (y - minY) / (maxY - minY))) : 0
        model.letter = letter
        model.centerY = knobCenterY(of: scrollView, fraction: fraction, fallbackTop: inset)
        model.visible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { self?.model.visible = false }
        }
    }
}

/// Vista invisibile dietro la lista: collega il tracker alla lista e lo riattacca quando entra nella finestra.
private struct ScrollLetterLocator: NSViewRepresentable {
    let tracker: ScrollLetterTracker
    let rowCounts: [Int]
    let letterForRow: (Int, Int) -> String?

    final class LocatorView: NSView {
        weak var tracker: ScrollLetterTracker?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tracker?.attachSoon()
        }
    }

    func makeNSView(context: Context) -> NSView {
        let v = LocatorView()
        v.tracker = tracker
        tracker.view = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        tracker.view = nsView
        tracker.rowCounts = rowCounts
        tracker.letterForRow = letterForRow
        tracker.attachSoon()
    }
}

/// Capsula con la lettera, a destra accanto al cursore e all'altezza del cursore; compare mentre si scorre. Mentre si digita
/// per posizionarsi (`typed`) mostra il testo digitato al posto della lettera e resta visibile finché si scrive.
private struct ScrollLetterBubble: View {
    @ObservedObject var model: ScrollLetterModel
    var typed: String = ""

    var body: some View {
        GeometryReader { geo in
            let showTyped = !typed.isEmpty
            let y = min(max(model.centerY, 22), max(22, geo.size.height - 22))
            // Le ultime 24 lettere al massimo; `fixedSize` evita che la capsula si allarghi a tutta la lista (altezza e larghezza
            // sono quelle del testo, minimo 44 pt) e che `offset` la sposti in basso.
            Text(showTyped ? String(typed.suffix(24)) : model.letter)
                .font(.system(size: showTyped ? 20 : 26, weight: .bold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, showTyped ? 14 : 0)
                .frame(minWidth: 44, minHeight: 44)
                .fixedSize(horizontal: true, vertical: true)
                .background(showTyped ? AnyShapeStyle(Material.thick) : AnyShapeStyle(Material.ultraThin.opacity(0.7)),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay { if showTyped { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5) } }
                .padding(.trailing, 24)
                .offset(y: y - 22)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
                .opacity((model.visible || showTyped) ? (showTyped ? 0.95 : 0.8) : 0)
                .animation(.easeOut(duration: 0.2), value: model.visible)
                .animation(.easeOut(duration: 0.2), value: showTyped)
        }
        .allowsHitTesting(false)
    }
}


/// Selezione a trascinamento sulla tabella AppKit dietro la `List` dei Brani: un monitor locale degli eventi del mouse
/// (senza consumarli, quindi click e doppio click restano quelli di prima) segue il trascinamento e comunica la riga di
/// partenza e quella sotto il cursore (indici dell'elenco: la tabella ha una riga di margine sopra e una sotto). Ai bordi
/// la tabella scorre da sola (`autoscroll`).
private struct SongDragSelector: NSViewRepresentable {
    let onDrag: (_ anchor: Int, _ current: Int) -> Void
    let onEnd: () -> Void

    final class Coordinator {
        var parent: SongDragSelector
        var monitor: Any?
        weak var view: NSView?
        var anchorRow: Int?
        var startPoint: NSPoint = .zero
        var dragging = false
        /// Controllo periodico del tasto premuto e della posizione del mouse: gli eventi di trascinamento possono non
        /// passare dal monitor (se la tabella AppKit li consuma nel proprio ciclo di tracciamento), la lettura diretta
        /// di `NSEvent.pressedMouseButtons` / `mouseLocation` no. Aggiunto in modalità `.common` per girare anche
        /// durante un ciclo di tracciamento.
        var timer: Timer?
        init(_ p: SongDragSelector) { parent = p }
        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
            timer?.invalidate()
        }

        func startTimer() {
            timer?.invalidate()
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        func finish() {
            timer?.invalidate()
            timer = nil
            if dragging { parent.onEnd() }
            dragging = false
            anchorRow = nil
        }

        /// Un passo del trascinamento: legge posizione e tasto direttamente dal sistema.
        func tick() {
            guard let anchor = anchorRow, let view, view.window != nil, let t = table(), let window = t.window else { finish(); return }
            guard NSEvent.pressedMouseButtons & 1 != 0 else { finish(); return }
            let p = t.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if !dragging {
                guard hypot(p.x - startPoint.x, p.y - startPoint.y) >= 4 else { return }
                dragging = true
            }
            autoscroll(t, pointer: p)
            if let current = itemRow(in: t, at: p) { parent.onDrag(anchor - 1, current - 1) }
        }

        /// Scorrimento automatico quando il cursore esce dal bordo alto o basso dell'elenco visibile.
        func autoscroll(_ t: NSTableView, pointer p: NSPoint) {
            guard let scroll = t.enclosingScrollView else { return }
            let clip = scroll.contentView
            let vis = t.visibleRect
            var dy: CGFloat = 0
            // Velocità contenuta: circa 1,5 pt per passo (30 passi al secondo) appena fuori dal bordo, fino a 12 pt lontano.
            if p.y < vis.minY + 6 { dy = -min(12, (vis.minY + 6 - p.y) * 0.1 + 1.5) }
            else if p.y > vis.maxY - 6 { dy = min(12, (p.y - (vis.maxY - 6)) * 0.1 + 1.5) }
            guard dy != 0 else { return }
            let maxY = max(0, t.frame.height - clip.bounds.height)
            let newY = min(max(0, clip.bounds.origin.y + dy), maxY)
            guard newY != clip.bounds.origin.y else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: newY))
            scroll.reflectScrolledClipView(clip)
        }

        func table() -> NSTableView? {
            var ancestor: NSView? = view?.superview
            while let a = ancestor {
                if let t = Self.firstTable(in: a) { return t }
                ancestor = a.superview
            }
            return nil
        }
        static func firstTable(in view: NSView) -> NSTableView? {
            if let t = view as? NSTableView { return t }
            for sub in view.subviews { if let t = firstTable(in: sub) { return t } }
            return nil
        }
        /// Riga di elenco (1…n nella tabella) sotto il punto, limitata agli estremi.
        func itemRow(in t: NSTableView, at p: NSPoint) -> Int? {
            let n = t.numberOfRows - 2
            guard n > 0 else { return nil }
            var row = t.row(at: p)
            if row < 0 {
                row = p.y < t.rect(ofRow: 1).minY ? 1 : n
            }
            return max(1, min(row, n))
        }

        func handle(_ event: NSEvent) {
            guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor, let t = table(), event.window == t.window else { return }
            let p = t.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                dragging = false
                anchorRow = nil
                let visible = t.visibleRect
                // Il click deve cadere davvero su questa tabella (le liste delle altre schede restano sovrapposte e nascoste).
                let hit = t.window?.contentView?.hitTest(event.locationInWindow)
                guard visible.contains(p), let hit, hit === t || hit.isDescendant(of: t), let row = itemRow(in: t, at: p), t.row(at: p) >= 1 else { return }
                anchorRow = row
                startPoint = p
                startTimer()
            case .leftMouseDragged:
                tick()
            case .leftMouseUp:
                finish()
            default: break
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let c = context.coordinator
        c.view = v
        c.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak c] event in
            c?.handle(event)
            return event
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.parent = self }
}


// MARK: - Finestra «Trova simili»

/// Elenco dei brani più simili a quelli di partenza, ordinato per punteggio, con una barra da 0 al massimo ottenibile.
/// Righe come nell'elenco Brani: click per scegliere (si sommano), doppio click per ascoltare. «OK» somma i brani scelti
/// alla selezione già fatta, «Invia a Custom» li manda alla Custom Playlist, «Annulla» chiude senza fare nulla.
struct SimilarTracksSheet: View {
    let request: SimilarRequest
    let artworkProvider: ((LocalTrack) async -> Data?)?
    let artworkRevision: Int
    let onPlay: (LocalTrack, [LocalTrack]) -> Void
    let onOK: (Set<String>) -> Void
    let onSendToCustom: ([LocalTrack]) -> Void
    /// Invio diretto al dispositivo dei brani scelti (attivo solo con un dispositivo scrivibile e nessuna operazione in corso).
    var canSendToDevice: Bool = false
    var onSendToDevice: ([LocalTrack]) -> Void = { _ in }
    let onCancel: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var picked = Set<String>()

    private var queue: [LocalTrack] { request.results.map(\.track) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("similar_title", request.title)).font(.title3.weight(.semibold)).lineLimit(2)
            Text(t(request.usesBPM || request.usesYear ? "similar_caption_extra" : "similar_caption")).font(.caption).foregroundStyle(.secondary)
            if request.results.isEmpty {
                Text(t("similar_empty")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(request.results) { result in
                        row(result)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture().onEnded {
                                toggle(result.id)
                                if ClickTracker.isDouble("f:\(result.id)") { onPlay(result.track, queue) }
                            })
                            .listRowBackground(picked.contains(result.id) ? rowHighlight(settings.highlightColor) : nil)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            if !request.results.isEmpty {
                Text(t("similar_footnote")).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(t("similar_selected_count", picked.count, request.results.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(t("button_cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                // Stessi testi e icone dei pulsanti della finestra principale («To Custom», invio con la freccia).
                Button { onSendToCustom(request.results.map(\.track).filter { picked.contains($0.id) }) } label: {
                    Label(t("button_send_to_playlist"), systemImage: "tray.and.arrow.down")
                }
                .disabled(picked.isEmpty)
                Button { onSendToDevice(request.results.map(\.track).filter { picked.contains($0.id) }) } label: {
                    Label(t("button_to_device"), systemImage: "arrow.right.circle.fill")
                }
                .disabled(picked.isEmpty || !canSendToDevice)
                Button("OK") { onOK(picked) }
                    .buttonStyle(.flatProminentRoomy)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
            }
        }
        .padding(16)
        .modifier(SheetFrame(width: 720, height: 560))
    }

    private func toggle(_ id: String) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    private func row(_ result: SimilarResult) -> some View {
        let track = result.track
        return HStack(spacing: 10) {
            ArtworkThumbnail(track: track, provider: artworkProvider, version: artworkRevision, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.system(size: settings.listTextSize.points)).lineLimit(1)
                Text("\(track.artist) — \(track.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            scoreBar(result.score, plays: track.playCountStored)
            SelectToggleIcon(state: picked.contains(result.id) ? .all : .none) { toggle(result.id) }
        }
    }

    /// Colore della barra: dal verde (il più affine dell'elenco) al rosso (il meno affine), passando per giallo e arancione.
    /// Si confronta con il migliore e il peggiore dei risultati mostrati (non col massimo teorico, che quasi nessuno raggiunge).
    private func affinityColor(_ score: Double) -> Color {
        let scores = request.results.map(\.score)
        guard let lo = scores.min(), let hi = scores.max(), hi > lo else { return Color(hue: 0.33, saturation: 0.7, brightness: 0.8) }
        let x = min(1, max(0, (score - lo) / (hi - lo)))
        return Color(hue: 0.33 * x, saturation: 0.75, brightness: 0.85)
    }

    /// Barra del punteggio: da 0 al massimo ottenibile con i dati dei brani di partenza.
    private func scoreBar(_ score: Double, plays: Int?) -> some View {
        let fraction = request.maxScore > 0 ? min(1, score / request.maxScore) : 0
        return HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                GeometryReader { geo in
                    Capsule().fill(affinityColor(score)).frame(width: geo.size.width * CGFloat(fraction))
                }
            }
            .frame(width: 90, height: 6)
            // Percentuale = punteggio / massimo ottenibile (la stessa proporzione della lunghezza della barra).
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .help(t("similar_score_help", String(format: "%.1f", score), String(format: "%.1f", request.maxScore))
              + (plays.map { "\n" + ($0 == 0 ? t("similar_never_played") : t("similar_played_n", $0)) } ?? ""))
    }
}

/// Riepilogo della Custom Playlist con, dopo una barra, lo spazio che occupano i file (omesso se le dimensioni non sono note).
func customPlaylistHeaderText<T: CatalogTrack>(_ tracks: [T]) -> String {
    let bytes = tracks.reduce(Int64(0)) { $0 + $1.sizeInBytes }
    let summary = customPlaylistSummary(tracks)
    guard bytes > 0 else { return summary }
    return summary + " / " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
