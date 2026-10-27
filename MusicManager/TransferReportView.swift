import SwiftUI
import AppKit

// MARK: - Modello

struct TransferItemResult: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case processing
        case transferred
        case skipped
        case error
    }

    let id: String
    let title: String
    let artist: String
    var status: Status = .pending
    /// Nota aggiuntiva mostrata sotto il brano (es. "Artwork aggiornato", oppure il motivo per cui
    /// una copertina confermata non è stata applicata). `noteIsWarning` la colora di arancione.
    var note: String?
    var noteIsWarning = false
}

/// Stato della finestra di trasferimento: un titolo (es. nome della playlist) e l'elenco dei
/// brani con l'esito di ciascuno. È un valore (non un ObservableObject) perché AppViewModel lo
/// tiene in una @Published property e lo riassegna per intero a ogni aggiornamento: più semplice
/// da ragionare, e la lista di brani è sempre di dimensioni contenute.
struct TransferReport: Identifiable {
    /// Resta lo stesso per tutta la serie di playlist inviate insieme: la finestra non si richiude e riapre a ogni playlist.
    var id = UUID()
    let title: String
    var items: [TransferItemResult]
    /// Nome della playlist in corso (nil per l'invio di brani sciolti).
    var playlistName: String? = nil
    /// true se la finestra fa parte di un invio di più playlist: mostra l'elenco delle playlist con il loro esito.
    var isMultiple = false
    /// Brani di tutte le playlist dell'invio multiplo, noto fin dall'inizio (nil = si somma man mano).
    var plannedTotal: Int? = nil
    /// true se, oltre alle playlist, l'invio comprende brani sciolti (scelti in altre schede): cambia la dicitura dei totali.
    var includesOtherSongs = false
    /// Playlist già concluse nello stesso invio multiplo, nell'ordine di invio.
    var history: [TransferPlaylistSummary] = []

    /// Riepilogo della playlist che questo rapporto descrive (usato quando si passa alla successiva).
    var summary: TransferPlaylistSummary? {
        guard let name = playlistName else { return nil }
        return TransferPlaylistSummary(name: name, copied: transferredCount, skipped: skippedCount, errors: errorCount)
    }

    var transferredCount: Int { items.filter { $0.status == .transferred }.count }
    var skippedCount: Int { items.filter { $0.status == .skipped }.count }
    var errorCount: Int { items.filter { $0.status == .error }.count }

    /// Totali dell'intero invio: per più playlist sommano quelle concluse e quella in corso; per un invio singolo coincidono con i conteggi sopra.
    var totalSelected: Int { plannedTotal ?? (items.count + history.reduce(0) { $0 + $1.copied + $1.skipped + $1.errors }) }
    var totalTransferred: Int { transferredCount + history.reduce(0) { $0 + $1.copied } }
    var totalSkipped: Int { skippedCount + history.reduce(0) { $0 + $1.skipped } }
    var totalErrors: Int { errorCount + history.reduce(0) { $0 + $1.errors } }
}

/// Esito di una playlist dentro un invio multiplo.
struct TransferPlaylistSummary: Identifiable {
    enum Outcome { case transferring, transferred, partial, check }
    let id = UUID()
    let name: String
    let copied: Int
    let skipped: Int
    let errors: Int

    /// Nessun errore → trasferita (anche con brani già presenti); errori ma qualcosa è arrivato → parziale; solo errori → da controllare.
    var outcome: Outcome {
        if errors == 0 { return .transferred }
        return (copied + skipped) > 0 ? .partial : .check
    }
}

// MARK: - Vista

