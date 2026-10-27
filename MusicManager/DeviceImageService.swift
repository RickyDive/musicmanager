import Foundation
import AppKit
import ImageIO

/// Un'app dell'orologio elencata in GarminDevice.xml (2.1 Beta 3).
struct DeviceAppInfo: Sendable {
    let name: String
    /// Vero per i servizi di streaming (`audio-content-provider-app`).
    let isStreamingService: Bool
}

/// Immagine del prodotto Garmin collegato, per il riquadro in alto a sinistra del pannello
/// dispositivo. `GarminDevice.xml` (letto via MTP) fornisce `PartNumber` e `Description` del modello.
/// Ordine di ricerca:
/// 1. elenco dispositivi del Connect IQ Store (`deviceTypes`): si cerca il `PartNumber` e si scarica
///    l'`imageUrl` indicata (res.garmin.com);
/// 2. se il part number non c'è, il CDN `static.garmincdn.com/appstore/img/bydevice/<nome>.png`
///    con nomi ricavati dalla descrizione (es. "fenix 9 Pro - inReach, 51mm" → `fenix9pro-51mm`).
/// L'immagine si scarica una sola volta, si ridimensiona e si tiene in cache in Application
/// Support/DeviceImages. Se nulla corrisponde, o la rete non risponde, resta l'icona predefinita.
enum DeviceImageService {
    private static let baseURL = "https://static.garmincdn.com/appstore/img/bydevice/"
    /// Elenco dei dispositivi del Connect IQ Store (JSON con `partNumber`, `name`, `imageUrl`, `urlName`).
    private static let deviceTypesURL = "https://apps.garmin.com/api/appsLibraryExternalServices/api/asw/deviceTypes"
    /// Lato massimo in pixel dell'immagine tenuta in cache (il riquadro è 132 pt, quindi 2x per Retina).
    private static let maxPixelSize = 264

    private static var cacheFolder: URL { AppFolders.devicesImages }

    /// File di cache di una chiave. Il suffisso "-v2" distingue le immagini elaborate (sfondo reso
    /// trasparente, ritagliate) da quelle opache delle versioni precedenti, che vengono eliminate.
    private static func cacheFile(_ key: String) -> URL {
        let legacy = cacheFolder.appendingPathComponent("\(key).png")
        if FileManager.default.fileExists(atPath: legacy.path) { try? FileManager.default.removeItem(at: legacy) }
        return cacheFolder.appendingPathComponent("\(key)-v2.png")
    }

    // MARK: - GarminDevice.xml

    /// Dati letti da `GarminDevice.xml`: `Model/PartNumber`, `Model/Description`,
    /// `Model/SoftwareVersion`, `Id` e `DisplayName` (il file è radicato in `Device`).
    struct ModelInfo: Equatable {
        var partNumber: String?
        var description: String?
        var softwareVersion: String?
        var id: String?
        var displayName: String?
    }

    /// Estrae i campi del dispositivo da `GarminDevice.xml` (primo elemento trovato per ciascuno).
    static func modelInfo(fromXML data: Data) -> ModelInfo {
        let parser = XMLParser(data: data)
        let delegate = ModelParser()
        parser.delegate = delegate
        parser.parse()
        func value(_ key: String) -> String? {
            let text = (delegate.values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return ModelInfo(partNumber: value("part"), description: value("description"),
                         softwareVersion: value("software"), id: value("id"), displayName: value("display"))
    }

    /// Capacità multimediali dichiarate in `GarminDevice.xml` (voci `DataType`).
    struct MediaCapabilities: Equatable {
        /// Estensioni (minuscole) accettate per `MEDIA_TRACK` con `TransferDirection` = `InputToUnit`.
        var trackExtensions: Set<String>
        /// Estensioni accettate per `MEDIA_PLAYLIST` (es. m3u, m3u8).
        var playlistExtensions: Set<String>
        /// Il dispositivo accetta musica solo se dichiara almeno un formato `MEDIA_TRACK` in ingresso.
        var isMusicCapable: Bool { !trackExtensions.isEmpty }
    }

    /// Legge i formati multimediali dal file. Restituisce nil se il file non contiene alcun
    /// `DataType` (illeggibile o formato inatteso): in quel caso la capacità è sconosciuta e non si blocca nulla.
    /// Vero se GarminDevice.xml dichiara che il dispositivo riceve percorsi (cartella `Garmin/Courses` o tipo `FitnessCourses`).
    /// Euristica non verificata su tutti i modelli: serve solo a distinguere «senza mappe ma con percorsi» da «senza nulla».
    static func supportsCourses(fromXML data: Data) -> Bool {
        let text = (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)).lowercased()
        return text.contains("<name>fitnesscourses</name>") || text.contains("<path>garmin/courses</path>")
    }

    /// Spazio (byte) occupato dai servizi di streaming musicale installati, come lo dichiara l'orologio:
    /// somma di `MediaCacheSize` delle app `audio-content-provider-app` (Amazon Music, Deezer, Spotify…).
    /// Per ora i servizi non si distinguono. 0 se il file non ne contiene (2.1 Beta 3).
    static func streamingServicesBytes(fromXML data: Data) -> UInt64 {
        let parser = XMLParser(data: data)
        let delegate = ServicesParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.total
    }

    /// App installate sull'orologio secondo GarminDevice.xml, per il nome del file (senza estensione, maiuscolo, es. «GAFF5927»):
    /// serve al navigatore dei file per riconoscere i file delle app e dei servizi di streaming (2.1 Beta 3).
    static func appFileMap(fromXML data: Data) -> [String: DeviceAppInfo] {
        let parser = XMLParser(data: data)
        let delegate = AppFilesParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.apps
    }

    private final class AppFilesParser: NSObject, XMLParserDelegate {
        var apps: [String: DeviceAppInfo] = [:]
        private var inApp = false
        private var name = ""
        private var type = ""
        private var fileName = ""
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if elementName == "App" { inApp = true; name = ""; type = ""; fileName = "" }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if inApp {
                switch elementName {
                case "AppName": name = value
                case "AppType": type = value
                case "FileName": fileName = value
                case "App":
                    let stem = (fileName as NSString).deletingPathExtension.uppercased()
                    if !stem.isEmpty, !name.isEmpty {
                        apps[stem] = DeviceAppInfo(name: name, isStreamingService: type == "audio-content-provider-app")
                    }
                    inApp = false
                default: break
                }
            }
            text = ""
        }
    }

