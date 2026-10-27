import SwiftUI
import AppKit
import Combine

@main
struct MusicManagerApp: App {
    // Intercetta la chiusura del programma per chiedere conferma (ed eventuale disconnessione)
    // quando un dispositivo Garmin è ancora connesso: vedi AppDelegate.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() { AppLog.start() }

    /// Osserva la lingua: al cambio il corpo dell'app si rivaluta e i menu personalizzati e i titoli delle finestre si aggiornano.
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .buttonStyle(.flat)
        }
        // All'apertura la finestra ha sempre la dimensione minima necessaria a mostrare tutto il contenuto
        // (né a tutto schermo né una misura salvata troppo piccola): non si ripristina il frame precedente.
        .defaultSize(width: 1440, height: 800)
        // Il minimo lo dà il contenuto; il massimo di larghezza (1440, tranne a schermo intero) lo imposta `FitWindowToVisibleScreen`.
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        // Voce «Informazioni su…» del menu dell'app: apre il pannello About personalizzato (vedi `AboutView`).
        .commands {
            AboutCommands()
            FileMenuCommands()
            HelpMenuCommands()
        }
        // Pannello About: finestra singola a misura del contenuto, senza minimizza/zoom, non aperta all'avvio.
        Window(t("about_window_title"), id: "about") {
            AboutView()
                .buttonStyle(.flat)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        // macOS aggiunge da solo la voce "Impostazioni…" (⌘,) nel menu dell'app per questa scena.
        Settings {
            SettingsView()
                .buttonStyle(.flat)
        }
    }
}


/// Stato minimo che i menu devono osservare (2.1 Beta 3). Prima i menu osservavano l'intero view model
/// (`@FocusedObject`): a ogni suo cambiamento (decine al secondo durante la preparazione dei brani da inviare)
/// SwiftUI ricostruiva la barra dei menu e la voce «Modifica», rimossa subito dopo, lampeggiava.
/// Ora i menu osservano solo questi tre valori, che cambiano di rado (`removeDuplicates`), e leggono il view model
/// senza osservarlo, solo quando si sceglie una voce.
@MainActor
final class MenuState: ObservableObject {
    static let shared = MenuState()
    @Published private(set) var isBusy = false
    @Published private(set) var hasDevice = false
    @Published private(set) var customPlaylistEmpty = true
    /// Il view model dell'unica finestra (non osservato: serve solo alle azioni delle voci di menu).
    private(set) weak var vm: AppViewModel?
    private var cancellables = Set<AnyCancellable>()

    func attach(_ vm: AppViewModel) {
        self.vm = vm
        cancellables.removeAll()
        vm.$isBusy.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.isBusy = $0 }.store(in: &cancellables)
        vm.$device.map { $0 != nil }.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.hasDevice = $0 }.store(in: &cancellables)
        vm.$customPlaylistEntries.map { $0.isEmpty }.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.customPlaylistEmpty = $0 }.store(in: &cancellables)
    }
}

/// Menu File: tolta «Nuova finestra» (l'app ha una sola finestra) e aggiunte le stesse azioni della Custom Playlist:
/// «Carica da file…» e «Salva su file…», con le stesse icone del pannello.
struct FileMenuCommands: Commands {
    @ObservedObject private var loc = LocalizationManager.shared   // ridisegna le voci al cambio di lingua
    @ObservedObject private var menu = MenuState.shared
    private var vm: AppViewModel? { menu.vm }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(t("menu_load_playlist_file"), systemImage: "square.and.arrow.down") {
                vm?.loadCustomPlaylistFromFile()
            }
            .labelStyle(.titleAndIcon)
            .disabled(vm == nil || menu.isBusy)
            Button(t("menu_save_playlist_file"), systemImage: "square.and.arrow.up") {
                vm?.saveCustomPlaylistToFile()
            }
            .labelStyle(.titleAndIcon)
            .disabled(vm == nil || menu.isBusy || menu.customPlaylistEmpty)
            Divider()
            Button(t("menu_reload_library"), systemImage: "arrow.clockwise") {
                guard let vm else { return }
                Task { await vm.loadLibrary(reloadRemote: true) }
            }
            .labelStyle(.titleAndIcon)
            .keyboardShortcut("r", modifiers: .command)
            .disabled(vm == nil || menu.isBusy)
        }
        // Menu Modifica: non serve all'app, si toglie per intero (le voci qui; la voce di menu in `AppDelegate.removeEditMenu`).
        CommandGroup(replacing: .undoRedo) {}
        CommandGroup(replacing: .pasteboard) {}
        CommandGroup(replacing: .textEditing) {}
        CommandGroup(replacing: .textFormatting) {}
        // Menu Vista: resta solo «Entra in schermo intero» (tolti barra strumenti, barra laterale e schede).
        CommandGroup(replacing: .toolbar) {}
        CommandGroup(replacing: .sidebar) {}
    }
}

