#!/bin/bash
set -euo pipefail
DMG="${1:?Usage: notarize-dmg.sh path/to/image.dmg}"
bash "$(dirname "$0")/notarize-artifact.sh" "$DMG" "$DMG"
# Stapling changes the image; always checksum the final bytes.
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
