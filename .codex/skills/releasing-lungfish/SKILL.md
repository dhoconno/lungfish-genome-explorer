---
name: releasing-lungfish
description: Use when asked to prepare, package, publish, recover, promote, or validate a Lungfish macOS release, DMG, or Sparkle preview/stable update.
---

# Releasing Lungfish

Use the coordinator for every operator action. Missing provenance, signature,
notarization, receipt, CI, or remote-verification evidence is a blocker.

## Supported operator front door

These are the only supported commands:

```text
python3 scripts/release/release.py debug
python3 scripts/release/release.py doctor [--profile PATH]
python3 scripts/release/release.py package preview|stable
python3 scripts/release/release.py publish preview|stable [--profile PATH]
```

There is no public prepare, resume, status, credential, receipt, reuse, or prune
option. Re-run the same `publish` command to recover an interrupted publication;
it derives and verifies the current-HEAD candidate receipt and never rebuilds it.
`build-notarized-dmg.sh`, `release-doctor.py`, and other phase helpers are internal
implementation interfaces. Do not give operators, CI, or nightly direct helper
commands. Release publication never prunes releases, tags, worktrees, or rescue
archives. Retention is a separate, explicit maintenance action with
`scripts/release/prune-github-prereleases.py`.

## Channel contract

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

Use only `python3 scripts/release/release.py debug`. The coordinator selects the
supported Xcode, sanitizes release credentials, performs internal Debug
assembly, and then validates the actual app's relocation and self-containment.

- App path: `build/Debug/Lungfish Debug.app`
- Display name: `Lungfish Genome Explorer Debug`
- Bundle name: `Lungfish Debug`
- Bundle identifier: `com.lungfish.browser.debug`
- Channel metadata: `debug`
- Signature: locally ad-hoc signed; not Developer ID signed or notarized
- Portability: self-contained and relocatable with no checkout or `.build`
  dependency

Debug is not a release, has no updater or publication path, and must never
receive a tag, upload, Sparkle publication, or GitHub release attachment. Report
the commit, branch, absolute app path, exact identity,
signature, and relocation result. Do not expose the internal assembly or smoke
helpers as operator commands.

## Release machine bootstrap and Doctor

On a fresh Apple-silicon Mac, the operator must provision these inputs before
publication; the repository does not provide an installer:

1. Install full Xcode `>=26.4.1,<27`, launch it once, accept its license, and let
   first-launch components finish. Do not use a manual `xcode-select` workaround.
2. Install Git, Bash, ripgrep, Python 3.11 or newer, and GitHub CLI; authenticate
   `gh` for the selected repository. The release runtime uses only the Python
   standard library; macOS supplies the remaining Apple tools.
3. Import the Developer ID Application certificate and its private key into the
   login Keychain, and configure a usable `notarytool` Keychain profile.
4. Resolve the repository-pinned Sparkle tools and keep the Sparkle EdDSA private
   key in the login Keychain. Do not export it to a shell file.
5. Create owner-only `~/.config/lungfish` and a regular, non-symlink mode-0600
   `~/.config/lungfish/release.json` with exactly:

   ```json
   {"schemaVersion":1,"repository":"OWNER/REPO","signingIdentity":"Developer ID Application: … (TEAMID)","teamId":"TEAMID","notaryProfile":"PROFILE"}
   ```

6. Run `python3 scripts/release/release.py doctor`. Doctor reports package
   readiness and publish readiness separately. A missing default profile may
   leave package READY and publish NOT READY with exit zero; an explicitly
   requested missing/unsafe profile or failed credential probe exits nonzero.
   Doctor checks only and does not install or repair prerequisites.

The contract requires Swift `>=6.2,<7`, macOS SDK major 26, deployment target
26.0, arm64, and at least 20 GiB free on cache and output volumes.

## Package, publish, and recovery

`package` is credentialless. It verifies the source checkout, runs package
Doctor, assembles the unsigned app, validates the actual artifact's portability
and smoke behavior, then creates and verifies a candidate receipt at
`build/Release/<channel>/<40-hex-commit>/unsigned-candidate-receipt.json`.
CI calls the same `package` command for both channels and
never signs, notarizes, tags, publishes, loads profiles, or uses secrets.

`publish` first derives and verifies that exact channel/current-HEAD receipt,
then loads the strict profile and pinned Keychain/tool inputs. It checks
credentials and live-feed build floors, creates and pushes the annotated tag,
waits for the required source/test jobs on
the exact tagged SHA; repeats credential and feed checks; then signs, notarizes,
staples, publishes the immutable versioned release, updates mutable feeds, and
independently verifies remote and local artifacts. Stable requires the strict
Alpha and Beta migration floors plus its Stable floor; only an uninitialized
Stable feed may be absent. Preview requires strict Alpha and Beta floors.

If signing, notarization, CI, or publication stops, preserve the candidate and
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

Before release work, read `config/release-contract.json`, all four
`release.py --help` surfaces, `docs/release/sparkle-updates.md`,
`.codex/agents/release-agent.md`, `SKILLS.md`, CI/nightly definitions, and
relevant release tests. Run:

```text
python3 .codex/skills/releasing-lungfish/scripts/validate.py --repo-root "$PWD"
```

For a release, also run `git diff --check` and old-version scans. Report only
evidence actually verified: channel, tag/commit and URL, candidate
receipt, archive/app/DMG paths, SHA-256, signature/notary/staple results, feeds
and legacy bridge, exact-SHA CI, artifact smoke/portability, cleanup, and
residual blockers.

## Install and maintain

Run `scripts/install.sh` from this skill directory to link the repository-owned
skill into the personal skill root. Re-run the validator whenever release
tooling or authority changes.
