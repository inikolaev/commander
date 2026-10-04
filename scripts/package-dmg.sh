#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${1:-$(uname -m)}"
if [[ "$ARCH" != arm64 && "$ARCH" != x86_64 ]]; then
    printf 'Usage: %s [arm64|x86_64]\n' "$0" >&2
    exit 2
fi
APP="dist/$ARCH/Commander.app"
if [[ ! -d "$APP" ]]; then
    echo "Expected packaged app at $APP" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$PWD/dist/Commander-$VERSION-macOS-$ARCH.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/commander-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Commander.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Commander" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

if [[ "${NOTARIZE:-0}" == 1 ]]; then
    : "${NOTARY_KEYCHAIN:?Notarization credential keychain is required}"
    result=$(xcrun notarytool submit "$DMG" --keychain-profile commander-notary \
        --keychain "$NOTARY_KEYCHAIN" --wait --timeout 40m --output-format json)
    submission=$(jq -er .id <<<"$result")
    status=$(jq -r .status <<<"$result")
    printf 'Apple DMG notarization submission: %s\n' "$submission"
    if [[ "$status" != Accepted ]]; then
        echo "DMG notarization was not accepted: $status" >&2
        xcrun notarytool log "$submission" --keychain-profile commander-notary --keychain "$NOTARY_KEYCHAIN" || true
        exit 1
    fi
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
printf 'Packaged %s\n' "$DMG"