struct TransferReportView: View {
    let report: TransferReport
    let isBusy: Bool
    /// Interruzione richiesta (l'invio finisce il file in corso e si ferma) / invio concluso perché interrotto.
    var stopRequested = false
    var wasStopped = false
    /// Scrittura del file playlist in corso: «Cancel» disattivato (non c'è più nulla da fermare).
    var stopLocked = false
    /// «Cancel» → conferma → ferma l'invio dopo il file in corso.
    var onStop: (() -> Void)? = nil
    let onClose: () -> Void
    @State private var confirmStop = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(report.title).font(.headline)
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
            }
            .padding()
            .background(infoZoneBackground)   // fascia alta: informativa, vetro più leggero

            Divider()

            if report.isMultiple { playlistsOverview }

            ScrollViewReader { proxy in
                List(report.items) { item in
                    row(item).id(item.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)   // lo sfondo di vetro del foglio si vede anche dietro l'elenco
                .onChange(of: report.items) { _, items in
                    // Fa scorrere la lista per tenere visibile il brano che si sta elaborando ora.
                    if let current = items.first(where: { $0.status == .processing }) {
                        withAnimation { proxy.scrollTo(current.id, anchor: .center) }
                    }
                }
            }

            Divider()

            summary
                .background(infoZoneBackground)   // fascia bassa: informativa, vetro più leggero
        }
        .modifier(SheetFrame(width: 560, height: report.isMultiple ? 660 : 520, fill: true))
        // Pannello di vetro (vedi `GlassModalPresenter`): vetro e angoli li dà il contenitore. Per tornare allo sheet:
        // `TransferReportView.swift.prima-report-vetro` e `ContentView.swift.prima-report-vetro`.
        .buttonStyle(.flatRoomy)
        // Conferma dell'interruzione: scheda sopra il pannello (un `.alert` in un pannello senza bordi non è affidabile).
        // L'invio prosegue mentre si decide: «Confirm» lo ferma dopo il file in corso, «Continue» lo lascia andare.
        .overlay {
            if confirmStop {
                ZStack {
                    Color.black.opacity(0.35)
                    VStack(spacing: 14) {
                        Text(t("alert_stop_send_title")).font(.headline).multilineTextAlignment(.center)
                        Text(t("alert_stop_send_message")).font(.callout).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button { confirmStop = false } label: { Text(t("button_continue")).frame(minWidth: 80) }
                                .buttonStyle(.flatRoomy)
                                .keyboardShortcut(.cancelAction)
                            Button(role: .destructive) { confirmStop = false; onStop?() } label: { Text(t("button_confirm")).frame(minWidth: 80) }
                                .buttonStyle(.flatProminentRoomy)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 420)
                    .background(RoundedRectangle(cornerRadius: 18).fill(.regularMaterial))
                }
            }
        }
    }

    /// Sfondo delle fasce alta e bassa: una velatura leggera sul vetro del pannello, così titolo e riepilogo restano distinti dall'elenco.
    private var infoZoneBackground: some View {
        Color.secondary.opacity(0.12)
    }

    /// Elenco delle playlist dell'invio multiplo: quelle concluse con il loro esito, poi quella in corso («Transferring»).
    /// Altezza di una riga dell'elenco delle playlist (nome + dettaglio + margini).
    private static let overviewRowHeight: CGFloat = 41

    @Environment(\.windowHeight) private var windowHeight

    private var playlistsOverview: some View {
        let current = report.summary
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(report.history) { entry in
                            playlistRow(entry, outcome: entry.outcome)
                            Divider()   // filo tra una playlist e la successiva, come tra i brani
                        }
                        if let current {
                            playlistRow(current, outcome: isBusy ? .transferring : current.outcome).id("current-playlist")
                        }
                    }
                    .padding(.horizontal)
                }
                // Fino a 4 righe complete (con il dettaglio) senza scorrere; oltre la quarta l'elenco scorre.
                // (n righe + n−1 fili da 1 pt)
                .frame(height: {
                    // Con la finestra bassa solo 2 righe, cosi resta spazio per l'elenco dei brani e per i pulsanti.
                    // Nel pannello di vetro l'ambiente non porta l'altezza: si usa quella della finestra principale.
                    let height = windowHeight > 0 ? windowHeight : MainWindowMetrics.shared.height
                    let rows = CGFloat(min(report.history.count + 1, height > 0 && height < 600 ? 2 : 4))
                    return rows * Self.overviewRowHeight + (rows - 1) + 2
                }())
                // Sfondo grigio al 20%: stacca l'elenco delle playlist da quello dei brani sotto.
                .background(Color.gray.opacity(0.2))
                .onAppear { proxy.scrollTo("current-playlist", anchor: .bottom) }
                .onChange(of: report.history.count) { _, _ in
                    withAnimation { proxy.scrollTo("current-playlist", anchor: .bottom) }
                }
                // Alla fine l'ultima playlist cambia da «Transferring» all'esito: la riga resta in vista, intera.
                .onChange(of: isBusy) { _, _ in
                    withAnimation { proxy.scrollTo("current-playlist", anchor: .bottom) }
                }
            }
            Divider()
        }
    }

    private func playlistRow(_ entry: TransferPlaylistSummary, outcome: TransferPlaylistSummary.Outcome) -> some View {
        let (text, color): (String, Color) = {
            switch outcome {
            case .transferring: return (t("transfer_playlist_transferring"), .accentColor)
            case .transferred: return (t("transfer_status_transferred"), .green)
            case .partial: return (t("transfer_playlist_partial"), .orange)
            case .check: return (t("transfer_playlist_check"), .red)
            }
        }()
        return HStack {
            if outcome == .transferring { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                if outcome != .transferring {
                    Text(t("transfer_playlist_detail", entry.copied, entry.skipped, entry.errors))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(text)
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        }
        .padding(.vertical, 5)
        .frame(height: Self.overviewRowHeight)   // tutte le righe della stessa altezza: quattro righe complete, senza tagli
    }

    private func row(_ item: TransferItemResult) -> some View {
        HStack {
            if item.status == .processing {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let note = item.note {
                    Text(note).font(.caption2)
                        .foregroundStyle(item.noteIsWarning ? Color.orange : Color.green)
                        .lineLimit(2)
                }
            }
            Spacer()
            statusBadge(item.status)
        }
        .listRowBackground(item.status == .processing ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func statusBadge(_ status: TransferItemResult.Status) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .pending: return (t("transfer_status_pending"), .secondary)
            case .processing: return (t("transfer_status_processing"), .accentColor)
            case .transferred: return (t("transfer_status_transferred"), .green)
            case .skipped: return (t("transfer_status_skipped"), .orange)
            case .error: return (t("transfer_status_error"), .red)
            }
        }()
        return Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if report.isMultiple {
                Text(report.includesOtherSongs ? t("transfer_summary_total_header_mixed") : t("transfer_summary_total_header"))
                    .font(.caption.bold()).foregroundStyle(.secondary)
            }
            // Finestra bassa: i quattro totali su due colonne, così all'elenco dei brani resta più spazio.
            let selectedLabel = report.isMultiple && !report.includesOtherSongs ? t("transfer_summary_selected_playlists") : t("transfer_summary_selected")
            if isCompactHeight {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                    GridRow {
                        summaryRow(selectedLabel, report.totalSelected)
                        summaryRow(t("transfer_summary_skipped"), report.totalSkipped)
                    }
                    GridRow {
                        summaryRow(t("transfer_summary_transferred"), report.totalTransferred)
                        summaryRow(t("transfer_summary_error"), report.totalErrors)
                    }
                }
            } else {
                summaryRow(selectedLabel, report.totalSelected)
                summaryRow(t("transfer_summary_transferred"), report.totalTransferred)
                summaryRow(t("transfer_summary_skipped"), report.totalSkipped)
                summaryRow(t("transfer_summary_error"), report.totalErrors)
            }

            // Interruzione dell'invio: in corso («dopo il file in corso») o già avvenuta (cosa non è stato inviato).
            if isBusy && stopRequested {
                Label(t("transfer_stopping"), systemImage: "hand.raised.fill")
                    .font(.caption.bold()).foregroundStyle(.orange)
            } else if wasStopped && !isBusy {
                Text(t("transfer_stopped_note"))
                    .font(.caption.bold()).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Durante l'invio «Cancel» prende il posto di «Close» (che si riattiva a invio concluso).
            HStack {
                Spacer()
                if isBusy {
                    Button(role: .destructive) { confirmStop = true } label: {
                        Label(t("button_cancel"), systemImage: "xmark.circle").frame(width: mainBarButtonWidth())
                    }
                    .disabled(stopRequested || stopLocked || onStop == nil)
                } else {
                    // Stessa misura di «Cancel» e dei pulsanti dei pannelli principali: nella stessa posizione non cambia nulla.
                    Button(action: onClose) { Text(t("button_close")).frame(width: mainBarButtonWidth()) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
        .padding()
    }

    /// Finestra principale bassa (stessa soglia delle righe dell'elenco delle playlist).
    private var isCompactHeight: Bool {
        let height = windowHeight > 0 ? windowHeight : MainWindowMetrics.shared.height
        return height > 0 && height < 600
    }

    private func summaryRow(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)").bold()
        }
        .font(.subheadline)
    }
}


/// Rende trasparente la finestra dello sheet (di serie è opaca): senza, il vetro non ha nulla da sfumare.
/// Per tornare indietro: `TransferReportView.swift.prima-finestra-trasparente`.
struct TransparentSheetWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { Self.apply(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(v.window) }
    }
    private static func apply(_ w: NSWindow?) {
        guard let w else { return }
        w.isOpaque = false
        w.backgroundColor = .clear
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