/// Sostituisce la voce standard «Informazioni su…» del menu dell'app con l'apertura del pannello About personalizzato.
struct AboutCommands: Commands {
    @ObservedObject private var loc = LocalizationManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(t("about_menu_item", AboutView.appName)) { openWindow(id: "about") }
        }
    }
}

/// Pannello «Informazioni su»: icona grande a sinistra; a destra nome, versione, nota di copyright e pulsante
/// «Note legali…». Impostato come quello di Musica (barra del titolo nascosta, solo il pulsante di chiusura attivo).
struct AboutView: View {
    static var appName: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? "Music Manager"
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        return t("about_version", version, build)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 56) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 168, height: 168)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 0) {
                Text(Self.appName)
                    .font(.system(size: 34, weight: .regular))
                    .padding(.top, 22)
                Text(versionText)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)

                Spacer(minLength: 24)

                Text(t("about_copyright"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button(t("about_legal_button")) { Self.showLegalNotes() }
                        .controlSize(.large)
                }
                .padding(.top, 14)
            }
            .frame(width: 380, height: 232, alignment: .topLeading)
        }
        .padding(.horizontal, 44)
        .padding(.top, 44)
        .padding(.bottom, 32)
        .fixedSize()
        .background(.windowBackground)
        // Minimizza e zoom disattivati (resta solo il pulsante di chiusura attivo), come nel pannello di Musica.
        .background(DisableWindowZoomAndMinimize())
    }

    /// Note legali: marchi e librerie di terze parti usate dall'app.
    private static func showLegalNotes() {
        let alert = NSAlert()
        alert.messageText = t("about_legal_title")
        alert.informativeText = t("about_legal_text")
        alert.alertStyle = .informational
        alert.addButton(withTitle: t("button_close"))
        alert.runModal()
    }
}


/// Disattiva i pulsanti «minimizza» e «zoom» della finestra che contiene la vista (resta attivo solo «chiudi»).
private struct DisableWindowZoomAndMinimize: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // La finestra esiste solo dopo che la vista è stata inserita: si applica al ciclo successivo.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}


/// All'apertura porta la finestra principale a occupare tutta l'altezza libera dello schermo: `visibleFrame` esclude la barra
/// dei menu e il Dock (anche grande o a sinistra/destra), quindi la finestra non lo copre. La larghezza non cambia (è
/// fissa). Si applica una sola volta per finestra: dopo, l'utente può ridimensionarla in altezza come vuole.
struct FitWindowToVisibleScreen: NSViewRepresentable {
    final class Coordinator {
        var applied = false
        var observers: [NSObjectProtocol] = []
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }

