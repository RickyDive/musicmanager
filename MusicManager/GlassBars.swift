import SwiftUI

extension View {
    /// Liquid Glass (macOS 26): un pannello di vetro in alto e uno in basso **sovrapposti** all'elenco,
    /// che occupa tutta l'altezza: all'apertura la prima riga sta subito sotto il pannello alto e
    /// l'ultima sopra quello basso (margini del contenuto = altezza dei pannelli, misurata), poi
    /// scorrendo le righe passano sotto il vetro e si fondono con l'interfaccia, come nelle app Apple.
    func glassBars<Top: View, Bottom: View>(
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) -> some View {
        modifier(GlassBarsModifier(topBar: top(), bottomBar: bottom()))
    }
}

/// Altezza dei due pannelli di vetro, passata alle liste dentro il contenuto.
struct GlassInsets: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}

private struct GlassInsetsKey: EnvironmentKey {
    static let defaultValue = GlassInsets()
}

/// Modalità compatta (finestra stretta, metà pannello < 720 pt): schede, selettori e pulsanti in basso mostrano solo l'icona.
private struct CompactPaneKey: EnvironmentKey {
    static let defaultValue = false
}

/// Altezza del contenuto della finestra principale (0 = non nota): i fogli (sheet) a misura fissa la usano per non diventare
/// più alti della finestra, cosi con la finestra al minimo i pulsanti in basso restano raggiungibili.
private struct WindowHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// Regola generale delle finestre di dialogo: alte il 90 % della finestra principale (minimo 300 pt).
/// Con `fill` la finestra occupa proprio il 90 %; senza, l'altezza «ideale» data, ma mai oltre il 90 %.
/// Vero dentro i pannelli modali di vetro (`GlassModalPresenter`).
private struct InGlassPanelKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var inGlassPanel: Bool {
        get { self[InGlassPanelKey.self] }
        set { self[InGlassPanelKey.self] = newValue }
    }
}

struct SheetFrame: ViewModifier {
    let width: CGFloat
    let height: CGFloat
    var fill = false
    @Environment(\.windowHeight) private var windowHeight
    @Environment(\.inGlassPanel) private var inGlassPanel
    func body(content: Content) -> some View {
        // Nei pannelli di vetro (finestra a parte, senza l'ambiente della principale) l'altezza viene dalla finestra principale,
        // tolto il margine trasparente del vetro (2 × 28).
        let mainHeight = MainWindowMetrics.shared.height
        let limit = windowHeight > 0 ? max(300, windowHeight * 0.90)
            : (inGlassPanel && mainHeight > 0 ? max(300, mainHeight * 0.90 - 56) : height)
        content.frame(width: width, height: fill ? limit : min(height, limit))
    }
}

/// Misure e finestra della finestra principale, lette anche dalla finestra Impostazioni (altra scena, senza ambiente condiviso).
@MainActor
final class MainWindowMetrics: ObservableObject {
    static let shared = MainWindowMetrics()
    @Published var height: CGFloat = 0
    weak var window: NSWindow?
    /// Altezza delle Impostazioni: 90 % della principale (minimo 480 pt); se non nota, quella di prima.
    var settingsHeight: CGFloat { height > 0 ? max(480, height * 0.90) : 740 }
}

/// Centra la finestra che lo contiene rispetto alla finestra principale (all'apertura e a ogni cambio di altezza).
struct CenterOnMainWindow: NSViewRepresentable {
    var trigger: CGFloat
    final class Coordinator { var last: CGFloat = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.last != trigger else { return }
        context.coordinator.last = trigger
        DispatchQueue.main.async {
            guard let window = nsView.window, let main = MainWindowMetrics.shared.window else { return }
            let m = main.frame, f = window.frame
            window.setFrameOrigin(NSPoint(x: m.midX - f.width / 2, y: m.midY - f.height / 2))
        }
    }
}

