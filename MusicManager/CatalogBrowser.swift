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
    /// Conteggi per gruppo (non trasferibili, acquistati): si calcolano una volta, non a ogni ridisegno dell'intestazione (build 25).
    struct GroupStats { var count = 0; var blocked = 0; var purchased = 0 }
    var groupStats: [String: GroupStats] = [:]
    var statsCount = -1
    var statsFirstID: Track.ID?
    var statsLastID: Track.ID?
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
    /// Balloon dell'icona «in playlist» del dispositivo: nomi, quante altre e riquadro dell'icona (nello spazio «catalogBrowser»).
    struct MembershipHover: Equatable {
        let names: [String]
        let more: Int
        let frame: CGRect
    }
    @State private var membershipHover: MembershipHover?
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
    /// 2.3 Beta 3 (pannello dispositivo): invece del suggerimento nativo, l'icona «in playlist» mostra subito un balloon con i nomi
    /// delle playlist (come quello della barra della memoria) e la colonna esiste anche senza icone di copertina.
    var showsInstantMembershipBalloon = false
    func instantMembershipBalloon() -> Self {
        var copy = self
        copy.showsInstantMembershipBalloon = true
        return copy
    }
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
    /// Miniature degli artisti: scaricarle da Apple Music solo per la libreria locale (default no). Librerie remote, unità esterne
    /// e dispositivo usano solo quelle già in cache (`ArtistThumbnailService.cachedThumbnail`).
    var downloadsArtistThumbnails = false
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
    /// Selezione di prima di un invio del solo brano cliccato dal menu; si ripristina a invio concluso.
    @State private var selectionToRestore: Set<Track.ID>?
    @State private var restoreSawBusy = false
    @State private var restoreWaitsForClear = false
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
    @State private var customSelectionAnchor: UUID?
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

    /// Consente la ricerca online delle miniature degli artisti (solo libreria locale).
    func artistThumbnailDownload(_ value: Bool) -> Self {
        var copy = self
        copy.downloadsArtistThumbnails = value
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
            .coordinateSpace(name: "catalogBrowser")
            .overlay { membershipBalloonOverlay }
            // Invio del solo brano cliccato (fuori dalla selezione): a invio concluso si ripristina la selezione di prima.
            .onChange(of: rowMenu?.isBusy) { _, busy in
                guard let busy, selectionToRestore != nil else { return }
                if busy { restoreSawBusy = true }
                else if restoreSawBusy, !restoreWaitsForClear { restoreSelectionAfterSingleSend() }
            }
            // Invio al dispositivo del solo brano cliccato: appena l'app svuota la selezione a fine copia, si rimette quella di prima.
            .onChange(of: selection) { _, new in
                guard restoreWaitsForClear, selectionToRestore != nil else { return }
                if new.isEmpty { if restoreSawBusy { restoreSelectionAfterSingleSend() } }
                else if new.count != 1 { selectionToRestore = nil; restoreWaitsForClear = false }   // l'utente ha scelto altro: niente ripristino
            }
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

    /// Larghezza di ogni scheda del selettore. 2.3 Beta 2: **fissa** a risoluzione normale (prima era quella della dicitura
    /// più lunga nella lingua corrente, e la barra cambiava misura passando da italiano a inglese). 80 pt bastano per icona +
    /// «Playlists» (la dicitura più lunga delle due lingue) con il carattere di sistema.
    private static var categorySegmentWidth: CGFloat { 80 }

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
                        if !compactPane { Text(c.title).lineLimit(1).minimumScaleFactor(0.85) }
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
                    if genreFilterEnabled, category != .customPlaylist, category != .playlists, !genreList.isEmpty { genreMenu }
                    // «Artista in evidenza» (2.3 Beta 2): pillola con due pulsanti a sola icona (brano / artista, la scelta resta
                    // evidenziata) e, come terzo segmento, l'ordinamento della Custom Playlist.
                    if category == .customPlaylist, let customPlaylist {
                        // Con la Custom vuota non c'è nulla da mostrare né da ordinare: i tre pulsanti sono spenti.
                        let isEmpty = customPlaylist.entries.isEmpty
                        artistFirstSwitch(customPlaylist)
                            .disabled(isEmpty)
                            .opacity(isEmpty ? 0.4 : 1)
                    }
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

    /// Doppio pulsante (icone brano / artista) per scegliere cosa mostrare sulla riga principale della Custom Playlist: lo stesso
    /// dato dell'interruttore in Impostazioni. La scelta attiva ha il colore di selezione.
    private func artistFirstSwitch(_ customPlaylist: CustomPlaylistConfig<Track>) -> some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { artist in
                Button { settings.customArtistFirst = artist } label: {
                    Image(systemName: artist ? "person.fill" : "music.note")
                        .frame(width: 30, height: 24)
                        .background(settings.customArtistFirst == artist ? settings.highlightColor : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(artist ? t("tooltip_custom_artist_first") : t("tooltip_custom_title_first"))
                .accessibilityAddTraits(settings.customArtistFirst == artist ? .isSelected : [])
            }
            sortMenu(customPlaylist)
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }

    /// «Ordina per» della Custom Playlist come pulsante a menu con icona (come il filtro genere): grigia con l'ordine manuale,
    /// blu quando la playlist è ordinata (criterio nel tooltip e con la spunta nel menu). Prima era un menu a tendina con etichetta.
    private func sortMenu(_ customPlaylist: CustomPlaylistConfig<Track>) -> some View {
        let current = customPlaylist.sortOption
        // Il segmento si disegna da sé (icona e fondo identici a quelli dei due pulsanti accanto) e il menu, trasparente, gli sta sopra:
        // un menu macOS con etichetta propria non aggiornava l'icona al cambio di ordinamento e scartava il fondo.
        // Stati: Manuale = icona nera; Titolo/Artista/Album = icona nel colore di selezione; Casuale = fondo nel colore di selezione, icona nera.
        return Image(systemName: sortIconName(current))
            .foregroundStyle(sortIconColor(current))
            .frame(width: 30, height: 24)
            .background(current == .random ? settings.highlightColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                Menu {
                    ForEach(CustomPlaylistSortOption.allCases.filter { $0 != .random }) { option in
                        Toggle(option.title, isOn: Binding(get: { current == option }, set: { _ in customPlaylist.onSort(option) }))
                    }
                    Divider()
                    Toggle(CustomPlaylistSortOption.random.title,
                           isOn: Binding(get: { current == .random }, set: { _ in customPlaylist.onSort(.random) }))
                } label: {
                    Color.clear.frame(width: 30, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)   // .plain: il clic vale su tutto il segmento, non solo sul centro dell'icona
                .menuIndicator(.hidden)
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
            }
            .help(current == .manual ? t("sort_by_label") : t("sort_by_label") + ": " + current.title)
    }

    /// Icona dell'ordinamento attivo: frecce per Manuale, le icone delle schede per Titolo (Brani) / Artista / Album, «shuffle» per Casuale.
    private func sortIconName(_ option: CustomPlaylistSortOption) -> String {
        switch option {
        case .manual: return "arrow.up.arrow.down"
        case .trackName: return CatalogCategory.songs.iconName
        case .artist: return CatalogCategory.artists.iconName
        case .album: return CatalogCategory.albums.iconName
        case .random: return "shuffle"
        }
    }

    /// Colore dell'icona di ordinamento: Manuale = come le altre icone della barra; Titolo/Artista/Album = colore di selezione;
    /// Casuale = nero su fondo nel colore di selezione.
    private func sortIconColor(_ option: CustomPlaylistSortOption) -> Color {
        switch option {
        case .manual: return Color.primary
        case .random: return Color.black
        case .trackName, .artist, .album: return settings.selectionSolidColor
        }
    }

    /// Filtro per genere (2.3 Beta 2): stessa pillola dell'ordinamento della Custom (un solo segmento, 30 × 24 pt su fondo tenue), con
    /// l'icona disegnata da noi e il menu trasparente sopra. Icona nera senza filtro, nel colore di selezione con il filtro applicato.
    private var genreMenu: some View {
        let active = genreList.first { $0.key == genreKey }
        let color: Color = active == nil ? Color.primary : settings.selectionSolidColor
        return HStack(spacing: 2) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(color)
                .frame(width: 30, height: 24)
                .overlay {
                    Menu {
                        // Toggle: nei menu di macOS è l'unico modo affidabile per avere la spunta sulla voce scelta.
                        Toggle(t("genre_all"), isOn: Binding(get: { genreKey == nil }, set: { _ in genreKey = nil }))
                        Divider()
                        ForEach(genreList, id: \.key) { entry in
                            let title = (entry.key.isEmpty ? t("genre_none") : entry.name) + " (\(entry.count))"
                            Toggle(title, isOn: Binding(get: { genreKey == entry.key }, set: { _ in genreKey = entry.key }))
                        }
                    } label: {
                        Color.clear.frame(width: 30, height: 24).contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)   // .plain: il clic vale su tutto il segmento, non solo sul centro dell'icona
                    .menuIndicator(.hidden)
                    .frame(width: 30, height: 24)
                    .contentShape(Rectangle())
                }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
        // Solo l'icona: con il filtro attivo il tooltip riporta il genere scelto; nel menu la voce scelta ha la spunta.
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
    /// Con librerie grandi (remote, su unità) si tiene viva SOLO la scheda in vista (build 27): le altre liste nascoste restavano
    /// con tutte le righe create (Brani da 55.000 righe: oltre 1 GB) e a ogni clic SwiftUI le aggiornava tutte. Si perde la
    /// posizione di scorrimento al cambio scheda, solo oltre `keepAliveTrackLimit` brani.
    private static var keepAliveTrackLimit: Int { 5000 }
    private func isLive(_ c: CatalogCategory) -> Bool {
        category == c || (tracks.count <= Self.keepAliveTrackLimit && visitedCategories.contains(c))
    }

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
                    SelectToggleIcon(state: selection.contains(track.id) ? .all : .none, hidden: track.isBlocked) {
                        toggleSelection(track.id)
                    }
                }
                // Nell'elenco Brani le righe non sono annidate in un gruppo: senza questo margine l'altoparlante del
                // brano in riproduzione, che sta a sinistra del titolo, verrebbe tagliato dal bordo della riga.
                .padding(.leading, 18)
                .tag(track.id)
                .selectionDisabled(track.isBlocked)
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
                        let ids = items[min(a, b)...max(a, b)].filter { !$0.isBlocked }.map(\.id)
                        if selection.contains(anchorID) { selection.formUnion(ids) } else { selection.subtract(ids) }
                        return
                    }
                    if !track.isBlocked { toggleSelection(track.id) }
                    songAnchorID = track.id
                    if ClickTracker.isDouble("s:\(track.id)") { onPlay?(track, items, nil) }
                })
                // Sfondo evidenziato (colore scelto in Impostazioni) quando il brano è selezionato.
                .listRowBackground(selection.contains(track.id) ? rowHighlight(settings.highlightColor) : nil)
                .contextMenu {
                    contextMenuItems(isSelected: selection.contains(track.id), artworkTracks: { tracks.filter { selection.contains($0.id) || $0.id == track.id } }, goTo: track, membershipTrack: track, similarSeeds: [track], full: true, focusTrack: track, sendIDs: { menuSendIDs(for: track) }) { if !track.isBlocked { toggleSelection(track.id) } }
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
                handleTypeAhead(event, entries: items.map { ($0.id, $0.title) }, rowOffset: Self.typeAheadSongRowOffset, proxy: proxy,
                                fastScroll: typeAheadFirstLetterOnly ? nil : { index in directScrollSongs(toItem: index, total: items.count) })
            }
            }
    }

    /// Posizionamento da tastiera: digitando alcune lettere la lista scorre fino alla voce che inizia così (o più simile:
    /// quella con più caratteri iniziali in comune). Non cambia la selezione. Un secondo di pausa azzera il testo digitato;
    /// Esc e Cancella lo azzerano / ne tolgono l'ultima lettera. Maiuscole e accenti sono ignorati.
    /// I tasti arrivano da `TypeAheadMonitor` (AppKit), che decide già quali intercettare.
    private func handleTypeAhead<ID: Hashable>(_ event: TypeAheadEvent, entries: [(ID, String)], rowOffset: Int, proxy: ScrollViewProxy, fastScroll: ((Int) -> Bool)? = nil) {
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
        scrollToBestMatch(entries, text: typed, rowOffset: rowOffset, proxy: proxy, fastScroll: fastScroll)
    }

    /// Articoli iniziali ignorati nel posizionamento da tastiera (italiano, inglese, spagnolo, francese, tedesco), già in
    /// minuscolo e senza accenti, con lo spazio (o l'apostrofo) che li separa dal resto del titolo.
    private static var leadingArticles: [String] {   // calcolata: i tipi generici non hanno proprietà statiche memorizzate
        ["the ", "a ", "an ", "il ", "lo ", "la ", "i ", "gli ", "le ", "l'", "un ", "uno ", "una ", "un'",
         "el ", "los ", "las ", "les ", "der ", "die ", "das ", "ein ", "eine "]
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
    private func scrollToBestMatch<ID: Hashable>(_ entries: [(ID, String)], text: String, rowOffset: Int, proxy: ScrollViewProxy, fastScroll: ((Int) -> Bool)? = nil) {
        func norm(_ text: String) -> String {
            text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
        }
        let typed = Array(norm(text))
        guard !typed.isEmpty else { return }
        // Spazi e articoli iniziali non contano («The Beatles» si trova digitando «beatles»; digitando «the» si trova comunque):
        // per ogni titolo vale la corrispondenza migliore tra il titolo intero e il titolo senza spazi/articolo iniziali.
        func matchLength(_ candidate: [Character]) -> Int {
            var n = 0
            while n < typed.count, n < candidate.count, candidate[n] == typed[n] { n += 1 }
            return n
        }
        let searchStart = Date()
        var bestIndex: Int?
        var bestLength = 0
        for (index, (_, title)) in entries.enumerated() {
            // Si normalizza solo l'inizio del titolo (build 28): con 55.000 voci normalizzare i titoli interi costa secondi.
            let head = norm(String(title.prefix(typed.count + 8)))
                .replacingOccurrences(of: "\u{2019}", with: "'")
                .replacingOccurrences(of: "\u{2018}", with: "'")
            let trimmed = String(head.drop(while: { $0.isWhitespace }))
            var n = matchLength(Array(trimmed))
            if n < typed.count, let article = Self.leadingArticles.first(where: { trimmed.hasPrefix($0) }) {
                let rest = trimmed.dropFirst(article.count).drop(while: { $0.isWhitespace })
                n = max(n, matchLength(Array(rest)))
            }
            if n > bestLength {
                bestLength = n
                bestIndex = index
                if n == typed.count { break }   // prima voce che inizia con tutto il testo digitato
            }
        }
        let searchTime = Date().timeIntervalSince(searchStart)
        if let bestIndex {
            let scrollStart = Date()
            // Liste molto grandi (build 29): `scrollTo` di SwiftUI su 55.000 righe impiegava 7 s + 3,7 s e +350 MB. Si porta
            // direttamente la tabella AppKit alla posizione (come fa il cursore di scorrimento), poi si affina.
            // La voce trovata sta una riga sotto la precedente (ultima della lettera prima), entrambe visibili sotto i pannelli.
            // Build 33: -2 (nella 32, con -1, la voce finiva sotto il pannello e la riga precedente restava nascosta).
            if let fastScroll, fastScroll(max(0, bestIndex - 2)) {
            } else {
                proxy.scrollTo(entries[max(0, bestIndex - rowOffset)].0, anchor: .top)
            }
            let what = "Digitazione «\(text)» (\(category)): voce \(bestIndex + 1) di \(entries.count), ricerca \(String(format: "%.2f", searchTime)) s, scorrimento \(String(format: "%.2f", Date().timeIntervalSince(scrollStart))) s"
            AppLog.debug("[prestazioni] " + what)
            StallWatchdog.lastAction = what
            PerfLag.measure(what)
        }
    }

    /// Porta la tabella AppKit dell'elenco Brani in modo che la voce `index` stia in cima sotto i pannelli, senza passare da
    /// `ScrollViewProxy.scrollTo` (lentissimo con decine di migliaia di righe). Stima l'altezza media della riga e corregge
    /// con qualche passo guardando quale riga è davvero in cima. Restituisce false se la tabella non si riconosce.
    private func directScrollSongs(toItem index: Int, total: Int) -> Bool {
        directScrollTable(view: songsLetters.view, rowCount: total + 2, wantedRow: index + 1)
    }

    /// Come sopra per Album/Artisti: `groupIndex` è l'indice del gruppo da portare in cima; la riga della tabella si ricava
    /// contando le righe dei gruppi precedenti (intestazioni, più i brani/album dei gruppi aperti).
    /// Righe «Disco n di m» di un album aperto (0 se ha un solo disco): sono righe della tabella e vanno contate.
    private func discRowCount(_ g: TrackGroup<Track>) -> Int {
        let discs = Set(g.tracks.map { max($0.discNumber, 1) })
        let total = max(g.tracks.map(\.discCount).max() ?? 0, discs.count)
        return (discs.count > 1 || total > 1) ? discs.count : 0
    }

    private func directScrollGroups(_ groups: [TrackGroup<Track>], toGroup groupIndex: Int, tracker: ScrollLetterTracker) -> Bool {
        var row = 1
        var total = 2
        for (i, g) in groups.enumerated() {
            var n = 1
            if expandedGroups.contains(g.id) {
                if g.subgroups.isEmpty { n += g.tracks.count + (category == .albums ? discRowCount(g) : 0) }
                else { n += g.subgroups.reduce(0) { $0 + 1 + (expandedGroups.contains($1.id) ? $1.tracks.count + discRowCount($1) : 0) } }
            }
            if i < groupIndex { row += n }
            total += n
        }
        return directScrollTable(view: tracker.view, rowCount: total, wantedRow: row)
    }

    private func directScrollTable(view: NSView?, rowCount: Int, wantedRow: Int) -> Bool {
        guard let view, let root = view.window?.contentView else { return false }
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let scrollView = ListScrollHandle.scrollViews(in: root, containing: center)
                .first(where: { ($0.documentView as? NSTableView)?.numberOfRows == rowCount }),
              let table = scrollView.documentView as? NSTableView else { return false }
        let clip = scrollView.contentView
        let minY = -scrollView.contentInsets.top
        let maxY = max(minY, table.bounds.height - clip.bounds.height + scrollView.contentInsets.bottom)
        let rows = table.numberOfRows
        let average = table.bounds.height / CGFloat(max(rows, 1))
        let wanted = max(1, min(wantedRow, rows - 2))
        // Build 32: la riga `wanted` va subito sotto i pannelli sovrapposti (la riga ancora più su resta visibile).
        let inset = table.rect(ofRow: 0).height
        var y = max(minY, min(CGFloat(wanted) * average - inset, maxY))
        for _ in 0..<5 {
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
            let readY = min(max(y + inset + 4, 0), table.bounds.height - 1)
            let actual = table.row(at: NSPoint(x: table.bounds.midX, y: readY))
            if actual < 0 || actual == wanted { break }
            let next = max(minY, min(y + CGFloat(wanted - actual) * average, maxY))
            if abs(next - y) < 1 { break }
            y = next
        }
        return true
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
        let range = items[min(drag.anchor, c)...max(drag.anchor, c)].filter { !$0.isBlocked }.map(\.id)
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
        case .playlists: return filteredPlaylists.filter(isInOpenFolders)
        default: return []
        }
    }

    /// Playlist nelle cartelle di Musica: con una ricerca in corso tutte le cartelle sono aperte.
    private func folderOpen(_ id: String) -> Bool { !query.isEmpty || expandedGroups.contains("folder:\(id)") }
    private func isInOpenFolders(_ group: TrackGroup<Track>) -> Bool { group.folderPath.allSatisfy { folderOpen($0.id) } }

    /// Albero delle playlist locali: cartelle di Musica (con i loro contenuti) e playlist. Senza cartelle è un elenco piatto.
    private struct TreeNode: Identifiable {
        let id: String
        let folder: FolderRef?
        let group: TrackGroup<Track>?
        var children: [TreeNode]
    }

    private func playlistTree(_ groups: [TrackGroup<Track>]) -> [TreeNode] {
        // I gruppi arrivano in ordine «a profondità» (ogni cartella seguita dal suo contenuto): basta guardare l'ultimo nodo.
        func insert(_ g: TrackGroup<Track>, into nodes: inout [TreeNode], depth: Int) {
            if depth >= g.folderPath.count {
                nodes.append(TreeNode(id: g.id, folder: nil, group: g, children: []))
                return
            }
            let ref = g.folderPath[depth]
            if nodes.isEmpty || nodes[nodes.count - 1].folder != ref {
                nodes.append(TreeNode(id: "folder:\(ref.id)", folder: ref, group: nil, children: []))
            }
            insert(g, into: &nodes[nodes.count - 1].children, depth: depth + 1)
        }
        var roots: [TreeNode] = []
        for g in groups { insert(g, into: &roots, depth: 0) }
        return roots
    }

    private func folderBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { folderOpen(id) },
                set: { newValue in
                    guard query.isEmpty else { return }   // con una ricerca in corso le cartelle restano aperte
                    if newValue { expandedGroups.insert("folder:\(id)") } else { expandedGroups.remove("folder:\(id)") }
                })
    }

    /// Miniatura di una playlist (32 pt, come gli album): ingranaggio per le smart/Genius (il contenuto cambia con le regole);
    /// per le altre mosaico 2×2 con le copertine di quattro album diversi, o la copertina del primo brano se gli album sono meno di quattro.
    @ViewBuilder
    private func playlistThumbnail(_ group: TrackGroup<Track>) -> some View {
        if group.isSmart {
            // Solo il simbolo, senza riquadro, più grande (occupa tutto lo spazio della miniatura).
            Image(systemName: "gearshape")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        } else {
            PlaylistMosaic(tracks: group.tracks, provider: artworkProvider, version: artworkRevision)
        }
    }

    // MARK: Playlist: righe piatte con colonne
    //
    // Ogni livello è una colonna larga `colUnit` (16 pt, come l'icona della cartella; la copertina ne occupa due).
    //  - freccia di apertura: colonna c (c = numero di cartelle che contengono la riga);
    //  - cartella: icona nella colonna c+1, titolo nella colonna c+3;
    //  - playlist: copertina subito dopo la freccia (c = 0) oppure nella colonna c+2 (dentro una cartella), titolo dopo la copertina;
    //  - brano: la copertina parte dove parte il titolo della playlist a cui appartiene.

    private static var colUnit: CGFloat { 16 }
    /// Altezza del contenuto di ogni riga di Album e Artisti (con il rientro verticale della lista fa 40 pt, l'altezza minima
    /// impostata): righe tutte uguali, così la tabella non deve misurarle una a una.
    private static var fixedRowContentHeight: CGFloat { 32 }
    /// Diametro del cerchio dell'artista nella scheda Artisti: 36 pt come in Apple Music (misurato su uno screenshot Retina: 72 px).
    private static var artistCoverSize: CGFloat { 36 }
    /// Copertina dell'album dentro l'artista: 32 pt, un po' meno del cerchio dell'artista, per distinguere i due livelli.
    private static var albumInArtistCoverSize: CGFloat { 32 }
    private static var coverSize: CGFloat { 32 }
    private static var coverTitleGap: CGFloat { 8 }

    private enum FlatPlaylistRow: Identifiable {
        case folder(FolderRef, level: Int)
        case playlist(TrackGroup<Track>, level: Int)
        case track(TrackGroup<Track>, Track, level: Int)

        var id: String {
            switch self {
            case .folder(let f, _): return "folder:\(f.id)"
            case .playlist(let g, _): return g.id
            case .track(let g, let t, _): return "\(g.id)#\(t.id)"
            }
        }
    }

    /// Posizione (da sinistra, in pt) della miniatura di una playlist al livello `level`.
    private static func playlistCoverX(level: Int) -> CGFloat {
        level == 0 ? colUnit : CGFloat(level + 2) * colUnit
    }
    /// Posizione del titolo di una playlist (e della copertina dei suoi brani).
    private static func playlistTitleX(level: Int) -> CGFloat {
        playlistCoverX(level: level) + coverSize + coverTitleGap
    }

    private func flatPlaylistRows(_ nodes: [TreeNode], level: Int = 0) -> [FlatPlaylistRow] {
        var out: [FlatPlaylistRow] = []
        for node in nodes {
            if let folder = node.folder {
                out.append(.folder(folder, level: level))
                if folderOpen(folder.id) { out += flatPlaylistRows(node.children, level: level + 1) }
            } else if let group = node.group {
                out.append(.playlist(group, level: level))
                if expandedGroups.contains(group.id) {
                    for track in group.tracks { out.append(.track(group, track, level: level)) }
                }
            }
        }
        return out
    }

    /// Freccia di apertura, nella sua colonna: apre e chiude senza animazione e senza spostare la lista.
    private func chevronButton(open: Bool, enabled: Bool = true, toggle: @escaping () -> Void) -> some View {
        Button {
            ListScrollHandle.keepPositionAfterToggle()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { toggle() }
        } label: {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.colUnit, height: 24, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func flatPlaylistRowView(_ row: FlatPlaylistRow, isPlaylists: Bool = true, showArtwork: Bool = false) -> some View {
        switch row {
        case .folder(let folder, let level):
            let open = folderOpen(folder.id)
            HStack(spacing: 0) {
                chevronButton(open: open, enabled: query.isEmpty) { folderBinding(folder.id).wrappedValue = !open }
                Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: Self.colUnit)
                Spacer().frame(width: Self.colUnit)
                Text(folder.name).font(.system(size: settings.listTextSize.points)).fontWeight(.medium).lineLimit(1)
                Spacer()
            }
            .padding(.leading, CGFloat(level) * Self.colUnit)
            .contentShape(Rectangle())
            .onTapGesture { if query.isEmpty { folderBinding(folder.id).wrappedValue = !open } }
            .listRowSeparator(.hidden)
        case .playlist(let group, let level):
            let open = expandedGroups.contains(group.id)
            let gap = Self.playlistCoverX(level: level) - (CGFloat(level) * Self.colUnit + Self.colUnit)
            HStack(spacing: 0) {
                chevronButton(open: open) { expandedBinding(group.id).wrappedValue = !open }
                groupHeaderLabel(group, coverLeading: isPlaylists ? gap : 0, isPlaylists: isPlaylists, showArtwork: showArtwork)
            }
            .frame(height: isPlaylists ? nil : Self.fixedRowContentHeight)
            .padding(.leading, CGFloat(level) * Self.colUnit)
            .listRowBackground(isGroupFullySelected(group, isPlaylists) ? rowHighlight(settings.highlightColor) : nil)
        case .track(let group, let track, let level):
            groupTrackRow(group, track, isPlaylists: isPlaylists, numbered: !isPlaylists, leading: Self.playlistTitleX(level: level))
                .frame(height: isPlaylists ? nil : Self.fixedRowContentHeight)
        }
    }

    /// Contenuto dell'intestazione di un gruppo (miniatura, titolo, sottotitolo, pulsanti, stato «sul dispositivo», clic e menu).
    /// Lo usano sia la riga con freccia nativa (Artisti, Album) sia la riga piatta delle Playlist; `coverLeading` è il margine
    /// a sinistra della miniatura delle playlist.
    @ViewBuilder
    private func groupHeaderLabel(_ group: TrackGroup<Track>, coverLeading: CGFloat = 0, isPlaylists: Bool, showArtwork: Bool) -> some View {
        HStack {
            // Selezione a sinistra (vuota = invisibile, solo ingombro), stato: tutto / parziale.
            // Playlist: nessun riquadro a sinistra (la copertina parte dove parte l'icona della cartella allo stesso livello);
            // lo stato di selezione è un piccolo segno sull'angolo della copertina.
            if isPlaylists {
                playlistThumbnail(group)
                    .overlay(alignment: .topLeading) { selectionBadge(group, isPlaylists: true) }
                    .padding(.leading, coverLeading)
            } else if showArtwork, let first = group.tracks.first {
                ArtworkThumbnail(track: first, provider: artworkProvider, version: artworkRevision, size: 32,
                                 placeholderSymbol: "music.quarternote.3")
                    .overlay(alignment: .topLeading) { selectionBadge(group, isPlaylists: false) }
            } else {
                // Artista (nessuna copertina): riquadro vuoto della stessa misura del mosaico delle playlist, ancora da definire.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 32, height: 32)
                    .overlay(alignment: .topLeading) { selectionBadge(group, isPlaylists: false) }
            }
            VStack(alignment: .leading, spacing: settings.listTextSize.lineSpacing) {
                Text(group.title).font(.system(size: settings.listTextSize.points)).fontWeight(.medium).lineLimit(1)
                Text(subtitleText(group)).font(.system(size: settings.listTextSize.secondaryPoints)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            purchasedBadge(count: groupStats(group).purchased)
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
                        Image(systemName: "arrow.right.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, statusIconGreen)
                            .help(t("artwork_on_device"))
                    } else if !isPlaylists, isGroupOnDevice(group.tracks) {
                        // Album (scheda Album) o artista: tutti i suoi brani trasferibili sono già sul dispositivo.
                        Image(systemName: "arrow.right.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, statusIconGreen)
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
            contextMenuItems(isSelected: isGroupFullySelected(group, isPlaylists), artworkTracks: { group.tracks }, groupName: group.title, sendCountHint: groupStats(group).count - groupStats(group).blocked, sendIDs: { menuSendIDs(forGroup: group) }) { toggleGroupSelection(group, isPlaylists) }
            if isPlaylists, let edit = onEditPlaylist {
                Button { edit(group) } label: {
                    Label(t("menu_edit_in_custom"), systemImage: "square.and.pencil")
                        .labelStyle(.titleAndIcon)
                }
            }
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
                    for t in tracks where !t.isBlocked {
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
            if isPlaylists {
                // Playlist: righe piatte (cartelle, playlist e brani delle playlist aperte), con freccia e rientri disegnati qui.
                ForEach(flatPlaylistRows(playlistTree(groups))) { row in
                    flatPlaylistRowView(row)
                }
            } else {
                // Album e Artisti: come nella 2.2 (DisclosureGroup annidati, righe della tabella native).
                ForEach(groups) { group in
                    DisclosureGroup(isExpanded: expandedBinding(group.id)) {
                        if group.subgroups.isEmpty {
                            legacyAlbumTrackRows(group, numbered: listCategory == .albums)
                        } else {
                            // Scheda Artisti: Artista → Album → Brani dell'album.
                            ForEach(group.subgroups) { album in
                                DisclosureGroup(isExpanded: expandedBinding(album.id)) {
                                    legacyAlbumTrackRows(album, numbered: true)
                                } label: {
                                    legacyAlbumHeader(album)
                                }
                                .listRowBackground(isGroupFullySelected(album, false) ? rowHighlight(settings.highlightColor) : nil)
                            }
                        }
                    } label: {
                        legacyGroupLabel(group, showArtwork: showArtwork)
                    }
                    // Sfondo evidenziato sull'intestazione quando tutti i brani del gruppo sono selezionati.
                    .listRowBackground(isGroupFullySelected(group, false) ? rowHighlight(settings.highlightColor) : nil)
                }
            }
            GlassInsetRow(edge: .bottom)
        }
        .listStyle(.inset)
        // Miniature degli artisti: tutto l'elenco si scarica in sottofondo, a cinque blocchi (solo libreria locale, con la ricerca vuota).
        .task(id: "\(listCategory == .artists)|\(downloadsArtistThumbnails && settings.autoLoadAppleArtwork)|\(query.isEmpty)|\(groups.count)|\(groups.first?.id ?? "")|\(groups.last?.id ?? "")") {
            guard listCategory == .artists, downloadsArtistThumbnails, settings.autoLoadAppleArtwork, query.isEmpty else { return }
            let names = groups.filter { !$0.subgroups.isEmpty && $0.id != "compilations" }.map(\.title)
            await ArtistThumbnailService.shared.enqueueBackground(ArtistThumbnailService.interleaved(names, blocks: 5),
                                                                  size: ArtistCoverBox.pixels)
        }
        .onChange(of: query) { _, _ in
            // Ricerca nelle playlist: si aprono anche le playlist trovate per un loro brano (non per il titolo).
            guard isPlaylists, !query.isEmpty else { return }
            for g in groups where !g.title.localizedCaseInsensitiveContains(query) { expandedGroups.insert(g.id) }
        }
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
                    if g.subgroups.isEmpty { return 1 + g.tracks.count + (listCategory == .albums ? discRowCount(g) : 0) }
                    return 1 + g.subgroups.reduce(0) { $0 + 1 + (expandedGroups.contains($1.id) ? $1.tracks.count + discRowCount($1) : 0) }
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
                    let shown = groups[max(0, min(index, groups.count - 1))]
                    if listCategory == .albums, settings.albumOrder == .dateAdded { return periodLabel(of: shown) }
                    return Self.initial(of: shown.title)
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
            let tracker = listCategory == .albums ? albumsLetters : artistsLetters
            // Scorrimento diretto della tabella (build 29-33) solo con la libreria Local; librerie remote e unità esterne: scrollTo come nella 2.2.
            handleTypeAhead(event, entries: groups.map { ($0.id, $0.title) }, rowOffset: Self.revealRowOffset, proxy: proxy,
                            fastScroll: typeAheadFirstLetterOnly ? nil : { index in directScrollGroups(groups, toGroup: index, tracker: tracker) })
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
        .onChange(of: category) { groupAnchorKey = nil; PerfLag.measure("Cambio scheda → \(category)") }
        .onChange(of: expandedGroups) { old, new in
            PerfLag.measure("Apertura/chiusura di un gruppo (\(category)): \(groups.count) gruppi, \(new.count) aperti, \(visibleRowCount(groups)) righe visibili")
            guard isActive, settings.autoLoadAppleArtwork, !onlyWithoutCover, let request = onRequestArtwork else { return }
            // Le copertine si richiedono dopo un istante: mentre la tabella sta ancora inserendo le righe, il ridisegno
            // dovuto alle copertine che arrivano faceva saltare la lista.
            let opened = new.subtracting(old)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                for id in opened {
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
    }

    // MARK: Album e Artisti: codice della 2.2
    //
    // Le schede Album, Artisti e Brani usano le righe native della 2.2 (DisclosureGroup annidati); il motore a righe piatte
    // della 2.3 è solo per le Playlist.

    /// Intestazione di un artista o di un album (scheda Album/Artisti), come nella 2.2.
    @ViewBuilder
    private func legacyGroupLabel(_ group: TrackGroup<Track>, showArtwork: Bool) -> some View {
        HStack {
            // Selezione a sinistra (vuota = invisibile, solo ingombro), stato: tutto / parziale.
            let selectedCount = group.tracks.filter { isPicked(group, $0, false) }.count
            SelectToggleIcon(state: isGroupFullySelected(group, false) ? .all
                             : (selectedCount > 0 ? .partial : .none), isGroup: true) {
                toggleGroupSelection(group, false)
            }
            if showArtwork, let first = group.tracks.first {
                ArtworkThumbnail(track: first, provider: artworkProvider, version: artworkRevision, size: 32,
                                 placeholderSymbol: "music.quarternote.3")
            } else if !group.subgroups.isEmpty {
                // 2.3 Beta 3, scheda Artisti: tre livelli con miniatura (Artista → Album → Brani). Per ora il riquadro
                // dell'artista è vuoto, della stessa dimensione della miniatura degli album (`artistCoverSize`); in seguito
                // vi comparirà la foto dell'artista.
                // (`ArtistCoverBox` mostra la miniatura se c'è, già in cache o scaricata da Apple Music; altrimenti resta vuoto.)
                ArtistCoverBox(name: group.id == "compilations" ? "" : group.title, size: Self.artistCoverSize,
                               fetchOnline: settings.autoLoadAppleArtwork && downloadsArtistThumbnails,
                               isCompilations: group.id == "compilations")
            }
            VStack(alignment: .leading, spacing: settings.listTextSize.lineSpacing) {
                Text(group.title).font(.system(size: settings.listTextSize.points)).fontWeight(.medium).lineLimit(1)
                Text(subtitleText(group)).font(.system(size: settings.listTextSize.secondaryPoints)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            purchasedBadge(count: group.tracks.filter(\.isPurchased).count)
            // Ultima colonna a destra: già sul dispositivo (freccia verde). Spazio fisso per l'allineamento con i brani.
            if isPlaylistOnDeviceCheck != nil || isOnDeviceCheck != nil {
                Group {
                    if isGroupOnDevice(group.tracks) {
                        Image(systemName: "arrow.right.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, statusIconGreen)
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
        // Click singolo sull'intestazione: come la spunta, inverte la selezione dell'intero gruppo;
        // il secondo click ravvicinato avvia la riproduzione (vedi `ClickTracker`).
        .simultaneousGesture(TapGesture().onEnded {
            if handleRangeClick(group: group, track: nil, isPlaylists: false) { return }
            toggleGroupSelection(group, false)
            if ClickTracker.isDouble("g:\(group.id)"), let first = group.tracks.first {
                onPlay?(first, group.tracks, PlaybackSource(name: group.title, category: category))
            }
        })
        // Click destro sull'intestazione: gli invii e la ricerca copertine agiscono sull'intero gruppo.
        .contextMenu {
            contextMenuItems(isSelected: isGroupFullySelected(group, false), artworkTracks: { group.tracks }, groupName: group.title, sendIDs: { menuSendIDs(forGroup: group) }) { toggleGroupSelection(group, false) }
        }
    }

    /// Intestazione di un album dentro un artista (scheda Artisti), come nella 2.2.
    private func legacyAlbumHeader(_ album: TrackGroup<Track>) -> some View {
        HStack {
            let selectedCount = album.tracks.filter { isPicked(album, $0, false) }.count
            SelectToggleIcon(state: isGroupFullySelected(album, false) ? .all
                             : (selectedCount > 0 ? .partial : .none), isGroup: true) {
                toggleGroupSelection(album, false)
            }
            if let first = album.tracks.first {
                ArtworkThumbnail(track: first, provider: artworkProvider, version: artworkRevision, size: Self.albumInArtistCoverSize,
                                 placeholderSymbol: "music.quarternote.3")
            }
            VStack(alignment: .leading, spacing: settings.listTextSize.lineSpacing) {
                Text(album.title).font(.system(size: settings.listTextSize.points)).lineLimit(1)
                Text(subtitleText(album)).font(.system(size: settings.listTextSize.secondaryPoints)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            purchasedBadge(count: album.tracks.filter(\.isPurchased).count)
            if isPlaylistOnDeviceCheck != nil || isOnDeviceCheck != nil {
                Group {
                    if isGroupOnDevice(album.tracks) {
                        Image(systemName: "arrow.right.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, statusIconGreen)
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

    /// Riga di un brano dentro un album (o un artista), come nella 2.2: quadrato di selezione a sinistra, clic, doppio clic e menu.
    @ViewBuilder
    private func legacyGroupTrackRow(_ group: TrackGroup<Track>, _ track: Track, numbered: Bool) -> some View {
        trackRow(track, number: numbered ? trackNumberLabel(track, in: group) : nil, insideAlbum: numbered) {
            // Brano non selezionabile (es. solo nel cloud): riquadro invisibile, stesso incolonnamento.
            SelectToggleIcon(state: isPicked(group, track, false) ? .all : .none, hidden: track.isBlocked) {
                toggleRow(group, track, false)
            }
        }
        // Brani numerati di un album: rientrati fino al titolo dell'album (stessa x di «Disco n di m»).
        .padding(.leading, numbered ? Self.albumTitleIndent : 0)
        .tag("\(track.id)")
        .selectionDisabled(track.isBlocked)
        // Identificativo per lo scorrimento automatico (lo stesso brano può stare in più gruppi).
        .id(rowScrollID(group.id, track.id))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if handleRangeClick(group: group, track: track, isPlaylists: false) { return }
            if !track.isBlocked { toggleRow(group, track, false) }
            if ClickTracker.isDouble("r:\(rowScrollID(group.id, track.id))") {
                onPlay?(track, group.tracks, PlaybackSource(name: group.title, category: category))
            }
        })
        .listRowBackground(isPicked(group, track, false) ? rowHighlight(settings.highlightColor)
                           : (flashRowID == rowScrollID(group.id, track.id) ? rowHighlight(Color.yellow.opacity(0.4)) : nil))
        .contextMenu {
            contextMenuItems(isSelected: isPicked(group, track, false), artworkTracks: { group.tracks }, goTo: track, membershipTrack: track, similarSeeds: [track], full: true, focusTrack: track, sendIDs: { menuSendIDs(for: track) }) { toggleRow(group, track, false) }
        }
    }

    /// Brani di un album (o di un artista senza album). Con più dischi, prima dei brani di ogni disco c'è una riga
    /// «Disco n di m» (non selezionabile) e i brani riportano solo il numero di traccia.
    @ViewBuilder
    private func legacyAlbumTrackRows(_ album: TrackGroup<Track>, numbered: Bool) -> some View {
        let discs = Set(album.tracks.map { max($0.discNumber, 1) })
        let totalDiscs = max(album.tracks.map(\.discCount).max() ?? 0, discs.count)
        if numbered && (discs.count > 1 || totalDiscs > 1) {
            ForEach(album.tracks) { track in
                let disc = max(track.discNumber, 1)
                if album.tracks.first(where: { max($0.discNumber, 1) == disc })?.id == track.id {
                    Text(t("disc_n_of_m", disc, totalDiscs))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, Self.albumTitleIndent)   // allineata all'inizio del titolo dell'album
                        .padding(.top, 4)
                        .selectionDisabled(true)
                        .listRowSeparator(.hidden)
                }
                legacyGroupTrackRow(album, track, numbered: numbered)
            }
        } else {
            ForEach(album.tracks) { track in
                legacyGroupTrackRow(album, track, numbered: numbered)
            }
        }
    }

    /// Icona sull'intestazione di un gruppo (playlist, artista, album) che contiene brani acquistati su iTunes Store.
    @ViewBuilder
    private func purchasedBadge(count n: Int) -> some View {
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
    private func groupTrackRow(_ group: TrackGroup<Track>, _ track: Track, isPlaylists: Bool, numbered: Bool = false, leading: CGFloat = 36) -> some View {
        // Oggetto di "secondo livello" (il brano dentro l'album/artista/playlist):
        // ha anche lui il proprio Select/Deseleziona, indipendente da quello
        // dell'intestazione — cosi la selezione multipla può prendere singoli
        // brani da dentro un gruppo, non solo il gruppo intero.
        // Nessun segno sul singolo brano: lo dice l'evidenziazione della riga; lo stato del gruppo è sulla copertina dell'intestazione.
        trackRow(track, number: numbered ? trackNumberLabel(track, in: group) : nil, insideAlbum: numbered) { EmptyView() }
        // Rientro rispetto alla copertina dell'intestazione, così il brano si legge come contenuto del gruppo aperto.
        .padding(.leading, leading)
        .tag(isPlaylists ? pickKey(group, track) : "\(track.id)")
        .selectionDisabled((isPlaylists && disablesTrackSelectionInPlaylists) || track.isBlocked)
        // Identificativo per lo scorrimento automatico (lo stesso brano può stare in più gruppi).
        .id(rowScrollID(group.id, track.id))
        .contentShape(Rectangle())
        // Click singolo sulla riga: come la spunta (non per i brani non selezionabili né nelle playlist del dispositivo);
        // il secondo click ravvicinato avvia la riproduzione (vedi `ClickTracker`).
        .simultaneousGesture(TapGesture().onEnded {
            if !(isPlaylists && disablesTrackSelectionInPlaylists), handleRangeClick(group: group, track: track, isPlaylists: isPlaylists) { return }
            if !track.isBlocked, !(isPlaylists && disablesTrackSelectionInPlaylists) { toggleRow(group, track, isPlaylists) }
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
    private func trackNumberLabel(_ track: Track, in album: TrackGroup<Track>) -> String? {
        guard album.tracks.contains(where: { $0.trackNumber > 0 }) else { return nil }
        let multiDisc = Set(album.tracks.map { max($0.discNumber, 1) }).count > 1
            || album.tracks.contains { $0.discCount > 1 }
        guard multiDisc else { return track.trackNumber > 0 ? "\(track.trackNumber)" : "–" }
        // Più dischi: il disco è nell'intestazione «Disco n di m» sopra i suoi brani, qui solo la traccia (01, 02…).
        return track.trackNumber > 0 ? String(format: "%02d", track.trackNumber) : "–"
    }

    /// Segno di selezione sull'angolo della copertina di un gruppo: spunta (tutto) o trattino (parziale); nulla se non selezionato.
    @ViewBuilder
    private func selectionBadge(_ group: TrackGroup<Track>, isPlaylists: Bool) -> some View {
        if isGroupFullySelected(group, isPlaylists) {
            SelectionMark(partial: false).offset(x: -5, y: -5)
        } else if pickedCount(group, isPlaylists) > 0 {
            SelectionMark(partial: true).offset(x: -5, y: -5)
        }
    }

    /// Vero se un album o un artista è già per intero sul dispositivo (2.1 Beta 3, logica A): tutti i brani con
    /// «sul dispositivo» vero. Esclusi dal conteggio i brani non trasferibili (con avviso: DRM, solo cloud, Hi-Res);
    /// i brani «solo sul dispositivo» contano come presenti. Senza brani trasferibili, falso. Solo negli elenchi
    /// che mostrano la colonna (Apple Music), come le righe dei brani.
    private func isGroupOnDevice(_ tracks: [Track]) -> Bool {
        guard artworkOriginProvider != nil, let onDevice = isOnDeviceCheck else { return false }
        var found = false
        for track in tracks where !track.isBlocked {
            if !(track.isDeviceOnly || onDevice(track)) { return false }
            found = true
        }
        return found
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedGroups.contains(id) },
                set: { isOpen in
                    // La tabella può richiamare questo setter anche senza che l'utente tocchi il triangolo (es. ridisegnando le righe
                    // mentre si scorre) con lo stesso valore: in quel caso non si fa nulla, altrimenti la posizione ripristinata
                    // riporterebbe la lista indietro mentre si scorre.
                    guard isOpen != expandedGroups.contains(id) else { return }
                    // Aprire o chiudere un gruppo con il triangolo non deve spostare la lista: si ricorda la posizione.
                    ListScrollHandle.keepPositionAfterToggle()
                    // Senza animazione: con tanti album l'animazione di inserimento righe della tabella nativa le disegna fuori
                    // posto e fa saltare la lista.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if isOpen { expandedGroups.insert(id) } else { expandedGroups.remove(id) }
                    }
                })
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
    /// Etichetta per la scheda Album ordinata per «Data di aggiunta» (come Musica): questa settimana, questo mese, ultimi tre mesi,
    /// poi l'anno. La data di un album è quella del suo brano aggiunto per ultimo.
    private func periodLabel(of group: TrackGroup<Track>) -> String {
        let latest = group.tracks.reduce(0.0) { Swift.max($0, $1.dateAdded) }
        guard latest > 0 else { return t("period_unknown") }
        let date = Date(timeIntervalSince1970: latest)
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return t("period_this_week") }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return t("period_this_month") }
        if let limit = calendar.date(byAdding: .month, value: -3, to: now), date >= limit { return t("period_last_three_months") }
        return String(calendar.component(.year, from: date))
    }

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
              let group = groups.first(where: { $0.id == playlistID }) else { return }
        expandedGroups.insert(group.id)
        for folder in group.folderPath { expandedGroups.insert("folder:\(folder.id)") }
        let target = rowScrollID(group.id, request.trackID)
        // Le righe delle playlist sono righe piatte della lista: si scorre la tabella AppKit fino alla riga del brano. Le righe
        // non ancora mostrate hanno un'altezza stimata, quindi si procede per passi (ci si avvicina e si riprova) finché la
        // riga è davvero presente nella vista e la si porta al centro. Se la tabella non è riconosciuta, `scrollTo` per id.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                let rows = flatPlaylistRows(playlistTree(groups))
                guard let rowIndex = rows.firstIndex(where: { $0.id == target }) else { continue }
                let result = scrollHandle.scroll(flatRow: rowIndex + 1, flatTotal: rows.count + 2,
                                                 blockRow: -1, blockTotal: -1, childIndex: 0, childCount: 0)
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
        // Le righe annidate dentro i gruppi aperti da codice non sono raggiungibili con `scrollTo`: si scorre fino al gruppo
        // di primo livello (album, o artista), ripetendo perché l'apertura cambia l'altezza della lista.
        Task { @MainActor in
            for delay in [300_000_000, 500_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                withAnimation { proxy.scrollTo(scrollTop, anchor: .top) }
            }
        }
    }

    /// Righe di scostamento sopra il risultato di "Vai all'Album/Artista" (pannelli sovrapposti alla lista).
    private static var revealRowOffset: Int { 8 }
    /// Rientro del titolo dell'album rispetto al bordo della riga: colonna di selezione (20) + cover (28) + due spaziature (8+8).
    private static var albumTitleIndent: CGFloat { SelectToggleIcon.columnWidth + 28 + 16 }
    /// Come sopra per l'elenco Brani (righe più basse di quelle di Album/Artisti, quindi più righe per coprire lo stesso spazio).
    private static var typeAheadSongRowOffset: Int { 12 }

    private func expandPlayingGroup(in groups: [TrackGroup<Track>], proxy: ScrollViewProxy) {
        guard let source = playingSource, source.category == category else { return }
        // Il gruppo in riproduzione può essere di primo livello (artista, album, playlist) oppure un album
        // dentro un artista (scheda Artisti): si aprono tutti i livelli fino al brano.
        var found: TrackGroup<Track>?
        if let group = groups.first(where: { $0.title == source.name }) {
            expandedGroups.insert(group.id)
            for folder in group.folderPath { expandedGroups.insert("folder:\(folder.id)") }
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
        guard !track.isBlocked else { return }
        guard isPlaylists else { toggleSelection(track.id); return }
        let key = pickKey(group, track)
        if playlistPicks.contains(key) { playlistPicks.remove(key) } else { playlistPicks.insert(key) }
    }

    /// Brani del gruppo che si possono scegliere (esclusi quelli non trasferibili, es. solo nel cloud).
    private func selectableTracks(_ group: TrackGroup<Track>) -> [Track] {
        group.tracks.filter { !$0.isBlocked }
    }

    private func isGroupFullySelected(_ group: TrackGroup<Track>, _ isPlaylists: Bool) -> Bool {
        if isPlaylists ? playlistPicks.isEmpty : selection.isEmpty { return false }   // nessuna scelta: non scorre i brani
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
    private func contextMenuItems(isSelected: Bool, artworkTracks: @escaping () -> [Track], goTo: Track? = nil, membershipTrack: Track? = nil, similarSeeds: [Track]? = nil, full: Bool = false, focusTrack: Track? = nil, groupName: String? = nil, sendCountHint: Int? = nil, sendIDs: @escaping () -> Set<Track.ID>, toggle: @escaping () -> Void) -> some View {
        if let menu = rowMenu {
            // Invio: agisce sull'elemento cliccato (brano, o gruppo intero), non sulla selezione precedente.
            // La selezione viene sostituita da quell'elemento e poi si usano le stesse azioni dei pulsanti in basso.
            // Per un gruppo basta il numero (già in memoria): non si costruisce l'insieme degli id a ogni ridisegno (build 25).
            let sendCount = sendCountHint ?? sendIDs().count
            // Brano cliccato dentro una selezione di più brani: due righe per azione (tutta la selezione / solo il brano).
            let focusID: Track.ID? = (full && sendCount > 1) ? focusTrack.map(\.id) : nil
            let focusName: String = {
                guard let title = focusTrack?.title else { return "" }
                return title.count > 15 ? String(title.prefix(15)) + "…" : title
            }()

            Button {
                selection = sendIDs()
                menu.sendToPlaylist()
            } label: {
                Label(groupName != nil ? t("menu_send_group_to_custom", groupLabel(groupName), songsText(sendCount))
                        : (sendCount > 1 ? t("menu_send_n_to_custom", sendCount) : t("menu_send_to_custom")),
                      systemImage: "tray.and.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(sendCount == 0 || menu.isBusy)
            if let focusID {
                Button {
                    sendOnly(focusID) { menu.sendToPlaylist() }
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
                Label(groupName != nil ? t("menu_send_group_to_device", groupLabel(groupName), songsText(sendCount))
                        : (sendCount > 1 ? t("menu_send_n_to_device", sendCount) : t("menu_send_to_device")),
                      systemImage: "arrow.right.circle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(sendCount == 0 || menu.isBusy || !menu.canSendToDevice)
            if let focusID {
                Button {
                    sendOnly(focusID, toDevice: true) { menu.sendToDevice() }
                } label: {
                    Label(t("menu_send_one_to_device", focusName), systemImage: "arrow.right.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(menu.isBusy || !menu.canSendToDevice)
            }

            // Su playlist, artista e album (intestazioni): oltre ai due invii, la ricerca online delle copertine per tutti i loro brani.
            if !full, groupName != nil, menu.canFixArtwork {
                Divider()
                Button {
                    selection = sendIDs()
                    menu.fixArtwork()
                } label: {
                    Label(t("menu_artwork_online_fix"), systemImage: "waveform.badge.magnifyingglass")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(sendCount == 0 || menu.isBusy)
            }

            // Menu completo solo su un brano; su playlist, artista, album solo gli invii e la ricerca copertine.
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
                    .disabled(sendCount == 0 || menu.isBusy)
                }
                // Solo scheda Brani: filtro «Mostra solo brani senza copertina» (spunta a sinistra = filtro attivo).
                if category == .songs, artworkOriginProvider != nil {
                    Toggle(isOn: $onlyWithoutCover) {
                        Label(t("menu_only_without_cover"), systemImage: "photo.badge.exclamationmark").labelStyle(.titleAndIcon)
                    }
                }

                Divider()

                // Salta all'album o all'artista del brano, aprendoli e scorrendo fino a lui.
                // Nella scheda Album non serve «Mostra in Album», in quella Artisti non serve «Mostra in Artisti».
                if let goTo {
                    if category != .albums {
                        Button { reveal(goTo, in: .albums) } label: {
                            Label(t("menu_go_to_album"), systemImage: "music.pages")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    if category != .artists {
                        Button { reveal(goTo, in: .artists) } label: {
                            Label(t("menu_go_to_artist"), systemImage: "microphone.dynamic.on.stand")
                                .labelStyle(.titleAndIcon)
                        }
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

    /// Conteggi del gruppo in memoria: valgono finché non cambiano i brani della libreria (numero, primo, ultimo) o il numero di brani del gruppo.
    private func groupStats(_ group: TrackGroup<Track>) -> CatalogDerivedCache<Track>.GroupStats {
        if derived.statsCount != tracks.count || derived.statsFirstID != tracks.first?.id || derived.statsLastID != tracks.last?.id {
            derived.groupStats = [:]
            derived.statsCount = tracks.count
            derived.statsFirstID = tracks.first?.id
            derived.statsLastID = tracks.last?.id
        }
        if let cached = derived.groupStats[group.id], cached.count == group.tracks.count { return cached }
        var stats = CatalogDerivedCache<Track>.GroupStats()
        stats.count = group.tracks.count
        for track in group.tracks {
            if track.isBlocked { stats.blocked += 1 }
            if track.isPurchased { stats.purchased += 1 }
        }
        derived.groupStats[group.id] = stats
        return stats
    }

    /// Quanti brani del gruppo sono scelti; con nessuna scelta attiva non scorre i brani.
    private func pickedCount(_ group: TrackGroup<Track>, _ isPlaylists: Bool) -> Int {
        if isPlaylists ? playlistPicks.isEmpty : selection.isEmpty { return 0 }
        var n = 0
        for track in group.tracks where isPicked(group, track, isPlaylists) { n += 1 }
        return n
    }

    /// Sottotitolo di un gruppo; se contiene brani non trasferibili (ALAC, FLAC, solo cloud…) aggiunge quanti sono inviabili.
    private func subtitleText(_ group: TrackGroup<Track>) -> String {
        let blocked = groupStats(group).blocked
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

    /// Brani da inviare dal menu su un brano: la selezione, a cui si aggiunge il brano cliccato se non ne fa parte
    /// (la selezione precedente non va persa).
    /// Invia solo `id` dal menu e poi rimette la selezione precedente (l'invio legge la selezione, quindi la si ripristina alla fine).
    private func sendOnly(_ id: Track.ID, toDevice: Bool = false, _ action: @escaping () -> Void) {
        selectionToRestore = selection
        restoreSawBusy = false
        restoreWaitsForClear = toDevice
        selection = [id]
        action()
        // Se l'invio non diventa mai «occupato» (operazione istantanea) si ripristina comunque dopo un attimo.
        if !toDevice {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !restoreSawBusy { restoreSelectionAfterSingleSend() }
            }
        }
    }

    private func restoreSelectionAfterSingleSend() {
        guard let previous = selectionToRestore else { return }
        selectionToRestore = nil
        restoreSawBusy = false
        restoreWaitsForClear = false
        selection = previous
    }

    private func menuSendIDs(for track: Track) -> Set<Track.ID> {
        if selection.contains(track.id) || track.isBlocked { return selection }
        return selection.union([track.id])
    }

    /// Brani da inviare dal menu su un gruppo (playlist, artista, album): tutti i suoi brani trasferibili.
    private func menuSendIDs(forGroup group: TrackGroup<Track>) -> Set<Track.ID> {
        Set(group.tracks.filter { !$0.isBlocked }.map(\.id))
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
        // Ricorrenze nella Custom (2.3 Beta 2): stesso artista, stesso album, stesso brano inserito più volte.
        var artistCounts: [String: Int] = [:], albumCounts: [String: Int] = [:], trackCounts: [String: Int] = [:]
        for entry in config.entries {
            let artist = entry.track.artist.trimmingCharacters(in: .whitespaces).lowercased()
            if !artist.isEmpty { artistCounts[artist, default: 0] += 1 }
            let album = entry.track.album.trimmingCharacters(in: .whitespaces).lowercased()
            if !artist.isEmpty, !album.isEmpty { albumCounts[artist + "\u{1}" + album, default: 0] += 1 }
            trackCounts[String(describing: entry.track.id), default: 0] += 1
        }
        let artistFirst = settings.customArtistFirst
        // Colonne degli indicatori: una per tipo, riservata (a larghezza fissa) solo se almeno una riga ne ha bisogno, così le righe
        // restano allineate anche passando a due cifre.
        let slotArtist = artistCounts.values.contains { $0 >= 2 }
        let slotAlbum = albumCounts.values.contains { $0 >= 2 }
        let slotTrack = trackCounts.values.contains { $0 >= 2 }
        // Build 45: la lista non ha NESSUNA selezione nativa (la fascia nativa è blu di sistema, non colorabile, e restava sotto la nostra).
        // La selezione la teniamo noi (`customPlaylistSelection`) e la disegniamo col colore scelto in Impostazioni, come nelle altre schede.
        // Click: seleziona; ⌘-click: aggiunge/toglie; ⇧-click: intervallo. Il riordino (`.onMove`) non ne ha bisogno.
        let order = shown.map(\.id)
        return List {
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
                    let artistKey = entry.track.artist.trimmingCharacters(in: .whitespaces).lowercased()
                    let albumKey = entry.track.album.trimmingCharacters(in: .whitespaces).lowercased()
                    let repeats = CustomRepeats(
                        artist: artistKey.isEmpty ? 0 : (artistCounts[artistKey] ?? 0),
                        album: (artistKey.isEmpty || albumKey.isEmpty) ? 0 : (albumCounts[artistKey + "\u{1}" + albumKey] ?? 0),
                        sameTrack: trackCounts[String(describing: entry.track.id)] ?? 0,
                        slotArtist: slotArtist, slotAlbum: slotAlbum, slotTrack: slotTrack)
                    trackRow(entry.track, selectionOnLeft: false, artistFirst: artistFirst, repeats: repeats) {
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
                    .contentShape(Rectangle())   // build 45: senza selezione nativa, il click deve funzionare su tutta la riga
                    // Doppio click avvia il brano, con la Custom Playlist stessa (nell'ordine
                    // attuale) come coda e come sorgente per i controlli del mini player.
                    .simultaneousGesture(TapGesture(count: 2).onEnded { if !entry.track.isDeviceOnly { onPlay?(entry.track, queue, source) } })
                    .simultaneousGesture(TapGesture().onEnded { selectCustomRow(entry.id, order: order) })
                    .listRowBackground(customPlaylistSelection.contains(entry.id) ? rowHighlight(settings.highlightColor) : nil)
                }
                // Il riordino è disattivato mentre si filtra con la ricerca (indici non corrispondenti).
                .onMove(perform: customQuery.isEmpty ? { source, destination in
                    // Se la riga trascinata è tra quelle selezionate, si spostano tutte insieme (la lista non conosce la nostra selezione).
                    var moving = source
                    if source.count == 1, let first = source.first, config.entries.indices.contains(first),
                       customPlaylistSelection.count > 1, customPlaylistSelection.contains(config.entries[first].id) {
                        moving = IndexSet(config.entries.indices.filter { customPlaylistSelection.contains(config.entries[$0].id) })
                    }
                    config.onMove(moving, destination)
                } : nil)
            }
            GlassInsetRow(edge: .bottom)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    /// Selezione della Custom (build 45): click, ⌘-click (aggiunge/toglie), ⇧-click (intervallo dall'ultima riga cliccata).
    private func selectCustomRow(_ id: UUID, order: [UUID]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if customPlaylistSelection.contains(id) { customPlaylistSelection.remove(id) } else { customPlaylistSelection.insert(id) }
            customSelectionAnchor = id
        } else if flags.contains(.shift), let anchor = customSelectionAnchor,
                  let i = order.firstIndex(of: anchor), let j = order.firstIndex(of: id) {
            customPlaylistSelection = Set(order[min(i, j)...max(i, j)])
        } else {
            customPlaylistSelection = [id]
            customSelectionAnchor = id
        }
    }

    /// Artista del brano se diverso da quello dell'album (artista dell'album, o del brano se manca); altrimenti nil.
    private func artistDifferingFromAlbum(_ track: Track) -> String? {
        let artist = track.artist.trimmingCharacters(in: .whitespaces)
        guard !artist.isEmpty else { return nil }
        let albumArtist = track.albumArtist.trimmingCharacters(in: .whitespaces)
        let reference = albumArtist.isEmpty ? artist : albumArtist
        return artist.compare(reference, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ? nil : artist
    }

    /// Ricorrenze di una riga nella Custom Playlist (0 = senza dato). Un solo conteggio ≥ 2 per tipo.
    struct CustomRepeats {
        var artist = 0, album = 0, sameTrack = 0
        var slotArtist = false, slotAlbum = false, slotTrack = false
        var hasAny: Bool { slotArtist || slotAlbum || slotTrack }
    }

    /// Indicatori discreti «×N» sulla riga: brano identico inserito più volte (arancione, il caso da correggere), stesso album,
    /// stesso artista. Sempre attivi nella Custom Playlist.
    @ViewBuilder
    private func repeatBadges(_ r: CustomRepeats) -> some View {
        HStack(spacing: 4) {
            if r.slotTrack {
                if r.sameTrack >= 2 { badge("doc.on.doc.fill", r.sameTrack, color: .orange, help: t("custom_dup_track_help", r.sameTrack)) }
                else { Color.clear.frame(width: Self.badgeWidth, height: 1) }
            }
            if r.slotAlbum {
                if r.album >= 2 { badge("square.stack", r.album, color: .secondary, help: t("custom_dup_album_help", r.album)) }
                else { Color.clear.frame(width: Self.badgeWidth, height: 1) }
            }
            if r.slotArtist {
                if r.artist >= 2 { badge("person.fill", r.artist, color: .secondary, help: t("custom_dup_artist_help", r.artist)) }
                else { Color.clear.frame(width: Self.badgeWidth, height: 1) }
            }
        }
    }

    /// Larghezza fissa di ogni indicatore (icona + «×» + fino a due cifre): non cambia passando da 9 a 10.
    private static var badgeWidth: CGFloat { 46 }

    private func badge(_ icon: String, _ count: Int, color: Color, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
            Text("×\(count)").monospacedDigit()
        }
        .font(.caption.monospacedDigit())   // come la durata del brano
        .foregroundStyle(color)
        .lineLimit(1).minimumScaleFactor(0.8)
        .frame(width: Self.badgeWidth, height: 16)
        .background(color.opacity(0.15), in: Capsule())
        .help(help)
    }

    private func trackRow(_ track: Track) -> some View {
        trackRow(track, number: nil) { EmptyView() }
    }

    /// Riga di un brano, con un accessorio finale opzionale (es. la scritta "Select"/"Deseleziona")
    /// nello stesso HStack — cosi c'è un solo Spacer a spingere tutto a destra, invece di
    /// annidarne un secondo attorno a questa vista.
    @ViewBuilder
    private func trackRow<Trailing: View>(_ track: Track, number: String? = nil, insideAlbum: Bool = false, selectionOnLeft: Bool = true,
                                          artistFirst: Bool = false, repeats: CustomRepeats? = nil,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
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
            VStack(alignment: .leading, spacing: settings.listTextSize.lineSpacing) {
                // «Artista in evidenza» (solo Custom Playlist): artista in grande, titolo e album sulla riga piccola.
                Text(artistFirst ? track.artist : track.title).font(.system(size: settings.listTextSize.points)).lineLimit(1)
                if !insideAlbum {
                    HStack(spacing: 6) {
                        Text(artistFirst ? "\(track.title) — \(track.album)" : "\(track.artist) — \(track.album)")
                            .font(.system(size: settings.listTextSize.secondaryPoints)).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if let differing = artistDifferingFromAlbum(track) {
                    // Dentro un album (schede Album e Artisti) l'album e il suo artista sono già nell'intestazione:
                    // sotto il brano resta solo l'artista, e solo se diverso da quello dell'album (raccolte).
                    Text(differing).font(.system(size: settings.listTextSize.secondaryPoints)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let repeats, repeats.hasAny { repeatBadges(repeats) }
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
                            Image(systemName: "arrow.right.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, statusIconGreen)
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
            // 2.3 Beta 3 (dispositivo): colonna «in playlist» prima della durata, come nel pannello Music.
            if showsInstantMembershipBalloon, artworkOriginProvider == nil, category != .playlists, let lookup = playlistsContainingTrack {
                deviceMembershipColumn(track, lookup)
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
                        if track.isBlocked {
                            Color.clear
                        } else if track.isDeviceOnly {
                            Image(systemName: "watch.analog")
                                .foregroundStyle(statusIconGreen)
                                .help(t("tooltip_device_only_track"))
                        } else if onDevice(track) {
                            Image(systemName: "arrow.right.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, statusIconGreen)
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
                playingIndicator.offset(x: -19)
            }
        }
    }

    /// Colonna «in playlist» del pannello dispositivo: icona per i brani inseriti in almeno una playlist, vuota per gli altri
    /// (larghezza fissa, per l'allineamento). Al passaggio del mouse mostra subito il balloon (vedi `membershipBalloonOverlay`).
    private func deviceMembershipColumn(_ track: Track, _ lookup: (Track) -> [(id: String, title: String)]) -> some View {
        let list = lookup(track)
        return Group {
            if list.isEmpty {
                Color.clear
            } else {
                Image(systemName: "music.note.list")
                    .foregroundStyle(Color.statusNeutral)
                    .overlay(GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onHover { inside in
                                let frame = geo.frame(in: .named("catalogBrowser"))
                                if inside {
                                    membershipHover = MembershipHover(
                                        names: list.prefix(Self.membershipMenuLimit).map { $0.title },
                                        more: max(0, list.count - Self.membershipMenuLimit),
                                        frame: frame)
                                } else if membershipHover?.frame == frame {
                                    membershipHover = nil
                                }
                            }
                    })
            }
        }
        .font(.system(size: 14))
        .frame(width: 20)
    }

    /// Balloon immediato dell'icona «in playlist»: a sinistra dell'icona, centrato in verticale e tenuto dentro il pannello; disegnato
    /// sopra l'intero elenco (non dentro la riga, che lo taglierebbe).
    @ViewBuilder
    private var membershipBalloonOverlay: some View {
        if let hover = membershipHover {
            GeometryReader { geo in
                let lines = hover.names.count + (hover.more > 0 ? 1 : 0)
                let height = CGFloat(lines) * 16 + 14
                let top = min(max(hover.frame.midY - height / 2, 4), max(4, geo.size.height - height - 4))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(hover.names.enumerated()), id: \.offset) { _, name in
                        Text(name).lineLimit(1)
                    }
                    if hover.more > 0 {
                        Text(t("menu_show_in_playlist_more", hover.more)).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, max(0, geo.size.width - hover.frame.minX + 6))
                .padding(.top, top)
            }
            .allowsHitTesting(false)
            .transition(.identity)
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

    /// Righe che la lista mostra con i gruppi aperti attuali (intestazioni + brani/album dei gruppi aperti). Diagnostica e pulizia.
    private func visibleRowCount(_ groups: [TrackGroup<Track>]) -> Int {
        groups.reduce(0) { total, g in
            guard expandedGroups.contains(g.id) else { return total + 1 }
            if g.subgroups.isEmpty { return total + 1 + g.tracks.count }
            return total + 1 + g.subgroups.reduce(0) { $0 + 1 + (expandedGroups.contains($1.id) ? $1.tracks.count : 0) }
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
        return "\(hasher.finalize())|\(genreKey ?? "")|\(query)|\(settings.albumOrder.rawValue)"
    }

    /// Brani filtrati e in ordine alfabetico per titolo (scheda Brani), in memoria finché non cambia la chiave.
    /// Con «solo senza copertina» il risultato dipende dalla scansione in corso: nessuna memoria.
    private var sortedFilteredSongs: [Track] {
        if onlyWithoutCover { return filteredSongs.sortedAlphabeticallyByTitle() }
        let key = derivedKey
        if derived.songsKey == key { return derived.songs }
        let perfStart = Date()
        let value = filteredSongs.sortedAlphabeticallyByTitle()
        AppLog.debug("[prestazioni] Elenco Brani ricalcolato: \(tracks.count) brani, \(String(format: "%.2f", Date().timeIntervalSince(perfStart))) s")
        derived.songsKey = key
        derived.songs = value
        return value
    }

    private var filteredAlbums: [TrackGroup<Track>] {
        let key = derivedKey
        if derived.albumsKey == key { return derived.albums }
        let perfStart = Date()
        let groups = scopedTracks.groupedByAlbum(byDateAdded: settings.albumOrder == .dateAdded)
        AppLog.debug("[prestazioni] Elenco Album ricalcolato: \(tracks.count) brani → \(groups.count) album, \(String(format: "%.2f", Date().timeIntervalSince(perfStart))) s")
        let value = query.isEmpty ? groups : groups.filter { $0.title.localizedCaseInsensitiveContains(query) }
        derived.albumsKey = key
        derived.albums = value
        return value
    }

    private var filteredArtists: [TrackGroup<Track>] {
        let key = derivedKey
        if derived.artistsKey == key { return derived.artists }
        let perfStart = Date()
        let groups = scopedTracks.groupedByAlbumArtist()
        AppLog.debug("[prestazioni] Elenco Artisti ricalcolato: \(tracks.count) brani → \(groups.count) artisti, \(String(format: "%.2f", Date().timeIntervalSince(perfStart))) s")
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
            return found.isEmpty ? nil : TrackGroup(id: g.id, title: g.title, subtitle: playlistSubtitle(found), tracks: found, folderPath: g.folderPath, isSmart: g.isSmart)
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

/// Riquadro dell'artista nella scheda Artisti: la miniatura dell'artista (`ArtistThumbnailService`) o, se manca, un quadrato vuoto.
/// La miniatura già salvata sul disco compare subito; quella da scaricare parte dopo 0,2 s da quando la riga è visibile
/// (scorrendo in fretta l'attività si annulla) e solo se `fetchOnline` è attivo (libreria locale e impostazione «Apple Music artwork»).
private struct ArtistCoverBox: View {
    let name: String
    let size: CGFloat
    let fetchOnline: Bool
    /// Voce «Compilations»: non è un artista, mostra il simbolo di due persone.
    var isCompilations = false
    @State private var image: NSImage?

    /// Miniature già decodificate (nome → immagine), per non rileggere il disco a ogni riga che riappare.
    private static let memory = NSCache<NSString, NSImage>()
    /// Lato della miniatura richiesta, in pixel (doppio della finestra più grande, per gli schermi Retina).
    static let pixels = 100

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if isCompilations {
                // Compilations: «person.2.fill» grigio (SF Symbols), senza cerchio.
                Image(systemName: "person.2.fill")
                    .resizable().scaledToFit()
                    .frame(width: size * 0.78)
                    .foregroundStyle(Color.secondary.opacity(0.7))
            } else {
                // Artista senza miniatura (non trovata o non ancora scaricata): cerchio grigio con il microfono bianco, come Apple Music.
                Image(systemName: "music.mic.circle.fill")
                    .resizable().scaledToFit()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.secondary.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())   // come in Apple Music: artisti in cerchio, album in quadrato (per tornare al quadrato: RoundedRectangle(cornerRadius: size * 0.18))
        .task(id: "\(name)|\(fetchOnline)") {
            guard !name.isEmpty else { image = nil; return }
            let key = name as NSString
            if let known = Self.memory.object(forKey: key) { image = known; return }
            image = nil
            let service = ArtistThumbnailService.shared
            var data = await service.cachedThumbnail(for: name, size: Self.pixels)
            if data == nil, fetchOnline {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
                data = await service.thumbnail(for: name, size: Self.pixels)
            }
            if Task.isCancelled { return }
            if let data, let img = NSImage(data: data) {
                Self.memory.setObject(img, forKey: key)
                image = img
            }
        }
        // Una miniatura scaricata in sottofondo mentre la riga è visibile e ancora vuota: si rilegge dal disco.
        .onReceive(NotificationCenter.default.publisher(for: ArtistThumbnailService.didArriveNotification)) { note in
            guard image == nil, !name.isEmpty, (note.userInfo?["name"] as? String) == name else { return }
            Task {
                if let data = await ArtistThumbnailService.shared.cachedThumbnail(for: name, size: Self.pixels),
                   let img = NSImage(data: data) {
                    Self.memory.setObject(img, forKey: name as NSString)
                    image = img
                }
            }
        }
    }
}

/// Miniatura della copertina per una riga di brano o per l'intestazione di un album.
/// Carica l'immagine in modo asincrono al primo apparire e la mette in cache per la durata
/// della vista; se non c'è alcun provider, o il provider restituisce nil, mostra un segnaposto.
/// Miniatura di una playlist (32 pt): mosaico 2×2 con le copertine di quattro brani di album diversi, o la copertina del primo
/// brano che ce l'ha se gli album con copertina sono meno di quattro, o il segnaposto se nessuno ce l'ha.
/// 2.3 Beta 3: si prendono le prime quattro copertine **disponibili**, saltando i brani senza copertina (prima si sceglievano i
/// primi quattro album e quelli senza copertina lasciavano celle vuote nel mosaico). La ricerca è in ordine, si ferma alla quarta
/// trovata e guarda al massimo 12 album diversi (dispositivo: ogni copertina è una lettura MTP).
private struct PlaylistMosaic<Track: CatalogTrack>: View {
    let tracks: [Track]
    let provider: ((Track) async -> Data?)?
    let version: Int

    @State private var images: [NSImage] = []

    var body: some View {
        Group {
            if images.count >= 4 {
                VStack(spacing: 2) {
                    HStack(spacing: 2) { cell(images[0]); cell(images[1]) }
                    HStack(spacing: 2) { cell(images[2]); cell(images[3]) }
                }
            } else if let first = images.first {
                Image(nsImage: first).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "music.note.list").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(tracks.count)|\(tracks.first.map { String(describing: $0.id) } ?? "")|\(tracks.last.map { String(describing: $0.id) } ?? "")|\(version)") {
            guard let provider else { return }
            var seen = Set<String>()
            var found: [NSImage] = []
            var tried = 0
            for track in tracks.prefix(300) {
                let key = track.album.isEmpty ? "t|" + String(describing: track.id) : track.album.lowercased()
                guard seen.insert(key).inserted else { continue }
                tried += 1
                if tried > 12 { break }
                if Task.isCancelled { return }
                if let data = await provider(track), let image = NSImage(data: data) {
                    found.append(image)
                    if found.count == 4 { break }
                }
            }
            if !Task.isCancelled { images = found }
        }
    }

    private func cell(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            .frame(width: 15, height: 15)
            .clipShape(RoundedRectangle(cornerRadius: 15 * 0.18))
    }
}


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
/// Segno di selezione unico per tutte le schede: cerchio verde con spunta (selezionato) o trattino (selezione parziale).
private struct SelectionMark: View {
    let partial: Bool
    var body: some View {
        Image(systemName: partial ? "minus.circle.fill" : "checkmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, statusIconGreen)
            .font(.system(size: 18))
    }
}

private struct SelectToggleIcon: View {
    enum State { case none, partial, all }
    let state: State
    var hidden = false   // invisibile e non cliccabile, ma occupa lo spazio (incolonnamento)
    /// Intestazione di un gruppo (Playlist / Album / Artista) invece di un brano: cambia l'icona.
    var isGroup = false
    let action: () -> Void
    /// Larghezza della colonna di selezione (2.3 Beta 2: ridotta da 24 a 20 pt, il tondino misura 18).
    static let columnWidth: CGFloat = 20

    var body: some View {
        Button(action: action) {
            // Stesso segno in tutte le schede: cerchio verde con spunta (tutto) o trattino (parziale), come sulle copertine delle playlist.
            switch state {
            case .none:
                Image(systemName: "circle").foregroundStyle(.secondary)
            case .partial:
                SelectionMark(partial: true)
            case .all:
                SelectionMark(partial: false)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 18))
        .frame(width: Self.columnWidth, alignment: .center)   // larghezza uguale per tutti i simboli: le colonne restano allineate
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
            if self.firstLetterOnly, !self.text.isEmpty {
                // Già posizionati sulla prima lettera. Build 28: l'orario si aggiorna anche per i tasti ignorati; prima, se lo
                // spostamento della prima lettera teneva occupata l'interfaccia per oltre un secondo, il tasto successivo
                // risultava «dopo una pausa» e avviava un nuovo salto (ogni carattere digitato = un nuovo blocco).
                self.lastTime = event.timestamp
                return nil
            }
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

    /// Righe visibili la cui vista non è dove la tabella dice che dovrebbe essere (o non esiste): sullo schermo la lista
    /// risulta vuota o sovrapposta anche se «le righe ci sono». Succede dopo un'apertura/chiusura quando le altezze cambiano.
    fileprivate static func misplacedRows(in table: NSTableView) -> Int {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return 0 }
        var bad = 0
        for r in visible.location..<(visible.location + visible.length) {
            let want = table.rect(ofRow: r)
            if let rv = table.rowView(atRow: r, makeIfNecessary: false) {
                if abs(rv.frame.minY - want.minY) > 1 || abs(rv.frame.height - want.height) > 1 { bad += 1 }
            } else { bad += 1 }
        }
        return bad
    }

    /// Rimette le viste delle righe al loro posto, come farebbe uno scorrimento col trackpad.
    fileprivate static func realign(_ scrollView: NSScrollView, _ table: NSTableView) {
        let c = scrollView.contentView
        let y = c.bounds.origin.y
        table.tile()
        c.scroll(to: NSPoint(x: c.bounds.origin.x, y: y + 1))
        scrollView.reflectScrolledClipView(c)
        c.scroll(to: NSPoint(x: c.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(c)
        table.layoutSubtreeIfNeeded()
        table.setNeedsDisplay(table.visibleRect)
        table.displayIfNeeded()
    }

    /// Diagnostica (registro dettagliato): dopo un clic registra posizione, riga in cima e altezza della lista a intervalli.
    static func traceAfterClick(_ what: String) {
        guard let type = NSApp.currentEvent?.type,
              [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp].contains(type) else { return }
        guard let window = NSApp.currentEvent?.window ?? NSApp.keyWindow ?? NSApp.mainWindow, let root = window.contentView,
              let scrollView = scrollViews(in: root, containing: window.mouseLocationOutsideOfEventStream).first,
              let table = scrollView.documentView as? NSTableView else { return }
        let clip = scrollView.contentView
        let savedY = clip.bounds.origin.y
        let probeX = table.bounds.midX
        func topRow(_ y: CGFloat) -> Int { table.row(at: NSPoint(x: probeX, y: min(max(y + 140, 0), table.bounds.height - 1))) }
        let startRow = topRow(savedY)
        let startRows = table.numberOfRows
        let startHeight = Int(table.bounds.height)
        AppLog.debug("[scorrimento] clic «\(what)»: y \(Int(savedY)); riga in cima \(startRow); righe \(startRows); altezza \(startHeight)")
        for delay in [0.1, 0.3, 0.7, 1.5, 3.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak scrollView, weak table] in
                guard let scrollView, let table else { return }
                let c = scrollView.contentView
                let y = c.bounds.origin.y
                let row = table.row(at: NSPoint(x: probeX, y: min(max(y + 140, 0), table.bounds.height - 1)))
                let visible = table.rows(in: table.visibleRect)
                var drawn = 0
                for r in visible.location..<(visible.location + visible.length) where table.rowView(atRow: r, makeIfNecessary: false) != nil { drawn += 1 }
                let misplaced = misplacedRows(in: table)
                AppLog.debug("[scorrimento] … +\(delay) s: y \(Int(y)) (da \(Int(savedY))); riga in cima \(row) (da \(startRow)); righe \(table.numberOfRows); altezza \(Int(table.bounds.height)) (da \(startHeight)); righe visibili \(visible.length), disegnate \(drawn), fuori posto \(misplaced)")
                if misplaced > 0 {
                    realign(scrollView, table)
                    AppLog.debug("[scorrimento] righe fuori posto (\(misplaced)): riallineate, ora \(misplacedRows(in: table))")
                }
                // Lista visibile ma vuota (righe non create): uno scorrimento più ampio, avanti e indietro, le fa ricreare.
                if visible.length > 0, drawn == 0 {
                    c.setBoundsOrigin(NSPoint(x: c.bounds.origin.x, y: y + 80))
                    scrollView.reflectScrolledClipView(c)
                    c.setBoundsOrigin(NSPoint(x: c.bounds.origin.x, y: y))
                    scrollView.reflectScrolledClipView(c)
                    AppLog.debug("[scorrimento] lista vuota: forzato un ridisegno delle righe")
                }
            }
        }
    }

    /// Aprendo/chiudendo un gruppo la tabella può riposizionarsi (es. fino all'ultimo elemento aperto): si legge la posizione
    /// della lista sotto il puntatore e la si ripristina subito dopo il ridisegno, per qualche istante (anche quando arrivano le copertine).
    static func keepPositionAfterToggle() {
        traceAfterClick("apertura/chiusura")
        // Solo se l'apertura/chiusura viene da un clic o da un tasto (non da un ridisegno della tabella durante lo scorrimento).
        guard let type = NSApp.currentEvent?.type,
              [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp].contains(type) else { return }
        guard let window = NSApp.currentEvent?.window ?? NSApp.keyWindow ?? NSApp.mainWindow, let root = window.contentView,
              let scrollView = scrollViews(in: root, containing: window.mouseLocationOutsideOfEventStream).first else { return }
        let clip = scrollView.contentView
        let savedY = clip.bounds.origin.y
        // Si tiene ferma la RIGA che si vedeva in cima (non un'altezza assoluta): se le righe sopra cambiano altezza durante il
        // ridisegno, la lista scivolerebbe di qualche riga. Ci si ferma appena l'utente scorre.
        let (anchorRow, anchorOffset): (Int, CGFloat) = {
            guard let table = scrollView.documentView as? NSTableView else { return (-1, 0) }
            let row = table.row(at: NSPoint(x: table.bounds.midX, y: min(max(savedY + 140, 0), table.bounds.height - 1)))
            return row >= 0 ? (row, savedY - table.rect(ofRow: row).minY) : (-1, 0)
        }()
        final class Flag { var userScrolled = false }
        let flag = Flag()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in flag.userScrolled = true; return event }
        // Le altezze dei blocchi di brani (alti, soprattutto negli Artisti) si misurano a poco a poco anche dopo più secondi:
        // finché la lista non viene scorsa dall'utente si continua a tenere ferma la riga ancorata, fino a 7 secondi.
        let delays: [Double] = [0.0, 0.03, 0.08, 0.15, 0.25, 0.4, 0.6, 0.9, 1.3] + Array(stride(from: 1.55, through: 7.0, by: 0.25))
        let nudgeDelays: Set<Double> = [0.08, 0.25, 0.6, 1.3]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak scrollView] in
                if delay == delays.last, let monitor { NSEvent.removeMonitor(monitor) }
                guard let scrollView, !flag.userScrolled else { return }
                let c = scrollView.contentView
                var target = savedY
                if let table = scrollView.documentView as? NSTableView {
                    if anchorRow >= 0, anchorRow < table.numberOfRows { target = table.rect(ofRow: anchorRow).minY + anchorOffset }
                    // Mai oltre la fine del contenuto (mentre le altezze si ricalcolano sarebbe un'oscillazione continua).
                    let maxY = max(-scrollView.contentInsets.top, table.bounds.height - c.bounds.height + scrollView.contentInsets.bottom)
                    target = min(target, maxY)
                }
                if abs(c.bounds.origin.y - target) > 1 {
                    c.scroll(to: NSPoint(x: c.bounds.origin.x, y: target))
                    scrollView.reflectScrolledClipView(c)
                }
                if let table = scrollView.documentView as? NSTableView, misplacedRows(in: table) > 0 { realign(scrollView, table) }
                // Micro-scorrimento (mezzo punto avanti e indietro): la tabella rimette a posto le righe di cui ha cambiato
                // altezza solo quando riceve uno scorrimento; altrimenti, a lista ferma, restano sovrapposte o vuote.
                if nudgeDelays.contains(delay) {
                    let y0 = c.bounds.origin.y
                    c.setBoundsOrigin(NSPoint(x: c.bounds.origin.x, y: y0 + 0.5))
                    scrollView.reflectScrolledClipView(c)
                    c.setBoundsOrigin(NSPoint(x: c.bounds.origin.x, y: y0))
                    scrollView.reflectScrolledClipView(c)
                }
            }
        }
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
    /// Se vero, la selezione nativa si toglie a ogni aggiornamento (non solo la prima volta): per le liste la cui tabella può essere ricreata.
    var reapplyOnUpdate = false
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        if reapplyOnUpdate, context.coordinator.done {
            var ancestor: NSView? = nsView.superview
            while let a = ancestor {
                if let table = Self.firstTable(in: a) {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                    return
                }
                ancestor = a.superview
            }
            return
        }
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
    private var lastContentHeight: CGFloat = .nan
    func attachSoon() {
        Task { @MainActor [weak self] in self?.attach() }
    }

    private func attach() {
        guard let view, let root = view.window?.contentView else { return }
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        // Build 38: solo le liste visibili (le altre schede restano in vita, nascoste, e potevano essere scelte per errore).
        let candidates = ListScrollHandle.scrollViews(in: root, containing: center).filter { !$0.isHiddenOrHasHiddenAncestor }
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
        defer { lastY = y; lastContentHeight = table.bounds.height }
        // Diagnostica (registro dettagliato): salti di posizione grandi e cambi dell'altezza del contenuto durante lo scorrimento.
        if !lastY.isNaN, abs(y - lastY) > 0.5 {
            let eventType = NSApp.currentEvent.map { String($0.type.rawValue) } ?? "nessuno"
            if abs(y - lastY) > 150 {
                AppLog.debug("[scorrimento] salto di \(Int(y - lastY)) pt (y \(Int(lastY)) → \(Int(y))); evento \(eventType); righe \(table.numberOfRows); altezza contenuto \(Int(table.bounds.height)) (prima \(Int(lastContentHeight.isNaN ? 0 : lastContentHeight))); riga 1: \(Int(table.rect(ofRow: min(1, table.numberOfRows - 1)).height)) pt")
            } else if !lastContentHeight.isNaN, abs(table.bounds.height - lastContentHeight) > 20 {
                let vis = table.rows(in: table.visibleRect)
                let hs = (vis.location..<(vis.location + min(vis.length, 14))).map { Int(table.rect(ofRow: $0).height) }
                AppLog.debug("[scorrimento] altezza del contenuto \(Int(lastContentHeight)) → \(Int(table.bounds.height)) pt durante lo scorrimento (y \(Int(y)); righe \(table.numberOfRows)); righe visibili da \(vis.location): \(hs)")
            }
        }
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
            let isLabel = !showTyped && model.letter.count > 1   // periodo («Questo mese», «2024»): testo più piccolo
            Text(showTyped ? String(typed.suffix(24)) : model.letter)
                .font(.system(size: showTyped ? 20 : (isLabel ? 17 : 26), weight: .bold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, (showTyped || isLabel) ? 14 : 0)
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
            VStack(alignment: .leading, spacing: settings.listTextSize.lineSpacing) {
                Text(track.title).font(.system(size: settings.listTextSize.points)).lineLimit(1)
                Text("\(track.artist) — \(track.album)").font(.system(size: settings.listTextSize.secondaryPoints)).foregroundStyle(.secondary).lineLimit(1)
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


/// Diagnostica 2.3 Beta 1: misura quanto l'interfaccia resta ferma dopo un'azione. Si registra l'istante dell'azione e, appena il ciclo
/// principale torna libero (due giri dopo, cioè dopo il ridisegno della lista), il ritardo con memoria e thread. Solo con il registro dettagliato.
enum PerfLag {
    @MainActor static func measure(_ what: String) {
        StallWatchdog.lastAction = what
        let start = Date()
        let memory = ProcessMemory.residentMB
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                let lag = Date().timeIntervalSince(start)
                AppLog.debug("[prestazioni] Interfaccia: \(what) — libera dopo \(String(format: "%.2f", lag)) s; memoria \(memory) → \(ProcessMemory.residentMB) MB; thread \(ProcessMemory.threadCount)")
            }
        }
    }
}
