import Foundation
import AVFoundation
import CoreAudio
import Combine
import ObjectiveC
import MediaPlayer
import AppKit

/// Motore di riproduzione audio locale per il mini player di Apple Music. Incapsula
/// AVPlayer ed espone solo lo stato osservabile (tempo corrente, durata, in riproduzione o
/// no): non conosce nulla della libreria Apple Music né della coda di brani, riceve solo un URL
/// da riprodurre. La logica "cosa riprodurre dopo" vive in AppViewModel.
@MainActor
final class PlayerService: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    /// Chiamato quando il brano corrente finisce da solo (non per una pausa manuale): usato da
    /// AppViewModel per passare automaticamente al brano successivo in coda.
    var onFinished: (() -> Void)?
    /// Brano successivo / precedente richiesti dai tasti multimediali o dal Centro di Controllo.
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    /// Informazioni del brano pubblicate al sistema ("In riproduzione"): le legge l'Apple TV (banner con copertina, artista e
    /// titolo), il Centro di Controllo e i tasti multimediali. Le imposta AppViewModel; qui si tengono solo per ripubblicarle.
    /// Interruttore: la registrazione dei comandi multimediali non rallentava l'avvio (la causa era la lettura della libreria),
    /// quindi è attiva. Mettere `false` per escludere del tutto le info «In riproduzione».
    private static let nowPlayingEnabled = true
    private var nowTitle: String?
    private var nowArtist: String?
    private var nowAlbum: String?
    private var nowArtwork: NSImage?

    /// Volume del mini player (0...1), ricordato tra un avvio e l'altro e applicato a ogni brano.
    @Published var volume: Float = {
        let v = UserDefaults.standard.object(forKey: "player_volume") as? Float
        return v ?? 1
    }() {
        didSet {
            UserDefaults.standard.set(volume, forKey: "player_volume")
            // Aggiornamento che arriva dal dispositivo (cursore del pannello AirPlay di sistema): non si riscrive sul dispositivo.
            if syncingVolumeFromDevice { return }
            lastUserVolumeChange = Date()
            applyVolume(changedByUser: true)
        }
    }

    /// Un solo `AVPlayer` per tutta la vita dell'app (si cambia solo il brano): il pulsante AirPlay è legato a
    /// questo oggetto, quindi l'uscita scelta (es. Apple TV) resta valida da un brano all'altro.
    /// Con `AVAudioPlayer` il selettore di sistema non poteva instradare la riproduzione: l'audio restava sul Mac.
    let routePlayer = AVPlayer()
    /// Vero quando la riproduzione sta andando su un dispositivo AirPlay (Apple TV, HomePod…).
    @Published private(set) var isExternalPlayback = false
    private var externalObservation: NSKeyValueObservation?
    private var airPlayModeObserver: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var currentItem: AVPlayerItem?
    private var timer: Timer?

    /// Vero se l'ultimo tentativo di regolare il volume del dispositivo di uscita è riuscito **ed è stato verificato** (il volume
    /// riletto coincide). Solo allora il guadagno del player resta a 1; altrimenti il cursore agisce sul guadagno del player.
    private var deviceVolumeHandled = false

    /// Applica il volume. Con AirPlay `AVPlayer.volume` può non agire sul dispositivo remoto: quando l'utente muove il cursore si
    /// prova prima il volume del dispositivo (contesto di uscita AVFoundation, poi uscita di sistema) e si **verifica** che sia
    /// cambiato davvero. Se nessuno lo regola (per esempio un dispositivo senza controllo del volume, come gli altoparlanti del
    /// Mac) il cursore ripiega sul guadagno del player, così il volume funziona sempre. Il volume del dispositivo si tocca solo
    /// quando è l'utente a muovere il cursore, mai all'avvio di un brano o al cambio di uscita.
    private func applyVolume(changedByUser: Bool = false) {
        let systemAirPlay = SystemOutputVolume.defaultOutputIsAirPlay()
        let remoteRoute = AirPlayRouteVolume.routeIsRemote(player: routePlayer)
        let airPlay = isExternalPlayback || systemAirPlay || remoteRoute
        if changedByUser {
            if airPlay {
                AppLog.debug("AirPlay volume: cursore \(volume) — riproduzioneEsterna=\(isExternalPlayback) uscitaSistemaAirPlay=\(systemAirPlay) percorsoRemoto=\(remoteRoute) uscitaMac=\(SystemOutputVolume.defaultOutputName() ?? "?")")
                AppLog.debug("AirPlay volume: dispositivi del percorso — \(AirPlayRouteVolume.describeDevices(player: routePlayer))")
                // Con un percorso remoto (ampli AirPlay) si regola solo il dispositivo del percorso, mai il volume del Mac.
                let routeHandled = AirPlayRouteVolume.set(volume, player: routePlayer)
                let systemHandled = !routeHandled && !remoteRoute && SystemOutputVolume.setDefaultOutputVolume(volume)
                deviceVolumeHandled = routeHandled || systemHandled
                AppLog.debug("AirPlay volume: esito — dispositivo=\(routeHandled) sistema=\(systemHandled) guadagnoPlayer=\(deviceVolumeHandled ? 1 : volume)")
                // Un dispositivo di rete (Apple TV) applica il volume con un po' di ritardo: la rilettura immediata può vedere
                // ancora il valore vecchio. Se non è andata, si ricontrolla dopo un istante.
                if !deviceVolumeHandled && remoteRoute { scheduleRouteVolumeRecheck(volume) }
            } else {
                deviceVolumeHandled = false
            }
        } else if !airPlay {
            deviceVolumeHandled = false
        }
        routePlayer.volume = deviceVolumeHandled ? 1 : volume
    }

    private var recheckTask: Task<Void, Never>?

    // MARK: Cursore del volume che segue il dispositivo AirPlay

    private var syncingVolumeFromDevice = false
    private var lastUserVolumeChange = Date.distantPast
    private var volumeSyncTimer: Timer?

    /// Ultima lettura del volume del dispositivo remoto: il cursore dell'app si aggiorna solo quando il valore è rimasto fermo
    /// per due letture di fila (≈0,3 s), cioè a movimento finito, e non mentre lo si trascina nel pannello AirPlay di sistema.
    private var lastRouteReading: Float?

    /// Il volume del dispositivo AirPlay può cambiare fuori dall'app (cursore del pannello AirPlay di sistema, telecomando): ogni
    /// 0,3 s, con un dispositivo remoto nel percorso, si legge il suo volume; quando è fermo ed è diverso dal cursore, questo
    /// salta al valore finale. Si legge soltanto: il volume del dispositivo non viene mai scritto da qui. Dopo un movimento del
    /// cursore dell'app si aspetta un secondo e mezzo, per non contrastare chi lo sta trascinando.
    private func syncVolumeFromRoute() {
        guard Date().timeIntervalSince(lastUserVolumeChange) > 1.5,
              AirPlayRouteVolume.routeIsRemote(player: routePlayer),
              let current = AirPlayRouteVolume.currentVolume(player: routePlayer) else {
            lastRouteReading = nil
            return
        }
        let still = lastRouteReading.map { abs($0 - current) < 0.005 } ?? false
        lastRouteReading = current
        guard still, abs(current - volume) > 0.02 else { return }
        AppLog.debug("AirPlay volume: il dispositivo è a \(current), il cursore a \(volume): il cursore lo segue")
        syncingVolumeFromDevice = true
        volume = current
        syncingVolumeFromDevice = false
        deviceVolumeHandled = true
        routePlayer.volume = 1
    }

    /// Rilettura ritardata del volume del dispositivo remoto (0,5 s dopo l'ultimo movimento del cursore): se nel frattempo il
    /// dispositivo ha applicato il livello richiesto, il volume del dispositivo è quello giusto e il guadagno del player torna a 1
    /// (altrimenti i due si sommerebbero).
    private func scheduleRouteVolumeRecheck(_ level: Float) {
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, abs(self.volume - level) < 0.001 else { return }
            let matches = AirPlayRouteVolume.volumeMatches(level, player: self.routePlayer)
            AppLog.debug("AirPlay volume: rilettura dopo 0,5 s — livello richiesto \(level), corrisponde=\(matches) — \(AirPlayRouteVolume.describeDevices(player: self.routePlayer))")
            if matches {
                self.deviceVolumeHandled = true
                self.routePlayer.volume = 1
            }
        }
    }

    override init() {
        super.init()
        if Self.nowPlayingEnabled { setupRemoteCommands() }
        // Impostazioni ▸ Avanzate ▸ «AirPlay come audio»: senza riproduzione esterna l'audio va al dispositivo come a un ampli AirPlay.
        routePlayer.allowsExternalPlayback = !AppSettings.shared.airPlayAsAudio
        airPlayModeObserver = AppSettings.shared.$airPlayAsAudio.dropFirst().sink { [weak self] asAudio in
            Task { @MainActor in
                self?.routePlayer.allowsExternalPlayback = !asAudio
                AppLog.debug("AirPlay: riproduzione esterna \(asAudio ? "disattivata (audio)" : "attivata")")
            }
        }
        volumeSyncTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncVolumeFromRoute() }
        }
        externalObservation = routePlayer.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] p, _ in
            let active = p.isExternalPlaybackActive
            Task { @MainActor in
                self?.isExternalPlayback = active
                self?.applyVolume()
            }
        }
    }

    /// Vero per i file su un volume montato (cartella condivisa di rete, disco esterno): `/Volumes/…`. È un
    /// semplice controllo sul testo del percorso, senza toccare il disco. Per questi file la preparazione
    /// avviene fuori dal thread principale (`playPrepared`); per i file locali resta quella diretta (`play`).
    nonisolated static func isOnMountedVolume(_ url: URL) -> Bool {
        url.path.hasPrefix("/Volumes/")
    }

    /// Risorsa preparata in background; `AVURLAsset` non è dichiarato `Sendable` in tutti gli SDK.
    private struct PreparedAsset: @unchecked Sendable {
        let asset: AVURLAsset
        let duration: TimeInterval
    }

    /// Incrementato a ogni `stop()` e a ogni nuova richiesta: una preparazione in background che finisce dopo
    /// che l'utente ha già cambiato brano si accorge di essere superata e non parte.
    private var generation = 0

    /// Riproduzione locale: tutto sul thread principale, come sempre (veloce).
    func play(url: URL) throws {
        stop()
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        begin(item: AVPlayerItem(url: url), duration: nil)
    }

    /// Riproduzione di un file su volume montato/di rete: controllo del file, apertura e lettura di
    /// durata/formato avvengono in un'attività in background; sul thread principale resta solo l'avvio
    /// finale. Se nel frattempo si è scelto un altro brano (o si è premuto stop), non fa nulla.
    func playPrepared(url: URL) async throws {
        stop()
        generation &+= 1
        let mine = generation
        let prepared = try await Task.detached(priority: .userInitiated) { () -> PreparedAsset in
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let asset = AVURLAsset(url: url)
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            guard playable else { throw CocoaError(.fileReadCorruptFile) }
            return PreparedAsset(asset: asset, duration: duration.isNumeric ? duration.seconds : 0)
        }.value
        guard mine == generation else { return }
        begin(item: AVPlayerItem(asset: prepared.asset), duration: prepared.duration)
    }

    /// Avvio vero e proprio, sul thread principale. `duration` nil = da leggere dal file.
    private func begin(item: AVPlayerItem, duration knownDuration: TimeInterval?) {
        currentItem = item
        applyVolume()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.onFinished?()
            }
        }
        routePlayer.replaceCurrentItem(with: item)
        routePlayer.play()
        currentTime = 0
        duration = knownDuration ?? 0
        isPlaying = true
        startTimer()
        publishNowPlaying()
        if knownDuration == nil {
            // La durata si legge dal file in modo asincrono.
            Task { @MainActor in
                if let d = try? await item.asset.load(.duration), d.isNumeric, self.currentItem === item {
                    self.duration = d.seconds
                    self.publishNowPlaying()
                }
            }
        }
    }

    func togglePlayPause() {
        guard currentItem != nil else { return }
        if routePlayer.rate > 0 {
            routePlayer.pause()
            isPlaying = false
        } else {
            routePlayer.play()
            isPlaying = true
        }
        publishNowPlaying()
    }

    /// Scorrimento manuale della posizione (slider di avanzamento nel mini player).
    func seek(to time: TimeInterval) {
        guard currentItem != nil else { return }
        let clamped = duration > 0 ? min(max(0, time), duration) : max(0, time)
        routePlayer.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        publishNowPlaying()
    }

    func stop() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        routePlayer.pause()
        routePlayer.replaceCurrentItem(with: nil)
        currentItem = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        if Self.nowPlayingEnabled {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
    }

    /// Imposta titolo, artista, album e copertina del brano in riproduzione (nil = nessuno) e li pubblica al sistema.
    func setNowPlaying(title: String?, artist: String?, album: String?, artwork: NSImage?) {
        nowTitle = title
        nowArtist = artist
        nowAlbum = album
        nowArtwork = artwork
        publishNowPlaying()
    }

    /// Contenitore per portare l'immagine nel blocco (non isolato) che il sistema richiama per la copertina.
    private struct ArtworkBox: @unchecked Sendable { let image: NSImage }

    /// Pubblica le informazioni "In riproduzione": il sistema (e l'Apple TV, via AirPlay) mostra il brano giusto, con copertina.
    /// Posizione e velocità servono al sistema per far avanzare da solo la barra del tempo; si ripubblicano a ogni pausa/ripresa/salto.
    private func publishNowPlaying() {
        guard Self.nowPlayingEnabled, currentItem != nil, let title = nowTitle else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let nowArtist, !nowArtist.isEmpty { info[MPMediaItemPropertyArtist] = nowArtist }
        if let nowAlbum, !nowAlbum.isEmpty { info[MPMediaItemPropertyAlbumTitle] = nowAlbum }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let image = nowArtwork {
            let box = ArtworkBox(image: image)
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in box.image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        AppLog.debug("In riproduzione: pubblicato \"\(title)\" — \(nowArtist ?? "")")
    }

    /// Tasti multimediali, Centro di Controllo e comandi dell'Apple TV: play, pausa, avanti, indietro, posizione.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.currentItem != nil, !self.isPlaying else { return }
                self.togglePlayPause()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.currentItem != nil, self.isPlaying else { return }
                self.togglePlayPause()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onNext?() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onPrevious?() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let t = self.routePlayer.currentTime().seconds
                self.currentTime = t.isFinite ? t : 0
            }
        }
    }
}


