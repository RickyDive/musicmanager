import Foundation

/// Inserisce (o sostituisce) la copertina di un file M4A/AAC modificando DIRETTAMENTE gli atom del
/// contenitore MP4, senza ricodificarlo né riscriverlo con AVFoundation: i dati audio (`mdat`) e
/// tutti gli altri metadati restano identici byte per byte, cambia solo l'atom `covr` dentro
/// `moov/udta/meta/ilst`. Il file risultante è il più possibile simile all'originale — quello che
/// il Garmin già accetta — invece di un file "rifatto" da un esportatore (che cambia marca
/// `ftyp`, riordina gli atom e scarta i metadati non "common").
///
/// Se il file ha una struttura che non si sa modificare in sicurezza (frammentato, `meta` non
/// iTunes...) restituisce nil e il chiamante ripiega su `AVAssetExportSession`.
enum MP4ArtworkWriter {
    private struct Box {
        let type: String
        let start: Int
        let headerSize: Int
        let end: Int
        var payloadStart: Int { start + headerSize }
    }

    // MARK: - Lettura/scrittura di interi big-endian

    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
    }

    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(b[i + k]) }
        return v
    }

    private static func put32(_ b: inout [UInt8], _ i: Int, _ v: Int) {
        b[i] = UInt8((v >> 24) & 0xFF)
        b[i + 1] = UInt8((v >> 16) & 0xFF)
        b[i + 2] = UInt8((v >> 8) & 0xFF)
        b[i + 3] = UInt8(v & 0xFF)
    }

    private static func put64(_ b: inout [UInt8], _ i: Int, _ v: UInt64) {
        for k in 0..<8 { b[i + k] = UInt8((v >> UInt64(8 * (7 - k))) & 0xFF) }
    }

    // MARK: - Atom

    /// Elenco degli atom contenuti in `b[from..<to]`; nil se la struttura non è coerente.
    private static func parse(_ b: [UInt8], _ from: Int, _ to: Int) -> [Box]? {
        var result: [Box] = []
        var pos = from
        while pos < to {
            guard pos + 8 <= to else { return nil }
            var size = u32(b, pos)
            let type = String(bytes: b[(pos + 4)..<(pos + 8)], encoding: .isoLatin1) ?? ""
            var header = 8
            if size == 1 {
                guard pos + 16 <= to else { return nil }
                let big = u64(b, pos + 8)
                guard big <= UInt64(Int.max) else { return nil }
                size = Int(big)
                header = 16
            } else if size == 0 {
                size = to - pos
            }
            guard size >= header, pos + size <= to else { return nil }
            result.append(Box(type: type, start: pos, headerSize: header, end: pos + size))
            pos += size
        }
        return result
    }

    private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        put32(&out, 0, 8 + payload.count)
        out += Array(type.utf8)
        out += payload
        return out
    }

    /// Atom `covr` con un solo atom `data` (tipo 13 = JPEG, 14 = PNG).
    private static func covrBox(_ image: [UInt8]) -> [UInt8] {
        let isPNG = image.count > 4 && image[0] == 0x89 && image[1] == 0x50
        let typeIndicator: UInt8 = isPNG ? 14 : 13
        let dataPayload: [UInt8] = [0, 0, 0, typeIndicator, 0, 0, 0, 0] + image
        return box("covr", box("data", dataPayload))
    }

    /// `meta` iTunes: versione/flag, `hdlr` di tipo "mdir" e l'`ilst` dato.
    private static func metaBox(ilst: [UInt8]) -> [UInt8] {
        let hdlrPayload: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
            + Array("mdir".utf8) + Array("appl".utf8)
            + [UInt8](repeating: 0, count: 8) + [0]
        return box("meta", [0, 0, 0, 0] + box("hdlr", hdlrPayload) + ilst)
    }

    // MARK: - Ricostruzione di moov/udta/meta/ilst

    private static func metaWithArtwork(_ meta: [UInt8], covr: [UInt8]) -> [UInt8]? {
        guard meta.count >= 12, let kids = parse(meta, 12, meta.count) else { return nil }
        // Solo il formato iTunes ("mdir"): un `meta` di altro tipo non si tocca.
        guard let hdlr = kids.first(where: { $0.type == "hdlr" }),
              hdlr.end - hdlr.start >= 20,
              String(bytes: meta[(hdlr.start + 16)..<(hdlr.start + 20)], encoding: .isoLatin1) == "mdir" else { return nil }
        let flags = Array(meta[8..<12])

        if let ilst = kids.first(where: { $0.type == "ilst" }) {
            guard ilst.headerSize == 8, let items = parse(meta, ilst.start + 8, ilst.end) else { return nil }
            var payload: [UInt8] = []
            for item in items where item.type != "covr" {   // la vecchia copertina esce
                payload += meta[item.start..<item.end]
            }
            payload += covr
            return box("meta", flags + Array(meta[12..<ilst.start]) + box("ilst", payload) + Array(meta[ilst.end...]))
        }
        return box("meta", flags + Array(meta[12...]) + box("ilst", covr))
    }

    private static func udtaWithArtwork(_ udta: [UInt8], covr: [UInt8]) -> [UInt8]? {
        guard let kids = parse(udta, 8, udta.count) else { return nil }
        if let meta = kids.first(where: { $0.type == "meta" }) {
            guard meta.headerSize == 8,
                  let newMeta = metaWithArtwork(Array(udta[meta.start..<meta.end]), covr: covr) else { return nil }
            return box("udta", Array(udta[8..<meta.start]) + newMeta + Array(udta[meta.end...]))
        }
        return box("udta", Array(udta[8...]) + metaBox(ilst: box("ilst", covr)))
    }

    private static func moovWithArtwork(_ moov: [UInt8], covr: [UInt8]) -> [UInt8]? {
        guard let kids = parse(moov, 8, moov.count) else { return nil }
        if let udta = kids.first(where: { $0.type == "udta" }) {
            guard udta.headerSize == 8,
                  let newUdta = udtaWithArtwork(Array(moov[udta.start..<udta.end]), covr: covr) else { return nil }
            return box("moov", Array(moov[8..<udta.start]) + newUdta + Array(moov[udta.end...]))
        }
        return box("moov", Array(moov[8...]) + box("udta", metaBox(ilst: box("ilst", covr))))
    }

    // MARK: - Offset dei chunk

    /// Se `moov` cambia dimensione, i dati audio che lo seguono nel file si spostano: ogni offset
    /// in `stco`/`co64` che punta dopo la vecchia fine di `moov` va corretto della differenza.
    private static func shiftChunkOffsets(_ b: inout [UInt8], from: Int, to: Int, delta: Int, threshold: Int) -> Bool {
        guard let kids = parse(b, from, to) else { return false }
        for k in kids {
            switch k.type {
            case "trak", "mdia", "minf", "stbl":
                if !shiftChunkOffsets(&b, from: k.payloadStart, to: k.end, delta: delta, threshold: threshold) { return false }
            case "stco":
                guard k.payloadStart + 8 <= k.end else { return false }
                let count = u32(b, k.payloadStart + 4)
                var p = k.payloadStart + 8
                guard p + count * 4 <= k.end else { return false }
                for _ in 0..<count {
                    let v = u32(b, p)
                    if v >= threshold {
                        let nv = v + delta
                        guard nv >= 0, nv <= 0xFFFF_FFFF else { return false }
                        put32(&b, p, nv)
                    }
                    p += 4
                }
            case "co64":
                guard k.payloadStart + 8 <= k.end else { return false }
                let count = u32(b, k.payloadStart + 4)
                var p = k.payloadStart + 8
                guard p + count * 8 <= k.end else { return false }
                for _ in 0..<count {
                    let v = u64(b, p)
                    if v >= UInt64(threshold) {
                        let nv = Int64(v) + Int64(delta)
                        guard nv >= 0 else { return false }
                        put64(&b, p, UInt64(nv))
                    }
                    p += 8
                }
            default:
                break
            }
        }
        return true
    }

    // MARK: - API

    /// Restituisce il contenuto di `source` con `image` come copertina (al posto di un'eventuale
    /// precedente), o nil se il file non si può modificare in sicurezza.
    static func embed(image: Data, into source: Data) -> Data? {
        let b = [UInt8](source)
        guard let top = parse(b, 0, b.count),
              !top.contains(where: { $0.type == "moof" }),
              let moov = top.first(where: { $0.type == "moov" }),
              moov.headerSize == 8 else { return nil }

        let oldMoov = Array(b[moov.start..<moov.end])
        guard var newMoov = moovWithArtwork(oldMoov, covr: covrBox([UInt8](image))) else { return nil }

        let delta = newMoov.count - oldMoov.count
        if delta != 0 {
            guard shiftChunkOffsets(&newMoov, from: 8, to: newMoov.count, delta: delta, threshold: moov.end) else { return nil }
        }

        var out = Array(b[0..<moov.start])
        out += newMoov
        out += b[moov.end...]
        return Data(out)
    }
}
