import SwiftUI
import AppKit

/// Barra grafica della memoria interna del dispositivo, con i segmenti impilati in proporzione alla capacità totale,
/// con i colori dell'archiviazione di macOS:
/// - grigio chiaro (sfondo): spazio libero;
/// - grigio molto scuro («System», 2.1 Beta 3): sistema e firmware del dispositivo, stimato come lo spazio occupato
///   non classificabile (capacità − libero − tutte le altre categorie);
/// - grigio («Data»): cartella "Garmin", mappe escluse;
/// - viola («Maps»): mappe (file .gma/.img) dentro la cartella Garmin;
/// - blu («Services»): brani dei servizi di streaming, somma di MediaCacheSize di GarminDevice.xml;
/// - verde («Music»): cartella "Music";
/// - righe diagonali (verdi, rosse se non c'è spazio): brani selezionati da inviare.
struct StorageBarView: View {
    let total: UInt64
    let garmin: UInt64
    let maps: UInt64
    /// Servizi di streaming (somma, senza distinguerli): 0 = nessuno, il segmento non compare.
    var services: UInt64 = 0
    let music: UInt64
    let free: UInt64
    /// Spazio dei brani selezionati da inviare (0 = nessuno): segmento a strisce dopo il verde di Music.
    var pending: UInt64 = 0
    var isLoading: Bool = false
    /// Dispositivo senza musica: un solo segmento con lo spazio totale occupato, nel rosso pallido di «Music not supported».
    var unsupported = false
    private let unsupportedColor = Color(red: 0.937, green: 0.604, blue: 0.604)
    private var usedBytes: UInt64 { total > free ? total - free : 0 }
    /// Spazio occupato che non rientra in Data, Maps, Services e Music: sistema e firmware del dispositivo (stima),
    /// più i file che non sappiamo classificare. Così la barra è sempre coerente con lo spazio libero reale
    /// (senza un vuoto che sembrerebbe libero).
    private var systemBytes: UInt64 {
        guard !isLoading, !unsupported, total > 0 else { return 0 }
        let known = garmin + maps + services + music
        return usedBytes > known ? usedBytes - known : 0
    }
    /// Tutto lo spazio occupato rappresentato nella barra, esclusi i brani da inviare.
    private var usedAll: UInt64 { systemBytes + garmin + maps + services + music }

    private let barHeight: CGFloat = 16
    @State private var barWidth: CGFloat = 0
    /// Suggerimento mostrato al passaggio del mouse: testo e posizione orizzontale del cursore nella barra.
    @State private var hoverTip: (text: String, x: CGFloat)?