/// Volume dell'uscita audio predefinita del Mac, via CoreAudio. Serve in AirPlay, dove `AVPlayer.volume` non regola il
/// dispositivo remoto (altoparlante, Apple TV, HomePod): si agisce sul volume del dispositivo di sistema, come fa il
/// cursore del Centro di Controllo.
enum SystemOutputVolume {
    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    /// Nome dell'uscita predefinita del Mac (per esempio «Altoparlanti MacBook Air»); nil se non è leggibile.
    static func defaultOutputName() -> String? {
        guard let device = defaultOutputDevice() else { return nil }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    /// Vero se l'uscita predefinita è un dispositivo AirPlay.
    static func defaultOutputIsAirPlay() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeAirPlay
    }

    /// Legge il volume (0...1) dell'uscita predefinita con gli stessi selettori usati in scrittura; nil se non è leggibile.
    private static func readDefaultOutputVolume() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        func read(selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Float? {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: element)
            guard AudioObjectHasProperty(device, &address) else { return nil }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
        }
        return read(selector: 0x766D7663 /* 'vmvc' */, element: kAudioObjectPropertyElementMain)
            ?? read(selector: kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain)
            ?? read(selector: kAudioDevicePropertyVolumeScalar, element: 1)
    }

    /// Imposta il volume (0...1) dell'uscita predefinita. Prima prova CoreAudio sul dispositivo (volume «virtuale» principale
    /// 'vmvc', poi volume scalare principale e canali 1 e 2) e **verifica** rileggendo il valore: i dispositivi AirPlay, ricreati a
    /// ogni nuova sessione, a volte accettano la scrittura senza applicarla. Se la scrittura non riesce o la verifica fallisce,
    /// ripiega su «set volume output volume» (AppleScript di sistema), che agisce sull'uscita corrente qualunque sia il dispositivo.
    /// Restituisce vero se il volume risulta impostato.
    @discardableResult
    static func setDefaultOutputVolume(_ value: Float) -> Bool {
        let level = max(0, min(1, value))
        let wrote = writeDefaultOutputVolumeViaCoreAudio(level)
        if wrote {
            if let current = readDefaultOutputVolume() {
                AppLog.debug("Volume di sistema: CoreAudio scritto \(level), riletto \(current)")
                if abs(current - level) < 0.03 { return true }
            } else {
                AppLog.debug("Volume di sistema: CoreAudio scritto \(level), volume non leggibile (non verificabile)")
                return true   // scrittura riuscita ma volume non leggibile: non si può verificare
            }
        } else {
            AppLog.debug("Volume di sistema: CoreAudio non ha accettato la scrittura, si prova AppleScript")
        }
        var error: NSDictionary?
        let script = NSAppleScript(source: "set volume output volume \(Int((level * 100).rounded()))")
        script?.executeAndReturnError(&error)
        guard error == nil else {
            AppLog.debug("Volume di sistema: AppleScript in errore — \(String(describing: error))")
            return false
        }
        // Verifica: se il volume dell'uscita è leggibile deve coincidere con quello richiesto. Se non è leggibile (tipico di
        // alcune uscite AirPlay) il comando è comunque riuscito: come per CoreAudio, non si può verificare e lo si considera
        // applicato (altrimenti il guadagno del player si sommerebbe al volume già cambiato).
        if let current = readDefaultOutputVolume() {
            AppLog.debug("Volume di sistema: AppleScript eseguito, riletto \(current) (richiesto \(level))")
            return abs(current - level) < 0.03
        }
        AppLog.debug("Volume di sistema: AppleScript eseguito, volume non leggibile (considerato applicato)")
        return true
    }

    private static func writeDefaultOutputVolumeViaCoreAudio(_ value: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var level = value
        let size = UInt32(MemoryLayout<Float32>.size)

        func write(selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> Bool {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: element)
            guard AudioObjectHasProperty(device, &address) else { return false }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
            return AudioObjectSetPropertyData(device, &address, 0, nil, size, &level) == noErr
        }

        if write(selector: 0x766D7663 /* 'vmvc' VirtualMainVolume */, element: kAudioObjectPropertyElementMain) { return true }
        if write(selector: kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) { return true }
        let left = write(selector: kAudioDevicePropertyVolumeScalar, element: 1)
        let right = write(selector: kAudioDevicePropertyVolumeScalar, element: 2)
        return left || right
    }
}


