import Foundation

// MARK: - Modelli

let mtpRootParent: UInt32 = 0xFFFFFFFF   // LIBMTP_FILES_AND_FOLDERS_ROOT

struct MTPStorage: Identifiable, Hashable, Sendable {
    let id: UInt32
    let name: String
    let capacity: UInt64
    let free: UInt64
}

struct MTPDeviceInfo: Sendable {
    let friendlyName: String
    let manufacturer: String
    let model: String
    /// Nome "amichevole" MTP così come lo dichiara il dispositivo (vuoto se non esposto):
    /// a differenza di `friendlyName` non ricade sul nome del modello.
    let nickname: String
    let storages: [MTPStorage]
}

struct MTPEntry: Identifiable, Hashable, Sendable {
    let id: UInt32
    let parentID: UInt32
    let storageID: UInt32
    let name: String
    let size: UInt64
    let isFolder: Bool
    let modified: Date
}

struct DeviceTrack: Identifiable, Hashable, Sendable {
    let id: UInt32          // ID oggetto MTP
    let title: String
    let artist: String
    let album: String
    let filename: String
    let size: UInt64
    /// Durata in secondi, 0 se il dispositivo non la espone tra i metadati MTP.
    let duration: TimeInterval
    /// Catena di ID cartella dalla cartella Music (esclusa) fino al genitore diretto del file,
    /// es. [idCartellaArtista, idCartellaAlbum]. Vuota se il file è direttamente dentro Music.
    /// Usata per rimuovere le cartelle Album/Artista rimaste vuote dopo un'eliminazione.
    let folderIDPath: [UInt32]
    /// Nomi delle stesse cartelle (Artista, Album): servono a ricostruire il percorso del file per la playlist.
    var folderNames: [String] = []
    /// Numero di traccia nell'album (0 = non disponibile): dai metadati MTP o, se mancano, dalla libreria Music.
    var trackNumber: Int = 0
    /// Numero del disco e numero di dischi dell'album (0 = non disponibile): il dispositivo non li espone, si ricavano
    /// dal file corrispondente nella libreria Music. Servono a ordinare e dividere in dischi gli album multi-disco.
    var discNumber: Int = 0
    var discCount: Int = 0
    /// Artista dell'album e tag «Compilation»: il dispositivo non li espone (le cartelle seguono l'artista del brano), si ricavano
    /// dal file nella libreria Music. Vuoto/false = sconosciuto: il raggruppamento ripiega sull'artista del brano.
    var albumArtist: String = ""
    var isCompilation: Bool = false
    /// Percorso relativo alla cartella Music, come lo scrive un file .m3u8 (Artista/Album/file).
    var relativePath: String { (folderNames + [filename]).joined(separator: "/") }
}

struct DevicePlaylist: Identifiable, Hashable, Sendable {
    let id: UInt32          // ID oggetto MTP del file .m3u/.m3u8
    let name: String
    let trackIDs: [UInt32]
    /// Cartella che contiene il file playlist: serve per riscriverlo (2.1 Beta 2) senza i brani eliminati.
    let parentID: UInt32
}

struct DeviceCatalog: Sendable {
    let tracks: [DeviceTrack]
    let playlists: [DevicePlaylist]
}

enum MTPError: LocalizedError {
    case noDevice
    case cannotOpen
    case notConnected
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return t("error_no_device")
        case .cannotOpen:
            return t("error_cannot_open")
        case .notConnected:
            return t("error_not_connected")
        case .failed(let msg):
            return msg
        }
    }
}

// MARK: - Servizio

