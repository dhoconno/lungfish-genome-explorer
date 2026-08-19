# Sparkle Updates

Lungfish uses Sparkle for graphical macOS updates. The app does not poll
GitHub's `/releases/latest` endpoint because GitHub defines that endpoint as
the latest non-prerelease, non-draft release. Preview builds use a fixed
Sparkle feed instead:

`https://github.com/dhoconno/lungfish-genome-explorer/releases/download/sparkle-beta/appcast-beta.xml`

The compatibility-named `sparkle-beta` GitHub release is the mutable preview
feed container. Each real app version gets a canonical CalVer tag such as
`v2026.8.1`, with the notarized DMG attached there. Version strings never carry
alpha, beta, preview, or stable suffixes; channel status belongs to the feed and
GitHub release state. The appcast points at those versioned DMG assets.

Legacy alpha builds before `0.5.0-beta1` still read:

`https://github.com/dhoconno/lungfish-genome-explorer/releases/download/sparkle-alpha/appcast-alpha.xml`

To migrate those users automatically, publish the same signed preview appcast item
to `sparkle-alpha` as `appcast-alpha.xml`. After users install the current app,
the app bundle's `SUFeedURL` points at the preview feed for subsequent updates.

New versions use `YYYY.M.PATCH`. Capture the release machine's local date once,
then increment the highest patch for that year/month found across remote Git
tags and GitHub releases; a new month starts at `1`. Month and patch components
have no leading zeroes. A future stable channel should use a separate appcast;
the repository does not currently configure one.

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
  --github-release-tag "v2026.8.1" \
  --sparkle-generate-appcast "/path/to/Sparkle/bin/generate_appcast" \
  --sparkle-ed-key-file "/path/to/private-key.txt" \
  --sparkle-publish-release "sparkle-beta" \
  --sparkle-bridge-publish-release "sparkle-alpha" \
  --sparkle-bridge-appcast-filename "appcast-alpha.xml"
```

The script sets `CFBundleVersion` from `git rev-list --count HEAD` unless
`LUNGFISH_BUILD_NUMBER` is set. Every shipped update must have a greater
`CFBundleVersion` than the previous shipped build, regardless of the marketing
version string. The script fetches the live preview appcast and enforces this
before building.

For direct publication, push the annotated `v<version>` tag first. The release
script requires that the peeled remote tag, local `HEAD`, and GitHub release
target all identify the same commit. It refuses to overwrite an existing
versioned release by default. Use `--recover-existing-release` only to resume a
known partial publication after those identity checks pass.

The script uploads the notarized DMG to the versioned GitHub preview release, then
generates `appcast-beta.xml` and uploads that feed to the fixed
`sparkle-beta` release. Release notes are copied from
`docs/release-notes/<version>.md` when present.

## Preview Retention Policy

Preview builds are intentionally frequent, but the large DMG assets do not
need to stay attached to GitHub Release records forever. Keep git tags and
committed release notes as the durable record, then prune only old GitHub
Release containers.

The nightly prerelease coordinator enables this policy by default after a
successful publish and verification:

```bash
scripts/release/run-nightly-prerelease.sh
```

For CalVer, it keeps the newest 10 preview release records across month boundaries,
keeps the current release, keeps `sparkle-beta`, and deletes older versioned
prerelease GitHub Release records without `--cleanup-tag`. The git tags remain,
so an older build can be recreated from commit history when needed.

Release notes are preserved before anything is deleted. A versioned prerelease
record is only eligible for pruning when the matching
`docs/release-notes/<version>.md` file exists in the checkout. Stale note
assets on the mutable `sparkle-beta` release are pruned only when their matching
tag still exists and the committed release-note file is present. The active
`appcast-beta.xml` feed asset is never pruned by this policy.

For a manual release, opt in explicitly:

```bash
bash scripts/release/build-notarized-dmg.sh \
  --signing-identity "Developer ID Application: Example (TEAMID)" \
  --team-id TEAMID \
  --notary-profile PROFILE \
  --github-release-tag "v2026.8.1" \
  --sparkle-generate-appcast "/path/to/Sparkle/bin/generate_appcast" \
  --sparkle-ed-key-file "/path/to/private-key.txt" \
  --sparkle-publish-release "sparkle-beta" \
  --prune-prereleases \
  --prune-prereleases-keep 10
```

To preview the retention plan without deleting anything:

```bash
scripts/release/prune-github-prereleases.py \
  --current-tag "v2026.8.1" \
  --keep 10
```

When `--sparkle-bridge-publish-release sparkle-alpha` is set, the script also
copies that generated preview appcast item to `appcast-alpha.xml` on the legacy
alpha feed. The current app still embeds the preview `SUFeedURL`; the bridge
feed only exists to let old alpha installations discover the update once.
