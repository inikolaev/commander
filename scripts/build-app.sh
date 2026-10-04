#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-2}"
ARCH="${1:-$(uname -m)}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    printf 'APP_VERSION must contain three integers; APP_BUILD_NUMBER must be an integer.\n' >&2
    exit 2
fi
if [[ "$ARCH" != arm64 && "$ARCH" != x86_64 ]]; then
    printf 'Usage: %s [arm64|x86_64]\n' "$0" >&2
    exit 2
fi

BUILD_ARGS=(-c release --arch "$ARCH")
APP="dist/$ARCH/Commander.app"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Assets/Commander.icns "$APP/Contents/Resources/Commander.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"
cp "$BIN_DIR/Commander" "$APP/Contents/MacOS/Commander"
SPARKLE_FRAMEWORK=$(find .build/artifacts -type d -name Sparkle.framework -print -quit)
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "Sparkle.framework was not found in SwiftPM artifacts" >&2
    exit 1
fi
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>Commander</string>
    <key>CFBundleIdentifier</key><string>local.commander.filemanager</string>
    <key>CFBundleName</key><string>Commander</string>
    <key>CFBundleDisplayName</key><string>Commander</string>
    <key>CFBundleIconFile</key><string>Commander.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$APP_BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key><string>https://inikolaev.github.io/commander/appcast.xml</string>
    <key>SUPublicEDKey</key><string>XB/GxXy5jYTCKmNWcaEju+anDChdM3GfowpPI7Xa5FY=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAllowsAutomaticUpdates</key><false/>
</dict></plist>
PLIST
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$SIGNING_IDENTITY" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE/Versions/B/Updater.app"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
    codesign --force --options runtime --sign - "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
    codesign --force --options runtime --preserve-metadata=entitlements --sign - "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --options runtime --sign - "$SPARKLE/Versions/B/Autoupdate"
    codesign --force --options runtime --sign - "$SPARKLE/Versions/B/Updater.app"
    codesign --force --options runtime --sign - "$SPARKLE"
    codesign --force --sign - "$APP"
fi
printf 'Built %s for %s\n' "$APP" "$ARCH"
