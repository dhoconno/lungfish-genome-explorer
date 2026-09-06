---
name: releasing-lungfish
description: Use when asked to prepare, package, publish, recover, promote, or validate a Lungfish macOS release, DMG, or Sparkle preview/stable update.
---

# Releasing Lungfish

Use the coordinator for every operator action. Missing provenance, local gate,
signature, notarization, receipt, or remote-verification evidence is a blocker.

## Meaning of build requests

A request for a **Debug build** means a local app for testing. Run the Debug
coordinator and report the local app path; do not publish it.

A request for a **Preview build** or **Stable build** means a complete release
published to GitHub, including signing, notarization, publication, and verified
Sparkle feeds (and the Preview legacy bridge). Packaging an unsigned local
candidate is an intermediate step, never completion of that request. Proceed
through `package` and `publish` without asking for publication approval again:
the channel build request authorizes publication. If a required gate fails,
report the blocker and continue recovery where possible; never describe an
unpublished candidate as an available update. Only stop at packaging when the
user explicitly requests an unsigned candidate or package-only work.

## Supported operator front door

These are the only supported commands:

```text
python3 scripts/release/release.py debug [--portable] [--jobs N]
python3 scripts/release/release.py configure-fork --repository OWNER/REPO --product-name NAME --namespace REVERSE_DNS --sparkle-public-key BASE64 --website URL --documentation URL
python3 scripts/release/release.py configure-machine --signing-identity LABEL --team-id TEAM --notary-profile NAME [--profile PATH]
python3 scripts/release/release.py setup [--profile PATH]
python3 scripts/release/release.py doctor [--profile PATH]
python3 scripts/release/release.py package preview|stable
python3 scripts/release/release.py publish preview|stable [--profile PATH]
```

There is no public prepare, resume, status, receipt, reuse, or prune
transaction option. Re-run the same `publish` command to recover an interrupted publication;
it derives and verifies the current-HEAD candidate receipt and never rebuilds it.
`build-notarized-dmg.sh`, `release-doctor.py`, and other phase helpers are internal
implementation interfaces. Do not give operators, CI, or nightly direct helper
commands. Release publication never prunes releases, tags, worktrees, or rescue
archives. Retention is a separate, explicit maintenance action with
`scripts/release/prune-github-prereleases.py`.

## Channel contract

The identities below describe upstream. Forks derive corresponding names, identifiers,
URLs and keys from their committed public contract.

Use one suffix-free `YYYY.M.PATCH` sequence across both channels. Determine the
next collision-free version from remote Git tags and GitHub releases.

- Preview packages `Lungfish Preview.app`, displays `Lungfish Genome Explorer Preview`, uses bundle name `Lungfish Preview`, channel `preview`,
  `sparkle-beta/appcast-beta.xml`, the `sparkle-alpha/appcast-alpha.xml` legacy
  bridge, and a GitHub prerelease.
- Stable packages `Lungfish.app`, displays `Lungfish Genome Explorer`, uses
  bundle name `Lungfish`, channel `stable`,
  `sparkle-stable/appcast-stable.xml`, and a full GitHub release.

The signed metadata is `CFBundleDisplayName=Lungfish Genome Explorer Preview`,
`CFBundleName=Lungfish Preview`, and `LungfishReleaseChannel=preview` for
Preview; Stable uses `CFBundleDisplayName=Lungfish Genome Explorer`,
`CFBundleName=Lungfish`, and `LungfishReleaseChannel=stable`.

Preview uses bundle identifier `com.lungfish.browser.preview`; Stable retains
`com.lungfish.browser`. Their distinct identifiers, wrapper names, feeds, and
updater hosts make installation, launch, updates, and identifier-keyed state
independent during side-by-side use. Because older Preview builds used the Stable identifier, they need
a one-time manual reinstall from a current Preview DMG; migrate any desired
Preview settings manually rather than expecting an in-place Sparkle update.

Preview notes and About text carry: “Preview builds are under rapid iterative
development. Features may be incomplete, change quickly, or require additional
feedback.”