/// Volume del dispositivo AirPlay (ampli, HomePod, Apple TV) come lo regola l'app Musica: tramite il contesto di uscita del
/// player (`AVOutputContext` → `AVOutputDevice`). Con AirPlay scelto dal selettore di sistema la riproduzione viene instradata
/// lì senza cambiare né l'uscita predefinita del Mac né `isExternalPlaybackActive`, e `AVPlayer.volume` non agisce sul
/// dispositivo remoto. Selettori privati cercati a runtime: se mancano non succede nulla e `set` restituisce falso.
enum AirPlayRouteVolume {
    /// Dispositivi di uscita del contesto del player (vuoto se non disponibili).
    private static func routeDevices(of player: AVPlayer) -> [NSObject] {
        guard player.responds(to: Selector(("outputContext"))),
              let context = player.value(forKey: "outputContext") as? NSObject else { return [] }
        if context.responds(to: Selector(("outputDevices"))),
           let list = context.value(forKey: "outputDevices") as? [NSObject], !list.isEmpty {
            return list
        }
        if context.responds(to: Selector(("outputDevice"))), let d = context.value(forKey: "outputDevice") as? NSObject {
            return [d]
        }
        return []
    }

    /// Nome del dispositivo, in minuscolo; nil se assente.
    private static func name(of device: NSObject) -> String? {
        guard let n = (readProperty("deviceName", of: device) ?? readProperty("name", of: device))?.lowercased(),
              !n.isEmpty, n != "nil" else { return nil }
        return n
    }

