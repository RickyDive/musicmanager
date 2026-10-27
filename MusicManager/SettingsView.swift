import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Pannello Impostazioni dell'app, raggiungibile dal menu dell'applicazione (⌘,). Le scelte fatte
/// qui si applicano subito e restano memorizzate per i prossimi avvii.
struct SettingsView: View {
    @ObservedObject private var metrics = MainWindowMetrics.shared
    @ObservedObject private var loc = LocalizationManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var remoteLoader = RemoteLibraryManager.shared
    @ObservedObject private var reach = LibraryReachability.shared
    /// Esito dell'ultima lettura di una libreria remota (errore da mostrare sotto l'elenco).
    @State private var remoteError: String?

    /// Vero mentre è visibile l'alert di spiegazione mostrato la prima volta che si accende
    /// "Cerca copertine mancanti online" (vedi sotto). Non è legato direttamente al Toggle: il
    /// Toggle si accende solo se l'utente conferma qui, altrimenti torna spento.
    @State private var confirmArtworkLookup = false
    /// Messaggio di conferma dopo "Svuota cache copertine", per dare un riscontro visibile (il
    /// pulsante da solo, senza nessuna reazione, farebbe dubitare che abbia funzionato).
    @State private var artworkCacheClearedJustNow = false
    /// Spazio occupato dalla cache delle copertine (byte), riletto all'apertura e dopo lo svuotamento.
    @State private var artworkCacheSize: UInt64 = 0
    /// Libreria condivisa di cui si chiede conferma della rimozione (nil = nessuna richiesta).
    @State private var pendingRemoveLibraryID: UUID?
    /// Vero mentre è visibile la richiesta di conferma di «Ripristina tutte le impostazioni».
    @State private var confirmReset = false

    // MARK: Librerie «Unità esterna» (2.2)
    @ObservedObject private var driveManager = DriveLibraryManager.shared
    /// Cartella scelta in attesa della scelta/conferma del dispositivo (nil = nessuna).
    @State private var driveSetup: DriveSetup?
    /// Nessun dispositivo registrato: la sorgente non parte.
    @State private var showNoDeviceAlert = false
    @State private var pendingRemoveDriveID: UUID?
    @State private var selectedDriveID: UUID?
    /// Riga appena aggiunta (file XML o cartella scelti) in attesa del nome obbligatorio: la lettura parte solo dopo.
    @State private var pendingRemoteNameID: UUID?
    @State private var pendingDriveNameID: UUID?
    @FocusState private var focusedDriveNickname: UUID?
    @State private var driveError: String?

    private struct DriveSetup: Identifiable {
        let id = UUID()
        let url: URL
        let choices: [DriveDeviceChoice]
        let automatic: DriveDeviceChoice?
    }

