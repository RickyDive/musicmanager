import SwiftUI
import AppKit

/// Stato della finestra "Fix Artwork": scorre i brani selezionati uno alla volta, mostra la
/// copertina originale (se c'è) accanto a quella trovata online, e lascia all'utente la decisione
/// su ciascun brano. Nulla viene memorizzato senza un "Confirm" esplicito: la ricerca online parte
/// solo quando si arriva su un brano in questa finestra, e il risultato si vede subito.
///
/// "Confirm" salva subito la copertina nella cache delle copertine confermate (`ArtworkCache`):
/// «Close» e «OK» chiudono la finestra senza toccare altro: le conferme già date restano valide.
@MainActor
final class FixArtworkSession: ObservableObject, Identifiable {
    enum OnlineState {
        case loading
        case found
        case notFound
    }

    let id = UUID()
    let tracks: [LocalTrack]

    @Published private(set) var index = 0
    @Published private(set) var originalImage: NSImage?
    @Published private(set) var originalLoaded = false
    @Published private(set) var online: OnlineState = .loading
    @Published private(set) var onlineImage: NSImage?
    /// Vero se la copertina online mostrata ora è proprio quella confermata per il brano (adesso o
    /// in passato).
    @Published private(set) var isCurrentConfirmed = false
    /// Posizione (da 0) della copertina online mostrata tra i candidati del brano, e loro numero.
    @Published private(set) var candidateIndex = 0
    @Published private(set) var candidateCount = 0
    /// Vero se l'ultimo tentativo di salvare la copertina confermata è fallito (disco pieno...).
    @Published private(set) var saveFailed = false

    private let fetchOriginal: (LocalTrack) async -> Data?
    private let fetchOnline: (LocalTrack) async -> [Data]
    private let onFinish: (Int) -> Void
    /// Vero dopo Close / OK: la vista chiude il pannello.
    @Published var isFinished = false
    /// Chiamata subito dopo ogni "Confirm" andato a buon fine, cosi chi ha aperto la finestra può
    /// aggiornare le copertine mostrate negli elenchi senza aspettare la chiusura.
    private let onConfirmed: () -> Void
    /// Altri brani dello stesso album (stesso artista) che non hanno ancora una copertina confermata.
    private let siblings: (LocalTrack) -> [LocalTrack]

    /// Domanda «applico la stessa copertina agli altri brani dell'album?» (nil = nessuna).
    struct AlbumPrompt {
        let album: String
        let tracks: [LocalTrack]
        let data: Data
    }
    @Published var albumPrompt: AlbumPrompt?
    /// Brani della lista a cui si è appena assegnata la copertina con «Sì» (stesso album): si saltano nella navigazione
    /// e non contano nel «Brano n di N».
    @Published private(set) var albumAssigned: Set<String> = []
    /// N del «Brano n di N»: i brani ancora da guardare più quelli già visti, senza i già assegnati in blocco.
    var displayTotal: Int { tracks.count - albumAssigned.count }
    /// n del «Brano n di N»: posizione del brano mostrato tra quelli non saltati.
    var displayPosition: Int { tracks[..<index].filter { !albumAssigned.contains($0.id) }.count + 1 }
    private func nextIndex() -> Int? { ((index + 1)..<tracks.count).first { !albumAssigned.contains(tracks[$0].id) } }
    private func previousIndex() -> Int? { (0..<index).last { !albumAssigned.contains(tracks[$0].id) } }
    /// Album per cui la domanda è già stata fatta (non si ripropone a ogni brano).
    private var promptedAlbums: Set<String> = []

    private var originalTask: Task<Void, Never>?
    private var onlineTask: Task<Void, Never>?
    /// Risultati della ricerca già ottenuti in questa sessione, per brano: tornando su un brano
    /// con "Previous" non si rifà la richiesta di rete.
    private var fetchedCandidates: [String: [Data]] = [:]
    /// Copertina già confermata per il brano mostrato (se c'è), sempre proposta per prima.
    private var confirmedData: Data?
    private var candidates: [Data] = []
    private var currentOnlineData: Data? {
        candidates.indices.contains(candidateIndex) ? candidates[candidateIndex] : nil
    }
    private var newlyConfirmedCount = 0

