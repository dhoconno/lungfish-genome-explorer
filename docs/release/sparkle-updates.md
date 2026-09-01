# Sparkle Updates and macOS Releases

## Supported commands

All manual, CI, recovery, and scheduled release work enters through exactly:

```text
python3 scripts/release/release.py debug
python3 scripts/release/release.py doctor [--profile PATH]
python3 scripts/release/release.py package preview|stable
python3 scripts/release/release.py publish preview|stable [--profile PATH]
```

Run `package` before `publish`. Re-run the identical `publish` command to recover
an interrupted signing, notarization, or publication transaction. Recovery
revalidates the deterministic current-HEAD receipt and does not rebuild.
Low-level release builders and phase helpers are internal interfaces, not
operator, CI, or nightly entry points.

No release command implicitly prunes GitHub releases, tags, worktrees, rescue
archives, cache namespaces, or candidates. When retention is intentionally
requested as a separate maintenance task, inspect and then run
`scripts/release/prune-github-prereleases.py`; it is not part of publication.

## Channel identity

Both channels use the same suffix-free `YYYY.M.PATCH` sequence. Channel state is
carried by the signed bundle metadata, baked feed, and GitHub prerelease state:

| Fact | Preview | Stable |
|---|---|---|
| Wrapper | `Lungfish Preview.app` | `Lungfish.app` |
| Display name | `Lungfish Genome Explorer Preview` | `Lungfish Genome Explorer` |
| Bundle name | `Lungfish Preview` | `Lungfish` |
| Release channel | `preview` | `stable` |
| Feed container | `sparkle-beta` | `sparkle-stable` |
| Appcast | `appcast-beta.xml` | `appcast-stable.xml` |
| GitHub release | Prerelease | Full release |

Preview also publishes the same signed item to the legacy
`sparkle-alpha/appcast-alpha.xml` bridge so older Alpha installations can move
onto the Beta feed.

Preview uses bundle identifier `com.lungfish.browser.preview`; Stable retains
`com.lungfish.browser`. The distinct identifiers, wrapper paths, names, feeds,
and updater hosts make side-by-side installation, launch, updates, and
identifier-keyed state independent. Older Preview builds used the Stable
identifier and therefore require a one-time manual reinstall from a current
Preview DMG. Manually migrate any desired Preview settings; no compatibility
shim is part of the release process.

Preview releases and About text include: “Preview builds are under rapid
iterative development. Features may be incomplete, change quickly, or require
additional feedback.”

## Release notes and version ledger

Choose the next collision-free `YYYY.M.PATCH` by capturing the release Mac's
local date and incrementing the highest positive patch for that year/month
across remote immutable versioned tags and GitHub releases. Ignore drafts,
legacy versions, and mutable `sparkle-*` containers. Never overwrite a
collision.

Every `docs/release-notes/<version>.md` begins with:

```text
Channel: Preview|Stable
Previous versioned release: v<version>
Stable baseline: v<full-version>|None (bootstrap aggregation baseline: v<version>)
Dependency set: <set>
```

Preview notes cover the previous versioned-release delta. Stable notes reconcile
the Git diff and every intervening committed note from the latest full release,
or from the recorded bootstrap aggregation baseline before the first Stable,
and include `## Included preview releases`. Immutable tags, GitHub release
state, and committed notes are the ledger; do not add a mutable registry.

## Fresh release Mac bootstrap

Provision the machine directly; this repository intentionally does not invent
an installer:

1. Install full Xcode `>=26.4.1,<27`, launch it once, accept the license, and
   finish first-launch components. The coordinator selects a compatible full
   Xcode; do not use a manual `xcode-select` workaround.
2. Install Git, Bash, ripgrep, Python 3.11 or newer, and GitHub CLI. Authenticate
   `gh` for the selected repository. Release scripts use only the Python
   standard library. Xcode/macOS provide the Apple build, signing, notarization,
   plist, archive, and disk-image commands.