    private final class ServicesParser: NSObject, XMLParserDelegate {
        var total: UInt64 = 0
        private var inApp = false
        private var appType = ""
        private var cacheSize: UInt64 = 0
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if elementName == "App" { inApp = true; appType = ""; cacheSize = 0 }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if inApp {
                switch elementName {
                case "AppType": appType = value
                case "MediaCacheSize": cacheSize = UInt64(value) ?? 0
                case "App":
                    if appType == "audio-content-provider-app" { total += cacheSize }
                    inApp = false
                default: break
                }
            }
            text = ""
        }
    }

    static func mediaCapabilities(fromXML data: Data) -> MediaCapabilities? {
        let parser = XMLParser(data: data)
        let delegate = MediaParser()
        parser.delegate = delegate
        parser.parse()
        guard delegate.sawDataType else { return nil }
        return MediaCapabilities(trackExtensions: delegate.tracks, playlistExtensions: delegate.playlists)
    }

    private final class MediaParser: NSObject, XMLParserDelegate {
        var tracks = Set<String>()
        var playlists = Set<String>()
        var sawDataType = false
        private var path: [String] = []
        private var dataTypeName = ""
        private var extensions: [String] = []
        private var directions: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            path.append(elementName)
            text = ""
            if elementName == "DataType" { sawDataType = true; dataTypeName = ""; extensions = []; directions = [] }
            if elementName == "File" { extensions.append(""); directions.append("") }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "Name" where path.count >= 2 && path[path.count - 2] == "DataType":
                dataTypeName = value
            case "FileExtension" where !extensions.isEmpty:
                extensions[extensions.count - 1] = value.lowercased()
            case "TransferDirection" where !directions.isEmpty:
                directions[directions.count - 1] = value
            case "DataType":
                for (ext, dir) in zip(extensions, directions) where !ext.isEmpty && dir == "InputToUnit" {
                    if dataTypeName == "MEDIA_TRACK" { tracks.insert(ext) }
                    if dataTypeName == "MEDIA_PLAYLIST" { playlists.insert(ext) }
                }
            default: break
            }
            text = ""
            _ = path.popLast()
        }
    }

    private final class ModelParser: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        private var path: [String] = []
        private var capturing: String?
        private var finished = Set<String>()

        /// Chiave del campo per l'elemento corrente, in base al suo percorso.
        private func key(for path: [String]) -> String? {
            guard let last = path.last else { return nil }
            if path.count >= 2, path[path.count - 2] == "Model" {
                switch last {
                case "PartNumber": return "part"
                case "Description": return "description"
                case "SoftwareVersion": return "software"
                default: return nil
                }
            }
            // `Id` e `DisplayName` sono figli diretti dell'elemento radice `Device`.
            if path.count == 2 {
                if last == "Id" { return "id" }
                if last == "DisplayName" { return "display" }
            }
            return nil
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            path.append(elementName)
            if let k = key(for: path), !finished.contains(k) {
                capturing = k
                values[k] = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let capturing { values[capturing, default: ""] += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if let k = capturing, key(for: path) == k {
                finished.insert(k)
                capturing = nil
            }
            _ = path.popLast()
        }
    }

    // MARK: - Nomi dei file

    /// Nomi di file candidati per un modello, dal più specifico al più generico. Si toglie
    /// accenti e maiuscole, si uniscono le parole senza separatori ("Forerunner 645 Music" →
    /// "forerunner645music") e poi si prova anche togliendo le ultime parole ("forerunner645").
    static func candidateNames(for description: String) -> [String] {
        let folded = description
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        var tokens = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if tokens.first == "garmin" { tokens.removeFirst() }
        guard !tokens.isEmpty else { return [] }

        // Varianti della lista di parole: completa, senza "inreach", senza parole accessorie
        // (solar, sapphire, amoled...) e senza la misura in mm; la misura (es. "51mm") viene
        // provata anche in coda al nome base ("fenix9pro51mm"), come usano alcuni file Garmin.
        let noise: Set<String> = ["inreach", "solar", "sapphire", "amoled", "titanium", "dlc", "edition", "series"]
        let isSize: (String) -> Bool = { $0.hasSuffix("mm") && $0.dropLast(2).allSatisfy(\.isNumber) }
        let size = tokens.first(where: isSize)
        var variants: [[String]] = [tokens]
        variants.append(tokens.filter { $0 != "inreach" })
        let core = tokens.filter { !noise.contains($0) && !isSize($0) }
        if let size { variants.append(core + [size]) }
        variants.append(core)

        var names: [String] = []
        // Alcuni file Garmin separano la misura con un trattino ("fenix9pro-51mm", "fenix3-rgt").
        if let size {
            let base = core.joined()
            if !base.isEmpty { names.append("\(base)-\(size)") }
        }
        for variant in variants {
            var count = variant.count
            while count >= 1 {
                let name = variant.prefix(count).joined()
                if !names.contains(name) { names.append(name) }
                // Si ferma a due parole (es. "fenix6"), per non finire sul solo nome della famiglia.
                if count <= 2 { break }
                count -= 1
            }
        }
        return names
    }

    // MARK: - Immagine

    /// Restituisce l'immagine del modello (dalla cache o scaricandola), o nil se non disponibile.
    /// `graphicURL`: immagine ufficiale indicata da Garmin (`unit-info`); se è un PNG si usa per prima (e si tiene in
    /// cache), altrimenti o se non risponde si passa alla ricerca di sempre.
    static func image(forModel info: ModelInfo, graphicURL: URL? = nil, overrideURL: URL? = nil) async -> NSImage? {
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        // Immagine scelta a mano dall'utente nell'elenco dei prodotti: ha la precedenza su tutto.
        if let overrideURL, let image = await image(fromCatalogURL: overrideURL) { return image }
        if let graphicURL, let image = await garminGraphic(graphicURL) { return image }

        let part = info.partNumber?.trimmingCharacters(in: .whitespaces).lowercased()
        let candidates = info.description.map { candidateNames(for: $0) } ?? []
        guard part != nil || !candidates.isEmpty else { return nil }

        // 1) Cache: part number o nome già scaricati.
        var cacheKeys: [String] = []
        if let part { cacheKeys.append("pn-\(part)") }
        cacheKeys += candidates
        for key in cacheKeys {
            if let image = NSImage(contentsOf: cacheFile(key)) { return image }
        }
        // 2) "Nessuna immagine" già verificata per questo modello: non si riprova a ogni connessione.
        let noneMarker = cacheFolder.appendingPathComponent("\(cacheKeys[0]).miss3")
        if let date = (try? noneMarker.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(date) < 7 * 24 * 3600 {
            return nil
        }
        var tried: [String] = []
        // 3) Elenco dispositivi del Connect IQ Store, cercando il part number.
        if let part {
            tried.append("storePartNumber:\(part)")
            if let imageURL = await storeImageURL(forPartNumber: part),
               let data = await download(imageURL, timeout: 12),
               let thumb = thumbnailPNG(from: data) {
                try? thumb.write(to: cacheFile("pn-\(part)"))
                return NSImage(data: thumb)
            }
        }
        // 4) CDN "bydevice" con i nomi ricavati dalla descrizione.
        for name in candidates {
            tried.append(name)
            guard let url = URL(string: baseURL + name + ".png"),
                  let data = await download(url),
                  let thumb = thumbnailPNG(from: data) else { continue }
            try? thumb.write(to: cacheFile(name))
            return NSImage(data: thumb)
        }
        // Nel marcatore si annotano i tentativi, utile per capire cosa manca sul sito.
        try? Data(tried.joined(separator: "\n").utf8).write(to: noneMarker)
        return nil
    }

    /// Immagine ufficiale del prodotto (`graphicUrl` di Garmin): dalla cache o scaricandola. Si accetta solo un vero PNG
    /// (firma del file); altrimenti nil e si usano le altre fonti. Chiave di cache dal percorso dell'indirizzo.
    private static func garminGraphic(_ url: URL) async -> NSImage? {
        let key = "gx-" + url.pathComponents.suffix(3).joined(separator: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        if let image = NSImage(contentsOf: cacheFile(key)) { return image }
        guard url.pathExtension.lowercased() == "png", let data = await download(url, timeout: 12),
              data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
              let thumb = thumbnailPNG(from: data) else { return nil }
        try? thumb.write(to: cacheFile(key))
        return NSImage(data: thumb)
    }

    // MARK: Elenco prodotti per la scelta manuale dell'immagine

    /// Un prodotto dell'elenco `deviceTypes` di Garmin (Connect IQ Store).
    struct CatalogDevice: Identifiable, Hashable {
        let name: String
        let additionalNames: [String]
        let partNumber: String
        let imageURL: URL
        var id: String { partNumber + "|" + imageURL.absoluteString }
        /// Testo su cui cerca il campo di ricerca (nome, varianti, part number), senza ®/™ e senza maiuscole.
        var searchText: String {
            ([name, partNumber] + additionalNames).joined(separator: " ").lowercased()
                .replacingOccurrences(of: "®", with: "").replacingOccurrences(of: "™", with: "")
        }
        /// Nome da mostrare, senza ® e ™.
        var displayName: String { name.replacingOccurrences(of: "®", with: "").replacingOccurrences(of: "™", with: "") }
    }

    /// Elenco dei prodotti con immagine, ordinato per nome. Usa il file già in cache (7 giorni) o lo scarica;
    /// senza rete e senza cache restituisce un elenco vuoto.
    static func catalogDevices() async -> [CatalogDevice] {
        guard let data = await deviceTypesData(), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var entries: [[String: Any]] = []
        if let array = json as? [[String: Any]] {
            entries = array
        } else if let dict = json as? [String: Any] {
            for value in dict.values { if let array = value as? [[String: Any]] { entries = array; break } }
        }
        var list: [CatalogDevice] = []
        for entry in entries {
            guard let name = entry["name"] as? String, let urlText = entry["imageUrl"] as? String,
                  let url = URL(string: urlText), url.scheme == "https" else { continue }
            list.append(CatalogDevice(name: name, additionalNames: entry["additionalNames"] as? [String] ?? [],
                                      partNumber: (entry["partNumber"] as? String) ?? "", imageURL: url))
        }
        return list.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Immagine di un prodotto dell'elenco (scaricata una volta, poi dalla cache).
    static func image(fromCatalogURL url: URL) async -> NSImage? {
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let key = "cat-" + url.pathComponents.suffix(4).joined(separator: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        if let image = NSImage(contentsOf: cacheFile(key)) { return image }
        guard url.scheme == "https", let data = await download(url, timeout: 12), let thumb = thumbnailPNG(from: data) else { return nil }
        try? thumb.write(to: cacheFile(key))
        return NSImage(data: thumb)
    }

    /// Cerca nell'elenco `deviceTypes` (tenuto in cache 7 giorni) il dispositivo con quel part number
    /// e ne restituisce l'indirizzo dell'immagine.
    private static func storeImageURL(forPartNumber part: String) async -> URL? {
        guard let data = await deviceTypesData(), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        // L'elenco può essere un array o un dizionario che contiene un array.
        var entries: [[String: Any]] = []
        if let array = json as? [[String: Any]] {
            entries = array
        } else if let dict = json as? [String: Any] {
            for value in dict.values {
                if let array = value as? [[String: Any]] { entries = array; break }
            }
        }
        for entry in entries {
            guard let partText = entry["partNumber"] as? String else { continue }
            let parts = partText.split(whereSeparator: { ",; ".contains($0) }).map { $0.lowercased() }
            if parts.contains(part), let urlText = entry["imageUrl"] as? String, let url = URL(string: urlText) {
                return url
            }
        }
        return nil
    }

    /// Scarica (o legge dalla cache locale, valida 7 giorni) il JSON dell'elenco dispositivi.
    private static func deviceTypesData() async -> Data? {
        let file = cacheFolder.appendingPathComponent("deviceTypes.json")
        if let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(date) < 7 * 24 * 3600,
           let cached = try? Data(contentsOf: file) {
            return cached
        }
        guard let url = URL(string: deviceTypesURL), let data = await download(url, timeout: 15) else {
            // Rete assente: meglio un elenco vecchio che nessuno.
            return try? Data(contentsOf: file)
        }
        try? data.write(to: file)
        return data
    }

    private static func download(_ url: URL, timeout: TimeInterval = 8) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              !data.isEmpty else { return nil }
        return data
    }


    /// Elabora l'immagine scaricata e la restituisce in PNG con trasparenza:
    /// 1. toglie lo sfondo uniforme (colore degli angoli) con un riempimento dai bordi e margine
    ///    sfumato, così non resta un alone chiaro attorno al prodotto;
    /// 2. ritaglia il prodotto ai suoi bordi, per farlo occupare tutto il riquadro;
    /// 3. lo ridimensiona (lato massimo `maxPixelSize`).
    /// Se l'immagine ha già la trasparenza, o lo sfondo non è uniforme, non si toglie nulla.
    private static func thumbnailPNG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 2, h > 2 else { return nil }

        // Il contesto possiede la propria memoria (`data: nil`): l'immagine ricavata da `makeImage()`
        // condivide quel buffer, che quindi deve vivere quanto l'immagine (con un array locale passato
        // al contesto, il buffer veniva liberato a fine blocco e l'immagine puntava a memoria non valida).
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rowBytes = ctx.bytesPerRow
        let p = base.bindMemory(to: UInt8.self, capacity: rowBytes * h)
        // Indice del primo byte (R) del pixel (x, y).
        @inline(__always) func at(_ x: Int, _ y: Int) -> Int { y * rowBytes + x * 4 }

        // Trasparenza già presente? (un pixel di bordo non opaco)
        var hasAlpha = false
        for x in 0..<w where p[at(x, 0) + 3] < 250 || p[at(x, h - 1) + 3] < 250 { hasAlpha = true; break }
        if !hasAlpha { for y in 0..<h where p[at(0, y) + 3] < 250 || p[at(w - 1, y) + 3] < 250 { hasAlpha = true; break } }

        if !hasAlpha {
            // Colore di sfondo = media dei quattro angoli.
            let corners = [at(0, 0), at(w - 1, 0), at(0, h - 1), at(w - 1, h - 1)]
            var bg = [0, 0, 0]
            for c in corners { for k in 0..<3 { bg[k] += Int(p[c + k]) } }
            bg = bg.map { $0 / 4 }
            // Gli angoli devono essere simili tra loro: altrimenti lo sfondo non è uniforme.
            let uniform = corners.allSatisfy { c in (0..<3).allSatisfy { abs(Int(p[c + $0]) - bg[$0]) < 12 } }
            if uniform {
                let low = 10, high = 44
                func distance(_ x: Int, _ y: Int) -> Int {
                    let i = at(x, y)
                    return max(abs(Int(p[i]) - bg[0]), abs(Int(p[i + 1]) - bg[1]), abs(Int(p[i + 2]) - bg[2]))
                }
                var visited = [Bool](repeating: false, count: w * h)
                var stack: [Int] = []   // pixel come y * w + x
                func seed(_ x: Int, _ y: Int) {
                    let n = y * w + x
                    if !visited[n], distance(x, y) <= high { visited[n] = true; stack.append(n) }
                }
                for x in 0..<w { seed(x, 0); seed(x, h - 1) }
                for y in 0..<h { seed(0, y); seed(w - 1, y) }
                while let n = stack.popLast() {
                    let x = n % w, y = n / w
                    if x > 0 { seed(x - 1, y) }
                    if x < w - 1 { seed(x + 1, y) }
                    if y > 0 { seed(x, y - 1) }
                    if y < h - 1 { seed(x, y + 1) }
                }
                for y in 0..<h {
                    for x in 0..<w where visited[y * w + x] {
                        let d = distance(x, y)
                        let a = d <= low ? 0.0 : Double(d - low) / Double(high - low)
                        let i = at(x, y)
                        // Colore premoltiplicato senza il contributo dello sfondo: c − bg·(1 − a).
                        for k in 0..<3 {
                            let value = Double(p[i + k]) - Double(bg[k]) * (1 - a)
                            p[i + k] = UInt8(max(0, min(255, value.rounded())))
                        }
                        p[i + 3] = UInt8(max(0, min(255, (a * 255).rounded())))
                    }
                }
            }
        }

        // Riquadro dei pixel visibili (alfa > 8), per ritagliare il prodotto.
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where p[at(x, y) + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        let box = (maxX >= minX && maxY >= minY) ? (minX, minY, maxX, maxY) : (0, 0, w - 1, h - 1)
        guard let cleaned = ctx.makeImage(),
              let cropped = cleaned.cropping(to: CGRect(x: box.0, y: box.1,
                                                        width: box.2 - box.0 + 1,
                                                        height: box.3 - box.1 + 1)) else { return nil }

        // Ridimensiona (lato massimo maxPixelSize) mantenendo le proporzioni e la trasparenza.
        let scale = Double(maxPixelSize) / Double(max(cropped.width, cropped.height))
        let outW = max(1, Int((Double(cropped.width) * scale).rounded()))
        let outH = max(1, Int((Double(cropped.height) * scale).rounded()))
        guard let out = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        out.interpolationQuality = .high
        out.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let final = out.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: final).representation(using: .png, properties: [:])
    }
}

// MARK: - Controllo aggiornamento software (server Garmin)

/// Esito del controllo dell'aggiornamento software del dispositivo.
enum SoftwareUpdateStatus: Equatable {
    case upToDate
    case available(version: String, notes: String?)
}

/// Chiede ai server Garmin (stesso servizio usato da Garmin Express, non documentato) se esiste un aggiornamento
/// del software di sistema per il dispositivo. Invia il contenuto di GarminDevice.xml; non scarica né installa nulla.
/// Qualsiasi anomalia (rete, risposta diversa dal previsto) restituisce nil: nessuna etichetta, nessun errore.
enum GarminUpdateService {
    private static let endpoint = URL(string: "https://omt.garmin.com/api/device-software/v1/updates")!

    static func check(deviceXML: Data, installedVersion: String?) async -> SoftwareUpdateStatus? {
        // Prova della finestra «Aggiornamento disponibile» senza interrogare Garmin (il server decide in base all'unità, non alla
        // versione scritta nell'XML). Si accende da Terminale:  defaults write com.crdev.MusicManager debugFakeSoftwareUpdate -bool YES
        // e si spegne con:  defaults delete com.crdev.MusicManager debugFakeSoftwareUpdate
        if UserDefaults.standard.bool(forKey: "debugFakeSoftwareUpdate") {
            AppLog.debug("Controllo aggiornamento software: SIMULATO (debugFakeSoftwareUpdate), installata \(installedVersion ?? "?")")
            return .available(version: "9.99", notes: "Aggiornamento simulato (prova della finestra).\nNessun dato è stato chiesto a Garmin.")
        }
        // Prova diagnostica: `defaults write com.crdev.MusicManager debugUpdateInteractive -bool YES` chiede al server come se l'utente
        // avesse cliccato «cerca aggiornamenti» (Garmin Express): il server potrebbe nascondere gli aggiornamenti non critici
        // alle richieste automatiche. Si spegne con `defaults delete com.crdev.MusicManager debugUpdateInteractive`.
        let interactive = UserDefaults.standard.bool(forKey: "debugUpdateInteractive")
        if interactive { AppLog.debug("Controllo aggiornamento software: richiesta INTERATTIVA (debugUpdateInteractive)") }
        guard let xml = String(data: deviceXML, encoding: .utf8),
              let body = try? JSONSerialization.data(withJSONObject: ["GarminDeviceXml": xml, "IsUserInteractive": interactive])
        else { return nil }

        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        let headers = [
            "appId": "Garmin_Express",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-garmin-client-id": "EXPRESS",
            "Garmin-Client-Name": "express",
            "Garmin-Client-Platform": "Mac",
            "Garmin-Client-SessionId": UUID().uuidString,
            "Accept-Language": GarminUnitInfoService.acceptLanguage,   // come Garmin Express: lingua dell'app
            "User-Agent": "MusicManager"
        ]
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updates = json["updates"] as? [[String: Any]]
        else {
            AppLog.debug("Controllo aggiornamento software: nessuna risposta utilizzabile dal server (versione installata \(installedVersion ?? "?"))")
            return nil
        }
        AppLog.debug("Controllo aggiornamento software: installata \(installedVersion ?? "?"); il server propone " +
                     updates.map { "\(($0["dataType"] as? String) ?? "?") \(($0["displayVersion"] as? String) ?? ($0["version"] as? String) ?? "?")" }.joined(separator: ", "))

        // Diagnosi (solo log dettagliato): campi semplici di ogni elemento della risposta, senza note di rilascio né indirizzi, per capire
        // quale campo contiene la versione che Garmin Express mostra (es. «System Software Bundle»).
        for (i, u) in updates.enumerated() {
            let fields = u.keys.sorted().compactMap { key -> String? in
                guard key != "releaseNotes", !key.lowercased().contains("url"), !key.lowercased().contains("uri") else { return nil }
                switch u[key] {
                case let v as String: return "\(key)=\(v.prefix(80))"
                case let v as NSNumber: return "\(key)=\(v)"
                case let v as [Any]: return "\(key)=[\(v.count) elementi]"
                case let v as [String: Any]: return "\(key)={\(v.keys.sorted().joined(separator: ","))}"
                default: return nil
                }
            }
            AppLog.debug("Controllo aggiornamento software: elemento \(i + 1): " + fields.joined(separator: "; "))
        }

        // Solo il firmware (il secondo elemento della risposta, «UpdateMetadata», è un file di servizio).
        let firmware = updates.filter { ($0["dataType"] as? String)?.lowercased() == "firmware" }
        func versionText(_ u: [String: Any]) -> String? { (u["displayVersion"] as? String) ?? (u["version"] as? String) }
        let best = firmware.max { (versionText($0) ?? "").compare(versionText($1) ?? "", options: .numeric) == .orderedAscending }
        guard let best, let version = versionText(best) else { return .upToDate }
        // Se la versione proposta non è più recente di quella installata, il dispositivo è aggiornato.
        if let installedVersion, version.compare(installedVersion, options: .numeric) != .orderedDescending {
            return .upToDate
        }
        let notes = (best["releaseNotes"] as? [[String: Any]])?
            .compactMap { $0["changeLog"] as? [String] }.flatMap { $0 }.joined(separator: "\n")
        return .available(version: version, notes: (notes?.isEmpty ?? true) ? nil : notes)
    }
}


// MARK: - Copia locale di GarminDevice.xml

/// Copia locale di `GarminDevice.xml` dei dispositivi registrati: una cartella per dispositivo,
/// Application Support/MusicManager/Devices/DeviceXML/<Global ID>/GarminDevice.xml (la cartella è pensata anche per
/// altri dati del dispositivo in futuro). Si riscrive a ogni collegamento; serve a interrogare i server Garmin
/// (aggiornamenti, in futuro mappe) anche a dispositivo scollegato. Contiene anche codici di sblocco: resta solo sul
/// Mac, non si mostra e non si registra altrove.
enum DeviceXMLStore {
    private static var folder: URL { AppFolders.devicesXML }

    /// Il Global ID diventa nome di cartella: si tengono solo caratteri sicuri.
    private static func deviceFolder(_ id: String) -> URL {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return folder.appendingPathComponent(safe, isDirectory: true)
    }

    private static func file(_ id: String) -> URL {
        deviceFolder(id).appendingPathComponent("GarminDevice.xml")
    }

    static func save(_ xml: Data, forDevice id: String) {
        try? FileManager.default.createDirectory(at: deviceFolder(id), withIntermediateDirectories: true)
        try? xml.write(to: file(id), options: .atomic)
    }

    /// Contenuto e data dell'ultima lettura dal dispositivo (nil se non c'è una copia).
    static func load(forDevice id: String) -> (xml: Data, date: Date?)? {
        let url = file(id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return (data, date)
    }

    // MARK: Mappe installate (Maps.json, accanto a GarminDevice.xml)

    /// Esito dell'ultimo controllo delle mappe: data e mappe installate. Serve a Settings / Advanced a dispositivo
    /// scollegato e a decidere quando ricontrollare (le mappe escono circa ogni 3 mesi).
    struct StoredMaps: Codable {
        var checkedAt: Date
        var installed: [GarminMapEntry]
        /// Aree offerte da Garmin (assente nei file scritti dalle versioni precedenti).
        var available: [GarminMapEntry]?
    }

    private static func mapsFile(_ id: String) -> URL { deviceFolder(id).appendingPathComponent("Maps.json") }

    static func saveMaps(_ catalog: GarminMapsCatalog, forDevice id: String, checkedAt: Date = Date()) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(StoredMaps(checkedAt: checkedAt, installed: catalog.installed, available: catalog.available)) else { return }
        try? FileManager.default.createDirectory(at: deviceFolder(id), withIntermediateDirectories: true)
        try? data.write(to: mapsFile(id), options: .atomic)
    }

    /// Perché Maps.json non si legge (nil se non c'è il file o se è tutto a posto): per la diagnostica in Settings.
    static func mapsReadProblem(forDevice id: String) -> String? {
        guard let data = try? Data(contentsOf: mapsFile(id)) else { return "Maps.json non trovato in \(mapsFile(id).path)" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { _ = try decoder.decode(StoredMaps.self, from: data); return nil }
        catch { return "Maps.json non leggibile: \(error)" }
    }

    static func loadMaps(forDevice id: String) -> StoredMaps? {
        guard let data = try? Data(contentsOf: mapsFile(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StoredMaps.self, from: data)
    }

    static func remove(forDevice id: String) { try? FileManager.default.removeItem(at: deviceFolder(id)) }
    static func removeAll() { try? FileManager.default.removeItem(at: folder) }
}


// MARK: - Cartelle dei dati dell'app

/// Organizzazione di `~/Library/Application Support/MusicManager/`:
/// - `External Library/` — copie compatte (json) delle librerie esterne già lette;
/// - `Devices/Images/` — immagini dei dispositivi e elenco del Connect IQ Store;
/// - `Devices/DeviceXML/<Global ID>/GarminDevice.xml` — copia dell'XML dei dispositivi registrati;
/// - `Artwork/ConfirmedArtwork/`, `Artwork/ArtworkCache/` — copertine (gestite da `ArtworkCache`).
enum AppFolders {
    nonisolated static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicManager", isDirectory: true)
    }
    nonisolated static var externalLibrary: URL { base.appendingPathComponent("External Library", isDirectory: true) }
    nonisolated static var artwork: URL { base.appendingPathComponent("Artwork", isDirectory: true) }
    nonisolated static var devices: URL { base.appendingPathComponent("Devices", isDirectory: true) }
    nonisolated static var devicesImages: URL { devices.appendingPathComponent("Images", isDirectory: true) }
    nonisolated static var devicesXML: URL { devices.appendingPathComponent("DeviceXML", isDirectory: true) }

    /// Sposta nelle nuove cartelle quanto salvato dalle versioni precedenti (stessi file, nessuna rilettura):
    /// `ConfirmedArtwork` e `ArtworkCache` → `Artwork/`, `DeviceImages` → `Devices/Images`, `DeviceXML` → `Devices/DeviceXML`, `external-library-v3-*.json` →
    /// `External Library/`. Si può chiamare a ogni avvio: se non c'è nulla da spostare non fa niente.
    nonisolated static func migrateLegacyFolders() {
        let fm = FileManager.default
        func moveFolder(_ old: URL, to new: URL) {
            guard fm.fileExists(atPath: old.path) else { return }
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: new.path) {
                try? fm.moveItem(at: old, to: new)
                return
            }
            // La destinazione esiste già: si uniscono le cartelle (anche annidate) spostando solo gli elementi mancanti;
            // un file già presente nella destinazione ha la precedenza e quello vecchio si scarta.
            func merge(_ from: URL, into to: URL) {
                for item in (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                    let target = to.appendingPathComponent(item.lastPathComponent)
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    if !fm.fileExists(atPath: target.path) {
                        try? fm.moveItem(at: item, to: target)
                    } else if isDir {
                        merge(item, into: target)
                    }
                }
            }
            merge(old, into: new)
            try? fm.removeItem(at: old)
        }
        // Ridenominazione del progetto (2.1 Beta 2): «GarminMusicManager» → «MusicManager» nei dati dell'app e in Musica.
        // Prima di tutto, così le migrazioni successive trovano già i dati nella cartella nuova.
        let oldBase = base.deletingLastPathComponent().appendingPathComponent("GarminMusicManager", isDirectory: true)
        moveFolder(oldBase, to: base)
        let music = fm.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true)
        moveFolder(music.appendingPathComponent("GarminMusicManager", isDirectory: true),
                   to: music.appendingPathComponent("MusicManager", isDirectory: true))
        moveFolder(base.appendingPathComponent("ConfirmedArtwork", isDirectory: true),
                   to: artwork.appendingPathComponent("ConfirmedArtwork", isDirectory: true))
        moveFolder(base.appendingPathComponent("ArtworkCache", isDirectory: true),
                   to: artwork.appendingPathComponent("ArtworkCache", isDirectory: true))
        moveFolder(base.appendingPathComponent("DeviceImages", isDirectory: true), to: devicesImages)
        moveFolder(base.appendingPathComponent("DeviceXML", isDirectory: true), to: devicesXML)
        let legacy = ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("external-library-v3-") && $0.pathExtension == "json" }
        if !legacy.isEmpty {
            try? fm.createDirectory(at: externalLibrary, withIntermediateDirectories: true)
            for file in legacy {
                let target = externalLibrary.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: file) } else { try? fm.moveItem(at: file, to: target) }
            }
        }
        // Le copie compatte delle librerie esterne v3 non hanno il genere: si eliminano, si rileggono dall'XML (2.1 Beta 2).
        for old in (try? fm.contentsOfDirectory(at: externalLibrary, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("external-library-v3-") {
            try? fm.removeItem(at: old)
        }
    }
}