/// Incapsula libmtp. È un actor: libmtp non è thread-safe, quindi tutte le chiamate
/// vengono serializzate.
actor MTPService {
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private var libraryInitialized = false
    /// Dispositivo senza supporto musicale (da `GarminDevice.xml`): ogni scrittura viene rifiutata
    /// anche qui, come ultima difesa oltre ai controlli dell'interfaccia e del ViewModel.
    private var writeLocked = false

    func setWriteLocked(_ locked: Bool) { writeLocked = locked }

    // MARK: Volume usato come dispositivo (2.1 Beta 3, sperimentale)

    /// Radice di un volume (scheda SD, disco in archiviazione di massa, immagine disco) usato come se fosse un dispositivo.
    /// Con la radice impostata `list`, `upload`, `download`, `createFolder`, `delete` e `loadMusicCatalog` lavorano sulle
    /// cartelle del volume invece che su libmtp; il resto dell'app non se ne accorge. Nil = dispositivo MTP normale.
    private var volumeRoot: URL?
    private var volumeName = ""
    /// Il file system non ha ID oggetto come MTP: si assegna un numero a ogni percorso incontrato (e viceversa).
    private var volumePaths: [UInt32: URL] = [:]
    private var volumeIDs: [String: UInt32] = [:]
    private var volumeNextID: UInt32 = 1
    /// Il volume è presentato come un'unica memoria con questo ID.
    static let volumeStorageID: UInt32 = 1

    /// Apre un volume come dispositivo. Restituisce le stesse informazioni di `connect()`.
    func connectVolume(root: URL, name: String, model: String) throws -> MTPDeviceInfo {
        disconnect()
        guard FileManager.default.isReadableFile(atPath: root.path) else { throw MTPError.noDevice }
        AppLog.debug("Volume come dispositivo: apertura di «\(root.path)» (nome «\(name)», modello «\(model)»)")
        volumeRoot = root
        volumeName = name
        volumePaths = [:]
        volumeIDs = [:]
        volumeNextID = 1
        return MTPDeviceInfo(friendlyName: model.isEmpty ? name : model,
                             manufacturer: "Garmin",
                             model: model,
                             nickname: "",
                             storages: [volumeStorage()])
    }

    /// Capacità e spazio libero aggiornati del volume (nil se non è aperto un volume): servono dopo un invio o un'eliminazione.
    func volumeStorages() -> [MTPStorage]? {
        volumeRoot == nil ? nil : [volumeStorage()]
    }

    private func volumeStorage() -> MTPStorage {
        let values = try? volumeRoot?.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return MTPStorage(id: Self.volumeStorageID,
                          name: volumeName.isEmpty ? t("label_storage") : volumeName,
                          capacity: UInt64(max(0, values?.volumeTotalCapacity ?? 0)),
                          free: UInt64(max(0, values?.volumeAvailableCapacity ?? 0)))
    }

    private func volumeID(for url: URL) -> UInt32 {
        let standard = url.standardizedFileURL
        if let id = volumeIDs[standard.path] { return id }
        let id = volumeNextID
        volumeNextID += 1
        volumeIDs[standard.path] = id
        volumePaths[id] = standard
        return id
    }

    private func volumeURL(_ id: UInt32) -> URL? {
        id == mtpRootParent ? volumeRoot : volumePaths[id]
    }

    private func volumeList(parentID: UInt32) throws -> [MTPEntry] {
        guard let dir = volumeURL(parentID) else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])
        var result: [MTPEntry] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            result.append(MTPEntry(id: volumeID(for: url),
                                   parentID: parentID,
                                   storageID: Self.volumeStorageID,
                                   name: url.lastPathComponent,
                                   size: UInt64(max(0, values?.fileSize ?? 0)),
                                   isFolder: values?.isDirectory == true,
                                   modified: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)))
        }
        return result
    }

    /// Rifiuta le scritture su un dispositivo in sola lettura; per un dispositivo MTP richiede anche la connessione.
    private func checkWritable() throws {
        if writeLocked { throw MTPError.failed(t("error_read_only_device")) }
        if volumeRoot == nil { _ = try requireDevice() }
    }

    // MARK: Connessione

    func connect() throws -> MTPDeviceInfo {
        disconnect()

        if !libraryInitialized {
            LIBMTP_Init()
            libraryInitialized = true
        }

        var raw: UnsafeMutablePointer<LIBMTP_raw_device_t>? = nil
        var count: Int32 = 0
        let err = LIBMTP_Detect_Raw_Devices(&raw, &count)
        guard err == LIBMTP_ERROR_NONE, count > 0, let rawDevices = raw else {
            throw MTPError.noDevice
        }
        defer { free(rawDevices) }

        // Prototipo: apre il primo dispositivo trovato.
        guard let dev = LIBMTP_Open_Raw_Device_Uncached(rawDevices) else {
            throw MTPError.cannotOpen
        }
        device = dev

        _ = LIBMTP_Get_Storage(dev, 0)

        let friendly = takeString(LIBMTP_Get_Friendlyname(dev))
        let model = takeString(LIBMTP_Get_Modelname(dev))
        let manufacturer = takeString(LIBMTP_Get_Manufacturername(dev))

        var storages: [MTPStorage] = []
        var node = dev.pointee.storage
        while let s = node {
            let name = s.pointee.StorageDescription.map { String(cString: $0) } ?? t("label_storage")
            storages.append(MTPStorage(id: s.pointee.id,
                                       name: name,
                                       capacity: s.pointee.MaxCapacity,
                                       free: s.pointee.FreeSpaceInBytes))
            node = s.pointee.next
        }

        return MTPDeviceInfo(friendlyName: friendly ?? model ?? t("device_default_name"),
                             manufacturer: manufacturer ?? "",
                             model: model ?? "",
                             nickname: friendly ?? "",
                             storages: storages)
    }

    func disconnect() {
        writeLocked = false
        volumeRoot = nil
        volumeName = ""
        volumePaths = [:]
        volumeIDs = [:]
        if let dev = device {
            LIBMTP_Release_Device(dev)
            device = nil
        }
    }

    // MARK: File system

    func list(storageID: UInt32, parentID: UInt32) throws -> [MTPEntry] {
        var result: [MTPEntry] = []

        if volumeRoot != nil {
            result = try volumeList(parentID: parentID)
        } else {
            let dev = try requireDevice()
            var node = LIBMTP_Get_Files_And_Folders(dev, storageID, parentID)
            while let f = node {
                let next = f.pointee.next
                let name = f.pointee.filename.map { String(cString: $0) } ?? ""
                result.append(MTPEntry(
                    id: f.pointee.item_id,
                    parentID: f.pointee.parent_id,
                    storageID: f.pointee.storage_id,
                    name: name,
                    size: f.pointee.filesize,
                    isFolder: f.pointee.filetype == LIBMTP_FILETYPE_FOLDER,
                    modified: Date(timeIntervalSince1970: TimeInterval(f.pointee.modificationdate))
                ))
                LIBMTP_destroy_file_t(f)
                node = next
            }
        }

        return result.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 2.1 Beta 3 (diagnostica): elenco completo e ricorsivo di tutto ciò che il dispositivo espone, in sola lettura.
    /// Serve a capire dove salvano i dati i servizi esterni (Spotify, Amazon Music, YouTube Music…): si salva l'albero
    /// prima e dopo aver scaricato una playlist con il servizio e si confrontano i due file. Una riga per elemento:
    /// percorso, dimensione, data di modifica, id MTP, id del genitore. In testa un riepilogo per cartella di primo livello.
    func dumpTree(storages: [MTPStorage], maxEntries: Int = 80_000) throws -> String {
        _ = try requireDevice()
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"; df.timeZone = TimeZone.current
        var lines: [String] = []
        var summary: [String: (files: Int, bytes: UInt64)] = [:]
        var total = 0, truncated = false
        for st in storages {
            lines.append("")
            lines.append("## Memoria \(st.id) «\(st.name)»: capacità \(st.capacity) byte, liberi \(st.free) byte")
            var pending: [(id: UInt32, path: String)] = [(mtpRootParent, "")]
            while let cur = pending.popLast() {
                if total >= maxEntries { truncated = true; break }
                guard let entries = try? list(storageID: st.id, parentID: cur.id) else {
                    lines.append("!! elenco non riuscito: \(cur.path.isEmpty ? "/" : cur.path)")
                    continue
                }
                // In ordine alfabetico, cartelle incluse (le cartelle si scendono dopo, per leggibilità).
                for e in entries.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                    let path = cur.path + "/" + e.name
                    total += 1
                    lines.append("\(path)\(e.isFolder ? "/" : "")\t\(e.isFolder ? "-" : String(e.size))\t\(df.string(from: e.modified))\t\(e.id)\t\(e.parentID)")
                    if e.isFolder {
                        pending.append((e.id, path))
                    } else {
                        let top = "/" + (path.split(separator: "/").first.map(String.init) ?? "")
                        let key = "\(st.id)\t\(top)"
                        let old = summary[key] ?? (0, 0)
                        summary[key] = (old.files + 1, old.bytes + e.size)
                    }
                }
            }
        }
        var out = ["# Music Manager – albero del dispositivo (sola lettura)",
                   "# Elementi elencati: \(total)" + (truncated ? " (INTERROTTO: troppi elementi)" : ""),
                   "# Colonne: percorso · dimensione (byte) · modifica · id MTP · id genitore",
                   "", "## Riepilogo per cartella di primo livello (memoria · cartella · file · byte)"]
        for k in summary.keys.sorted() {
            let v = summary[k]!
            out.append("\(k)\t\(v.files)\t\(v.bytes)")
        }
        return (out + lines).joined(separator: "\n") + "\n"
    }

    func download(itemID: UInt32, to url: URL) throws {
        if volumeRoot != nil {
            guard let source = volumeURL(itemID) else { throw MTPError.failed(t("error_download_failed", t("error_unknown"))) }
            do {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: source, to: url)
            } catch {
                throw MTPError.failed(t("error_download_failed", error.localizedDescription))
            }
            return
        }
        let dev = try requireDevice()
        let rc = LIBMTP_Get_File_To_File(dev, itemID, url.path, nil, nil)
        if rc != 0 { throw MTPError.failed(t("error_download_failed", lastError(dev))) }
    }

    func upload(from url: URL, storageID: UInt32, parentID: UInt32) throws {
        if volumeRoot != nil {
            try checkWritable()
            guard let folder = volumeURL(parentID) else {
                throw MTPError.failed(t("error_upload_failed", url.lastPathComponent, t("error_unknown")))
            }
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            AppLog.debug("Volume come dispositivo: copia di «\(url.lastPathComponent)» in «\(folder.path)»")
            do {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                throw MTPError.failed(t("error_upload_failed", url.lastPathComponent, error.localizedDescription))
            }
            return
        }
        let dev = try requireWritableDevice()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        guard let file = LIBMTP_new_file_t() else {
            throw MTPError.failed(t("error_out_of_memory"))
        }
        defer { LIBMTP_destroy_file_t(file) }   // libera anche filename

        file.pointee.filename = strdup(url.lastPathComponent)
        file.pointee.parent_id = parentID
        file.pointee.storage_id = storageID
        file.pointee.filesize = size
        file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        file.pointee.modificationdate = time(nil)

        let rc = LIBMTP_Send_File_From_File(dev, url.path, file, nil, nil)
        if rc != 0 { throw MTPError.failed(t("error_upload_failed", url.lastPathComponent, lastError(dev))) }
    }

    /// Verifica se esiste già, nella cartella indicata, un file con questo nome (confronto senza
    /// distinguere maiuscole/minuscole). Usato sia per evitare di ricopiare brani già presenti sia
    /// per confermare che un upload sia arrivato. Non confronta le dimensioni: alcuni dispositivi
    /// riportano via MTP una dimensione leggermente diversa da quella del file sorgente anche
    /// quando il file è perfettamente a posto, e un confronto stretto produce falsi negativi che
    /// fanno ricopiare brani già corretti o, peggio, fanno fallire la verifica a torto.
    func fileExists(named filename: String, storageID: UInt32, parentID: UInt32) -> Bool {
        guard let items = try? list(storageID: storageID, parentID: parentID) else { return false }
        let key = Self.nameKey(filename)
        return items.contains { !$0.isFolder && Self.nameKey($0.name) == key }
    }

    /// Elimina tutto il contenuto della cartella Music (sottocartelle e file), senza eliminare la
    /// cartella Music stessa. Non fa nulla se Music non esiste ancora.
    func emptyMusicFolder(storageID: UInt32) throws {
        try checkWritable()
        guard let musicID = findFolder(named: "Music", parentID: mtpRootParent, storageID: storageID) else { return }
        for item in try list(storageID: storageID, parentID: musicID) {
            try? delete(itemID: item.id)
        }
    }

    /// Calcola la dimensione della cartella "Garmin" (mappe escluse) e il totale delle mappe
    /// (.gma/.img) al suo interno. Può richiedere qualche secondo su dispositivi con molti file;
    /// per questo va chiamata solo quando serve (connessione o cambio memoria), non a ogni refresh.
    func garminAndMapsSize(storageID: UInt32) -> (garmin: UInt64, maps: UInt64) {
        guard let garminID = findFolder(named: "Garmin", parentID: mtpRootParent, storageID: storageID) else {
            return (0, 0)
        }
        var garmin: UInt64 = 0
        var maps: UInt64 = 0
        var pending: [UInt32] = [garminID]
        while let current = pending.popLast() {
            guard let items = try? list(storageID: storageID, parentID: current) else { continue }
            for e in items {
                if e.isFolder {
                    pending.append(e.id)
                } else {
                    let ext = (e.name as NSString).pathExtension.lowercased()
                    if ext == "gma" || ext == "img" {
                        maps += e.size
                    } else {
                        garmin += e.size
                    }
                }
            }
        }
        return (garmin, maps)
    }

    func createFolder(named name: String, parentID: UInt32, storageID: UInt32) throws -> UInt32 {
        if volumeRoot != nil {
            try checkWritable()
            guard let parent = volumeURL(parentID) else {
                throw MTPError.failed(t("error_folder_create_failed", t("error_unknown")))
            }
            let folder = parent.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw MTPError.failed(t("error_folder_create_failed", error.localizedDescription))
            }
            return volumeID(for: folder)
        }
        let dev = try requireWritableDevice()
        guard let cName = strdup(name) else { throw MTPError.failed(t("error_out_of_memory")) }
        defer { free(cName) }   // libmtp può modificare il buffer

        let id = LIBMTP_Create_Folder(dev, cName, parentID, storageID)
        if id == 0 { throw MTPError.failed(t("error_folder_create_failed", lastError(dev))) }
        return id
    }

    /// Chiave di confronto tra nomi: normalizzazione Unicode (NFC), senza distinguere maiuscole/minuscole e
    /// ignorando spazi e punti a inizio/fine. Serve perché il dispositivo può riportare lo stesso nome con
    /// una codifica diversa (lettere accentate scomposte, spazi finali...): con il solo confronto esatto la
    /// cartella già presente non veniva riconosciuta e il tentativo di ricrearla falliva.
    static func nameKey(_ name: String, loose: Bool = false) -> String {
        var s = name.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if loose {
            // Confronto più largo (ultima spiaggia): ignora anche accenti e larghezza dei caratteri.
            s = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        } else {
            s = s.lowercased()
        }
        return s
    }

    /// Restituisce l'ID della cartella (la crea se manca). Se la creazione fallisce (tipico quando la cartella
    /// c'è già ma non era stata riconosciuta, per esempio per un elenco incompleto o un nome scritto in modo
    /// leggermente diverso), rilegge l'elenco e riprova a trovarla prima di segnalare l'errore.
    func ensureFolder(named name: String, parentID: UInt32, storageID: UInt32) throws -> UInt32 {
        let key = Self.nameKey(name)
        let items = try list(storageID: storageID, parentID: parentID)
        if let existing = items.first(where: { $0.isFolder && Self.nameKey($0.name) == key }) {
            return existing.id
        }
        do {
            return try createFolder(named: name, parentID: parentID, storageID: storageID)
        } catch {
            // Recupero: nuova lettura dell'elenco (anche con confronto largo), con un paio di tentativi.
            let loose = Self.nameKey(name, loose: true)
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
                if let again = try? list(storageID: storageID, parentID: parentID),
                   let found = again.first(where: {
                       $0.isFolder && (Self.nameKey($0.name) == key || Self.nameKey($0.name, loose: true) == loose)
                   }) {
                    return found.id
                }
            }
            throw error
        }
    }

    func delete(itemID: UInt32) throws {
        if volumeRoot != nil {
            try checkWritable()
            guard let url = volumeURL(itemID), itemID != mtpRootParent else { return }
            AppLog.debug("Volume come dispositivo: eliminazione di «\(url.path)»")
            do {
                try FileManager.default.removeItem(at: url)   // definitivo: sul volume non c'è il Cestino
            } catch {
                throw MTPError.failed(t("error_delete_failed", error.localizedDescription))
            }
            return
        }
        let dev = try requireWritableDevice()
        if LIBMTP_Delete_Object(dev, itemID) != 0 {
            throw MTPError.failed(t("error_delete_failed", lastError(dev)))
        }
    }

    // MARK: Catalogo musicale

    private static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "adb", "wav", "flac", "ogg"]

    /// Scansiona la cartella `Music` del dispositivo e ricostruisce brani, album, artisti e playlist.
    ///
    /// Metadati: prima prova quelli MTP (LIBMTP_Get_Tracklisting). Se il dispositivo non li espone,
    /// usa il nome del file come titolo e deduce artista/album dalla struttura di cartelle
    /// (Music/Artista/Album/brano.mp3 oppure Music/Album/brano.mp3).
    /// Playlist: file .m3u/.m3u8 nella cartella Music, abbinati ai brani per nome file.
    func loadMusicCatalog(storageID: UInt32) throws -> DeviceCatalog {
        // Su un volume non ci sono metadati MTP: titolo, artista e album si deducono da nome file e cartelle.
        var mtpDevice: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
        if volumeRoot == nil { mtpDevice = try requireDevice() }

        let root = try list(storageID: storageID, parentID: mtpRootParent)
        guard let musicFolder = root.first(where: {
            $0.isFolder && $0.name.caseInsensitiveCompare("Music") == .orderedSame
        }) else {
            return DeviceCatalog(tracks: [], playlists: [])
        }

        // 1. Scansione ricorsiva
        var audioFiles: [(entry: MTPEntry, folders: [String], folderIDs: [UInt32])] = []
        var playlistFiles: [MTPEntry] = []
        var pending: [(id: UInt32, folders: [String], folderIDs: [UInt32])] = [(musicFolder.id, [], [])]

        while let current = pending.popLast() {
            for e in try list(storageID: storageID, parentID: current.id) {
                if e.isFolder {
                    pending.append((e.id, current.folders + [e.name], current.folderIDs + [e.id]))
                    continue
                }
                let ext = (e.name as NSString).pathExtension.lowercased()
                if Self.audioExtensions.contains(ext) {
                    audioFiles.append((e, current.folders, current.folderIDs))
                } else if ext == "m3u" || ext == "m3u8" {
                    playlistFiles.append(e)
                }
            }
        }

        // 2. Metadati MTP (se disponibili)
        var meta: [UInt32: (title: String, artist: String, album: String, duration: UInt32, trackNumber: UInt16)] = [:]
        if let dev = mtpDevice {
            var node = LIBMTP_Get_Tracklisting_With_Callback(dev, nil, nil)
            while let t = node {
                let next = t.pointee.next
                meta[t.pointee.item_id] = (cstr(t.pointee.title) ?? "",
                                           cstr(t.pointee.artist) ?? "",
                                           cstr(t.pointee.album) ?? "",
                                           t.pointee.duration,
                                           t.pointee.tracknumber)
                LIBMTP_destroy_track_t(t)
                node = next
            }
            LIBMTP_Clear_Errorstack(dev)
        }

        // 3. Brani
        let tracks: [DeviceTrack] = audioFiles.map { file in
            let e = file.entry
            let folders = file.folders
            let m = meta[e.id]

            var artist = t("unknown_artist")
            var album = ""
            if folders.count >= 2 {
                artist = folders[0]; album = folders[1]
            } else if folders.count == 1 {
                album = folders[0]
            }
            if let a = m?.artist, !a.isEmpty { artist = a }
            if let a = m?.album, !a.isEmpty { album = a }

            let fallbackTitle = (e.name as NSString).deletingPathExtension
            let title = (m?.title.isEmpty == false) ? m!.title : fallbackTitle

            return DeviceTrack(id: e.id, title: title, artist: artist, album: album,
                               filename: e.name, size: e.size,
                               duration: TimeInterval(m?.duration ?? 0) / 1000.0,
                               folderIDPath: file.folderIDs, folderNames: file.folders,
                               trackNumber: Int(m?.trackNumber ?? 0))
        }
        .sortedForLibrary()

        // 4. Playlist M3U
        var byFilename: [String: UInt32] = [:]
        for t in tracks {
            let key = t.filename.lowercased()
            if byFilename[key] == nil { byFilename[key] = t.id }
        }

        // 2.0.1: abbinamento per percorso completo (Artista/Album/file): due brani con lo stesso nome file in
        // album diversi non vanno più confusi. Il solo nome file resta come ripiego.
        func pathKey(_ components: [String]) -> String { components.map { Self.nameKey($0) }.joined(separator: "/") }
        var byPath: [String: UInt32] = [:]
        for t in tracks {
            let key = pathKey(t.folderNames + [t.filename])
            if byPath[key] == nil { byPath[key] = t.id }
        }

        var playlists: [DevicePlaylist] = []
        if !playlistFiles.isEmpty {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("garmin-m3u-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            for pl in playlistFiles {
                let dest = tmp.appendingPathComponent(pl.name)
                guard (try? download(itemID: pl.id, to: dest)) != nil else { continue }

                let text = (try? String(contentsOf: dest, encoding: .utf8))
                    ?? (try? String(contentsOf: dest, encoding: .isoLatin1))
                    ?? ""

                let ids: [UInt32] = text
                    .replacingOccurrences(of: "\u{FEFF}", with: "")
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                    .compactMap { line in
                        var parts = line.replacingOccurrences(of: "\\", with: "/")
                            .split(separator: "/").map(String.init).filter { $0 != "." }
                        if parts.first?.caseInsensitiveCompare("Music") == .orderedSame, parts.count > 1 { parts.removeFirst() }
                        if let id = byPath[pathKey(parts)] { return id }
                        guard let name = parts.last else { return nil }
                        return byFilename[name.lowercased()]
                    }

                if !ids.isEmpty {
                    playlists.append(DevicePlaylist(id: pl.id,
                                                    name: (pl.name as NSString).deletingPathExtension,
                                                    trackIDs: ids,
                                                    parentID: pl.parentID))
                }
            }
        }
        playlists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return DeviceCatalog(tracks: tracks, playlists: playlists)
    }

    /// Crea un file .m3u8 che elenca i nomi dei file indicati e lo carica nella cartella data.
    /// Garmin legge le playlist come percorsi relativi alla cartella Music, quindi basta il nome file
    /// quando la playlist e i brani stanno nella stessa cartella.
    func uploadPlaylist(name: String, filenames: [String], storageID: UInt32, parentID: UInt32) throws {
        let content = Self.playlistContent(filenames)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).m3u8")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try content.write(to: tmp, atomically: true, encoding: .utf8)
        try upload(from: tmp, storageID: storageID, parentID: parentID)
    }

    private static func playlistContent(_ filenames: [String]) -> String {
        filenames.joined(separator: "\r\n") + "\r\n"
    }

    /// 2.0.1: carica il .m3u8 e ne verifica l'esito subito dopo: il file deve comparire nell'elenco della
    /// cartella, poter essere riscaricato e avere lo stesso contenuto. Se manca o è incompleto lo elimina e lo
    /// ricrea (fino a `attempts` tentativi in tutto). Restituisce vero solo a file verificato.
    func uploadPlaylistVerified(name: String, filenames: [String], storageID: UInt32, parentID: UInt32,
                                attempts: Int = 3) async -> Bool {
        // 2.1 Beta 2: il confronto è sulle righe normalizzate (fine riga CRLF/LF, BOM, «\\» come «/», maiuscole, righe di
        // commento): alcuni dispositivi riscrivono il file con altri a capo e il confronto del testo esatto falliva
        // anche con la playlist scritta correttamente. I motivi di un fallimento finiscono nel registro.
        let expected = Self.normalizedPlaylistLines(Self.playlistContent(filenames))
        let fileName = "\(name).m3u8"
        for attempt in 1...max(1, attempts) {
            if attempt > 1 { deleteExistingPlaylistFile(named: name, storageID: storageID, parentID: parentID) }
            do { try uploadPlaylist(name: name, filenames: filenames, storageID: storageID, parentID: parentID) }
            catch {
                AppLog.write("Playlist check «\(name)» (attempt \(attempt)): upload failed: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 1_000_000_000); continue
            }
            // Il dispositivo può impiegare un istante a rendere visibile il file appena scritto.
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let items = try? list(storageID: storageID, parentID: parentID),
                      let entry = items.first(where: { !$0.isFolder && Self.nameKey($0.name) == Self.nameKey(fileName) })
                else {
                    AppLog.write("Playlist check «\(name)» (attempt \(attempt)): file not in the folder listing")
                    continue
                }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("garmin-m3u-check-\(UUID().uuidString).m3u8")
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard (try? download(itemID: entry.id, to: tmp)) != nil,
                      let data = try? Data(contentsOf: tmp),
                      let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
                else {
                    AppLog.write("Playlist check «\(name)» (attempt \(attempt)): could not download the file back")
                    continue
                }
                let got = Self.normalizedPlaylistLines(text)
                if got == expected { return true }
                let firstDiff = zip(got, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                AppLog.write("Playlist check «\(name)» (attempt \(attempt)): content differs, expected \(expected.count) lines, found \(got.count)"
                             + (firstDiff.map { ", first difference at line \($0 + 1)" } ?? ""))
                break   // presente ma diverso: si ricrea
            }
        }
        return false
    }

    /// Righe di una playlist confrontabili tra loro: senza BOM, commenti e righe vuote, con «/» come separatore.
    private static func normalizedPlaylistLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\\", with: "/")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping.lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Prova a leggere un'immagine ("representative sample") associata al file sul dispositivo.
    /// Molti dispositivi MTP, inclusi diversi modelli Garmin, non implementano questa proprietà:
    /// in quel caso restituisce semplicemente nil, senza che sia un errore da segnalare all'utente.
    func artwork(forItemID id: UInt32) -> Data? {
        guard let dev = device else { return nil }
        guard let sample = LIBMTP_new_filesampledata_t() else { return nil }
        defer { LIBMTP_destroy_filesampledata_t(sample) }

        guard LIBMTP_Get_Representative_Sample(dev, id, sample) == 0 else {
            LIBMTP_Clear_Errorstack(dev)
            return nil
        }
        guard let dataPtr = sample.pointee.data, sample.pointee.size > 0 else { return nil }
        return Data(bytes: dataPtr, count: Int(sample.pointee.size))
    }

    /// Legge `/Garmin/GarminDevice.xml` (descrizione e codice articolo del dispositivo) da una
    /// delle memorie indicate, la prima in cui il file esiste. Nil se manca o non si riesce a scaricarlo.
    func readGarminDeviceXML(storageIDs: [UInt32]) -> Data? {
        for storageID in storageIDs {
            guard let garminID = findFolder(named: "Garmin", parentID: mtpRootParent, storageID: storageID),
                  let items = try? list(storageID: storageID, parentID: garminID),
                  let file = items.first(where: { !$0.isFolder && $0.name.caseInsensitiveCompare("GarminDevice.xml") == .orderedSame })
            else { continue }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("GarminDevice-\(UUID().uuidString).xml")
            defer { try? FileManager.default.removeItem(at: tmp) }
            if (try? download(itemID: file.id, to: tmp)) != nil, let data = try? Data(contentsOf: tmp) {
                return data
            }
        }
        return nil
    }

    /// Cerca una sottocartella per nome senza crearla. Nil se non esiste o in caso di errore.
    func findFolder(named name: String, parentID: UInt32, storageID: UInt32) -> UInt32? {
        guard let items = try? list(storageID: storageID, parentID: parentID) else { return nil }
        let key = Self.nameKey(name)
        return items.first(where: { $0.isFolder && Self.nameKey($0.name) == key })?.id
    }

    /// Se nella cartella indicata esiste già un file .m3u/.m3u8 con questo nome, lo elimina.
    /// Usato prima di rigenerare una playlist: il file viene sempre ricreato da zero, mai
    /// aggiornato "in place", cosi non può restare disallineato rispetto al contenuto attuale
    /// della playlist in Musica se questa è stata modificata (brani aggiunti o rimossi).
    func deleteExistingPlaylistFile(named name: String, storageID: UInt32, parentID: UInt32) {
        guard !writeLocked else { return }
        guard let items = try? list(storageID: storageID, parentID: parentID) else { return }
        let candidates = items.filter {
            !$0.isFolder &&
            ($0.name.caseInsensitiveCompare("\(name).m3u8") == .orderedSame ||
             $0.name.caseInsensitiveCompare("\(name).m3u") == .orderedSame)
        }
        for item in candidates {
            try? delete(itemID: item.id)
        }
    }

    // MARK: Helper

    /// Converte una stringa C in String senza liberarla (di proprietà della struttura libmtp).
    private func cstr(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }


    private func requireDevice() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let dev = device else { throw MTPError.notConnected }
        return dev
    }

    /// Come `requireDevice`, ma rifiuta l'operazione se il dispositivo è in sola lettura.
    private func requireWritableDevice() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        if writeLocked { throw MTPError.failed(t("error_read_only_device")) }
        return try requireDevice()
    }

    private func lastError(_ dev: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> String {
        var message = t("error_unknown")
        if let e = LIBMTP_Get_Errorstack(dev), let text = e.pointee.error_text {
            message = String(cString: text)
        }
        LIBMTP_Clear_Errorstack(dev)
        return message
    }

    /// Converte una stringa C allocata da libmtp in String e la libera.
    private func takeString(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { free(p) }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }
}
