# Sparkle Updates

Lungfish uses Sparkle for graphical macOS updates. The app does not poll
GitHub's `/releases/latest` endpoint because GitHub defines that endpoint as
the latest non-prerelease, non-draft release. Beta builds use a fixed Sparkle
feed instead:

`https://github.com/dhoconno/lungfish-genome-explorer/releases/download/sparkle-beta/appcast-beta.xml`

The `sparkle-beta` GitHub release is a mutable feed container. Each real app
version still gets its own versioned prerelease tag, for example
`v0.5.0-beta2`, with the notarized DMG attached there. The appcast points at
those versioned DMG assets.

Legacy alpha builds before `0.5.0-beta1` still read:

`https://github.com/dhoconno/lungfish-genome-explorer/releases/download/sparkle-alpha/appcast-alpha.xml`

To migrate those users automatically, publish the same signed beta appcast item
to `sparkle-alpha` as `appcast-alpha.xml`. After users install the beta app,
the app bundle's `SUFeedURL` points at the beta feed for subsequent updates.

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
  --github-release-tag "v0.5.0-beta2" \
  --sparkle-generate-appcast "/path/to/Sparkle/bin/generate_appcast" \
  --sparkle-ed-key-file "/path/to/private-key.txt" \
  --sparkle-publish-release "sparkle-beta" \
  --sparkle-bridge-publish-release "sparkle-alpha" \
  --sparkle-bridge-appcast-filename "appcast-alpha.xml"
```

The script sets `CFBundleVersion` from `git rev-list --count HEAD` unless
`LUNGFISH_BUILD_NUMBER` is set. Every shipped update must have a greater
`CFBundleVersion` than the previous shipped build, regardless of the marketing
version string.

The script uploads the notarized DMG to the versioned GitHub prerelease, then
generates `appcast-beta.xml` and uploads that feed to the fixed
`sparkle-beta` release. Release notes are copied from
`docs/release-notes/v<version>.md` when present.

When `--sparkle-bridge-publish-release sparkle-alpha` is set, the script also
copies that generated beta appcast item to `appcast-alpha.xml` on the legacy
alpha feed. The beta app still embeds the beta `SUFeedURL`; the bridge feed only
exists to let old alpha installations discover the beta update once.
