// Music Manager
// Copyright (C) 2026 Riccardo Colaiori
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import SQLite3
import SwiftUI
import CryptoKit
import ImageIO

// 2.4 Internal — Podcast di Apple sul Garmin, fasi 1-5.
// Vedi la scheda «Podcast sul Garmin - scheda di progetto» nel progetto.
//
// - `ApplePodcastsLibrary` legge in sola lettura (su una COPIA del database) gli episodi di Apple Podcasts già scaricati sul Mac.
// - `ID3Writer` scrive i tag ID3v2.3 su una COPIA del file MP3: l'originale nella cache di Apple non si tocca mai.
// - `PodcastModel` / `PodcastPane` sono la scheda Podcast del pannello del dispositivo (un solo elenco: episodi di Apple, spunte, file orfani).

/// Dati di un episodio presi dal database di Apple (anche se il file non è più scaricato) o dalla memoria degli invii.
struct PodcastMeta: Codable, Hashable, Sendable {
    var uuid: String          // maiuscolo, senza estensione: è il nome del file
    var title: String
    var author: String
    var program: String
    var pubDate: Date?
    var season: Int?
    var number: Int?
    var byteSize: Int64

    /// Raggruppamento come lo mostra l'orologio: programma + « S07» se c'è la stagione.
    var albumLabel: String {
        var album = program
        if let s = season { album += String(format: " S%02ld", s) }
        return album
    }

    init(uuid: String, title: String, author: String, program: String, pubDate: Date?, season: Int?, number: Int?, byteSize: Int64) {
        self.uuid = uuid; self.title = title; self.author = author; self.program = program
        self.pubDate = pubDate; self.season = season; self.number = number; self.byteSize = byteSize
    }

    init(episode ep: PodcastEpisode) {
        self.init(uuid: ep.uuid.uppercased(), title: ep.title, author: ep.author, program: ep.program,
                  pubDate: ep.pubDate, season: ep.season, number: ep.number, byteSize: ep.byteSize)
    }
}

/// Memoria degli episodi inviati (`podcast-sent.json` in Application Support): serve a mostrare titolo e programma degli episodi
/// presenti sul dispositivo senza leggere i file via MTP e anche se Apple Podcasts li ha poi cancellati.
enum PodcastSentStore {
    private static let lock = NSLock()
    private static var url: URL { AppFolders.base.appendingPathComponent("podcast-sent.json") }

    nonisolated static func load() -> [String: PodcastMeta] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: PodcastMeta].self, from: data)) ?? [:]
    }

    nonisolated static func remember(_ metas: [PodcastMeta]) {
        guard !metas.isEmpty else { return }
        var all = load()
        for m in metas { all[m.uuid.uppercased()] = m }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: AppFolders.base, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }
}

/// Un episodio scaricato in locale da Apple Podcasts.
struct PodcastEpisode: Identifiable, Hashable, Sendable {
    /// `ZUUID` dell'episodio: è anche il nome del file nella cache di Apple (`<UUID>.mp3`), quindi l'identità stabile dell'episodio.
    let uuid: String
    let title: String
    let author: String
    let program: String
    let pubDate: Date?
    let season: Int?
    let number: Int?
    /// Dimensione dichiarata dal database (0 se assente).
    let byteSize: Int64
    let fileURL: URL
    /// Dimensione reale del file su disco.
    let fileSize: Int64
    /// Modelli di URL della copertina dell'episodio e del programma (`ZARTWORKTEMPLATEURL`): il loro MD5 dà il nome del file nella cache di Apple.
    var episodeArtworkTemplate: String? = nil
    var programArtworkTemplate: String? = nil
    /// Descrizione del programma (testo semplice, senza HTML), per l'intestazione dell'elenco.
    var programDescription: String? = nil
    /// Colori del programma scelti da Apple in base alla copertina (esadecimale senza «#»): sfondo e testo principale.
    var programBackgroundHex: String? = nil
    var programTextHex: String? = nil

    var id: String { uuid }
    var isMP3: Bool { fileURL.pathExtension.lowercased() == "mp3" }
    /// File completo: la dimensione su disco raggiunge quella dichiarata (se il database non la dichiara non si può dire: vale come completo).
    var isComplete: Bool { byteSize <= 0 || fileSize >= byteSize }
}

/// Testi del database di Apple: le descrizioni possono contenere HTML.
enum PodcastText {
    /// Testo semplice su una riga: tag tolti (a capo e paragrafi diventano spazi), entità più comuni decodificate, spazi compattati.
    nonisolated static func plain(_ html: String?) -> String? {
        guard var text = html, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "<br\\s*/?>|</p>|</li>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension PodcastText {
    /// Colore da una stringa esadecimale di 6 cifre (con o senza «#»); nil se non è valida.
    static func color(hex: String?) -> Color? {
        guard let rgb = components(hex: hex) else { return nil }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    static func components(hex: String?) -> (r: Double, g: Double, b: Double)? {
        guard var h = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// Testo scuro o chiaro adatto a uno sfondo (luminosità percepita).
    static func readableText(on background: (r: Double, g: Double, b: Double)) -> Color {
        0.299 * background.r + 0.587 * background.g + 0.114 * background.b > 0.55 ? Color.black : Color.white
    }
}

enum PodcastError: LocalizedError {
    case notFound
    case permission(String)
    case copyFailed(String)
    case unreadable(String)
    case schema(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "Apple Podcasts non ha una libreria su questo Mac."
        case .permission(let s): return "macOS non consente di leggere i dati di Apple Podcasts (\(s))."
        case .copyFailed(let s): return "Copia del database non riuscita (\(s))."
        case .unreadable(let s): return "Database di Apple Podcasts non leggibile (\(s))."
        case .schema(let s): return "Struttura del database di Apple Podcasts non riconosciuta (\(s))."
        }
    }
}

enum ApplePodcastsLibrary {
    nonisolated static var containerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/243LU875E5.groups.com.apple.podcasts", isDirectory: true)
    }
    nonisolated static var databaseURL: URL { containerURL.appendingPathComponent("Documents/MTLibrary.sqlite") }
    /// Cartella dei file scaricati: `<ZUUID>.mp3`.
    nonisolated static var cacheURL: URL { containerURL.appendingPathComponent("Library/Cache", isDirectory: true) }

    private static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "mp4", "aac"]

