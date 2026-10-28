#!/bin/bash
# Uso: Scripts/verify-bundle.sh "/percorso/Music Manager.app"
set -euo pipefail
APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"   # percorso assoluto (defaults read lo richiede)
EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist")"
fail=0
for f in "$EXE" "$APP"/Contents/Frameworks/*.dylib; do
  if otool -L "$f" | tail -n +2 | grep -E "/opt/homebrew|/usr/local" ; then
    echo "ERRORE: riferimento a Homebrew in $f"; fail=1
  fi
done
# Versione minima di macOS delle librerie incorporate: non oltre quella dell'app (26.0), altrimenti su macOS 26 non si caricano.
MAXMIN="26.0"
for f in "$APP"/Contents/Frameworks/*.dylib; do
  [ -e "$f" ] || continue
  min="$(vtool -show-build "$f" 2>/dev/null | awk '$1=="minos"{print $2; exit}')"
  if [ -n "$min" ] && [ "$(printf '%s\n%s\n' "$min" "$MAXMIN" | sort -V | tail -1)" != "$MAXMIN" ]; then
    echo "ERRORE: $(basename "$f") richiede macOS $min (massimo $MAXMIN)"; fail=1
  fi
done
lipo -archs "$EXE" | grep -q arm64 || { echo "ERRORE: manca arm64"; fail=1; }
codesign --verify --deep --strict "$APP" || { echo "ERRORE: firma non valida"; fail=1; }
[ -f "$APP/Contents/Resources/THIRD-PARTY-LICENSES.txt" ] || { echo "ERRORE: licenze mancanti"; fail=1; }
[ $fail -eq 0 ] && echo "Bundle OK"
exit $fail
