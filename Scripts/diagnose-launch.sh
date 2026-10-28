#!/bin/bash
# Raccoglie informazioni quando l'app non si apre / resta bloccata al primo avvio (problema macOS 27).
# Uso: bash diagnose-launch.sh ["/Applications/Music Manager.app"]
# Scrive il risultato in ~/Desktop/MusicManager-launch-diagnosis.txt (non contiene dati personali).
APP="${1:-/Applications/Music Manager.app}"
OUT="$HOME/Desktop/MusicManager-launch-diagnosis.txt"
limit() { perl -e 'alarm shift; exec @ARGV' "$@"; }   # macOS non ha "timeout"
{
echo "== Data =="; date
echo; echo "== macOS =="; sw_vers; uname -m
echo; echo "== App =="; ls -ld "$APP"
echo; echo "== Quarantena (vuoto = nessuna) =="; xattr -l "$APP" 2>&1
echo; echo "== Firma =="; limit 20 codesign --verify --deep --strict --verbose=2 "$APP" 2>&1
limit 20 codesign -dv --verbose=2 "$APP" 2>&1 | head -12
echo; echo "== Valutazione Gatekeeper (max 20 s) =="; start=$(date +%s)
limit 20 spctl --assess --type execute -vv "$APP" 2>&1; echo "exit=$? tempo=$(( $(date +%s) - start ))s"
echo; echo "== Rete verso i server Apple (max 8 s ciascuno) =="
for h in ocsp.apple.com api.apple-cloudkit.com gdmf.apple.com; do
  printf "%s -> " "$h"; curl -sS -m 8 -o /dev/null -w "%{http_code} in %{time_total}s\n" "https://$h" 2>&1
done
echo; echo "== Proxy / VPN =="; scutil --proxy 2>/dev/null | head -12; scutil --nc list 2>/dev/null | head -5
echo; echo "== Processi di Music Manager =="; ps -o pid,state,etime,command -p "$(pgrep -d, -f 'MacOS/Music Manager' )" 2>&1
echo; echo "== Registro di sistema, ultimi 15 minuti =="
log show --last 15m --info --style compact \
  --predicate 'process IN {"syspolicyd","amfid","trustd","taskgated","kernel"} AND (eventMessage CONTAINS[c] "Music Manager" OR eventMessage CONTAINS[c] "crdev")' 2>&1 | tail -80
} > "$OUT" 2>&1
echo "Fatto: $OUT"
