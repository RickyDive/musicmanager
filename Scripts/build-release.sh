#!/bin/bash
# Music Manager
# Copyright (C) 2026 Riccardo Colaiori
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# Compila in Release e crea il DMG da pubblicare su GitHub Releases. Richiede: xcodegen, libmtp, libusb (brew install libmtp libusb xcodegen).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen non trovato: brew install xcodegen"; exit 1; }
xcodegen generate
PROJ="MusicManager.xcodeproj"
# Nome dello scheme: preso dal progetto (il primo disponibile) per non dipendere dal nome del target
SCHEME="$(xcodebuild -project "$PROJ" -list -json | python3 -c 'import json,sys; d=json.load(sys.stdin)["project"]; print((d.get("schemes") or [""])[0])')"
[ -n "$SCHEME" ] || { echo "Nessuno scheme trovato in $PROJ"; xcodebuild -project "$PROJ" -list; exit 1; }
echo "Scheme: $SCHEME"
xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" build
APP="$(ls -d build/Build/Products/Release/*.app | head -1)"
Scripts/verify-bundle.sh "$APP"

VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" | tr ' ' '-')"
STAGE="build/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.md "$STAGE/READ ME.txt"
cp LICENSE "$STAGE/LICENSE.txt"
DMG="build/MusicManager-$VER.dmg"
rm -f "$DMG"
# `hdiutil create` è deprecato (avviso: usare `diskutil image create from`). Si prova prima il comando nuovo; se non è disponibile
# o fallisce (macOS più vecchi, opzioni diverse) si ripiega sul vecchio, che funziona ancora. DMG_TOOL=hdiutil lo forza.
make_dmg_old() { hdiutil create -volname "Music Manager" -srcfolder "$STAGE" -ov -format UDZO "$DMG"; }
if [ "${DMG_TOOL:-diskutil}" = "hdiutil" ]; then
  make_dmg_old
elif diskutil image create from "$STAGE" "$DMG" --volumeName "Music Manager" --format UDZO; then
  echo "DMG creato con diskutil image create"
else
  echo "diskutil image create non riuscito: ripiego su hdiutil create" >&2
  rm -f "$DMG"
  make_dmg_old
fi
# Controllo del risultato: l'immagine deve essere valida e contenere app, collegamento Applications e READ ME.
hdiutil verify "$DMG" >/dev/null
MNT="$(mktemp -d)"
# Montaggio e smontaggio con i comandi nuovi (`hdiutil attach/detach` sono deprecati); se non riescono si ripiega sui vecchi.
if diskutil image attach --readOnly --mountOptions nobrowse --mountPoint "$MNT" "$DMG" >/dev/null; then
  unmount_dmg() { diskutil eject "$MNT" >/dev/null; }
else
  hdiutil attach "$DMG" -readonly -nobrowse -noverify -mountpoint "$MNT" >/dev/null
  unmount_dmg() { hdiutil detach "$MNT" >/dev/null; }
fi
ls "$MNT"
for item in "Music Manager.app" "Applications" "READ ME.txt"; do
  [ -e "$MNT/$item" ] || [ -L "$MNT/$item" ] || { echo "Manca nel DMG: $item"; unmount_dmg; exit 1; }
done
unmount_dmg
rmdir "$MNT" 2>/dev/null || true
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Pronto: $DMG"
