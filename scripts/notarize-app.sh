#!/bin/bash
set -euo pipefail
APP="${1:?Usage: notarize-app.sh path/to/App.app}"
: "${SIGNING_IDENTITY:?Developer ID signing identity is required}"
: "${NOTARY_KEYCHAIN:?Notarization credential keychain is required}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/commander-notarize.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/submission.zip"
bash "$(dirname "$0")/notarize-artifact.sh" "$WORK/submission.zip" "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