    /// Esito per brano (id) man mano che li si guarda: copertina scelta (adesso o in passato), trovata online ma non scelta,
    /// non trovata. I brani senza esito non sono ancora stati controllati. Serve all'avviso del pulsante «OK».
    private enum Outcome { case chosen, foundNotChosen, notFound }
    private var outcomes: [String: Outcome] = [:]
    /// Brani con una copertina online trovata ma non scelta.
    var notChosenCount: Int { outcomes.values.filter { $0 == .foundNotChosen }.count }
    /// Brani non ancora controllati (mai mostrati o ricerca ancora in corso).
    var uncheckedCount: Int { tracks.count - outcomes.count }
    /// Vero se «OK» deve prima avvisare: ci sono copertine non scelte o brani non controllati.
    var needsOKWarning: Bool { notChosenCount > 0 || uncheckedCount > 0 }

    init(tracks: [LocalTrack],
         fetchOriginal: @escaping (LocalTrack) async -> Data?,
         fetchOnline: @escaping (LocalTrack) async -> [Data],
         onConfirmed: @escaping () -> Void,
         siblings: @escaping (LocalTrack) -> [LocalTrack] = { _ in [] },
         onFinish: @escaping (Int) -> Void) {
        self.tracks = tracks
        self.fetchOriginal = fetchOriginal
        self.fetchOnline = fetchOnline
        self.onConfirmed = onConfirmed
        self.siblings = siblings
        self.onFinish = onFinish
        loadCurrent()
    }

    var currentTrack: LocalTrack { tracks[index] }
    var canGoPrevious: Bool { previousIndex() != nil }
    var canGoNext: Bool { nextIndex() != nil }
    var canConfirm: Bool { online == .found && currentOnlineData != nil }
    var canGoPreviousCandidate: Bool { candidateIndex > 0 }
    var canGoNextCandidate: Bool { candidateIndex < candidates.count - 1 }

    /// Frecce sotto la copertina online: scorrono le copertine trovate per il brano mostrato.
    func previousCandidate() {
        guard canGoPreviousCandidate else { return }
        showCandidate(candidateIndex - 1)
    }

    func nextCandidate() {
        guard canGoNextCandidate else { return }
        showCandidate(candidateIndex + 1)
    }

    private func showCandidate(_ index: Int) {
        candidateIndex = index
        onlineImage = currentOnlineData.flatMap { NSImage(data: $0) }
        isCurrentConfirmed = currentOnlineData != nil && currentOnlineData == confirmedData
    }

    // MARK: - Navigazione

    func previous() {
        guard let target = previousIndex() else { return }
        index = target
        loadCurrent()
    }

    func next() {
        guard let target = nextIndex() else { return }
        index = target
        loadCurrent()
    }

    /// Passa al brano successivo (se c'è): sull'ultimo si resta lì e si chiude con «OK» o «Close».
    private func advance() {
        if canGoNext { next() }
    }

    /// «Ignore»: lascia il brano com'è (nessuna copertina scelta) e passa al successivo.
    func ignore() {
        advance()
    }

    /// «Close»: chiude la finestra in qualsiasi momento; le conferme già date restano memorizzate
    /// (sono salvate in `ArtworkCache` al momento del "Confirm", non alla chiusura).
    func close() {
        finish()
    }

    /// «OK»: accetta quanto scelto e chiude (la vista mostra prima l'avviso se `needsOKWarning`).
    func accept() {
        finish()
    }

