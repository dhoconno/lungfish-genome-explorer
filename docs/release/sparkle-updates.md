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

GitHub Actions is advisory. Main and pull requests run script contracts and a narrow Swift compile/behavior
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

### Stable graphical evidence

Stable packaging requires the contract-selected real-app smoke methods against the exact assembled candidate in an active logged-in macOS graphical session. The receipt retains the source and app payload identities, selected/completed XCTest counts, command logs and xcresult hashes. Missing graphical access, any skipped/empty/incomplete selection, or changed evidence blocks Stable readiness. The Release candidate uses ordinary UI actions; DEBUG fixture hooks and invented parser fixtures do not count as graphical evidence. Signing and embedded-tool smoke alone do not establish full release readiness.
The graphical session must belong to the disposable `lungfish-release-qa` macOS account declared by `gates.appSmokeAccount`, provisioned on a dedicated test Mac or VM with no user projects or credentials. Before launch the gate rejects existing Lungfish preferences, saved windows, application support and managed storage; it records the account name, UID, real account home and clean-state result. Provision or restore a fresh disposable account/VM before each run. The gate does not erase state. A `HOME` override does not isolate macOS preferences, keychain or application support, and an ordinary personal account must never run this smoke.

## Automatic feedback and pinned test inputs

The automatic fast job retains narrow Swift source compilation and seven named integer/histogram behavior checks, including a deliberate compiler-error control. It compiles the production `SequenceLengthStatistics.swift` file; it does not compile the app or establish whole-package validity. A local arm64/macOS 26 run with Apple Swift 6.3.3 measured about 1.5 seconds for compiler identity, negative/positive compilation and execution. CI uploads exact command statuses, source commit/worktree identity, input hashes, named executed checks and log hashes even on failure. Full app compilation and full/tool conformance remain separate checks.

CI preserves the existing `macos-26` runner and compatible-Xcode resolver. The [official runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) documents this platform. Action pins come from the official [checkout](https://github.com/actions/checkout/releases), [cache](https://github.com/actions/cache/releases) and [upload-artifact](https://github.com/actions/upload-artifact/releases) repositories and use complete commit revisions, retaining the existing major versions.

For maintainer-only local script validation, install the same declared inputs into a disposable environment. This is not a new release-Mac prerequisite:

```bash
python3 -m venv /tmp/lungfish-script-tests
/tmp/lungfish-script-tests/bin/python -m pip install --require-hashes --only-binary=:all: -r scripts/requirements-test.txt
/tmp/lungfish-script-tests/bin/python -B -m unittest discover -s scripts/tests
```

The script input includes PyYAML and all direct/transitive image and spreadsheet test dependencies. Optional full/conformance parity environments use `scripts/requirements-parity.txt`, which includes that same input and pins its additional dependencies. Python 3.12 or newer is required for those parity pins. Installation fails if an approved wheel/hash is unavailable; do not silently fall back to an unpinned solver or source build.

For updates, review upstream release notes and transitive requirements; resolve the existing action major tag to its full commit in the official repository. Review package metadata and SHA-256 digests from each exact version's PyPI JSON release endpoint, then replace versions and approved artifact hashes together. Install into a fresh environment with hash enforcement, run CI contract tests and the declared script suite, and record the interpreter/tool versions and outcomes in the change review. Optional parity packages require their own authorized parity validation. Never update pins automatically during a release.

## Correcting an already installed bad build

A feed restored to an older build cannot repair clients that already installed a higher build. Preserve monotonicity and ship a corrected higher build through the same channel. This is separate from resuming an interrupted publication of an unchanged candidate.

1. Pause promotion and automated release scheduling through the release owner's normal controls. Preserve the bad candidate, receipt and all gate evidence, signed DMG, appcast/notes/bridge bytes and hashes, source tag/commit, installed build/channel and the reproduction. Keep copies outside disposable caches; retain the affected project before any repair attempt.
2. Make a corrective source commit with release notes identifying the bad build, impact, workaround and any data repair needed. Choose a `CFBundleVersion` strictly above every applicable live and migration floor. Restoring older feeds or weakening the build-number gate is not a correction.
3. On a dedicated logged-in test account, use a copy of a representative project made by the bad build. Verify the corrected candidate opens the stored schema, reads imported provenance, displays the project, completes the relevant edit/import, closes and reopens it. Retain old/new schema identifiers and payload/provenance hashes. If the correction cannot read that schema, stop promotion and provide a tested migration or explicit manual reinstall/restore procedure. Never run a lower-build app against the only copy of changed user data.
4. Run the supported `package` and `publish` coordinator commands for the selected channel when that publication is authorized. Stable requires its exact-candidate graphical evidence. Verify an already-installed Preview client follows Beta, a legacy Preview client follows the Alpha bridge, and Stable follows Stable with the Beta migration floor. Record the installed build before and after the real client update; inspecting feed text alone is not an installed-client test.
5. If publication stops between the immutable DMG, primary feed, notes or Preview bridge, preserve the partial state and run the same supported `publish` command for the same unchanged current-HEAD candidate. Recovery must reuse immutable DMG bytes and complete matching mutable assets without rebuilding/re-signing. Verify notes and both Preview feeds resolve to the correction, then rerun independent remote verification before restarting promotion.

The local test-channel drill in `test_corrective_higher_build_test_channel_drill_recovers_each_mutable_stage` uses disposable repositories and fake signing/network tools. It preserves a bad-build-42 evidence fixture, rejects an equal build, accepts correction 43, and interrupts primary feed, notes and legacy bridge uploads separately before resuming the exact candidate. It verifies retained receipts/DMG identity and matching primary/bridge assets. These fixtures prove publication control behavior only. Actual installed-client channel migration, representative schema compatibility and the real graphical smoke must still have retained runtime evidence before declaring the full corrective release ready.
