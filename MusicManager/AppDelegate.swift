import AppKit
import SwiftUI

/// Intercetta la chiusura del programma (⌘Q, menu "Esci", o click sulla X della finestra, che su
/// macOS in questa app termina l'app dato che non ci sono altre finestre): se un dispositivo
/// Garmin è ancora connesso, chiede prima conferma di voler davvero chiudere e, se confermato, se
/// si vuole anche disconnettere il dispositivo prima di uscire. Nessuna delle due domande compare
/// se non c'è un dispositivo connesso: il programma si chiude normalmente.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Senza questo, chiudere l'unica finestra (il pallino rosso) lascerebbe il programma in
    /// esecuzione senza finestre invece di uscire: qui invece il click sulla X passa dalla stessa
    /// `applicationShouldTerminate` di ⌘Q/"Esci", cosi le domande sotto compaiono in entrambi i
    /// casi, in modo identico.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// All'avvio applica l'aspetto scelto in Impostazioni (Chiaro / Scuro / Sistema).
    /// Prima dell'avvio dei menu: niente schede di finestra (tolti «Mostra barra delle schede» / «Mostra tutte le schede»)
    /// e niente «Emoji e simboli» / «Avvia dettatura» nel menu Modifica.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.set(true, forKey: "NSDisabledDictationMenuItem")
        UserDefaults.standard.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
    }

    /// Toglie dalla barra dei menu «Modifica» e «Formato» (quest'ultimo compare da solo dopo aver tolto Modifica):
    /// riconosciuti dal nome o dalle azioni del sottomenu (paste, orderFrontFontPanel).
    private func removeEditMenu() {
        guard let menu = NSApp.mainMenu else { return }
        let names: Set<String> = ["Edit", "Modifica", "Format", "Formato"]
        for item in menu.items where names.contains(item.title) || names.contains(item.submenu?.title ?? "")
            || item.submenu?.items.contains(where: { $0.action == #selector(NSText.paste(_:)) || $0.action == #selector(NSFontManager.orderFrontFontPanel(_:)) }) == true {
            menu.removeItem(item)
        }
    }

    /// SwiftUI/AppKit possono rimettere i menu dopo l'avvio (o a ogni cambio lingua): si ripete la rimozione ogni volta
    /// che una voce viene aggiunta alla barra dei menu (rimandata, per non modificare il menu durante la notifica).
    private var menuObserver: NSObjectProtocol?
    private func observeMainMenu() {
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? NSMenu) === NSApp.mainMenu else { return }
            DispatchQueue.main.async { self.removeEditMenu() }
        }
    }

    /// Senza il menu Modifica ⌘X/⌘C/⌘V/⌘A non arriverebbero ai campi di testo (nickname, ricerca): li si inoltra a mano,
    /// solo mentre si sta scrivendo in un campo (così ⌘A non tocca le liste).
    private var editKeysMonitor: Any?
    private func installEditKeysMonitor() {
        editKeysMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  NSApp.keyWindow?.firstResponder is NSText,
                  let key = event.charactersIgnoringModifiers else { return event }
            let action: Selector?
            switch key {
            case "x": action = #selector(NSText.cut(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            default: action = nil
            }
            guard let action else { return event }
            return NSApp.sendAction(action, to: nil, from: nil) ? nil : event
        }
    }

    /// Menu del tasto destro nei campi di testo ridotto a Taglia / Copia / Incolla / Seleziona tutto
    /// (senza Look Up, Traduci, Google, Writing Tools, Ortografia, Sostituzioni, AutoFill, Servizi…).
    private var contextMenuMonitor: Any?
    private func installTextContextMenuMonitor() {
        contextMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let window = event.window, let content = window.contentView else { return event }
            let point = content.convert(event.locationInWindow, from: nil)
            guard let hit = content.hitTest(point) else { return event }
            // Campo di testo sotto il cursore (o editor del campo già attivo).
            var field: NSTextField?
            var v: NSView? = hit
            while let cur = v {
                if let f = cur as? NSTextField { field = f; break }
                v = cur.superview
            }
            // Campi contrassegnati «senza menu» (es. Nickname della tabella Devices): nessun menu, né il nostro né quello di sistema.
            if let tv = hit as? NSTextView, tv.isFieldEditor, let f = tv.delegate as? NSTextField,
               f.accessibilityIdentifier() == "noContextMenu" { return nil }
            if let f = field, f.accessibilityIdentifier() == "noContextMenu" { return nil }
            let editor: NSTextView?
            if let tv = hit as? NSTextView, tv.isFieldEditor { editor = tv }
            else if let f = field, f.isEditable {
                window.makeFirstResponder(f)
                editor = f.currentEditor() as? NSTextView
            } else { return event }
            guard let editor else { return event }
            let menu = NSMenu()
            menu.autoenablesItems = true
            let entries: [(String, Selector)] = [
                (t("textmenu_cut"), #selector(NSText.cut(_:))),
                (t("textmenu_copy"), #selector(NSText.copy(_:))),
                (t("textmenu_paste"), #selector(NSText.paste(_:))),
                (t("textmenu_select_all"), #selector(NSText.selectAll(_:)))
            ]
            for (i, e) in entries.enumerated() {
                if i == 3 { menu.addItem(.separator()) }
                let item = NSMenuItem(title: e.0, action: e.1, keyEquivalent: "")
                item.target = editor
                menu.addItem(item)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: editor)
            return nil
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditKeysMonitor()
        installTextContextMenuMonitor()
        DispatchQueue.main.async { [weak self] in self?.removeEditMenu() }
        observeMainMenu()
        AppSettings.shared.applyAppearance()
    }

    /// Alla chiusura elimina i file preparati per il dispositivo in `~/Music/MusicManager/TEMP`
    /// (vedi `AppViewModel.exportStagingFolder`): sono solo copie di lavoro, si ricreano a ogni invio.
    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: AppViewModel.exportStagingFolder)
    }

    /// Custom Playlist compilata: prima di uscire chiede se salvarla su file (Custom Lib) o ignorarla. Il nome si può
    /// scrivere o correggere nella stessa finestra. Vero = si può proseguire con l'uscita.
    private func confirmCustomPlaylistBeforeQuit(_ vm: AppViewModel) -> Bool {
        guard vm.customPlaylistHasContent else { return true }
        let model = QuitDialogModel(
            title: t("alert_quit_playlist_title"), message: t("alert_quit_playlist_message"),
            buttons: [QuitDialogButton(title: t("button_save_to_file"), icon: "square.and.arrow.up", kind: .primary),
                      QuitDialogButton(title: t("button_quit")),
                      QuitDialogButton(title: t("button_cancel"), isCancel: true)],
            showsField: true, name: vm.customPlaylistName, placeholder: t("custom_playlist_name_placeholder"))
        while true {
            switch runQuitDialog(model) {
            case 0:
                let name = model.name.trimmingCharacters(in: .whitespaces)
                if name.isEmpty {
                    // Senza nome non si può salvare: si ripropone la domanda con un avviso.
                    model.placeholder = t("status_custom_playlist_name_required")
                    continue
                }
                if vm.customPlaylistFileExists(named: name) {
                    // Stessa finestra (senza icona) delle altre domande all'uscita.
                    let replace = QuitDialogModel(
                        title: t("alert_file_overwrite_title"), message: t("alert_file_overwrite_message", name),
                        buttons: [QuitDialogButton(title: t("button_replace"), kind: .primary),
                                  QuitDialogButton(title: t("button_cancel"), isCancel: true)])
                    if runQuitDialog(replace) != 0 { continue }
                }
                if let error = vm.saveCustomPlaylistFileNow(named: name) {
                    let failed = QuitDialogModel(
                        title: error, message: "",
                        buttons: [QuitDialogButton(title: t("button_close"), kind: .primary, isCancel: true)])
                    _ = runQuitDialog(failed)
                    continue
                }
                return true
            case 1:
                return true
            default:
                return false
            }
        }
    }

    /// Mostra una finestra di conferma all'uscita (SwiftUI in un pannello modale) e restituisce l'indice del pulsante scelto
    /// (Esc → il pulsante di annullamento; -1 se non ce n'è).
    private func runQuitDialog(_ model: QuitDialogModel) -> Int {
        let panel = GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        QuitDialogView.makeGlassPanel(panel)
        model.choice = -1
        model.finish = { index in
            model.choice = index
            NSApp.stopModal()
        }
        let host = NSHostingView(rootView: QuitDialogView(model: model))
        // Senza l'area sicura della barra del titolo (trasparente) il contenuto parte dal bordo alto: niente spazio vuoto sopra il titolo.
        host.safeAreaRegions = []
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.center()
        // L'ombra segue la forma disegnata (rettangolo arrotondato): va ricalcolata a layout fatto.
        DispatchQueue.main.async { panel.invalidateShadow() }
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return model.choice
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let vm = AppViewModel.current, !confirmCustomPlaylistBeforeQuit(vm) {
            return .terminateCancel
        }
        guard let vm = AppViewModel.current, vm.device != nil else {
            return finishQuitUnmountingNetwork(AppViewModel.current)
        }

        let confirmQuit = QuitDialogModel(
            title: t("alert_quit_device_connected_title", vm.deviceNameForAlerts), message: t("alert_quit_device_connected_message"),
            buttons: [QuitDialogButton(title: t("button_close"), kind: .primary),
                      QuitDialogButton(title: t("button_cancel"), isCancel: true)])
        guard runQuitDialog(confirmQuit) == 0 else {
            return .terminateCancel
        }

        let confirmDisconnect = QuitDialogModel(
            title: t("alert_quit_disconnect_title"), message: t("alert_quit_disconnect_message"),
            buttons: [QuitDialogButton(title: t("button_disconnect_and_quit"), kind: .primary),
                      QuitDialogButton(title: t("button_quit_without_disconnecting"))])
        let wantsDisconnect = runQuitDialog(confirmDisconnect) == 0

        guard wantsDisconnect else { return finishQuitUnmountingNetwork(vm) }

        // La disconnessione è asincrona (chiude la sessione MTP): si chiede ad AppKit di
        // aspettare (.terminateLater) invece di terminare subito, cosi il processo non esce di
        // mezzo alla chiusura della connessione USB.
        Task { @MainActor in
            await vm.disconnect()
            // Dopo la disconnessione del dispositivo, se serve, si smontano anche le risorse di rete (con il messaggio).
            let reply = self.finishQuitUnmountingNetwork(vm)
            if reply == .terminateNow { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// Ultimo passo dell'uscita: smonta i volumi di rete montati dall'app. Se in questa sessione si è usata una libreria di rete
    /// compare, senza pulsanti, il messaggio «Disconnessione dalle risorse di rete…» (si chiude da solo): l'attesa di qualche
    /// secondo non sembra un blocco. Se i volumi erano stati solo montati, lo smontaggio è silenzioso.
    /// Restituisce `.terminateNow` se non c'è nulla da smontare, altrimenti `.terminateLater` e risponde ad AppKit a lavoro finito.
    private func finishQuitUnmountingNetwork(_ vm: AppViewModel?) -> NSApplication.TerminateReply {
        guard let vm, vm.hasVolumesMountedByApp else { return .terminateNow }
        var panel: NSPanel?
        if vm.networkLibraryUsedThisSession {
            let model = QuitDialogModel(title: t("quit_disconnecting_network_title"), message: t("quit_disconnecting_network_message"),
                                        buttons: [])
            let p = GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            QuitDialogView.makeGlassPanel(p)
            let host = NSHostingView(rootView: QuitDialogView(model: model))
            host.safeAreaRegions = []
            p.contentView = host
            p.setContentSize(host.fittingSize)
            p.center()
            p.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { p.invalidateShadow() }
            panel = p
        }
        Task { @MainActor in
            await vm.unmountVolumesMountedByApp()
            panel?.orderOut(nil)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Pannello senza cornice del sistema (niente bordo né angoli propri): la forma e il bordo li disegna la vista (vetro di raggio 26),
/// l'ombra segue quella forma. Senza cornice un pannello non diventerebbe «key»: serve per Invio / Esc sui pulsanti.
final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Un pulsante delle finestre di uscita.
struct QuitDialogButton {
    enum Kind { case primary, plain }
    let title: String
    var icon: String? = nil
    var kind: Kind = .plain
    /// Attivato da Esc.
    var isCancel = false
}

/// Stato di una finestra di conferma all'uscita (titolo, messaggio, campo del nome opzionale, pulsanti, scelta finale).
final class QuitDialogModel: ObservableObject {
    let title: String
    let message: String
    let buttons: [QuitDialogButton]
    let showsField: Bool
    @Published var name: String
    @Published var placeholder: String
    /// Elenco opzionale (per esempio i titoli dei brani) sotto il messaggio, in un riquadro scorrevole.
    var items: [String] = []
    /// Indice del pulsante scelto (Esc → il pulsante di annullamento, se c'è).
    var choice = -1
    var finish: (Int) -> Void = { _ in }
    init(title: String, message: String, buttons: [QuitDialogButton], showsField: Bool = false, name: String = "", placeholder: String = "") {
        self.title = title; self.message = message; self.buttons = buttons
        self.showsField = showsField; self.name = name; self.placeholder = placeholder
    }
}

/// Finestra di conferma all'uscita: stessa grafica per tutte (nessuna icona, titolo, messaggio, campo opzionale, pulsanti
/// della misura standard sulla stessa riga) e stessa larghezza.
struct QuitDialogView: View {
    @ObservedObject var model: QuitDialogModel
    @FocusState private var nameFocused: Bool

    /// Forma e vetro dei pannelli (stessi delle capsule delle barre: raggio 26, colore di finestra all'opacità scelta in Impostazioni).
    private let glassShape = RoundedRectangle(cornerRadius: 26, style: .continuous)
    private static let glassMargin: CGFloat = 28

    /// Pannello senza sfondo proprio: lo sfondo è il vetro disegnato dalla vista, con l'ombra della finestra.
    static func makeGlassPanel(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // l'ombra di finestra restava con la forma/posizione vecchie (secondo contorno): resta solo quella del vetro
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.title).font(.headline).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            if !model.message.isEmpty {
                Text(model.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.items.enumerated()), id: \.offset) { _, item in
                            Text("• " + item).font(.callout).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 130)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            }
            if model.showsField {
                TextField(model.placeholder, text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .padding(.top, 4)
            }
            // Pannello di sola attesa (senza pulsanti, es. «Disconnessione dalle risorse di rete…»): rotellina al posto dei pulsanti.
            if model.buttons.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
            HStack(spacing: 8) {
                ForEach(Array(model.buttons.enumerated()), id: \.offset) { index, button in
                    let isPrimary = button.kind == .primary
                    let shortcut: KeyboardShortcut? = isPrimary ? .defaultAction : (button.isCancel ? .cancelAction : nil)
                    Button { model.finish(index) } label: {
                        Group {
                            if let icon = button.icon { Label(button.title, systemImage: icon) } else { Text(button.title) }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: mainBarButtonWidth())
                    }
                    .buttonStyle(isPrimary ? FlatButtonStyle(prominent: true, horizontal: 14) : FlatButtonStyle(horizontal: 14))
                    .keyboardShortcut(shortcut)
                }
            }
            .padding(.top, model.buttons.isEmpty ? 0 : 4)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(20)
        // Larghezza uguale per tutte le finestre di uscita (tre pulsanti + due spazi + margini); altezza minima comune.
        .frame(width: mainBarButtonWidth() * 3 + 16 + 40 + 24 + 3 * 16)
        .frame(minHeight: model.buttons.isEmpty ? 0 : 190)
        // Liquid Glass come le barre (prima: fondo pieno della finestra). Per tornare indietro: `AppDelegate.swift.prima-vetro`.
        .background(Color(nsColor: .windowBackgroundColor).opacity(AppSettings.shared.windowOpacity), in: glassShape)
        .glassEffect(.regular, in: glassShape)
        // Bordo sottile nostro (la cornice del sistema non c'è più): definisce il contorno anche su sfondi chiari.
        .overlay(glassShape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        // Margine trasparente attorno al vetro: l'effetto vetro ha un'ombra e un bordo luminoso che escono dalla forma; con la
        // finestra aderente venivano tagliati e restavano come «fili» disegnati sul contorno.
        .padding(Self.glassMargin)
        .onAppear { if model.showsField { nameFocused = true } }
    }
}


/// Presenta un pannello di domanda (stessa grafica delle finestre di uscita) e restituisce l'indice del pulsante scelto
/// (Esc → il pulsante di annullamento; -1 se non ce n'è). Lo usa anche il view model: gli avvisi di sistema (`.alert`) hanno una
/// larghezza fissa e stretta, questo pannello no.
enum DialogPresenter {
    @MainActor static func run(_ model: QuitDialogModel) -> Int {
        let panel = GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        QuitDialogView.makeGlassPanel(panel)
        model.choice = -1
        model.finish = { index in
            model.choice = index
            NSApp.stopModal()
        }
        let host = NSHostingView(rootView: QuitDialogView(model: model))
        host.safeAreaRegions = []
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.center()
        // L'ombra segue la forma disegnata (rettangolo arrotondato): va ricalcolata a layout fatto.
        DispatchQueue.main.async { panel.invalidateShadow() }
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return model.choice
    }
}


/// Contenitore dei pannelli modali di vetro (forma, vetro, bordo e margine trasparente come le finestre di conferma).
private struct GlassModalContainer<Content: View>: View {
    let content: Content
    private let glassShape = RoundedRectangle(cornerRadius: 26, style: .continuous)
    static var margin: CGFloat { 28 }
    var body: some View {
        content
            .environment(\.inGlassPanel, true)
            .clipShape(glassShape)   // le fasce a tutta larghezza seguono gli angoli del pannello
            .buttonStyle(.flatRoomy)   // fuori dalla finestra principale i pulsanti non ereditano lo stile: piatti come altrove
            .background(Color(nsColor: .windowBackgroundColor).opacity(AppSettings.shared.windowOpacity), in: glassShape)
            .glassEffect(.regular, in: glassShape)
            .overlay(glassShape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            .padding(Self.margin)
    }
}

/// Presenta una vista SwiftUI qualsiasi in un pannello modale di vetro (come `DialogPresenter`, ma con contenuto libero).
/// Il pannello si apre al centro della finestra principale (non si sposta) e si chiude chiamando `close`.
/// Per tornare allo sheet: `ContentView.swift.prima-pannello-eliminazione`.
enum GlassModalPresenter {
    /// `window`: finestra su cui centrare il pannello (per esempio quella delle Impostazioni); predefinita: la finestra principale.
    @MainActor static func run<Content: View>(over window: NSWindow? = nil, _ build: (_ close: @escaping () -> Void) -> Content) {
        let panel = GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        QuitDialogView.makeGlassPanel(panel)
        let host = NSHostingView(rootView: GlassModalContainer(content: build({ NSApp.stopModal() })))
        host.safeAreaRegions = []
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(size)
        if let w = window ?? MainWindowMetrics.shared.window {
            panel.setFrameOrigin(NSPoint(x: w.frame.midX - size.width / 2, y: w.frame.midY - size.height / 2))
        } else {
            panel.center()
        }
        DispatchQueue.main.async { panel.invalidateShadow() }
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
    }
}


/// Esegue `block` al prossimo giro del run loop principale (modalità predefinita), cioè FUORI da un blocco della coda GCD
/// principale. I pannelli modali (`GlassModalPresenter`) vanno aperti così: se `runModal` parte da dentro un blocco di
/// `DispatchQueue.main`, la coda principale è occupata fino alla chiusura del pannello e nulla di ciò che è messo sul
/// MainActor (`Task`, `.task`, `await` su oggetti del view model) avanza mentre il pannello è aperto.
func onNextRunLoop(_ block: @escaping () -> Void) {
    final class Holder: @unchecked Sendable { let block: () -> Void; init(_ b: @escaping () -> Void) { block = b } }
    let holder = Holder(block)
    RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { holder.block() } }
}