    /// "Confirm": accetta la copertina trovata online per il brano mostrato, la memorizza e passa
    /// al successivo (sull'ultimo brano si resta lì: si chiude con «OK»).
    func confirm() {
        guard canConfirm, let data = currentOnlineData else { return }
        let track = currentTrack
        let key = ArtworkCache.key(artist: track.artist, title: track.title, album: track.album)

        // Già confermata in passato con la stessa immagine: niente da riscrivere (riscriverla
        // farebbe rimandare inutilmente il brano sull'orologio al prossimo invio).
        if confirmedData == data {
            saveFailed = false
            outcomes[track.id] = .chosen
            if !proposeAlbum(for: track, data: data) { advance() }
            return
        }
        guard ArtworkCache.storeConfirmed(key: key, imageData: data) else {
            saveFailed = true
            return
        }
        saveFailed = false
        newlyConfirmedCount += 1
        confirmedData = data
        isCurrentConfirmed = true
        outcomes[track.id] = .chosen
        onConfirmed()
        if !proposeAlbum(for: track, data: data) { advance() }
    }

    /// Se altri brani dello stesso album sono senza copertina confermata, prepara la domanda.
    /// Ritorna vero se la domanda è stata mostrata (il passaggio al brano successivo avviene dopo la risposta).
    private func proposeAlbum(for track: LocalTrack, data: Data) -> Bool {
        let albumKey = (track.artist + "|" + track.album).lowercased()
        guard !track.album.isEmpty, !promptedAlbums.contains(albumKey) else { return false }
        let others = siblings(track)
        guard !others.isEmpty else { return false }
        promptedAlbums.insert(albumKey)
        albumPrompt = AlbumPrompt(album: track.album, tracks: others, data: data)
        return true
    }

    /// «Sì»: la stessa copertina diventa quella confermata di tutti gli altri brani dell'album.
    func applyToAlbum() {
        guard let prompt = albumPrompt else { return }
        albumPrompt = nil
        var stored = 0
        for other in prompt.tracks {
            let key = ArtworkCache.key(artist: other.artist, title: other.title, album: other.album)
            if ArtworkCache.storeConfirmed(key: key, imageData: prompt.data) {
                stored += 1
                if tracks.contains(where: { $0.id == other.id }) {
                    outcomes[other.id] = .chosen
                    if other.id != currentTrack.id { albumAssigned.insert(other.id) }   // saltato dalla navigazione e dal conteggio
                }
            }
        }
        if stored > 0 {
            newlyConfirmedCount += stored
            onConfirmed()
        }
        advance()
    }

    /// «No»: solo il brano scelto; si passa al successivo.
    func declineAlbum() {
        guard albumPrompt != nil else { return }
        albumPrompt = nil
        advance()
    }

    private func finish() {
        originalTask?.cancel()
        onlineTask?.cancel()
        onFinish(newlyConfirmedCount)
        isFinished = true   // il pannello di vetro si chiude (vedi `FixArtworkView`)
    }

    // MARK: - Caricamento del brano corrente

    private func loadCurrent() {
        originalTask?.cancel()
        onlineTask?.cancel()

        let track = currentTrack
        let key = ArtworkCache.key(artist: track.artist, title: track.title, album: track.album)
        saveFailed = false
        originalImage = nil
        originalLoaded = false

        // Nuovo brano: si riparte dai candidati vuoti (non si deve "mantenere" quello del precedente).
        candidates = []
        candidateIndex = 0
        // Copertine online: prima quella già confermata (se c'è), poi quelle trovate dal servizio
        // (cercate una sola volta per brano in questa sessione).
        confirmedData = ArtworkCache.confirmedImage(forKey: key)
        let alreadyFetched = fetchedCandidates[track.id]
        setCandidates(merged(confirmed: confirmedData, fetched: alreadyFetched ?? []),
                      finished: alreadyFetched != nil)
        if alreadyFetched == nil {
            let fetchOnline = self.fetchOnline
            onlineTask = Task { [weak self] in
                let found = await fetchOnline(track)
                guard !Task.isCancelled, let self, self.currentTrack.id == track.id else { return }
                self.fetchedCandidates[track.id] = found
                self.setCandidates(self.merged(confirmed: self.confirmedData, fetched: found), finished: true)
            }
        }

        let fetchOriginal = self.fetchOriginal
        originalTask = Task { [weak self] in
            let data = await fetchOriginal(track)
            guard !Task.isCancelled, let self, self.currentTrack.id == track.id else { return }
            self.originalImage = data.flatMap { NSImage(data: $0) }
            self.originalLoaded = true
        }
    }

