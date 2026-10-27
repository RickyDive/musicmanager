import Foundation

/// Archivio su disco delle copertine che l'utente ha **confermato** nella finestra "Fix Artwork"
/// (vedi `FixArtworkView`): un piccolo indice JSON (`index.json`, chiave = artista+titolo+album
/// normalizzati) più un'immagine JPEG per ogni copertina confermata, tutto sotto "Application
/// Support". Al momento dell'invio all'orologio, `AppViewModel.resolvedUpload` usa SOLO queste
/// copertine già confermate: nessuna ricerca di rete e nessuna scelta automatica in background.
///
/// Apposta senza stato in memoria e senza isolamento a un actor: sono semplici operazioni sul file
/// system, utilizzabili sia dalla finestra Fix Artwork, sia da `AppViewModel` durante un invio, sia
/// direttamente dal pulsante "Svuota cache copertine" in `SettingsView`, senza passare da
/// `AppViewModel`.
enum ArtworkCache {
    struct Entry: Codable {
        let imageFileName: String
        /// Vero dopo che la versione con questa copertina è stata effettivamente caricata sul
        /// dispositivo almeno una volta: da quel momento gli invii successivi non devono più
        /// sovrascrivere ogni volta il file già presente (altrimenti si perderebbe la logica
        /// "delta" che evita di ricopiare brani già sull'orologio). Torna falso se l'utente
        /// conferma una copertina diversa per lo stesso brano.
        var pushedToDevice: Bool
        /// Vero se la copertina arriva da Apple Music (cache di Musica o altro brano dell'album) e non
        /// da una ricerca online: nel riepilogo di invio si chiama "Apple artwork". Assente nelle
        /// voci create prima di questa funzione (= online).
        var fromApple: Bool? = nil
    }

    /// Chiavi delle copertine scelte online in Fix Artwork da quando l'app è aperta: nel riepilogo di invio compaiono come
    /// «Online Artwork» invece che «Garmin Cache» (che resta per quelle confermate in sessioni precedenti). Solo in memoria.
    nonisolated(unsafe) static var chosenOnlineThisSession = Set<String>()

    /// `Application Support/MusicManager/Artwork` (vedi `AppFolders`).
    private static var baseDirectory: URL { AppFolders.artwork }

    private static var directory: URL {
        baseDirectory.appendingPathComponent("ConfirmedArtwork", isDirectory: true)
    }

    /// Cartella della prima versione della funzione (ricerca automatica in background, copertine
    /// mai confermate dall'utente): non viene più letta, ma "Svuota cache copertine" la elimina
    /// comunque per non lasciare file inutili.
    private static var legacyDirectory: URL {
        baseDirectory.appendingPathComponent("ArtworkCache", isDirectory: true)
    }

    private static var indexFileURL: URL {
        directory.appendingPathComponent("index.json")
    }

    /// Chiave stabile per un brano: normalizza artista/titolo/album (minuscolo, spazi ridotti,
    /// spazi ai bordi tolti) cosi piccole differenze di formattazione non creano voci duplicate.
    static func key(artist: String, title: String, album: String) -> String {
        func normalized(_ s: String) -> String {
            s.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return "\(normalized(artist))|\(normalized(title))|\(normalized(album))"
    }

    /// Dati JPEG della copertina confermata per questa chiave, nil se non ce n'è (o se il file è
    /// stato rimosso da fuori senza passare da `clearAll()`).
    static func confirmedImage(forKey key: String) -> Data? {
        guard let entry = loadIndex()[key] else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(entry.imageFileName))
    }

    static func isPushedToDevice(key: String) -> Bool {
        loadIndex()[key]?.pushedToDevice ?? false
    }

    /// Memorizza la copertina confermata dall'utente (già ridimensionata/compressa da
    /// `ArtworkLookupService`). Sostituisce un'eventuale conferma precedente per lo stesso brano e
    /// azzera `pushedToDevice`, cosi al prossimo invio il file sull'orologio viene aggiornato.
    /// Restituisce false se la scrittura su disco fallisce (spazio esaurito, permessi...).
    @discardableResult
    static func storeConfirmed(key: String, imageData: Data, fromApple: Bool = false, chosenOnline: Bool = true) -> Bool {
        var index = loadIndex()
        let fileName = fileName(for: key)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try imageData.write(to: directory.appendingPathComponent(fileName))
        } catch {
            return false
        }
        index[key] = Entry(imageFileName: fileName, pushedToDevice: false, fromApple: fromApple ? true : nil)
        if chosenOnline && !fromApple { chosenOnlineThisSession.insert(key) } else { chosenOnlineThisSession.remove(key) }
        return saveIndex(index)
    }

    /// Segna che questa copertina è ora presente sul dispositivo (vedi `Entry.pushedToDevice`).
    static func markPushedToDevice(key: String) {
        var index = loadIndex()
        guard var entry = index[key] else { return }
        entry.pushedToDevice = true
        index[key] = entry
        _ = saveIndex(index)
    }

    /// Cancella tutte le copertine confermate (indice + immagini), più l'eventuale cartella della
    /// versione precedente: usata dal pulsante "Svuota cache copertine" in Impostazioni.
    /// Spazio occupato su disco dalla cache delle copertine (immagini + indice, compresa la
    /// vecchia cartella della prima versione, se ancora presente), in byte.
    static func sizeOnDisk() -> UInt64 {
        var total: UInt64 = 0
        for folder in [directory, legacyDirectory] {
            guard let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.fileSizeKey], options: []) else { continue }
            for case let url as URL in enumerator {
                total += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// Notifica inviata dopo lo svuotamento: il view model azzera le origini già calcolate (altrimenti i brani risultano ancora
    /// «con copertina» dalla cache appena cancellata, e Fix Artwork non li propone).
    static let didClearNotification = Notification.Name("ArtworkCacheDidClear")

    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: legacyDirectory)
        NotificationCenter.default.post(name: didClearNotification, object: nil)
    }

    private static func fileName(for key: String) -> String {
        // Un hash semplice e stabile (FNV-1a) basta qui: serve solo un nome file univoco e senza
        // caratteri problematici, non una garanzia crittografica.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016x.jpg", hash)
    }

    private static func loadIndex() -> [String: Entry] {
        guard let data = try? Data(contentsOf: indexFileURL),
              let index = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return index
    }

    private static func saveIndex(_ index: [String: Entry]) -> Bool {
        guard let data = try? JSONEncoder().encode(index) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: indexFileURL)
            return true
        } catch {
            return false
        }
    }
}