// MARK: - Informazioni sull'unità (server Garmin)

/// Dati dell'unità restituiti dal servizio Garmin `unit-info`: numero di serie di produzione (quello stampato
/// sull'orologio) e immagine ufficiale del prodotto.
struct GarminUnitInfo {
    var serialNumber: String?
    var graphicURL: URL?
    var deviceModel: String?
    var unitPartNumber: String?
}

/// Chiede a Garmin le informazioni di un'unità (stesso servizio di Garmin Express, non documentato):
/// `GET https://omt.garmin.com/api/unit-info/manufacturers/<produttore>/unitids/<unitId>`. Invia solo l'ID dell'unità.
/// Qualsiasi anomalia restituisce nil. NON VERIFICATO: il segmento «Taiwan» è quello visto nella cattura della
/// fēnix 9 Pro; non si sa da dove venga (paese di produzione?) e se vale per altri modelli.
enum GarminUnitInfoService {
    private static let manufacturer = "Taiwan"

    /// Lingua dell'app nel formato di Garmin Express («it-IT,it;q=0.9»): italiano o inglese.
    static var acceptLanguage: String {
        LocalizationStore.language == .it ? "it-IT,it;q=0.9" : "en-US,en;q=0.9"
    }

    static func fetch(unitID: String) async -> GarminUnitInfo? {
        // L'ID dell'unità è numerico (per la fēnix 9 Pro coincide col «Global ID» dell'XML, da confermare).
        guard !unitID.isEmpty, unitID.allSatisfy(\.isNumber),
              let url = URL(string: "https://omt.garmin.com/api/unit-info/manufacturers/\(manufacturer)/unitids/\(unitID)")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        let headers = [
            "appId": "Garmin_Express",
            "Accept": "application/json",
            "X-garmin-client-id": "EXPRESS",
            "Garmin-Client-Name": "express",
            "Garmin-Client-Platform": "Mac",
            "Garmin-Client-SessionId": UUID().uuidString,
            "Accept-Language": acceptLanguage,
            "User-Agent": "MusicManager"
        ]
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func text(_ key: String) -> String? {
            let v = (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
        return GarminUnitInfo(serialNumber: text("serialNumber"),
                              graphicURL: text("graphicUrl").flatMap { URL(string: $0) },
                              deviceModel: text("deviceModel"), unitPartNumber: text("unitPartNumber"))
    }
}


// MARK: - Mappe del dispositivo (server Garmin)

/// Una mappa del catalogo Garmin per il dispositivo: installata (con la versione letta dall'XML) oppure offerta.
struct GarminMapEntry: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let type: String
    /// Versione disponibile («2026.11»).
    let version: String
    let isInstalled: Bool
    /// Versione installata, letta da `UpdateFile` nell'XML del dispositivo (nil = sconosciuta o non installata).
    let installedVersion: String?
    /// true = c'è una versione più recente, false = aggiornata, nil = non determinabile.
    let updateAvailable: Bool?
    /// Installata: spazio occupato sul dispositivo; offerta: dimensione del download.
    let sizeBytes: UInt64
    /// Area geografica (livello più alto), per raggruppare le mappe offerte.
    let region: String?
    /// Nomi dei file sul dispositivo (da `filesToRemove`, solo mappe installate): una mappa può occupare più file
    /// (es. `D6185190A.img` più i file dei dati aggiuntivi). Assente nei Maps.json scritti dalle versioni precedenti.
    var files: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, type, version, isInstalled, installedVersion, updateAvailable, sizeBytes, region, files
    }
}