    /// Scheda scelta. Le schede sono disegnate a mano (non con `TabView`) per tenerle allineate a sinistra e
    /// per lasciare fisso il titolo della finestra («Impostazioni»), che con `TabView` cambia a ogni scheda.
    private enum Pane: CaseIterable {
        case general, appearance, artwork, advanced
        var key: String {
            switch self {
            case .general: return "settings_tab_general"
            case .appearance: return "settings_tab_appearance"
            case .artwork: return "settings_tab_artwork"
            case .advanced: return "settings_tab_advanced"
            }
        }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .artwork: return "photo"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }
    @State private var pane: Pane = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Barra delle schede, allineata a sinistra.
            HStack(spacing: 6) {
                ForEach(Pane.allCases, id: \.self) { item in
                    Button { pane = item } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.icon).font(.system(size: 18))
                            Text(t(item.key)).font(.caption)
                        }
                        .frame(width: 86, height: 46)
                        .background(pane == item ? Color.accentColor.opacity(0.22) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            Group {
                switch pane {
                case .general: generalTab
                case .appearance: appearanceTab
                case .artwork: artworkTab
                case .advanced: advancedTab
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: metrics.settingsHeight)   // 90 % della finestra principale, centrata su di essa
        .background(CenterOnMainWindow(trigger: metrics.settingsHeight))
        .onAppear {
            Task { await LibraryReachability.shared.refresh() }
            artworkCacheSize = ArtworkCache.sizeOnDisk()
            Task {
                currentRouter = await Task.detached(priority: .utility, operation: { NetworkIdentity.currentRouterID() }).value
            }
            // Librerie salvate prima dell'indirizzo con IP: si ricava ora.
            for lib in settings.remoteLibraries where lib.networkAddress == nil && !lib.path.isEmpty {
                settings.refreshNetworkAddress(for: lib.id)
            }
        }
        .alert(t("alert_remove_library_title"), isPresented: Binding(
            get: { pendingRemoveLibraryID != nil },
            set: { if !$0 { pendingRemoveLibraryID = nil } }
        )) {
            Button(t("button_remove"), role: .destructive) {
                if let id = pendingRemoveLibraryID {
                    settings.remoteLibraries.removeAll { $0.id == id }
                    selectedLibrary = nil
                }
                pendingRemoveLibraryID = nil
            }
            Button(t("button_cancel"), role: .cancel) { pendingRemoveLibraryID = nil }
        } message: {
            Text(t("alert_remove_library_message",
                   settings.remoteLibraries.first { $0.id == pendingRemoveLibraryID }?.nickname ?? ""))
        }
        .alert(t("drive_no_device_title"), isPresented: $showNoDeviceAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(t("drive_no_device_message"))
        }
        .alert(t("drive_remove_title"), isPresented: Binding(
            get: { pendingRemoveDriveID != nil },
            set: { if !$0 { pendingRemoveDriveID = nil } }
        )) {
            Button(t("button_remove"), role: .destructive) {
                if let id = pendingRemoveDriveID { settings.driveLibraries.removeAll { $0.id == id } }
                pendingRemoveDriveID = nil
            }
            Button(t("button_cancel"), role: .cancel) { pendingRemoveDriveID = nil }
        } message: {
            Text(t("drive_remove_message", settings.driveLibraries.first { $0.id == pendingRemoveDriveID }?.nickname ?? ""))
        }
        .sheet(item: $driveSetup) { setup in
            DriveSetupSheet(url: setup.url, choices: setup.choices, automatic: setup.automatic,
                            onCreate: { device in driveSetup = nil; createDriveLibrary(url: setup.url, device: device) },
                            onCancel: { driveSetup = nil })
        }
        .alert(t("alert_reset_settings_title"), isPresented: $confirmReset) {
            Button(t("button_reset_settings"), role: .destructive) { settings.resetAllSettings() }
            Button(t("button_cancel"), role: .cancel) {}
        } message: {
            Text(t("alert_reset_settings_message"))
        }
        .alert(t("alert_enable_artwork_lookup_title"), isPresented: $confirmArtworkLookup) {
            Button(t("button_enable")) { settings.lookupMissingArtworkOnline = true }
            Button(t("button_cancel"), role: .cancel) {}
        } message: {
            Text(t("alert_enable_artwork_lookup_message"))
        }
    }

    // MARK: Schede

    /// Lingua ed elenco iniziale.
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            generalForm
            // In basso a destra: ripristino di tutte le impostazioni (con conferma).
            HStack {
                Spacer()
                Button(t("settings_reset_all")) { confirmReset = true }
            }
        }
    }

    private var generalForm: some View {
        Form {
            // Ogni controllo sta nella stessa riga del modulo con la sua nota (niente divisore in mezzo); tra una voce e
            // l'altra resta il divisore. Etichetta a sinistra e controllo a destra, come nel modulo.
            Picker(t("settings_language"), selection: $loc.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text("\(lang.flag) \(lang.nativeName)").tag(lang)
                }
            }
            Text(t("settings_language_note")).font(.caption).foregroundStyle(.secondary)

            settingRow(t("settings_default_category"), hint: t("settings_default_category_hint")) {
                Picker("", selection: $settings.defaultCategory) {
                    // "Custom Playlist" non è una scheda di apertura valida: è la playlist creata a
                    // mano, sempre vuota a ogni avvio, non una scheda tra cui scegliere di partire.
                    ForEach(CatalogCategory.browsable) { category in
                        Text(category.title).tag(category)
                    }
                }
                .labelsHidden()
            }

            settingRow(t("settings_playlist_types"), hint: t("settings_playlist_types_hint")) {
                Picker("", selection: $settings.playlistTypeFilter) {
                    ForEach(AppSettings.PlaylistTypeFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
            }

            settingRow(t("settings_show_only_transferable"), hint: t("settings_show_only_transferable_hint")) {
                Toggle("", isOn: $settings.showOnlyTransferable)
                    .labelsHidden().toggleStyle(.switch)
            }

            settingRow(t("settings_confirm_music_changes"), hint: t("settings_confirm_music_changes_hint")) {
                Toggle("", isOn: $settings.confirmBeforeMusicChanges)
                    .labelsHidden().toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
    }

    /// Riga del modulo: etichetta a sinistra, controllo a destra e, sotto, la nota; tutto in un'unica riga del `Form`
    /// (così il modulo non disegna il divisore tra il controllo e la nota).
    private func settingRow<Control: View>(_ title: String, hint: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                control()
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Aspetto (chiaro/scuro/sistema), colore di selezione, opacità della finestra.
    /// Dimensione comune delle due anteprime (testo e trasparenza).
    private let previewSize = CGSize(width: 260, height: 52)

    /// Un album a caso della libreria Apple Music con la copertina disponibile, scelto all'apertura delle Impostazioni.
    @State private var previewAlbum: (title: String, artist: String, cover: NSImage)?

    /// Anteprima della dimensione del testo: la riga di un album come nell'elenco (copertina, titolo alla dimensione scelta
    /// e sottotitolo secondario). Senza libreria o copertine, una riga di esempio con un'icona.
    private var textSizePreview: some View {
        HStack(spacing: 10) {
            Group {
                if let cover = previewAlbum?.cover {
                    Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.secondary.opacity(0.15)
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 32 * 0.18))
            VStack(alignment: .leading, spacing: 2) {
                Text(previewAlbum?.title ?? t("settings_text_size_sample"))
                    .font(.system(size: settings.listTextSize.points)).fontWeight(.medium).lineLimit(1)
                Text(previewAlbum?.artist ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: previewSize.width, height: previewSize.height, alignment: .leading)
        .task { await pickPreviewAlbum() }
    }

    /// Sceglie a caso, tra gli album della libreria, uno con copertina (prova al massimo 40 album).
    private func pickPreviewAlbum() async {
        guard previewAlbum == nil, let vm = AppViewModel.current else { return }
        var seen = Set<String>()
        let candidates = vm.tracks.filter { !$0.album.isEmpty && seen.insert($0.album.lowercased() + "|" + $0.artist.lowercased()).inserted }
            .shuffled().prefix(40)
        for track in candidates {
            if let data = await vm.appleArtwork(for: track), let image = NSImage(data: data) {
                let artist = track.albumArtist.trimmingCharacters(in: .whitespaces)
                previewAlbum = (track.album, artist.isEmpty ? track.artist : artist, image)
                return
            }
        }
    }

    /// Anteprima dell'opacità della finestra, della stessa dimensione di quella del testo.
    private var opacityPreview: some View {
        ZStack {
            // Sfondo con colore e dettagli, come una foto dietro la finestra.
            LinearGradient(colors: [Color(red: 0.36, green: 0.62, blue: 0.95), Color(red: 0.80, green: 0.90, blue: 1.0)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(Color.yellow.opacity(0.85)).frame(width: 22, height: 22).offset(x: -80, y: -10)
            HStack(spacing: 6) {
                Rectangle().fill(Color.orange.opacity(0.8)).frame(width: 26, height: 30)
                Rectangle().fill(Color.pink.opacity(0.7)).frame(width: 18, height: 40)
                Rectangle().fill(Color.indigo.opacity(0.7)).frame(width: 30, height: 24)
            }
            .offset(x: 60, y: 12)
            // Gli stessi strati della finestra principale.
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(settings.windowOpacity))
            // Barra di controlli: pulsanti piatti (condividi / altro) e un campo di ricerca.
            HStack(spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up")
                    Image(systemName: "ellipsis")
                }
                .padding(.horizontal, 10).frame(height: 26)
                // Pulsanti piatti, come nell'app (stesso colore dello stile `FlatButtonStyle`): niente vetro.
                .background(Capsule().fill(Color.primary.opacity(0.10)))
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                    Text(t("settings_opacity_sample_search"))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).frame(height: 26)
                .background(.thinMaterial, in: Capsule())
            }
            .font(.system(size: 11, weight: .medium))
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))
    }

    private var appearanceTab: some View {
        Form {
            // Controllo e nota nella stessa riga del modulo, così non c'è il divisore in mezzo.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 12) {
                    Text(t("settings_appearance"))
                        .frame(width: previewSize.width, alignment: .leading)
                    // Tre anteprime della nostra interfaccia (pannelli, elenco, riga selezionata): Chiaro, Scuro, Automatico (metà e metà).
                    HStack(spacing: 14) {
                        ForEach([AppSettings.Appearance.light, .dark, .system]) { option in
                            AppearanceTile(option: option, isSelected: settings.appearance == option) {
                                settings.appearance = option
                            }
                        }
                    }
                    // Centrate nella fascia delle barre sotto (stessa colonna a sinistra, fino al bordo destro).
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                Text(t("settings_appearance_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Colore di selezione: pallini e barra della tonalità occupano la stessa fascia delle barre sotto
            // (stesso margine a sinistra dell'anteprima e a destra del valore), con la barra centrata sotto i pallini.
            VStack(alignment: .leading, spacing: 6) {
                // Titolo e didascalia a sinistra, pallini e barra della tonalità nella fascia delle barre: il titolo sta sulla
                // riga dei pallini (24 pt), la didascalia su quella della barra (22 pt), con la stessa spaziatura (6 pt).
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t("settings_highlight_color")).lineLimit(1).frame(height: 24, alignment: .leading)
                        SelectionColorCaption(settings: settings).frame(height: 22, alignment: .leading)
                    }
                    .frame(width: previewSize.width, alignment: .leading)
                    SelectionColorSwatches(settings: settings)
                }
                Text(t("settings_highlight_color_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Dimensione del testo negli elenchi: cinque posizioni, tre nomi sotto la barra. Tutto in un'unica riga del
            // modulo (così non ci sono divisori in mezzo): etichetta in alto; poi, sulla stessa riga, anteprima a
            // sinistra, barra che occupa tutto lo spazio libero (centrata sull'anteprima) e valore a destra (48 pt);
            // infine la nota.
            VStack(alignment: .leading, spacing: 6) {
                Text(t("settings_text_size")).lineLimit(1)
                HStack(spacing: 12) {
                    textSizePreview
                    // La larghezza della barra si fissa a quella disponibile: da sola, nel modulo, resterebbe stretta.
                    // Il pomello non arriva ai bordi della barra (margine di circa 8 pt per lato).
                    GeometryReader { geo in
                        let inset: CGFloat = 8
                        let span = max(geo.size.width - 2 * inset, 1)
                        NativeSlider(value: Binding(
                            get: { Double(settings.listTextSize.rawValue) },
                            set: { settings.listTextSize = AppSettings.ListTextSize(rawValue: Int($0.rounded())) ?? .medium }
                        ), range: 0...4, tickMarks: 5)
                        .frame(width: geo.size.width, height: 22)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        ForEach([(0, "settings_text_size_xs"), (2, "settings_text_size_medium"), (4, "settings_text_size_large")], id: \.0) { item in
                            Text(t(item.1))
                                .font(.caption)
                                .fixedSize()
                                .foregroundStyle(item.0 == settings.listTextSize.rawValue ? Color.primary : Color.secondary)
                                .position(x: inset + span * CGFloat(item.0) / 4, y: geo.size.height / 2 + 22)
                        }
                    }
                    .frame(height: previewSize.height)
                }
                Text(t("settings_text_size_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Quanto è "pieno" lo sfondo della finestra principale (0 % = molto trasparente). Stessa struttura e stessa
            // larghezza della barra; senza trattini; sotto la barra, a sinistra l'icona del vetro e a destra quella piena.
            VStack(alignment: .leading, spacing: 6) {
                Text(t("settings_window_opacity")).lineLimit(1)
                HStack(spacing: 12) {
                    opacityPreview
                    GeometryReader { geo in
                        let inset: CGFloat = 8
                        NativeSlider(value: Binding(
                            get: { settings.windowOpacity },
                            set: { settings.windowOpacity = ($0 * 20).rounded() / 20 }   // passi del 5 %, senza trattini
                        ), range: 0...1, tickMarks: 0)
                        .frame(width: geo.size.width, height: 22)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        Image(systemName: "capsule.on.rectangle.liquid.glass")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                            .position(x: inset, y: geo.size.height / 2 + 22)
                        Image(systemName: "capsule.on.rectangle.fill")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                            .position(x: geo.size.width - inset, y: geo.size.height / 2 + 22)
                    }
                    .frame(height: previewSize.height)
                }
                Text(t("settings_window_opacity_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Fix Artwork (ricerca online), caricamento automatico da Apple Music, cache.
    private var artworkTab: some View {
        Form {
            // Toggle con binding personalizzato: accendendolo non si accende subito, ma apre prima
            // l'alert di spiegazione; si accende davvero solo confermando li. Spegnerlo è immediato.
            settingRow(t("settings_lookup_artwork"), hint: t("settings_lookup_artwork_hint")) {
                Toggle("", isOn: Binding(
                    get: { settings.lookupMissingArtworkOnline },
                    set: { newValue in
                        if newValue {
                            confirmArtworkLookup = true
                        } else {
                            settings.lookupMissingArtworkOnline = false
                        }
                    }
                ))
                .labelsHidden().toggleStyle(.switch)
            }

            settingRow(t("settings_auto_apple_artwork"), hint: t("settings_auto_apple_artwork_hint")) {
                Toggle("", isOn: $settings.autoLoadAppleArtwork)
                    .labelsHidden().toggleStyle(.switch)
            }

            // Richiede la ricerca online (Fix Artwork): senza, resta spenta.
            settingRow(t("settings_propose_shared_artwork"), hint: t("settings_propose_shared_artwork_hint")) {
                Toggle("", isOn: $settings.proposeSharedArtworkSearch)
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!settings.lookupMissingArtworkOnline)
            }

            // Dimensione della cache (stesso corpo delle altre voci) a sinistra e, sulla stessa riga, il pulsante a destra.
            HStack {
                Text(t("settings_artwork_cache_size",
                       ByteCountFormatter.string(fromByteCount: Int64(artworkCacheSize), countStyle: .file)))
                Spacer(minLength: 12)
                if artworkCacheClearedJustNow {
                    Text(t("status_artwork_cache_cleared"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(t("button_clear_artwork_cache")) {
                    ArtworkCache.clearAll()
                    artworkCacheSize = ArtworkCache.sizeOnDisk()
                    artworkCacheClearedJustNow = true
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Librerie remote.
    private var advancedTab: some View {
        // Riquadro disegnato a mano (non un `Form`, che trasformerebbe tabella e pulsanti in righe di modulo):
        // stesso aspetto arrotondato e grigio delle sezioni delle altre schede.
        ScrollView {
            VStack(spacing: 14) {
                devicesSection
                    .padding(.horizontal, 10).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                remoteLibrariesSection
                    .padding(.horizontal, 10).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                driveLibrariesSection
                    .padding(.horizontal, 10).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    .onDisappear { dropUnnamedLibraries() }   // aggiunta non completata (nome mancante): la riga si scarta
                toolsSection
                    .padding(.horizontal, 10).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 20)   // stesso margine del riquadro del modulo nelle altre schede (larghezza 680 pt)
        }
    }

    /// Vero per qualche secondo dopo «Clean Log» (conferma a schermo).
    @State private var logCleaned = false

    /// Strumenti: interruttore del file manager del dispositivo (2.1 Beta 3).
    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("settings_tools")).font(.headline)
            Toggle(t("settings_device_file_manager"), isOn: $settings.showDeviceFileManager)
            Text(t("settings_device_file_manager_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.top, 6)
            Toggle(t("settings_volume_music"), isOn: $settings.manageMusicOnVolumes)
                .padding(.top, 2)
            Text(t("settings_volume_music_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.top, 6)
            Toggle(t("settings_airplay_audio"), isOn: $settings.airPlayAsAudio)
                .padding(.top, 2)
            Text(t("settings_airplay_audio_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.top, 6)
            HStack {
                Text(t("settings_library_threads"))
                Spacer()
                Picker("", selection: $settings.libraryReadThreads) {
                    Text(t("settings_library_threads_multi")).tag(8)
                    Text(t("settings_library_threads_single")).tag(1)
                }
                .labelsHidden()
                .frame(width: 180)
            }
            .padding(.top, 2)
            Text(t("settings_library_threads_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.top, 6)
            Toggle(t("settings_detailed_log"), isOn: $settings.detailedLog)
                .padding(.top, 2)
            Text(t("settings_detailed_log_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(t("settings_show_log")) {
                    // Evidenzia il file nel Finder; se non esiste ancora apre la sua cartella.
                    if FileManager.default.fileExists(atPath: AppLog.fileURL.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
                    } else {
                        NSWorkspace.shared.open(AppLog.fileURL.deletingLastPathComponent())
                    }
                }
                .buttonStyle(.flatRoomy)
                Button(t("settings_clean_log")) {
                    AppLog.clear()
                    logCleaned = true
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        logCleaned = false
                    }
                }
                .buttonStyle(.flatRoomy)
                if logCleaned {
                    Label(t("settings_log_cleaned"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    // MARK: - Devices

    @State private var confirmForgetDevices = false
    private let deviceConnectedColumnWidth: CGFloat = 28
    private let deviceNicknameColumnWidth: CGFloat = 150
    private let deviceSoftwareColumnWidth: CGFloat = 100
    private let deviceSerialColumnWidth: CGFloat = 110
    private let deviceMapsColumnWidth: CGFloat = 44

    /// Contenuto del pannello Mappe, passato alla finestra al momento di aprirla (nessuno stato «vecchio» da rileggere).
    private struct MapsPayload: Identifiable {
        let id = UUID()
        let catalog: GarminMapsCatalog?
        let checkedAt: Date?
        let error: String?
    }
    @State private var mapsPayload: MapsPayload?

    /// Apre le mappe di un dispositivo: legge sempre e solo Maps.json (nessuna richiesta a Garmin).
    private func openMaps(forDevice id: String) {
        let saved = settings.storedMaps(forDevice: id)
        // Se il file si legge non c'è nulla da segnalare; altrimenti si mostra il motivo (percorso o errore di lettura).
        let problem = saved == nil ? (DeviceXMLStore.mapsReadProblem(forDevice: id) ?? "Maps.json non leggibile") : nil
        mapsPayload = MapsPayload(catalog: saved?.catalog, checkedAt: saved?.checkedAt, error: problem)
    }

    /// Vero se il Maps.json del dispositivo contiene almeno una mappa (installata o offerta): il file è la fonte vera,
    /// l'indicatore `hasMaps` memorizzato può essere mancante o vecchio (vale solo se il file non si legge).
    private func hasMapsData(_ device: AppSettings.KnownDevice) -> Bool {
        guard let saved = settings.storedMaps(forDevice: device.id) else { return device.hasMaps == true }   // file illeggibile: vale l'indicatore
        return !saved.catalog.isEmpty
    }

    /// Colore del globo dal Maps.json (vedi `mapsGlobeColor(catalog:checkedAt:)`).
    private func deviceGlobeColor(_ device: AppSettings.KnownDevice) -> Color {
        guard let saved = settings.storedMaps(forDevice: device.id) else { return .secondary }
        return mapsGlobeColor(catalog: saved.catalog, checkedAt: saved.checkedAt)
    }

    /// Riepilogo (tooltip) delle mappe installate memorizzate per un dispositivo.
    private func mapsTooltip(_ device: AppSettings.KnownDevice) -> String {
        guard let stored = DeviceXMLStore.loadMaps(forDevice: device.id), !stored.installed.isEmpty else { return t("tooltip_maps_info") }
        let maps = stored.installed
        let lines = maps.map { m -> String in
            let state = m.updateAvailable == true ? "Update Available" : (m.updateAvailable == false ? "Map Updated" : "")
            return "\(m.name) \(m.installedVersion ?? m.version)" + (state.isEmpty ? "" : " — \(state)")
        }
        var text = lines.joined(separator: "\n")
        text += "\n\n" + mapsCheckedText(stored.checkedAt)
        return text
    }

    /// Binding sicuro del Nickname di un dispositivo, cercato per Global ID a ogni accesso.
    private func deviceNicknameBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { settings.knownDevices.first { $0.id == id }?.nickname ?? "" },
            set: { settings.setNickname($0, forDevice: id) }
        )
    }

    /// Dispositivi memorizzati: tabella nello stesso stile (e della stessa dimensione) delle Remote Libraries.
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("settings_devices")).font(.headline)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: deviceConnectedColumnWidth)   // colonna senza titolo: stato di connessione
                    Divider().frame(height: 16)
                    Text(t("device_col_nickname"))
                        .padding(.horizontal, 8)
                        .frame(width: deviceNicknameColumnWidth, alignment: .leading)
                    Divider().frame(height: 16)
                    Text(t("device_col_model"))
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider().frame(height: 16)
                    Text(t("device_col_serial"))
                        .padding(.horizontal, 8)
                        .frame(width: deviceSerialColumnWidth, alignment: .leading)
                    Divider().frame(height: 16)
                    Text(t("device_col_maps"))
                        .padding(.horizontal, 8)
                        .frame(width: deviceMapsColumnWidth, alignment: .center)
                    Divider().frame(height: 16)
                    Text(t("device_col_software"))
                        .padding(.horizontal, 8)
                        .frame(width: deviceSoftwareColumnWidth, alignment: .leading)
                }
                .font(.system(size: 10, weight: .semibold))
                .frame(height: tableRowHeight)
                Divider()
                // Righe a strisce; scorrono se sono più di quelle visibili.
                ScrollView {
                VStack(spacing: 0) {
                ForEach(Array(settings.knownDevices.enumerated()), id: \.element.id) { index, device in
                    HStack(spacing: 0) {
                        // Pallino verde: l'orologio è collegato in questo momento.
                        // ZStack con Color.clear: la colonna tiene la sua larghezza anche senza pallino (un Group vuoto
                        // non produce nessuna vista e la colonna si ridurrebbe a zero, spostando le altre).
                        ZStack {
                            Color.clear
                            if settings.connectedDeviceIDs.contains(device.id) {
                                Circle().fill(statusIconGreen).frame(width: 9, height: 9)
                                    .help(t("device_connected_help"))
                            }
                        }
                        .frame(width: deviceConnectedColumnWidth)
                        TextField("", text: deviceNicknameBinding(device.id))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("noContextMenu")   // click destro: nessun menu (vedi AppDelegate)
                            .padding(.horizontal, 8)
                            .frame(width: deviceNicknameColumnWidth, alignment: .leading)
                        Text(device.model.isEmpty ? "—" : device.model)
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(device.model)
                        Text(device.serialNumber ?? "—")
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.disabled)
                            .padding(.horizontal, 8)
                            .frame(width: deviceSerialColumnWidth, alignment: .leading)
                            // Click destro: solo «Copia», che copia il numero di serie.
                            .contextMenu {
                                if let serial = device.serialNumber, !serial.isEmpty {
                                    Button(t("textmenu_copy")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(serial, forType: .string)
                                    }
                                }
                            }
                        ZStack {
                            Color.clear
                            if hasMapsData(device) {
                                Button { openMaps(forDevice: device.id) } label: {
                                    Image(systemName: "map").font(.system(size: 12))
                                        .foregroundStyle(deviceGlobeColor(device))
                                }
                                .buttonStyle(.plain)
                                .help(mapsTooltip(device))
                            }
                        }
                        .frame(width: deviceMapsColumnWidth, alignment: .center)
                        HStack(spacing: 5) {
                            Text(device.softwareVersion.isEmpty ? "—" : device.softwareVersion).lineLimit(1)
                            if let ok = device.softwareUpToDate {
                                Image(systemName: ok ? "checkmark.circle" : "xmark.circle")
                                    .foregroundStyle(ok ? statusIconGreen : statusIconRed)
                                    .help(ok ? "Software Updated" : "Upgrade Available")
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(width: deviceSoftwareColumnWidth, alignment: .leading)
                    }
                    .font(.system(size: 11))
                    .frame(height: tableRowHeight)
                    .background(index % 2 == 1 ? Color.primary.opacity(0.05) : Color.clear)
                }
                ForEach(settings.knownDevices.count..<max(tableVisibleRows, settings.knownDevices.count), id: \.self) { index in
                    (index % 2 == 1 ? Color.primary.opacity(0.05) : Color.clear).frame(height: tableRowHeight)
                }
                }
                }
            }
            .frame(height: tableRowHeight * CGFloat(tableVisibleRows + 1) + 1)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))

            HStack(spacing: 10) {
                Text(t("devices_hint")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                Button(t("button_forget_devices")) { confirmForgetDevices = true }
                    .disabled(settings.knownDevices.isEmpty)
            }

            Divider().padding(.top, 4)

            // Controllo (opzionale) dell'aggiornamento software del dispositivo sui server Garmin.
            Toggle(t("settings_check_device_updates"), isOn: $settings.checkDeviceUpdates)

            Text(t("settings_check_device_updates_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Pannello di vetro come quello della finestra principale (non più uno sheet), centrato sulle Impostazioni.
        // Per tornare allo sheet: `SettingsView.swift.prima-mappe-impostazioni`.
        .onChange(of: mapsPayload?.id) { _, id in
            guard id != nil, let payload = mapsPayload else { return }
            mapsPayload = nil
            let window = NSApp.keyWindow
            let check = settings.checkDeviceUpdates
            onNextRunLoop {
                GlassModalPresenter.run(over: window) { close in
                    MapsSheet(catalog: payload.catalog, checkEnabled: check, errorDetail: payload.error,
                              checkedAt: payload.checkedAt, onClose: { close() })
                }
            }
        }
        .alert(t("alert_forget_devices_title"), isPresented: $confirmForgetDevices) {
            Button("OK", role: .destructive) { settings.knownDevices = []; DeviceXMLStore.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(t("alert_forget_devices_message"))
        }
    }

    // MARK: - Remote Libraries

    /// Libreria selezionata nella tabella delle librerie remote.
    @State private var selectedLibrary: UUID?
    /// Riga il cui nickname è in modifica: il campo di testo «si prende» il click, quindi la selezione
    /// della riga si ricava dal fuoco (altrimenti «−» resterebbe spento cliccando sul nome).
    @FocusState private var focusedNickname: UUID?
    /// Binding sicuro del Nickname di una libreria, cercata per id a ogni accesso: se la riga non esiste più
    /// (appena rimossa) legge «» e ignora la scrittura, invece di usare un indice obsoleto.
    private func nicknameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { settings.remoteLibraries.first { $0.id == id }?.nickname ?? "" },
            set: { new in
                if let i = settings.remoteLibraries.firstIndex(where: { $0.id == id }) {
                    settings.remoteLibraries[i].nickname = new
                }
            }
        )
    }

    private func hasNickname(_ lib: RemoteLibraryConfig) -> Bool {
        !lib.nickname.trimmingCharacters(in: .whitespaces).isEmpty
    }
    /// Vero se la riga selezionata ha il Nickname compilato (condizione per scegliere il file XML).
    private var selectedHasNickname: Bool {
        settings.remoteLibraries.first { $0.id == selectedLibrary }.map(hasNickname) ?? false
    }
    private let tableRowHeight: CGFloat = 26
    private let tableVisibleRows = 3
    /// Riga di cui si sta modificando il MAC del router, testo in modifica ed eventuale messaggio d'errore.
    @State private var editingNetworkID: UUID?
    @State private var macDraft = ""
    @State private var macMessage: String?
    /// Rete attuale rilevata dall'app (e, se non si rileva, la diagnosi), mostrata nella finestrella del MAC.
    @State private var currentNetworkText: String?
    /// MAC del router della rete attuale (nil = non rilevato): serve a scegliere l'icona di ogni riga.
    @State private var currentRouter: String?

    /// Tabella a due colonne (Library Nickname / Path) delle librerie remote: file XML di Musica esportato
    /// dall'altro Mac. Al massimo `AppSettings.maxRemoteLibraries`; i nomi compaiono nel selettore della
    /// finestra principale. Righe a strisce e selezione come le tabelle di sistema; sotto, i pulsanti
    /// «+ / −» e quello per scegliere il file della riga selezionata.
    private var remoteLibrariesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("settings_remote_libraries")).font(.headline)

            VStack(spacing: 0) {
                // Intestazione (testi allineati a sinistra)
                HStack(spacing: 0) {
                    Color.clear.frame(width: deviceConnectedColumnWidth)   // colonna senza titolo: stato (pallino)
                    Divider().frame(height: 16)
                    Text(t("remote_col_nickname"))
                        .padding(.horizontal, 8)
                        .frame(width: deviceNicknameColumnWidth, alignment: .leading)
                    Divider().frame(height: 16)
                    Text(t("remote_col_path"))
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 10, weight: .semibold))
                .frame(height: tableRowHeight)
                Divider()
                // Righe (con strisce vuote fino a riempire la tabella); scorrono se sono più di quelle visibili.
                ScrollView {
                VStack(spacing: 0) {
                // Si itera sui valori (non su `$array`, i cui binding per elemento vanno in crash «Index out of
                // range» se la riga viene rimossa mentre è ancora a schermo) e il campo scrive per identificativo.
                ForEach(settings.remoteLibraries) { lib in
                    let index = settings.remoteLibraries.firstIndex { $0.id == lib.id } ?? 0
                    let stripe = index % 2 == 1 ? Color.primary.opacity(0.05) : Color.clear
                    let isSelected = selectedLibrary == lib.id
                    HStack(spacing: 0) {
                        // Stato: pallino verde pieno = volume montato (file XML leggibile); cerchio verde vuoto = il server risponde ma il
                        // volume non è montato (si monta alla scelta della libreria); rosso = non raggiungibile. Nessun pallino finché non
                        // si è fatta la prima verifica. Un clic sul pallino apre la finestrella della rete (MAC del router) della libreria.
                        let isMounted = reach.isMounted(lib.id)
                        let canReach = reach.reachable[lib.id] == true
                        Button {
                            guard reach.isOnline else { return }   // senza rete non si può leggere né modificare il MAC del router
                            macDraft = lib.homeNetwork ?? ""
                            macMessage = nil
                            selectedLibrary = lib.id
                            editingNetworkID = lib.id
                        } label: {
                            ZStack {
                                Color.clear
                                if !lib.path.isEmpty {
                                    if isMounted {
                                        Circle().fill(statusIconGreen).frame(width: 9, height: 9)
                                    } else if canReach {
                                        Circle().strokeBorder(statusIconGreen, lineWidth: 1.5).frame(width: 9, height: 9)
                                    } else if reach.isUnreachable(lib.id) {
                                        Circle().fill(statusIconRed).frame(width: 9, height: 9)
                                    }
                                }
                            }
                            .frame(width: deviceConnectedColumnWidth, height: tableRowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(!reach.isOnline ? t("remote_network_offline_help")
                              : (!isMounted && canReach) ? t("library_reachable_not_mounted", lib.nickname)
                              : reach.isUnreachable(lib.id) ? t("library_unreachable_status", lib.nickname) + "\n" + (reach.details[lib.id] ?? "")
                              : (lib.homeNetwork.map { t("remote_network_help_set", $0) } ?? t("remote_network_help_unset")))
                        .popover(isPresented: Binding(get: { editingNetworkID == lib.id },
                                                      set: { if !$0 { editingNetworkID = nil } }),
                                 arrowEdge: .bottom) { networkEditor(lib.id) }
                        TextField(t("library_name_placeholder"), text: nicknameBinding(lib.id))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .focused($focusedNickname, equals: lib.id)
                            .onSubmit { commitRemoteName(lib.id) }
                            .padding(.horizontal, 8)
                            .frame(width: deviceNicknameColumnWidth, alignment: .leading)
                        Text(lib.path.isEmpty ? "—" : (lib.networkAddress ?? lib.path))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(lib.path.isEmpty ? .secondary : .primary)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(lib.networkAddress.map { "\($0)\n\(lib.path)" } ?? lib.path)
                            .contentShape(Rectangle())
                            // Click sul Path: con il Nickname compilato apre subito la scelta del file XML.
                            .onTapGesture {
                                selectedLibrary = lib.id
                                if hasNickname(lib) { chooseXML(for: lib.id) }
                            }
                    }
                    .font(.system(size: 11))
                    .frame(height: tableRowHeight)
                    .background(isSelected ? Color.accentColor.opacity(0.28) : stripe)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { selectedLibrary = lib.id })
                }
                // Righe vuote a strisce, fino a riempire la tabella.
                ForEach(settings.remoteLibraries.count..<max(tableVisibleRows, settings.remoteLibraries.count), id: \.self) { index in
                    (index % 2 == 1 ? Color.primary.opacity(0.05) : Color.clear).frame(height: tableRowHeight)
                }
                }
                }
            }
            .onChange(of: focusedNickname) { old, new in
                if let new { selectedLibrary = new }
                // Uscendo dal campo del nome di una libreria appena aggiunta: se è vuoto si torna lì (il nome è obbligatorio).
                if let old, old == pendingRemoteNameID, new != old { commitRemoteName(old) }
            }
            .frame(height: tableRowHeight * CGFloat(tableVisibleRows + 1) + 1)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))

            HStack(spacing: 10) {
                // Pulsanti «+ | −» in un unico gruppo, come nelle tabelle di sistema.
                HStack(spacing: 0) {
                    Button { addRemoteLibrary() } label: { Image(systemName: "plus").frame(width: 28, height: 22).contentShape(Rectangle()) }
                    .disabled(settings.remoteLibraries.count >= AppSettings.maxRemoteLibraries || pendingRemoteNameID != nil)
                    .help(t("remote_add"))
                    Divider().frame(height: 14)
                    Button {
                        // Toglie la riga selezionata; se la selezione si fosse persa, l'ultima dell'elenco.
                        let id = settings.remoteLibraries.first { $0.id == selectedLibrary }?.id
                            ?? settings.remoteLibraries.last?.id
                        if let id {
                            if pendingRemoteNameID == id { pendingRemoteNameID = nil }
                            focusedNickname = nil
                            // Una riga appena aggiunta e ancora vuota si toglie subito; una libreria vera chiede conferma.
                            if settings.remoteLibraries.first(where: { $0.id == id })?.isUsable == true {
                                pendingRemoveLibraryID = id
                            } else {
                                settings.remoteLibraries.removeAll { $0.id == id }
                                selectedLibrary = nil
                            }
                        }
                    } label: { Image(systemName: "minus").frame(width: 28, height: 22).contentShape(Rectangle()) }
                    .disabled(settings.remoteLibraries.isEmpty)
                    .help(t("remote_remove_help"))
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))

                Text(t("remote_max_hint", AppSettings.maxRemoteLibraries)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 10)
                // Montaggio automatico all'avvio (spento: solo sondaggio; il volume si monta alla scelta della libreria).
                Text(t("settings_mount_at_launch")).font(.caption).foregroundStyle(.secondary)
                Toggle("", isOn: $settings.mountRemoteLibrariesAtLaunch)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(t("settings_mount_at_launch_help"))
            }
            // Lettura in corso (senza finestra): una riga con l'indicatore e la fase.
            if let p = remoteLoader.progress, p.inSettings {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(p.nickname): \(p.phase)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if pendingRemoteNameID != nil {
                Text(t("library_name_required")).font(.caption).foregroundStyle(.red)
            }
            if let remoteError {
                Text(remoteError).font(.caption).foregroundStyle(.red)
            }
            Text(t("remote_hint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - External Drive Libraries (2.2)

    private func driveNicknameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { settings.driveLibraries.first { $0.id == id }?.nickname ?? "" },
            set: { new in settings.updateDriveLibrary(id) { $0.nickname = new } }
        )
    }

    /// Cartella con i file audio su un'unità esterna: indice JSON proprio con i soli brani compatibili con il dispositivo.
    /// Tabella come quella delle Remote Libraries (pallino di stato, Nickname, Percorso) con i pulsanti «+ | −» sotto.
    /// La riscansione non ha più un pulsante: parte da sola scegliendo la libreria nel selettore della finestra principale.
    private var driveLibrariesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("settings_drive_libraries")).font(.headline)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: deviceConnectedColumnWidth)   // colonna senza titolo: stato (pallino)
                    Divider().frame(height: 16)
                    Text(t("remote_col_nickname"))
                        .padding(.horizontal, 8)
                        .frame(width: deviceNicknameColumnWidth, alignment: .leading)
                    Divider().frame(height: 16)
                    Text(t("remote_col_path"))
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 10, weight: .semibold))
                .frame(height: tableRowHeight)
                Divider()
                ScrollView {
                VStack(spacing: 0) {
                ForEach(settings.driveLibraries) { lib in
                    let index = settings.driveLibraries.firstIndex { $0.id == lib.id } ?? 0
                    let stripe = index % 2 == 1 ? Color.primary.opacity(0.05) : Color.clear
                    let available = DriveLibraryService.rootURL(lib) != nil
                    HStack(spacing: 0) {
                        // Pallino verde = unità collegata e cartella raggiungibile; rosso = non disponibile.
                        ZStack {
                            Color.clear
                            Circle().fill(available ? statusIconGreen : statusIconRed).frame(width: 9, height: 9)
                        }
                        .frame(width: deviceConnectedColumnWidth)
                        .help(available ? t("drive_row_info", lib.deviceName, lib.trackCount) : t("drive_err_unavailable", lib.nickname))
                        TextField(t("library_name_placeholder"), text: driveNicknameBinding(lib.id))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .focused($focusedDriveNickname, equals: lib.id)
                            .onSubmit { commitDriveName(lib.id) }
                            .accessibilityIdentifier("noContextMenu")
                            .padding(.horizontal, 8)
                            .frame(width: deviceNicknameColumnWidth, alignment: .leading)
                        Text(lib.path.isEmpty ? "—" : lib.path)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(available ? Color.primary : Color.secondary)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(lib.path)
                    }
                    .font(.system(size: 11))
                    .frame(height: tableRowHeight)
                    .background(selectedDriveID == lib.id ? Color.accentColor.opacity(0.28) : stripe)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { selectedDriveID = lib.id })
                }
                ForEach(settings.driveLibraries.count..<max(tableVisibleRows, settings.driveLibraries.count), id: \.self) { index in
                    (index % 2 == 1 ? Color.primary.opacity(0.05) : Color.clear).frame(height: tableRowHeight)
                }
                }
                }
            }
            .onChange(of: focusedDriveNickname) { old, new in
                if let new { selectedDriveID = new }
                if let old, old == pendingDriveNameID, new != old { commitDriveName(old) }
            }
            .frame(height: tableRowHeight * CGFloat(tableVisibleRows + 1) + 1)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))

            HStack(spacing: 10) {
                // Pulsanti «+ | −» in un unico gruppo, come nelle Remote Libraries.
                HStack(spacing: 0) {
                    Button { addDriveLibrary() } label: { Image(systemName: "plus").frame(width: 28, height: 22).contentShape(Rectangle()) }
                        .disabled(settings.driveLibraries.count >= AppSettings.maxDriveLibraries || driveManager.progress != nil || pendingDriveNameID != nil)
                        .help(t("drive_add"))
                    Divider().frame(height: 14)
                    Button {
                        // Toglie la cartella selezionata (con conferma); se la selezione si fosse persa, l'ultima dell'elenco.
                        let id = settings.driveLibraries.first { $0.id == selectedDriveID }?.id ?? settings.driveLibraries.last?.id
                        if let id {
                            // Una cartella appena scelta e ancora senza nome si toglie subito; una libreria vera chiede conferma.
                            if pendingDriveNameID == id {
                                pendingDriveNameID = nil
                                focusedDriveNickname = nil
                                settings.driveLibraries.removeAll { $0.id == id }
                                selectedDriveID = nil
                            } else {
                                pendingRemoveDriveID = id
                            }
                        }
                    } label: { Image(systemName: "minus").frame(width: 28, height: 22).contentShape(Rectangle()) }
                        .disabled(settings.driveLibraries.isEmpty)
                        .help(t("remote_remove_help"))
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))

                Text(t("remote_max_hint", AppSettings.maxDriveLibraries)).font(.caption).foregroundStyle(.secondary)
            }
            if let progress = driveManager.progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
            }
            if pendingDriveNameID != nil {
                Text(t("library_name_required")).font(.caption).foregroundStyle(.red)
            }
            if let driveError { Text(driveError).font(.caption).foregroundStyle(.red) }
            Text(t("drive_hint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// «Aggiungi cartella…»: serve almeno un dispositivo registrato (collegato almeno una volta); poi si sceglie la
    /// cartella e si conferma (o si sceglie) il dispositivo per cui creare il catalogo.
    private func addDriveLibrary() {
        let choices = driveManager.deviceChoices()
        guard !choices.isEmpty else { showNoDeviceAlert = true; return }
        let panel = NSOpenPanel()
        panel.title = t("drive_pick_title")
        panel.message = t("drive_pick_message")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        driveSetup = DriveSetup(url: url, choices: choices, automatic: driveManager.automaticDevice(in: choices))
    }

    private func createDriveLibrary(url: URL, device: DriveDeviceChoice) {
        // Il nome è obbligatorio: la riga nasce senza nome, il cursore va subito lì e la scansione parte dopo il nome.
        let cfg = DriveLibraryConfig(nickname: "", path: url.path, bookmark: FileBookmark.make(for: url),
                                     deviceID: device.id, deviceName: device.name, extensions: device.extensions)
        settings.driveLibraries.append(cfg)
        driveError = nil
        selectedDriveID = cfg.id
        pendingDriveNameID = cfg.id
        DispatchQueue.main.async { focusedDriveNickname = cfg.id }
    }

    /// Conferma del nome di una cartella appena aggiunta: vuoto = si resta nel campo; compilato = parte la scansione.
    private func commitDriveName(_ id: UUID) {
        guard pendingDriveNameID == id else { return }
        guard let cfg = settings.driveLibraries.first(where: { $0.id == id }) else { pendingDriveNameID = nil; return }
        if cfg.nickname.trimmingCharacters(in: .whitespaces).isEmpty {
            DispatchQueue.main.async { focusedDriveNickname = id }
            return
        }
        pendingDriveNameID = nil
        focusedDriveNickname = nil
        Task { do { try await driveManager.scan(cfg) } catch { driveError = error.localizedDescription } }
    }

    /// «+» delle librerie remote: prima si sceglie il file XML, poi si dà il nome (obbligatorio) e solo allora parte la lettura.
    private func addRemoteLibrary() {
        let p = NSOpenPanel()
        p.title = t("external_pick_xml_title")
        p.message = t("external_pick_xml_message")
        p.allowedContentTypes = [.xml, .propertyList]
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        var cfg = RemoteLibraryConfig()
        cfg.path = url.path
        cfg.bookmark = FileBookmark.make(for: url)
        settings.remoteLibraries.append(cfg)
        remoteError = nil
        selectedLibrary = cfg.id
        pendingRemoteNameID = cfg.id
        DispatchQueue.main.async { focusedNickname = cfg.id }
    }

    /// Conferma del nome di una libreria remota appena aggiunta: vuoto = si resta nel campo; compilato = lettura del file.
    private func commitRemoteName(_ id: UUID) {
        guard pendingRemoteNameID == id else { return }
        guard let cfg = settings.remoteLibraries.first(where: { $0.id == id }) else { pendingRemoteNameID = nil; return }
        if cfg.nickname.trimmingCharacters(in: .whitespaces).isEmpty {
            DispatchQueue.main.async { focusedNickname = id }
            return
        }
        pendingRemoteNameID = nil
        focusedNickname = nil
        settings.refreshNetworkAddress(for: id)
        settings.refreshHomeNetwork(for: id)
        Task {
            do {
                _ = try await RemoteLibraryManager.shared.load(cfg, verify: false, inSettings: true)
            } catch {
                remoteError = error.localizedDescription
            }
        }
    }

    /// Righe rimaste senza nome (aggiunta non completata) si scartano quando si lascia la sezione.
    private func dropUnnamedLibraries() {
        settings.remoteLibraries.removeAll { $0.nickname.trimmingCharacters(in: .whitespaces).isEmpty && pendingRemoteNameID == $0.id }
        settings.driveLibraries.removeAll { $0.nickname.trimmingCharacters(in: .whitespaces).isEmpty && pendingDriveNameID == $0.id }
        pendingRemoteNameID = nil
        pendingDriveNameID = nil
    }

    /// Finestrella per scrivere a mano il MAC del router della rete «di casa» di una libreria (o prendere quello della
    /// rete attuale). Vuoto = libreria senza rete nota (si comporta come prima).
    private func networkEditor(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("remote_network_title")).font(.headline)
            Text(t("remote_network_hint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let currentNetworkText {
                Text(currentNetworkText).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("aa:bb:cc:dd:ee:ff", text: $macDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { saveNetwork(id) }
            if let macMessage {
                Text(macMessage).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(t("remote_network_use_current")) {
                    Task {
                        let found = await Task.detached(priority: .utility, operation: { NetworkIdentity.currentRouterID() }).value
                        if let found { macDraft = found; macMessage = nil } else {
                            let diag = await Task.detached(priority: .utility, operation: { NetworkIdentity.diagnose() }).value
                            macMessage = t("remote_network_none_found") + "\n" + diag
                        }
                    }
                }
                Spacer()
                Button(t("remote_network_clear")) { setNetwork(id, nil); editingNetworkID = nil }
                Button(t("button_cancel")) { editingNetworkID = nil }
                Button(t("remote_network_save")) { saveNetwork(id) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 400)
        .task {
            currentNetworkText = nil
            let found = await Task.detached(priority: .utility, operation: { NetworkIdentity.currentRouterID() }).value
            if let found {
                currentNetworkText = t("remote_network_current", found)
            } else {
                let diag = await Task.detached(priority: .utility, operation: { NetworkIdentity.diagnose() }).value
                currentNetworkText = t("remote_network_current_none") + "\n" + diag
            }
        }
    }

    private func setNetwork(_ id: UUID, _ mac: String?) {
        guard let i = settings.remoteLibraries.firstIndex(where: { $0.id == id }) else { return }
        settings.remoteLibraries[i].homeNetwork = mac
    }

    /// Accetta anche separatori «-» o «.» e maiuscole; salva nel formato `aa:bb:cc:dd:ee:ff`. Campo vuoto = rimuove.
    private func saveNetwork(_ id: UUID) {
        let hex = macDraft.lowercased().filter { $0.isHexDigit }
        if macDraft.trimmingCharacters(in: .whitespaces).isEmpty {
            setNetwork(id, nil); editingNetworkID = nil; return
        }
        guard hex.count == 12 else { macMessage = t("remote_network_invalid"); return }
        let pairs = stride(from: 0, to: 12, by: 2).map { i -> String in
            let a = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[a..<hex.index(a, offsetBy: 2)])
        }
        setNetwork(id, pairs.joined(separator: ":"))
        editingNetworkID = nil
    }

    /// Finestra per scegliere il file XML; poi la lettura parte subito, con la finestra di avanzamento.
    private func chooseXML(for id: UUID) {
        let p = NSOpenPanel()
        p.title = t("external_pick_xml_title")
        p.message = t("external_pick_xml_message")
        p.allowedContentTypes = [.xml, .propertyList]
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url,
              let i = settings.remoteLibraries.firstIndex(where: { $0.id == id }) else { return }
        settings.remoteLibraries[i].path = url.path
        settings.remoteLibraries[i].networkAddress = nil
        settings.remoteLibraries[i].bookmark = FileBookmark.make(for: url)
        settings.remoteLibraries[i].mediaBookmark = nil
        settings.remoteLibraries[i].homeNetwork = nil
        settings.remoteLibraries[i].mediaPath = ""
        if settings.remoteLibraries[i].nickname.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.remoteLibraries[i].nickname = t("remote_default_nickname", i + 1)
        }
        let cfg = settings.remoteLibraries[i]
        settings.refreshNetworkAddress(for: id)
        settings.refreshHomeNetwork(for: id)
        remoteError = nil
        Task {
            do {
                _ = try await RemoteLibraryManager.shared.load(cfg, verify: false, inSettings: true)
            } catch {
                remoteError = error.localizedDescription
            }
        }
    }
}


/// Cursore nativo (NSSlider) che occupa tutta la larghezza proposta: il `Slider` di SwiftUI, dentro il modulo delle
/// impostazioni, restava stretto (circa 180 pt) anche con una larghezza esplicita. `tickMarks` > 0 mette quel numero di
/// trattini e blocca il cursore sulle posizioni; 0 = cursore continuo senza trattini.
private struct NativeSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var tickMarks: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.numberOfTickMarks = tickMarks
        slider.allowsTickMarkValuesOnly = tickMarks > 0
        slider.isContinuous = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if slider.doubleValue != value { slider.doubleValue = value }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 160, height: max(nsView.intrinsicContentSize.height, 20))
    }

    final class Coordinator: NSObject {
        var parent: NativeSlider
        init(_ parent: NativeSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
}


/// Miniatura della finestra dell'app (pannello alto con schede, elenco con una riga selezionata, barra in basso)
/// in versione chiara o scura: serve da anteprima nella scelta dell'aspetto.
private struct AppearanceMock: View {
    let dark: Bool

    var body: some View {
        let background = dark ? Color(white: 0.12) : Color(white: 0.95)
        let panel = dark ? Color.white.opacity(0.10) : Color.white
        let line = dark ? Color.white.opacity(0.28) : Color.black.opacity(0.16)
        let accent = Color.accentColor
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                Capsule().fill(accent).frame(width: 14, height: 4)
                Capsule().fill(line).frame(width: 10, height: 4)
                Capsule().fill(line).frame(width: 10, height: 4)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4).padding(.vertical, 2.5)
            .background(panel, in: RoundedRectangle(cornerRadius: 4))

            VStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { i in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5).fill(line).frame(width: 6, height: 6)
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(height: 3)
                    }
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(i == 0 ? accent.opacity(0.35) : Color.clear, in: RoundedRectangle(cornerRadius: 2))
                }
            }
            Spacer(minLength: 0)

            HStack(spacing: 2) {
                Capsule().fill(line).frame(width: 14, height: 4)
                Spacer(minLength: 0)
                Capsule().fill(accent).frame(width: 14, height: 4)
            }
            .padding(.horizontal, 4).padding(.vertical, 2.5)
            .background(panel, in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(3)
        .frame(width: 116, height: 38)
        .background(background)
    }
}

/// Anteprima selezionabile di un aspetto: miniatura con bordo (più spesso e colorato se scelto) e nome sotto.
/// «Automatico» mostra metà chiara e metà scura.
private struct AppearanceTile: View {
    let option: AppSettings.Appearance
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                mock
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                                    lineWidth: isSelected ? 3 : 1)
                    )
                Text(option.title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var mock: some View {
        switch option {
        case .light:
            AppearanceMock(dark: false)
        case .dark:
            AppearanceMock(dark: true)
        case .system:
            ZStack {
                AppearanceMock(dark: false)
                AppearanceMock(dark: true)
                    .mask(alignment: .trailing) { Rectangle().frame(width: 58, height: 38) }
            }
        }
    }
}


/// Colore di selezione (72 % di opacità) del pallino `index` per l'intensità data: agisce sulla saturazione, non sulla
/// luminosità (0 = molto tenue, 0,5 = colore originale, 1 = massima saturazione). Tinta e luminosità restano quelle del pallino.
fileprivate func selectionTonedColor(_ index: Int, _ tone: Double) -> Color {
    let swatch = AppSettings.highlightSwatches[index]
    var value: UInt64 = 0
    Scanner(string: swatch.hex).scanHexInt64(&value)
    let ns = NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                     blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    var h: CGFloat = 0, sat: CGFloat = 0, br: CGFloat = 0, al: CGFloat = 0
    ns.getHue(&h, saturation: &sat, brightness: &br, alpha: &al)
    let t = CGFloat(tone)
    // Colore senza tinta (grafite): la saturazione non ha effetto (e salendo tenderebbe al rosso), quindi la barra va
    // dal grigio quasi bianco (0) al grigio quasi nero (1), passando dal grafite originale a metà.
    if sat < 0.05 {
        let grey = t < 0.5 ? br + (0.93 - br) * ((0.5 - t) * 2) : br - (br - 0.12) * ((t - 0.5) * 2)
        return Color(.sRGB, white: Double(grey), opacity: 0.72)
    }
    // Sotto la metà si smorza la saturazione (fino al 12 % dell'originale); sopra si sale verso il massimo.
    let newSat = t < 0.5 ? sat * (0.12 + 0.88 * (t / 0.5)) : sat + (1 - sat) * ((t - 0.5) * 2)
    return Color(hue: Double(h), saturation: Double(newSat), brightness: Double(br), opacity: 0.72)
}

/// Pallino e tonalità attivi: quelli salvati se corrispondono al colore attuale; altrimenti si riconosce un colore fisso.
fileprivate func selectionActive(current: Color, storedBase: Int, storedTone: Double) -> (index: Int, tone: Double)? {
    let hex = current.toHex().prefix(6)
    if storedBase >= 0, storedBase < AppSettings.highlightSwatches.count,
       selectionTonedColor(storedBase, storedTone).toHex().prefix(6) == hex { return (storedBase, storedTone) }
    for i in AppSettings.highlightSwatches.indices where selectionTonedColor(i, 0.5).toHex().prefix(6) == hex { return (i, 0.5) }
    return nil
}

/// Didascalia sotto il titolo: «Colore di selezione principale: Blu».
private struct SelectionColorCaption: View {
    @ObservedObject var settings: AppSettings
    @AppStorage("highlight_base") private var storedBase = -1
    @AppStorage("highlight_tone") private var storedTone = 0.5

    var body: some View {
        if let a = selectionActive(current: settings.highlightColor, storedBase: storedBase, storedTone: storedTone) {
            Text(t("settings_highlight_primary", t(AppSettings.highlightSwatches[a.index].nameKey)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

/// Scelta del colore di selezione: una fila di pallini con i colori fissi (distribuiti su tutta la larghezza) e,
/// sotto, una barra per variare la tonalità del colore scelto da chiara a scura.
/// La scelta attiva ha un anello e il suo nome compare sotto il pallino.
private struct SelectionColorSwatches: View {
    @ObservedObject var settings: AppSettings
    /// Colore base scelto e posizione sulla barra (0 = chiaro, 0,5 = colore originale, 1 = scuro).
    @AppStorage("highlight_base") private var storedBase = -1
    @AppStorage("highlight_tone") private var storedTone = 0.5

    private var active: (index: Int, tone: Double)? {
        selectionActive(current: settings.highlightColor, storedBase: storedBase, storedTone: storedTone)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(AppSettings.highlightSwatches.indices, id: \.self) { index in
                    let swatch = AppSettings.highlightSwatches[index]
                    let selected = active?.index == index
                    Button {
                        storedBase = index
                        // Cambiando colore si mantiene la tonalità scelta.
                        let tone = active?.tone ?? 0.5
                        storedTone = tone
                        settings.highlightColor = selectionTonedColor(index, tone)
                    } label: {
                        Circle()
                            .fill(Color(hex: swatch.hex + "FF") ?? .gray)
                            .frame(width: 24, height: 24)
                            .modifier(SwatchRing(selected: selected))
                    }
                    .buttonStyle(.plain)
                    .help(t(swatch.nameKey))
                    if index < AppSettings.highlightSwatches.count - 1 { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, 8)   // stesso margine delle altre barre

            if let a = active {
                ToneSlider(from: selectionTonedColor(a.index, 0).opacity(1), mid: selectionTonedColor(a.index, 0.5).opacity(1), to: selectionTonedColor(a.index, 1).opacity(1),
                           value: Binding(get: { a.tone }, set: { v in
                    let tone = (v * 40).rounded() / 40
                    storedBase = a.index
                    storedTone = tone
                    settings.highlightColor = selectionTonedColor(a.index, tone)
                }))
                .frame(height: 22)
            } else {
                // Colore non riconducibile a un pallino (profilo precedente): la barra riparte dal primo clic su un pallino.
                Color.clear.frame(height: 22)
            }
        }
    }
}

/// Barra della tonalità: sfumatura da chiaro a scuro con un pomello ad anello (margine di 8 pt per lato, come le altre barre).
private struct ToneSlider: View {
    let from: Color
    let mid: Color
    let to: Color
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 8
            let span = max(geo.size.width - 2 * inset, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: [from, mid, to], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 14)
                    .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                Circle()
                    .fill(Color.clear)
                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
                    .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5).padding(-1.5))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: 20, height: 20)
                    .offset(x: inset + span * CGFloat(value) - 10)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = min(max(Double((g.location.x - inset) / span), 0), 1)
            })
        }
        .help(t("settings_highlight_tone_help"))
    }
}

/// Anello attorno al pallino scelto (il nome è nella didascalia sotto il titolo).
private struct SwatchRing: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if selected {
                    Circle().stroke(Color.accentColor, lineWidth: 2.5).padding(-4)
                }
            }
    }
}


/// Foglio di creazione di una libreria «Unità esterna»: con un dispositivo noto (collegato, o l'unico registrato) avvisa che
/// il catalogo sarà per quel dispositivo; altrimenti elenca i dispositivi registrati (nome e formati) per sceglierne uno.
private struct DriveSetupSheet: View {
    let url: URL
    let choices: [DriveDeviceChoice]
    let automatic: DriveDeviceChoice?
    let onCreate: (DriveDeviceChoice) -> Void
    let onCancel: () -> Void
    @State private var selected: String?

    private var device: DriveDeviceChoice? { automatic ?? choices.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("drive_setup_title")).font(.headline)
            Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let automatic {
                Text(t(automatic.connected ? "drive_setup_connected" : "drive_setup_single", automatic.name, automatic.formatsText))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(t("drive_setup_pick")).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 0) {
                    Text(t("drive_col_device")).frame(width: 190, alignment: .leading)
                    Text(t("drive_col_formats")).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.bold()).padding(.horizontal, 8)
                List(choices, selection: $selected) { choice in
                    HStack(spacing: 0) {
                        Text(choice.name).frame(width: 190, alignment: .leading)
                        Text(choice.formatsText).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(height: 130)
            }
            Text(t("drive_setup_note")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(t("button_cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(t("drive_create")) { if let device { onCreate(device) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(device == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
