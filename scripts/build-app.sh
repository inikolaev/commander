#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-2}"
ARCH="${1:-$(uname -m)}"
CONFIGURATION="${CONFIGURATION:-debug}"
case "$CONFIGURATION" in
    debug)
        BUNDLE_ID="io.github.inikolaev.commander.debug"
        DISPLAY_NAME="Commander [DEBUG]"
        AUTOMATIC_UPDATE_CHECKS=false
        ;;
    release)
        BUNDLE_ID="io.github.inikolaev.commander"
        DISPLAY_NAME="Commander"
        AUTOMATIC_UPDATE_CHECKS=true
        ;;
    *)
        printf 'CONFIGURATION must be debug or release.\n' >&2
        exit 2
        ;;
esac
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    printf 'APP_VERSION must contain three integers; APP_BUILD_NUMBER must be an integer.\n' >&2
    exit 2
fi
if [[ "$ARCH" != arm64 && "$ARCH" != x86_64 ]]; then
    printf 'Usage: %s [arm64|x86_64]\n' "$0" >&2
    exit 2
fi

BUILD_ARGS=(-c "$CONFIGURATION" --arch "$ARCH")
APP="dist/$ARCH/Commander.app"
# SwiftPM can regenerate accessors during planning. Patch only at the compiler
# boundary, after planning, so the compiled code always uses Contents/Resources.
export COMMANDER_REAL_SWIFTC="$(xcrun --find swiftc)"
export SWIFT_EXEC="$PWD/scripts/app-swiftc.py"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Assets/Commander.icns "$APP/Contents/Resources/Commander.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"
cp "$BIN_DIR/Commander" "$APP/Contents/MacOS/Commander"
# Include both Commander’s shell hooks and Ghostty’s runtime resources.
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
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
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleIconFile</key><string>Commander.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>$APP_BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key><string>https://inikolaev.github.io/commander/appcast.xml</string>
    <key>SUPublicEDKey</key><string>XB/GxXy5jYTCKmNWcaEju+anDChdM3GfowpPI7Xa5FY=</string>
    <key>SUEnableAutomaticChecks</key><$AUTOMATIC_UPDATE_CHECKS/>
    <key>SUAllowsAutomaticUpdates</key><false/>
</dict></plist>
PLIST
if [[ "${SIGN_APP:-1}" == 1 ]]; then
    bash scripts/sign-app.sh "$APP"
fi
# Exercise the actual packaged accessors, rejecting build-directory fallbacks.
if [[ "${SIGN_APP:-1}" == 1 && "$ARCH" == "$(uname -m)" ]]; then
    "$APP/Contents/MacOS/Commander" --verify-bundled-resources
fi
printf 'Built %s for %s (%s)\n' "$APP" "$ARCH" "$CONFIGURATION"