    /// Tempo (secondi) della copia del database, per il registro.
    struct Scan: Sendable {
        var episodes: [PodcastEpisode]
        var copySeconds: Double
        var querySeconds: Double
        var databaseEpisodes: Int
        /// Dati di TUTTI gli episodi del database (anche non scaricati), per UUID maiuscolo.
        var meta: [String: PodcastMeta] = [:]
        /// Colonna di `ZMTPODCAST` da cui si legge la descrizione del programma (nil se non se ne trova una); `descriptionLike` elenca quelle simili, per il registro.
        var descriptionColumn: String? = nil
        var descriptionLike: [String] = []
        /// Colonne di `ZMTPODCAST` da cui si leggono i colori (vuoto se mancano), per il registro.
        var colorColumns: [String] = []
    }

    /// Episodi con il file presente in locale. Lavora su una copia temporanea del database (e dei file `-wal` / `-shm`), mai sull'originale.
    nonisolated static func scan() throws -> Scan {
        let fm = FileManager.default
        guard fm.fileExists(atPath: containerURL.path) else { throw PodcastError.notFound }

        // 1. File presenti in cache, per UUID (maiuscolo).
        var files: [String: (url: URL, size: Int64)] = [:]
        do {
            let list = try fm.contentsOfDirectory(at: cacheURL, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            for u in list where audioExtensions.contains(u.pathExtension.lowercased()) {
                let size = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                files[u.deletingPathExtension().lastPathComponent.uppercased()] = (u, size)
            }
        } catch {
            throw classify(error, fallback: { PodcastError.unreadable("cartella dei file: \($0)") })
        }

        // 2. Copia temporanea del database.
        let t0 = Date()
        let tmp = fm.temporaryDirectory.appendingPathComponent("MusicManager-podcast-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) } catch { throw PodcastError.copyFailed(error.localizedDescription) }
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("MTLibrary.sqlite")
        do {
            try fm.copyItem(at: databaseURL, to: copy)
            for suffix in ["-wal", "-shm"] {
                let src = URL(fileURLWithPath: databaseURL.path + suffix)
                if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: URL(fileURLWithPath: copy.path + suffix)) }
            }
        } catch {
            throw classify(error, fallback: { PodcastError.copyFailed($0) })
        }
        let copySeconds = Date().timeIntervalSince(t0)

        // 3. Lettura (la copia si apre in lettura/scrittura: con il WAL serve poter creare il file -shm).
        let t1 = Date()
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "apertura"
            sqlite3_close(db)
            throw PodcastError.unreadable(msg)
        }
        defer { sqlite3_close(db) }

