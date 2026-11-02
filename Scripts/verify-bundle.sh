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