    /// Vero se il contesto di uscita del player punta a un dispositivo diverso dall'uscita del Mac (per esempio un ampli AirPlay).
    static func routeIsRemote(player: AVPlayer) -> Bool {
        let local = SystemOutputVolume.defaultOutputName()?.lowercased()
        return routeDevices(of: player).contains { name(of: $0).map { $0 != local } ?? false }
    }

    /// Descrizione dei dispositivi del percorso per il registro dettagliato: classe, nome, volume, tipo di controllo del volume e
    /// se il volume è impostabile (proprietà lette solo se il dispositivo le espone).
    static func describeDevices(player: AVPlayer) -> String {
        let devices = routeDevices(of: player)
        if devices.isEmpty { return "nessun dispositivo nel contesto di uscita" }
        return devices.map { device in
            var parts = ["classe=\(String(describing: type(of: device)))"]
            for key in ["deviceName", "name", "volume", "volumeControlType", "canSetVolume", "supportsVolumeControl", "deviceSubType"] {
                if let value = readProperty(key, of: device) { parts.append("\(key)=\(value)") }
            }
            return "{" + parts.joined(separator: ", ") + "}"
        }.joined(separator: " ")
    }

    /// Volume (0...1) che il primo dispositivo del percorso riporta ora; nil se non lo espone.
    static func currentVolume(player: AVPlayer) -> Float? {
        for device in routeDevices(of: player) {
            if let value = readProperty("volume", of: device).flatMap({ Float($0) }) { return value }
        }
        return nil
    }

