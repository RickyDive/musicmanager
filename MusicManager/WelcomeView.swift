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

import SwiftUI

/// Finestra di benvenuto del primo avvio (dalla 2.4 Internal: prima era un avviso di sistema). Icona dell'app, nome, versione,
/// una riga di ringraziamento e cinque punti con una icona ciascuno. Mostrata nel pannello di vetro (`GlassModalPresenter`) come le altre finestre; chiusa con «OK» o con Esc. La spunta «Non mostrare al prossimo avvio» (attiva di partenza) decide se ricompare.
struct WelcomeView: View {
    /// Chiamata alla chiusura con il valore della spunta «Non mostrare al prossimo avvio».
    let onClose: (_ dontShowAgain: Bool) -> Void
    @State private var dontShowAgain = true

    private var release: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("welcome_hello")).font(.system(size: 15))
                    Text(AboutView.appName).font(.system(size: 30, weight: .bold))
                    Text(t("welcome_release", release)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }

            Divider().padding(.vertical, 20)

            Text(t("welcome_intro"))
                .font(.system(size: 14))
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 14) {
                point("music.note.list", "welcome_point_music")
                point("checkmark.shield", "welcome_point_safe")
                point("lock.shield", "welcome_point_garmin")
                point("mic", "welcome_point_podcast")
                point("lifepreserver", "welcome_point_help")
            }

            // Spunta a sinistra (allineata al margine del testo) e OK a destra, sulla stessa linea centrale.
            HStack(alignment: .center) {
                Toggle(t("welcome_dont_show"), isOn: $dontShowAgain)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                Spacer()
                Button(t("button_ok")) { onClose(dontShowAgain) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.flatProminentRoomy)
                    .controlSize(.large)
            }
            .padding(.top, 26)
        }
        .padding(30)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        // Esc chiude come OK (pulsante invisibile: nel pannello di vetro non c'è altro modo di annullare).
        .background(Button("") { onClose(dontShowAgain) }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0))
    }

    /// Un punto: icona nel colore dell'interfaccia e testo (con **grassetto** per la parola chiave).
    private func point(_ symbol: String, _ key: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.tint)
                .frame(width: 26)
            Text(.init(t(key)))
                .font(.system(size: 13.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