    private func merged(confirmed: Data?, fetched: [Data]) -> [Data] {
        var result: [Data] = []
        if let confirmed { result.append(confirmed) }
        for data in fetched where !result.contains(data) { result.append(data) }
        return result
    }

    /// Imposta i candidati mostrati; `finished` indica che la ricerca di rete è terminata (senza
    /// candidati vuol dire "non trovata", altrimenti si è ancora in attesa).
    private func setCandidates(_ list: [Data], finished: Bool) {
        // Se l'elenco si aggiorna a ricerca finita, si resta sulla copertina già mostrata.
        let shown = currentOnlineData
        candidates = list
        candidateCount = list.count
        let keep = shown.flatMap { list.firstIndex(of: $0) } ?? 0
        online = list.isEmpty ? (finished ? .notFound : .loading) : .found
        showCandidate(min(keep, max(list.count - 1, 0)))
        // Esito del brano mostrato (senza toccare una scelta già fatta).
        let id = currentTrack.id
        if outcomes[id] != .chosen {
            if confirmedData != nil { outcomes[id] = .chosen }
            else if !list.isEmpty { outcomes[id] = .foundNotChosen }
            else if finished { outcomes[id] = .notFound }
        }
    }
}


/// Finestra di dialogo "Fix Artwork" (vedi `FixArtworkSession`). Stesso schema del pannello dei file trascinati
/// (`DroppedFilesView`): fascia grigia in alto con copertine e dati del brano, frecce sovrapposte alla copertina online
/// (chevron doppio se ne restano più di una in quella direzione), «Confirm» e «Ignore» nella fascia grigia, barra in
/// basso con Close a sinistra, frecce e «Brano n di N» al centro, «OK» a destra.
struct FixArtworkView: View {
    @ObservedObject var session: FixArtworkSession
    /// Chiude il pannello di vetro (chiamata da `isFinished`).
    var onClose: () -> Void = {}
    @State private var showOKWarning = false

