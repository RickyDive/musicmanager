import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @ObservedObject private var loc = LocalizationManager.shared
    /// Osservata perché la voce "Fix Artwork" del menu contestuale compare solo con la funzione
    /// attiva in Impostazioni, e deve apparire/sparire non appena la si accende o spegne.
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var reach = LibraryReachability.shared
    @ObservedObject private var remoteLoader = RemoteLibraryManager.shared
    @State private var confirmDelete = false
    @State private var showDeleteSheet = false
    /// 2.1 Beta 3 (diagnostica): navigatore dei file del dispositivo, sola lettura.
    @State private var showDeviceFiles = false
    /// Trascinamento di file audio (da Finder, non da Music) sul pannello del dispositivo.
    @State private var isDropTargeted = false
    @State private var droppedAudio: DroppedAudioInfo?
    @State private var importPanel: DroppedImportPayload?
    @State private var confirmEmptyMusic = false
    /// Messaggio di benvenuto: una sola volta per installazione (chi aveva già visto quello delle beta non lo rivede).
    @State private var showWelcome = false
    /// Finestra a schermo intero (aggiornata dalle notifiche della finestra): serve allo sfondo, vedi `containerBackground`.
    @State private var isFullScreen = false
    // Centro notifiche (campanella nella barra del titolo)
    @State private var showNotices = false
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool

    /// Altezza dei controlli che, lato dispositivo, precedono l'elenco Playlist/Artisti/Album/
    /// Brani (storage, barra della memoria, modalità Musica/File): usando la stessa altezza per
    /// il mini player lato Apple Music, le due righe del selettore Playlist/Artisti/Album/Brani
    /// restano allineate graficamente tra i due riquadri.
    private let topReservedHeight: CGFloat = 132
    /// Altezza fissa della riga del titolo in cima ai due pannelli (Apple Music e Device): senza,
    /// il pulsante Connetti/Disconnetti rende la riga del Device più alta e i pannelli disallineati.
    private let titleRowHeight: CGFloat = 24

    /// Testo della conferma di eliminazione: per le playlist indica quanti brani vengono eliminati
    /// sul totale e quanti restano perché presenti in altre playlist.
    private var deleteAlertMessage: String {
        guard !vm.selectedDevicePlaylistFileIDs.isEmpty else { return t("alert_delete_message") }
        let plan = vm.deviceDeletionPlan
        if plan.kept == 0 { return t("alert_delete_playlists_message_all", plan.items.count) }
        return t("alert_delete_playlists_message", plan.items.count, plan.items.count + plan.kept, plan.kept)
    }

    /// Contenuto principale con sfondo e barra del titolo (separato da `body` perché la catena di modificatori,
    /// con il centro notifiche, era troppo lunga per il compilatore).
    private var framedContent: some View {
        VStack(spacing: 0) {
            // Due metà identiche e fisse: con HSplitView la larghezza dei riquadri cambiava in base
            // al contenuto della scheda scelta (es. Custom Playlist), qui no. Con due `frame` elastici
            // la metà con il selettore più largo (Apple Music: 5 schede) poteva comunque prendere più
            // spazio dell'altra, e la barra dei selettori risultava di lunghezza diversa nel Device:
            // `containerRelativeFrame` assegna a ciascuna esattamente metà finestra (meno il divisore da 1 pt).
            //: larghezze esplicite da `GeometryReader` (ricalcolate a ogni cambio di dimensione). Con
            // `containerRelativeFrame` all'apertura, mentre la finestra veniva adattata allo schermo, il
            // pannello Music poteva restare con la misura iniziale (più largo/stretto del Device).
            GeometryReader { geo in
                let half = ((geo.size.width - 1) / 2).rounded(.down)
                let _ = updateCompact(half)
                HStack(spacing: 0) {
                    musicPane
                        .frame(width: half)
                        .clipped()
                        .simultaneousGesture(TapGesture().onEnded { vm.searchTarget = .music })
                    // Prova: nessuna linea di divisione tra i due pannelli (resta 1 pt di spazio, cosi le
                    // larghezze non cambiano). Per rimetterla: `Divider()` al posto di `Color.clear`.
                    Color.clear.frame(width: 1)
                    devicePane
                        .frame(width: geo.size.width - 1 - half)
                        .clipped()
                        .simultaneousGesture(TapGesture().onEnded { vm.searchTarget = .device })
                }
            }
        }
        // I comandi dei menu raggiungono il view model tramite `MenuState` (non lo osservano: vedi `MenuState`).
        // Minimo: ogni metà (Apple Music / dispositivo) ha almeno 720 pt, abbastanza per schede, selettore libreria,
        // ricerca e «Solo trasferibili» senza tagli.
        // Larghezza fissa (1440) e altezza libera da 530 in su (con «Testo più grande» lo schermo è ~650 pt: la finestra deve poter stare sopra il Dock): il limite di larghezza lo mette `FitWindowToVisibleScreen` sulla finestra
        // (non qui), così a schermo intero il contenuto può espandersi.
        .frame(minWidth: 1024, maxWidth: .infinity, minHeight: 530, maxHeight: .infinity)
        .environment(\.compactPane, compactPane)
        // Capsula attività DENTRO il contenuto, nella fascia del titolo: la larghezza la dà il layout (esatta, sempre aggiornata),
        // a differenza degli elementi della toolbar che macOS non allarga e non ricalcola quando la finestra cambia misura.
        // A sinistra lascia i pulsanti della finestra (a schermo intero no), a destra i quattro pulsanti della toolbar.
        .overlay(alignment: .topLeading) {
            GeometryReader { geo in
                let titleBar = geo.safeAreaInsets.top
                // A schermo intero la barra sta sopra il contenuto (area sicura 0): lì la capsula è un elemento della toolbar (sotto).
                if !isFullScreen {
                activityCapsule
                    .padding(.leading, 108)
                    .padding(.trailing, Self.toolbarButtonsWidth)
                    .offset(y: -(titleBar + Self.capsuleHeight) / 2)
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { windowHeight = $0.height; windowWidth = $0.width; MainWindowMetrics.shared.height = $0.height }
        // All'apertura la finestra occupa l'altezza libera dello schermo (senza barra dei menu né Dock).
        .background(FitWindowToVisibleScreen())
        // Prova "tutta la finestra in vetro": lo sfondo della finestra diventa un materiale traslucido
        // (si intravede ciò che sta dietro), e la barra del titolo si fonde con il contenuto. Gli
        // elenchi hanno lo sfondo nascosto (vedi `CatalogBrowser`), così il vetro si vede ovunque.
        // Per tornare indietro basta togliere queste due righe.
        .containerBackground(for: .window) {
            // Materiale traslucido + uno strato di colore di finestra la cui opacità si regola in
            // Impostazioni ("Opacità finestra"): 0 % = come prima, 100 % = finestra piena.
            ZStack {
                if isFullScreen {
                    // A schermo intero dietro la finestra non c'è nulla da intravedere (solo il nero dello spazio dedicato) e il
                    // materiale traslucido, anche con un foglio sotto, rendeva gli elenchi scuri: qui niente materiale, solo il
                    // foglio grigio pieno del colore di finestra.
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(settings.windowOpacity))
                }
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Centro notifiche: al posto della barra di stato, al centro della barra del titolo c'è il nome dell'app,
        // che per qualche secondo lascia il posto all'ultimo messaggio (o all'operazione in corso, con la rotellina);
        // a destra la campanella apre la cronologia. Per tornare alla barra di stato: ripristinare le copie `.prima-notifiche`.
        // Titolo a sinistra (quello di sistema); a destra una capsula fissa con messaggio, ingranaggio e campanella.
        // Stile Xcode: titolo in grassetto e sotto, più piccolo, l'ultimo messaggio (`navigationSubtitle`); a destra
        // gruppi di pulsanti separati: aggiorna + cerca, impostazioni, notifiche (campanella con il numero dei non letti).
        // Capsula «attività» al centro, come quella di Xcode (prova): il titolo di sistema è nascosto (resta il nome della finestra).
        // Per tornare a titolo + sottotitolo a sinistra: ripristinare `ContentView.swift.prima-capsula-attivita`.
        .navigationTitle("Music Manager")
        .toolbar(removing: .title)
        .toolbar {
            // Segnaposto invisibile al centro: senza elementi a sinistra/centro macOS sposta i pulsanti a sinistra; con questo
            // restano contro il bordo destro. La capsula visibile è l'overlay del contenuto (vedi sopra).
            ToolbarItem(placement: .principal) {
                // A schermo intero la capsula è già un elemento della barra: il segnaposto (380 pt) la farebbe traboccare nel menu «»».
                if !isFullScreen {
                    Color.clear.frame(minWidth: 180, idealWidth: 380, minHeight: 24)
                        .allowsHitTesting(false)
                }
            }
            .sharedBackgroundVisibility(.hidden)
            // Schermo intero: i pulsanti della finestra spariscono e la capsula, come elemento della toolbar a sinistra, ne prende il posto.
            ToolbarItem(placement: .navigation) {
                if isFullScreen {
                    activityCapsule.frame(width: fullScreenCapsuleWidth)
                }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .primaryAction) {
                refreshButton
                searchButton
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { settingsButton }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { noticeBell }
        }
    }

    // Espressioni tolte dalla catena di modificatori di `body` (il compilatore non riusciva a verificarla in tempo ragionevole).
    private var appleConflictShown: Binding<Bool> {
        Binding(get: { vm.pendingSaveToAppleMusicConflict != nil },
                set: { if !$0 { vm.cancelSaveToAppleMusicConflict() } })
    }

    /// Apre il pannello di vetro con il riepilogo dell'invio al dispositivo (fuori dall'aggiornamento della vista).
    private func presentExportPanel() {
        guard let plan = vm.exportPlan else { return }
        onNextRunLoop {
            var sent = false
            GlassModalPresenter.run { close in
                DeviceExportView(plan: plan, onSend: { sent = true; close() }, onCancel: { close() })
            }
            if sent { Task { await vm.confirmDeviceExport() } } else { vm.cancelDeviceExport() }
        }
    }

    /// Apre il pannello di vetro di conferma dell'eliminazione (fuori dall'aggiornamento della vista).
    private func presentDeleteConfirm() {
        let items = vm.deviceDeletionPlan.items
        let playlists = vm.devicePlaylists
        let excluded = Set(vm.selectedDevicePlaylistIDs)
        onNextRunLoop {
            var confirmed = false
            GlassModalPresenter.run { close in
                DeviceDeleteConfirmView(items: items, playlists: playlists, excludedPlaylistIDs: excluded,
                                        onCancel: { close() },
                                        onConfirm: { confirmed = true; close() })
            }
            if confirmed { Task { await vm.deleteSelection() } }
        }
    }

    var body: some View {
        framedContent
        // Forza il ricalcolo dell'intera vista quando la lingua cambia dal pannello Impostazioni
        // (la lingua non è più scelta qui, ma il testo in questa finestra deve comunque aggiornarsi).
        .id(loc.language)
        // Schermo intero: serve a mettere il foglio grigio dietro il vetro (vedi `containerBackground`).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = false }
        // Ritorno nell'app: la libreria di Music si rilegge in silenzio se è cambiata (vedi `refreshLibraryIfNeeded`).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await vm.checkDriveLibraryStillAvailable()
                await vm.refreshLibraryIfNeeded()
            }
        }
        .task {
            await vm.loadLibrary()
        }
        // Connessione automatica se l'orologio risulta già collegato via USB all'apertura
        // dell'app: senza questo, bisognerebbe staccare e riattaccare il cavo (o premere
        // "Connetti" a mano) ogni volta, anche quando il dispositivo era già lì da prima.
        .task { await vm.connectIfDeviceAlreadyPresent() }
        .onAppear {
            let seen = UserDefaults.standard.bool(forKey: "welcome_seen_2_1") || UserDefaults.standard.bool(forKey: "welcome_seen_2_1_beta1")
            if !seen { showWelcome = true }
        }
        .alert(t("welcome_title"), isPresented: $showWelcome) {
            Button(t("button_ok")) { UserDefaults.standard.set(true, forKey: "welcome_seen_2_1") }
        } message: {
            Text(t("welcome_message"))
        }
        // Brani di una libreria condivisa senza copertina da inviare: propone la ricerca online.
        .alert(t("artwork_proposal_title"), isPresented: Binding(
            get: { vm.artworkProposal != nil },
            set: { if !$0 && vm.artworkProposal != nil { vm.answerArtworkProposal(.cancel) } }
        )) {
            Button(t("artwork_proposal_search")) { vm.answerArtworkProposal(.search) }
            Button(t("artwork_proposal_continue")) { vm.answerArtworkProposal(.continueAnyway) }
            Button(t("button_cancel"), role: .cancel) { vm.answerArtworkProposal(.cancel) }
        } message: {
            Text(t("artwork_proposal_message", vm.artworkProposal?.missing.count ?? 0))
        }
        // Apple Music chiusa mentre servono le copertine: chiede se aprirla (in secondo piano).
        .alert(t("music_prompt_title"), isPresented: Binding(
            get: { vm.musicPrompt != nil },
            // Nessuna azione alla chiusura: la risposta la danno solo i due pulsanti (Esc = pulsante di annulla). Prima, se la chiusura
            // dell'avviso arrivava prima dell'azione di «Apri», la domanda risultava «No» e Musica non veniva aperta.
            set: { _ in }
        )) {
            Button(t("music_prompt_open")) { vm.answerMusicPrompt(open: true) }
            Button(vm.musicPrompt == .startup ? t("music_prompt_no") : t("button_cancel"), role: .cancel) {
                vm.answerMusicPrompt(open: false)
            }
        } message: {
            Text(vm.musicPrompt == .startup ? t("music_prompt_startup_message") : t("music_prompt_manual_message"))
        }
        .alert(t("alert_tracks_only_title"), isPresented: $vm.showTracksOnlyFromPlaylistAlert) {
            Button(t("alert_tracks_only_send")) { Task { await vm.sendSelectedTracksToDevice(confirmedPartialPlaylist: true) } }
            Button(t("button_cancel"), role: .cancel) {}
        } message: {
            Text(t("alert_tracks_only_message"))
        }
        .alert(t("alert_partial_playlist_title"), isPresented: $vm.showPartialPlaylistSendAlert) {
            Button(t("alert_partial_playlist_custom")) { vm.addSelectedTracksToCustomPlaylist() }
            Button(t("button_cancel"), role: .cancel) {}
        } message: {
            Text(t("alert_partial_playlist_message"))
        }
        // Tolto da un'altra scheda un brano di una playlist scelta per intero: la playlist non verrà più inviata come playlist.
        .alert(t("alert_playlist_removal_title"), isPresented: Binding(
            get: { vm.playlistRemovalPrompt != nil },
            set: { _ in }   // la chiusura la gestiscono i due pulsanti
        )) {
            Button(t("button_confirm")) { vm.confirmPlaylistRemoval() }
            Button(t("button_cancel"), role: .cancel) { vm.cancelPlaylistRemoval() }
        } message: {
            if let prompt = vm.playlistRemovalPrompt {
                Text(playlistRemovalMessage(subject: prompt.subject, plural: prompt.subjectIsPlural, playlists: prompt.titles))
            }
        }
        .alert(t("alert_empty_library_title"), isPresented: $vm.showEmptyLibraryAlert) {
            Button(t("button_close"), role: .cancel) {}
        } message: {
            Text(t("alert_empty_library_message"))
        }
        .alert(t("alert_delete_title"), isPresented: $confirmDelete) {
            Button(t("button_delete"), role: .destructive) { Task { await vm.deleteSelection() } }
            Button(t("button_cancel"), role: .cancel) {}
        } message: {
            Text(deleteAlertMessage)
        }
        // 2.1 Beta 2: per i brani (anche scelti da Artisti/Album) una finestra con l'elenco di cosa verrà eliminato e delle playlist coinvolte.
        // Pannello modale di vetro (non più uno sheet: si può spostare e il vetro è vero). Si apre fuori dall'aggiornamento della vista.
        .onChange(of: showDeleteSheet) { _, on in
            if on { showDeleteSheet = false; presentDeleteConfirm() }
        }
        .alert(t("alert_empty_music_title"), isPresented: $confirmEmptyMusic) {
            Button(t("button_confirm"), role: .destructive) { Task { await vm.emptyMusicFolder() } }
            Button(t("button_cancel"), role: .cancel) {}
        } message: {
            Text(t("alert_empty_music_message", vm.deviceTitle))
        }
        .alert(t("alert_apple_music_exists_title"), isPresented: appleConflictShown) {
            Button(t("button_replace_playlist")) { vm.confirmReplaceAppleMusicPlaylist() }
            Button(t("button_add_to_playlist")) { vm.confirmAddToExistingAppleMusicPlaylist() }
            Button(t("button_cancel"), role: .cancel) { vm.cancelSaveToAppleMusicConflict() }
        } message: {
            Text(t("alert_apple_music_exists_message", vm.pendingSaveToAppleMusicConflict?.name ?? ""))
        }
        .alert(t("alert_apple_music_duplicates_title"), isPresented: Binding(
            get: { vm.pendingSaveToAppleMusicDuplicates != nil },
            set: { if !$0 { vm.cancelAppleMusicDuplicates() } }
        )) {
            Button(t("button_add_anyway")) { vm.confirmAddAppleMusicDuplicatesAnyway() }
            Button(t("button_skip")) { vm.skipAppleMusicDuplicatesAndAddFresh() }
            Button(t("button_cancel"), role: .cancel) { vm.cancelAppleMusicDuplicates() }
        } message: {
            Text(t("alert_apple_music_duplicates_message", duplicateTracksListText(vm.pendingSaveToAppleMusicDuplicates?.duplicateTracks ?? [])))
        }
        .alert(t("alert_load_full_playlist_title"), isPresented: Binding(
            get: { vm.pendingLoadFullAppleMusicPlaylist != nil },
            set: { if !$0 { vm.declineLoadFullAppleMusicPlaylistIntoCustom() } }
        )) {
            Button(t("button_yes")) { vm.confirmLoadFullAppleMusicPlaylistIntoCustom() }
            Button(t("button_no"), role: .cancel) { vm.declineLoadFullAppleMusicPlaylistIntoCustom() }
        } message: {
            Text(t("alert_load_full_playlist_message", vm.pendingLoadFullAppleMusicPlaylist?.name ?? ""))
        }
        .alert(t("alert_remote_library_title"), isPresented: Binding(
            get: { vm.pendingRemoteNetworkLibrary != nil },
            set: { if !$0 { vm.declineRemoteNetworkLibrary() } }
        )) {
            Button(t("button_yes")) { vm.confirmRemoteNetworkLibrary() }
            Button(t("button_no"), role: .cancel) { vm.declineRemoteNetworkLibrary() }
        } message: {
            Text(t("alert_remote_library_message", vm.pendingRemoteNetworkLibrary?.nickname ?? ""))
        }
        // Svuota Custom Playlist, import di una playlist del dispositivo e nickname: pannelli di vetro (vedi `SimpleGlassPanels`).
        .modifier(SimpleGlassPanels(vm: vm, showImagePicker: $showImagePicker, showMaps: $showMapsSheet, showDeviceFiles: $showDeviceFiles))
        // Le mappe sul dispositivo sono cambiate rispetto a Maps.json (es. installate con Garmin Express).
        .alert(t("alert_maps_changed_title"), isPresented: $vm.mapsChangedProposal) {
            Button(t("button_check_now")) { vm.acceptMapsRecheck() }
            Button(t("button_later"), role: .cancel) {}
        } message: {
            Text(t("alert_maps_changed_message"))
        }
        // Ultimo controllo delle mappe vecchio di oltre 3 mesi: si propone di verificare le novità sui server Garmin.
        .alert(t("alert_maps_recheck_title"), isPresented: Binding(
            get: { vm.mapsRecheckProposalDays != nil },
            set: { if !$0 { vm.mapsRecheckProposalDays = nil } }
        )) {
            Button(t("button_check_now")) { vm.acceptMapsRecheck() }
            Button(t("button_later"), role: .cancel) {}
        } message: {
            Text(t("alert_maps_recheck_message", String(vm.mapsRecheckProposalDays ?? 0)))
        }
        .alert(t("alert_random_to_manual_title"), isPresented: $vm.pendingRandomToManual) {
            Button(t("button_keep_random_as_manual")) { vm.keepRandomOrderAsManual() }
            Button(t("button_restore_previous_manual")) { vm.restorePreviousManualOrder() }
            Button(t("button_cancel"), role: .cancel) {}
        } message: {
            Text(t("alert_random_to_manual_message"))
        }
        // Caricamento da file con Custom già piena: alert nativo (solo per il file; l'import da playlist del device ha il suo foglio).
        .alert(t("alert_file_load_title"), isPresented: Binding(
            get: { vm.pendingFileLoad != nil && vm.pendingFileLoad?.fromDevice != true },
            set: { if !$0 && vm.pendingFileLoad?.fromDevice != true { vm.cancelFileLoad() } }
        )) {
            Button(t("button_load_replace"), role: .destructive) { vm.resolveFileLoad(.replace) }
            Button(t("button_load_current_after")) { vm.resolveFileLoad(.currentAfterSaved) }
            Button(t("button_load_saved_after")) { vm.resolveFileLoad(.savedAfterCurrent) }
            Button(t("button_cancel"), role: .cancel) { vm.cancelFileLoad() }
        } message: {
            Text(t("alert_file_load_message", vm.pendingFileLoad?.name ?? ""))
        }
        .alert(t("alert_file_overwrite_title"), isPresented: Binding(
            get: { vm.pendingFileOverwriteName != nil },
            set: { if !$0 { vm.cancelFileOverwrite() } }
        )) {
            Button(t("button_replace"), role: .destructive) { vm.confirmFileOverwrite() }
            Button(t("button_cancel"), role: .cancel) { vm.cancelFileOverwrite() }
        } message: {
            Text(t("alert_file_overwrite_message", vm.pendingFileOverwriteName ?? ""))
        }
        .alert(t("alert_clear_custom_playlist_title"), isPresented: Binding(
            get: { vm.pendingWholePlaylistSend != nil },
            set: { if !$0 { vm.cancelWholePlaylistSend() } }
        )) {
            Button(t("button_empty_and_send"), role: .destructive) { vm.confirmClearAndSendWholePlaylist() }
            Button(t("button_append_without_clearing")) { vm.confirmAppendWholePlaylistWithoutClearing() }
            Button(t("button_cancel"), role: .cancel) { vm.cancelWholePlaylistSend() }
        } message: {
            Text(t("alert_clear_custom_playlist_message", vm.pendingWholePlaylistSend?.playlistTitle ?? ""))
        }
        .onChange(of: settings.remoteLibraries) { _, libs in
            // Libreria remota attiva rimossa (o resa non usabile) dalle Impostazioni: si torna alla locale.
            if let id = vm.externalLibraryID, !vm.isDriveLibraryActive, !libs.contains(where: { $0.id == id && $0.isUsable }) {
                Task { await vm.showLocalLibrary() }
            }
        }
        .onChange(of: settings.driveLibraries) { _, libs in
            // Libreria «Unità esterna» a schermo rimossa dalle Impostazioni: si torna alla locale.
            if let id = vm.externalLibraryID,
               settings.remoteLibraries.contains(where: { $0.id == id }) == false, !libs.contains(where: { $0.id == id }) {
                Task { await vm.showLocalLibrary() }
            }
        }
        .alert(t("drive_rescan_title"), isPresented: Binding(
            get: { vm.driveRescanProposal != nil },
            set: { if !$0 { vm.declineDriveRescan() } }
        )) {
            Button(t("drive_rescan_for", vm.driveRescanProposal?.target.name ?? "")) { vm.confirmDriveRescan() }
            Button(t("drive_keep"), role: .cancel) { vm.declineDriveRescan() }
        } message: {
            Text(t("drive_rescan_message", vm.driveRescanProposal?.library.nickname ?? "",
                   vm.driveRescanProposal?.library.deviceName ?? "", vm.driveRescanProposal?.target.name ?? ""))
        }
        // L'avanzamento delle eliminazioni è nell'anello rosso della capsula; i pulsanti restano bloccati da `isBusy`.
        // Riepilogo prima dell'invio: pannello modale di vetro (non più uno sheet). Si chiude con Invia / Annulla.
        .onChange(of: vm.exportPlan?.id) { _, id in
            if id != nil { presentExportPanel() }
        }
        // In fondo alla catena (dopo tutti i `.sheet`): l'ambiente raggiunge solo ciò che sta DENTRO il modificatore, e i fogli
        // sono presentati dalle viste interne; messo prima dei `.sheet` i fogli leggevano 0 e restavano a misura fissa.
        .environment(\.windowHeight, windowHeight)
    }

    // MARK: - Pannello Apple Music

    /// Menu contestuale (click destro) sulle righe delle schede Playlist/Artisti/Album/Brani:
    /// le azioni sono le stesse dei pulsanti in fondo al pannello (stessi controlli), vedi
    /// `CatalogBrowser.RowMenu`.
    private var appleRowMenu: CatalogBrowser<LocalTrack>.RowMenu {
        CatalogBrowser<LocalTrack>.RowMenu(
            canSendToDevice: vm.device != nil && !vm.isDeviceReadOnly,
            canFixArtwork: settings.lookupMissingArtworkOnline,
            isBusy: vm.isBusy,
            sendToDevice: { Task { await vm.sendSelectedTracksToDevice() } },
            sendToPlaylist: { vm.addSelectedTracksToCustomPlaylist() },
            fixArtwork: { vm.startFixArtwork() },
            findSimilar: { vm.findSimilar(to: $0) }
        )
    }

    /// Riga di stato del pannello Music; col filtro «senza copertina» aggiunge quanti brani ne sono sprovvisti.
    private var summaryWithCoverCount: String {
        guard vm.appleCategory == .songs, let count = vm.coverFilterCount else { return vm.selectionSummaryText }
        return vm.selectionSummaryText + " · " + t("n_without_cover", count)
    }

    private var musicPane: some View {
        // Liquid Glass: l'elenco occupa tutto il riquadro e scorre SOTTO la zona alta (titolo,
        // mini player, selettore schede, ricerca) e SOTTO la barra dei pulsanti in basso; le due
        // zone sono "barre" trasparenti (`safeAreaBar`, vedi `CatalogBrowser`) con l'effetto di
        // sfumatura/vetro ai bordi di scorrimento di macOS 26.
            CatalogBrowser(tracks: vm.visibleTracks,
                           playlists: vm.visiblePlaylists,
                           category: $vm.appleCategory,
                           selection: $vm.selectedTrackIDs,
                           emptyMessage: t("empty_apple_music"),
                           rowMenu: appleRowMenu,
                           artworkRevision: vm.artworkRevision,
                           artworkProvider: vm.appleArtwork,
                           artworkOriginProvider: vm.artworkOrigin,
                           onPlay: { track, queue, source in vm.play(track, queue: queue, source: source) },
                           playingTrackID: vm.playerTrack?.id,
                           player: vm.player,
                           playingSource: vm.playbackSource,
                           availableCategories: CatalogCategory.allCases,
                           customPlaylist: vm.customPlaylistConfig)
        .externalReveal($vm.externalReveal)
        .genreFilter()
        .typeAheadFirstLetterOnly(vm.externalLibraryName != nil)   // librerie remote / unità esterne: solo la prima lettera
        .toolbarSearch($vm.musicSearch, custom: $vm.customPlaylistSearch)
        .onRequestArtwork { vm.loadMissingArtwork(for: $0, manual: $1) }
        .onCoverFilterCount { vm.coverFilterCount = $0 }
        .wholePlaylistSelection { vm.wholePlaylistSelectionID = $0 }
        .onSelectedPlaylistsChange { vm.selectedApplePlaylistIDs = $0 }
        .onPlaylistCompletedBySongs { vm.status = "ℹ️ " + t("status_playlist_completed_by_songs", $0) }
        .onDeviceCheck { vm.isOnDevice($0) }
        .onPlaylistMembership { vm.playlistsContaining($0) }
        .onPlaylistDeviceCheck { vm.isPlaylistOnDevice($0) }
        .topAccessory {
            VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label {
                                    Text("Music")
                                } icon: {
                                    Image(systemName: "music.note.square.stack").foregroundStyle(statusIconRed)   // Music: rosso
                                }
                                .font(.headline)
                                Spacer()
                            }
                            // Stessa altezza della riga titolo del Device (che ha il pulsante), così i due
                            // pannelli sono alti uguale e la riga della ricerca resta allineata.
                            .frame(height: titleRowHeight)

                            // Mini player: stessa altezza dei controlli di storage/modalità del dispositivo, cosi
                            // la riga Playlist/Artisti/Album/Brani resta allineata con quella del dispositivo.
                            // Si avvia facendo doppio click su un brano dell'elenco qui sotto.
                            MiniPlayerView(player: vm.player,
                                           track: vm.playerTrack,
                                           artwork: vm.playerArtwork,
                                           onTogglePlayPause: { vm.togglePlayPause() },
                                           onNext: { vm.playNextInQueue() },
                                           onPrevious: { vm.playPreviousInQueue() },
                                           onSeek: { vm.seekPlayer(to: $0) },
                                           playlistName: vm.playbackSource?.name,
                                           playlistIcon: vm.playbackSource?.iconName ?? "music.note.list",
                                           queue: vm.playOrder,
                                           queuePosition: vm.playOrderPos,
                                           isShuffle: $vm.isShuffleOn,
                                           isRepeat: $vm.isRepeatOn,
                                           onJump: { vm.jumpToQueuePosition($0) },
                                           onSendToCustom: { if let tr = vm.playerTrack { vm.addTracksToCustomPlaylist([tr]) } },
                                           onSendToWatch: { if let tr = vm.playerTrack { Task { await vm.sendTracksToDevice([tr]) } } },
                                           canSendToWatch: vm.device != nil && !vm.isDeviceReadOnly,
                                           canFixArtwork: settings.lookupMissingArtworkOnline,
                                           onFixArtwork: { if let tr = vm.playerTrack { vm.startFixArtwork(for: [tr]) } },
                                           onGoToAlbum: { if let tr = vm.playerTrack { vm.externalReveal = ExternalRevealRequest(trackID: tr.id, target: .albums) } },
                                           onGoToArtist: { if let tr = vm.playerTrack { vm.externalReveal = ExternalRevealRequest(trackID: tr.id, target: .artists) } },
                                           onFindSimilar: { if let tr = vm.playerTrack { vm.findSimilar(to: [tr]) } },
                                           playlistsContaining: vm.playerTrack.map { vm.playlistsContaining($0) } ?? [],
                                           onShowInPlaylist: { id in if let tr = vm.playerTrack { vm.externalReveal = ExternalRevealRequest(trackID: tr.id, target: .playlists, playlistID: id) } },
                                           isBusy: vm.isBusy,
                                           originProvider: { await vm.artworkOrigin(for: $0) },
                                           artworkRevision: vm.artworkRevision,
                                           isOnDevice: vm.playerTrack.map { vm.isOnDevice($0) } ?? false,
                                           isInPlaylist: vm.playerTrack.map { !vm.playlistsContaining($0).isEmpty } ?? false,
                                           height: topReservedHeight)
            }
        }
        // Selettore della libreria (locale o condivisa in rete, sola consultazione), a destra
        // sulla riga delle schede.
        .categoryAccessory {
            HStack(spacing: 6) {
            // Libreria «Unità esterna» a schermo: pulsante «Espelli» (torna alla libreria locale e smonta l'unità).
            // Compare solo quando serve e non riserva più spazio: le capsule dei pannelli hanno larghezza fissa
            // (vedi `glassBars`), quindi la larghezza del pannello non cambia passando da una libreria all'altra.
            let canEject = vm.isDriveLibraryActive && vm.driveLibraryVolumeURL != nil
            if canEject {
                Button { Task { await vm.ejectDriveLibrary() } } label: { accessoryIcon("eject.fill") }
                    .buttonStyle(.flat)
                    .disabled(vm.isBusy)
                    .help(t("drive_eject_help"))
            }
            Menu {
                // Le voci usano l'inizializzatore con `systemImage` e lo stile «titolo + icona»: con un `Label` dentro
                // la chiusura dell'etichetta, i menu di macOS mostravano solo il testo.
                Button((vm.externalLibraryName != nil ? "" : "✓ ") + t("library_local"),
                       systemImage: "laptopcomputer") {
                    Task { await vm.showLocalLibrary() }
                }
                .labelStyle(.titleAndIcon)
                Divider()
                let remotes = settings.remoteLibraries.filter(\.isUsable)
                if remotes.isEmpty && settings.driveLibraries.isEmpty {
                    Text(t("library_none_found"))
                }
                ForEach(remotes) { cfg in
                    let isRemote = vm.locality(of: cfg) == .remote
                    let unreachable = reach.isUnreachable(cfg.id)
                    // Server non raggiungibile: icona «network.slash» e voce non selezionabile. Altra rete (raggiungibile,
                    // es. via VPN): mondo e avviso alla scelta. Rete locale: drive di rete.
                    Button((vm.externalLibraryID == cfg.id ? "✓ " : "") + cfg.nickname
                           + (unreachable ? " — " + t("library_unreachable")
                              : (isRemote ? " — " + t("library_other_network") : "")),
                           systemImage: unreachable ? "network.slash"
                               : (isRemote ? "network" : "externaldrive.connected.to.line.below")) {
                        Task { await vm.requestRemoteLibrary(cfg) }
                    }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(unreachable ? Color.red : Color.primary)
                    .disabled(unreachable)
                }
                // Librerie «Unità esterna» (cartella di file audio con indice proprio).
                let drives = settings.driveLibraries.filter { !$0.nickname.isEmpty }
                if !drives.isEmpty {
                    Divider()
                    ForEach(drives) { cfg in
                        let available = DriveLibraryService.rootURL(cfg) != nil
                        Button((vm.externalLibraryID == cfg.id ? "✓ " : "") + cfg.nickname
                               + (available ? "" : " — " + t("library_unavailable")),
                               systemImage: available ? "externaldrive" : "externaldrive.badge.xmark") {
                            // Scansione incrementale a ogni apertura: i file aggiunti o tolti sul drive compaiono subito (solo i file nuovi si rileggono).
                            Task { await vm.selectDriveLibrary(cfg, rescan: true) }
                        }
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(available ? Color.primary : Color.red)
                        .disabled(!available)
                    }
                }
            } label: {
                Label(shortLibraryName(vm.externalLibraryName ?? t("library_local")),
                      systemImage: vm.externalLibraryName == nil ? "laptopcomputer"
                          : vm.isDriveLibraryActive ? "externaldrive"
                          : (settings.remoteLibraries.first { $0.id == vm.externalLibraryID }
                                .map { vm.locality(of: $0) == .remote } == true
                             ? "network" : "externaldrive.connected.to.line.below"))
                // Larghezza fissa: il pulsante non si allarga né si stringe cambiando sorgente. Una sola riga: se il nome
                // è più lungo si taglia con «…».
                .lineLimit(1)
                .truncationMode(.tail)
                .labelStyle(CompactAwareLabelStyle())
                .frame(width: compactPane ? nil : 130, alignment: .leading)
            }
            .menuStyle(.button)
            .disabled(vm.isBusy)
            .help(t("library_menu_help"))
            }
        }
        // (Il pulsante di aggiornamento è nella barra del titolo, vedi `refreshButton`.)
        .bottomBar {
                        HStack {
                            if vm.appleCategory == .customPlaylist {
                                // Salvataggio / caricamento della playlist come file M3U8 (Musica/MusicManager/Custom Lib).
                                // Pulsante doppio (Carica | Salva): «Carica» sempre attivo, «Salva» solo con almeno un brano e un titolo.
                                LoadSaveSplitButton(width: barButtonWidth, canSave: !isCustomPlaylistEmptyOrUnnamed, busy: vm.isBusy,
                                                    onLoad: { vm.loadCustomPlaylistFromFile() },
                                                    onSave: { vm.saveCustomPlaylistToFile() })

                                Button {
                                    vm.customPlaylistConfig.onSaveToAppleMusic()
                                } label: { Label(t("button_save_to_apple_music"), systemImage: "music.note.list").labelStyle(CompactAwareLabelStyle()).frame(width: barButtonWidth) }
                                .buttonStyle(.flat)
                                // Con una libreria «Unità esterna» a schermo il salvataggio in Music non c'è: quelle librerie non hanno legami con Music.
                                .disabled(isCustomPlaylistEmptyOrUnnamed || vm.isDriveLibraryActive)
                                .help(vm.isDriveLibraryActive ? t("tooltip_save_to_music_drive") : t("tooltip_save_to_music"))

                                // «Svuota» è il terzo pulsante, dopo «Salva in Musica»: «Invia» resta ultimo a destra come negli altri pannelli.
                                Button(role: .destructive) {
                                    vm.customPlaylistConfig.onClear()
                                } label: { Label(t("button_clear_custom_playlist"), systemImage: "trash").labelStyle(CompactAwareLabelStyle()).frame(width: barButtonWidth) }
                                .buttonStyle(.flat)
                                .disabled(vm.customPlaylistEntries.isEmpty || vm.isBusy)
                                .help(t("tooltip_clear_playlist"))
                            } else {
                                // "Pulisci selezione" e "Invia alla Playlist" agiscono sulla selezione corrente,
                                // condivisa tra le schede Playlist/Artisti/Album/Brani: non toccano la Custom
                                // Playlist stessa, quindi non hanno senso quando quella scheda è aperta (sopra).
                                Button {
                                    vm.clearSelection()
                                } label: { Label(t("button_clear_selection"), systemImage: "xmark.circle").labelStyle(CompactAwareLabelStyle()).frame(width: barButtonWidth) }
                                .disabled(vm.selectedTrackIDs.isEmpty || vm.isBusy)
                                .help(t("tooltip_clear_selection"))

                                Button {
                                    vm.addSelectedTracksToCustomPlaylist()
                                } label: { Label(t("button_send_to_playlist"), systemImage: "tray.and.arrow.down").labelStyle(CompactAwareLabelStyle()).frame(width: barButtonWidth) }
                                .disabled(vm.selectedTrackIDs.isEmpty || vm.isBusy)
                                .help(t("tooltip_send_to_playlist"))
                            }

                            Spacer()
                            // Nella Custom Playlist numero di brani e durata sono già accanto al nome: qui nulla.
                            if vm.appleCategory != .customPlaylist {
                                Text(summaryWithCoverCount)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)   // due righe quando sono scelte più playlist
                            }

                            if vm.appleCategory == .customPlaylist {
                                if vm.device != nil {
                                    Button {
                                        vm.customPlaylistConfig.onSendToWatch()
                                    } label: { HStack(spacing: 6) { if !compactPane { Text(t("button_send")) }; Image(systemName: "arrow.right.circle.fill") }.frame(width: barButtonWidth) }
                                    // Stesso aspetto degli altri pulsanti della barra della Custom Playlist (Carica/Salva, Salva in Musica, Svuota).
                                    .buttonStyle(.flat)
                                    .disabled(isCustomPlaylistEmptyOrUnnamed || vm.isDeviceReadOnly || vm.pendingExceedsFreeSpace)
                                    // Spazio insufficiente: come nelle altre schede, testo rosso e pulsante disattivato con la spiegazione.
                                    .foregroundStyle(vm.pendingExceedsFreeSpace ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                                    .help(vm.pendingExceedsFreeSpace ? t("storage_pending_exceeds") : t("tooltip_send_to_device"))
                                }
                            } else {
                                if vm.device != nil {
                                    Button {
                                        Task { await vm.sendSelectedTracksToDevice() }
                                    } label: { HStack(spacing: 6) { if !compactPane { Text(t("button_send")) }; Image(systemName: "arrow.right.circle.fill") }.frame(width: barButtonWidth) }
                                    .disabled(vm.selectedTrackIDs.isEmpty || vm.isBusy || vm.isDeviceReadOnly || vm.pendingExceedsFreeSpace)
                                    // Spazio insufficiente: pulsante rosso come la barra della memoria e disattivato, con la spiegazione.
                                    .foregroundStyle(vm.pendingExceedsFreeSpace ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                                    .help(vm.pendingExceedsFreeSpace ? t("storage_pending_exceeds") : t("tooltip_send_to_device"))
                                }
                            }
                        }
        }
        // Avviso non bloccante mentre si leggono le copertine da Musica (con librerie grandi può durare).
        .overlay(alignment: .center) {
            if vm.isLoadingArtwork {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(t(vm.isDriveLibraryActive ? "artwork_loading_notice_drive" : (vm.externalLibraryName != nil ? "artwork_loading_notice_shared" : "artwork_loading_notice"))).font(.callout)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 8, y: 2)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.isLoadingArtwork)
    }


    /// Larghezza uguale per tutti i pulsanti della barra in basso di Apple Music (Svuota playlist /
    /// Pulisci selezione, Salva in Apple Music / Invia alla Playlist, Invia all'orologio): quella
    /// dell'etichetta più lunga fra tutti (nella lingua corrente) + icona + margine, così passando da
    /// una scheda all'altra i pulsanti restano identici.
    private var barButtonWidth: CGFloat { compactPane ? 40 : mainBarButtonWidth() }
    /// Modalità compatta: metà pannello sotto i 700 pt (finestra < ~1400 pt; a 1440 ogni metà è 719 pt: resta in modalità normale) → solo icone.
    @State private var compactPane = false
    /// Altezza del contenuto della finestra: i fogli a misura fissa si adattano (vedi `SheetFrame`).
    @State private var windowHeight: CGFloat = 0
    /// Larghezza del contenuto della finestra: serve a dare alla capsula del titolo la larghezza che resta (la barra di macOS non allarga da sola gli elementi).
    @State private var windowWidth: CGFloat = 0
    private func updateCompact(_ half: CGFloat) {
        let c = half < 700
        if c != compactPane { DispatchQueue.main.async { compactPane = c } }
    }

    /// Condizione comune a "Salva in Apple Music" e "Invia all'orologio" per la Custom Playlist:
    /// serve un nome, almeno un brano, e nessun'altra operazione già in corso. "Invia
    /// all'orologio" aggiunge anche il bisogno di un dispositivo connesso (vedi sopra).
    private var isCustomPlaylistEmptyOrUnnamed: Bool {
        vm.customPlaylistEntries.isEmpty
            || vm.customPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty
            || vm.isBusy
    }

    // MARK: - Pannello dispositivo

    /// Zona alta del pannello dispositivo, con la STESSA struttura di quella Apple Music: riga del
    /// titolo (con Connetti/Disconnetti), poi un riquadro alto `topReservedHeight` con a sinistra
    /// un'icona quadrata (come la copertina del mini player) e a destra i controlli di storage; sotto, il selettore Playlist/Artisti/Album/Brani e la ricerca li aggiunge
    /// `CatalogBrowser`. Nessun vetro proprio: il vetro è quello del pannello in `glassBars`.
    private var deviceTopBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label {
                    Text(vm.deviceTitle)
                } icon: {
                    Image(systemName: "watch.analog").foregroundStyle(statusIconGreen)   // dispositivo: stesso verde delle altre icone «dispositivo»
                }
                .font(.headline)
                Spacer()
                if vm.deviceBusy {
                    ProgressView().controlSize(.small)
                }
                // 2.1 Beta 3 (solo diagnostica): apre un navigatore dei file del dispositivo, in sola lettura.
                if vm.device != nil, settings.showDeviceFileManager {
                    Button { showDeviceFiles = true } label: { Image(systemName: "folder").frame(width: 22) }
                        .help(t("tooltip_device_files"))
                        .disabled(vm.isBusy)
                }
                // Eject / Connetti / Disconnetti sono ora sulla riga delle schede (`deviceCategoryControls`).
            }
            // Stesso aspetto dei pulsanti della barra in basso: piatti (senza vetro).
            .buttonStyle(.flat)
            .frame(height: titleRowHeight)

            HStack(spacing: 12) {
                // Immagine del prodotto Garmin connesso (sfondo trasparente, a tutto riquadro con 4 pt di bordo);
                // finché non è pronta, o se non esiste, l'icona predefinita.
                Group {
                    if let image = (vm.device != nil ? vm.deviceImage : (vm.volumeDevices.isEmpty ? nil : vm.volumeDeviceImage)) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    } else {
                        Image(systemName: "watch.analog")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: topReservedHeight, height: topReservedHeight)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .contextMenu {
                    if vm.device != nil || !vm.volumeDevices.isEmpty {
                        Button(t("menu_choose_device_image")) { showImagePicker = true }
                        if vm.hasImageOverride {
                            Button(t("menu_auto_device_image")) { vm.chooseDeviceImage(nil) }
                        }
                    }
                }

                if let device = vm.device {
                    VStack(alignment: .leading, spacing: 0) {
                        // In alto a sinistra: dati letti da GarminDevice.xml.
                        deviceInfoLines

                        // Lo spazio libero sta tra le righe in alto e il blocco in basso.
                        Spacer(minLength: 4)

                        // In basso, senza spazi tra le parti e allineato al bordo inferiore del riquadro dell'immagine:
                        // barra della memoria (solo storage interno) con la sua didascalia, poi i conteggi.
                        VStack(alignment: .leading, spacing: 2) {
                            if vm.isSelectedStorageInternal, let s = device.storages.first(where: { $0.id == vm.selectedStorageID }) {
                                StorageBarView(total: s.capacity, garmin: vm.garminFolderSize, maps: vm.mapsSize,
                                               services: vm.servicesSize, music: vm.musicFolderSize, free: s.free, pending: vm.pendingTransferBytes,
                                               isLoading: vm.isLoadingStorageBreakdown, unsupported: vm.isDeviceReadOnly)
                                // Filo sottilissimo, del colore dei testi, tra la legenda e i conteggi; largo come la barra.
                                // Senza musica (dispositivo non supportato) né il filo né i conteggi.
                                if !vm.isDeviceReadOnly { Rectangle().fill(Color.secondary).frame(height: 0.5) }
                            }
                            if !vm.isDeviceReadOnly {
                                Text(deviceCountsText)
                                    .font(.caption).foregroundStyle(StorageBarView.textColor)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if let volume = vm.volumeDevices.first {
                    volumeDeviceInfo(volume)
                } else {
                    TwoLineHint(text: t("placeholder_connect_device"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: topReservedHeight)
            .padding(.horizontal, 10).padding(.top, 3).padding(.bottom, 10.5)   //: sotto +7,5 pt (come nel mini player di Music)
        }
    }

    /// Dispositivo Garmin visto come disco esterno (2.1 Beta 2, fase 1): solo informazioni ed Espelli.
    private func volumeDeviceInfo(_ volume: VolumeDevice) -> some View {
        let free = ByteCountFormatter.string(fromByteCount: volume.freeBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: volume.totalBytes, countStyle: .file)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                infoLine("Model", volume.info.description)
                if !volume.isMusicCapable {
                    updateCapsule(t("device_no_music_capsule"), color: Color(red: 0.937, green: 0.604, blue: 0.604))
                        .help(t("tooltip_device_not_music_capable"))
                }
                if vm.volumeMapsAvailable {
                    Button { Task { await vm.ensureVolumeMaps(); showMapsSheet = true } } label: {
                        Image(systemName: "map").font(.system(size: 12))
                            .foregroundStyle(mapsGlobeColor(catalog: vm.volumeMaps, checkedAt: vm.volumeMapsCheckedAt))
                    }
                    .buttonStyle(.plain)
                    .help(t("tooltip_maps_info"))
                } else if vm.volumeRoutesOnly {
                    routesOnlyIcon
                }
            }
            softwareVersionLine(formattedSoftwareVersion(volume.info.softwareVersion), status: vm.volumeSoftwareStatus)
            infoLine("Serial Number", vm.volumeSerial, copyable: true)
            infoLine("Volume", t("volume_space", volume.name, free, total))
            infoLine("Storage Capacity", total)
            Spacer(minLength: 4)
            // Con l'opzione «musica sui volumi» (Avanzate) e un dispositivo con musica, il volume si collega con «Connect».
            Text(t(settings.manageMusicOnVolumes && volume.isMusicCapable ? "volume_info_note_music" : "volume_info_note"))
                .foregroundStyle(.secondary).lineLimit(2)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "n Playlist · n Artists · n Albums · n Songs" della musica presente sul dispositivo.
    private var deviceCountsText: String {
        // Nessuna musica (a lettura finita): al posto dei conteggi una scritta sola.
        if vm.deviceTracks.isEmpty && vm.devicePlaylists.isEmpty && !vm.isBusy { return t("device_no_music") }
        let summary = vm.deviceSummary
        // Durata nel formato delle playlist («1 ora e 5 minuti» / «1 hour, 5 minutes»); se per qualche brano è ignota
        // il totale è parziale e si aggiunge «(stimato)»; «—» se non si ricava nessuna durata.
        let text = totalTimeText(summary.seconds)
        let running = text.isEmpty ? "—" : (summary.complete ? text : text + " " + t("device_time_estimated"))
        let rest = t("device_counts_rest", summary.artists, summary.albums, vm.deviceTracks.count, running)
        // Playlist: omessa (con il suo separatore) se non ce ne sono; singolare con una sola, plurale con più.
        switch vm.devicePlaylists.count {
        case 0: return rest
        case 1: return t("device_playlists_one") + " · " + rest
        default: return t("device_playlists_many", vm.devicePlaylists.count) + " · " + rest
        }
    }

    /// Versione software come numero con due decimali: "649" → "6.49" (ultime due cifre = decimali).
    /// Se il valore non è numerico viene mostrato così com'è.
    private func formattedSoftwareVersion(_ raw: String?) -> String? {
        AppViewModel.formattedSoftwareVersion(raw)
    }

    /// Capacità totale della memoria interna del dispositivo («Storage Capacity: 16,97 GB»). Se il nome non permette di
    /// riconoscere quella interna, si usa la prima memoria; nil senza dispositivo.
    private var internalStorageCapacityText: String? {
        guard let storages = vm.device?.storages, !storages.isEmpty else { return nil }
        let internalStorage = storages.count == 1 ? storages.first
            : (storages.first(where: { $0.name.localizedCaseInsensitiveContains("intern") }) ?? storages.first)
        guard let capacity = internalStorage?.capacity, capacity > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(capacity), countStyle: .file)
    }

    /// Dati del dispositivo letti da GarminDevice.xml, una riga per campo ("Etichetta  valore").
    /// Un valore assente (ad es. Global ID non presente) si mostra come "—".
    private var deviceInfoLines: some View {
        let info = vm.deviceXMLInfo
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                infoLine("Model", vm.deviceModelText)
                // Garmin ha restituito le informazioni sulle mappe del dispositivo: icona del mondo.
                if vm.deviceMapsAvailable {
                    Button { Task { await vm.ensureDeviceMaps(); showMapsSheet = true } } label: {
                        Image(systemName: "map").font(.system(size: 12))
                            .foregroundStyle(mapsGlobeColor(catalog: vm.deviceMaps, checkedAt: vm.deviceMapsCheckedAt))
                    }
                    .buttonStyle(.plain)
                    .help(t("tooltip_maps_info"))
                } else if vm.deviceRoutesOnly {
                    routesOnlyIcon
                }
                // Dispositivo senza musica (da GarminDevice.xml): invio e cancellazione sono disattivati.
                if vm.isDeviceReadOnly {
                    updateCapsule(t("device_no_music_capsule"), color: Color(red: 0.937, green: 0.604, blue: 0.604))
                        .help(t("tooltip_device_not_music_capable"))
                }
            }
            softwareVersionLine(formattedSoftwareVersion(info?.softwareVersion), status: vm.softwareUpdateStatus)
            infoLine("Serial Number", vm.deviceSerial, copyable: true)
            infoLine("Storage Capacity", internalStorageCapacityText)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// «Software Version: 6.49» seguito, se il controllo opzionale ha dato un esito, da una capsula piena con testo nero
    /// (stesso stile di «Hi-Res»): verde «Software Updated» oppure arancione «Upgrade Available».
    private func softwareVersionLine(_ value: String?, status: SoftwareUpdateStatus?) -> some View {
        HStack(spacing: 6) {
            Text("Software Version:").foregroundStyle(StorageBarView.textColor)
            Text(value ?? "—").lineLimit(1).truncationMode(.middle).textSelection(.disabled)
            switch status {
            case .upToDate:
                updateCapsule("Software Updated", color: Color(red: 0.62, green: 0.84, blue: 0.62)) // verde pallido
                    .help(t("tooltip_software_updated"))
            case .available(let version, let notes):
                updateCapsule("Upgrade Available", color: Color(red: 0.937, green: 0.604, blue: 0.604)) // rosso pallido #EF9A9A
                    .help([t("tooltip_update_available", version), notes].compactMap { $0 }.joined(separator: "\n\n"))
            case nil:
                EmptyView()
            }
        }
    }

    /// Dispositivo senza mappe ma che accetta percorsi (es. Forerunner 255): icona informativa, non cliccabile.
    private var routesOnlyIcon: some View {
        Image(systemName: "point.bottomleft.forward.to.arrow.triangle.scurvepath").font(.system(size: 12))
            .foregroundStyle(.secondary)
            .help(t("tooltip_routes_only"))
    }

    /// Finestra delle mappe (icona della mappa nel pannello Device).
    @State private var showMapsSheet = false
    /// Scelta manuale dell'immagine del prodotto (menu contestuale sull'immagine del dispositivo).
    @State private var showImagePicker = false

    private func updateCapsule(_ text: String, color: Color) -> some View {
        UpdateCapsuleView(text: text, color: color)
    }

    private func infoLine(_ label: String, _ value: String?, copyable: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label + ":").foregroundStyle(StorageBarView.textColor)
            if copyable, let value, !value.isEmpty {
                // Come in Settings > Avanzate: click destro con la sola voce «Copia», che copia il valore negli appunti.
                Text(value).lineLimit(1).truncationMode(.middle).textSelection(.disabled)
                    .contextMenu {
                        Button(t("textmenu_copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(value, forType: .string)
                        }
                    }
            } else {
                Text(value ?? "—").lineLimit(1).truncationMode(.middle).textSelection(.disabled)
            }
        }
    }

    /// Nome mostrato per una memoria del dispositivo: "Internal Storage" diventa solo "Internal".
    private func storageDisplayName(_ name: String) -> String {
        name.replacingOccurrences(of: "Internal Storage", with: "Internal", options: .caseInsensitive)
    }

    /// Icona dei pulsanti tondi a destra delle schede (Eject, Connetti…): stessa area per tutti, così il pulsante è sempre
    /// tondo / rettangolo con i lati arrotondati della stessa misura, qualunque sia la forma del simbolo.
    /// Icona della memoria nel menu: scheda SD o memoria interna.
    private func storageIconName(_ name: String) -> String {
        name.lowercased().contains("sd") ? "sdcard" : "internaldrive"
    }

    private func accessoryIcon(_ name: String) -> some View {
        Image(systemName: name).frame(width: 20, height: 16)
    }

    /// A destra della riga delle schede del dispositivo (come il selettore libreria in Music): Eject, Connetti/Disconnetti
    /// e, con più memorie, il selettore della memoria (il più a destra).
    /// - Eject: nero se si può espellere (disco rilevato, non connesso), grigio altrimenti (connesso o nulla da espellere).
    /// - Connetti / Disconnetti: cavo / cavo barrato.
    private var deviceCategoryControls: some View {
        HStack(spacing: 6) {
            let volume = vm.device == nil ? vm.volumeDevices.first : nil
            if vm.device != nil {
                Button { Task { await vm.disconnect() } } label: { accessoryIcon("cable.connector.slash") }
                    .disabled(vm.isBusy)
                    .help(t("tooltip_disconnect_device"))
            } else if let volume {
                // Musica su dischi e schede SD (Impostazioni ▸ Avanzate): il volume si apre come un dispositivo.
                Button { Task { await vm.connectVolume(volume) } } label: { accessoryIcon("cable.connector") }
                    .disabled(vm.isBusy || !(settings.manageMusicOnVolumes && volume.isMusicCapable))
                    .help(t("tooltip_connect_device"))
            } else {
                Button { Task { await vm.connect() } } label: { accessoryIcon("cable.connector") }
                    .disabled(vm.isBusy)
                    .help(t("tooltip_connect_device"))
            }
            Button { if let volume { vm.ejectVolume(volume) } } label: { accessoryIcon("eject.fill") }
                .disabled(volume == nil || vm.isBusy)
                .help(volume == nil ? t("tooltip_eject_unavailable") : t("tooltip_eject_disk"))
            // Regola 2.0.1: il selettore compare solo se il dispositivo ha più di una memoria.
            if let device = vm.device, device.storages.count > 1 {
                // Stesso aspetto del selettore della libreria in Music: pulsante a menu, icona + nome, larghezza fissa.
                let current = device.storages.first { $0.id == vm.selectedStorageID }
                Menu {
                    ForEach(device.storages) { s in
                        Button((s.id == vm.selectedStorageID ? "✓ " : "") + storageDisplayName(s.name),
                               systemImage: storageIconName(s.name)) {
                            Task { await vm.changeStorage(to: s.id) }
                        }
                        .labelStyle(.titleAndIcon)
                    }
                } label: {
                    Label(current.map { storageDisplayName($0.name) } ?? t("label_storage"),
                          systemImage: storageIconName(current?.name ?? ""))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .labelStyle(CompactAwareLabelStyle())
                        .frame(width: compactPane ? nil : 130, alignment: .leading)
                }
                .menuStyle(.button)
                .disabled(vm.isBusy)
                .help(t("tooltip_storage_menu"))
            }
        }
        .buttonStyle(.flat)
    }

    /// Pulsanti in fondo al pannello dispositivo (stesso pannello di vetro di quello Apple Music).
    private var deviceBottomBar: some View {
        // Nessuno stile esplicito: i pulsanti ereditano `.glass` della barra, come «Invia all'orologio» nel pannello Music.
        HStack {
            Button {
                vm.clearDeviceSelection()
            } label: { Label(t("button_clear_selection"), systemImage: "xmark.circle").labelStyle(CompactAwareLabelStyle()).frame(width: barButtonWidth) }
            .disabled(!vm.hasDeviceSelection || vm.isBusy)
            .help(t("tooltip_clear_selection"))

            Button(role: .destructive) {
                // Brani: finestra di conferma dettagliata; playlist intere: il vecchio avviso.
                if vm.selectedDevicePlaylistFileIDs.isEmpty { showDeleteSheet = true } else { confirmDelete = true }
            } label: {
                Label(t("button_delete"), systemImage: "trash").labelStyle(CompactAwareLabelStyle()).frame(width: barButtonWidth)
            }
            .disabled(vm.device == nil || !vm.hasDeviceSelection || vm.isBusy || vm.isDeviceReadOnly)
            .help(t("tooltip_delete_selected"))

            Spacer()
            Text(vm.deviceSelectionSummaryText)
                .font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive) { confirmEmptyMusic = true } label: {
                Label(t("button_delete_all"), systemImage: "arrow.up.trash").labelStyle(CompactAwareLabelStyle()).frame(width: barButtonWidth)
            }
            // Senza musica sul dispositivo (né brani né playlist) non c'è nulla da eliminare.
            .disabled(vm.device == nil || vm.isBusy || vm.isDeviceReadOnly || (vm.deviceTracks.isEmpty && vm.devicePlaylists.isEmpty))
            .help(t("tooltip_delete_all_music"))
        }
    }

    /// Stessa costruzione del pannello Apple Music: l'elenco è la vista principale e le barre di
    /// vetro (`topAccessory` / `bottomBar`) gli stanno sopra e sotto. Nessun `.disabled`/`.opacity`
    /// sul contenitore (creerebbero un livello che appiattisce il vetro): il blocco durante le
    /// operazioni è applicato solo all'elenco e ai singoli controlli.
    private var devicePane: some View {
        deviceMusicView
            .topAccessory { deviceTopBlock }
            .categoryAccessory { deviceCategoryControls }
            .bottomBar { deviceBottomBar }
            // Trascinamento di file audio dal Finder: mentre ci si passa sopra, l'elenco diventa grigio con un simbolo al
            // centro (sotto le barre alta e bassa, vedi `CatalogBrowser.dropOverlayActive`); al rilascio si apre un dialogo.
            .dropOverlay(isDropTargeted && canDropAudio)
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                guard canDropAudio else {
                    vm.status = "⚠️ " + t("status_drop_no_device")
                    return false
                }
                return handleDroppedFiles(providers)
            }
            .alert(t("alert_drop_audio_title"), isPresented: Binding(
                get: { droppedAudio != nil },
                set: { if !$0 { droppedAudio = nil } }
            )) {
                Button(t("button_ok")) {
                    // Dopo l'avviso sui file non caricabili si prosegue con quelli accettati.
                    let supported = droppedAudio?.supported ?? []
                    droppedAudio = nil
                    if !supported.isEmpty { startImportPanel(for: supported) }
                }
            } message: {
                Text(droppedAudio.map { dropMessage($0) } ?? "")
            }
            .sheet(item: $importPanel) { payload in
                DroppedFilesView(items: payload.items,
                                 canSearch: settings.lookupMissingArtworkOnline,
                                 libraryMatch: { libraryMatchText(for: $0) },
                                 libraryArtwork: { await libraryArtwork(for: $0) },
                                 isBlocked: { vm.isLibraryMatchBlocked(for: $0) },
                                 onSend: { items in
                                     importPanel = nil
                                     Task { await vm.sendDroppedFiles(items) }
                                 },
                                 search: { info in
                                     await ArtworkLookupService().search(artist: info.artist, title: info.displayTitle,
                                                                         durationSeconds: info.duration)
                                 })
            }
    }

    /// Il trascinamento di file audio serve solo con un dispositivo collegato e scrivibile.
    private var canDropAudio: Bool { vm.device != nil && !vm.isDeviceReadOnly }

    /// Legge gli URL dei file trascinati e, finito, apre il dialogo con il riepilogo.
    private func handleDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.loadFileURL(from: provider) { urls.append(url) }
            }
            let audio = urls.filter { url in
                UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .audio) ?? false
            }
            // Formati accettati dal dispositivo collegato (o, senza dispositivo, quelli che l'app sa preparare).
            let accepted = LocalTrack.supportedExtensions
            let supported = audio.filter { accepted.contains($0.pathExtension.lowercased()) }
            let unsupported = audio.filter { !accepted.contains($0.pathExtension.lowercased()) }
            let info = DroppedAudioInfo(supported: supported, unsupported: unsupported, ignored: urls.count - audio.count)
            if unsupported.isEmpty && info.ignored == 0 && !supported.isEmpty {
                startImportPanel(for: supported)
            } else {
                droppedAudio = info
            }
        }
        return true
    }

    nonisolated private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func dropMessage(_ info: DroppedAudioInfo) -> String {
        var parts: [String] = []
        if !info.unsupported.isEmpty {
            let names = info.unsupported.prefix(10).map(\.lastPathComponent).joined(separator: "\n")
            let more = info.unsupported.count > 10 ? "\n…" : ""
            let formats = LocalTrack.supportedExtensions.sorted().map { $0.uppercased() }.joined(separator: ", ")
            parts.append(t("alert_drop_audio_unsupported", names + more, formats))
        }
        if info.ignored > 0 { parts.append(t("alert_drop_audio_ignored", info.ignored)) }
        if info.supported.isEmpty && info.unsupported.isEmpty { return t("alert_drop_audio_none") }
        return parts.joined(separator: "\n\n")
    }

    /// Legge i tag dei file accettati e apre il pannello informativo (un file alla volta).
    private func startImportPanel(for urls: [URL]) {
        Task { @MainActor in
            var items: [DroppedTrackInfo] = []
            for url in urls { items.append(await Self.readTags(of: url)) }
            importPanel = DroppedImportPayload(items: items)
        }
    }

    /// Brano della libreria Music che coincide con quello del file (ricalcolato a ogni modifica dei campi).
    private func libraryMatchText(for info: DroppedTrackInfo) -> String? {
        guard let match = vm.libraryMatch(for: info) else { return nil }
        return "\(match.title) — \(match.artist)" + (match.album.isEmpty ? "" : " (\(match.album))")
    }

    /// Copertina del brano già presente in Music: prima dal file/cache (veloce), poi, se Music è aperta, da Music stessa.
    private func libraryArtwork(for info: DroppedTrackInfo) async -> Data? {
        guard let match = vm.libraryMatch(for: info) else { return nil }
        if let data = await vm.appleArtworkResolved(for: match, fromMusic: false).data { return data }
        guard AppleMusicScripting.isMusicRunning else { return nil }
        return await vm.appleArtworkResolved(for: match, fromMusic: true).data
    }

    /// Metadati del file (AVFoundation: ID3 per MP3, atomi iTunes per M4A/AAC): gli stessi campi della scheda
    /// «Dettagli» di Music. I campi trovati restano in sola lettura (`locked`), quelli assenti si possono compilare.
    nonisolated private static func readTags(of url: URL) async -> DroppedTrackInfo {
        var info = DroppedTrackInfo(url: url)
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite { info.duration = seconds }
        }
        var strings: [String: String] = [:]
        var datas: [String: Data] = [:]
        var numbers: [String: Int] = [:]
        var dates: [String: Date] = [:]
        // Tutti i formati di metadati disponibili (ID3, iTunes, QuickTime...): `metadata` da solo può non includerli tutti.
        var all: [AVMetadataItem] = (try? await asset.load(.metadata)) ?? []
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let items = try? await asset.loadMetadata(for: format) { all.append(contentsOf: items) }
            }
        }
        do {
            for item in all {
                var ids: [String] = []
                if let id = item.identifier?.rawValue { ids.append(id) }
                if let common = item.commonKey?.rawValue { ids.append("common/" + common) }
                for id in ids {
                if strings[id] == nil, let value = try? await item.load(.stringValue) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { strings[id] = trimmed }
                }
                if datas[id] == nil, let data = try? await item.load(.dataValue) { datas[id] = data }
                if numbers[id] == nil, let number = try? await item.load(.numberValue) { numbers[id] = number.intValue }
                if dates[id] == nil, let date = try? await item.load(.dateValue) { dates[id] = date }
                }
            }
        }
        func first(_ ids: [String]) -> String {
            for id in ids { if let value = strings[id] { return value } }
            return ""
        }
        // Campi comuni (titolo, artista, album, copertina) dai metadati «common», uguali per ogni formato.
        if let common = try? await asset.load(.commonMetadata) {
            func commonString(_ id: AVMetadataIdentifier) async -> String {
                guard let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: id).first,
                      let value = try? await item.load(.stringValue) else { return "" }
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            info.title = await commonString(.commonIdentifierTitle)
            info.artist = await commonString(.commonIdentifierArtist)
            info.album = await commonString(.commonIdentifierAlbumName)
            if let art = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierArtwork).first {
                info.artwork = try? await art.load(.dataValue)
            }
        }
        info.albumArtist = first(["itsk/aART", "id3/TPE2"])
        info.composer = first(["itsk/%A9wrt", "itsk/\u{A9}wrt", "id3/TCOM"])
        // Genere: testo («Pop»), codice ID3v1 («13», «(13)Pop») o atomo iTunes `gnre` (indice + 1, 2 byte).
        var genre = first(["itsk/%A9gen", "itsk/\u{A9}gen", "id3/TCON", "common/type"])
        if let number = Int(genre.trimmingCharacters(in: CharacterSet(charactersIn: "()"))) {
            genre = id3Genres.indices.contains(number) ? id3Genres[number] : ""
        } else if genre.hasPrefix("("), let close = genre.firstIndex(of: ")") {
            let rest = String(genre[genre.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            let code = Int(genre[genre.index(after: genre.startIndex)..<close]) ?? -1
            genre = !rest.isEmpty ? rest : (id3Genres.indices.contains(code) ? id3Genres[code] : "")
        }
        if genre.isEmpty, let d = datas["itsk/gnre"], d.count >= 2 {
            let code = Int(d[d.startIndex]) << 8 | Int(d[d.startIndex + 1])
            if id3Genres.indices.contains(code - 1) { genre = id3Genres[code - 1] }
        }
        info.genre = genre
        // Anno: i primi 4 caratteri della data di rilascio (es. «2014» o «2014-05-12T07:00:00Z»).
        let yearIDs = ["itsk/%A9day", "itsk/\u{A9}day", "udta/%A9day", "udta/\u{A9}day", "id3/TDRC", "id3/TYER", "id3/TORY", "id3/TDOR",
                       "common/creationDate", "mdta/com.apple.quicktime.creationdate"]
        let yearText = first(yearIDs)
        if yearText.count >= 4, Int(yearText.prefix(4)) != nil {
            info.year = String(yearText.prefix(4))
        } else {
            // Il valore può essere di tipo data o numero invece che testo.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            for id in yearIDs {
                if let date = dates[id] { info.year = String(calendar.component(.year, from: date)); break }
                if let number = numbers[id], (1000...3000).contains(number) { info.year = String(number); break }
            }
        }
        if info.year.isEmpty {
            // Diagnostica (console di Xcode): identificatori trovati nel file, per capire dove sta l'anno.
            print("[DropTags] anno non trovato in \(url.lastPathComponent). Chiavi:",
                  Set(strings.keys).union(datas.keys).union(numbers.keys).union(dates.keys).sorted())
        }
        // Traccia e disco: «3/12» negli ID3; negli atomi iTunes 8/6 byte (2 byte a 0, numero, totale).
        func pair(id3: String, atom: String) -> (String, String) {
            if let text = strings[id3] {
                let parts = text.split(separator: "/", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
            }
            if let d = datas[atom], d.count >= 6 {
                let bytes = [UInt8](d)
                let number = Int(bytes[2]) << 8 | Int(bytes[3])
                let total = Int(bytes[4]) << 8 | Int(bytes[5])
                return (number > 0 ? String(number) : "", total > 0 ? String(total) : "")
            }
            return ("", "")
        }
        (info.track, info.trackTotal) = pair(id3: "id3/TRCK", atom: "itsk/trkn")
        (info.disc, info.discTotal) = pair(id3: "id3/TPOS", atom: "itsk/disk")
        info.compilation = (numbers["itsk/cpil"] ?? 0) != 0 || (datas["itsk/cpil"]?.first ?? 0) != 0
            || strings["id3/TCMP"] == "1"
        // Campi trovati: in sola lettura.
        let found: [(String, String)] = [
            ("title", info.title), ("artist", info.artist), ("album", info.album), ("albumArtist", info.albumArtist),
            ("composer", info.composer), ("genre", info.genre), ("year", info.year),
            ("track", info.track), ("trackTotal", info.trackTotal), ("disc", info.disc), ("discTotal", info.discTotal)
        ]
        for (key, value) in found where !value.isEmpty { info.locked.insert(key) }
        if info.compilation { info.locked.insert("compilation") }
        return info
    }

    private var deviceMusicView: CatalogBrowser<DeviceTrack> {
        CatalogBrowser(tracks: vm.deviceTracks,
                       playlists: vm.devicePlaylists,
                       category: $vm.deviceCategory,
                       selection: $vm.selectedDeviceTrackIDs,
                       emptyMessage: t("empty_device_music"),
                       artworkRevision: vm.deviceArtworkRevision,
                       artworkProvider: vm.deviceArtwork)
        // Playlist del dispositivo: si sceglie solo la playlist intera (si elimina con i suoi brani).
        .trackSelectionInPlaylistsDisabled()
        .toolbarSearch($vm.deviceSearch)
        .onSelectedPlaylistsChange { vm.selectedDevicePlaylistIDs = $0 }
        // «Edit in Custom»: porta la playlist del dispositivo nella Custom Playlist per modificarla e rinviarla.
        .onEditPlaylist { vm.editDevicePlaylistInCustom($0) }
        // Dispositivo senza musica: schede, ricerca, memoria e ricarica disattivate.
        .controlsDisabled(vm.isDeviceReadOnly)
    }

    // MARK: - Centro notifiche (barra del titolo)

    /// Icona di un pulsante della barra del titolo: simbolo più grande e area minima uguale per tutti, così le capsule di
    /// sistema sono tonde/proporzionate come in Xcode (invece di icone piccole e capsule strette).
    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .regular))
            .frame(minWidth: 26, minHeight: 24)
    }

    /// Sottotitolo della finestra (sotto il titolo, come in Xcode): l'ultimo messaggio, in testo semplice; avvisi ed errori
    /// con un simbolo davanti. Resta finché arriva un altro messaggio.
    /// Capsula centrale della barra del titolo (stile Xcode): a sinistra la rotellina se c'è un'operazione in corso, altrimenti
    /// l'icona del tipo dell'ultimo messaggio; poi il nome dell'app in grassetto e sotto, più piccolo, l'ultimo messaggio.
    /// Larghezza della capsula: tutta la barra meno lo spazio a sinistra (pulsanti della finestra, nascosti a schermo intero)
    /// e a destra (aggiorna+cerca, impostazioni, notifiche, margini). Stime prudenti: meglio qualche punto di vuoto che far
    /// finire i pulsanti nel menu «»» di overflow.
    /// Spazio a destra riservato ai pulsanti della toolbar (aggiorna+cerca, impostazioni, notifiche) e ai margini.
    private static let toolbarButtonsWidth: CGFloat = 212
    private static let capsuleHeight: CGFloat = 38
    /// Larghezza della capsula a schermo intero (elemento della toolbar): tutta la barra meno i pulsanti a destra.
    /// Spazio da lasciare a schermo intero (margini della toolbar + quattro pulsanti + distanze): prudente, perché se la capsula
    /// è troppo larga i pulsanti finiscono nel menu «»» di overflow (visto con 248: troppo poco).
    private static let fullScreenReserve: CGFloat = 245
    private var fullScreenCapsuleWidth: CGFloat {
        guard windowWidth > 0 else { return 600 }
        return min(max(windowWidth - Self.fullScreenReserve, 180), 2400)
    }

    /// Anello di avanzamento della capsula: traccia chiara e tratto pieno nel colore dato (blu = operazioni normali, rosso = eliminazioni).
    private func progressRing(_ p: Double, color: Color) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.18), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.03, min(p, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .animation(.linear(duration: 0.25), value: p)
    }

    private var activityCapsule: some View {
        HStack(spacing: 8) {
            Group {
                if let d = vm.deletionProgress {
                    // Eliminazione dal dispositivo (Delete / Delete All): anello ROSSO che si riempie; senza totale ancora, rotellina rossa.
                    if d.total > 0 {
                        progressRing(Double(d.current) / Double(d.total), color: .red)
                    } else {
                        ProgressView().controlSize(.small).tint(.red)
                    }
                } else if vm.remotePlaybackLoading != nil {
                    ProgressView().controlSize(.small).tint(.green)
                } else if let r = remoteLoader.progress, r.isCopying, !r.inSettings {
                    // Copia dell'XML di una libreria di rete: anello VERDE (come la disponibilità della libreria) con i MB nella seconda riga.
                    progressRing(r.fraction, color: .green)
                } else if vm.isBusy, let p = vm.progress {
                    // Anello che si riempie fino al completamento (come l'attività di Xcode).
                    progressRing(p, color: .accentColor)
                } else if vm.isBusy {
                    ProgressView().controlSize(.small)
                } else if let last = vm.notices.last {
                    Image(systemName: last.kind.symbol).foregroundStyle(noticeColor(last.kind))
                } else {
                    Image(systemName: "music.note.list").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14))
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 0) {
                Text("Music Manager").font(.system(size: 12, weight: .semibold))
                Text(vm.deletionProgress.flatMap { $0.detail.isEmpty ? nil : $0.detail }
                     ?? vm.remotePlaybackLoading.map { "\(t("remote_playback_loading")) «\($0.title)»" }
                     ?? remoteLoader.progress.flatMap { $0.isCopying && !$0.inSettings ? "\($0.nickname): \($0.phase)" : nil }
                     ?? subtitleText)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: Self.capsuleHeight, maxHeight: Self.capsuleHeight, alignment: .leading)   // si allarga fino ai pulsanti a destra (prova: prima maxWidth 640)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .help(t("notices_title"))
    }

    private var subtitleText: String {
        guard let last = vm.notices.last else { return NoticeFormat.plain(vm.status) }
        let prefix: String
        switch last.kind {
        case .warning: prefix = "⚠️ "
        case .error: prefix = "❌ "
        default: prefix = ""
        }
        return prefix + NoticeFormat.plain(last.text)
    }

    /// Aggiorna (libreria e, se connesso, dispositivo): durante un'operazione mostra la rotellina.
    private var refreshButton: some View {
        Button { Task { await vm.refreshAll() } } label: {
            if vm.libraryBusy || vm.refreshAllRunning { ProgressView().controlSize(.small).frame(minWidth: 26, minHeight: 24) } else { toolbarIcon("arrow.clockwise") }
        }
        .buttonStyle(.automatic)
        .help(vm.device != nil && !vm.isDeviceReadOnly ? t("tooltip_refresh_all") : t("tooltip_reload_library"))
        .disabled(vm.isBusy)
    }

    private var settingsButton: some View {
        SettingsLink { toolbarIcon("gearshape") }
            .buttonStyle(.automatic)
            .help(t("menu_settings_help"))
    }

    /// Testo della ricerca del pannello scelto (Custom Playlist: la sua, separata).
    private var searchTextBinding: Binding<String> {
        Binding(
            get: {
                switch vm.effectiveSearchTarget {
                case .music: return vm.appleCategory == .customPlaylist ? vm.customPlaylistSearch : vm.musicSearch
                case .device: return vm.deviceSearch
                }
            },
            set: { new in
                switch vm.effectiveSearchTarget {
                case .music:
                    if vm.appleCategory == .customPlaylist { vm.customPlaylistSearch = new } else { vm.musicSearch = new }
                case .device: vm.deviceSearch = new
                }
            })
    }

    /// Lente nella barra del titolo: apre il campo di ricerca (⌘F). Un puntino segnala un filtro attivo.
    private var searchButton: some View {
        Button { showSearch.toggle() } label: {
            toolbarIcon("magnifyingglass")
                .overlay(alignment: .topTrailing) {
                    if vm.isSearchFilterActive { Circle().fill(Color.accentColor).frame(width: 8, height: 8).offset(x: -1, y: 1) }
                }
        }
        .buttonStyle(.automatic)
        .keyboardShortcut("f", modifiers: .command)
        .help((vm.effectiveSearchTarget == .music ? t("search_in_music") : t("search_in_device")) + " (⌘F)")
        .popover(isPresented: $showSearch, arrowEdge: .bottom) { searchPopover }
        .onChange(of: vm.device == nil) { _, none in if none { vm.deviceSearch = ""; vm.searchTarget = .music } }
    }

    private var searchPopover: some View {
        HStack(spacing: 8) {
            // Con il dispositivo collegato: icona del pannello (rossa Music / verde dispositivo); un clic le alterna.
            if vm.device != nil {
                Button { vm.searchTarget = vm.effectiveSearchTarget == .music ? .device : .music } label: {
                    Image(systemName: vm.effectiveSearchTarget == .music ? "music.note.square.stack" : "watch.analog")
                        .foregroundStyle(vm.effectiveSearchTarget == .music ? statusIconRed : statusIconGreen)
                        .frame(width: 22)
                }
                .buttonStyle(.plain)
                .help(t("search_switch_panel"))
            }
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(vm.effectiveSearchTarget == .music ? t("search_in_music") : t("search_in_device"), text: searchTextBinding)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .frame(width: 280)
            if !searchTextBinding.wrappedValue.isEmpty {
                Button { searchTextBinding.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(t("tooltip_search_clear"))
            }
        }
        .padding(12)
        .onAppear { searchFocused = true }
    }

    private func noticeColor(_ kind: NoticeKind) -> Color {
        switch kind {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    /// Campanella a destra della barra del titolo: con avvisi/errori non letti mostra un puntino.
    private var noticeBell: some View {
        Button { showNotices.toggle() } label: {
            HStack(spacing: 4) {
                toolbarIcon(vm.unreadIssues > 0 ? "bell.badge.fill" : "bell")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(vm.unreadIssues > 0 ? (vm.unreadHasError ? Color.red : Color.orange) : Color.primary, Color.primary)
                if vm.unreadIssues > 0 { Text("\(vm.unreadIssues)").font(.system(size: 12).monospacedDigit()) }
            }
        }
        .buttonStyle(.automatic)
        .help(vm.unreadIssues > 0 ? t("tooltip_notices_unread", vm.unreadIssues) : t("notices_title"))
        .popover(isPresented: $showNotices, arrowEdge: .bottom) { noticeList }
        .onChange(of: showNotices) { _, open in if open { vm.unreadIssues = 0 } }
    }

    private var noticeList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(t("notices_title")).font(.headline)
                Spacer()
                Button(t("notices_clear")) { vm.notices.removeAll(); vm.unreadIssues = 0 }
                    .disabled(vm.notices.isEmpty)
            }
            .padding(12)
            Divider()
            if vm.notices.isEmpty {
                Text(t("notices_empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.notices.reversed()) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: entry.kind.symbol)
                                    .foregroundStyle(noticeColor(entry.kind))
                                    .frame(width: 18)
                                Text(NoticeFormat.attributed(entry.text))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(entry.date, style: .time)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 420)
    }

    /// Nome della libreria nel pulsante del selettore: al massimo 15 caratteri in tutto; se più lungo, i primi 12 più «...».
    private func shortLibraryName(_ name: String) -> String {
        name.count <= 15 ? name : String(name.prefix(12)) + "..."
    }

}


/// Conferma di «Svuota» della Custom Playlist: «Salva su file» è il pulsante predefinito, su sfondo verde.
struct ClearPlaylistConfirmView: View {
    let onSave: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// Larghezza dei tre pulsanti: la più larga tra le loro etichette (in tutte le lingue) e quella dei pulsanti delle barre.
    /// «Conferma svuotamento» è più lunga di tutte le etichette delle barre: con la misura delle barre andava a capo.
    private var buttonWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let keys = ["button_save_to_file", "button_confirm_clear", "button_cancel"]
        let widest = AppLanguage.allCases.flatMap { lang in
            keys.map { (tFor(lang, $0) as NSString).size(withAttributes: [.font: font]).width }
        }.max() ?? 0
        return max(mainBarButtonWidth(), ceil(widest) + 24)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(t("alert_clear_playlist_title"))
                .font(.headline)
            Text(t("alert_clear_playlist_message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Tre pulsanti su una riga, della stessa misura (quella dei pulsanti delle barre principali) e con le stesse icone.
            HStack(spacing: 8) {
                // 1. Predefinito (Invio): stessa icona di «Salva su file» della barra della Custom Playlist.
                Button(action: onSave) {
                    Label(t("button_save_to_file"), systemImage: "square.and.arrow.up").frame(width: buttonWidth).lineLimit(1)
                }
                .buttonStyle(.flatProminentRoomy)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
                // 2. Svuota davvero: rosso con il cestino, come «Delete All».
                Button(role: .destructive, action: onConfirm) {
                    Label(t("button_confirm_clear"), systemImage: "trash").frame(width: buttonWidth).lineLimit(1)
                }
                .buttonStyle(.flatRoomy)
                // 3. Non fa nulla (Esc).
                Button(action: onCancel) {
                    Text(t("button_cancel")).frame(width: buttonWidth).lineLimit(1)
                }
                .buttonStyle(.flatRoomy)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        // Tre pulsanti + due spazi + margini.
        .frame(width: buttonWidth * 3 + 16 + 40 + 24 + 3 * 16)   // + 16 pt per pulsante: margine interno dei pulsanti dei dialoghi
    }
}


/// Richiesta del nickname per un dispositivo collegato per la prima volta: OK conferma, Skip lascia il nome del dispositivo
/// (il nickname si può impostare poi in Impostazioni → Avanzate → Devices).
struct DeviceNicknamePromptView: View {
    let model: String
    let onConfirm: (String) -> Void
    let onSkip: () -> Void
    @State private var nickname = ""

    private var trimmed: String { nickname.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "watch.analog")
                .font(.system(size: 34))
                .foregroundStyle(.blue)
            Text(t("nickname_prompt_title"))
                .font(.headline)
            Text(t("nickname_prompt_message", model))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)   // testo allineato a sinistra, come nel pannello di import
            TextField(t("nickname_prompt_placeholder"), text: $nickname)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !trimmed.isEmpty { onConfirm(trimmed) } }
            HStack {
                Spacer()
                Button("Skip") { onSkip() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { onConfirm(trimmed) }
                    .buttonStyle(.flatProminentRoomy)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
    }
}

/// Brani che sarebbero doppi nella Custom Playlist: l'elenco completo scorre e ogni brano ha la sua spunta (tutte attive).
/// «Aggiungi comunque (n)» aggiunge solo quelli spuntati, «Salta i brani» non ne aggiunge nessuno.
struct DuplicateTracksView: View {
    let tracks: [LocalTrack]
    let onAdd: ([LocalTrack]) -> Void
    let onSkip: () -> Void
    @State private var selected: Set<Int>

    init(tracks: [LocalTrack], onAdd: @escaping ([LocalTrack]) -> Void, onSkip: @escaping () -> Void) {
        self.tracks = tracks
        self.onAdd = onAdd
        self.onSkip = onSkip
        _selected = State(initialValue: Set(tracks.indices))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("alert_duplicate_tracks_title")).font(.headline)
            Text(t("duplicates_panel_message")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button(t("duplicates_select_all")) { selected = Set(tracks.indices) }.disabled(selected.count == tracks.count)
                Button(t("duplicates_select_none")) { selected = [] }.disabled(selected.isEmpty)
                Spacer()
            }
            .buttonStyle(.link)
            .font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                        Button {
                            if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(index) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selected.contains(index) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(track.title).lineLimit(1)
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            HStack {
                Spacer()
                Button(t("button_skip_tracks"), action: onSkip)
                    .buttonStyle(.flatRoomy)
                    .keyboardShortcut(.cancelAction)
                Button(t("duplicates_add_count", selected.count)) {
                    onAdd(tracks.indices.filter { selected.contains($0) }.map { tracks[$0] })
                }
                .buttonStyle(.flatProminentRoomy)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 520, height: min(520, max(300, MainWindowMetrics.shared.height * 0.9 - 56)))
    }
}

/// Scelta all'import di una playlist del dispositivo nella Custom Playlist che contiene già dei brani.
/// Ordine dei pulsanti (dall'alto): 1. Playlist First (predefinito) · 2. Current Tracks First · 3. Replace · 4. Annulla.
struct DevicePlaylistImportView: View {
    let name: String
    let onPlaylistFirst: () -> Void
    let onCurrentFirst: () -> Void
    let onReplace: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "watch.analog")
                .font(.system(size: 34))
                .foregroundStyle(.blue)
            Text(t("alert_device_load_title"))
                .font(.headline)
            Text(t("alert_device_load_message", name))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                Button(action: onPlaylistFirst) {
                    Text(t("button_load_current_after_device")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.flatProminentRoomy)
                .keyboardShortcut(.defaultAction)
                Button(action: onCurrentFirst) {
                    Text(t("button_load_saved_after_device")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.flatRoomy)
                Button(role: .destructive, action: onReplace) {
                    Text(t("button_load_replace")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.flatRoomy)
                Button(action: onCancel) {
                    Text(t("button_cancel")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.flatRoomy)
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 420)
    }
}


/// Pallino pieno con testo nero (stile «Hi-Res»): «Software Updated» / «Upgrade Available» nel pannello dispositivo e
/// nella tabella della finestra degli aggiornamenti.
struct UpdateCapsuleView: View {
    let text: String
    let color: Color
    /// Corpo del testo: 8 pt nel pannello dispositivo, più grande nella finestra degli aggiornamenti.
    var fontSize: CGFloat = 8
    static let upToDate = Color(red: 0.62, green: 0.84, blue: 0.62)      // verde pallido
    static let available = Color(red: 0.937, green: 0.604, blue: 0.604)  // rosso pallido #EF9A9A
    static let checkNeeded = Color(red: 0.98, green: 0.80, blue: 0.46)   // ambra pallido: controllo da rifare

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .medium))
            .padding(.horizontal, fontSize * 0.75).padding(.vertical, fontSize * 0.125)
            .background(color, in: Capsule())
            .foregroundStyle(Color.black)
            .fixedSize()
    }
}

/// Finestra «Aggiornamento disponibile»: una riga per dispositivo registrato, con il pallino dell'esito nella prima
/// colonna e il nome assegnato nella seconda. Le novità (changelog) sono nel tooltip del pallino «Upgrade Available».
private struct DeviceUpdateSheet: View {
    let rows: [AppViewModel.DeviceUpdateRow]
    let onOK: () -> Void
    let onIgnore: () -> Void

    private var hasAvailable: Bool {
        rows.contains { if case .available = $0.status { return true } else { return false } }
    }

    /// Testo del tooltip di «Upgrade Available»: versioni, data dei dati e novità (changelog).
    private func updateTooltip(_ row: AppViewModel.DeviceUpdateRow, version: String, notes: String?) -> String {
        var lines: [String] = []
        if let installed = row.installed { lines.append("\(installed) → \(version)") }
        lines.append(t("tooltip_update_available", version))
        if let d = row.readDate { lines.append(t("update_data_read_on", d.formatted(date: .abbreviated, time: .omitted))) }
        if let notes, !notes.isEmpty { lines.append("\n" + notes) }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func badge(_ row: AppViewModel.DeviceUpdateRow) -> some View {
        switch row.status {
        case .available(let version, let notes):
            UpdateCapsuleView(text: "Upgrade Available", color: UpdateCapsuleView.available, fontSize: 10)
                .help(updateTooltip(row, version: version, notes: notes))
        case .upToDate:
            UpdateCapsuleView(text: "Software Updated", color: UpdateCapsuleView.upToDate, fontSize: 10)
                .help(t("tooltip_software_updated"))
        case nil:
            Text("—").font(.caption).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("alert_device_update_title")).font(.headline)
            Text(t("update_sheet_hint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 14) {
                        badge(row).frame(width: 150, alignment: .leading)
                        Text(row.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    if row.id != rows.last?.id { Divider() }
                }
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Text(t("alert_device_update_footer")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if hasAvailable { Button(t("button_ignore_update"), action: onIgnore) }
                Button("OK", action: onOK).buttonStyle(.flatProminentRoomy).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}


/// Colori delle icone di stato (globo, spunta/croce del software): verde scuro = a posto, rosso = da aggiornare.
let statusIconGreen = Color(red: 0.18, green: 0.58, blue: 0.28)
let statusIconRed = Color(red: 0.86, green: 0.24, blue: 0.24)

/// Colore del globo delle mappe: rosso se c'è una mappa da aggiornare o l'ultimo controllo ha oltre `mapsRecheckDays`
/// giorni, verde (scuro) se è tutto aggiornato e il controllo è recente, grigio se non ci sono dati.
@MainActor
func mapsGlobeColor(catalog: GarminMapsCatalog?, checkedAt: Date?) -> Color {
    guard let catalog, let checkedAt else { return .secondary }
    let days = Calendar.current.dateComponents([.day], from: checkedAt, to: Date()).day ?? 0
    let stale = days > AppSettings.mapsRecheckDays
    return (catalog.hasUpdates || stale) ? statusIconRed : statusIconGreen
}

/// «Checked Today» / «Checked 78 days ago» a partire dalla data del controllo delle mappe.
func mapsCheckedText(_ date: Date) -> String {
    let cal = Calendar.current
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
    return days <= 0 ? t("maps_checked_today") : t("maps_checked_days", String(days))
}

/// Finestra informativa sulle mappe: quelle presenti sul dispositivo (con «Map Updated» / «Update Available») e le aree
/// che Garmin offre e si possono aggiungere. Installare o aggiornare si fa con Garmin Express.
struct MapsSheet: View {
    let catalog: GarminMapsCatalog?
    let checkEnabled: Bool
    var errorDetail: String? = nil
    var checkedAt: Date? = nil
    /// Controllo forzato sui server Garmin (solo nel pannello della pagina principale); nil = pulsante assente.
    var onRefresh: (() async -> Void)? = nil
    @State private var refreshing = false
    let onClose: () -> Void

    private func sizeText(_ bytes: UInt64) -> String {
        bytes == 0 ? "—" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Giorni dall'ultimo controllo se superano `mapsRecheckDays` (nil = controllo recente o data sconosciuta).
    private var staleDays: Int? {
        guard let checkedAt else { return nil }
        let days = Calendar.current.dateComponents([.day], from: checkedAt, to: Date()).day ?? 0
        return days > AppSettings.mapsRecheckDays ? days : nil
    }

    /// Corpo del testo delle capsule nella finestra delle mappe (2.1 Beta 3: 8 pt, come «Software Updated» nel pannello dispositivo).
    private static let badgeFontSize: CGFloat = 8

    @ViewBuilder
    private func badge(_ entry: GarminMapEntry) -> some View {
        switch entry.updateAvailable {
        case .some(true):
            UpdateCapsuleView(text: "Update Available", color: UpdateCapsuleView.available, fontSize: Self.badgeFontSize)
                .help(t("maps_update_tooltip", entry.installedVersion ?? "—", entry.version))
        case .some(false):
            if let days = staleDays {
                // Ultimo controllo troppo vecchio: «aggiornata» non è più una garanzia, si invita a ricontrollare.
                UpdateCapsuleView(text: "Check Needed", color: UpdateCapsuleView.checkNeeded, fontSize: Self.badgeFontSize)
                    .help(t("maps_stale_tooltip", String(days)))
            } else {
                UpdateCapsuleView(text: "Map Updated", color: UpdateCapsuleView.upToDate, fontSize: Self.badgeFontSize)
                    .help(t("maps_updated_tooltip", entry.version))
            }
        case nil:
            Text("—").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func installedRow(_ entry: GarminMapEntry) -> some View {
        HStack(spacing: 12) {
            badge(entry).frame(width: 100, alignment: .leading)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(entry.installedVersion ?? entry.version).foregroundStyle(.secondary).monospacedDigit()
            Text(sizeText(entry.sizeBytes)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.vertical, 6).padding(.horizontal, 12)
    }

    private func availableRow(_ entry: GarminMapEntry) -> some View {
        HStack(spacing: 12) {
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(entry.version).foregroundStyle(.secondary).monospacedDigit()
            Text(sizeText(entry.sizeBytes)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.vertical, 6).padding(.horizontal, 12)
    }

    /// «arrow.clockwise.circle.fill» grigio scuro: rilegge e ricontrolla le mappe dai server Garmin (solo con `onRefresh`).
    @ViewBuilder
    private var refreshButton: some View {
        if let onRefresh, checkEnabled {
            if refreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    refreshing = true
                    Task { await onRefresh(); refreshing = false }
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color(white: 0.42))
                }
                .buttonStyle(.plain)
                .help(t("maps_refresh_tooltip"))
            }
        }
    }

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(t("maps_title")).font(.headline)
                Spacer()
                // Senza dati (errore) il pulsante di controllo sta qui; con i dati sta accanto a «Checked …».
                if catalog == nil { refreshButton }
            }
            if let catalog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(t("maps_installed")).font(.subheadline.weight(.semibold))
                            Spacer()
                            if let checkedAt {
                                Text(mapsCheckedText(checkedAt)).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            refreshButton
                        }
                        if catalog.installed.isEmpty {
                            Text(t("maps_none_installed")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            box {
                                ForEach(catalog.installed) { entry in
                                    installedRow(entry)
                                    if entry.id != catalog.installed.last?.id { Divider() }
                                }
                            }
                        }
                        if !catalog.available.isEmpty {
                            Text(t("maps_available")).font(.subheadline.weight(.semibold)).padding(.top, 4)
                        }
                        let regions = Dictionary(grouping: catalog.available) { $0.region ?? t("maps_other_region") }
                        ForEach(regions.keys.sorted(), id: \.self) { region in
                            Text(region).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            box {
                                let list = regions[region] ?? []
                                ForEach(list) { entry in
                                    availableRow(entry)
                                    if entry.id != list.last?.id { Divider() }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(checkEnabled ? t("maps_unavailable") : t("maps_disabled_hint"))
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if checkEnabled, let errorDetail {
                    Text(errorDetail).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Text("**\(t("maps_footer_title"))** \(t("maps_footer"))")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK", action: onClose).buttonStyle(.flatProminentRoomy).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .modifier(SheetFrame(width: 560, height: 560))
    }
}

/// Generi ID3v1 (indice 0...79), usati anche dall'atomo iTunes `gnre` (indice + 1).
private let id3Genres = [
    "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age",
    "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska",
    "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion",
    "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "AlternRock",
    "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
    "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy",
    "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave",
    "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro",
    "Musical", "Rock & Roll", "Hard Rock"
]

/// File audio trascinati sul pannello del dispositivo: accettati dal dispositivo, non accettati (formato) e non audio.
struct DroppedAudioInfo {
    let supported: [URL]
    let unsupported: [URL]
    let ignored: Int
}

/// Dati letti dai tag di un file trascinato (stessi campi della scheda «Dettagli» di Music). `locked` = campi già
/// presenti nel file (sola lettura); gli altri si possono compilare nel pannello.
struct DroppedTrackInfo: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var composer = ""
    var genre = ""
    var year = ""
    var track = ""
    var trackTotal = ""
    var disc = ""
    var discTotal = ""
    var compilation = false
    var duration: TimeInterval = 0
    var artwork: Data?
    /// Vero se la copertina è stata scelta nel pannello (ricerca online o «usa per l'album»), non letta dal file o da Music.
    var coverChanged = false
    var locked: Set<String> = []

    init(url: URL) { self.url = url }

    /// Titolo dai tag o, se manca, nome del file senza estensione.
    var displayTitle: String { title.isEmpty ? url.deletingPathExtension().lastPathComponent : title }
}

struct DroppedImportPayload: Identifiable {
    let id = UUID()
    let items: [DroppedTrackInfo]
}

/// Pannello informativo sui file trascinati, sul modello della scheda «Dettagli» di Music (senza le schede): un file
/// alla volta, campi già presenti in sola lettura e campi mancanti modificabili, copertina con ricerca online dal
/// click destro, avviso se il brano risulta già nella libreria Music.
struct DroppedFilesView: View {
    @State private var items: [DroppedTrackInfo]
    let canSearch: Bool
    let libraryMatch: (DroppedTrackInfo) -> String?
    let libraryArtwork: (DroppedTrackInfo) async -> Data?
    /// Invio confermato: file (con i dati compilati nel pannello) e scelta «usa i brani già in Music».
    let isBlocked: (DroppedTrackInfo) -> Bool
    let onSend: ([DroppedTrackInfo]) -> Void
    let search: (DroppedTrackInfo) async -> [Data]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var confirmSend = false
    /// File per cui si è già provato a leggere la copertina da Music.
    @State private var musicCoverTried: Set<UUID> = []

    private struct CoverSearch {
        var searching = false
        var notFound = false
        var candidates: [Data] = []
        var position = 0
    }
    @State private var covers: [UUID: CoverSearch] = [:]

    init(items: [DroppedTrackInfo], canSearch: Bool,
         libraryMatch: @escaping (DroppedTrackInfo) -> String?,
         libraryArtwork: @escaping (DroppedTrackInfo) async -> Data?,
         isBlocked: @escaping (DroppedTrackInfo) -> Bool,
         onSend: @escaping ([DroppedTrackInfo]) -> Void,
         search: @escaping (DroppedTrackInfo) async -> [Data]) {
        _items = State(initialValue: items)
        self.canSearch = canSearch
        self.libraryMatch = libraryMatch
        self.libraryArtwork = libraryArtwork
        self.isBlocked = isBlocked
        self.onSend = onSend
        self.search = search
    }

    var body: some View {
        let item = items[index]
        VStack(alignment: .leading, spacing: 0) {
            header(item)
            VStack(alignment: .leading, spacing: 6) {
                row(t("drop_field_title"), "title", \.title)
                row(t("drop_field_artist"), "artist", \.artist)
                row(t("drop_field_album"), "album", \.album)
                row(t("drop_field_album_artist"), "albumArtist", \.albumArtist)
                row(t("drop_field_composer"), "composer", \.composer)
                row(t("drop_field_genre"), "genre", \.genre, width: 180)
                row(t("drop_field_year"), "year", \.year, width: 80)
                pairRow(t("drop_field_track"), ("track", \.track), ("trackTotal", \.trackTotal))
                pairRow(t("drop_field_disc"), ("disc", \.disc), ("discTotal", \.discTotal))
                toggleRow(t("drop_compilation"), \.compilation, locked: item.locked.contains("compilation"))
                row(t("drop_field_file"), "file", \.title, fixed: item.url.lastPathComponent)

                if isBlocked(item) {
                    Label(t("drop_in_cloud"), systemImage: "exclamationmark.icloud.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(height: 20, alignment: .leading)
                        .padding(.top, 6)
                } else if let match = libraryMatch(item) {
                    Label(t("drop_in_library", match), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(height: 20, alignment: .leading)
                        .padding(.top, 6)
                } else {
                    Label(t("drop_not_in_library"), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .frame(height: 20, alignment: .leading)
                        .padding(.top, 6)
                }

                // Barra in basso: Close a sinistra, «File n di N» al centro tra due frecce (come quelle della copertina),
                // «Send to Device» a destra (stesso pulsante del pannello Music).
                HStack {
                    Button(t("button_close")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button {
                        confirmSend = true
                    } label: {
                        Label(t("button_send_to_watch"), systemImage: "arrow.right.circle.fill")
                            .frame(width: sendButtonWidth)
                    }
                }
                .overlay {
                    HStack(spacing: 10) {
                        // Frecce con lo stesso aspetto dei pulsanti dell'interfaccia (Close, Send to Device...).
                        Button { index -= 1 } label: { Image(systemName: "chevron.left") }
                            .disabled(index == 0)
                        // Stesso balloon di «Use this cover…» (pulsante bordato piccolo, non cliccabile) ma di larghezza
                        // fissa, calcolata sul testo più lungo («File N di N»): non si allarga passando alle doppie cifre.
                        Button {} label: {
                            Text(t("drop_progress", index + 1, items.count)).font(.caption).lineLimit(1)
                                .frame(width: progressWidth)
                        }
                        .buttonStyle(.flat)
                        .controlSize(.small)
                        .allowsHitTesting(false)
                        Button { index += 1 } label: { Image(systemName: "chevron.right") }
                            .disabled(index >= items.count - 1)
                    }
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .alert(t("alert_drop_send_title"), isPresented: $confirmSend) {
            Button(t("drop_continue")) { onSend(items) }
            Button(t("button_cancel"), role: .cancel) {}
        } message: {
            Text(sendMessage)
        }
        // Brano già in Music e file senza copertina: come prima anteprima si propone quella di Music (poi, come per ogni
        // copertina, compare «Usa questa copertina per altri N file dell'album»).
        .task(id: "\(items[index].id)|\(libraryMatch(items[index]) ?? "")") {
            let item = items[index]
            guard item.artwork == nil, libraryMatch(item) != nil, !musicCoverTried.contains(item.id) else { return }
            musicCoverTried.insert(item.id)
            if let data = await libraryArtwork(item), let position = items.firstIndex(where: { $0.id == item.id }),
               items[position].artwork == nil {
                items[position].artwork = data
            }
        }
    }

    // MARK: Intestazione (copertina, titolo, artista, album)

    private func header(_ item: DroppedTrackInfo) -> some View {
        HStack(alignment: .top, spacing: 20) {
            // Altezza fissa: la copertina e il resto del pannello non si spostano quando sotto compare il pulsante
            // «Usa questa copertina…» (o l'indicatore di ricerca).
            VStack(alignment: .leading, spacing: 6) {
                cover(item)
                coverStatus(item)
            }
            .frame(width: 150, height: 150 + 6 + 19, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayTitle).font(.system(size: 21, weight: .bold)).lineLimit(2)
                if !item.artist.isEmpty { Text(item.artist).font(.system(size: 14)).foregroundStyle(.secondary) }
                if !item.album.isEmpty { Text(item.album).font(.system(size: 14)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.12))
    }

    private func cover(_ item: DroppedTrackInfo) -> some View {
        Group {
            if let data = item.artwork, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.18)
                    Text(t("drop_no_cover")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 150, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { coverArrows(item) }
        // Click destro sulla copertina: ricerca online, come nel pannello Music.
        .contextMenu {
            if canSearch {
                Button { searchCover() } label: {
                    Label(t("menu_artwork_online_fix"), systemImage: "waveform.badge.magnifyingglass")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    /// Frecce sovraimposte alla copertina (solo con più candidati). Il simbolo dice quante copertine restano in quella
    /// direzione: nessuna = niente freccia, una sola = chevron singolo, più di una = chevron doppio.
    @ViewBuilder
    private func coverArrows(_ item: DroppedTrackInfo) -> some View {
        if let state = covers[item.id], !state.searching, state.candidates.count > 1 {
            let last = state.candidates.count - 1
            let before = state.position
            let after = last - state.position
            HStack {
                if before > 0 {
                    arrowButton(before == 1 ? "chevron.left" : "chevron.left.2") { showCandidate(state.position - 1) }
                }
                Spacer(minLength: 0)
                if after > 0 {
                    arrowButton(after == 1 ? "chevron.right" : "chevron.right.2") { showCandidate(state.position + 1) }
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

    @ViewBuilder
    private func coverStatus(_ item: DroppedTrackInfo) -> some View {
        let state = covers[item.id]
        if state?.searching == true {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(t("fix_artwork_searching")).font(.caption).foregroundStyle(.secondary)
            }
        } else if state?.notFound == true {
            Text(t("fix_artwork_not_found")).font(.caption).foregroundStyle(.secondary)
        }
        // File dello stesso album (stesso artista) con una copertina diversa: si può dare loro quella di questo file.
        let others = siblingsNeedingCover(of: item)
        if item.artwork != nil, !others.isEmpty, state?.searching != true {
            Button { applyCoverToAlbum() } label: {
                Text(t("drop_apply_album", others.count)).font(.caption).lineLimit(1)
            }
            .buttonStyle(.flat)
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// Chiave di raggruppamento: artista dell'album (o artista) + album, senza maiuscole/accenti; nil senza album.
    private func albumKey(_ info: DroppedTrackInfo) -> String? {
        func norm(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let album = norm(info.album)
        guard !album.isEmpty else { return nil }
        return norm(info.albumArtist.isEmpty ? info.artist : info.albumArtist) + "|" + album
    }

    /// Posizioni degli altri file dello stesso album la cui copertina è diversa da quella del file mostrato.
    private func siblingsNeedingCover(of item: DroppedTrackInfo) -> [Int] {
        guard let key = albumKey(item) else { return [] }
        return items.indices.filter { i in
            items[i].id != item.id && albumKey(items[i]) == key && items[i].artwork != item.artwork
        }
    }

    private func applyCoverToAlbum() {
        let item = items[index]
        for i in siblingsNeedingCover(of: item) {
            items[i].artwork = item.artwork
            items[i].coverChanged = true
            covers[items[i].id] = nil
        }
    }

    private func searchCover() {
        let snapshot = items[index]
        let id = snapshot.id
        covers[id] = CoverSearch(searching: true)
        Task { @MainActor in
            let found = await search(snapshot)
            guard let position = items.firstIndex(where: { $0.id == id }) else { return }
            if let first = found.first {
                items[position].artwork = first
                items[position].coverChanged = true
                covers[id] = CoverSearch(candidates: found)
            } else {
                covers[id] = CoverSearch(notFound: true)
            }
        }
    }

    private func showCandidate(_ position: Int) {
        let id = items[index].id
        guard var state = covers[id], state.candidates.indices.contains(position) else { return }
        state.position = position
        covers[id] = state
        items[index].artwork = state.candidates[position]
        items[index].coverChanged = true
    }

    // MARK: Righe dei campi

    /// File che risultano già nella libreria Music, quelli bloccati (in Music ma solo cloud/protetti) e quelli inviabili.
    private var identifiedCount: Int { items.filter { libraryMatch($0) != nil }.count }
    private var blockedCount: Int { items.filter { isBlocked($0) }.count }

    private var sendMessage: String {
        // Con «Chiedi conferma prima di aggiungere a Music» acceso, l'aggiunta si decide dopo: qui si dice solo quanti non sono in Music.
        var text = t(AppSettings.shared.confirmBeforeMusicChanges ? "alert_drop_send_message_ask" : "alert_drop_send_message",
                     items.count, identifiedCount, items.count - identifiedCount)
        if blockedCount > 0 { text += "\n\n" + t("alert_drop_send_blocked", blockedCount) }
        return text
    }

    private let labelWidth: CGFloat = 110
    /// Altezza unica di tutte le righe (campi in sola lettura e modificabili): la finestra non cambia misura tra un file e l'altro.
    private let fieldHeight: CGFloat = 24

    /// Larghezza fissa del balloon «File n di N»: quella del testo più lungo possibile (ultimo file) più margine.
    private var progressWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let widest = (t("drop_progress", items.count, items.count) as NSString).size(withAttributes: [.font: font]).width
        return max(ceil(widest) + 36, 120)
    }

    /// Larghezza del pulsante «Send to Device»: la stessa del pannello Music (testo + icona + margini).
    private var sendButtonWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return ceil((t("button_send_to_watch") as NSString).size(withAttributes: [.font: font]).width) + 34
    }

    /// Campo di testo: in sola lettura se il file lo conteneva, altrimenti modificabile.
    private func row(_ label: String, _ key: String, _ keyPath: WritableKeyPath<DroppedTrackInfo, String>,
                     width: CGFloat? = nil, fixed: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .trailing)
            fieldBox(key: key, keyPath: keyPath, width: width, fixed: fixed)
            if width != nil { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder
    private func fieldBox(key: String, keyPath: WritableKeyPath<DroppedTrackInfo, String>,
                          width: CGFloat?, fixed: String? = nil) -> some View {
        if let fixed {
            readOnlyBox(fixed, width: width)
        } else if items[index].locked.contains(key) {
            readOnlyBox(items[index][keyPath: keyPath], width: width)
        } else {
            TextField("", text: Binding(get: { items[index][keyPath: keyPath] },
                                        set: { items[index][keyPath: keyPath] = $0 }))
                .textFieldStyle(.plain)
                .padding(.horizontal, 6)
                .frame(maxWidth: width ?? .infinity, minHeight: fieldHeight, maxHeight: fieldHeight, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.45), lineWidth: 1))
        }
    }

    private func readOnlyBox(_ text: String, width: CGFloat?) -> some View {
        Text(text).textSelection(.enabled).lineLimit(1)
            .padding(.horizontal, 6)
            .frame(maxWidth: width ?? .infinity, minHeight: fieldHeight, maxHeight: fieldHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.10)))
    }

    /// «n di N» (traccia, disco).
    private func pairRow(_ label: String,
                         _ first: (String, WritableKeyPath<DroppedTrackInfo, String>),
                         _ second: (String, WritableKeyPath<DroppedTrackInfo, String>)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .trailing)
            fieldBox(key: first.0, keyPath: first.1, width: 56)
            Text(t("drop_of")).foregroundStyle(.secondary)
            fieldBox(key: second.0, keyPath: second.1, width: 56)
            Spacer(minLength: 0)
        }
    }

    private func toggleRow(_ label: String, _ keyPath: WritableKeyPath<DroppedTrackInfo, Bool>, locked: Bool) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: labelWidth, height: 1)
            Toggle(label, isOn: Binding(get: { items[index][keyPath: keyPath] },
                                        set: { items[index][keyPath: keyPath] = $0 }))
                .disabled(locked)
            Spacer(minLength: 0)
        }
        .frame(height: fieldHeight)
    }
}


// MARK: - Scelta manuale dell'immagine del prodotto

/// Elenco dei prodotti Garmin (file `deviceTypes` già memorizzato, o scaricato se manca o è vecchio) con ricerca:
/// un click sceglie l'immagine per il dispositivo mostrato.
struct DeviceImagePickerSheet: View {
    let onPick: (URL) -> Void
    let onClose: () -> Void
    @State private var devices: [DeviceImageService.CatalogDevice] = []
    @State private var isLoading = true
    @State private var search = ""

    private var filtered: [DeviceImageService.CatalogDevice] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? devices : devices.filter { $0.searchText.contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("image_picker_title")).font(.headline)
            Text(t("image_picker_hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(t("image_picker_search"), text: $search).textFieldStyle(.roundedBorder)
            if isLoading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.frame(maxHeight: .infinity)
            } else if devices.isEmpty {
                Text(t("image_picker_empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { device in
                    Button {
                        onPick(device.imageURL)
                        onClose()
                    } label: {
                        HStack(spacing: 10) {
                            CatalogDeviceImage(url: device.imageURL)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.displayName)
                                let detail = ([device.partNumber] + device.additionalNames.prefix(2)).filter { !$0.isEmpty }.joined(separator: " · ")
                                if !detail.isEmpty {
                                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            // Solo l'informativa: quanti prodotti ha letto dall'elenco di Garmin.
            if !isLoading {
                Text(t("image_picker_loaded", devices.count)).font(.caption).foregroundStyle(.primary)
            }
            HStack {
                Spacer()
                Button(t("button_cancel"), action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .modifier(SheetFrame(width: 520, height: 560))
        // Con il pannello aperto dopo il ciclo corrente (`onNextRunLoop`) il caricamento normale funziona.
        .task {
            devices = await DeviceImageService.catalogDevices()
            isLoading = false
        }
    }
}


/// 2.1 Beta 2: conferma dell'eliminazione di brani dal dispositivo. Mostra in un riquadro i brani scelti (anche con
/// selezioni sparse tra Brani/Artisti/Album), in un altro le playlist del dispositivo che li contengono, e spiega cosa
/// succede alla conferma. Le playlist che resterebbero vuote vengono eliminate completamente.
struct DeviceDeleteConfirmView: View {
    let items: [DeviceTrack]
    let playlists: [TrackGroup<DeviceTrack>]
    let excludedPlaylistIDs: Set<String>
    let onCancel: () -> Void
    let onConfirm: () -> Void

    /// Playlist toccate, con il numero di brani prima e dopo.
    private var impacted: [(name: String, before: Int, after: Int)] {
        let deleted = Set(items.map(\.id))
        return playlists.compactMap { g in
            guard !excludedPlaylistIDs.contains(g.id) else { return nil }
            let inside = g.tracks.filter { deleted.contains($0.id) }.count
            guard inside > 0 else { return nil }
            return (g.title, g.tracks.count, g.tracks.count - inside)
        }
    }

    var body: some View {
        let impacted = self.impacted
        let emptied = impacted.filter { $0.after == 0 }.count
        VStack(alignment: .leading, spacing: 14) {
            Text(t("alert_delete_title")).font(.headline)

            box(title: t("delete_sheet_tracks_title", items.count)) {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        Text(item.title).lineLimit(1)
                        Text([item.artist, item.album].filter { !$0.isEmpty }.joined(separator: " · "))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                }
            }

            box(title: t("delete_sheet_playlists_title", impacted.count)) {
                if impacted.isEmpty {
                    Text(t("delete_sheet_no_playlists")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(impacted.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 6) {
                        Text(p.name).lineLimit(1)
                        Spacer(minLength: 8)
                        if p.after == 0 {
                            Label(t("delete_sheet_playlist_empty"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(statusIconRed)
                        } else {
                            Text(t("delete_sheet_playlist_update", p.before, p.after)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(t("delete_sheet_what_title")).font(.subheadline.weight(.semibold))
                Text("• " + t("delete_sheet_step_tracks", items.count))
                Text("• " + t("delete_sheet_step_folders"))
                if !impacted.isEmpty { Text("• " + t("delete_sheet_step_playlists")) }
                if emptied > 0 { Text("• " + t("delete_sheet_step_emptied", emptied)) }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center) {
                // «Questa azione non si può annullare»: rosso e grassetto, a sinistra, centrata in verticale rispetto ai pulsanti.
                Text(t("alert_delete_message"))
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(t("button_cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(impacted.isEmpty ? t("button_delete") : t("button_delete_update_playlists"),
                       role: .destructive, action: onConfirm)
                    .buttonStyle(.flatProminentRoomy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 700)   // largo abbastanza per avviso + due pulsanti sulla stessa riga
    }

    /// Altezza massima dei due riquadri: 150, ridotta se la finestra principale è bassa (il pannello resta entro il 90 % della sua altezza).
    private var boxMaxHeight: CGFloat {
        min(150, max(44, (MainWindowMetrics.shared.height * 0.9 - 300) / 2))
    }

    /// Riquadro con titolo e righe scorrevoli (altezza massima fissa).
    private func box<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 44, maxHeight: boxMaxHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
    }
}


/// Marcatura di un file noto nel navigatore dei file del dispositivo (2.1 Beta 3).
private struct DeviceFileMark {
    enum Kind { case musicManager, service, app, maps }
    let text: String
    let kind: Kind
    var color: Color {
        switch kind {
        case .musicManager: return statusIconGreen
        case .service: return StorageBarView.servicesColor
        case .app: return Color.secondary
        case .maps: return StorageBarView.mapsColor
        }
    }
}

/// Riga della tabella del navigatore: la voce MTP più i valori usati per ordinare le colonne.
private struct DeviceFileRow: Identifiable {
    let entry: MTPEntry
    let mark: DeviceFileMark?
    var id: UInt32 { entry.id }
    var isFolder: Bool { entry.isFolder }
    var nameKey: String { entry.name.lowercased() }
    var kind: String {
        if entry.isFolder { return t("device_files_kind_folder") }
        let ext = (entry.name as NSString).pathExtension
        return ext.isEmpty ? t("device_files_kind_file") : ext.uppercased()
    }
    var sizeValue: UInt64 { entry.isFolder ? 0 : entry.size }
    var modified: Date { entry.modified }
}

/// 2.1 Beta 3 (solo diagnostica): navigatore dei file del dispositivo MTP, in SOLA LETTURA sul dispositivo.
/// Tabella con colonne ordinabili (Nome, Tipo, Dimensione, Modificato), barra del percorso cliccabile, marcature dei
/// file noti (cartella Music di Music Manager; file delle app e dei servizi di streaming, riconosciuti dal nome del
/// file nell'XML del dispositivo) e copia dei file selezionati SUL MAC. Nessuna azione modifica, elimina o rinomina
/// qualcosa sul dispositivo.
struct DeviceFileBrowserView: View {
    @ObservedObject var vm: AppViewModel
    let onClose: () -> Void

    @State private var storageID: UInt32 = 0
    /// Cartelle percorse dalla radice (vuoto = radice della memoria).
    @State private var stack: [(id: UInt32, name: String)] = []
    @State private var entries: [MTPEntry] = []
    @State private var loading = false
    @State private var failed = false
    @State private var reloadToken = 0
    @State private var selection = Set<UInt32>()
    @State private var sortOrder = [KeyPathComparator(\DeviceFileRow.nameKey)]
    /// Nome del file (senza estensione, maiuscolo) → app dell'orologio, dall'XML.
    @State private var appFiles: [String: DeviceAppInfo] = [:]
    /// Nome del file (senza estensione, maiuscolo) → etichetta della mappa («Maps - Europe»).
    @State private var mapFiles: [String: String] = [:]
    @State private var copying = false
    @State private var copyMessage: String?

    private var currentParent: UInt32 { stack.last?.id ?? mtpRootParent }
    private var pathText: String { "/" + stack.map(\.name).joined(separator: "/") }
    private var loadKey: String { "\(storageID)-\(currentParent)-\(reloadToken)" }

    /// Voci con la loro marcatura, ordinate come richiesto dalle colonne; le cartelle restano sempre prima dei file.
    private var sortedRows: [DeviceFileRow] {
        let rows = entries.map { DeviceFileRow(entry: $0, mark: mark(for: $0)) }.sorted(using: sortOrder)
        return rows.filter(\.isFolder) + rows.filter { !$0.isFolder }
    }

    private func mark(for e: MTPEntry) -> DeviceFileMark? {
        let names = stack.map { $0.name.lowercased() }
        if names.first == "music" || (names.isEmpty && e.isFolder && e.name.lowercased() == "music") {
            return DeviceFileMark(text: "Music Manager", kind: .musicManager)
        }
        if !e.isFolder, let label = mapFiles[(e.name as NSString).deletingPathExtension.uppercased()] {
            return DeviceFileMark(text: label, kind: .maps)
        }
        if names.contains("apps"), !e.isFolder {
            let stem = (e.name as NSString).deletingPathExtension.uppercased()
            if let app = appFiles[stem] {
                return DeviceFileMark(text: app.name, kind: app.isStreamingService ? .service : .app)
            }
        }
        return nil
    }

    /// Percorso completo di una voce sul dispositivo, come lo mostra la barra del percorso.
    private func fullPath(_ e: MTPEntry) -> String { (pathText == "/" ? "" : pathText) + "/" + e.name }

    private func copyPaths(_ rows: [DeviceFileRow]) {
        let text = rows.map { fullPath($0.entry) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copia i file indicati in una cartella del Mac scelta dall'utente. Il dispositivo si legge soltanto.
    private func copyToMac(_ files: [MTPEntry]) {
        guard !files.isEmpty, !copying else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = t("device_files_copy_here")
        panel.message = t("device_files_copy_panel_message", files.count)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        copying = true
        copyMessage = nil
        Task {
            var copied: [URL] = []
            var failedCount = 0
            for file in files {
                if let url = await vm.copyDeviceFileToMac(file, to: folder) { copied.append(url) } else { failedCount += 1 }
            }
            copying = false
            copyMessage = failedCount == 0
                ? t("device_files_copied", copied.count)
                : t("device_files_copied_failed", copied.count, failedCount)
            if !copied.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(copied) }
        }
    }

    private var selectedFiles: [MTPEntry] {
        entries.filter { selection.contains($0.id) && !$0.isFolder }
    }

    /// Barra del percorso: ogni cartella è un pulsante che porta a quel livello.
    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button { stack = [] } label: { Image(systemName: "externaldrive") }
                .buttonStyle(.link)
                .help(t("device_files_root"))
            ForEach(Array(stack.enumerated()), id: \.offset) { index, folder in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                Button(folder.name) { stack = Array(stack.prefix(index + 1)) }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .disabled(index == stack.count - 1)
            }
        }
        .font(.callout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(t("device_files_title")).font(.headline)
                Spacer()
                if let storages = vm.device?.storages, storages.count > 1 {
                    Picker(t("label_storage"), selection: Binding(get: { storageID }, set: { storageID = $0; stack = [] })) {
                        ForEach(storages) { st in Text(st.name).tag(st.id) }
                    }
                    .fixedSize()
                }
                Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.flat)
                    .help(t("tooltip_refresh_device"))
            }
            HStack(spacing: 8) {
                Button { _ = stack.popLast() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.flat)
                    .disabled(stack.isEmpty)
                    .help(t("device_files_back"))
                ScrollView(.horizontal, showsIndicators: false) { breadcrumb }
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pathText, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.flat)
                    .help(t("device_files_copy_path"))
                if loading { ProgressView().controlSize(.small) }
            }

            Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(t("device_files_col_name"), value: \.nameKey) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.isFolder ? "folder" : "doc").frame(width: 18)
                            .foregroundStyle(row.isFolder ? Color.accentColor : Color.secondary)
                        Text(row.entry.name).lineLimit(1).truncationMode(.middle)
                        if let mark = row.mark {
                            Text(mark.text)
                                .font(.caption2)
                                .lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(mark.color.opacity(0.18)))
                                .foregroundStyle(mark.color)
                        }
                    }
                }
                TableColumn(t("device_files_col_kind"), value: \.kind) { row in
                    Text(row.kind).foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 90, max: 140)
                TableColumn(t("device_files_col_size"), value: \.sizeValue) { row in
                    Text(row.isFolder ? "" : ByteCountFormatter.string(fromByteCount: Int64(row.entry.size), countStyle: .file))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 90, max: 130)
                TableColumn(t("device_files_col_modified"), value: \.modified) { row in
                    Text(row.modified.formatted(date: .numeric, time: .shortened)).foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 140, max: 190)
            }
            .scrollContentBackground(.hidden)   // il vetro del pannello si vede attraverso la tabella
            .overlay {
                if failed {
                    Text(t("device_files_failed")).foregroundStyle(.secondary)
                } else if entries.isEmpty && !loading {
                    Text(t("device_files_empty")).foregroundStyle(.secondary)
                }
            }
            .contextMenu(forSelectionType: UInt32.self) { ids in
                let picked = sortedRows.filter { ids.contains($0.id) }
                if !picked.isEmpty {
                    Button(t("device_files_copy_path"), systemImage: "doc.on.doc") { copyPaths(picked) }
                    let files = picked.filter { !$0.isFolder }.map(\.entry)
                    if !files.isEmpty {
                        Button(t("device_files_copy_to_mac"), systemImage: "square.and.arrow.down") { copyToMac(files) }
                    }
                }
            } primaryAction: { ids in
                // Doppio clic (o Invio): si entra nella cartella.
                if ids.count == 1, let row = sortedRows.first(where: { ids.contains($0.id) }), row.isFolder {
                    stack.append((row.entry.id, row.entry.name))
                }
            }
            .frame(minHeight: 90, maxHeight: .infinity)   // si adatta all'altezza del pannello (finestra ridotta)

            HStack {
                Text(t("device_files_readonly_note")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if copying {
                    ProgressView().controlSize(.small)
                    Text(t("device_files_copying")).font(.caption).foregroundStyle(.secondary)
                } else if let copyMessage {
                    Text(copyMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text(t("device_files_items", entries.count)).font(.caption).foregroundStyle(.secondary)
                Button(t("device_files_copy_to_mac")) { copyToMac(selectedFiles) }
                    .disabled(selectedFiles.isEmpty || copying)
                Button(t("button_close"), action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .modifier(SheetFrame(width: 860, height: 560))
        .task(id: loadKey) {
            if storageID == 0 { storageID = vm.selectedStorageID != 0 ? vm.selectedStorageID : (vm.device?.storages.first?.id ?? 0) }
            guard storageID != 0 else { return }
            loading = true; failed = false
            selection = []
            if let list = await vm.listDeviceFolder(storageID: storageID, parentID: currentParent) {
                entries = list
            } else {
                entries = []; failed = true
            }
            loading = false
        }
        .task {
            // Nomi dei file delle app (Amazon Music, Deezer, Spotify…) dall'XML: serve alle marcature.
            appFiles = await vm.loadDeviceAppFileMap()
            mapFiles = await vm.loadDeviceMapFileLabels()
        }
    }
}

/// Larghezza dei pulsanti dei pannelli principali (stessa per tutti): quella dell'etichetta più lunga fra tutte le lingue +
/// icona + margine. Usata anche dai pulsanti della finestra di trasferimento (Cancel / Close), che hanno la stessa misura.
func mainBarButtonWidth() -> CGFloat {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    // Misurata su TUTTE le lingue (non solo la corrente), così i pulsanti non cambiano larghezza cambiando lingua.
    let keys = ["button_clear_custom_playlist", "button_save_to_apple_music", "menu_load_playlist_file", "button_save_to_file", "button_clear_selection",
                "button_send_to_playlist", "button_send", "button_delete_all", "button_delete",
                "button_connect", "button_disconnect", "button_eject"]
    let widest = AppLanguage.allCases.flatMap { lang in
        keys.map { (tFor(lang, $0) as NSString).size(withAttributes: [.font: font]).width }
    }.max() ?? 0
    // icona (~16) + spazio tra icona e testo (~6) + margine interno dei pulsanti piatti (~12 con il riempimento dello stile)
    return ceil(widest) + 24
}


/// Stile di etichetta: titolo + icona normalmente, solo icona in modalità compatta (il tooltip `.help` resta).
struct CompactAwareLabelStyle: LabelStyle {
    @Environment(\.compactPane) private var compact
    /// Distanza in punti tra icona e testo (modificare qui il valore per cambiarla in tutti i pulsanti che usano questo stile).
    static let iconTextSpacing: CGFloat = 4
    func makeBody(configuration: Configuration) -> some View {
        if compact { configuration.icon }
        else { HStack(spacing: Self.iconTextSpacing) { configuration.icon; configuration.title } }
    }
}


/// Pulsante doppio «Carica | Salva» della barra della Custom Playlist: una sola capsula con due metà separate da un filo.
/// «Carica da file» è sempre disponibile; «Salva su file» solo con almeno un brano e un titolo. In interfaccia ridotta restano le icone.
/// Per tornare ai due pulsanti alternati: `ContentView.swift.prima-carica-salva`.
private struct LoadSaveSplitButton: View {
    let width: CGFloat
    let canSave: Bool
    let busy: Bool
    let onLoad: () -> Void
    let onSave: () -> Void

    private struct HalfStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onLoad) {
                Label(t("button_load_short"), systemImage: "square.and.arrow.down").labelStyle(CompactAwareLabelStyle())
            }
            .buttonStyle(HalfStyle())
            .disabled(busy)
            .help(t("tooltip_load_playlist_file"))
            Divider().frame(height: 16)
            Button(action: onSave) {
                Label(t("button_save_short"), systemImage: "square.and.arrow.up").labelStyle(CompactAwareLabelStyle())
            }
            .buttonStyle(HalfStyle())
            .disabled(!canSave || busy)
            .help(t("tooltip_save_playlist_file"))
        }
        .frame(width: width)
        .background(Capsule().fill(Color.primary.opacity(0.10)))
        .clipShape(Capsule())
    }
}

/// Pannelli semplici (una scelta) presentati come pannelli modali di vetro invece che come sheet: svuota Custom Playlist,
/// import di una playlist del dispositivo su una Custom già piena, nickname del dispositivo nuovo. Tenuti in un modificatore
/// a parte perché la catena di `body` di `ContentView` era al limite per il compilatore.
/// Per tornare agli sheet: `ContentView.swift.prima-pannelli-semplici`.
private struct SimpleGlassPanels: ViewModifier {
    @ObservedObject var vm: AppViewModel
    @Binding var showImagePicker: Bool
    @Binding var showMaps: Bool
    @Binding var showDeviceFiles: Bool
    /// Rapporto di trasferimento già aperto (evita di aprirne un secondo sopra).
    @State private var reportOpen = false

    func body(content: Content) -> some View {
        content
            .onChange(of: vm.transferReport?.id) { _, id in
                if id != nil { onNextRunLoop { presentTransferReport() } }
            }
            .onChange(of: showDeviceFiles) { _, on in
                if on { onNextRunLoop { presentDeviceFiles() } }
            }
            .onChange(of: vm.fixArtworkSession?.id) { _, id in
                if id != nil { onNextRunLoop { presentFixArtwork() } }
            }
            .onChange(of: vm.similarRequest?.id) { _, id in
                if id != nil { onNextRunLoop { presentSimilar() } }
            }
            .onChange(of: vm.pendingClearCustomPlaylist) { _, on in
                if on { onNextRunLoop { presentClearPlaylist() } }
            }
            .onChange(of: vm.pendingCustomPlaylistDuplicates != nil) { _, on in
                if on { onNextRunLoop { presentDuplicates() } }
            }
            .onChange(of: vm.pendingFileLoad?.fromDevice == true) { _, on in
                if on { onNextRunLoop { presentDevicePlaylistImport() } }
            }
            .onChange(of: vm.nicknamePromptDeviceID != nil) { _, on in
                if on { onNextRunLoop { presentNickname() } }
            }
            .onChange(of: showImagePicker) { _, on in
                if on { onNextRunLoop { presentImagePicker() } }
            }
            .onChange(of: vm.pendingUpdateNotices.isEmpty) { _, empty in
                if !empty { onNextRunLoop { presentUpdates() } }
            }
            .onChange(of: showMaps) { _, on in
                if on { onNextRunLoop { presentMaps() } }
            }
    }

    /// Svuota: 1. Salva su file (predefinito) · 2. Conferma svuotamento · 3. Annulla.
    private func presentClearPlaylist() {
        guard vm.pendingClearCustomPlaylist else { return }
        enum Choice { case save, clear, cancel }
        var choice = Choice.cancel
        GlassModalPresenter.run { close in
            ClearPlaylistConfirmView(onSave: { choice = .save; close() },
                                     onConfirm: { choice = .clear; close() },
                                     onCancel: { close() })
        }
        switch choice {
        case .save: vm.saveCustomPlaylistToFileThenClear()
        case .clear: vm.clearCustomPlaylist()
        case .cancel: vm.pendingClearCustomPlaylist = false
        }
    }

    /// Brani già presenti nella Custom Playlist: elenco completo con una spunta per brano (tutti spuntati).
    private func presentDuplicates() {
        guard let tracks = vm.pendingCustomPlaylistDuplicates else { return }
        var chosen: [LocalTrack]?
        GlassModalPresenter.run { close in
            DuplicateTracksView(tracks: tracks,
                                onAdd: { chosen = $0; close() },
                                onSkip: { close() })
        }
        if let chosen { vm.addChosenDuplicatesToCustomPlaylist(chosen) } else { vm.cancelPendingCustomPlaylistDuplicates() }
    }

    /// Import di una playlist del dispositivo con la Custom già piena.
    private func presentDevicePlaylistImport() {
        guard vm.pendingFileLoad?.fromDevice == true else { return }
        let name = vm.pendingFileLoad?.name ?? ""
        var choice: AppViewModel.FileLoadChoice?
        GlassModalPresenter.run { close in
            DevicePlaylistImportView(name: name,
                                     onPlaylistFirst: { choice = .currentAfterSaved; close() },
                                     onCurrentFirst: { choice = .savedAfterCurrent; close() },
                                     onReplace: { choice = .replace; close() },
                                     onCancel: { close() })
        }
        if let choice { vm.resolveFileLoad(choice) } else { vm.cancelFileLoad() }
    }

    /// Scelta dell'immagine del dispositivo dal catalogo Garmin.
    private func presentImagePicker() {
        guard showImagePicker else { return }
        GlassModalPresenter.run { close in
            DeviceImagePickerSheet(onPick: { vm.chooseDeviceImage($0) }, onClose: { close() })
        }
        showImagePicker = false
    }

    /// Aggiornamento software disponibile: OK chiude, «Ignora» non ripropone la stessa versione.
    private func presentUpdates() {
        guard !vm.pendingUpdateNotices.isEmpty else { return }
        let rows = vm.updateRows
        var ignored = false
        GlassModalPresenter.run { close in
            DeviceUpdateSheet(rows: rows, onOK: { close() }, onIgnore: { ignored = true; close() })
        }
        if ignored { vm.ignorePendingUpdates() } else { vm.closeUpdateSheet() }
    }

    /// «Trova simili»: pannello di vetro. Le azioni scelte (OK / Invia a Custom) si eseguono a pannello chiuso, così le finestre che
    /// possono seguire (copertine, duplicati) non si aprono dentro un altro pannello modale. Per tornare allo sheet:
    /// `ContentView.swift.prima-brani-simili` e `CatalogBrowser.swift.prima-brani-simili`.
    private func presentSimilar() {
        guard let request = vm.similarRequest else { return }
        enum Choice { case select(Set<String>), custom([LocalTrack]), device([LocalTrack]) }
        var choice: Choice?
        GlassModalPresenter.run { close in
            SimilarTracksSheet(request: request,
                               artworkProvider: vm.appleArtwork,
                               artworkRevision: vm.artworkRevision,
                               onPlay: { track, queue in vm.play(track, queue: queue) },
                               onOK: { choice = .select($0); close() },
                               onSendToCustom: { choice = .custom($0); close() },
                               canSendToDevice: vm.device != nil && !vm.isDeviceReadOnly && !vm.isBusy,
                               onSendToDevice: { choice = .device($0); close() },
                               onCancel: { close() })
        }
        vm.similarRequest = nil
        switch choice {
        case .select(let ids): vm.addToSelection(ids)
        case .custom(let list): vm.addTracksToCustomPlaylist(list)
        case .device(let list): Task { await vm.sendTracksToDevice(list) }
        case nil: break
        }
    }

    /// Rapporto di trasferimento: pannello di vetro «vivo» (si aggiorna mentre l'invio prosegue). «Close» (a invio concluso) lo chiude;
    /// durante l'invio c'è solo «Cancel» (con conferma). Per tornare allo sheet: `ContentView.swift.prima-report-vetro`.
    private func presentTransferReport() {
        guard vm.transferReport != nil, !reportOpen else { return }
        reportOpen = true
        GlassModalPresenter.run { close in
            TransferReportHost(vm: vm, onClose: { close() })
        }
        reportOpen = false
        if vm.transferReport != nil, !vm.isBusy { vm.closeTransferReport() }
    }

    /// Fix Artwork: pannello di vetro; il seguito (es. invio) riprende a pannello chiuso. Per tornare allo sheet: `ContentView.swift.prima-fix-artwork`.
    private func presentFixArtwork() {
        guard let session = vm.fixArtworkSession else { return }
        GlassModalPresenter.run { close in
            FixArtworkView(session: session, onClose: { close() })
        }
        // Chiuso senza Close/OK (es. Esc): termina la sessione come con «Close».
        if !session.isFinished { session.close() }
        vm.completeFixArtwork()
    }

    /// Navigatore dei file del dispositivo (sola lettura): pannello di vetro. Per tornare allo sheet: `ContentView.swift.prima-file-dispositivo`.
    private func presentDeviceFiles() {
        guard showDeviceFiles else { return }
        GlassModalPresenter.run { close in
            DeviceFileBrowserView(vm: vm, onClose: { close() })
        }
        showDeviceFiles = false
    }

    /// Mappe del dispositivo (o del volume): vista «viva», perché «Controlla» aggiorna i dati mentre il pannello è aperto.
    private func presentMaps() {
        guard showMaps else { return }
        GlassModalPresenter.run { close in
            MapsPanelHost(vm: vm, onClose: { close() })
        }
        showMaps = false
    }

    /// Dispositivo nuovo: si propone un nickname.
    private func presentNickname() {
        guard vm.nicknamePromptDeviceID != nil else { return }
        let model = vm.deviceModelText ?? vm.device?.friendlyName ?? t("device_default_name")
        var nickname: String?
        GlassModalPresenter.run { close in
            DeviceNicknamePromptView(model: model,
                                     onConfirm: { nickname = $0; close() },
                                     onSkip: { close() })
        }
        if let nickname { vm.confirmDeviceNickname(nickname) } else { vm.nicknamePromptDeviceID = nil }
    }
}


/// Contenuto del pannello del rapporto di trasferimento: legge lo stato dal view model a ogni aggiornamento.
private struct TransferReportHost: View {
    @ObservedObject var vm: AppViewModel
    let onClose: () -> Void

    var body: some View {
        Group {
            if let report = vm.transferReport {
                TransferReportView(report: report, isBusy: vm.isBusy,
                                   stopRequested: vm.transferStopRequested, wasStopped: vm.transferWasStopped,
                                   stopLocked: vm.transferStopLocked,
                                   onStop: { vm.requestTransferStop() },
                                   onClose: { vm.closeTransferReport(); onClose() })
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .onChange(of: vm.transferReport == nil) { _, gone in
            if gone { onClose() }
        }
    }
}

/// Contenuto del pannello delle mappe: legge i dati dal view model a ogni aggiornamento (volume o dispositivo).
private struct MapsPanelHost: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject private var settings = AppSettings.shared
    let onClose: () -> Void

    var body: some View {
        if vm.showingVolumeDevice {
            MapsSheet(catalog: vm.volumeMaps, checkEnabled: settings.checkDeviceUpdates, errorDetail: vm.volumeMapsError,
                      checkedAt: vm.volumeMapsCheckedAt, onRefresh: { await vm.refreshVolumeMaps() }, onClose: onClose)
        } else {
            MapsSheet(catalog: vm.deviceMaps, checkEnabled: settings.checkDeviceUpdates, errorDetail: vm.deviceMapsError,
                      checkedAt: vm.deviceMapsCheckedAt, onRefresh: { await vm.refreshDeviceMaps() }, onClose: onClose)
        }
    }
}


/// Immagine di un prodotto del catalogo Garmin: scaricata dal servizio (con cache su disco) invece che da `AsyncImage`, che
/// dentro un pannello modale di vetro non caricava le immagini. Per tornare indietro: `ContentView.swift.prima-immagini-catalogo`.
private struct CatalogDeviceImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task {
            guard image == nil else { return }
            image = await DeviceImageService.image(fromCatalogURL: url)
        }
    }
}
