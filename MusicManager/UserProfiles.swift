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
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Profili utente (2.4 Internal, sperimentale)
//
// Più persone con lo stesso account macOS: ognuna ha impostazioni, dispositivi memorizzati e librerie esterne proprie.
// Le chiavi di `UserDefaults` dell'utente attivo si ottengono aggiungendo un prefisso (`ProfileDefaults`). Il primo utente
// ha prefisso vuoto: sono le chiavi di sempre, quindi non serve alcuna migrazione e, finché l'interruttore sperimentale è
// spento (o c'è un solo utente), l'app si comporta esattamente come prima. Cache, copertine confermate e libreria di
// Musica restano comuni a tutti.

/// Un utente dell'app.
struct UserProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// «symbol» (nome di un simbolo SF), «letter» (una lettera) o «photo» (file `Users/<id>.png`).
    var avatarKind = "letter"
    var avatarValue = ""
    /// Prefisso delle chiavi di `UserDefaults`: vuoto per il primo utente (le impostazioni di prima dei profili).
    var prefix = ""

    /// Lettera mostrata nell'avatar «lettera»: quella scelta o, in mancanza, l'iniziale del nome.
    var letter: String {
        let chosen = avatarValue.trimmingCharacters(in: .whitespaces)
        if !chosen.isEmpty { return String(chosen.prefix(1)).uppercased() }
        return String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
}

/// Registro degli utenti e utente attivo, letti all'avvio prima di qualunque altra impostazione.
enum ProfileStorage {
    static let enabledKey = "profiles_enabled"
    static let registryKey = "profiles_registry"
    static let activeKey = "profiles_active_id"

    /// Prefisso dell'utente attivo (vuoto se i profili sono spenti o non ce ne sono). Si legge una volta, alla prima richiesta.
    nonisolated(unsafe) static var activePrefix: String = loadActivePrefix()

    private static func loadActivePrefix() -> String {
        let d = UserDefaults.standard
        guard d.bool(forKey: enabledKey),
              let data = d.data(forKey: registryKey),
              let list = try? JSONDecoder().decode([UserProfile].self, from: data), !list.isEmpty else { return "" }
        let active = d.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        return (list.first { $0.id == active } ?? list[0]).prefix
    }
}

/// Stessa interfaccia di `UserDefaults` per le chiavi che appartengono all'utente: aggiunge il prefisso dell'utente attivo.
struct ProfileDefaults {
    static let shared = ProfileDefaults()
    private var defaults: UserDefaults { .standard }
    private func k(_ key: String) -> String { ProfileStorage.activePrefix + key }

    func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: k(key)) }
    func object(forKey key: String) -> Any? { defaults.object(forKey: k(key)) }
    func string(forKey key: String) -> String? { defaults.string(forKey: k(key)) }
    func data(forKey key: String) -> Data? { defaults.data(forKey: k(key)) }
    func removeObject(forKey key: String) { defaults.removeObject(forKey: k(key)) }

    /// Valore di un altro utente (per riconoscere i suoi dispositivi) e cancellazione delle chiavi di un utente eliminato.
    static func data(forKey key: String, prefix: String) -> Data? { UserDefaults.standard.data(forKey: prefix + key) }
    static func removeAll(prefix: String, keys: [String]) {
        for key in keys { UserDefaults.standard.removeObject(forKey: prefix + key) }
    }
}

/// Foto degli avatar: ritagliate in quadrato a 128 px e salvate in `Application Support/MusicManager/Users/<id>.png`.
@MainActor
enum ProfilePhotoStore {
    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicManager/Users", isDirectory: true)
    }
    private static func url(for id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).png") }
    private static var cache: [UUID: NSImage] = [:]

    static func image(for id: UUID) -> NSImage? {
        if let cached = cache[id] { return cached }
        guard let image = NSImage(contentsOf: url(for: id)) else { return nil }
        cache[id] = image
        return image
    }

    /// Ritaglia al centro in quadrato e riduce a `side` px; nil se l'immagine non si può disegnare.
    static func squared(_ image: NSImage, side: Int = 128) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let edge = min(w, h)
        let source = NSRect(x: (w - edge) / 2, y: (h - edge) / 2, width: edge, height: edge)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: source, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: side, height: side))
        result.addRepresentation(rep)
        return result
    }

    static func save(_ image: NSImage, for id: UUID) {
        guard let square = squared(image),
              let rep = square.representations.first as? NSBitmapImageRep,
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: url(for: id), options: .atomic)
        cache[id] = square
    }

    static func remove(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        cache[id] = nil
    }
}