extension GarminMapEntry {
    /// Lettura esplicita (invece di quella generata): i campi facoltativi, compreso `files` assente nei Maps.json
    /// scritti dalle versioni precedenti, si leggono con `decodeIfPresent`.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        version = try c.decode(String.self, forKey: .version)
        isInstalled = try c.decode(Bool.self, forKey: .isInstalled)
        installedVersion = try c.decodeIfPresent(String.self, forKey: .installedVersion)
        updateAvailable = try c.decodeIfPresent(Bool.self, forKey: .updateAvailable)
        sizeBytes = try c.decode(UInt64.self, forKey: .sizeBytes)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        files = try c.decodeIfPresent([String].self, forKey: .files)
    }
}

struct GarminMapsCatalog {
    var installed: [GarminMapEntry]
    var available: [GarminMapEntry]

    /// Almeno una mappa installata ha una versione più recente da installare (esito dell'ultimo controllo, non in tempo reale).
    var hasUpdates: Bool { installed.contains { $0.updateAvailable == true } }

    /// Garmin non conosce nessuna mappa per questo dispositivo (né installata né offerta): è il caso di orologi che
    /// seguono tracce ma non supportano mappe (es. Forerunner 255). Niente globo, niente proposte di controllo.
    var isEmpty: Bool { installed.isEmpty && available.isEmpty }
}

