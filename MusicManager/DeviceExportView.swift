import SwiftUI

/// Finestra di riepilogo mostrata PRIMA di scrivere sul dispositivo: tutti i file (audio e
/// playlist) sono già pronti in locale in `~/Music/MusicManager/TEMP`, e per ogni brano si
/// vede subito se l'artwork è stato modificato. Solo con "Invia" si tocca il dispositivo.
struct DeviceExportView: View {
    /// Etichetta a destra di ogni brano: da dove viene la copertina (pallino pieno = scritta ora nel file inviato;
    /// cerchio barrato rosso = nessuna copertina).
    private func sourceLabel(_ key: String, color: Color, filled: Bool, symbol: String? = nil) -> some View {
        Label {
            Text(t(key))
        } icon: {
            Image(systemName: symbol ?? (filled ? "circle.fill" : "circle")).foregroundStyle(color)
                .frame(width: 16)   // stessa larghezza per tutte le icone: i testi partono dallo stesso punto
        }
        .font(filled ? .caption.bold() : .caption)
        .foregroundStyle(color)
        // Colonna di stato a larghezza fissa, allineata a sinistra: le icone stanno tutte sulla stessa verticale.
        .frame(width: 130, alignment: .leading)
        .help(t(helpKey(key)))
    }

    /// «Origine: n» per il riepilogo in testa alla finestra.
    private func countLabel(_ key: String, _ count: Int, color: Color, symbol: String) -> some View {
        Label {
            Text("\(t(key)): \(count)")
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(color)
        .help(t(helpKey(key)))
    }

    /// Spiegazione in un suggerimento (passando il mouse) di ogni origine della copertina.
    private func helpKey(_ key: String) -> String {
        switch key {
        case "export_artwork_apple": return "export_artwork_apple_help"
        case "export_artwork_online": return "export_artwork_online_help"
        case "export_artwork_garmin_cache": return "export_artwork_cache_help"
        case "export_artwork_file": return "export_artwork_file_help"
        case "export_artwork_none": return "export_artwork_none_help"
        default: return key
        }
    }

    let plan: DeviceExportPlan
    let onSend: () -> Void
    let onCancel: () -> Void

    /// Fascia alta e bassa: colore di finestra in più sopra il vetro del pannello, così restano più piene del centro (elenco).
    private var infoZone: some View {
        Color(nsColor: .windowBackgroundColor).opacity(0.45)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 12) {
            Text(t("export_dialog_title")).font(.title3).fontWeight(.bold)
            if let name = plan.playlistName {
                Text(t("export_playlist_label", name))
            }
            Text(t("export_dialog_summary", plan.items.count))
                .foregroundStyle(.secondary)
            // Conteggio per origine della copertina, con gli stessi colori delle righe; «No Cover» (mancanti) sempre
            // visibile, in rosso, anche quando è zero.
            HStack(spacing: 16) {
                countLabel("export_artwork_apple", plan.count(of: .apple), color: .blue, symbol: "circle.fill")
                if plan.count(of: .online) > 0 {
                    countLabel("export_artwork_online", plan.count(of: .online), color: .purple, symbol: "circle.fill")
                }
                countLabel("export_artwork_garmin_cache", plan.count(of: .garminCache), color: .teal, symbol: "circle.fill")
                countLabel("export_artwork_file", plan.count(of: .file), color: .green, symbol: "circle")
                countLabel("export_artwork_none", plan.count(of: .none),
                           color: plan.count(of: .none) > 0 ? .red : .secondary, symbol: "slash.circle")
                if plan.count(of: .deviceOnly) > 0 {
                    countLabel("export_device_only", plan.count(of: .deviceOnly), color: .secondary, symbol: "watch.analog")
                }
            }
          }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(infoZone)   // fascia alta: informativa, più corposa del centro

            // Elenco a scorrimento con filo esplicito tra le righe (un `List` metteva la linea solo sotto la colonna di
            // destra e sfasata): titolo e origine della copertina sono centrati rispetto alla riga.
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(plan.items) { item in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.artist + (item.album.isEmpty ? "" : " — " + item.album))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let problem = item.problem {
                                    Text(problem).font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            switch item.artworkSource {
                            case .apple:
                                sourceLabel("export_artwork_apple", color: .blue, filled: true)
                            case .online:
                                sourceLabel("export_artwork_online", color: .purple, filled: true)
                            case .garminCache:
                                sourceLabel("export_artwork_garmin_cache", color: .teal, filled: true)
                            case .file:
                                sourceLabel("export_artwork_file", color: .green, filled: false)
                            case .none:
                                sourceLabel("export_artwork_none", color: .red, filled: false, symbol: "slash.circle")
                            case .deviceOnly:
                                sourceLabel("export_device_only", color: .secondary, filled: false, symbol: "watch.analog")
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 12)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .padding(.horizontal, 20)

            HStack {
                Spacer()
                Button(t("button_cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(t("button_proceed"), action: onSend)
                    .buttonStyle(.flatProminentRoomy)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(infoZone)   // fascia bassa: informativa, più corposa del centro
        }
        // Pannello di vetro (`GlassModalPresenter`): 90 % dell'altezza della finestra principale, tolto il margine trasparente del vetro.
        // Per tornare allo sheet: `DeviceExportView.swift.prima-pannello` e `ContentView.swift.prima-pannello-invio`.
        .frame(width: 620, height: min(600, max(300, MainWindowMetrics.shared.height * 0.9 - 56)))
    }
}


/// Finestra di avanzamento delle eliminazioni sul dispositivo: nessun pulsante, si chiude da sola
/// a operazione conclusa (vedi `AppViewModel.deletionProgress`).
struct DeletionProgressView: View {
    let progress: DeletionProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(progress.title).font(.headline)
            if progress.total > 0 {
                ProgressView(value: Double(progress.current), total: Double(progress.total))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(progress.detail)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}