    /// Larghezza fissa della finestra (punti di contenuto).
    private static let fixedWidth: CGFloat = 1440

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window, !context.coordinator.applied else { return }
            context.coordinator.applied = true
            MainWindowMetrics.shared.window = window
            // Larghezza bloccata a 1440, altezza libera; il pallino verde offre «Riempi» (altezza) e schermo intero.
            // A schermo intero il limite di larghezza si toglie, e si rimette all'uscita.
            let width = Self.fixedWidth
            window.contentMaxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            window.collectionBehavior.insert(.fullScreenPrimary)
            let center = NotificationCenter.default
            context.coordinator.observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { _ in
                window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            })
            context.coordinator.observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                window.contentMaxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            })
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            var frame = window.frame
            frame.size.height = visible.height
            // In alto sotto la barra dei menu; in orizzontale resta dentro l'area libera (centrata se ci sta).
            frame.origin.y = visible.maxY - frame.height
            frame.origin.x = max(visible.minX, min(visible.midX - frame.width / 2, visible.maxX - frame.width))
            window.setFrame(frame, display: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}


// MARK: - Registro, diagnostica e menu Aiuto (2.1 Beta 1)

/// Registro semplice degli eventi (messaggi della barra di stato), in `~/Library/Logs/MusicManager/MusicManager.log`.
/// Non contiene dati personali oltre ai messaggi mostrati dall'app (che possono citare il titolo di un brano in lavorazione).
enum AppLog {
    private static let queue = DispatchQueue(label: "com.crdev.MusicManager.log")
    private static var lastMessage = ""
    private static let maxBytes = 400_000
    private static let keepBytes = 150_000

    /// Registro dettagliato (Impostazioni ▸ Avanzate): se spento, `debug` non scrive nulla.
    nonisolated(unsafe) static var detailed = false

    /// Riga di diagnostica: scritta solo con il registro dettagliato acceso. Il testo si calcola solo in quel caso.
    static func debug(_ message: @autoclosure () -> String) {
        guard detailed else { return }
        write("[debug] " + message())
    }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MusicManager/MusicManager.log")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    static func start() {
        let info = Bundle.main.infoDictionary
        let v = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let b = (info?["CFBundleVersion"] as? String) ?? "?"
        write("=== Avvio \(v) (\(b)) — macOS \(ProcessInfo.processInfo.operatingSystemVersionString) ===", force: true)
    }

    static func write(_ message: String, force: Bool = false) {
        queue.async {
            guard force || message != lastMessage, !message.isEmpty else { return }
            lastMessage = message
            let line = stamp() + "  " + message.replacingOccurrences(of: "\n", with: " ⏎ ") + "\n"
            let url = fileURL
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes,
               let data = try? Data(contentsOf: url) {
                var tail = data.suffix(keepBytes)
                if let nl = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: nl)...] }
                try? Data(tail).write(to: url)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            }
        }
    }

    /// «Clean Log» (Impostazioni ▸ Avanzate): cancella il file di registro, che riparte da zero alla prossima riga scritta.
    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
            lastMessage = ""
        }
    }

    /// Ultime `count` righe del registro.
    static func tail(_ count: Int) -> String {
        queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
            return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).joined(separator: "\n")
        }
    }
}