/// Registro degli utenti: elenco, utente attivo, interruttore sperimentale e cambio utente.
@MainActor
final class UserProfiles: ObservableObject {
    static let shared = UserProfiles()
    static let maxUsers = 5

    @Published private(set) var profiles: [UserProfile] = []
    @Published private(set) var activeID: UUID?
    /// Interruttore sperimentale (Impostazioni ▸ Avanzate): spento = nessuna icona e l'app come prima.
    @Published private(set) var enabled: Bool

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: ProfileStorage.enabledKey)
        if let data = d.data(forKey: ProfileStorage.registryKey),
           let list = try? JSONDecoder().decode([UserProfile].self, from: data) { profiles = list }
        activeID = d.string(forKey: ProfileStorage.activeKey).flatMap(UUID.init(uuidString:)) ?? profiles.first?.id
    }

    var active: UserProfile? { profiles.first { $0.id == activeID } ?? profiles.first }

    /// Numero d'ordine dell'utente («n. 2»), per il registro: i nomi non si scrivono nel log.
    func number(of id: UUID?) -> String {
        guard let id, let i = profiles.firstIndex(where: { $0.id == id }) else { return "n. ?" }
        return "n. \(i + 1)"
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: ProfileStorage.enabledKey)
        if let data = try? JSONEncoder().encode(profiles) { d.set(data, forKey: ProfileStorage.registryKey) }
        d.set(activeID?.uuidString, forKey: ProfileStorage.activeKey)
    }

    /// Nome proposto per l'utente di adesso: il nome dell'account macOS.
    static var suggestedCurrentName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "Utente"
    }

    // MARK: Interruttore

    func enable() {
        guard !enabled else { return }
        enabled = true
        save()
        if let p = active, p.prefix != ProfileStorage.activePrefix {
            ProfileStorage.activePrefix = p.prefix
            AppSettings.shared.reloadForProfile()
            AppViewModel.current?.profileDidChange()
        }
    }

    /// Spegnendo l'interruttore si torna al primo utente (le impostazioni di prima dei profili); gli altri restano salvati.
    func disable() {
        guard enabled else { return }
        if let legacy = profiles.first(where: { $0.prefix.isEmpty }) {
            if legacy.id != activeID, !performSwitch(to: legacy, mode: .reload) { return }
        } else if !ProfileStorage.activePrefix.isEmpty {
            ProfileStorage.activePrefix = ""
            AppSettings.shared.reloadForProfile()
            AppViewModel.current?.profileDidChange()
        }
        enabled = false
        save()
        AppLog.event("utenti", "profili disattivati: si torna al primo utente (n. 1); gli altri utenti restano salvati")
    }

    // MARK: Cambio utente

    private enum SwitchMode: Equatable { case reload, copyCurrent }

    private var isBusy: Bool {
        let vm = AppViewModel.current
        return (vm?.isBusy ?? false) || (vm?.sendPreparing ?? false)
    }

    /// Finestra di avviso in primo piano; restituisce l'indice del pulsante premuto.
    @discardableResult
    private func ask(_ title: String, _ message: String, buttons: [String], destructive: Bool = false) -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        for b in buttons { alert.addButton(withTitle: b) }
        if destructive, alert.buttons.count > 0 { alert.buttons[0].hasDestructiveAction = true }
        return StallWatchdog.modal({ alert.runModal() }).rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    private func showBusy() {
        AppLog.event("utenti", "cambio utente rifiutato: operazione in corso")
        ask(t("profile_busy_title"), t("profile_busy_message"), buttons: [t("button_ok")])
    }

    @discardableResult
    func switchTo(_ id: UUID) -> Bool {
        guard id != activeID, let p = profiles.first(where: { $0.id == id }) else { return false }
        return performSwitch(to: p, mode: .reload)
    }

    @discardableResult
    private func performSwitch(to p: UserProfile, mode: SwitchMode) -> Bool {
        if isBusy { showBusy(); return false }
        let from = number(of: activeID)
        ProfileStorage.activePrefix = p.prefix
        activeID = p.id
        save()
        AppLog.event("utenti", "cambio utente: da \(from) a \(number(of: p.id)) (\(mode == .copyCurrent ? "impostazioni copiate dall'utente precedente" : "impostazioni dell'utente caricate"))")
        switch mode {
        case .reload: AppSettings.shared.reloadForProfile()
        case .copyCurrent: AppSettings.shared.copyCurrentToActiveProfile()
        }
        AppViewModel.current?.profileDidChange()
        // La lingua dell'interfaccia cambia subito; i pochi menu di sistema di macOS la seguono al prossimo avvio (come
        // cambiando la lingua dalle Impostazioni): nessuna richiesta di riavvio.
        return true
    }

    // MARK: Aggiunta, modifica, eliminazione

    /// Aggiunge un utente e passa a lui. Alla prima aggiunta le impostazioni di adesso diventano il primo utente
    /// (`currentUserName`). `copyCurrent`: parte dalle impostazioni e dalle librerie esterne dell'utente attuale; altrimenti dai valori predefiniti.
    @discardableResult
    func addProfile(name: String, avatarKind: String, avatarValue: String, photo: NSImage?,
                    copyCurrent: Bool, currentUserName: String?) -> Bool {
        if isBusy { showBusy(); return false }
        if profiles.isEmpty {
            let first = currentUserName?.trimmingCharacters(in: .whitespaces) ?? ""
            let legacy = UserProfile(name: first.isEmpty ? Self.suggestedCurrentName : first, prefix: "")
            profiles = [legacy]
            activeID = legacy.id
        }
        guard profiles.count < Self.maxUsers else { return false }
        let p = UserProfile(name: name.trimmingCharacters(in: .whitespaces), avatarKind: avatarKind,
                            avatarValue: avatarValue, prefix: "user.\(UUID().uuidString).")
        if avatarKind == "photo", let photo { ProfilePhotoStore.save(photo, for: p.id) }
        profiles.append(p)
        AppLog.event("utenti", "nuovo utente \(number(of: p.id)) creato (partenza: \(copyCurrent ? "impostazioni dell'utente attuale" : "valori predefiniti"); immagine: \(avatarKind)); utenti: \(profiles.count)")
        return performSwitch(to: p, mode: copyCurrent ? .copyCurrent : .reload)
    }

    /// Attivazione dei profili: l'utente di adesso diventa il primo (prefisso vuoto = le chiavi di sempre), con le sue
    /// impostazioni e i suoi dispositivi così come sono: nessun cambio di utente, nessuna rilettura. Accende l'interruttore.
    @discardableResult
    func createFirstProfile(name: String, avatarKind: String, avatarValue: String, photo: NSImage?) -> Bool {
        guard profiles.isEmpty else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let p = UserProfile(name: trimmed.isEmpty ? Self.suggestedCurrentName : trimmed, avatarKind: avatarKind,
                            avatarValue: avatarValue, prefix: "")
        if avatarKind == "photo", let photo { ProfilePhotoStore.save(photo, for: p.id) }
        profiles = [p]
        activeID = p.id
        ProfileStorage.activePrefix = ""
        enabled = true
        save()
        AppLog.event("utenti", "profili attivati: l'utente di adesso diventa il primo (n. 1; immagine: \(avatarKind)); impostazioni e dispositivi invariati")
        return true
    }

    func updateProfile(_ updated: UserProfile, photo: NSImage?) {
        guard let i = profiles.firstIndex(where: { $0.id == updated.id }) else { return }
        if updated.avatarKind == "photo", let photo { ProfilePhotoStore.save(photo, for: updated.id) }
        profiles[i] = updated
        save()
    }

    /// Elimina un utente (con conferma): impostazioni, dispositivi e librerie esterne sue; Musica e copertine non si toccano.
    /// L'ultimo utente non si elimina. Se è l'utente attivo si passa al primo rimasto.
    func deleteProfile(_ id: UUID) {
        guard profiles.count > 1, let p = profiles.first(where: { $0.id == id }) else { return }
        let answer = ask(t("profile_delete_title", p.name), t("profile_delete_message"),
                         buttons: [t("button_remove"), t("button_cancel")], destructive: true)
        guard answer == 0 else { return }
        AppLog.event("utenti", "utente \(number(of: id)) eliminato\(id == activeID ? " (era l'attivo)" : ""); utenti rimasti: \(profiles.count - 1)")
        if id == activeID {
            guard let next = profiles.first(where: { $0.id != id }), performSwitch(to: next, mode: .reload) else { return }
        }
        // Copie salvate e indici delle sue librerie esterne (non quelli con lo stesso identificativo in uso a un altro utente).
        let others = profiles.filter { $0.id != id }
        let usedRemote = Set(others.flatMap { AppSettings.remoteLibraries(forPrefix: $0.prefix).map(\.id) })
        let usedDrive = Set(others.flatMap { AppSettings.driveLibraries(forPrefix: $0.prefix).map(\.id) })
        for lib in AppSettings.remoteLibraries(forPrefix: p.prefix) where !usedRemote.contains(lib.id) {
            ExternalParsed.removeCache(forXMLPath: lib.path, key: lib.id.uuidString)
        }
        for lib in AppSettings.driveLibraries(forPrefix: p.prefix) where !usedDrive.contains(lib.id) {
            DriveLibraryService.removeIndex(lib.id)
        }
        ProfileDefaults.removeAll(prefix: p.prefix, keys: AppSettings.perUserKeys)
        ProfilePhotoStore.remove(id: p.id)
        profiles.removeAll { $0.id == id }
        save()
    }

    // MARK: Dispositivi

    /// Se il dispositivo non è tra quelli dell'utente attivo ma lo è tra quelli di un altro utente, restituisce quell'utente.
    func ownerOfUnknownDevice(_ deviceID: String) -> UserProfile? {
        guard enabled, profiles.count > 1, let active else { return nil }
        if AppSettings.shared.knownDevices.contains(where: { $0.id == deviceID }) { return nil }
        return profiles.first { $0.id != active.id
            && AppSettings.knownDevices(forPrefix: $0.prefix).contains { $0.id == deviceID } }
    }
}

// MARK: - Interfaccia

/// Immagine tonda di un utente: foto, simbolo o lettera (sfondo nel colore dell'interfaccia). Senza utente: un «+».
struct ProfileAvatar: View {
    let profile: UserProfile?
    var size: CGFloat = 24
    /// Foto appena scelta e non ancora salvata (anteprima nella finestra di modifica).
    var previewPhoto: NSImage? = nil
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            if let p = profile {
                switch p.avatarKind {
                case "photo":
                    if let img = previewPhoto ?? ProfilePhotoStore.image(for: p.id) {
                        Image(nsImage: img).resizable().scaledToFill()
                            .frame(width: size, height: size).clipped()
                    } else {
                        Circle().fill(settings.accentColor)
                        Image(systemName: "person.fill").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
                    }
                case "symbol":
                    Circle().fill(settings.accentColor)
                    Image(systemName: p.avatarValue.isEmpty ? "person.fill" : p.avatarValue)
                        .font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
                default:
                    Circle().fill(settings.accentColor)
                    Text(p.letter).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
                }
            } else {
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
                Image(systemName: "plus").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Finestra aperta dal menu: nuovo utente o modifica di uno esistente.
enum ProfileSheetMode: Identifiable {
    case add
    case edit(UserProfile)
    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let p): return "edit-\(p.id.uuidString)"
        }
    }
}

/// Pulsante tondo dell'utente: nella barra del titolo (`.toolbar`) e nella riga delle schede di Impostazioni (`.settings`,
/// con il nome). Senza utenti è un «+»; poi un menu con l'utente attuale in prima riga, gli altri utenti e le azioni.
/// Compare solo con l'interruttore sperimentale acceso.
struct UserProfileMenu: View {
    enum Style { case toolbar, settings, capsule }
    /// Nella capsula della finestra principale: con il nome accanto all'immagine (true) o solo il tondo (false).
    private static let capsuleShowsName = true
    let style: Style
    @ObservedObject private var users = UserProfiles.shared
    @ObservedObject private var settings = AppSettings.shared   // il colore dell'avatar segue l'interfaccia
    @State private var sheet: ProfileSheetMode?
    /// Larghezza fissa del riquadro nelle Impostazioni: 8 + 36 + 8 + ~124 (20 caratteri) + 8 + 8 + 8.
    private static let settingsBoxWidth: CGFloat = 200

    /// L'avatar come immagine già disegnata: nelle etichette dei menu macOS i colori e le forme delle viste non si rispettano
    /// (la lettera bianca restava senza il cerchio e il resto spariva), mentre un'immagine si mostra com'è.
    private func avatarImage(_ profile: UserProfile?, size: CGFloat) -> Image {
        let renderer = ImageRenderer(content: ProfileAvatar(profile: profile, size: size))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return Image(systemName: "person.crop.circle") }
        // Dimensione imposta: l'immagine disegnata può avere una misura propria (foto da 128 px) e sfondare la barra.
        return Image(nsImage: image).renderingMode(.original).resizable().interpolation(.high)
    }

    var body: some View {
        if users.enabled {
            content
                .sheet(item: $sheet) { ProfileEditorSheet(mode: $0) }
        }
    }

    /// Voci del menu dell'utente attivo (con più utenti: prima gli utenti, poi le azioni).
    @ViewBuilder private func menuItems(_ active: UserProfile) -> some View {
        if users.profiles.count > 1 {
            Button { } label: { Label(active.name, systemImage: "checkmark") }
                .disabled(true)
            ForEach(users.profiles.filter { $0.id != active.id }) { p in
                Button(p.name) { users.switchTo(p.id) }
            }
            Divider()
        }
        Button(t("profile_menu_add")) { sheet = .add }
            .disabled(users.profiles.count >= UserProfiles.maxUsers)
        Button(t("profile_menu_edit")) { sheet = .edit(active) }
        if users.profiles.count > 1 {
            Button(t("profile_menu_delete"), role: .destructive) { users.deleteProfile(active.id) }
        }
    }

    @ViewBuilder private var content: some View {
        if let active = users.active, !users.profiles.isEmpty {
            switch style {
            case .toolbar:
                Menu { menuItems(active) } label: { label(for: active) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(t("profile_menu_tooltip", active.name))
            case .settings, .capsule:
                // Come il selettore delle memorie: il riquadro lo disegniamo noi (le etichette dei menu macOS scartano contorni,
                // frecce e colori) e il menu, trasparente, sta sopra.
                label(for: active)
                    .overlay {
                        Menu { menuItems(active) } label: { Color.clear.contentShape(Rectangle()) }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .fixedSize()
                    .help(t("profile_menu_tooltip", active.name))
            }
        } else {
            Button { sheet = .add } label: { label(for: nil) }
                .buttonStyle(.plain)
                .help(t("profile_menu_add"))
        }
    }

    @ViewBuilder private func label(for profile: UserProfile?) -> some View {
        switch style {
        case .toolbar:
            avatarImage(profile, size: 24)
                .frame(width: 24, height: 24)
                .clipShape(Circle())
                .frame(minWidth: 26, minHeight: 24)
        case .capsule:
            // Nella capsula (38 pt): immagine da 30 pt, nome e triangoli, senza riquadro.
            HStack(spacing: 8) {
                avatarImage(profile, size: 30)
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                if Self.capsuleShowsName, let profile {
                    Text(profile.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                        .frame(width: 124, alignment: .leading)   // larghezza fissa: il tondo resta sempre nello stesso punto
                }
                if Self.capsuleShowsName, profile != nil {
                    VStack(spacing: 2) {
                        if users.profiles.count > 1 { Image(systemName: "arrowtriangle.up.fill") }
                        Image(systemName: "arrowtriangle.down.fill")
                    }
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.trailing, Self.capsuleShowsName ? 8 : 0)   // le frecce staccate dal bordo: come lo spazio tra tondo e nome
            .frame(height: 30)
            .contentShape(Rectangle())
        case .settings:
            // Riquadro come quello delle schede (46 pt di altezza, angoli di 8 pt), ma solo contorno nel colore di selezione.
            // Larghezza fissa: immagine da 36 pt (come il cerchio degli artisti) + 20 caratteri + freccia/frecce.
            HStack(spacing: 8) {
                avatarImage(profile, size: 36)
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                Text(profile?.name ?? t("profile_menu_add"))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Un solo utente: triangolo in giù (menu delle azioni); più utenti: triangolo su e giù (menu con gli utenti).
                if profile != nil {
                    VStack(spacing: 2) {
                        if users.profiles.count > 1 { Image(systemName: "arrowtriangle.up.fill") }
                        Image(systemName: "arrowtriangle.down.fill")
                    }
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: Self.settingsBoxWidth, height: 46)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(settings.highlightColor, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Finestra «Nuovo utente» / «Modifica utente»: soprannome e immagine (simbolo, lettera o foto). Alla prima aggiunta
/// (attivazione dei profili) crea l'utente di adesso, con le impostazioni attuali e senza altre domande; per gli utenti
/// successivi chiede da dove partono le impostazioni.
struct ProfileEditorSheet: View {
    let mode: ProfileSheetMode
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var users = UserProfiles.shared
    @State private var name = ""
    @State private var kind = "letter"
    @State private var symbol = "person.fill"
    @State private var letter = ""
    @State private var photo: NSImage?
    @State private var startFromCurrent = true
    @State private var loaded = false

    private static let symbols = ["person.fill", "figure.walk", "figure.run", "bicycle", "heart.fill", "star.fill",
                                  "bolt.fill", "leaf.fill", "flame.fill", "moon.fill", "sun.max.fill", "music.note",
                                  "guitars.fill", "headphones", "mountain.2.fill", "pawprint.fill", "gamecontroller.fill", "airplane"]

    private var isAdd: Bool { if case .add = mode { return true } else { return false } }
    private var isFirstAdd: Bool { isAdd && users.profiles.isEmpty }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool {
        guard !trimmedName.isEmpty else { return false }
        if kind == "photo", photo == nil, !hasStoredPhoto { return false }
        return true
    }
    private var hasStoredPhoto: Bool {
        if case .edit(let p) = mode, p.avatarKind == "photo" { return ProfilePhotoStore.image(for: p.id) != nil }
        return false
    }
    private var draft: UserProfile {
        var p = UserProfile(name: trimmedName.isEmpty ? " " : trimmedName)
        if case .edit(let existing) = mode { p.id = existing.id }
        p.avatarKind = kind
        p.avatarValue = kind == "symbol" ? symbol : (kind == "letter" ? letter : "")
        return p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t(isAdd ? "profile_sheet_add_title" : "profile_sheet_edit_title")).font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(t("profile_nickname")).font(.subheadline.weight(.semibold))
                TextField(t("profile_nickname"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, new in if new.count > 20 { name = String(new.prefix(20)) } }
                if isFirstAdd {
                    // Primo utente: le impostazioni e i dispositivi di adesso restano così come sono, sotto questo nome.
                    Text(t("profile_first_hint", trimmedName.isEmpty ? UserProfiles.suggestedCurrentName : trimmedName))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(t("profile_avatar")).font(.subheadline.weight(.semibold))
                HStack(alignment: .top, spacing: 14) {
                    ProfileAvatar(profile: draft, size: 56, previewPhoto: photo)
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $kind) {
                            Text(t("profile_avatar_symbol")).tag("symbol")
                            Text(t("profile_avatar_letter")).tag("letter")
                            Text(t("profile_avatar_photo")).tag("photo")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        avatarEditor
                    }
                }
            }

            if isAdd && !isFirstAdd {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("profile_start_from")).font(.subheadline.weight(.semibold))
                    Picker("", selection: $startFromCurrent) {
                        Text(t("profile_start_current")).tag(true)
                        Text(t("profile_start_defaults")).tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(t("profile_start_hint")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button(t("button_cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(t(isAdd ? "profile_create" : "profile_save")) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { load() }
    }

    @ViewBuilder private var avatarEditor: some View {
        switch kind {
        case "symbol":
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 6), alignment: .leading, spacing: 4) {
                ForEach(Self.symbols, id: \.self) { s in
                    Button { symbol = s } label: {
                        Image(systemName: s).font(.system(size: 15))
                            .frame(width: 34, height: 30)
                            .background(symbol == s ? AppSettings.shared.highlightColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        case "photo":
            VStack(alignment: .leading, spacing: 6) {
                Button(t("profile_choose_photo")) { choosePhoto() }
                Text(t("profile_photo_hint")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in loadPhoto(from: url) } }
                }
                return true
            }
        default:
            HStack(spacing: 8) {
                Text(t("profile_letter_field")).font(.caption).foregroundStyle(.secondary)
                TextField(String(trimmedName.prefix(1)).uppercased(), text: $letter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .onChange(of: letter) { _, new in if new.count > 1 { letter = String(new.prefix(1)) } }
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if isFirstAdd { name = UserProfiles.suggestedCurrentName }
        if case .edit(let p) = mode {
            name = p.name
            kind = p.avatarKind
            if p.avatarKind == "symbol" { symbol = p.avatarValue }
            if p.avatarKind == "letter" { letter = p.avatarValue }
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard StallWatchdog.modal({ panel.runModal() }) == .OK, let url = panel.url else { return }
        loadPhoto(from: url)
    }

    private func loadPhoto(from url: URL) {
        guard let image = NSImage(contentsOf: url), let square = ProfilePhotoStore.squared(image) else { return }
        photo = square
        kind = "photo"
    }

    private func commit() {
        let value = kind == "symbol" ? symbol : (kind == "letter" ? letter : "")
        switch mode {
        case .add:
            dismiss()
            // Il cambio utente può aprire finestre di avviso: si lascia prima chiudere questa.
            let newName = trimmedName, newKind = kind, newPhoto = photo, copy = startFromCurrent
            if isFirstAdd {
                users.createFirstProfile(name: newName, avatarKind: newKind, avatarValue: value, photo: newPhoto)
                return
            }
            Task { @MainActor in
                users.addProfile(name: newName, avatarKind: newKind, avatarValue: value, photo: newPhoto,
                                 copyCurrent: copy, currentUserName: nil)
            }
        case .edit(var p):
            p.name = trimmedName
            p.avatarKind = kind
            p.avatarValue = value
            users.updateProfile(p, photo: photo)
            dismiss()
        }
    }
}

/// Alert «Dispositivo di un altro utente»: il Garmin appena collegato è tra quelli di un altro utente; si propone il cambio.
struct DeviceOwnerPromptModifier: ViewModifier {
    @ObservedObject var vm: AppViewModel
    @ObservedObject private var users = UserProfiles.shared

    func body(content: Content) -> some View {
        content.alert(t("device_owner_title"), isPresented: Binding(
            get: { vm.deviceOwnerPrompt != nil },
            set: { if !$0, vm.deviceOwnerPrompt != nil { vm.resolveDeviceOwnerPrompt(switchUser: false) } }
        ), presenting: vm.deviceOwnerPrompt) { p in
            Button(t("device_owner_switch", p.owner.name)) { vm.resolveDeviceOwnerPrompt(switchUser: true) }
            Button(t("device_owner_stay", users.active?.name ?? "")) { vm.resolveDeviceOwnerPrompt(switchUser: false) }
        } message: { p in
            Text(t("device_owner_message", p.model.isEmpty ? p.deviceID : p.model, p.owner.name))
        }
    }
}
