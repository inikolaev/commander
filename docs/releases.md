# macOS releases

Every push to `main` runs `.github/workflows/release.yml`. It tests the project,
builds separate Release executables for arm64 and x86_64, packages
`Commander.app`, verifies its signature and architectures, and publishes a GitHub
Release with the ZIP and a SHA-256 checksum. You can also run **macOS release**
manually from GitHub Actions on `main`. Failed tests/builds do not publish a release.

## Version format

Versions use `YYYY.M.build`, for example `2026.9.42`. The year and month come from
the original workflow creation date in UTC. The final number is GitHub's increasing
run number for this workflow; it does not reset each month or year. Failed runs may
leave gaps. This is calendar versioning, not a semantic compatibility promise.

The version appears in `CFBundleShortVersionString`, the archive filename, the
release title, and its Git tag (`v2026.9.42`). `CFBundleVersion` holds the run number.
Tags associate each release with its exact source commit. GitHub Actions maintains
the counter, so no bot commits or manually updated version file are needed.
Keep this workflow's identity/history to retain its counter.

Re-running an existing workflow keeps its version. Publication uses a draft until
both assets are uploaded; a retry can finish a draft. Already published releases
are left unchanged. Use a new manual run to create another release of the same
commit. Concurrent runs use distinct versions; no push is canceled to make way
for a newer push.

## Local packaging

```sh
CONFIGURATION=release APP_VERSION=2026.9.42 APP_BUILD_NUMBER=42 bash scripts/package-app.sh arm64
```

Local builds default to Debug, development version `0.1.0`, build `2`.
Debug uses `io.github.inikolaev.commander.debug`, displays as `Commander [DEBUG]`,
and disables the updater. `CONFIGURATION=release` selects optimized compilation
and the production identifier `io.github.inikolaev.commander`; the release workflow
sets this explicitly. PR previews use Debug. No preference migration or cleanup runs.
Both configurations write to `dist/<architecture>/Commander.app`.
The command above creates `dist/Commander-2026.9.42-macOS-arm64.zip`
and the matching `.zip.sha256` file.
After downloading both release assets into one directory, verify with:

```sh
shasum -a 256 -c Commander-2026.9.42-macOS-arm64.zip.sha256
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