/// Testo di diagnostica da incollare in un feedback: versioni, sistema, dispositivo, conteggi e ultimi eventi.
/// Nessun titolo, artista o nome della libreria (tranne quelli eventualmente presenti nei messaggi del registro).
@MainActor
enum Diagnostics {
    private static func hwModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    static func text(for vm: AppViewModel?) -> String {
        let info = Bundle.main.infoDictionary
        var lines: [String] = []
        lines.append("App: \(AboutView.appName) \((info?["CFBundleShortVersionString"] as? String) ?? "?") (build \((info?["CFBundleVersion"] as? String) ?? "?"))")
        lines.append("Bundle ID: \(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Mac: \(hwModel())")
        lines.append("libmtp: \(LIBMTP_VERSION_STRING)")
        lines.append("Language: \(LocalizationManager.shared.language.rawValue)")
        lines.append("Online artwork: \(AppSettings.shared.lookupMissingArtworkOnline ? "on" : "off"); Garmin update/maps check: \(AppSettings.shared.checkDeviceUpdates ? "on" : "off")")
        lines.append("Detailed log: \(AppSettings.shared.detailedLog ? "on" : "off"); music on volumes: \(AppSettings.shared.manageMusicOnVolumes ? "on" : "off")")
        if let vm {
            if let d = vm.device {
                lines.append("Device: \(d.manufacturer) \(d.model) — storages: \(d.storages.count)")
                lines.append("Device software: \(vm.deviceXMLInfo?.softwareVersion.map { "\($0)" } ?? "-")")
                lines.append("Device music: \(vm.deviceTracks.count) tracks, \(vm.devicePlaylists.count) playlists")
            } else {
                lines.append("Device: not connected")
            }
            lines.append("Garmin volumes: " + (vm.volumeDevices.isEmpty ? "none" : vm.volumeDevices.map { "\($0.info.description ?? "?") (music: \($0.isMusicCapable ? "yes" : "no"))" }.joined(separator: ", ")))
            lines.append("Music library: \(vm.tracks.count) tracks, \(vm.playlists.count) playlists")
            // Libreria a schermo e motivi per cui i brani non sono trasferibili (conteggi, senza dati personali).
            var shown = "local (Music)"
            if vm.externalLibraryName != nil { shown = vm.isDriveLibraryActive ? "external (drive)" : "external (XML)" }
            lines.append("Library shown: " + shown)
            var reasons: [String: Int] = [:]
            for track in vm.tracks { if let reason = track.blockedReason { reasons[reason, default: 0] += 1 } }
            let transferable = vm.tracks.count - reasons.values.reduce(0, +)
            lines.append("Transferable: \(transferable) of \(vm.tracks.count)" + (reasons.isEmpty ? "" : "; not transferable: "
                + reasons.sorted { $0.value > $1.value }.map { "\($0.key) × \($0.value)" }.joined(separator: ", ")))
            lines.append("Status: \(vm.status.replacingOccurrences(of: "\n", with: " "))")
        }
        let log = AppLog.tail(40)
        if !log.isEmpty { lines.append(""); lines.append("--- Last log lines ---"); lines.append(log) }
        return lines.joined(separator: "\n")
    }

    static func copy(for vm: AppViewModel?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text(for: vm), forType: .string)
    }
}

/// Menu Aiuto: diagnostica, feedback, registro e licenze.
struct HelpMenuCommands: Commands {
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject private var menu = MenuState.shared
    private var vm: AppViewModel? { menu.vm }

    private var feedbackURL: URL? {
        guard let raw = Bundle.main.infoDictionary?["MMFeedbackURL"] as? String,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return URL(string: raw)
    }

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(t("help_copy_diagnostics"), systemImage: "doc.on.clipboard") {
                Diagnostics.copy(for: vm)
                vm?.status = t("status_diagnostics_copied")
            }
            .labelStyle(.titleAndIcon)
            Button(t("help_send_feedback"), systemImage: "paperplane") {
                Diagnostics.copy(for: vm)
                if let url = feedbackURL {
                    vm?.status = t("status_diagnostics_copied")
                    NSWorkspace.shared.open(url)
                } else {
                    vm?.status = t("status_feedback_not_configured")
                }
            }
            .labelStyle(.titleAndIcon)
            Divider()
            Button(t("help_save_device_tree"), systemImage: "list.bullet.indent") {
                if let vm { Task { await vm.saveDeviceTree() } }
            }
            .labelStyle(.titleAndIcon)
            .disabled(!menu.hasDevice || menu.isBusy)
            Button(t("help_save_device_xml"), systemImage: "doc.badge.gearshape") {
                if let vm { Task { await vm.saveDeviceXML() } }
            }
            .labelStyle(.titleAndIcon)
            .disabled(!menu.hasDevice || menu.isBusy)
            Button(t("help_show_log"), systemImage: "doc.text.magnifyingglass") {
                let url = AppLog.fileURL
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(url.deletingLastPathComponent())
                }
            }
            .labelStyle(.titleAndIcon)
            Button(t("help_licenses"), systemImage: "doc.plaintext") {
                if let url = Bundle.main.url(forResource: "THIRD-PARTY-LICENSES", withExtension: "txt") {
                    NSWorkspace.shared.open(url)
                }
            }
            .labelStyle(.titleAndIcon)
        }
    }
}
