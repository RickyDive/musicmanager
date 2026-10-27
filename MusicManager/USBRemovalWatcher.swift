import Foundation
import IOKit

/// Avvisa quando un dispositivo USB Garmin viene scollegato. L'app non lo sapeva: restava
/// "connessa" a un orologio ormai staccato finché non si premeva "Disconnetti" a mano (e con una
/// chiamata MTP appesa nemmeno quello bastava). Si appoggia alla notifica di rimozione di IOKit,
/// consegnata sul run loop principale.
final class USBRemovalWatcher {
    /// Codice fornitore USB di Garmin.
    private static let garminVendorID = 0x091E

    private var port: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private let onRemoved: @MainActor () -> Void
    private let isConnected: @MainActor () -> Bool
    private var pollTimer: Timer?
    /// Vero se, durante la connessione corrente, il Garmin è stato visto sul bus USB almeno una
    /// volta: la sparizione viene segnalata solo in quel caso (evita falsi allarmi se il rilevamento
    /// per qualche motivo non vedesse mai il dispositivo).
    private var seenWhileConnected = false

    /// Indica se sul bus USB c'è un dispositivo con codice fornitore Garmin. Scorre tutti i
    /// dispositivi USB (senza filtro sul fornitore nel dizionario di ricerca) e legge `idVendor`.
    static func isGarminPresent() -> Bool {
        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &it) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(it) }
            var object = IOIteratorNext(it)
            while object != 0 {
                defer { IOObjectRelease(object); object = IOIteratorNext(it) }
                if let value = IORegistryEntryCreateCFProperty(object, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
                   value == garminVendorID {
                    return true
                }
            }
        }
        return false
    }

    init(isConnected: @escaping @MainActor () -> Bool, onRemoved: @escaping @MainActor () -> Void) {
        self.onRemoved = onRemoved
        self.isConnected = isConnected

        // Controllo periodico (ogni secondo e mezzo): non dipende dalle notifiche di IOKit, che
        // con il dispositivo aperto da libmtp/libusb possono non arrivare.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["idVendor"] = Self.garminVendorID
        // IOServiceAddMatchingNotification "consuma" un riferimento al dizionario: lo si compensa.
        _ = Unmanaged.passRetained(matching)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching, { refcon, iterator in
            var removed = false
            var object = IOIteratorNext(iterator)
            while object != 0 {
                IOObjectRelease(object)
                removed = true
                object = IOIteratorNext(iterator)
            }
            guard removed, let refcon else { return }
            let watcher = Unmanaged<USBRemovalWatcher>.fromOpaque(refcon).takeUnretainedValue()
            // La notifica arriva già sul thread principale (run loop principale).
            MainActor.assumeIsolated { watcher.onRemoved() }
        }, refcon, &iterator)

        // Dopo la registrazione l'iteratore va "svuotato" una volta per armare le notifiche future.
        if result == KERN_SUCCESS {
            var object = IOIteratorNext(iterator)
            while object != 0 {
                IOObjectRelease(object)
                object = IOIteratorNext(iterator)
            }
        }
    }

    @MainActor
    private func poll() {
        guard isConnected() else { seenWhileConnected = false; return }
        if Self.isGarminPresent() {
            seenWhileConnected = true
        } else if seenWhileConnected {
            seenWhileConnected = false
            onRemoved()
        }
    }

    deinit {
        pollTimer?.invalidate()
        if iterator != 0 { IOObjectRelease(iterator) }
        if let port { IONotificationPortDestroy(port) }
    }
}
