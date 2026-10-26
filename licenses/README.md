# Licenses

**Music Manager** — Copyright (C) 2026 Riccardo Colaiori (cr.developer)
Released under the **GNU General Public License v3.0** (see `../LICENSE`).

## Third-party libraries bundled in the app
| Library | License | Source |
|---|---|---|
| libmtp | LGPL 2.1 or later | https://github.com/libmtp/libmtp |
| libusb | LGPL 2.1 or later | https://github.com/libusb/libusb |

The LGPL 2.1 text is in `LGPL-2.1.txt`. The libraries are separate `.dylib` files in `Music Manager.app/Contents/Frameworks` and can be replaced with your own build. The bundled versions are those installed by Homebrew at build time (`brew list --versions libmtp libusb`) and are listed in each release's notes and in `Music Manager.app/Contents/Resources/BUNDLED-LIBS.txt`.

## Trademarks
Garmin, Apple, Apple Music and iTunes are trademarks of their respective owners. This project is not affiliated with or endorsed by Garmin or Apple.
