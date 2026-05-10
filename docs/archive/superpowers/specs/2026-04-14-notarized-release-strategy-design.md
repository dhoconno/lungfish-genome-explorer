# Notarized Release Strategy Design

Date: 2026-04-14
Status: Auto-approved

## Scope

This design adds a reproducible Apple Silicon release pipeline for Lungfish that:

- archives the app from the Xcode project
- embeds `lungfish-cli` inside `Lungfish.app`
- signs and notarizes the app bundle
- builds a distributable `.dmg`
- signs and notarizes the `.dmg`
- records release metadata in `build/Release`

It also updates the committed repo agent so future runs follow the same workflow.

## Goals

- Produce a clean `arm64` release artifact that runs on other Macs without Gatekeeper warnings after notarization.
- Ship the GUI and CLI together in one signed app bundle.
- Keep the release layout deterministic so future agents can rebuild it without rediscovering paths.
- Validate the packaged native tools before notarization is reported as successful.

## Non-Goals

- Universal or Intel release support.
- Replacing the existing Xcode archive flow with a SwiftPM-only app packager.
- Changing the bundled tool set beyond the existing sanitizer and smoke-test coverage.

## Design

### 1. Archive-Centered Release Flow

Use `xcodebuild archive` as the source of truth for the GUI app. The archive is created in `build/Release/Lungfish.xcarchive` with `arm64`-only build settings.

The release candidate app is:

`build/Release/Lungfish.xcarchive/Products/Applications/Lungfish.app`

### 2. Embedded CLI

Build `lungfish-cli` from the package with SwiftPM using a dedicated scratch path, then install it into:

`Lungfish.app/Contents/MacOS/lungfish-cli`

Sign the CLI first with the tracked entitlements.

### 2a. Inner-Tool Signing (required for notarization)

Before re-signing the outer app bundle, walk every Mach-O file under

`Lungfish.app/Contents/Resources/LungfishGenomeBrowser_LungfishWorkflow.bundle/Contents/Resources/Tools/`

and sign each one individually with
`codesign --force --options runtime --timestamp`.

Why this exists: Apple's `codesign --deep` is deprecated and does not recurse
into nested resource bundles, so bundled third-party binaries (samtools,
tabix, bcftools, cutadapt, fastp, pigz, bgzip, vsearch, seqkit, micromamba,
bedToBigBed, bedGraphToBigWig, `sra-tools/{fasterq-dump,prefetch}`,
`scrubber/bin/aligns_to`, `bbtools/jni/libbbtoolsjni.dylib`) retain their
upstream ad-hoc signatures and cause notarization to fail
`status: Invalid` with per-tool errors:
"not signed with a valid Developer ID certificate",
"signature does not include a secure timestamp",
"executable does not have the hardened runtime enabled".

The outer bundle is then signed without `--deep` so the inner signatures
survive intact.

### 3. App Verification And Notarization

Before notarization:

- run `codesign --verify --deep --strict`
- run `scripts/smoke-test-release-tools.sh` against the archived app

`notarytool submit` does not accept `.app` bundles directly (it requires
`.zip`, `.pkg`, or `.dmg`). Wrap the signed app with
`ditto -c -k --keepParent` into a throwaway ZIP, submit the ZIP, wait for
completion, and staple the **original `.app`** (stapling keys off the
code-signing hash, not the archive format). The throwaway ZIP is then
deleted.

`notarytool submit --wait` exits 0 for any terminal status including
`Invalid`, so the script treats `Invalid` the same as any other failure and
downstream steps (`stapler staple`) will fail visibly. The next diagnostic
step is always:

`xcrun notarytool log <id-from-notary-app-log.json> --keychain-profile <profile>`

### 4. DMG Packaging

Create a simple distribution image containing:

- `Lungfish.app`
- an `Applications` symlink

Then sign the `.dmg`, submit it directly to `notarytool` (DMGs are accepted
as-is, no ZIP wrapper needed), wait for completion, and staple it.

The final artifact is:

`build/Release/Lungfish-<version>-arm64.dmg`

### 5. Reproducibility Metadata

Write `build/Release/release-metadata.txt` containing:

- app version
- git commit
- redacted signing identity, team ID, and notary profile placeholders
- relative archive/app/dmg paths
- SHA-256 of the final `.dmg`
- relative notary output log paths

## Inputs

The release script requires explicit command-line inputs for:

- `--signing-identity`
- `--team-id`
- `--notary-profile`

This avoids hidden local defaults while still using the already-configured Keychain profile.

## Release-machine values

The release flow requires a locally installed Developer ID Application
certificate and a `notarytool` Keychain profile on the release machine. Do not
commit Apple IDs, app-specific passwords, Keychain profile names, or private key
material.

| Input                | Value                                          | Source of truth                                     |
|----------------------|------------------------------------------------|-----------------------------------------------------|
| `--signing-identity` | `<DEVELOPER_ID_APPLICATION_IDENTITY>`           | `security find-identity -v -p codesigning`          |
| `--team-id`          | `<TEAMID>`                                     | Parenthesized suffix in the certificate Common Name |
| `--notary-profile`   | `<KEYCHAIN_PROFILE_NAME>`                      | `notarytool store-credentials` Keychain profile     |

Canonical invocation:

```
bash scripts/release/build-notarized-dmg.sh \
  --team-id "<TEAMID>" \
  --notary-profile "<KEYCHAIN_PROFILE_NAME>" \
  --signing-identity "<DEVELOPER_ID_APPLICATION_IDENTITY>"
```

The signing identity may be a certificate common name or SHA-1 fingerprint; it
is an identifier, not private key material. The only secret involved is the
notarization credential bound to the Keychain profile on the release machine.
Credentials for that profile are established once via:

```
xcrun notarytool store-credentials "<KEYCHAIN_PROFILE_NAME>" \
  --apple-id <apple-id> \
  --team-id "<TEAMID>" \
  --password <app-specific-password>
```

If the Developer ID certificate is renewed, revoked, or replaced, update local
release-machine configuration and the
corresponding `.codex/agents/release-agent.md` entry, and re-run the canonical
invocation to verify.

## Testing

Add release-configuration tests that require:

- a committed `scripts/release/build-notarized-dmg.sh`
- archive, embedded CLI, `notarytool`, `stapler`, and `hdiutil` steps in that script
- a committed repo agent that points to the release script rather than the older export-only flow

Manual verification then attempts the real release command and confirms the resulting app and `.dmg` paths.
