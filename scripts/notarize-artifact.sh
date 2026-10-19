#!/bin/bash
set -euo pipefail
PAYLOAD="${1:?Usage: notarize-artifact.sh submission-file staple-target}"
TARGET="${2:?A staple target is required}"
: "${NOTARY_KEYCHAIN:?Notarization credential keychain is required}"
source "$(dirname "$0")/apple-network-retry.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/commander-notary.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# Submit once: a lost response could still mean Apple accepted the upload.
xcrun notarytool submit "$PAYLOAD" --keychain-profile commander-notary \
    --keychain "$NOTARY_KEYCHAIN" --output-format json > "$WORK/submission.json"
submission=$(jq -er .id "$WORK/submission.json")
printf 'Apple notarization submission: %s (%s)\n' "$submission" "$TARGET"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf 'Apple notarization submission: `%s` (%s)\n' "$submission" "$TARGET" >> "$GITHUB_STEP_SUMMARY"
fi
# Retry waiting on the same submission, never upload it again on a wait failure.
if ! retry_apple_network xcrun notarytool wait "$submission" --keychain-profile commander-notary \
    --keychain "$NOTARY_KEYCHAIN" --timeout 10m --output-format json > "$WORK/result.json"; then
    echo "Notarization wait failed; submission $submission remains available in Apple's history." >&2
    xcrun notarytool log "$submission" --keychain-profile commander-notary --keychain "$NOTARY_KEYCHAIN" || true
    exit 1
fi
status=$(jq -r .status "$WORK/result.json")
if [[ "$status" != Accepted ]]; then
    echo "Notarization was not accepted: $status" >&2
    xcrun notarytool log "$submission" --keychain-profile commander-notary --keychain "$NOTARY_KEYCHAIN" || true
    exit 1
fi
retry_apple_network xcrun stapler staple "$TARGET"
retry_apple_network xcrun stapler validate "$TARGET"