        let ec = columns(db, "ZMTEPISODE"), pc = columns(db, "ZMTPODCAST")
        let missingE = ["ZUUID", "ZTITLE", "ZPODCAST"].filter { !ec.contains($0) }
        let missingP = ["Z_PK", "ZTITLE"].filter { !pc.contains($0) }
        guard missingE.isEmpty, missingP.isEmpty else {
            throw PodcastError.schema("mancano: " + (missingE.map { "episodi." + $0 } + missingP.map { "programmi." + $0 }).joined(separator: ", "))
        }
        func e(_ n: String) -> String { ec.contains(n) ? "e.\(n)" : "NULL" }
        let author: String
        switch (ec.contains("ZAUTHOR"), pc.contains("ZAUTHOR")) {
        case (true, true): author = "COALESCE(NULLIF(e.ZAUTHOR, ''), p.ZAUTHOR)"
        case (true, false): author = "e.ZAUTHOR"
        case (false, true): author = "p.ZAUTHOR"
        default: author = "NULL"
        }
        let epArt = ec.contains("ZARTWORKTEMPLATEURL") ? "e.ZARTWORKTEMPLATEURL" : "NULL"
        let pArt = pc.contains("ZARTWORKTEMPLATEURL") ? "p.ZARTWORKTEMPLATEURL" : "NULL"
        // Descrizione del programma: la prima colonna nota che esiste (il nome può cambiare con le versioni di macOS).
        let descColumn = ["ZITEMDESCRIPTION", "ZSUMMARY", "ZDESCRIPTION", "ZPODCASTDESCRIPTION"].first { pc.contains($0) }
        let pBg = pc.contains("ZARTWORKPRIMARYCOLOR") ? "p.ZARTWORKPRIMARYCOLOR" : "NULL"
        let pText = pc.contains("ZARTWORKTEXTPRIMARYCOLOR") ? "p.ZARTWORKTEXTPRIMARYCOLOR" : "NULL"
        let colorColumns = ["ZARTWORKPRIMARYCOLOR", "ZARTWORKTEXTPRIMARYCOLOR"].filter { pc.contains($0) }
        let pDesc = descColumn.map { "p.\($0)" } ?? "NULL"
        let descLike = pc.filter { $0.contains("DESC") || $0.contains("SUMMARY") }.sorted()
        let sql = "SELECT e.ZUUID, e.ZTITLE, \(author), p.ZTITLE, \(e("ZPUBDATE")), \(e("ZSEASONNUMBER")), \(e("ZEPISODENUMBER")), \(e("ZBYTESIZE")), \(epArt), \(pArt), \(pDesc), \(pBg), \(pText) "
            + "FROM ZMTEPISODE e LEFT JOIN ZMTPODCAST p ON e.ZPODCAST = p.Z_PK"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(stmt)
            throw PodcastError.schema(msg)
        }
        defer { sqlite3_finalize(stmt) }

        func text(_ col: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: c)
        }
        func int(_ col: Int32) -> Int64? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, col)
        }

        var episodes: [PodcastEpisode] = []
        var allMeta: [String: PodcastMeta] = [:]
        var total = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            total += 1
            guard let uuid = text(0) else { continue }
            let pub: Date? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
            let season = int(5).flatMap { $0 > 0 ? Int($0) : nil }
            let number = int(6).flatMap { $0 > 0 ? Int($0) : nil }
            let meta = PodcastMeta(uuid: uuid.uppercased(), title: text(1) ?? "", author: text(2) ?? "", program: text(3) ?? "",
                                   pubDate: pub, season: season, number: number, byteSize: int(7) ?? 0)
            allMeta[meta.uuid] = meta
            guard let file = files[uuid.uppercased()] else { continue }
            episodes.append(PodcastEpisode(
                uuid: uuid,
                title: meta.title,
                author: meta.author,
                program: meta.program,
                pubDate: pub,
                season: season,
                number: number,
                byteSize: meta.byteSize,
                fileURL: file.url,
                fileSize: file.size,
                episodeArtworkTemplate: text(8),
                programArtworkTemplate: text(9),
                programDescription: PodcastText.plain(text(10)),
                programBackgroundHex: text(11),
                programTextHex: text(12)))
        }
        return Scan(episodes: episodes, copySeconds: copySeconds,
                    querySeconds: Date().timeIntervalSince(t1), databaseEpisodes: total, meta: allMeta,
                    descriptionColumn: descColumn, descriptionLike: descLike, colorColumns: colorColumns)
    }

    private nonisolated static func columns(_ db: OpaquePointer?, _ table: String) -> Set<String> {
        var stmt: OpaquePointer?
        var out = Set<String>()
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) { out.insert(String(cString: c).uppercased()) }
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Distingue il rifiuto di macOS (permessi) da un guasto qualunque.
    private nonisolated static func classify(_ error: Error, fallback: (String) -> PodcastError) -> PodcastError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError {
            return .permission(ns.localizedDescription)
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) { return .permission(ns.localizedDescription) }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain,
           under.code == Int(EPERM) || under.code == Int(EACCES) { return .permission(ns.localizedDescription) }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError { return .notFound }
        return fallback(ns.localizedDescription)
    }
}

/// Tag da scrivere su una copia (mappatura decisa l'11/11/2026, vedi la scheda del progetto).
struct PodcastTags: Sendable {
    var title: String
    var artist: String
    var album: String
    var genre: String = "Podcast"
    var track: Int?

    /// `album` = programma, più « S07» (stagione a due cifre) se l'episodio ha una stagione; `track` = numero di puntata.
    static func make(for ep: PodcastEpisode) -> PodcastTags {
        var album = ep.program
        if let s = ep.season { album += String(format: " S%02ld", s) }
        return PodcastTags(title: ep.title, artist: ep.author, album: album, track: ep.number)
    }
}