    /// Larghezza comune dei quattro pulsanti di testo (Confirm, Ignore, Close, OK): quella dell'etichetta più lunga tra le lingue
    /// più il margine dello stile piatto, così restano tutti uguali (come i pulsanti della finestra principale).
    private var textButtonWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = AppLanguage.allCases.flatMap { lang in
            ["button_confirm", "button_ignore", "button_close", "button_ok"].map {
                (tFor(lang, $0) as NSString).size(withAttributes: [.font: font]).width
            }
        }.max() ?? 0
        return max(ceil(widest) + 28, 84)
    }

    /// Testo dell'avviso di «OK»: copertine online trovate ma non scelte e brani non ancora controllati.
    private var okWarningMessage: String {
        var lines: [String] = []
        if session.notChosenCount > 0 { lines.append(t("alert_fix_ok_not_chosen", session.notChosenCount)) }
        if session.uncheckedCount > 0 { lines.append(t("alert_fix_ok_unchecked", session.uncheckedCount)) }
        return lines.joined(separator: "\n")
    }

    /// Lato delle due copertine: quanto serve alla scritta «L'artwork è già presente nella Libreria» per stare per esteso su
    /// una riga sotto la copertina originale (misurata sulla più lunga tra le lingue; almeno 170 pt). Così le copertine sono
    /// più grandi e la distanza tra le due colonne resta quella normale.
    private var artworkSize: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .bold)
        let widest = AppLanguage.allCases.map { (tFor($0, "fix_artwork_still_present") as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // + icona e spazio prima del testo
        return max(170, ceil(widest) + 20)
    }
    /// Altezza fissa del piede sotto ogni copertina: una riga di caption in grassetto (la più alta tra «Artwork updated» e
    /// l'icona del segno di spunta), calcolata dal carattere. Il pannello non cambia altezza né cambiando brano né quando
    /// compare la scritta.
    private var footerHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .bold)
        return ceil(font.boundingRectForFont.height) + 2
    }

    var body: some View {
        let track = session.currentTrack

        VStack(alignment: .leading, spacing: 0) {
            // Fascia grigia: copertina originale, copertina online, dati del brano.
            HStack(alignment: .top, spacing: 20) {
                artworkColumn(title: t("fix_artwork_original")) {
                    originalContent
                } footer: {
                    if session.originalImage != nil {
                        Label {
                            Text(t("fix_artwork_still_present"))
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(.blue)
                        }
                        .font(.caption.bold()).foregroundStyle(.blue)
                        .lineLimit(1).fixedSize()
                    }
                }

                artworkColumn(title: t("fix_artwork_online")) {
                    onlineContent
                        .overlay { candidateArrows }
                } footer: {
                    // Stessa scritta della finestra di trasferimento: la copertina online è stata confermata.
                    if session.isCurrentConfirmed {
                        Label(t("transfer_note_artwork_applied"), systemImage: "checkmark.circle.fill")
                            .font(.caption.bold()).foregroundStyle(.green)
                            .lineLimit(1)
                    }
                }

                // Dati del brano mostrato: titolo in grassetto, poi artista e album (come nel pannello dei file trascinati).
                VStack(alignment: .leading, spacing: 6) {
                    Text(track.title).font(.system(size: 21, weight: .bold)).lineLimit(2)
                    if !track.artist.isEmpty { Text(track.artist).font(.system(size: 14)).foregroundStyle(.secondary) }
                    Text(track.album.isEmpty ? t("unknown_album") : track.album)
                        .font(.system(size: 14)).foregroundStyle(.secondary)

                    if session.saveFailed {
                        Text(t("fix_artwork_save_failed"))
                            .font(.caption).foregroundStyle(.red)
                    }

                    Spacer(minLength: 12)

                    // Scelte sul brano mostrato, in basso allineate al bordo inferiore della copertina.
                    HStack(spacing: 8) {
                        Button { session.confirm() } label: { Text(t("button_confirm")).frame(width: textButtonWidth) }
                            .buttonStyle(.flatRoomy)
                            .disabled(!session.canConfirm)
                        Button { session.ignore() } label: { Text(t("button_ignore")).frame(width: textButtonWidth) }
                            .buttonStyle(.flatRoomy)
                            .disabled(!session.canGoNext)
                    }
                }
                .padding(.top, 22)
                // Il piede sotto la copertina (altezza fissa + spazio): i pulsanti arrivano al bordo inferiore della copertina.
                .padding(.bottom, footerHeight + 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12))

            // Barra in basso: Close a sinistra, OK a destra; con più brani, al centro frecce e «Brano n di N».
            HStack {
                Button { session.close() } label: { Text(t("button_close")).frame(width: textButtonWidth) }
                    .buttonStyle(.flatRoomy)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    if session.needsOKWarning { showOKWarning = true } else { session.accept() }
                } label: { Text(t("button_ok")).frame(width: textButtonWidth) }
                .buttonStyle(.flatProminentRoomy)
                .keyboardShortcut(.defaultAction)
            }
            .overlay {
                if session.displayTotal > 1 {
                    HStack(spacing: 10) {
                        Button { session.previous() } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.flatRoomy)
                            .disabled(!session.canGoPrevious)
                        // Balloon di larghezza fissa (testo più lungo possibile): non si allarga passando alle doppie cifre.
                        Button {} label: {
                            Text(t("fix_artwork_progress", session.displayPosition, session.displayTotal))
                                .font(.caption).lineLimit(1)
                                .frame(width: progressWidth)
                        }
                        .buttonStyle(.flatRoomy)
                        .controlSize(.small)
                        .allowsHitTesting(false)
                        Button { session.next() } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.flatRoomy)
                            .disabled(!session.canGoNext)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 760)
        .fixedSize(horizontal: false, vertical: true)
        // Domande interne come strato sopra il pannello (un `.alert` in un pannello senza bordi non è affidabile).
        .overlay {
            if showOKWarning {
                promptCard(title: t("alert_fix_ok_title"), message: okWarningMessage,
                           primary: (t("button_continue"), { showOKWarning = false; session.accept() }),
                           secondary: (t("button_back"), { showOKWarning = false }))
            } else if session.albumPrompt != nil {
                promptCard(title: t("alert_fix_album_title"),
                           message: (session.albumPrompt?.tracks.count ?? 0) == 1
                               ? t("alert_fix_album_message_one", session.albumPrompt?.album ?? "")
                               : t("alert_fix_album_message", session.albumPrompt?.tracks.count ?? 0, session.albumPrompt?.album ?? ""),
                           primary: (t("button_yes"), { session.applyToAlbum() }),
                           secondary: (t("button_no"), { session.declineAlbum() }))
            }
        }
        .onChange(of: session.isFinished) { _, done in
            if done { onClose() }
        }
    }

    /// Scheda di domanda al centro del pannello, con un velo sul resto.
    private func promptCard(title: String, message: String,
                            primary: (String, () -> Void), secondary: (String, () -> Void)) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 14) {
                Text(title).font(.headline).multilineTextAlignment(.center)
                Text(message).font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(action: secondary.1) { Text(secondary.0).frame(minWidth: 70) }
                        .buttonStyle(.flatRoomy)
                        .keyboardShortcut(.cancelAction)
                    Button(action: primary.1) { Text(primary.0).frame(minWidth: 70) }
                        .buttonStyle(.flatProminentRoomy)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: 18).fill(.regularMaterial))
        }
    }

    // MARK: - Pezzi di interfaccia

    /// Larghezza fissa del balloon «Brano n di N»: quella del testo più lungo (ultimo brano) più margine.
    private var progressWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let count = session.tracks.count   // il testo più lungo possibile (nessun brano saltato)
        let widest = (t("fix_artwork_progress", count, count) as NSString).size(withAttributes: [.font: font]).width
        return max(ceil(widest) + 36, 120)
    }

    /// Frecce sovrapposte alla copertina online (solo con più candidate): nessuna freccia se non ne restano in quella
    /// direzione, chevron singolo se ne resta una, doppio se più di una.
    @ViewBuilder
    private var candidateArrows: some View {
        if session.candidateCount > 1 {
            let before = session.candidateIndex
            let after = session.candidateCount - 1 - session.candidateIndex
            HStack {
                if before > 0 {
                    arrowButton(before == 1 ? "chevron.left" : "chevron.left.2") { session.previousCandidate() }
                }
                Spacer(minLength: 0)
                if after > 0 {
                    arrowButton(after == 1 ? "chevron.right" : "chevron.right.2") { session.nextCandidate() }
                }
            }
            .padding(6)
        }
    }

    private func arrowButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
        .buttonStyle(.plain)
    }

    /// Colonna con titolo, copertina quadrata e un piede di altezza fissa (scritte di stato).
    private func artworkColumn<Content: View, Footer: View>(title: String,
                                                            @ViewBuilder content: () -> Content,
                                                            @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            // Il piede sta in uno spazio sempre presente (anche senza scritta): un `.frame` direttamente su un contenuto
            // vuoto non occupa spazio, e la finestra si alzava solo quando compariva «Artwork updated».
            Color.clear
                .frame(width: artworkSize, height: footerHeight)
                .overlay(alignment: .topLeading) { footer() }
        }
    }

    @ViewBuilder
    private var originalContent: some View {
        if let image = session.originalImage {
            artworkImage(image)
        } else if !session.originalLoaded {
            placeholder { ProgressView().controlSize(.small) }
        } else {
            placeholder { placeholderLabel(t("fix_artwork_none"), icon: "photo") }
        }
    }

    @ViewBuilder
    private var onlineContent: some View {
        switch session.online {
        case .loading:
            placeholder {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(t("fix_artwork_searching")).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .found:
            if let image = session.onlineImage {
                artworkImage(image)
            } else {
                placeholder { placeholderLabel(t("fix_artwork_not_found"), icon: "magnifyingglass") }
            }
        case .notFound:
            placeholder { placeholderLabel(t("fix_artwork_not_found"), icon: "magnifyingglass") }
        }
    }

    private func artworkImage(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
    }

    private func placeholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.secondary.opacity(0.18)
            content()
        }
    }

    private func placeholderLabel(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(8)
    }
}