    /// Vero se i brani da inviare non stanno nello spazio libero: il segmento diventa rosso.
    private var exceedsFree: Bool { pending > free }
    /// Rosso se i brani non stanno; arancione se stanno ma lo spazio libero che resterebbe è troppo piccolo per mostrarne il
    /// valore nella barra (si sta raggiungendo il limite); altrimenti verde come Music.
    private var pendingColor: Color {
        if exceedsFree { return .red }
        if pending > 0, !unsupported, !freeLabelFits(width: barWidth) { return .orange }
        return Self.musicColor
    }
    /// Colori delle categorie, ripresi dall'archiviazione di macOS (Dati di sistema, Messaggi, Foto) e sfondo chiaro dello libero.
    static let garminColor = Color(red: 0.47, green: 0.47, blue: 0.47)
    /// Grigio scuro del segmento «System»: più scuro di «Data» e, in tema scuro, anche dello sfondo del libero.
    static let systemColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.33, alpha: 1)
    })
    static let servicesColor = Color(red: 0.33, green: 0.52, blue: 0.90)
    /// Viola (2.1 Beta 3): l'arancione è riservato all'avviso «spazio quasi finito» dei brani da inviare.
    static let mapsColor = Color(red: 0.66, green: 0.42, blue: 0.86)
    static let musicColor = Color(red: 0.42, green: 0.75, blue: 0.35)
    /// Colore dei testi grigi del pannello Device (legenda, conteggi, etichette): in tema scuro più chiaro del grigio
    /// secondario di sistema, che sullo sfondo scuro risultava poco leggibile; in tema chiaro resta quello di sistema.
    static let textColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.80, alpha: 1) : NSColor.secondaryLabelColor
    })
    static let freeColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.30, alpha: 1) : NSColor(white: 0.86, alpha: 1)
    })

    /// Spazio libero mostrato nella barra: con brani selezionati da inviare è quello che resterebbe dopo l'invio (mai sotto zero).
    /// La capacità totale sta nella riga «Storage Capacity» del pannello.
    private var remainingFree: UInt64 {
        unsupported || pending == 0 ? free : (free > pending ? free - pending : 0)
    }

    /// Zona libera della barra (dopo lo spazio occupato e i brani da inviare): posizione e larghezza per la scritta al centro.
    private func freeRegion(width: CGFloat) -> (x: CGFloat, w: CGFloat) {
        guard total > 0, width > 0 else { return (0, 0) }
        let usedPart = unsupported ? usedBytes : usedAll
        let room = total > usedPart ? total - usedPart : 0
        let pend = unsupported ? 0 : min(pending, room)
        let fraction = min(1, Double(usedPart + pend) / Double(total))
        let x = width * CGFloat(fraction)
        return (x, max(0, width - x))
    }

    /// Larghezza che serve alla scritta del libero (stesso carattere di «Storage Capacity», più un po' d'aria).
    private var freeLabelWidth: CGFloat {
        let size = (formatted(remainingFree) as NSString).size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)])
        return ceil(size.width) + 12
    }

    /// Vero se il valore del libero sta nella zona libera. Con la larghezza non ancora nota (0) si considera che stia,
    /// per non far lampeggiare l'avviso arancione al primo disegno.
    private func freeLabelFits(width: CGFloat) -> Bool {
        guard !isLoading, total > 0, width > 0 else { return true }
        return freeRegion(width: width).w >= freeLabelWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Riga vuota al posto della vecchia scritta «xx GB free of yy GB»: tiene il posto alla scritta «+ n GB» dei brani selezionati.
            Color.clear.frame(height: 12)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Self.freeColor)   // spazio completo: il libero è lo sfondo chiaro

                    HStack(spacing: 0) {
                        if unsupported {
                            segment(color: unsupportedColor, value: usedBytes, totalWidth: geo.size.width, tip: t("storage_tip", t("storage_legend_used"), formatted(usedBytes)))
                        } else {
                            segment(color: Self.systemColor, value: systemBytes, totalWidth: geo.size.width,
                                    tip: t("storage_tip", t("storage_legend_system"), formatted(systemBytes)))
                            segment(color: Self.garminColor, value: garmin, totalWidth: geo.size.width, separated: systemBytes > 0,
                                    tip: t("storage_tip", t("storage_legend_data"), formatted(garmin)))
                            segment(color: Self.mapsColor, value: maps, totalWidth: geo.size.width, separated: systemBytes + garmin > 0,
                                    tip: t("storage_tip", t("storage_legend_maps"), formatted(maps)))
                            segment(color: Self.servicesColor, value: services, totalWidth: geo.size.width, separated: systemBytes + garmin + maps > 0,
                                    tip: t("storage_tip", t("storage_legend_services"), formatted(services)))
                            segment(color: Self.musicColor, value: music, totalWidth: geo.size.width, separated: systemBytes + garmin + maps + services > 0,
                                    tip: t("storage_tip", t("storage_legend_music"), formatted(music)))
                        }
                        if pending > 0 && !unsupported {
                            let used = usedAll
                            let room = total > used ? total - used : 0
                            // Il segmento non esce dalla barra: se supera lo spazio, copre tutto il libero.
                            DiagonalStripes(color: pendingColor)
                                .frame(width: geo.size.width * CGFloat(total > 0 ? Double(min(pending, room)) / Double(total) : 0))
                                .overlay(alignment: .leading) { if used > 0 { separator } }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    // Spazio libero al centro della zona libera della barra; se non ci sta, il valore si toglie.
                    if !isLoading, freeLabelFits(width: geo.size.width), geo.size.width > 0 {
                        let region = freeRegion(width: geo.size.width)
                        Text(formatted(remainingFree))
                            .font(.caption)   // lo stesso carattere del valore di «Storage Capacity»
                            .foregroundStyle(Color.primary)
                            .lineLimit(1).fixedSize()
                            .frame(width: region.w, alignment: .center)
                            .offset(x: region.x)
                            .allowsHitTesting(false)
                    }

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                // Suggerimento immediato (il `.help` nativo di macOS compare dopo oltre un secondo): si calcola il segmento
                // sotto il cursore e si mostra un piccolo balloon sopra la barra.
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverTip = tip(atX: point.x, width: geo.size.width)
                    case .ended: hoverTip = nil
                    }
                }
            }
            .frame(height: barHeight)
            .overlay(alignment: .topLeading) { hoverBalloon }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
            .overlay(alignment: .topLeading) { pendingTick }
            .overlay(alignment: .topLeading) { pendingLabel }

            legend
        }
    }

    /// Testo del suggerimento per il punto `x` della barra (nome e dimensione del segmento sotto il cursore).
    private func tip(atX x: CGFloat, width: CGFloat) -> (text: String, x: CGFloat)? {
        guard !isLoading, total > 0, width > 0 else { return nil }
        var parts: [(label: String, bytes: UInt64)] = []
        if unsupported {
            parts.append((t("storage_legend_used"), usedBytes))
        } else {
            parts = [(t("storage_legend_system"), systemBytes), (t("storage_legend_data"), garmin), (t("storage_legend_maps"), maps),
                     (t("storage_legend_services"), services), (t("storage_legend_music"), music)]
        }
        var start: CGFloat = 0
        for part in parts where part.bytes > 0 {
            let w = width * CGFloat(Double(part.bytes) / Double(total))
            if x >= start && x < start + w { return (t("storage_tip", part.label, formatted(part.bytes)), x) }
            start += w
        }
        if pending > 0 && !unsupported {
            let room = total > usedAll ? total - usedAll : 0
            let w = width * CGFloat(Double(min(pending, room)) / Double(total))
            // Sulle righe dei brani selezionati nessun suggerimento (il testo era troppo lungo): la scritta «+ n GB» basta.
            if x >= start && x < start + w { return nil }
        }
        return unsupported ? nil : (t("storage_tip", t("storage_legend_free"), formatted(free)), x)
    }

    /// Balloon del suggerimento, SOTTO la barra (sopra c'è la scritta «+ n GB» dei brani selezionati) e vicino al cursore.
    @ViewBuilder
    private var hoverBalloon: some View {
        if let tip = hoverTip {
            Text(tip.text)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .offset(x: max(0, min(tip.x - 40, max(0, barWidth - 170))), y: -28)
                .allowsHitTesting(false)
                .transition(.identity)
        }
    }

    /// Posizione (x) in cui inizia il segmento a strisce, cioè la fine del verde di Music.
    private var pendingStartX: CGFloat {
        guard total > 0 else { return 0 }
        return barWidth * CGFloat(Double(min(usedAll, total)) / Double(total))
    }

    /// Posizione (x) in cui finisce il segmento a strisce (come è disegnato: non esce dalla barra).
    private var pendingEndX: CGFloat {
        guard total > 0 else { return 0 }
        let used = usedAll
        let room = total > used ? total - used : 0
        let w = barWidth * CGFloat(Double(min(pending, room)) / Double(total))
        return min(barWidth, pendingStartX + w)
    }

    /// Lineetta sottile alla fine del segmento, a collegare la barra alla scritta SOPRA la barra
    /// (2.0.1: prima scendeva sulla legenda sotto la barra e si sovrapponeva alle didascalie).
    @ViewBuilder
    private var pendingTick: some View {
        if pending > 0 && !unsupported {
            Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 1, height: barHeight + 8)
                .offset(x: max(0, pendingEndX - 1), y: -8)
                .allowsHitTesting(false)
        }
    }

    /// "+ 4,02 GB" sopra la barra, a destra della lineetta che chiude il segmento a righe (rosso se non c'è spazio).
    @ViewBuilder
    private var pendingLabel: some View {
        if pending > 0 && !unsupported {
            Text("+ " + formatted(pending))
                .font(.caption2)
                .foregroundStyle(exceedsFree ? Color.red : Self.textColor)
                .lineLimit(1).fixedSize()
                // Il bordo sinistro della scritta parte dalla lineetta, alla fine delle strisce, e prosegue a destra
                // (se le strisce arrivano quasi in fondo alla barra la scritta si ferma ~70 pt prima del bordo destro).
                .frame(width: max(barWidth, 70), alignment: .leading)
                .offset(x: max(0, min(pendingEndX + 4, barWidth - 70)), y: -18)
        }
    }

    /// `separated`: c'è qualcosa prima di questo segmento, quindi si disegna la linea di separazione sul suo bordo sinistro
    /// (nessuna linea in coda alla barra: compare solo davanti alle righe dei brani selezionati).
    /// `tip`: suggerimento al passaggio del mouse («Maps 21,91 GB»); le dimensioni non stanno più nella legenda.
    private func segment(color: Color, value: UInt64, totalWidth: CGFloat, separated: Bool = false, tip: String = "") -> some View {
        let fraction = total > 0 ? Double(value) / Double(total) : 0
        let width = max(0, totalWidth * CGFloat(fraction))
        return color.frame(width: width)
            .overlay(alignment: .leading) { if separated && width > 2 { separator } }
    }

    /// Linea di separazione tra i segmenti, del colore della finestra (come nell'archiviazione di macOS).
    private var separator: some View {
        Rectangle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 1)
    }

    private var legend: some View {
        HStack(alignment: .center, spacing: 10) {
            // Legenda dinamica, solo nomi (le dimensioni sono nel suggerimento sui segmenti): una voce compare solo
            // se la categoria ha uno spazio occupato (Music se c'è musica, Services se ci sono servizi, ecc.).
            if unsupported {
                legendItem(color: unsupportedColor, label: t("storage_legend_used"))
            } else {
                if isPresent(systemBytes) { legendItem(color: Self.systemColor, label: t("storage_legend_system"), help: t("storage_system_help")) }
                if isPresent(garmin) { legendItem(color: Self.garminColor, label: t("storage_legend_data"), help: t("storage_data_help")) }
                if isPresent(maps) { legendItem(color: Self.mapsColor, label: t("storage_legend_maps")) }
                if isPresent(services) { legendItem(color: Self.servicesColor, label: t("storage_legend_services"), help: t("storage_services_help")) }
                if isPresent(music) { legendItem(color: Self.musicColor, label: t("storage_legend_music")) }
            }
            // Ultima voce: lo spazio libero, il cui valore sta scritto al centro della zona libera della barra.
            if !isLoading && total > 0 { legendItem(color: Self.freeColor, label: t("storage_legend_free_short"), outlined: true) }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 14)   // altezza fissa anche a legenda vuota (caricamento): il pannello non si sposta
        .font(.caption2)
        .foregroundStyle(Self.textColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Una categoria compare in legenda solo se occupa almeno 1 MB: avanzi minuscoli (qualche file .gma di mappe già
    /// rimosse, una sola playlist in Music, le cache vuote dei servizi da 128 KB) non devono far comparire la voce.
    private func isPresent(_ bytes: UInt64) -> Bool { bytes >= 1_048_576 }

    /// Voce della legenda: quadratino colorato e nome (la dimensione si legge sul segmento, al passaggio del mouse).
    private func legendItem(color: Color, label: String, help: String? = nil, outlined: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                .overlay { if outlined { RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.25), lineWidth: 0.5) } }
            Text(label).lineLimit(1)
        }
        .help(help ?? "")
    }

    /// Spazio in GB (anche sotto 1 GB, es. «0,15 GB»), come «xx GB liberi su yy GB».
    private func formattedGB(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}


/// Strisce diagonali spesse (verdi o rosse) con un sottile filo del colore dello sfondo tra l'una e l'altra:
/// il segmento "da inviare" della barra dello spazio.
private struct DiagonalStripes: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(StorageBarView.freeColor))
            let period: CGFloat = 10      // passo delle strisce, misurato in orizzontale
            let stripe: CGFloat = 8       // parte colorata; i 2 pt restanti sono il filo grigio
            var x = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + stripe, y: size.height))
                path.addLine(to: CGPoint(x: x + stripe + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.closeSubpath()
                ctx.fill(path, with: .color(color))
                x += period
            }
        }
    }
}