/// Scrive un tag ID3v2.3 in testa a una COPIA del file MP3 (i dati audio restano identici byte per byte). Un tag ID3v2 già presente
/// (i file di Apple hanno un tag vuoto da 4 KB) viene sostituito, non unito: copertina e altri frame del file di partenza non si portano dietro.
enum ID3Writer {
    enum Failure: LocalizedError {
        case readFailed(String)
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .readFailed(let s): return "Lettura del file non riuscita (\(s))."
            case .writeFailed(let s): return "Scrittura del file non riuscita (\(s))."
            }
        }
    }

    /// Esito sulla copertina: già incorporata nel file di Apple (conservata), aggiunta dalla cache di Apple, oppure assente.
    enum CoverResult: String, Sendable { case kept = "incorporata", added = "aggiunta dalla cache", none = "nessuna" }

    /// `cover` si chiama solo se il file non ha già una copertina incorporata: JPEG da aggiungere (o nil).
    @discardableResult
    nonisolated static func writeCopy(of source: URL, to dest: URL, tags: PodcastTags, cover: (@Sendable () -> Data?)? = nil) throws -> CoverResult {
        let fm = FileManager.default
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) } catch { throw Failure.readFailed(error.localizedDescription) }
        defer { try? input.close() }

        // Dove iniziano i dati audio: dopo l'eventuale ID3v2 già presente (10 byte + dimensione synchsafe, + 10 se c'è il footer).
        var audioStart: UInt64 = 0
        // Copertina già incorporata nel file di Apple (frame APIC): si conserva, riscritta per ID3v2.3.
        var artwork = Data()
        if let head = try? input.read(upToCount: 10), head.count == 10, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 {
            let size = (Int(head[6] & 0x7F) << 21) | (Int(head[7] & 0x7F) << 14) | (Int(head[8] & 0x7F) << 7) | Int(head[9] & 0x7F)
            let footer = (head[5] & 0x10) != 0 ? 10 : 0
            audioStart = UInt64(10 + size + footer)
            if size > 0, size < 64 << 20, let tag = try? input.read(upToCount: size), tag.count == size {
                artwork = artworkFrames(from: [UInt8](tag), version: head[3], flags: head[5])
            }
        }

        var frames = Data()
        frames.append(textFrame("TIT2", tags.title))
        frames.append(textFrame("TPE1", tags.artist))
        frames.append(textFrame("TALB", tags.album))
        frames.append(textFrame("TCON", tags.genre))
        if let n = tags.track { frames.append(textFrame("TRCK", String(n))) }
        var result: CoverResult = artwork.isEmpty ? .none : .kept
        if artwork.isEmpty, let jpeg = cover?(), !jpeg.isEmpty {
            frames.append(coverFrame(jpeg))
            result = .added
        } else {
            frames.append(artwork)
        }

        var header = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
        let n = frames.count
        header.append(contentsOf: [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])

        try? fm.removeItem(at: dest)
        guard fm.createFile(atPath: dest.path, contents: nil) else { throw Failure.writeFailed("impossibile creare il file") }
        let output: FileHandle
        do { output = try FileHandle(forWritingTo: dest) } catch { throw Failure.writeFailed(error.localizedDescription) }
        defer { try? output.close() }
        do {
            try output.write(contentsOf: header)
            try output.write(contentsOf: frames)
            try input.seek(toOffset: audioStart)
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        } catch {
            try? fm.removeItem(at: dest)
            throw Failure.writeFailed(error.localizedDescription)
        }
        return result
    }

    /// Frame APIC ID3v2.3 con una copertina JPEG (tipo «copertina anteriore», descrizione vuota).
    private nonisolated static func coverFrame(_ jpeg: Data) -> Data {
        var body = Data([0x00])
        body.append(Data("image/jpeg".utf8)); body.append(0x00)
        body.append(0x03)
        body.append(0x00)
        body.append(jpeg)
        var frame = Data("APIC".utf8)
        let n = body.count
        frame.append(contentsOf: [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(body)
        return frame
    }

    /// Frame APIC (copertina) di un ID3v2.3 o v2.4 esistente, riscritti come frame ID3v2.3. Si saltano quelli compressi o cifrati e
    /// i tag ID3v2.2; la descrizione in UTF-8 (solo v2.4) diventa ISO-8859-1. Senza copertina restituisce dati vuoti.
    private nonisolated static func artworkFrames(from tag: [UInt8], version: UInt8, flags: UInt8) -> Data {
        guard version == 3 || version == 4 else { return Data() }
        var b = tag
        if flags & 0x80 != 0 { b = unsynchronised(b) }
        func be32(_ i: Int) -> Int { (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3]) }
        func ss32(_ i: Int) -> Int { (Int(b[i] & 0x7F) << 21) | (Int(b[i + 1] & 0x7F) << 14) | (Int(b[i + 2] & 0x7F) << 7) | Int(b[i + 3] & 0x7F) }
        var pos = 0
        if flags & 0x40 != 0, b.count >= 4 { pos = version == 3 ? 4 + be32(0) : ss32(0) }   // intestazione estesa
        var out = Data()
        while pos >= 0, pos + 10 <= b.count, b[pos] != 0 {
            let id = String(decoding: b[pos..<pos + 4], as: UTF8.self)
            let size = version == 3 ? be32(pos + 4) : ss32(pos + 4)
            let fl = b[pos + 9]
            let start = pos + 10
            guard size >= 0, start + size <= b.count else { break }
            pos = start + size
            guard id == "APIC" else { continue }
            var body = Array(b[start..<start + size])
            if version == 3 {
                if fl & 0xC0 != 0 { continue }                                 // compresso o cifrato
                if fl & 0x20 != 0, !body.isEmpty { body.removeFirst() }        // byte del gruppo
            } else {
                if fl & 0x0C != 0 { continue }                                 // compresso o cifrato
                if fl & 0x40 != 0, !body.isEmpty { body.removeFirst() }        // byte del gruppo
                if fl & 0x01 != 0, body.count > 4 { body.removeFirst(4) }      // lunghezza dei dati
                if fl & 0x02 != 0 { body = unsynchronised(body) }
            }
            if body.first == 3 {
                guard let converted = latin1Artwork(body) else { continue }
                body = converted
            }
            guard body.count > 4 else { continue }
            var frame = Data("APIC".utf8)
            let n = body.count
            frame.append(contentsOf: [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
            frame.append(contentsOf: [0x00, 0x00])
            frame.append(contentsOf: body)
            out.append(frame)
        }
        return out
    }

    /// Toglie la «unsynchronisation» (0xFF 0x00 → 0xFF).
    private nonisolated static func unsynchronised(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            out.append(b[i])
            if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0 { i += 1 }
            i += 1
        }
        return out
    }

    /// APIC con codifica UTF-8 (v2.4, byte 3) → ISO-8859-1 (byte 0), l'unica che l'ID3v2.3 conosce oltre a UTF-16.
    private nonisolated static func latin1Artwork(_ body: [UInt8]) -> [UInt8]? {
        guard body.count > 4, let mimeEnd = body[1...].firstIndex(of: 0), mimeEnd + 2 < body.count else { return nil }
        let typeIndex = mimeEnd + 1
        guard let descEnd = body[(typeIndex + 1)...].firstIndex(of: 0) else { return nil }
        let desc = String(decoding: body[(typeIndex + 1)..<descEnd], as: UTF8.self)
        var out: [UInt8] = [0]
        out += body[1...mimeEnd]
        out.append(body[typeIndex])
        if let latin = desc.data(using: .isoLatin1, allowLossyConversion: true) { out += [UInt8](latin) }
        out.append(0)
        out += body[(descEnd + 1)...]
        return out
    }

    /// Frame di testo ID3v2.3: ISO-8859-1 se il testo ci sta, altrimenti UTF-16 con BOM.
    private nonisolated static func textFrame(_ id: String, _ value: String) -> Data {
        var body = Data()
        if let latin = value.data(using: .isoLatin1) {
            body.append(0x00)
            body.append(latin)
        } else {
            body.append(0x01)
            body.append(contentsOf: [0xFF, 0xFE])
            body.append(value.data(using: .utf16LittleEndian) ?? Data())
        }
        var frame = Data(id.utf8)
        let n = body.count
        frame.append(contentsOf: [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(body)
        return frame
    }
}

// MARK: - Copertine dalla cache di Apple

/// Copertine già scaricate da Apple Podcasts (`Library/Cache/Assets/Artwork/<Show|Episode>-<MD5 dell'URL modello>-<L>x<A>-bb.heic`).
/// Il nome è l'MD5 del `ZARTWORKTEMPLATEURL` (verificato l'11/11/2026 su 5 programmi). Non si scarica nulla: se il file non c'è, nessuna copertina.
enum PodcastArtwork {
    nonisolated static var folder: URL { ApplePodcastsLibrary.containerURL.appendingPathComponent("Library/Cache/Assets/Artwork", isDirectory: true) }
    /// Dimensioni accettate, dalla migliore; mai le versioni `-blurred` né quelle piccole (80x80).
    private static let sizes = ["600x600", "400x400", "236x236"]

    nonisolated static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// File HEIC da usare: prima quello dell'episodio, poi quello del programma.
    nonisolated static func fileURL(for ep: PodcastEpisode) -> URL? {
        let fm = FileManager.default
        for (prefix, template) in [("Episode", ep.episodeArtworkTemplate), ("Show", ep.programArtworkTemplate)] {
            guard let template, !template.isEmpty else { continue }
            let hash = md5(template)
            for size in sizes {
                let url = folder.appendingPathComponent("\(prefix)-\(hash)-\(size)-bb.heic")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Copertina per l'intestazione di un programma: prima quella del programma (`Show-`), poi quella dell'episodio.
    nonisolated static func programFileURL(for ep: PodcastEpisode) -> URL? {
        let fm = FileManager.default
        for (prefix, template) in [("Show", ep.programArtworkTemplate), ("Episode", ep.episodeArtworkTemplate)] {
            guard let template, !template.isEmpty else { continue }
            let hash = md5(template)
            for size in sizes {
                let url = folder.appendingPathComponent("\(prefix)-\(hash)-\(size)-bb.heic")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// JPEG (qualità ~85 %) della copertina trovata, convertita con ImageIO; nil se non c'è o non si legge.
    nonisolated static func jpegData(for ep: PodcastEpisode) -> Data? {
        guard let url = fileURL(for: ep),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

// MARK: - Interfaccia

/// Scheda extra della barra delle categorie di `CatalogBrowser` (dopo un divisore, come la Custom Playlist): quando è scelta,
/// il contenuto del pannello è `extraContentView` al posto dell'elenco dei brani. Usata dai Podcast nel pannello del dispositivo.
struct CatalogExtraTab {
    var title: String
    var iconName: String
    var isSelected: Bool
    var select: () -> Void
    var deselect: () -> Void
}

struct PodcastGroup: Identifiable {
    let title: String
    let episodes: [PodcastEpisode]
    /// Descrizione del programma e file della sua copertina (HEIC nella cache di Apple), per l'intestazione.
    var description: String? = nil
    var cover: URL? = nil
    /// Sfondo e colore del testo dell'intestazione (colori scelti da Apple per il programma); nil se il database non li ha.
    var background: Color? = nil
    var textColor: Color? = nil
    var id: String { title }
}

/// File presente in `Podcasts/` sul dispositivo (anche in sottocartelle).
struct DevicePodcastFile: Identifiable, Hashable, Sendable {
    let id: UInt32
    let name: String
    let size: UInt64
    let folder: String
}

/// File sul dispositivo che non corrisponde a nessun episodio scaricato in Apple Podcasts («orfano»).
struct OrphanPodcastRow: Identifiable, Hashable {
    let file: DevicePodcastFile
    let title: String
    let detail: String
    var id: String { "dev-\(file.id)" }
}

/// Stato della scheda Podcast: episodi di Apple Podcasts scaricati in locale, contenuto di `Podcasts/` sul dispositivo, selezione.
/// Un solo elenco: gli episodi già sul dispositivo hanno la spunta verde; i file sul dispositivo senza episodio locale stanno in fondo («orfani»).
@MainActor
final class PodcastModel: ObservableObject {
    enum LoadState: Equatable { case idle, loading, ready, noLibrary, permission, failed(String) }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var episodes: [PodcastEpisode] = []
    /// Identificativi selezionati: `PodcastEpisode.id` per gli episodi, `OrphanPodcastRow.id` per i file orfani.
    @Published var selection = Set<String>()

    // Dispositivo: ultimo stato letto (si conserva se il dispositivo viene scollegato).
    @Published private(set) var deviceFiles: [DevicePodcastFile] = []
    @Published private(set) var deviceMeta: [String: PodcastMeta] = [:]
    @Published private(set) var deviceLoaded = false
    @Published private(set) var deviceLoading = false
    /// File da rimuovere in attesa di conferma (il pannello mostra l'avviso quando non è vuoto).
    @Published var pendingDelete: [DevicePodcastFile] = []

    private var deviceFilesByKey: [String: [DevicePodcastFile]] {
        Dictionary(grouping: deviceFiles) { MTPService.nameKey($0.name) }
    }

    func isOnDevice(_ ep: PodcastEpisode) -> Bool {
        deviceFilesByKey[MTPService.nameKey(ep.fileURL.lastPathComponent)] != nil
    }

    /// File sul dispositivo senza un episodio scaricato in Apple Podcasts, con titolo ricavato dalla memoria degli invii o dal database di Apple.
    var orphans: [OrphanPodcastRow] {
        let known = Set(episodes.map { MTPService.nameKey($0.fileURL.lastPathComponent) })
        var rows: [OrphanPodcastRow] = []
        for f in deviceFiles where !known.contains(MTPService.nameKey(f.name)) {
            let m = deviceMeta[Self.uuid(ofFile: f.name)]
            var parts: [String] = []
            if let m { parts.append(m.albumLabel) }
            if let n = m?.number { parts.append(t("podcast_episode_n", n)) }
            if let a = m?.author, !a.isEmpty { parts.append(a) }
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))
            if m == nil { parts.append(f.name) }
            if !f.folder.isEmpty { parts.append(f.folder) }
            rows.append(OrphanPodcastRow(file: f, title: m?.title ?? f.name, detail: parts.joined(separator: " · ")))
        }
        return rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Programmi (con la stagione, come li mostra l'orologio) in ordine alfabetico; dentro, gli episodi per numero di puntata decrescente.
    var groups: [PodcastGroup] {
        let grouped = Dictionary(grouping: episodes) { PodcastTags.make(for: $0).album }
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            let eps = (grouped[key] ?? []).sorted { a, b in
                if (a.number ?? 0) != (b.number ?? 0) { return (a.number ?? 0) > (b.number ?? 0) }
                return (a.pubDate ?? .distantPast) > (b.pubDate ?? .distantPast)
            }
            let bgHex = eps.lazy.compactMap { $0.programBackgroundHex }.first
            let bg = PodcastText.components(hex: bgHex)
            let text = PodcastText.color(hex: eps.lazy.compactMap { $0.programTextHex }.first) ?? bg.map { PodcastText.readableText(on: $0) }
            return PodcastGroup(title: key, episodes: eps,
                                description: eps.lazy.compactMap { $0.programDescription }.first,
                                cover: eps.first.flatMap { PodcastArtwork.programFileURL(for: $0) },
                                background: PodcastText.color(hex: bgHex), textColor: text)
        }
    }

    /// Episodi selezionati, nell'ordine in cui compaiono nell'elenco.
    var selectedEpisodes: [PodcastEpisode] {
        groups.flatMap { $0.episodes }.filter { selection.contains($0.id) }
    }

    /// Episodi selezionati che si possono inviare e non sono ancora sul dispositivo.
    var episodesToSend: [PodcastEpisode] {
        selectedEpisodes.filter { $0.isMP3 && $0.isComplete && !isOnDevice($0) }
    }

    /// Numero e dimensione di tutto ciò che è selezionato (episodi e file orfani).
    var selectionSummary: (count: Int, bytes: Int64) {
        let orphanRows = orphans.filter { selection.contains($0.id) }
        let bytes = selectedEpisodes.reduce(Int64(0)) { $0 + $1.fileSize } + orphanRows.reduce(Int64(0)) { $0 + Int64($1.file.size) }
        return (selectedEpisodes.count + orphanRows.count, bytes)
    }

    /// File sul dispositivo corrispondenti agli identificativi indicati (episodi già inviati e file orfani).
    func filesToRemove(for ids: Set<String>) -> [DevicePodcastFile] {
        var files: [DevicePodcastFile] = []
        let byKey = deviceFilesByKey
        for ep in episodes where ids.contains(ep.id) {
            files += byKey[MTPService.nameKey(ep.fileURL.lastPathComponent)] ?? []
        }
        for row in orphans where ids.contains(row.id) { files.append(row.file) }
        return files
    }

    /// Alla scelta della scheda: rilegge Apple Podcasts (la lettura costa pochi centesimi di secondo) e il dispositivo.
    func opened(vm: AppViewModel) {
        reload()
        reloadDevice(vm)
    }

    private nonisolated static func uuid(ofFile name: String) -> String {
        URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.uppercased()
    }

    private nonisolated static func isAudio(_ name: String) -> Bool {
        ["mp3", "m4a", "m4b", "mp4", "aac"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    /// Rilegge `Podcasts/` sul dispositivo. Titolo e programma dei file orfani: prima la memoria degli invii, poi il database di Apple (se si può leggere).
    /// Senza dispositivo collegato si tiene l'ultimo stato letto.
    func reloadDevice(_ vm: AppViewModel) {
        guard !deviceLoading, vm.device != nil else { return }
        deviceLoading = true
        Task { [weak self] in
            let all = await vm.devicePodcastFiles()
            vm.podcastsFolderSize = all.reduce(UInt64(0)) { $0 + $1.size }
            let files = all.filter { Self.isAudio($0.name) }
            var meta = PodcastSentStore.load()
            if files.contains(where: { meta[Self.uuid(ofFile: $0.name)] == nil }) {
                let fromDatabase = await Task.detached(priority: .utility) { (try? ApplePodcastsLibrary.scan())?.meta ?? [:] }.value
                for (key, value) in fromDatabase where meta[key] == nil { meta[key] = value }
            }
            self?.applyDevice(files, meta)
        }
    }

    private func applyDevice(_ files: [DevicePodcastFile], _ meta: [String: PodcastMeta]) {
        deviceFiles = files
        deviceMeta = meta
        deviceLoaded = true
        deviceLoading = false
        pruneSelection()
        AppLog.event("podcast", "scheda Podcast: \(files.count) file sul dispositivo, \(orphans.count) senza episodio locale")
    }

    private func pruneSelection() {
        let valid = Set(episodes.map { $0.id }).union(orphans.map { $0.id })
        selection = selection.intersection(valid)
    }

    func reload() {
        guard state != .loading else { return }
        state = .loading
        Task.detached(priority: .userInitiated) { [weak self] in
            var scan: ApplePodcastsLibrary.Scan?
            var failure: PodcastError?
            do { scan = try ApplePodcastsLibrary.scan() }
            catch let e as PodcastError { failure = e }
            catch { failure = .unreadable(error.localizedDescription) }
            let result = scan, error = failure
            await self?.apply(result, error)   // la classe è @MainActor: la chiamata torna da sola sul thread principale (senza catturare `self` in una chiusura concorrente)
        }
    }

    private func apply(_ scan: ApplePodcastsLibrary.Scan?, _ failure: PodcastError?) {
        if let scan {
            episodes = scan.episodes
            state = .ready
            pruneSelection()
            if let column = scan.descriptionColumn {
                AppLog.event("podcast", "descrizione dei programmi: colonna \(column)")
            } else {
                AppLog.event("podcast", "descrizione dei programmi: nessuna colonna nota (simili: \(scan.descriptionLike.joined(separator: ", ")))")
            }
            AppLog.event("podcast", "colori dei programmi: \(scan.colorColumns.isEmpty ? "colonne non trovate" : scan.colorColumns.joined(separator: ", "))")
            AppLog.event("podcast", "scheda Podcast: \(scan.episodes.count) episodi in locale (lettura \(String(format: "%.2f", scan.copySeconds + scan.querySeconds)) s)")
            return
        }
        episodes = []
        selection = selection.filter { $0.hasPrefix("dev-") }
        switch failure {
        case .some(.notFound): state = .noLibrary
        case .some(.permission): state = .permission
        case .some(let e): state = .failed(e.localizedDescription)
        case .none: state = .failed("?")
        }
        AppLog.event("podcast", "scheda Podcast: \(failure?.localizedDescription ?? "errore")")
    }
}

/// Contenuto della scheda Podcast (pannello del dispositivo): un solo elenco con gli episodi di Apple Podcasts già scaricati (spunta verde se
/// sono già sul dispositivo) e, in fondo, i file presenti solo sul dispositivo. Tasto destro: «Rimuovi dal dispositivo». L'invio sta nella
/// barra in basso (`ContentView.podcastBottomBar`).
struct PodcastPane: View {
    @ObservedObject var model: PodcastModel
    @ObservedObject var vm: AppViewModel
    /// Dimensione del testo degli elenchi (Impostazioni ▸ Aspetto): la scheda Podcast la segue come gli altri elenchi.
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.glassInsets) private var insets

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            bodyContent
        }
        .padding(.top, insets.top)
        .padding(.bottom, insets.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Intestazione

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("podcast_info"))
                    .font(.system(size: settings.listTextSize.secondaryPoints + 1.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if vm.device == nil && model.deviceLoaded {
                    Text(t("podcast_device_stale")).font(.system(size: settings.listTextSize.secondaryPoints + 1.5)).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Button {
                model.reload()
                model.reloadDevice(vm)
            } label: {
                Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t("podcast_reload_tooltip"))
            .disabled(model.state == .loading || model.deviceLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Contenuto

    @ViewBuilder
    private var bodyContent: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noLibrary:
            message(t("podcast_no_library"))
        case .permission:
            permissionBox
        case .failed(let text):
            VStack(spacing: 10) {
                Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(t("podcast_retry")) { model.reload() }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if model.episodes.isEmpty && model.orphans.isEmpty { message(t("podcast_empty")) } else { episodeList }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// macOS non chiede il permesso da solo: la richiesta la scriviamo noi, con il pulsante che apre la pagina giusta delle Impostazioni.
    private var permissionBox: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(t("podcast_permission_title")).font(.headline)
            Text(t("podcast_permission_body"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(t("podcast_open_settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(t("podcast_retry")) { model.reload() }
            }
        }
        .padding(24)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var episodeList: some View {
        List(selection: $model.selection) {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.episodes) { ep in
                        row(ep)
                            // Episodi allineati al titolo del programma (dopo la copertina), come i brani sotto un album.
                            .padding(.leading, Self.headerInset + Self.coverSize + Self.coverGap)
                            // Selezione nel colore scelto in Impostazioni, come le altre liste.
                            .listRowBackground(model.selection.contains(ep.id) ? rowHighlight(settings.highlightColor) : nil)
                    }
                } header: {
                    groupHeader(group)
                }
            }
            let orphans = model.orphans
            if !orphans.isEmpty {
                Section {
                    ForEach(orphans) { orphan in
                        orphanRow(orphan)
                            .listRowBackground(model.selection.contains(orphan.id) ? rowHighlight(settings.highlightColor) : nil)
                    }
                } header: {
                    Text(t("podcast_orphans_header")).font(.system(size: settings.listTextSize.points + 1, weight: .semibold)).foregroundStyle(.primary)
                }
            }
        }
        .listStyle(.inset)
        // Sfondo trasparente come le altre liste (lascia vedere il vetro sotto); prima era il fondo opaco di `List`, nero in tema scuro.
        .scrollContentBackground(.hidden)
        .background(HideNativeSelection(reapplyOnUpdate: true))   // la selezione si vede solo col colore scelto, non col blu di sistema
        .contextMenu(forSelectionType: String.self) { ids in
            let files = model.filesToRemove(for: ids)
            if !files.isEmpty {
                Button(t("podcast_remove_menu"), systemImage: "trash", role: .destructive) { model.pendingDelete = files }
                    .disabled(vm.isBusy || vm.device == nil || vm.isDeviceReadOnly)
            }
        }
        .alert(t("podcast_delete_title"),
               isPresented: Binding(get: { !model.pendingDelete.isEmpty }, set: { if !$0 { model.pendingDelete = [] } })) {
            Button(t("button_delete"), role: .destructive) {
                let files = model.pendingDelete
                Task {
                    await vm.deletePodcastFiles(files)
                    model.selection = []
                    model.reloadDevice(vm)
                }
            }
            Button(t("button_cancel"), role: .cancel) {}
        } message: {
            Text(t("podcast_delete_message", model.pendingDelete.count))
        }
    }

    private static let coverSize: CGFloat = 32
    private static let coverGap: CGFloat = 8
    /// Margine interno della fascia colorata dell'intestazione (gli episodi lo sommano al rientro per restare allineati al titolo).
    private static let headerInset: CGFloat = 8

    /// Intestazione di un programma, come quella di un album: copertina, nome del programma e, sotto, la descrizione.
    private func groupHeader(_ group: PodcastGroup) -> some View {
        HStack(spacing: Self.coverGap) {
            PodcastCoverView(url: group.cover, size: Self.coverSize)
            VStack(alignment: .leading, spacing: settings.listTextSize.lineSpacing) {
                Text(group.title)
                    .font(.system(size: settings.listTextSize.points + 1, weight: .semibold))
                    .foregroundStyle(group.textColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                    .lineLimit(1)
                if let description = group.description {
                    Text(description)
                        .font(.system(size: settings.listTextSize.secondaryPoints))
                        .foregroundStyle(group.textColor.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.headerInset)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        // Fascia nel colore che Apple Podcasts assegna al programma (dalla copertina), come nella sua app.
        .background(RoundedRectangle(cornerRadius: 8).fill(group.background ?? Color.clear))
    }

    private func row(_ ep: PodcastEpisode) -> some View {
        let onDevice = model.isOnDevice(ep)
        let sendable = ep.isMP3 && ep.isComplete
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ep.title).font(.system(size: settings.listTextSize.points)).lineLimit(1)
                Text(detail(ep, sendable: sendable)).font(.system(size: settings.listTextSize.secondaryPoints)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if onDevice {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(t("podcast_on_device_tooltip"))
            } else if !sendable {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(t("podcast_not_sendable"))
            }
        }
        .opacity(sendable || onDevice ? 1 : 0.55)
    }

    private func orphanRow(_ orphan: OrphanPodcastRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(orphan.title).font(.system(size: settings.listTextSize.points)).lineLimit(1)
                Text(orphan.detail).font(.system(size: settings.listTextSize.secondaryPoints)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "externaldrive").foregroundStyle(.secondary).help(t("podcast_orphan_tooltip"))
        }
    }

    private func detail(_ ep: PodcastEpisode, sendable: Bool) -> String {
        var parts: [String] = []
        if let n = ep.number { parts.append(t("podcast_episode_n", n)) }
        if !ep.author.isEmpty { parts.append(ep.author) }
        if let d = ep.pubDate { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        parts.append(ByteCountFormatter.string(fromByteCount: ep.fileSize, countStyle: .file))
        if !sendable { parts.append(t("podcast_not_sendable")) }
        return parts.joined(separator: " · ")
    }
}


/// Copertina quadrata di un programma (file HEIC della cache di Apple), con angoli come le copertine degli album; segnaposto se manca.
private struct PodcastCoverView: View {
    let url: URL?
    let size: CGFloat
    @State private var image: NSImage?

    private static let memory = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "mic.fill").font(.system(size: size * 0.45)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(image == nil ? Color.secondary.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        .task(id: url?.path ?? "") {
            guard let url else { image = nil; return }
            let key = url.path as NSString
            if let known = Self.memory.object(forKey: key) { image = known; return }
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            if let data, let loaded = NSImage(data: data) {
                Self.memory.setObject(loaded, forKey: key)
                image = loaded
            }
        }
    }
}