extension EnvironmentValues {
    var windowHeight: CGFloat {
        get { self[WindowHeightKey.self] }
        set { self[WindowHeightKey.self] = newValue }
    }
    var compactPane: Bool {
        get { self[CompactPaneKey.self] }
        set { self[CompactPaneKey.self] = newValue }
    }
    var glassInsets: GlassInsets {
        get { self[GlassInsetsKey.self] }
        set { self[GlassInsetsKey.self] = newValue }
    }
}

/// Riga vuota, non selezionabile, in testa o in coda a una `List`: riserva lo spazio dei pannelli di
/// vetro sovrapposti, cosi a riposo nessuna riga resta nascosta; scorrendo, le righe passano sotto
/// il vetro. (I `contentMargins` non venivano applicati alle List di macOS: la riga è la via sicura.)
struct GlassInsetRow: View {
    enum Edge { case top, bottom }
    let edge: Edge
    @Environment(\.glassInsets) private var insets

    var body: some View {
        Color.clear
            .frame(height: max(0, edge == .top ? insets.top : insets.bottom))
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Distanza della capsula alta dal bordo superiore (fuori dal tipo generico: lì le proprietà statiche non sono ammesse).
/// Intensità del velo sfocato dietro il vetro `.clear` del pannello alto (0…1): regola l'equilibrio tra trasparenza e leggibilità.
private let glassTopVeil: Double = 0.5

private let glassTopGap: CGFloat = 2   //: 2 pt di stacco dalla barra del titolo, così gli angoli alti della capsula si vedono interi (prima 0)

private struct GlassBarsModifier<TopBar: View, BottomBar: View>: ViewModifier {
    let topBar: TopBar
    let bottomBar: BottomBar

    /// Altezze reali dei due pannelli (aggiornate a ogni cambio di layout): diventano i margini
    /// del contenuto scorrevole, cosi a riposo nulla resta nascosto sotto i pannelli.
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0
    /// Larghezza del pannello (metà finestra): le due capsule hanno SEMPRE la stessa larghezza, qualunque cosa contengano.
    /// Se i controlli di una barra non ci stanno, escono dal bordo (tagliati dal pannello) invece di allargare la capsula.
    @State private var paneWidth: CGFloat = 0
    private var barContentWidth: CGFloat? { paneWidth > 0 ? max(0, paneWidth - 16 - 16) : nil }   // 2×8 margine + 2×8 padding
    /// «Opacità finestra» (Impostazioni → Aspetto): i due pannelli la seguono, come lo sfondo della finestra.
    @ObservedObject private var settings = AppSettings.shared

    /// Strato di colore di finestra sopra il vetro, all'opacità scelta: 0 % = vetro puro (come prima), 100 % = pannello
    /// quasi pieno. È lo stesso strato (colore e opacità) che la finestra principale mette dietro tutto il contenuto.
    private var panelFill: Color { Color(nsColor: .windowBackgroundColor).opacity(settings.windowOpacity) }

    // Capsule staccate dai bordi, come la barra di Music: angoli tutti arrotondati.
    // Per tornare ai pannelli attaccati ai bordi: ripristinare la copia GlassBars.swift.prima-capsula.
    private let topShape = RoundedRectangle(cornerRadius: 26, style: .continuous)
    private let bottomShape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    /// Distanza della capsula alta dal bordo superiore della finestra; la fascia sopra la capsula
    /// è mascherata, cosi lì non si vede il testo dell'elenco che scorre.
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask {
                VStack(spacing: 0) {
                    Color.clear.frame(height: glassTopGap)
                    Color.black
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
            .environment(\.glassInsets, GlassInsets(top: topHeight, bottom: bottomHeight))
            .contentMargins(.top, topHeight, for: .scrollIndicators)
            .contentMargins(.bottom, bottomHeight, for: .scrollIndicators)
            .overlay(alignment: .top) {
                // Il vetro grande (pannello alto, circa 4 volte più alto del basso) con `.regular` risulta «soffice»: sfoca e schiarisce molto
                // quello che passa sotto, mentre il basso lascia vedere le righe quasi nitide. Prova: variante `.clear` (più trasparente) per il
                // pannello alto, così con «Opacità finestra» al minimo l'effetto è evidente come in basso. Per tornare a `.regular`:
                // `GlassBars.swift.prima-vetro-chiaro` (stesso contenitore, `.regular`) o `.prima-vetro-uguale`.
                GlassEffectContainer(spacing: 8) {
                    topBar
                        .frame(width: barContentWidth, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 10)
                        .background(panelFill, in: topShape)
                        // Velo leggero tra `.regular` (troppo soffice) e `.clear` (troppo trasparente: il testo sotto si sovrappone a quello del
                        // pannello): sfoca appena le righe che passano sotto. Si regola con `glassTopVeil` (0 = tutto `.clear`, 1 = molto soffice).
                        .background(.ultraThinMaterial.opacity(glassTopVeil), in: topShape)
                        .glassEffect(.clear, in: topShape)
                }
                    // Capsula staccata: margine ai lati e in alto.
                    .padding(.horizontal, 8)
                    .padding(.top, glassTopGap)
                    .padding(.bottom, 4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            }
            .overlay(alignment: .bottom) {
                GlassEffectContainer(spacing: 8) {
                    bottomBar
                        .buttonStyle(.flat)
                        .frame(width: barContentWidth, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 10)
                        // Attaccato al bordo inferiore: angoli bassi retti, arrotondati solo quelli alti.
                        .background(panelFill, in: bottomShape)
                        .glassEffect(.regular, in: bottomShape)
                }
                // Capsula staccata: margine ai lati e in basso.
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
            }
            .clipped()
    }
}

/// Campo di ricerca con lente d'ingrandimento a sinistra, come quello delle Impostazioni di
/// macOS, in una capsula di vetro; il pulsante "x" per svuotarlo compare solo con del testo.
struct GlassSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Dentro il pannello di vetro della barra alta: solo un leggero riempimento, niente secondo vetro.
        .background(.quaternary, in: Capsule())
    }
}


// MARK: - Pulsanti piatti (senza vetro)

/// Stile unico dei pulsanti dell'app (2.1 Beta 3): capsula piatta, senza effetto vetro, come il «Confirm» degli avvisi.
/// - normale: fondo grigio leggero, testo del colore primario;
/// - ruolo `.destructive`: fondo rosato, testo rosso;
/// - `prominent`: fondo del colore d'accento, testo bianco (azione principale).
/// Rispetta `controlSize` e lo stato disattivato.
struct FlatButtonStyle: ButtonStyle {
    var prominent = false
    /// Margine interno ai lati del testo: 6 nelle barre (larghezze calcolate), più ampio nei dialoghi e nei fogli.
    var horizontal: CGFloat = 6
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        let foreground: Color = destructive ? .red : (prominent ? .white : .primary)
        let fill: Color = destructive ? Color.red.opacity(0.22) : (prominent ? Color.accentColor : Color.primary.opacity(0.10))
        let vertical: CGFloat = controlSize == .large ? 9 : (controlSize == .small || controlSize == .mini ? 3 : 6)
        configuration.label
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == FlatButtonStyle {
    static var flat: FlatButtonStyle { FlatButtonStyle() }
    static var flatProminent: FlatButtonStyle { FlatButtonStyle(prominent: true) }
    /// Per dialoghi e fogli: più aria prima e dopo il testo. Per tornare indietro: `*.prima-margine-bottoni`.
    static var flatRoomy: FlatButtonStyle { FlatButtonStyle(horizontal: 14) }
    static var flatProminentRoomy: FlatButtonStyle { FlatButtonStyle(prominent: true, horizontal: 14) }
}


/// Messaggio vuoto su due righe (separate da «\n»): titolo in evidenza e istruzione sotto; ogni riga resta intera
/// (a capo solo se non ci sta), così funziona uguale in interfaccia ridotta o larga.
struct TwoLineHint: View {
    let text: String
    var body: some View {
        let parts = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 3) {
            Text(parts.first ?? "").font(.headline)
            if parts.count > 1 { Text(parts[1]).font(.subheadline) }
        }
        .foregroundStyle(.secondary)
    }
}
