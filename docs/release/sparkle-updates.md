# Sparkle Updates

Lungfish uses Sparkle for graphical macOS updates. The app does not poll
GitHub's `/releases/latest` endpoint because GitHub defines that endpoint as
the latest non-prerelease, non-draft release. Alpha builds use a fixed Sparkle
feed instead:

`https://github.com/dhoconno/lungfish-genome-explorer/releases/download/sparkle-alpha/appcast-alpha.xml`

The `sparkle-alpha` GitHub release is a mutable feed container. Each real app
version still gets its own versioned prerelease tag, for example
`v0.4.0-alpha.12`, with the notarized DMG attached there. The appcast points at
those versioned DMG assets.

## One-Time Setup

1. Download the matching Sparkle release tools and run `generate_keys`.
2. Store the printed public key as `LUNGFISH_SPARKLE_PUBLIC_ED_KEY`.
3. Keep the private EdDSA key in the signing machine's login Keychain.
   For unattended release runs, export it to a temporary mode-0600 file with
   `generate_keys -x /path/to/private-key.txt` and pass that file with
   `--sparkle-ed-key-file`; delete the file after the release.
4. Authenticate GitHub CLI with release permissions: `gh auth login`.

Sparkle's public key is injected during release archive builds. Development
builds leave the key empty, which keeps the menu item present but disabled.

## Release Flow

```bash
export LUNGFISH_SPARKLE_PUBLIC_ED_KEY="<base64 public key from generate_keys>"

bash scripts/release/build-notarized-dmg.sh \
  --signing-identity "Developer ID Application: Example (TEAMID)" \
  --team-id TEAMID \
  --notary-profile PROFILE \
  --github-release-tag "v0.4.0-alpha.12" \
  --sparkle-generate-appcast "/path/to/Sparkle/bin/generate_appcast" \
  --sparkle-ed-key-file "/path/to/private-key.txt" \
  --sparkle-publish-release "sparkle-alpha"
```

The script sets `CFBundleVersion` from `git rev-list --count HEAD` unless
`LUNGFISH_BUILD_NUMBER` is set. Every shipped update must have a greater
`CFBundleVersion` than the previous shipped build, regardless of the marketing
version string.

The script uploads the notarized DMG to the versioned GitHub prerelease, then
generates `appcast-alpha.xml` and uploads that feed to the fixed
`sparkle-alpha` release. Release notes are copied from
`docs/release-notes/v<version>.md` when present.
