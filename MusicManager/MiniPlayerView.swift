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
import AVKit
import CoreAudio

/// Mini player per l'ascolto dei brani di Apple Music, selezionati nell'elenco con un doppio
/// click: copertina a sinistra (grande quanto l'altezza disponibile), titolo in grassetto,
/// artista/album, barra di avanzamento scorrevole a mano con i tempi, e i controlli
/// indietro/play-pausa/avanti (che scorrono la "coda" di brani in cui si è fatto doppio click).
struct MiniPlayerView: View {
    @ObservedObject var player: PlayerService
    /// Uscita audio attuale (cuffie, AirPods, AirPlay…), per l'icona accanto al pulsante AirPlay.
    @StateObject private var route = AudioRouteMonitor()
    let track: LocalTrack?
    let artwork: NSImage?
    let onTogglePlayPause: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onSeek: (TimeInterval) -> Void
    /// Playlist da cui si sta riproducendo (nil altrimenti), con l'ordine effettivo dei brani e la
    /// posizione corrente: abilitano nome cliccabile + balloon, casuale e ripetizione.
    var playlistName: String? = nil
    var playlistIcon: String = "music.note.list"
    var queue: [LocalTrack] = []
    var queuePosition: Int = 0
    var isShuffle: Binding<Bool> = .constant(false)
    var isRepeat: Binding<Bool> = .constant(false)
    /// Anteprima: 15 s da circa il 30 % di ogni brano (in ogni pannello del player).
    var isPreview: Binding<Bool> = .constant(false)
    var onJump: (Int) -> Void = { _ in }
    /// Menu del tasto destro sulla copertina (brano in ascolto): «Invia a Custom» e «Invia all'orologio»,
    /// con le stesse icone dei pulsanti in fondo al pannello. nil = voce assente; `canSendToWatch` false = voce non attiva.
    var onSendToCustom: (() -> Void)? = nil
    var onSendToWatch: (() -> Void)? = nil
    var canSendToWatch: Bool = false
    /// Altre voci del menu (stesso ordine della lista): Fix Artwork online (fisso, se attivo in Impostazioni), vai ad album/artista,
    /// trova simili, «Mostra in playlist» (voce assente se il brano non è in nessuna playlist).
    var canFixArtwork: Bool = false
    var onFixArtwork: (() -> Void)? = nil
    var onGoToAlbum: (() -> Void)? = nil
    var onGoToArtist: (() -> Void)? = nil
    var onFindSimilar: (() -> Void)? = nil
    var playlistsContaining: [(id: String, title: String)] = []
    var onShowInPlaylist: ((String) -> Void)? = nil
    var isBusy: Bool = false
    /// Icone di stato a destra del titolo, come nell'elenco dei brani (acquistato, origine della copertina,
    /// già sul dispositivo, in almeno una playlist). nil = nessuna icona.
    var originProvider: ((LocalTrack) async -> ArtworkOrigin)? = nil
    var artworkRevision: Int = 0
    var isOnDevice: Bool = false
    var isInPlaylist: Bool = false
    /// Riproduzione dalla Custom Playlist: dettagli della riga (numero, tempo progressivo, km PacePro…), al posto dell'icona «in playlist».
    var customInfo: CustomPlayInfo? = nil
    let height: CGFloat

