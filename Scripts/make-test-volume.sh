#!/bin/bash
# Crea e monta un disco di prova FAT32 (immagine disco) per provare il riconoscimento dei dispositivi Garmin come volume.
# Uso: Scripts/make-test-volume.sh music|nomusic|notgarmin|badxml
#   music      Garmin finto che dichiara MEDIA_TRACK (musica supportata)  -> atteso: riconosciuto, senza capsula "No music"
#   nomusic    Garmin finto senza MEDIA_TRACK (come un Edge)              -> atteso: riconosciuto, con capsula "No music"
#   notgarmin  disco senza Garmin/GarminDevice.xml                       -> atteso: ignorato
#   badxml     GarminDevice.xml con radice sbagliata                     -> atteso: ignorato
# Per smontare: Espelli dall'app, oppure `hdiutil detach /Volumes/<nome>`. Le immagini sono in ~/Desktop/MM-test-*.dmg
set -euo pipefail
MODE="${1:-}"
case "$MODE" in music|nomusic|notgarmin|badxml) ;; *) sed -n 2,9p "$0"; exit 1;; esac
NAME="MMTEST_${MODE}"
IMG="$HOME/Desktop/MM-test-${MODE}.dmg"
rm -f "$IMG"
hdiutil create -size 128m -fs "MS-DOS FAT32" -volname "$NAME" "$IMG" >/dev/null
hdiutil attach "$IMG" >/dev/null
VOL="/Volumes/$NAME"
NS='xmlns="http://www.garmin.com/xmlschemas/GarminDevice/v2"'
HEAD="<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
MODEL="<Model><PartNumber>000-TEST-00</PartNumber><SoftwareVersion>100</SoftwareVersion><Description>Test ${MODE} volume</Description></Model><Id>0</Id>"
case "$MODE" in
  music)
    mkdir -p "$VOL/Garmin" "$VOL/Music"
    echo "${HEAD}<Device ${NS}>${MODEL}<MassStorageMode><DataType><Name>MEDIA_TRACK</Name><File><Specification><Identifier>MP3</Identifier></Specification><Location><Path>Music</Path><FileExtension>mp3</FileExtension></Location><TransferDirection>InputToUnit</TransferDirection></File></DataType></MassStorageMode></Device>" > "$VOL/Garmin/GarminDevice.xml";;
  nomusic)
    mkdir -p "$VOL/Garmin"
    echo "${HEAD}<Device ${NS}>${MODEL}<MassStorageMode><DataType><Name>FITBinary</Name><File><Specification><Identifier>FIT</Identifier></Specification><Location><Path>Garmin</Path><FileExtension>FIT</FileExtension></Location><TransferDirection>InputOutput</TransferDirection></File></DataType></MassStorageMode></Device>" > "$VOL/Garmin/GarminDevice.xml";;
  notgarmin)
    mkdir -p "$VOL/Documents"; echo "niente da vedere" > "$VOL/Documents/note.txt";;
  badxml)
    mkdir -p "$VOL/Garmin"; echo "${HEAD}<Other><Model><Description>Not a Garmin</Description></Model></Other>" > "$VOL/Garmin/GarminDevice.xml";;
esac
echo "Montato: $VOL  (l'app lo rileva entro un paio di secondi)"
