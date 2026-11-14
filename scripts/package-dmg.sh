#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${1:-$(uname -m)}"
if [[ "$ARCH" != arm64 && "$ARCH" != x86_64 ]]; then
    printf 'Usage: %s [arm64|x86_64]\n' "$0" >&2
    exit 2
fi
case "${CONFIGURATION:-debug}" in
    debug) APP_BASENAME="Commander [DEBUG].app" ;;
    release) APP_BASENAME="Commander.app" ;;
    *) printf 'CONFIGURATION must be debug or release.\n' >&2; exit 2 ;;
esac
APP="dist/$ARCH/$APP_BASENAME"
if [[ ! -d "$APP" ]]; then
    echo "Expected packaged app at $APP" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$PWD/dist/Commander-$VERSION-macOS-$ARCH.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/commander-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/$APP_BASENAME"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Commander" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

if [[ "${NOTARIZE:-0}" == 1 ]]; then
    bash scripts/notarize-dmg.sh "$DMG"
fi
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
printf 'Packaged %s\n' "$DMG"