Every `docs/release-notes/<version>.md` begins with `Channel:`, `Previous
versioned release:`, `Stable baseline:`, and `Dependency set:`. Preview notes
describe the previous versioned-release delta. Stable notes reconcile the Git
diff and all intervening committed notes from the latest full versioned GitHub
release, or the recorded bootstrap baseline, and include `## Included preview
releases`. Git tags, GitHub release state, and committed notes are the ledger.

## Debug build

Run `python3 scripts/release/release.py debug` for incremental local development.
The coordinator selects supported Xcode and assembles the GUI and CLI from one
native build graph. The default performs cheap bundle/CLI checks; add
`--portable` for the full relocation and self-containment diagnostic. `--jobs N`
bounds build parallelism. Neither option runs the unit or UI suites.

The upstream result is `build/Debug/Lungfish Debug.app`, displaying
`Lungfish Genome Explorer Debug`, bundle name `Lungfish Debug`, identifier
`com.lungfish.browser.debug`, channel `debug`. Fork names and identifiers come
from `config/release-contract.json`. It is locally ad-hoc signed, not Developer ID signed,
and not notarized. It is self-contained and relocatable with no checkout or `.build`
dependency; use the portable check when validating that property. Debug is not a release,
has no updater or publication path, and must never be tagged or uploaded as a release.

## Release machine bootstrap and Doctor

Provision full Xcode `>=26.4.1,<27` with first launch and license complete,
Git, Bash, ripgrep, Python 3.11+, and authenticated `gh` for the selected repository.
The release runtime uses only the Python standard library. The contract requires
Swift `>=6.2,<7`, macOS SDK 26, deployment target 26.0, arm64, and 20 GiB free on
cache and output volumes. The coordinator selects supported Xcode; do not use a
manual `xcode-select` workaround.

For a fork, first set its origin and run `configure-fork` with its own product name,
reverse-DNS namespace, Sparkle public key and public URLs. Review and commit the
public contract. This changes app/CLI metadata, feeds and runtime state isolation;
it does not rename scientific formats, modules or resource identities.

Import the Developer ID Application certificate/private key, provision a notarytool
Keychain profile and a Sparkle EdDSA Keychain account, then run `configure-machine`.
Its optional `--signing-keychain`, `--certificate-sha1`, `--notary-keychain` and
`--sparkle-account` select existing credentials. It probes no secrets, writes an
owned regular mode-0600 profile atomically under mode-0700 directories, and never
overwrites an existing profile. New v2 profiles default to
`~/.config/lungfish/releases/<repository-hash>.json`; strict legacy v1
`~/.config/lungfish/release.json` remains supported. Profiles contain selectors,
never passwords or private keys. Do not export Sparkle keys to shell files.

Run `setup` explicitly after provisioning. Setup may request macOS authorization;
it tests actual disposable signing, verifies the signing team, independently checks
Sparkle against the committed public key, and checks notary/GitHub access. Successful
proof is bound to repository, credential selectors, public key, tool hashes and boot.
It remains valid during the same boot while those inputs match; rerun setup after
a reboot or binding change. Setup does not require a clean source checkout or a
managed verification environment. It never installs or repairs prerequisites.

Run `doctor` for separate package/publish readiness. Unattended Doctor/publish fail
early without matching setup proof and do not repeat setup probes. Closing stdin
and timeouts do not suppress macOS Keychain dialogs: a subsequently locked Keychain
or changed ACL can still require operator repair. Commands have bounded process groups
and safe logs; failure preserves recovery evidence instead of waiting indefinitely.

## Package, publish, and recovery

`package` is credentialless and is the blocking release gate. It verifies the
source checkout, runs package Doctor, verifies committed dependency manifests, and runs the contract-defined focused and channel gates locally.
Both channels run the compact headless `release` profile once; UI and external-tool
conformance are optional diagnostics. The default manifest policy requires no installed
managed environment or parity runtime. Only after those gates pass does it assemble the unsigned app,
validate the actual artifact's portability and smoke behavior, and create and
verify a candidate receipt at
`build/Release/<channel>/<40-hex-commit>/unsigned-candidate-receipt.json`.

GitHub Actions is advisory only. Main and pull requests run script contracts and a narrow Swift compile/behavior
gate, and explicitly dispatched diagnostic jobs may do more work. Tag pushes do
not start release gates, and Actions never authorizes or blocks publication.

