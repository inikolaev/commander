# macOS releases

Main-branch CI invokes `.github/workflows/release.yml` after its checks pass.
Release-affecting changes produce separate Apple silicon and Intel builds. You can
also run **macOS release** manually on `main`.

## Version format

Versions use `YYYY.M.build`, for example `2026.10.82`. The date comes from the
workflow creation time. Build numbers are allocated from `release-numbers.json`
on the separate **release-state** branch before any build starts. This ledger is
independent of GitHub releases, tags, and the Latest flag. Failed builds consume
a number; rerunning the same GitHub workflow run reuses its reserved number and
version. Atomic non-force Git ref updates prevent concurrent reservations from
receiving the same number. The branch's commit history provides an audit trail.

`CFBundleVersion` and Sparkle's version both contain the reserved build number.
Deleting a release or tag never decrements the ledger. Do not delete or reset the
`release-state` branch. Keep backups of that branch; if it is unavailable, publishing
fails closed instead of attempting to reconstruct the counter from release metadata.

Initialize the ledger **once**, after checking the highest number ever shipped or
reserved (including deleted/recalled releases). For this migration, build 81 is
already used and the next reservation must be at least 82:

```sh
python3 scripts/release-number.py --repo inikolaev/commander initialize --last-build 81
```

Initialization refuses to replace an existing branch. Do not run it to recover a
deleted ledger: restore the branch from its history/backup instead. The workflow's
`contents: write` permission must allow ordinary fast-forward updates on this
branch; no force pushes or changes to `main` are used for numbering.

## Release notes after a recall

Generated notes explicitly compare against the highest prior published stable
release, excluding drafts, prereleases, and releases marked as recalled. For
example, if build 81 was recalled, build 82 compares with build 80, including both
the changes introduced in 81 and the fixes in 82. Notes name recalled releases in
that interval for transparency. The old notes are not copied verbatim: GitHub
regenerates the combined change list and comparison link. Later releases resume
comparing against the latest working published release.

## Recall a broken release

In GitHub Actions, select **Recall release**, choose **Run workflow** on `main`,
and supply the exact tag (for example `v2026.10.81`) and a reason.

The workflow fetches the live Sparkle feed, removes the specified build's entries
for both architectures, temporarily makes the GitHub release a draft to hide its
downloads, and deletes all uploaded assets. After deploying the updated feed, it
publishes an asset-free **RECALLED — do not install** record with `latest=false`.
The workflow then explicitly marks the highest-build published, non-recalled
stable release as GitHub **Latest** and verifies that selection. Drafts and
prereleases are excluded. Recalling an older build keeps a newer eligible release
as Latest; if no eligible release exists, the workflow reports that in its summary
without marking a replacement. This changes GitHub's Latest link, not the Sparkle
feed's remaining entries.

The completed recall is a normal published record rather than a draft pinned at
the top of the release list. GitHub's automatic source archives may still be shown;
there are no uploaded app binaries, installers, or checksums.

Other feed entries remain intact; if none remain, clients receive a valid empty
feed. It does not automatically promote an older release in Sparkle. Release
notes and the Git tag remain for transparency. The independent ledger reserves
build numbers even if those records are later deleted.
Uploaded assets are permanently deleted; keep any forensic copies separately.

Recall, release publication, and ordinary Pages deployment share a concurrency
group so they cannot overwrite each other's feed changes while running. Ordinary
Pages deployment preserves the live feed and fails if it cannot fetch it. Recalled
records are excluded from release-note baselines and cannot receive new assets
through the release workflow. Temporary recalled drafts are excluded from cleanup.

If asset deletion or Pages deployment fails, the release stays a draft. Rerun
Recall release with the same tag to finish; already deleted assets and removed
feed entries do not block a retry. Inspect the deployed `appcast.xml`, the public
recall title, and the empty uploaded-assets list after completion. CDN/client caches may delay propagation;
a recall cannot revoke an already downloaded or installed copy. Clients whose app
crashes at startup may need to install the fixed version manually.

Publish the fix as a new, higher build. Do not delete the retained tag or manually
restore binaries to the recalled record. Deleting a GitHub release alone does not update the
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
