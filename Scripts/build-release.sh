#!/bin/bash
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
DMG="build/MusicManager-$VER.dmg"
rm -f "$DMG"
hdiutil create -volname "Music Manager" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Pronto: $DMG"
