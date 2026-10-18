#!/bin/bash
set -euo pipefail
APP="${1:?Usage: sign-app.sh path/to/App.app}"
source "$(dirname "$0")/apple-network-retry.sh"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    retry_apple_network codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    retry_apple_network codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$SIGNING_IDENTITY" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    retry_apple_network codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
    retry_apple_network codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE/Versions/B/Updater.app"
    retry_apple_network codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE"
    retry_apple_network codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
    retry_apple_network codesign --force --options runtime --sign - "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    retry_apple_network codesign --force --options runtime --preserve-metadata=entitlements --sign - "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    retry_apple_network codesign --force --options runtime --sign - "$SPARKLE/Versions/B/Autoupdate"
    retry_apple_network codesign --force --options runtime --sign - "$SPARKLE/Versions/B/Updater.app"
    retry_apple_network codesign --force --options runtime --sign - "$SPARKLE"
    retry_apple_network codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
