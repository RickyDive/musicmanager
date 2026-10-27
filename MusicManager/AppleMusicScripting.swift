import Foundation
import AppKit

/// Crea, legge o aggiorna playlist nell'app Musica via Apple Event (AppleScript), per salvare
/// anche li la Custom Playlist creata in questa app. Non serve nessuna entitlement particolare (il
/// progetto ha già `com.apple.security.app-sandbox: false`): basta `NSAppleEventsUsageDescription`
/// in Info.plist, che fa comparire la richiesta di permesso di automazione la prima volta.
enum AppleMusicScripting {
    enum ScriptingError: LocalizedError {
        case scriptCreationFailed
        case appleScriptError(String)
        var errorDescription: String? {
            switch self {
            case .scriptCreationFailed: return t("error_unknown")
            case .appleScriptError(let message): return message
            }
        }
    }

    // MARK: Cartella «Music Manager»

    /// Nome della cartella di Musica in cui finiscono tutte le playlist salvate da questa app, così restano
    /// raggruppate e non si mischiano a quelle create dall'utente.
    static let folderName = "Music Manager"
    /// Simbolo davanti al nome della cartella. Per usare un altro simbolo basta cambiare questo valore (per il
    /// glifo di SF Symbols: app SF Symbols ▸ Modifica ▸ Copia simbolo, poi incollarlo qui). La cartella si
    /// riconosce dalla parte finale del nome, quindi cambiarlo non crea cartelle doppie (la già esistente si
    /// rinomina a mano in Musica).
    static let folderIcon = "≡♪"
    private static var folderTitle: String { folderIcon + " " + folderName }

    /// AppleScript (da inserire dentro `tell application "Music"`): trova la cartella in `gmmFolder` (missing
    /// value se non c'è) e, con `create`, la crea se manca.
    private static func folderLookup(create: Bool) -> String {
        var lines = [
            "    set gmmFolder to missing value",
            "    repeat with f in (every folder playlist)",
            "        if (name of f) ends with \"\(escaped(folderName))\" then",
            "            set gmmFolder to contents of f",
            "            exit repeat",
            "        end if",
            "    end repeat"
        ]
        // Ridenominazione (2.1 Beta 2): la cartella creata dalle versioni precedenti, «≡♪ Garmin Music Manager», prende
        // il nome nuovo con le sue playlist. Solo se il nome finisce proprio con il nome vecchio.
        lines += [
            "    if gmmFolder is not missing value then",
            "        if (name of gmmFolder) ends with \"Garmin \(escaped(folderName))\" then",
            "            set name of gmmFolder to \"\(escaped(folderTitle))\"",
            "        end if",
            "    end if"
        ]
        if create {
            lines += [
                "    if gmmFolder is missing value then",
                "        set gmmFolder to make new folder playlist with properties {name:\"\(escaped(folderTitle))\"}",
                "    end if"
            ]
        }
        return lines.joined(separator: "\n")
    }

    /// AppleScript: cerca la playlist `name` **dentro la cartella** (in `targetPlaylist`, missing value se non c'è).
    /// Una playlist con lo stesso nome fuori dalla cartella (creata dall'utente) non viene mai toccata.
    private static func playlistLookup(_ name: String) -> String {
        [
            "    set targetPlaylist to missing value",
            "    if gmmFolder is not missing value then",
            "        repeat with p in (every user playlist whose name is \"\(escaped(name))\")",
            "            try",
            "                if (name of parent of p) is (name of gmmFolder) then",
            "                    set targetPlaylist to contents of p",
            "                    exit repeat",
            "                end if",
            "            end try",
            "        end repeat",
            "    end if"
        ].joined(separator: "\n")
    }

    /// true se la cartella di questa app contiene già una playlist con questo nome.
    static func playlistExists(named name: String) throws -> Bool {
        let script = """
        tell application "Music"
        \(folderLookup(create: false))
        \(playlistLookup(name))
            return targetPlaylist is not missing value
        end tell
        """
        return try run(script)?.booleanValue ?? false
    }

