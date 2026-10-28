#!/bin/bash
# Incorpora libmtp, libusb (e dipendenze Homebrew) in Contents/Frameworks, riscrive i percorsi con @rpath e firma ad hoc.
# Eseguito come Run Script di Xcode (usa TARGET_BUILD_DIR, FULL_PRODUCT_NAME, EXECUTABLE_NAME).
set -euo pipefail

APP="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
EXE="${APP}/Contents/MacOS/${EXECUTABLE_NAME}"
FW="${APP}/Contents/Frameworks"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -z "$IDENTITY" ] && IDENTITY="-"
BREW="${HOMEBREW_PREFIX:-/opt/homebrew}"

mkdir -p "$FW"

# Versione minima di macOS dell'app. Le librerie Homebrew compilate su un macOS più recente (es. 27) dichiarano quella come
# minima e su un macOS più vecchio (es. 26) non si caricherebbero ("built for macOS 27.0 which is newer than running OS"):
# si riporta la loro versione minima a quella dell'app (solo metadati; la firma si rifà più sotto).
TARGET_MIN="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
retarget_minos() {
  local f="$1" info min sdk
  info="$(vtool -show-build "$f" 2>/dev/null || true)"
  min="$(echo "$info" | awk '$1=="minos"{print $2; exit}')"
  sdk="$(echo "$info" | awk '$1=="sdk"{print $2; exit}')"
  [ -z "$min" ] && return 0
  if [ "$(printf '%s\n%s\n' "$min" "$TARGET_MIN" | sort -V | tail -1)" != "$TARGET_MIN" ]; then
    echo "Libreria $(basename "$f"): minima macOS $min -> $TARGET_MIN"
    vtool -set-build-version macos "$TARGET_MIN" "${sdk:-$TARGET_MIN}" -replace -output "$f.tmp" "$f" && mv -f "$f.tmp" "$f"
  fi
}

# Dipendenze non di sistema di un file Mach-O (percorsi Homebrew)
deps_of() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E "^(/opt/homebrew|/usr/local)" || true; }

copied=""
copy_lib() {
  local src real name
  src="$1"
  real="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$src")"
  name="$(basename "$real")"
  case " $copied " in *" $name "*) return;; esac
  copied="$copied $name"
  cp -f "$real" "$FW/$name"
  chmod u+w "$FW/$name"
  install_name_tool -id "@rpath/$name" "$FW/$name"
  retarget_minos "$FW/$name"
  local d
  for d in $(deps_of "$FW/$name"); do
    [ "$d" = "$real" ] && continue
    local dreal dname
    dreal="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$d")"
    dname="$(basename "$dreal")"
    copy_lib "$d"
    install_name_tool -change "$d" "@rpath/$dname" "$FW/$name"
  done
}

for d in $(deps_of "$EXE"); do
  real="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$d")"
  copy_lib "$d"
  install_name_tool -change "$d" "@rpath/$(basename "$real")" "$EXE"
done

# Firma ogni libreria (la firma finale dell'app viene fatta da Xcode subito dopo)
for f in "$FW"/*.dylib; do
  [ -e "$f" ] || continue
  codesign --force --sign "$IDENTITY" --timestamp=none "$f"
done
# Elenco delle versioni incorporate (serve per l'LGPL: indicare quale versione si distribuisce)
mkdir -p "${APP}/Contents/Resources"
{
  echo "Librerie incorporate / Bundled libraries"
  for n in libmtp libusb; do
    v="$(ls "${BREW}/Cellar/${n}" 2>/dev/null | sort -V | tail -1)"
    echo "${n} ${v:-sconosciuta/unknown}"
  done
  echo "File in Contents/Frameworks:$copied"
} > "${APP}/Contents/Resources/BUNDLED-LIBS.txt"
echo "Librerie incorporate:$copied"