    /// Vero se almeno un dispositivo del percorso riporta ora il volume richiesto (rilettura, senza modificare nulla).
    static func volumeMatches(_ value: Float, player: AVPlayer) -> Bool {
        let level = max(0, min(1, value))
        return routeDevices(of: player).contains { device in
            readProperty("volume", of: device).flatMap { Float($0) }.map { abs($0 - level) < 0.03 } ?? false
        }
    }

    /// Imposta il volume (0...1) sui dispositivi del contesto del player. Vero se almeno uno lo ha accettato: si controlla che il
    /// volume riletto coincida con quello richiesto (i dispositivi senza controllo del volume «accettano» la chiamata ma non cambiano).
    @discardableResult
    static func set(_ value: Float, player: AVPlayer) -> Bool {
        let level = max(0, min(1, value))
        var accepted = false
        for device in routeDevices(of: player) {
            let before = readProperty("volume", of: device) ?? "-"
            let called = setVolume(level, on: device)
            let afterText = readProperty("volume", of: device)
            AppLog.debug("AirPlay volume: setVolume \(level) su \(String(describing: type(of: device))) — chiamata=\(called) prima=\(before) dopo=\(afterText ?? "-")")
            if called, let after = afterText.flatMap({ Float($0) }), abs(after - level) < 0.03 {
                accepted = true
            }
        }
        return accepted
    }

    /// Legge una proprietà Objective-C come testo, solo se l'oggetto la espone (nessuna eccezione per chiavi sconosciute).
    private static func readProperty(_ key: String, of object: NSObject) -> String? {
        guard object.responds(to: Selector((key))) else { return nil }
        guard let value = object.value(forKey: key) else { return "nil" }
        return "\(value)"
    }

    /// Chiama `setVolume:` oppure `setVolume:withCompletionHandler:` se il dispositivo li espone.
    private static func setVolume(_ level: Float, on device: NSObject) -> Bool {
        let plain = Selector(("setVolume:"))
        if device.responds(to: plain), let imp = class_getMethodImplementation(type(of: device), plain) {
            typealias Fn = @convention(c) (AnyObject, Selector, Float) -> Void
            unsafeBitCast(imp, to: Fn.self)(device, plain, level)
            return true
        }
        let withCompletion = Selector(("setVolume:withCompletionHandler:"))
        if device.responds(to: withCompletion), let imp = class_getMethodImplementation(type(of: device), withCompletion) {
            typealias Fn = @convention(c) (AnyObject, Selector, Float, AnyObject?) -> Void
            unsafeBitCast(imp, to: Fn.self)(device, withCompletion, level, nil)
            return true
        }
        return false
    }
}