    /// Percorsi POSIX dei file dei brani già presenti in una playlist (della cartella dell'app), per capire
    /// quali brani della Custom Playlist risultano già aggiunti prima di aggiungerli una seconda
    /// volta. I brani senza un file locale (es. in streaming) vengono ignorati: non possono
    /// comunque comparire nella Custom Playlist, che contiene solo brani letti da iTunesLibrary.
    static func existingTrackPaths(inPlaylistNamed name: String) throws -> [String] {
        let script = """
        tell application "Music"
        \(folderLookup(create: false))
        \(playlistLookup(name))
            set thePaths to {}
            if targetPlaylist is missing value then return thePaths
            repeat with t in (tracks of targetPlaylist)
                try
                    set end of thePaths to POSIX path of (location of t)
                end try
            end repeat
            return thePaths
        end tell
        """
        guard let result = try run(script) else { return [] }
        // Con zero o un solo elemento, AppleScript può restituire il valore "nudo" invece di una
        // lista di un elemento: numberOfItems vale 0 anche in quel caso, da cui il controllo su
        // stringValue come scorciatoia per l'elemento singolo.
        let count = result.numberOfItems
        guard count > 0 else {
            return result.stringValue.map { [$0] } ?? []
        }
        return (1...count).compactMap { result.atIndex($0)?.stringValue }
    }

    /// Elimina (se esiste) la playlist con questo nome dalla cartella dell'app, senza eliminare i brani stessi.
    static func deletePlaylist(named name: String) throws {
        let script = """
        tell application "Music"
        \(folderLookup(create: false))
        \(playlistLookup(name))
            if targetPlaylist is not missing value then delete targetPlaylist
        end tell
        """
        try run(script)
    }

    /// Righe AppleScript che aggiungono i brani a `targetPlaylist`: prima per **ID persistente** (copia il
    /// brano della libreria, preciso), se non riesce ripiega sul file. Un `add` del solo file può essere
    /// ignorato in silenzio da Musica per alcuni brani, ed è così che ne mancavano dalla playlist salvata.
    private static func addLines(for tracks: [LocalTrack]) -> String {
        var s = ""
        for track in tracks {
            let hex = UInt64(track.id).map { String(format: "%016llX", $0) }
            let file = track.url.map { "add (POSIX file \"\(escaped($0.path))\") to targetPlaylist" }
            if let hex {
                s += "\n    try\n        duplicate (first track of library playlist 1 whose persistent ID is \"\(hex)\") to targetPlaylist"
                s += "\n    on error"
                if let file { s += "\n        try\n            \(file)\n        end try" }
                s += "\n    end try"
            } else if let file, let path = track.url?.path {
                // Brano non in libreria (per esempio di una libreria esterna): `add … to playlist` lo porta in libreria ma a volte
                // Musica non lo mette nella playlist. Se il conteggio non sale si ripiega su: aggiunta alla libreria + duplicate.
                s += "\n    set countBeforeAdd to count of tracks of targetPlaylist"
                s += "\n    try\n        \(file)\n    end try"
                s += "\n    if (count of tracks of targetPlaylist) = countBeforeAdd then"
                s += "\n        try\n            set newLibTrack to add (POSIX file \"\(escaped(path))\")"
                s += "\n            duplicate newLibTrack to targetPlaylist\n        end try"
                s += "\n    end if"
            }
        }
        return s
    }

    /// Crea la playlist nella cartella dell'app (creandola se manca) con i brani della libreria: restituisce
    /// quanti ne sono finiti davvero nella playlist, così il chiamante può avvisare se qualcuno manca.
    @discardableResult
    static func createPlaylist(named name: String, tracks: [LocalTrack]) throws -> Int {
        var script = """
        tell application "Music"
        \(folderLookup(create: true))
            set targetPlaylist to make new user playlist at gmmFolder with properties {name:"\(escaped(name))"}
        """
        script += addLines(for: tracks)
        script += "\n    return count of tracks of targetPlaylist\nend tell"
        return Int(try run(script)?.int32Value ?? 0)
    }

    /// Aggiunge brani a una playlist della cartella dell'app (creata se manca); restituisce quanti ne sono stati aggiunti.
    @discardableResult
    static func addTracks(_ tracks: [LocalTrack], toPlaylistNamed name: String) throws -> Int {
        guard !tracks.isEmpty else { return 0 }
        var script = """
        tell application "Music"
        \(folderLookup(create: true))
        \(playlistLookup(name))
            if targetPlaylist is missing value then
                set targetPlaylist to make new user playlist at gmmFolder with properties {name:"\(escaped(name))"}
            end if
            set countBefore to count of tracks of targetPlaylist
        """
        script += addLines(for: tracks)
        script += "\n    return (count of tracks of targetPlaylist) - countBefore\nend tell"
        return Int(try run(script)?.int32Value ?? 0)
    }

    // MARK: Aggiunta di file alla libreria