/// Interroga Garmin (stesso servizio di Garmin Express, non documentato) per il catalogo delle mappe del dispositivo:
/// `POST https://omt.garmin.com/api/maps/universal/update` con `{"options":{"groupingMode":2,"extractionMode":2},
/// "garminDeviceXml": <contenuto di GarminDevice.xml>}`. Anonima; invia l'intero XML (codici di sblocco compresi).
/// Solo informativa: non scarica né installa nulla. Qualsiasi anomalia restituisce nil.
enum GarminMapsService {
    private static let endpoint = URL(string: "https://omt.garmin.com/api/maps/universal/update")!

    /// Versioni dei file presenti sul dispositivo: `UpdateFile` (PartNumber, Version/Major, Version/Minor) nell'XML.
    private final class UpdateFileParser: NSObject, XMLParserDelegate {
        var versions: [String: (major: Int, minor: Int)] = [:]
        /// Nome del file (senza estensione, maiuscolo) → PartNumber, per i file immagine/mappa citati dentro `UpdateFile`.
        var fileParts: [String: String] = [:]
        private var pendingStems: [String] = []
        private var path: [String] = []
        private var text = ""
        private var part = ""
        private var major = 0, minor = 0
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(name); text = ""
            if name == "UpdateFile" { part = ""; major = 0; minor = 0; pendingStems = [] }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.starts(with: ["Device"]), path.contains("UpdateFile") {
                switch name {
                case "PartNumber": part = value
                case "Major": major = Int(value) ?? 0
                case "Minor": minor = Int(value) ?? 0
                case "UpdateFile":
                    if !part.isEmpty {
                        versions[part] = (major, minor)
                        for stem in pendingStems { fileParts[stem] = part }
                    }
                default:
                    // Qualsiasi valore che sia un nome di file immagine/mappa (es. «D1399580A.img»).
                    let ext = (value as NSString).pathExtension.lowercased()
                    if ["img", "gma", "gmapsupp", "gcd"].contains(ext) {
                        let file = (value as NSString).lastPathComponent
                        pendingStems.append((file as NSString).deletingPathExtension.uppercased())
                    }
                }
            }
            _ = path.popLast(); text = ""
        }
    }

    /// File delle mappe sul dispositivo: nome del file (senza estensione, maiuscolo) → PartNumber della mappa, dall'XML.
    /// Serve al navigatore dei file per marcare i file delle mappe («Maps - Europe»).
    static func mapFileParts(fromXML data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        let delegate = UpdateFileParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.fileParts
    }

    static func installedVersions(fromXML data: Data) -> [String: (major: Int, minor: Int)] {
        let parser = XMLParser(data: data)
        let delegate = UpdateFileParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.versions
    }

    /// Vero se le mappe presenti sul dispositivo (da `UpdateFile` nell'XML appena letto) non coincidono più con quelle
    /// memorizzate in Maps.json: mappa aggiunta (una delle «offerte» ora è presente), rimossa o con versione diversa.
    /// Confronto solo locale, senza interrogare Garmin.
    static func mapsChanged(since stored: DeviceXMLStore.StoredMaps, xml: Data) -> Bool {
        let files = installedVersions(fromXML: xml)
        func partNumber(_ entry: GarminMapEntry) -> String? {
            guard let p = entry.id.split(separator: "|", omittingEmptySubsequences: false).last, !p.isEmpty else { return nil }
            return String(p)
        }
        for entry in stored.installed {
            guard let part = partNumber(entry), let before = entry.installedVersion else { continue }
            guard let now = files[part] else { return true }                 // rimossa
            if "\(now.major).\(now.minor)" != before { return true }       // versione cambiata
        }
        for entry in stored.available ?? [] {
            if let part = partNumber(entry), files[part] != nil { return true }  // aggiunta
        }
        return false
    }

    /// Nome dell'area di livello più alto per ogni codice di sotto-regione (es. «TopoActive-EU-West» → «Europa»).
    private static func regionTitles(_ nodes: [[String: Any]], top: String? = nil, into map: inout [String: String]) {
        for node in nodes {
            let info = node["subregionInfo"] as? [String: Any]
            let title = info?["title"] as? String
            let code = info?["code"] as? String
            let topTitle = top ?? title
            if let code, let topTitle { map[code] = topTitle }
            regionTitles(node["childSubregions"] as? [[String: Any]] ?? [], top: topTitle, into: &map)
        }
    }

    /// Nomi di file (img, gma, gmapsupp) trovati in qualunque campo testuale delle voci di `filesToRemove`
    /// (cerca in profondità, senza dipendere dal nome del campo). Nil se non ce ne sono.
    private static func fileNames(in value: Any?) -> [String]? {
        var found: [String] = []
        func walk(_ v: Any?) {
            if let text = v as? String {
                let name = (text as NSString).lastPathComponent
                if ["img", "gma", "gmapsupp"].contains((name as NSString).pathExtension.lowercased()) { found.append(name) }
            } else if let array = v as? [Any] {
                array.forEach { walk($0) }
            } else if let dict = v as? [String: Any] {
                dict.values.forEach { walk($0) }
            }
        }
        walk(value)
        return found.isEmpty ? nil : Array(Set(found)).sorted()
    }

    /// Restituisce il catalogo oppure, se qualcosa va storto, il motivo (mostrato nella finestra Mappe).
    static func fetch(deviceXML: Data) async -> (catalog: GarminMapsCatalog?, error: String?) {
        let xmlText = String(data: deviceXML, encoding: .utf8) ?? String(decoding: deviceXML, as: UTF8.self)
        guard let body = try? JSONSerialization.data(withJSONObject: [
                "options": ["groupingMode": 2, "extractionMode": 2], "garminDeviceXml": xmlText])
        else { return (nil, "XML non codificabile") }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = body
        let headers = [
            "appId": "Garmin_Express",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-garmin-client-id": "EXPRESS",
            "Garmin-Client-Name": "express",
            "Garmin-Client-Platform": "Mac",
            "Garmin-Client-SessionId": UUID().uuidString,
            "Garmin-Client-Version": "7.29.3.0",
            "Garmin-Client-Platform-Version": "27.0",
            "Garmin-Client-Platform-Version-Revision": "1",
            "Accept-Language": GarminUnitInfoService.acceptLanguage,
            "User-Agent": "Garmin Express Mac - 7.29.3.0"
        ]
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { return (nil, "Rete: \(error.localizedDescription)") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
            return (nil, "HTTP \(status) \(snippet)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let maps = json["maps"] as? [[String: Any]]
        else { return (nil, "Risposta senza elenco mappe (\(data.count) byte)") }

        let installedFiles = installedVersions(fromXML: deviceXML)
        var regions: [String: String] = [:]
        regionTitles(json["subregions"] as? [[String: Any]] ?? [], into: &regions)

        var installed: [GarminMapEntry] = [], available: [GarminMapEntry] = []
        for m in maps {
            guard let name = m["displayName"] as? String, let release = m["release"] as? [String: Any],
                  var major = release["majorVersion"] as? Int, let minor = release["minorVersion"] as? Int else { continue }
            let type = (m["mapType"] as? String) ?? ""
            let isInstalled = (m["installationState"] as? Int ?? 0) == 1
            let options = m["installOptions"] as? [[String: Any]] ?? []
            let option = options.first { $0["isPreferred"] as? Bool == true } ?? options.first
            let imagePart = (option?["identifier"] as? [String: Any])?["mapImagePartNumber"] as? String
            // Versione disponibile «2026.11» ↔ file installato «26.11»: si confronta con le ultime due cifre dell'anno.
            let shownMajor = major
            if major >= 100 { major %= 100 }
            let installedVersion = imagePart.flatMap { installedFiles[$0] }
            let update: Bool? = installedVersion.map { ($0.major, $0.minor) < (major, minor) }
            let size: UInt64
            if isInstalled {
                size = (m["filesToRemove"] as? [[String: Any]] ?? []).reduce(0) { $0 + UInt64(($1["sizeInBytes"] as? Int) ?? 0) }
            } else {
                size = (option?["files"] as? [[String: Any]] ?? []).reduce(0) { sum, f in
                    let first = (f["deliverableOptions"] as? [[String: Any]])?.first
                    return sum + UInt64((first?["sizeInBytes"] as? Int) ?? 0)
                }
            }
            let code = (option?["subregionReference"] as? [String: Any])?["code"] as? String
            let region = (m["geographicRegion"] as? [String: Any])?["title"] as? String ?? code.flatMap { regions[$0] }
            let entry = GarminMapEntry(
                id: name + "|" + (imagePart ?? ""), name: name, type: type, version: "\(shownMajor).\(minor)",
                isInstalled: isInstalled,
                installedVersion: installedVersion.map { "\($0.major).\($0.minor)" },
                updateAvailable: isInstalled ? update : nil, sizeBytes: size, region: region,
                files: isInstalled ? Self.fileNames(in: m["filesToRemove"]) : nil)
            if isInstalled { installed.append(entry) } else { available.append(entry) }
        }
        installed.sort { ($0.type, $0.name) < ($1.type, $1.name) }
        available.sort { (($0.region ?? "~"), $0.name) < (($1.region ?? "~"), $1.name) }
        return (GarminMapsCatalog(installed: installed, available: available), nil)
    }
}


// MARK: - Dispositivi Garmin montati come volume (archiviazione di massa) — 2.1 Beta 2, fase 1

/// Dispositivo Garmin che macOS vede come disco esterno (non MTP). Fase 1: solo riconoscimento e informazioni.
struct VolumeDevice: Identifiable, Equatable {
    let url: URL
    let name: String
    let info: DeviceImageService.ModelInfo
    let isMusicCapable: Bool
    let totalBytes: Int64
    let freeBytes: Int64
    /// Contenuto di GarminDevice.xml (per i controlli opzionali di aggiornamenti e mappe, fase 1b).
    let xml: Data
    var id: String { url.path }
}

/// Cerca tra i volumi montati i dispositivi Garmin. Un volume è accettato solo se:
/// 1. è esterno (rimovibile o espellibile; mai il disco interno);
/// 2. contiene `Garmin/GarminDevice.xml` (nomi di cartella e file senza distinguere maiuscole/minuscole);
/// 3. il file è un XML con radice `Device` nello spazio dei nomi Garmin e un `Model/Description` non vuoto.
/// I volumi che non rispettano tutte le condizioni vengono ignorati in silenzio.
enum VolumeDeviceScanner {
    static func scan() -> [VolumeDevice] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                      .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return [] }
        var found: [VolumeDevice] = []
        for url in urls where url.path != "/" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.volumeIsInternal == true { continue }
            guard values.volumeIsRemovable == true || values.volumeIsEjectable == true else { continue }
            guard let xmlURL = garminDeviceXML(in: url),
                  let data = try? Data(contentsOf: xmlURL), data.count > 0, data.count < 2_000_000,
                  hasGarminDeviceRoot(data) else { continue }
            let info = DeviceImageService.modelInfo(fromXML: data)
            guard let description = info.description, !description.isEmpty else { continue }
            let media = DeviceImageService.mediaCapabilities(fromXML: data)
            found.append(VolumeDevice(url: url,
                                      name: values.volumeName ?? url.lastPathComponent,
                                      info: info,
                                      isMusicCapable: media?.isMusicCapable ?? false,
                                      totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                                      freeBytes: Int64(values.volumeAvailableCapacity ?? 0),
                                      xml: data))
        }
        return found
    }

    /// `<volume>/Garmin/GarminDevice.xml`, cercando le cartelle senza distinguere maiuscole e minuscole.
    private static func garminDeviceXML(in volume: URL) -> URL? {
        let fm = FileManager.default
        guard let root = try? fm.contentsOfDirectory(atPath: volume.path),
              let garmin = root.first(where: { $0.caseInsensitiveCompare("Garmin") == .orderedSame }) else { return nil }
        let folder = volume.appendingPathComponent(garmin)
        guard let inner = try? fm.contentsOfDirectory(atPath: folder.path),
              let file = inner.first(where: { $0.caseInsensitiveCompare("GarminDevice.xml") == .orderedSame }) else { return nil }
        return folder.appendingPathComponent(file)
    }

    /// Vero se la radice del documento è `Device` nello spazio dei nomi `www.garmin.com/xmlschemas/GarminDevice`.
    private static func hasGarminDeviceRoot(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        let delegate = RootParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.rootName == "Device" && (delegate.rootNamespace ?? "").contains("garmin.com/xmlschemas/GarminDevice")
    }

    private final class RootParser: NSObject, XMLParserDelegate {
        var rootName: String?
        var rootNamespace: String?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            rootName = elementName
            rootNamespace = namespaceURI
            parser.abortParsing()   // basta la radice
        }
    }
}
