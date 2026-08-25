# Sparkle Updates

Lungfish uses Sparkle for graphical macOS updates. The app does not poll
GitHub's `/releases/latest` endpoint because GitHub defines that endpoint as
the latest non-prerelease, non-draft release. Preview builds use a fixed
Sparkle feed instead:

`https://github.com/dhoconno/lungfish-genome-explorer/releases/download/sparkle-beta/appcast-beta.xml`

The compatibility-named `sparkle-beta` GitHub release is the mutable preview
feed container. Each real app version gets a canonical CalVer tag such as
`v2026.8.1`, with the notarized DMG attached there. Version strings never carry
alpha, beta, preview, or stable suffixes; channel status belongs to the feed,
GitHub release state, and signed bundle metadata. The appcast points at those
versioned DMG assets.

Legacy alpha builds before `0.5.0-beta1` still read:

`https://github.com/dhoconno/lungfish-genome-explorer/releases/download/sparkle-alpha/appcast-alpha.xml`

To migrate those users automatically, publish the same signed preview appcast item
to `sparkle-alpha` as `appcast-alpha.xml`. After users install the current app,
the app bundle's `SUFeedURL` points at the preview feed for subsequent updates.

New versions use `YYYY.M.PATCH`. Capture the release machine's local date once,
then increment the highest patch for that year/month found across remote Git
tags and GitHub releases; a new month starts at `1`. Month and patch components
have no leading zeroes.

## Channels

Both channels share the single `YYYY.M.PATCH` version line: every build, preview
or stable, takes the next patch number, so `2026.8.7` names exactly one build no
matter which channel carries it, Sparkle's version comparison stays trivially
correct for a user who switches channels, and no suffix grammar exists to parse.
Stable versions are therefore not consecutive (a user may see `2026.8.2` then
`2026.8.9`); that is expected. The channel has a three-part identity, never in
the version string:

- The Sparkle feed the app polls, baked in at build time by
  `build-notarized-dmg.sh --channel`:
  - `--channel preview` (default): `appcast-beta.xml` at the `sparkle-beta`
    release, published as a GitHub prerelease.
  - `--channel stable`: `appcast-stable.xml` at the `sparkle-stable` release,
    published as a full GitHub release.
- The GitHub release's prerelease flag, which is also what routes CI: a full
  release (or promoting a prerelease to full) fires the `released` event and
  runs the heavy validation board; prereleases run nothing beyond the push
  gate their commit already passed.
- The signed bundle metadata, stamped before Developer ID signing:
  - Preview: `CFBundleDisplayName=Lungfish Genome Explorer Preview`,
    `CFBundleName=Lungfish Preview`, and `LungfishReleaseChannel=preview`.
  - Stable: `CFBundleDisplayName=Lungfish Genome Explorer`,
    `CFBundleName=Lungfish`, and `LungfishReleaseChannel=stable`.

Because the feed URL is baked into the bundle, a stable release is built as
stable from its tagged commit rather than by re-labelling a preview DMG. A
preview installation remains on the preview feed; switching to stable requires
installing a stable DMG, and opting into Preview requires installing a Preview
DMG. The two channels ship differently named bundles: the stable DMG contains
`Lungfish.app` and the preview DMG contains `Lungfish Preview.app`, so both can
sit side by side in `/Applications` (the VS Code stable/Insiders model). They
share the `com.lungfish.browser` bundle identifier because Sparkle refuses an
update whose identifier differs from the installed app's; a preview install
made before the rename keeps its `Lungfish.app` filename across Sparkle
updates (Sparkle installs to the existing path) and only a fresh drag from a
new preview DMG picks up the `Lungfish Preview.app` name.
Preview is publicly available as a GitHub prerelease and carries this
visible caveat: “Preview builds are under rapid iterative development. Features
may be incomplete, change quickly, or require additional feedback.” If an
in-app channel toggle is ever wanted, Sparkle 2's
`<sparkle:channel>` element and `allowedChannels` delegate support a single-feed
model where promotion republishes the same signed item without the channel tag;
adopt that only alongside the settings UI and a migration plan for existing
preview-feed installs.

## Release Notes Across Channels

Immutable tags, GitHub's prerelease/full state, and committed per-version notes
are the release ledger. Do not maintain a second channel/version registry.
Every `docs/release-notes/<version>.md` begins with:

```text
Channel: Preview|Stable
Previous versioned release: v<version>
Stable baseline: v<full-version>|None (bootstrap aggregation baseline: v<version>)
Dependency set: <set>
```

Preview notes cover one versioned-release delta. Stable notes compare the latest
full versioned release with the candidate, then reconcile that Git diff with
every intervening committed preview note. Before the first stable release, use
the explicitly recorded bootstrap aggregation baseline rather than repository
root. Stable notes include `## Included preview releases` and aggregate, without
duplication, user-facing workflows, correctness and stability, scientific
provenance, storage or migration changes, dependency/database pins,
platform/toolchain compatibility, release infrastructure, and known issues.

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
  --channel preview \
  --signing-identity "Developer ID Application: Example (TEAMID)" \
  --team-id TEAMID \
  --notary-profile PROFILE \
  --github-release-tag "v2026.8.1" \
  --sparkle-generate-appcast "/path/to/Sparkle/bin/generate_appcast" \
  --sparkle-ed-key-file "/path/to/private-key.txt" \
  --sparkle-bridge-publish-release "sparkle-alpha" \
  --sparkle-bridge-appcast-filename "appcast-alpha.xml" \
  --prune-prereleases
```

For stable, use `--channel stable` and omit the preview bridge and pruning
flags. The channel chooses `sparkle-stable/appcast-stable.xml` and makes the
versioned GitHub release full rather than prerelease. Explicit appcast flags
remain available for audited recovery or migration and override these defaults.

Before signing, the builder reads back and requires the selected
`CFBundleDisplayName`, `CFBundleName`, and `LungfishReleaseChannel` values. In
post-build verification, independently inspect those three keys in the archived
app, the copied release app, and the mounted DMG app; do not infer channel from
the app wrapper or DMG filename.

The script sets `CFBundleVersion` from `git rev-list --count HEAD` unless
`LUNGFISH_BUILD_NUMBER` is set. Every shipped update must have a greater
`CFBundleVersion` than the previous shipped build, regardless of the marketing
version string. The script fetches the selected channel's live appcast and
enforces this before building.

For direct publication, push the annotated `v<version>` tag first. The release
script requires that the peeled remote tag, local `HEAD`, and GitHub release
target all identify the same commit. It refuses to overwrite an existing
versioned release by default. Use `--recover-existing-release` only to resume a
known partial publication after those identity checks pass.

The script uploads the notarized DMG to the channel-appropriate versioned
GitHub release, then generates and publishes that channel's appcast to its
fixed mutable feed container. Release notes are copied from
`docs/release-notes/<version>.md` when present. Mutable `sparkle-*` feed
containers remain prerelease/non-latest infrastructure; only a versioned stable
release is full and triggers the heavy `release` event board.

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
  --channel preview \
  --signing-identity "Developer ID Application: Example (TEAMID)" \
  --team-id TEAMID \
  --notary-profile PROFILE \
  --github-release-tag "v2026.8.1" \
  --sparkle-generate-appcast "/path/to/Sparkle/bin/generate_appcast" \
  --sparkle-ed-key-file "/path/to/private-key.txt" \
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