    /// Metadati da impostare su un brano appena aggiunto (solo quelli non vuoti): servono quando nel file mancavano.
    struct NewTrackFields: Sendable {
        var name = "", artist = "", album = "", albumArtist = "", composer = "", genre = ""
        var year = "", trackNumber = "", trackCount = "", discNumber = "", discCount = ""
        var compilation = false
    }

    /// Aggiunge un file alla libreria di Musica (la apre se serve) e imposta i metadati indicati e, se c'è, la copertina (file JPEG). Restituisce l'ID
    /// persistente del nuovo brano (16 cifre esadecimali maiuscole), o nil se Musica non lo ha restituito.
    static func addFileToLibrary(_ url: URL, fields: NewTrackFields, artworkFile: URL? = nil) throws -> String? {
        func text(_ property: String, _ value: String) -> String {
            value.isEmpty ? "" : "\n        try\n            set \(property) of newTrack to \"\(escaped(value))\"\n        end try"
        }
        func number(_ property: String, _ value: String) -> String {
            guard let n = Int(value), n > 0 else { return "" }
            return "\n        try\n            set \(property) of newTrack to \(n)\n        end try"
        }
        var script = """
        tell application "Music"
            set newTrack to add (POSIX file "\(escaped(url.path))")
            if newTrack is missing value then return missing value
        """
        script += text("name", fields.name) + text("artist", fields.artist) + text("album", fields.album)
        script += text("album artist", fields.albumArtist) + text("composer", fields.composer) + text("genre", fields.genre)
        script += number("year", fields.year) + number("track number", fields.trackNumber)
        script += number("track count", fields.trackCount) + number("disc number", fields.discNumber)
        script += number("disc count", fields.discCount)
        if fields.compilation { script += "\n        try\n            set compilation of newTrack to true\n        end try" }
        // Copertina scelta nel pannello: impostata sul brano in Music, che la scrive nel file (MP3/M4A) così
        // viaggia con il brano quando lo si trasferisce.
        if let artworkFile {
            script += "\n        try\n            set artData to (read (POSIX file \"\(escaped(artworkFile.path))\") as JPEG picture)"
            script += "\n            set data of artwork 1 of newTrack to artData\n        end try"
        }
        script += "\n        return persistent ID of newTrack\nend tell"
        return try run(script)?.stringValue
    }

    // MARK: Copertina letta da Musica

    /// Coda dedicata (una chiamata alla volta): la ricerca del brano in una libreria grande può
    /// richiedere un po' e non deve bloccare l'interfaccia.
    private static let artworkQueue = DispatchQueue(label: "AppleMusicScripting.artwork", qos: .utility)

    /// Copertina di un brano così come la vede Musica (comprese quelle nella sua cache locale delle
    /// copertine, che né il framework iTunesLibrary né il file del brano espongono sempre).
    /// `decimalID` è l'ID persistente come numero decimale (quello di `LocalTrack.id`). Se Musica non
    /// è già aperta non fa nulla (restituisce nil), per non avviarla da sola.
    /// Vero se Musica è già aperta.
    static var isMusicRunning: Bool {
        NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.Music" })
    }

    static func artwork(forTrackID decimalID: String) async -> Data? {
        guard isMusicRunning,
              let number = UInt64(decimalID) else { return nil }
        // In AppleScript l'ID persistente è una stringa di 16 cifre esadecimali maiuscole.
        let hex = String(format: "%016llX", number)
        return await withCheckedContinuation { cont in
            artworkQueue.async { cont.resume(returning: artworkSync(hexID: hex)) }
        }
    }

    private static func artworkSync(hexID: String) -> Data? {
        let script = """
        tell application "Music"
            try
                set t to first track of library playlist 1 whose persistent ID is "\(hexID)"
                if (count of artworks of t) > 0 then
                    return raw data of artwork 1 of t
                end if
            end try
            return missing value
        end tell
        """
        guard let descriptor = try? run(script) else { return nil }
        let data = descriptor.data
        // Un descriptor "missing value" ha dati vuoti; i valori sensati sono immagini di migliaia di byte.
        return data.count > 64 ? data : nil
    }

    @discardableResult
    private static func run(_ script: String) throws -> NSAppleEventDescriptor? {
        guard let appleScript = NSAppleScript(source: script) else {
            throw ScriptingError.scriptCreationFailed
        }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? t("error_unknown")
            throw ScriptingError.appleScriptError(message)
        }
        return result
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