3. Import the Developer ID Application certificate with its private key into
   the login Keychain.
4. Configure a usable `notarytool` Keychain profile.
5. Resolve the repository-pinned Sparkle tools and create/import the Sparkle
   EdDSA private key in the login Keychain. Do not export a key file for release.
6. Create an owner-only `~/.config/lungfish` directory and a current-user,
   regular, non-symlink mode-0600 `~/.config/lungfish/release.json` containing
   exactly:

   ```json
   {
     "schemaVersion": 1,
     "repository": "OWNER/REPO",
     "signingIdentity": "Developer ID Application: Example (TEAMID)",
     "teamId": "TEAMID",
     "notaryProfile": "PROFILE"
   }
   ```

7. Run `python3 scripts/release/release.py doctor`. It reports `Package
   readiness` and `Publish readiness` separately. A missing default profile can
   report package READY/publish NOT READY with exit zero; an explicit missing or
   unsafe profile, or a failed credential probe, exits nonzero. Doctor is
   read-only apart from disposable probes and never installs or repairs tools.

The release Mac must also have the pinned verification root at
`~/.lungfish-verify`. Provision or refresh it with
`bash scripts/deps/verify.sh --tier 1 --root ~/.lungfish-verify`. Doctor verifies
its canonical `dependency-receipt.json` and isolated `parity-python` runtime; it
does not install or update dependencies.

The release contract also requires Swift `>=6.2,<7`, macOS SDK major 26,
deployment target 26.0, arm64, and at least 20 GiB free on both cache and output
volumes.

## Package and publish semantics

`package` is credentialless and locally authoritative. It sanitizes
credential/capability environment values, checks the source checkout, runs
package Doctor, verifies the reconciled dependency receipt, and runs the
contract-defined focused tests plus the selected channel gates on the release
Mac. Preview runs unit and integration; Stable runs full and conformance with
tools required. Only after those gates pass does it perform internal unsigned
assembly, validate the actual artifact with portability and smoke checks, and
perform exact receipt verification. Its output is
`build/Release/<channel>/<40-hex-commit>/unsigned-candidate-receipt.json` plus
the bound candidate.

GitHub Actions is advisory. Main and pull requests run the fast structural
gate; manually dispatched diagnostics can exercise additional builds. Tag
pushes do not start release gates, and no Actions result authorizes or blocks a
publication.

`publish` verifies current source history and the expected channel/current-HEAD
receipt before it reads the strict profile. It then runs credential Doctor and
live Sparkle build floors, creates and atomically pushes the annotated tag, and
repeats credentials and receipt-bound live floors; then gives the
candidate to the internal signer. There is no rebuild between package receipt
and Developer ID signing.

The signer replaces package ad-hoc seals, signs nested code and the app,
notarizes and staples app and DMG, publishes the immutable versioned release,
then updates the mutable channel feed and Preview bridge. Independent
verification checks receipt/commit/tag identity, app and CLI versions, wrapper
and bundle metadata, feed URL, signatures, notarization logs and staples,
Gatekeeper, smoke tests, DMG SHA-256, GitHub target/prerelease/assets, and exact
appcast assets.

Live build-number floors are repeated immediately before internal signing and
again before remote mutation. Preview requires strict legacy Alpha and Beta
floors. Stable requires those migration floors plus Stable; only a never-created
Stable feed may be absent.

## Compiler cache and repeated builds

Only disposable SwiftPM and Xcode DerivedData intermediates are reusable at
`/private/var/tmp/lungfish-release-cache/v1/<repository-key>/<fingerprint>/`.
The canonical, path-independent fingerprint covers repository identity,
Xcode/Swift/SDK identities, architecture, deployment target, dependency locks,
release contract, and build recipe. Compatible builds serialize and reuse one
namespace; a changed compiler input selects a sibling. Candidate apps, receipts,
signed/notarized outputs, DMGs, feeds, and credentials never enter the cache.
Receipt hashes—not cached bytes—authorize recovery.