    @State private var showQueue = false
    /// Volume prima del mute (per il ripristino con un secondo click sull'altoparlante).
    @State private var volumeBeforeMute: Float = 0.5
    /// Finestra stretta: controlli più vicini e cursore del volume più corto.
    @Environment(\.compactPane) private var compactPane
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            artworkView
                .frame(width: height, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if let track {
                VStack(alignment: .leading, spacing: customInfo != nil ? 4 : 6) {   // con la tabella Runner gli spazi si stringono
                    // Titolo e artista/album vicini: la riga del titolo ha altezza fissa (le icone di stato, più alte del testo,
                    // non la allargano più) e i due testi stanno in un gruppo con 1 pt di spazio.
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 10) {
                            Text(track.title)
                                .font(.headline)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            statusIcons(track)
                        }
                        .frame(height: 18)
                        Text("\(track.artist) — \(track.album)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    VStack(spacing: 2) {
                        Slider(value: Binding(
                            get: { player.currentTime },
                            set: { onSeek($0) }
                        ), in: 0...max(player.duration, 1))

                        HStack {
                            Text(timeString(player.currentTime))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Text(timeString(player.duration))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }

                    // Riga dei controlli: a sinistra la playlist (solo da playlist), al centro i
                    // controlli di riproduzione, a destra volume + AirPlay. Le due metà laterali hanno
                    // la stessa larghezza flessibile, così i controlli restano centrati.
                    HStack(spacing: 8) {
                        Group {
                            if let playlistName {
                                playlistButton(playlistName)
                            } else {
                                Color.clear.frame(height: 1)
                            }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .clipped()   // il nome della playlist non allarga la riga oltre il pannello

                        HStack(spacing: compactPane ? 10 : 16) {
                            if playlistName != nil {
                                Button { isShuffle.wrappedValue.toggle() } label: {
                                    Image(systemName: "shuffle")
                                        .foregroundStyle(isShuffle.wrappedValue ? Color.accentColor : .secondary)
                                }
                                .help(t("tooltip_player_shuffle"))
                            }

                            Button(action: onPrevious) {
                                Image(systemName: "backward.fill")
                            }
                            .help(t("tooltip_player_previous"))

                            Button(action: onTogglePlayPause) {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2)
                            }
                            .help(player.isPlaying ? t("tooltip_player_pause") : t("tooltip_player_play"))

                            Button(action: onNext) {
                                Image(systemName: "forward.fill")
                            }
                            .help(t("tooltip_player_next"))

                            if playlistName != nil {
                                Button { isRepeat.wrappedValue.toggle() } label: {
                                    Image(systemName: "repeat")
                                        .foregroundStyle(isRepeat.wrappedValue ? Color.accentColor : .secondary)
                                }
                                .help(t("tooltip_player_repeat"))
                            }

                            Button { isPreview.wrappedValue.toggle() } label: {
                                Image(systemName: "timer")
                                    .foregroundStyle(isPreview.wrappedValue ? Color.accentColor : .secondary)
                            }
                            .help(t("tooltip_player_preview"))
                        }
                        .buttonStyle(.borderless)
                        .fixedSize()

                        volumeControl
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    // Custom Playlist con PacePro: percorso da 0 km ai km totali, in fondo (allineato al bordo basso della copertina),
                    // con il runner al posto del cursore. Non si sposta a mano: avanza con la riproduzione (previsione PacePro).
                    // I dettagli a capsule (`customChips`) per ora non sono mostrati: la loro posizione si decide dopo.
                    if let c = customInfo, c.trackID == track.id, let fraction = c.liveFraction(elapsed: player.currentTime) {
                        runnerTable(c)
                        Spacer(minLength: 0)
                        RunnerProgressLine(fraction: fraction, isPlaying: player.isPlaying,
                                           endText: c.totalKm.formatted(.number.precision(.fractionLength(1))) + " " + c.unit)
                            .help(t("custom_live_forecast_help"))
                    }
                }
                // Larghezza vincolata a quella del pannello: barra di riproduzione e volume seguono la finestra.
                .frame(maxWidth: .infinity, alignment: .leading)
                // Altezza fissa quanto la copertina, ancorata in alto: se il contenuto fosse più alto, eccede in basso e non
                // sposta più la copertina verso l'alto (2.5.1).
                .frame(height: height, alignment: .top)
            } else {
                // Testo allineato a sinistra e centrato in verticale rispetto al riquadro vuoto dell'artwork.
                TwoLineHint(text: t("player_no_track"))
                    .frame(maxHeight: .infinity, alignment: .leading)
                // Senza uno Slider (presente solo quando c'è un brano) questo ramo non avrebbe
                // nulla che chiede larghezza flessibile: il riquadro di vetro risulterebbe più
                // stretto all'avvio, finché il primo brano in play non "sbloccasse" la larghezza
                // piena. Larghezza esplicita qui, cosi le dimensioni sono identiche da subito.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .contentShape(Rectangle())
        .contextMenu { playerMenu }   // tasto destro su tutta l'area del miniplayer (cursori compresi)
        .padding(.horizontal, 10).padding(.top, 3).padding(.bottom, 10.5)   //: sotto +7,5 pt = distanza misurata titolo→riquadro (30 px) meno riquadro→schede (15 px), a 2x
        // Nessun vetro proprio: sta dentro il pannello di vetro della barra alta (vedi
        // `glassBars`); altezza e padding restano uguali al riquadro del dispositivo.
    }

    /// Menu del tasto destro, nello stesso ordine di quello dei brani nella lista.
    @ViewBuilder
    private var playerMenu: some View {
        if let track {
            if let onSendToCustom {
                Button { onSendToCustom() } label: {
                    Label(t("menu_send_to_custom"), systemImage: "tray.and.arrow.down").labelStyle(.titleAndIcon)
                }
                .disabled(isBusy || !track.isTransferable)
            }
            if let onSendToWatch {
                Button { onSendToWatch() } label: {
                    Label(t("menu_send_to_device"), systemImage: "arrow.right.circle.fill").labelStyle(.titleAndIcon)
                }
                .disabled(isBusy || !canSendToWatch || !track.isTransferable)
            }
            if canFixArtwork, let onFixArtwork {
                Divider()
                Button { onFixArtwork() } label: {
                    Label(t("menu_artwork_online_fix"), systemImage: "waveform.badge.magnifyingglass").labelStyle(.titleAndIcon)
                }
                .disabled(isBusy)
            }
            Divider()
            if let onGoToAlbum {
                Button { onGoToAlbum() } label: {
                    Label(t("menu_go_to_album"), systemImage: "music.pages").labelStyle(.titleAndIcon)
                }
            }
            if let onGoToArtist {
                Button { onGoToArtist() } label: {
                    Label(t("menu_go_to_artist"), systemImage: "microphone.dynamic.on.stand").labelStyle(.titleAndIcon)
                }
            }
            if let onFindSimilar {
                Button { onFindSimilar() } label: {
                    Label(t("menu_find_similar"), systemImage: "apple.haptics.and.music.note").labelStyle(.titleAndIcon)
                }
                .disabled(isBusy)
            }
            if !playlistsContaining.isEmpty, let onShowInPlaylist {
                Divider()
                Menu {
                    ForEach(Array(playlistsContaining.prefix(15).enumerated()), id: \.offset) { _, entry in
                        Button(entry.title) { onShowInPlaylist(entry.id) }
                    }
                } label: {
                    Label(t("menu_show_in_playlist"), systemImage: "music.note.list").labelStyle(.titleAndIcon)
                }
            }
        }
    }

    /// Stesse icone dell'elenco, nello stesso ordine e in colonne di 20 pt (1 pt tra l'una e l'altra); un brano non
    /// trasferibile mostra al loro posto l'avviso (icona iCloud per «solo cloud», capsula gialla per Hi-Res).
    @ViewBuilder
    private func statusIcons(_ track: LocalTrack) -> some View {
        if let warning = track.warning {
            if warning == t("reason_cloud_only") {
                Image(systemName: "icloud")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 86/255, green: 189/255, blue: 228/255))
                    .help(warning)
            } else {
                let isHiRes = LocalTrack.losslessLabels.contains(warning)
                Text(warning)
                    .font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(isHiRes ? Color(red: 1.0, green: 0.757, blue: 0.027) : Color.orange.opacity(0.25), in: Capsule())
                    .foregroundStyle(isHiRes ? Color.black : Color.orange)
            }
        } else {
            HStack(spacing: 1) {
                Group {
                    if track.isPurchased {
                        Image(systemName: "bag").foregroundStyle(Color.statusNeutral).help(t("purchased_track_help"))
                    } else { Color.clear }
                }
                .font(.system(size: 14)).frame(width: 20)
                if let originProvider {
                    ArtworkOriginIcon(track: track, provider: originProvider, version: artworkRevision)
                }
                Group {
                    if track.isDeviceOnly {
                        Image(systemName: "watch.analog").foregroundStyle(statusIconGreen).help(t("tooltip_device_only_track"))
                    } else if isOnDevice {
                        Image(systemName: "arrow.right.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, statusIconGreen).help(t("artwork_on_device"))
                    } else { Color.clear }
                }
                .font(.system(size: 14)).frame(width: 20)
                Group {
                    if isInPlaylist {
                        Image(systemName: "music.note.list").foregroundStyle(Color.statusNeutral).help(t("tooltip_in_playlist"))
                    } else { Color.clear }
                }
                .font(.system(size: 14)).frame(width: 20)
            }
        }
    }

    /// Tabella di quello che un runner vede sul quadrante: tempo di corsa, distanza e frazione PacePro (passo + numero d'ordine). Celle di
    /// larghezza fissa, allineate a sinistra (come la barra del percorso); il resto della riga a destra resta libero.
    private func runnerTable(_ c: CustomPlayInfo) -> some View {
        let elapsed = player.currentTime
        let time = c.liveRolling(elapsed: elapsed) ?? "—"
        let km = c.liveKm(elapsed: elapsed, decimals: 2) ?? c.kmStart ?? "—"   // due decimali (es. 7,52 km)
        let pace = c.livePace(elapsed: elapsed)
        return HStack(spacing: 0.5) {   // spazio minimo tra le celle: a risoluzione ridotta a destra ne resta poco
            runnerCell(width: 82) {
                Image(systemName: "timer.circle").foregroundStyle(Self.runnerAccent).offset(y: -0.5)
                Text(time)
            }
            runnerCell(width: 82) {
                Image(systemName: "road.lanes").foregroundStyle(Self.runnerAccent).offset(y: -0.5)
                Text(km)
            }
            runnerCell(width: 82, trailing: 1, shrinks: false) {   // meno margine a destra: l'indicatore della frazione sta il più possibile al bordo
                Image(systemName: "shoe.running.and.shadow.fill").foregroundStyle(Self.runnerAccent).offset(y: -0.5)
                Text(pace?.pace ?? "—")
                Spacer(minLength: 0)
                if let lap = pace?.lap {
                    // «1.circle» … «12.circle»: la frazione in corso; oltre la dodicesima resta il numero.
                    if lap <= 12 { Image(systemName: "\(lap).circle").font(.system(size: 12.5)).offset(x: 2) } else { Text("\(lap)") }   // 12,5 pt: il cerchio occupa tutta l'altezza del simbolo e deve stare dentro la cella (15 pt); 2 pt più a destra
                }
            }
            // Cartelli dei km nello spazio a destra: quello del km raggiunto sta fermo a sinistra dell'area; il successivo entra da destra
            // negli ultimi 50 m e, arrivato, prende il posto del precedente. Al traguardo resta solo la bandierina.
            kmSignArea(c, elapsed: elapsed)
                .padding(.leading, 4)   // qualche punto di aria tra la cella del passo e il cartello km
        }
        .offset(y: 1)   // tabella 1 pt più in basso; la linea del runner non si sposta
        .help(t("custom_live_forecast_help"))
    }

    /// Colore d'accento della corsa sui Garmin (rosso): icone delle tre celle (tranne l'indicatore N.lane, bianco), in un rosso chiaro.
    private static let runnerAccent = Color(red: 1.0, green: 128/255, blue: 128/255)

    /// Larghezza del cartello «km N» (fissa, per calcolare lo scorrimento).
    private let kmSignWidth: CGFloat = 54

    private func kmSign(_ n: Int, unit: String) -> some View {
        // Tema chiaro: turchese più scuro e sfondo un po' più pieno, altrimenti il cartello si legge male; tema scuro invariato.
        Text("\(unit) \(n)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(colorScheme == .dark ? Color.teal : Color(red: 0.0, green: 0.40, blue: 0.46))
            .frame(width: kmSignWidth, height: 15)
            .background(Color.teal.opacity(colorScheme == .dark ? 0.18 : 0.28), in: Capsule())
    }

    /// Larghezza approssimata del simbolo della bandierina (15 pt di corpo): serve a farla entrare dal bordo destro come le capsule.
    private let finishFlagGlyphWidth: CGFloat = 14

    private var finishFlag: some View {
        Image(systemName: "flag.checkered")
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.green)
            .frame(width: kmSignWidth, height: 15, alignment: .leading)
    }

    private func kmSignArea(_ c: CustomPlayInfo, elapsed: Double) -> some View {
        let signs = c.liveKmSigns(elapsed: elapsed)
        return GeometryReader { geo in
            let travel = max(0, geo.size.width - kmSignWidth)
            ZStack(alignment: .leading) {
                if signs.finished {
                    finishFlag
                } else {
                    // Il cartello precedente sfuma mentre il nuovo gli scorre sopra (con poco spazio i due si sovrapporrebbero).
                    let slide = travel * (1 - signs.progress)
                    let approaching = signs.approachingKm != nil || signs.approachingFinish
                    if let reached = signs.reached {
                        kmSign(reached, unit: c.unit).opacity(approaching ? min(1, slide / kmSignWidth) : 1)
                    }
                    if let n = signs.approachingKm {
                        kmSign(n, unit: c.unit)
                            .offset(x: slide)
                            .animation(.linear(duration: 0.25), value: signs.progress)
                    } else if signs.approachingFinish {
                        // La bandierina sta a sinistra della sua cella larga come il cartello: per farla entrare dal bordo destro, come le
                        // capsule km, la si sposta in più della differenza di larghezza; a fine corsa l'extra è zero e la posizione finale è invariata.
                        finishFlag
                            .offset(x: slide + (kmSignWidth - finishFlagGlyphWidth) * (1 - signs.progress))
                            .animation(.linear(duration: 0.25), value: signs.progress)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 15)
    }

    private func runnerCell<Content: View>(width: CGFloat, trailing: CGFloat = 6, shrinks: Bool = true, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 3) { content() }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.white)   // testo e icone sempre bianchi al 100% (quadrante scuro, come i Garmin recenti)
            .lineLimit(1)
            .minimumScaleFactor(shrinks ? 0.8 : 1)   // con due decimali (es. «12,52 km») il testo si stringe un poco; il passo PacePro no
            .padding(.leading, 4).padding(.trailing, trailing)
            .frame(width: width, height: 15, alignment: .leading)
            .background(Color(white: 0.12).opacity(0.9), in: RoundedRectangle(cornerRadius: 6, style: .continuous))   // grigio molto scuro al 90%: richiama il quadrante nero
    }

    /// Dettagli della riga nella Custom Playlist (ora in una riga sotto i controlli), come nell'elenco: numero, «Metà», traguardo, «km N», km di partenza, tempo progressivo.
    private func customChips(_ c: CustomPlayInfo, elapsed: Double) -> some View {
        // Colonne a larghezza fissa, allineate a destra come le icone di stato: restano ferme da un brano all'altro.
        HStack(spacing: 4) {
            Group {
                if c.isMid {
                    Text(t("custom_mid_badge"))
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.orange)
                        .padding(.horizontal, 6).frame(height: 16)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                }
            }.frame(width: 40, alignment: .trailing)
            Group {
                if c.finish {
                    Image(systemName: "flag.checkered").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.green)
                }
            }.frame(width: 20, alignment: .center)
            Group {
                if let first = c.crossings.first, let last = c.crossings.last {
                    Text(first == last ? "\(c.unit) \(first)" : "\(c.unit) \(first)–\(last)")
                        .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Color.teal)
                        .padding(.horizontal, 6).frame(height: 16)
                        .background(Color.teal.opacity(0.18), in: Capsule())
                }
            }.frame(width: 62, alignment: .trailing)
            Group {
                if let km = c.liveKm(elapsed: elapsed) ?? c.kmStart, !km.isEmpty {
                    Text(km.contains(c.unit) || km == "—" ? km : km + " " + c.unit)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.frame(width: 52, alignment: .trailing)
            Group {
                if let r = c.liveRolling(elapsed: elapsed) ?? c.rolling {
                    Text(r).font(.caption.monospacedDigit()).foregroundStyle(AppSettings.shared.selectionSolidColor)
                }
            }.frame(width: 52, alignment: .trailing)
        }
        .lineLimit(1)
        .fixedSize()
        .help(c.help.isEmpty ? t("custom_live_forecast_help") : c.help + "\n" + t("custom_live_forecast_help"))
    }

    /// Icona playlist + nome (cliccabile): apre il balloon con i brani già riprodotti, quello in
    /// riproduzione e quelli da riprodurre.
    private func playlistButton(_ name: String) -> some View {
        Button { showQueue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: playlistIcon)
                Text(name).lineLimit(1).truncationMode(.tail)
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .help(t("tooltip_player_queue"))
        .popover(isPresented: $showQueue, arrowEdge: .bottom) { queuePopover(name) }
    }

    private func queuePopover(_ name: String) -> some View {
        ScrollViewReader { proxy in
            List {
                if queuePosition > 0 {
                    Section(t("queue_played")) {
                        ForEach(0..<min(queuePosition, queue.count), id: \.self) { i in
                            queueRow(i, icon: "checkmark.circle", dimmed: true)
                        }
                    }
                }
                if queue.indices.contains(queuePosition) {
                    Section(t("queue_now")) {
                        queueRow(queuePosition, icon: "speaker.wave.2.fill", dimmed: false, current: true)
                            .id(queuePosition)
                    }
                }
                if queuePosition + 1 < queue.count {
                    Section(t("queue_next")) {
                        ForEach((queuePosition + 1)..<queue.count, id: \.self) { i in
                            queueRow(i, icon: "circle", dimmed: false)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .onAppear { proxy.scrollTo(queuePosition, anchor: .center) }
        }
        .frame(width: 340, height: 380)
    }

    private func queueRow(_ index: Int, icon: String, dimmed: Bool, current: Bool = false) -> some View {
        let track = queue[index]
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(current ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).fontWeight(current ? .semibold : .regular).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .opacity(dimmed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !current { onJump(index) } }
    }

    /// Volume (icona altoparlante + cursore) e pulsante AirPlay per scegliere l'uscita audio.
    private var volumeControl: some View {
        HStack(spacing: 6) {
            // Mute: un click azzera il volume (ricordando il livello), un altro click lo ripristina.
            Button {
                if player.volume > 0 {
                    volumeBeforeMute = player.volume
                    player.volume = 0
                } else {
                    player.volume = volumeBeforeMute > 0 ? volumeBeforeMute : 0.5
                }
            } label: {
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t("tooltip_player_mute"))
            Slider(value: Binding(
                get: { Double(player.volume) },
                set: { player.volume = Float($0) }
            ), in: 0...1)
            .controlSize(.small)
            .frame(minWidth: 50, maxWidth: 130)   // si accorcia con la finestra stretta
            .help(t("tooltip_player_volume"))

            // Icona dell'uscita in uso: AirPods (icona del modello), cuffie, altoparlante AirPlay.
            // Nulla con l'uscita normale del Mac (altoparlanti interni, monitor...).
            if player.isExternalPlayback {
                Image(systemName: "airplayaudio")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .help(t("tooltip_player_airplay"))
            } else if let symbol = route.kind.symbol {
                // Apple TV, HomePod, altoparlanti: icona a sinistra del nome del dispositivo.
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if route.kind.showsDeviceName, !route.name.isEmpty {
                        Text(route.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 110, alignment: .leading)
                    }
                }
                .help(t("tooltip_player_output", route.name))
            }

            AirPlayButton(player: player.routePlayer)
                .frame(width: 22, height: 22)
                .help(t("tooltip_player_airplay"))
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "music.note")
                    .font(.system(size: height * 0.35))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Formato "m:ss" (o "h:mm:ss"), sempre presente anche a 0 — a differenza di `formatDuration`
    /// (pensato per le righe dei brani, dove 0/ignoto deve restare vuoto) qui serve sempre un
    /// tempo da mostrare accanto alla barra di avanzamento.
    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// Pulsante di sistema per scegliere l'uscita audio (AirPlay, Bluetooth, altoparlanti…).
/// Legato all'`AVPlayer` della riproduzione (`player`): senza, la scelta di un dispositivo AirPlay si attiva
/// ma l'audio continua a uscire dal Mac.
struct AirPlayButton: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        v.player = player
        return v
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) { nsView.player = player }
}


/// Controlla l'uscita audio predefinita del Mac (quella su cui suona il player) e ne ricava il
/// tipo: AirPods (modelli), cuffie (Bluetooth o jack) o altoparlante AirPlay. Aggiorna ogni secondo
/// e subito quando cambia l'uscita predefinita (anche il jack cuffie cambia solo la "sorgente dati"
/// dello stesso dispositivo, quindi non basta ascoltare il cambio di dispositivo).
@MainActor
final class AudioRouteMonitor: ObservableObject {
    enum Kind: Equatable {
        case airPods, airPodsPro, airPodsMax, headphones, airPlay, appleTV, homePod, homePodMini, speaker, other

        /// Nome dell'SF Symbol; nil se non va mostrata nessuna icona.
        var symbol: String? {
            switch self {
            case .airPods: return "airpods"
            case .airPodsPro: return "airpodspro"
            case .airPodsMax: return "airpodsmax"
            case .headphones: return "headphones"
            case .airPlay: return "airplayaudio"
            case .appleTV: return "appletv.fill"
            case .homePod: return "homepod.fill"
            case .homePodMini: return "homepodmini.fill"
            case .speaker: return "hifispeaker.fill"   // altoparlante Bluetooth o AirPlay non riconosciuto
            case .other: return nil
            }
        }

        /// Vero per le uscite di tipo altoparlante/Apple TV, per le quali accanto all'icona si mostra il nome del dispositivo.
        var showsDeviceName: Bool {
            switch self {
            case .appleTV, .homePod, .homePodMini, .speaker: return true
            default: return false
            }
        }
    }

    @Published private(set) var kind: Kind = .other
    @Published private(set) var name = ""
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    private func refresh() {
        let (newKind, newName) = Self.currentOutput()
        if newKind != kind { kind = newKind }
        if newName != name { name = newName }
    }

    private static func currentOutput() -> (Kind, String) {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return (.other, "") }

        // Nome del dispositivo
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        let nameStatus = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, $0)
        }
        let deviceName = nameStatus == noErr ? (name as String) : ""
        let lower = deviceName.lowercased()

        // Tipo di collegamento (Bluetooth, AirPlay, USB, interno…)
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transport)

        if lower.contains("airpods max") { return (.airPodsMax, deviceName) }
        if lower.contains("airpods pro") { return (.airPodsPro, deviceName) }
        if lower.contains("airpods") { return (.airPods, deviceName) }
        if transport == kAudioDeviceTransportTypeAirPlay {
            // Dispositivi Apple riconosciuti dal nome; qualsiasi altro dispositivo AirPlay ha l'icona dell'altoparlante.
            if lower.contains("apple tv") { return (.appleTV, deviceName) }
            if lower.contains("homepod mini") { return (.homePodMini, deviceName) }
            if lower.contains("homepod") { return (.homePod, deviceName) }
            return (.speaker, deviceName)
        }
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            // Altoparlanti Bluetooth riconosciuti da parole tipiche del nome; il resto resta «cuffie».
            let speakerWords = ["speaker", "altoparlante", "soundbar", "boom", "soundlink", "jbl", "sonos", "marshall", "echo"]
            if speakerWords.contains(where: { lower.contains($0) }) { return (.speaker, deviceName) }
            return (.headphones, deviceName)
        }