`publish` first derives and verifies that exact channel/current-HEAD receipt,
then loads the strict profile and pinned Keychain/tool inputs. It checks
setup proof and live-feed build floors, creates and pushes the annotated tag,
revalidates setup proof and feed checks, then signs, notarizes,
staples, publishes the immutable versioned release, updates mutable feeds, and
independently verifies remote and local artifacts. Stable requires the strict
Alpha and Beta migration floors plus its Stable floor; only an uninitialized
Stable feed may be absent. Preview requires strict Alpha and Beta floors.

If signing, notarization, or publication stops, preserve the candidate and
run the identical `publish` command again. Receipt verification precedes every
credentialed continuation. Recovery uses the same candidate and never rebuilds.

## Compiler cache

Only disposable SwiftPM and DerivedData intermediates are reused under
`/private/var/tmp/lungfish-release-cache/v1/<repository-key>/<fingerprint>/`.
The path-independent fingerprint binds repository identity, Xcode/Swift/SDK
identity, arm64/deployment settings, dependency locks, release contract, and
build recipe. Compatible repeated builds reuse the same serialized namespace;
changed compiler inputs select a sibling. Candidates, receipts, apps, DMGs,
signatures, feeds, and credentials never enter the cache, and cache contents
never authorize release reuse. There is no hidden cache or candidate pruning.

## Load and validate current authority

Before release work, read `config/release-contract.json`, all seven
`release.py --help` surfaces, `docs/release/sparkle-updates.md`,
`.codex/agents/release-agent.md`, `SKILLS.md`, CI/nightly definitions, and
relevant release tests. Run:

```text
python3 .codex/skills/releasing-lungfish/scripts/validate.py --repo-root "$PWD"
```

For a release, also run `git diff --check` and old-version scans. Report only
evidence actually verified: channel, tag/commit and URL, candidate
receipt, archive/app/DMG paths, SHA-256, signature/notary/staple results, feeds
and legacy bridge, local contract gates, optional advisory CI status, artifact
smoke/portability, cleanup, and residual blockers.

## Install and maintain

Run `scripts/install.sh` from this skill directory to link the repository-owned
skill into the personal skill root. Re-run the validator whenever release
tooling or authority changes.

### Optional graphical diagnostics

Routine Preview and Stable packaging are headless: `gates.appSmokeRequired` is false.
UI, extended and external-tool conformance profiles are explicit diagnostics, selected
with `python3 scripts/test.py list --profile ui`, `--profile extended` or
`--profile tool-conformance`; inspect the declared command and prerequisites before
running it. They do not independently authorize a release.

Real-app graphical checks require the disposable `lungfish-release-qa` macOS account
in `gates.appSmokeAccount`, an active logged-in graphical session, and a dedicated
Mac or VM with no user projects or credentials. A `HOME` override is not isolation.
The harness rejects existing app state and retains exact selection/completion,
source/app identities, logs and xcresult hashes. Restore a clean account before a
new diagnostic; the harness does not erase state. If the committed contract explicitly
requires graphical evidence, missing, skipped or incomplete results block that policy.


## Durable signing recovery

Keep `signing-transaction` and the exact candidate when publication stops. Signed
app input, app ZIP and input DMG are immutable and hash-bound to the candidate,
profile and public identity. Repeated `publish` resumes recorded notary submission
IDs with bounded polling and preserves signed bytes; it does not re-sign or re-ZIP
pending inputs. An ambiguous upload without a durable submission ID fails closed:
preserve the journal and reconcile the submission with Apple before retrying. Never
delete transaction state to force a second submission. Changed artifact bytes,
submission IDs or signing context block continuation.

## Release compilation

Release uses native Xcode `build` with Release configuration in the fingerprinted
DerivedData namespace, sharing the GUI and CLI dependency graph. The packager then
assembles a retained `.xcarchive` layout containing the app, dSYMs and `Info.plist`.
This internal artifact layout does not imply an Xcode `archive` action. Candidate
metadata, portability, smoke, receipt and signing checks still apply to those bytes.
Incremental compiler reuse and exact-candidate reuse are measured separately;
a retained cache alone establishes neither a timing result nor release authority.
