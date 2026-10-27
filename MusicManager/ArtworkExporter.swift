import Foundation
import AVFoundation

/// Esito positivo di `ArtworkExporter.exportWithArtwork`: la cartella temporanea creata (da
/// eliminare a cura del chiamante a fine invio) e il file arricchito al suo interno.
struct ArtworkExportResult {
    let tempDirectory: URL
    let fileURL: URL
}

/// Motivo (già nella lingua dell'interfaccia) per cui la copertina non è stata scritta nel file.
struct ArtworkExportError: Error {
    let reason: String
}

/// Scrive una copertina in una copia temporanea di un file audio AAC/M4A, senza mai toccare
/// l'originale della libreria Apple Music. Usa `AVAssetExportSession` in modalità "passthrough":
/// copia il flusso audio cosi com'è, senza ricomprimerlo, cambiando solo i metadati del
/// contenitore — nessuna perdita di qualità, nessuna attesa percepibile per un singolo brano.
enum ArtworkExporter {
    /// Esporta `sourceURL` in una nuova cartella temporanea, con lo stesso nome di file
    /// dell'originale (importante: è il nome che poi finisce sul dispositivo, deve restare
    /// identico) e con `artworkData` (JPEG) incorporata insieme ai metadati già presenti nel file
    /// (titolo, artista, album...), al posto di un'eventuale copertina precedente.
    ///
    /// La copertina viene scritta con l'identificatore iTunes (atom "covr" dei file M4A), quello che
    /// il contenitore M4A si aspetta davvero; dopo l'esportazione si **rilegge il file prodotto**
    /// per controllare che la copertina ci sia: se non c'è, l'esito è un errore con il motivo, non
    /// un file "arricchito" che in realtà non lo è. In caso di errore il chiamante continua con il
    /// file originale e mostra il motivo nella finestra di trasferimento: questa funzione non deve
    /// mai interrompere un invio.
    static func exportWithArtwork(sourceURL: URL, artworkData: Data) async -> Result<ArtworkExportResult, ArtworkExportError> {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicManagerArtwork-\(UUID().uuidString)", isDirectory: true)
        let destinationURL = tempDirectory.appendingPathComponent(sourceURL.lastPathComponent)

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(ArtworkExportError(reason: error.localizedDescription))
        }

        func fail(_ reason: String) -> Result<ArtworkExportResult, ArtworkExportError> {
            try? FileManager.default.removeItem(at: tempDirectory)
            return .failure(ArtworkExportError(reason: reason))
        }

        // Via principale: modifica diretta degli atom MP4 (audio e altri metadati invariati byte
        // per byte, vedi `MP4ArtworkWriter`). Se non è possibile, o se il risultato non passa il
        // controllo, si ripiega su `AVAssetExportSession` qui sotto.
        if let source = try? Data(contentsOf: sourceURL, options: .mappedIfSafe),
           let patched = MP4ArtworkWriter.embed(image: artworkData, into: source) {
            if (try? patched.write(to: destinationURL)) != nil,
               await MusicLibraryService.embeddedArtwork(at: destinationURL) != nil {
                return .success(ArtworkExportResult(tempDirectory: tempDirectory, fileURL: destinationURL))
            }
            try? FileManager.default.removeItem(at: destinationURL)
        }

        let asset = AVURLAsset(url: sourceURL)

        func isArtwork(_ item: AVMetadataItem) -> Bool {
            if item.commonKey == .commonKeyArtwork || item.identifier == .iTunesMetadataCoverArt { return true }
            let raw = item.identifier?.rawValue.lowercased() ?? ""
            return raw.hasSuffix("/covr") || raw.hasSuffix("/apic") || raw.hasSuffix("/pic")
        }

        // 2.0.1: per non perdere i dati del brano si portano nella copia TUTTI i metadati del file (genere, anno,
        // compositore, numeri di traccia e disco, artista dell'album…), non solo quelli «common» (titolo, artista,
        // album): senza questo l'esportazione li scartava. La copertina vecchia esce, quella nuova entra.
        var full: [AVMetadataItem] = (try? await asset.load(.metadata)) ?? []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            full += (try? await asset.loadMetadata(for: format)) ?? []
        }
        var seen = Set<String>()
        var unique: [AVMetadataItem] = []
        for item in full where !isArtwork(item) {
            // Valori caricati con l'API asincrona (le proprietà dirette sono deprecate da macOS 13).
            let text = try? await item.load(.stringValue)
            let number = try? await item.load(.numberValue)
            let data = try? await item.load(.dataValue)
            let key = (item.identifier?.rawValue ?? item.commonKey?.rawValue ?? "?") + "|"
                + (text ?? number?.stringValue ?? "\(data?.hashValue ?? 0)")
            if seen.insert(key).inserted { unique.append(item) }
        }
        full = unique
        let commonOnly = ((try? await asset.load(.commonMetadata)) ?? []).filter { !isArtwork($0) }

        let artworkItem = AVMutableMetadataItem()
        artworkItem.identifier = .iTunesMetadataCoverArt
        artworkItem.value = artworkData as NSData
        artworkItem.dataType = kCMMetadataBaseDataType_JPEG as String
        artworkItem.extendedLanguageTag = "und"

        // Prima con tutti i metadati; se l'esportazione non riesce (o la copertina non risulta nel file prodotto) si
        // riprova con i soli «common», come prima.
        var lastReason = t("artwork_reason_no_session")
        for metadata in [full, commonOnly] {
            try? FileManager.default.removeItem(at: destinationURL)
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                lastReason = t("artwork_reason_no_session")
                continue
            }
            exportSession.metadata = metadata + [artworkItem]
            do {
                try await exportSession.export(to: destinationURL, as: .m4a)
            } catch {
                lastReason = error.localizedDescription
                continue
            }
            // Controllo sul file prodotto: la copertina deve risultare davvero incorporata.
            guard await MusicLibraryService.embeddedArtwork(at: destinationURL) != nil else {
                lastReason = t("artwork_reason_not_in_output")
                continue
            }
            return .success(ArtworkExportResult(tempDirectory: tempDirectory, fileURL: destinationURL))
        }
        return fail(lastReason)
    }
}
