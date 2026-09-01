# Next Release Handoff

## Current authority

Use only:

```text
python3 scripts/release/release.py debug
python3 scripts/release/release.py doctor [--profile PATH]
python3 scripts/release/release.py package preview|stable
python3 scripts/release/release.py publish preview|stable [--profile PATH]
```

Re-run `publish` for partial-release recovery. It derives the exact
current-HEAD/channel receipt and continues without rebuilding. Direct builder
commands, public prepare/resume/status modes, shell `release.env`, and implicit
release pruning are retired. Nightly uses the same front door; GitHub Actions
is advisory and never authorizes or blocks publication. Retention is a separate
explicit maintenance task.

The strict default profile is `~/.config/lungfish/release.json`, a current-user
regular non-symlink at mode 0600 beneath an owner-only directory. Schema v1 has
exactly `schemaVersion`, `repository`, `signingIdentity`, `teamId`, and
`notaryProfile`. The Sparkle private key remains in Keychain and the tools come
from the pinned package dependency.

Doctor reports package and publish readiness separately. A fresh Mac needs full
Xcode `>=26.4.1,<27` with first launch complete, Swift `>=6.2,<7`, SDK 26,
deployment target 26.0, arm64, 20 GiB free on cache and output volumes, Git,
Bash, ripgrep, Python 3.11+, `gh`, the Developer ID certificate/private key, a
notary Keychain profile, the Sparkle Keychain key, and the strict JSON profile.
The release runtime uses only the Python standard library.
Doctor does not install or repair these inputs and no manual `xcode-select`
workaround is part of the release procedure.

The release Mac also needs the pinned dependency verification root at
`~/.lungfish-verify`, including its canonical `dependency-receipt.json` and
isolated `parity-python` runtime. Doctor checks both before reporting package
readiness.

## Channel and installation ledger

- Preview: `Lungfish Preview.app`, `Lungfish Genome Explorer Preview`,
  `sparkle-beta/appcast-beta.xml`, legacy
  `sparkle-alpha/appcast-alpha.xml`, GitHub prerelease.
- Stable: `Lungfish.app`, `Lungfish Genome Explorer`,
  `sparkle-stable/appcast-stable.xml`, full GitHub release.

Preview uses `com.lungfish.browser.preview`; Stable retains
`com.lungfish.browser`. Distinct identifiers, wrapper paths, names, feeds, and
updater hosts make installation, launch, updates, and identifier-keyed state
independent during side-by-side use. Older Preview builds require a one-time manual reinstall from a
current Preview DMG and manual migration of any desired Preview settings.

## Transaction and cache ledger

Package is credentialless and authoritative. It checks source and package
Doctor, verifies the dependency receipt, runs the contract-defined focused and
channel gates locally, assembles and smoke/portability-checks the actual
artifact, then writes and verifies it under
`build/Release/<channel>/<40-hex-commit>/`. Publish verifies that receipt before
loading credentials, checks credentials and feed floors,
pushes the annotated tag, repeats live readiness, signs without rebuilding,
notarizes, staples, publishes, and
independently verifies. Preview uses strict Alpha/Beta live floors; Stable also
checks Stable and permits absence only before that feed exists.

Only SwiftPM and DerivedData compiler intermediates are cached under the
private fingerprint namespace. The path-independent fingerprint binds the
repository, exact compiler/SDK identities, architecture/deployment, locks,
contract, and recipe. Compatible repeated builds serialize and reuse one
namespace; incompatible inputs select siblings. Candidate receipts, payloads,
DMGs, signatures, feeds, and credentials are never cached, cached bytes are not
release authority, and nothing is implicitly pruned.

## Historical recovery ledger

`v2026.8.4` was the first Stable CalVer release. Its automatic Toolset
conformance job exposed a test-only MEGAHIT path that bypassed the shipped
command builder. The immutable correction shipped as Stable `v2026.8.5`.

Dependency set 2026.2 was completed by the CalVer Preview train. `v2026.8.1`
was withdrawn after a bundled micromamba portability defect; corrected Preview
artifact `v2026.8.3` replaced it, while `v2026.8.2` remained an unpublished
preparation tag. Current release decisions come from remote tags, GitHub
release state, committed per-version notes, the release contract, and the
current coordinator—not these historical events.
