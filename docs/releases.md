# macOS releases

Main-branch CI invokes `.github/workflows/release.yml` after its checks pass.
Release-affecting changes produce separate Apple silicon and Intel builds. You can
also run **macOS release** manually on `main`.

## Version format

Versions use `YYYY.M.build`, for example `2026.10.82`. The date comes from the
workflow creation time. The build number is one greater than the largest release
build found in Git tags, including tags belonging to recalled or deleted releases.
Keep release tags permanently: they reserve build numbers already distributed to
clients. `CFBundleVersion` and Sparkle's version both contain that build number.

## Recall a broken release

In GitHub Actions, select **Recall release**, choose **Run workflow** on `main`,
and supply the exact tag (for example `v2026.10.81`) and a reason.

The workflow fetches the live Sparkle feed, removes the specified build's entries
for both architectures, converts the GitHub release to a draft, and deploys the
updated feed to GitHub Pages. Other feed entries remain intact; if none remain,
clients receive a valid empty feed. It does not automatically promote an older
release. Release assets, notes, and the Git tag are retained for audit and recovery.
Public downloads stop being available when the release becomes a draft.

Recall, release publication, and ordinary Pages deployment share a concurrency
group so they cannot overwrite each other's feed changes while running. Ordinary
Pages deployment preserves the live feed and fails if it cannot fetch it. Recalled
drafts are excluded from cleanup and cannot be republished by the release workflow.

If withdrawal succeeds but Pages deployment fails, rerun Recall release with the
same tag. Feed removal is idempotent. Inspect the deployed `appcast.xml` and the
release's draft status after completion. CDN/client caches may delay propagation;
a recall cannot revoke an already downloaded or installed copy. Clients whose app
crashes at startup may need to install the fixed version manually.

Publish the fix as a new, higher build. Do not delete the retained tag or manually
republish the recalled draft. Deleting a GitHub release alone does not update the
static Sparkle feed. This workflow must first be merged into `main` to be available.

## Local packaging

```sh
APP_VERSION=2026.9.42 APP_BUILD_NUMBER=42 bash scripts/package-app.sh
```

Local builds default to development version `0.1.0`, build `2`. Packaging creates
`dist/Commander-2026.9.42-macOS-universal.zip` and the matching `.zip.sha256` file.
After downloading both release assets into one directory, verify with:

```sh
shasum -a 256 -c Commander-2026.9.42-macOS-universal.zip.sha256
```

## Runner and signing

The workflow uses `macos-15` and Xcode 26.2 (Swift 6.2 or newer), including Apple's
cross-compilation tools for Intel. The release job uses these repository secrets:

- `APPLE_CERTIFICATE_P12_BASE64`: Base64-encoded Developer ID Application certificate and private key (.p12).
- `APPLE_CERTIFICATE_PASSWORD`: Password protecting the .p12 export.
- `APPLE_ID`: Apple Account email used for notarization.
- `APPLE_TEAM_ID`: Apple Developer team ID.
- `APPLE_APP_SPECIFIC_PASSWORD`: App-specific password for notarization.

The certificate is imported into a temporary keychain and selected by its signing
identity hash. The workflow signs with Hardened Runtime and a secure timestamp,
submits the app to Apple, waits up to 40 minutes for acceptance, staples the ticket,
and checks both the ticket and Gatekeeper assessment before creating the final ZIP.
The checksum covers this final stapled archive. Missing credentials, failed signing,
or unsuccessful notarization block publication. The keychain and exported certificate
are removed with an always-run cleanup step.

The submission ID is recorded in the job log and summary for troubleshooting.
If Apple takes longer than the wait limit, the job fails without publishing; the
submission remains in Apple's notarization history. A workflow retry submits again.
Local builds remain ad-hoc signed by default. `SIGNING_IDENTITY` enables Developer ID
signing; `NOTARIZE=1` additionally requires `NOTARY_KEYCHAIN` with the
`commander-notary` credential profile. Never commit certificates or credentials.