        // Altoparlanti interni con le cuffie nel jack: la sorgente dati attiva è "hdpn" (Headphones).
        var source: UInt32 = 0
        var sourceSize = UInt32(MemoryLayout<UInt32>.size)
        var sourceAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                       mScope: kAudioObjectPropertyScopeOutput,
                                                       mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(deviceID, &sourceAddress, 0, nil, &sourceSize, &source) == noErr,
           source == 0x6864706E {   // 'hdpn'
            return (.headphones, deviceName)
        }
        if lower.contains("headphone") || lower.contains("headset") || lower.contains("cuffie") {
            return (.headphones, deviceName)
        }
        return (.other, deviceName)
    }
}


/// Percorso del runner (Custom Playlist con PacePro): «0» a sinistra, km totali a destra, barra non modificabile e, al posto del
/// cursore, la figura del runner che corre (saltella mentre il brano suona, ferma in pausa).
struct RunnerProgressLine: View {
    let fraction: Double
    let isPlaying: Bool
    let endText: String
    private let runnerSize: CGFloat = 13   // 2.5.1: altezza del glifo = altezza del triangolo Play (misurata dallo screenshot: Play 27 px, runner a 18 pt 38 px → 13 pt)

    /// Di quanto l'intero percorso (barra, runner, km finali) è spostato in basso rispetto alla composizione precedente, senza cambiarne
    /// posizioni relative né centrature.
    private let lowering: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let x = max(0, min(1, fraction)) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
                    Capsule().fill(Self.runnerOutline).frame(width: x, height: 4)
                    runner.position(x: min(max(runnerSize / 2, x), w - runnerSize / 2), y: geo.size.height / 2 - 1)
                }
                .frame(height: geo.size.height)
            }
            .frame(height: 16)
            Text(endText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .offset(y: lowering)
    }

    /// Verde del simbolo `figure.run` di SF Symbols (campionato dallo screenshot di Riccardo, 15/11): richiama il runner di Apple.
    private static let runnerGreen = Color(red: 98/255, green: 196/255, blue: 81/255)

    /// Ombra: stessa icona, 1 pt più grande, in verde scuro e spostata di 1 pt in basso e a destra, dietro a quella verde (due simboli sovrapposti).
    private static let runnerOutline = Color(red: 30/255, green: 100/255, blue: 28/255)

    /// Il runner non si anima (il saltello era eccessivo): avanza solo lungo il percorso.
    private var runner: some View {
        ZStack {
            Image(systemName: "figure.run")
                .font(.system(size: runnerSize, weight: .black))
                .foregroundStyle(Self.runnerOutline)
                .offset(x: 0.75, y: 0.75)   // ombra: 0,75 pt in basso e a destra
            Image(systemName: "figure.run")
                .font(.system(size: runnerSize, weight: .semibold))
                .foregroundStyle(Self.runnerGreen)
        }
    }
}
