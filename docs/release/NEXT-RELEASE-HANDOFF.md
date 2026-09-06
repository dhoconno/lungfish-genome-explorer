# Next Release Handoff

## September 5 redesign handoff

The redesign is integrated into main with the prior app remediation. Version 2026.9.9 is still an unpublished Preview. The first redesigned package passed at `c8d6b8126fc5f1297d0ef5fffc78a86937f9e53b` in 15 minutes 8 seconds; exact candidate reuse took 1.474 seconds. Warm Debug measured 17 seconds, or 24 seconds with full portability checks.

This Mac reports Package READY and Publish NOT READY because credential setup proof has not been established. Run explicit `setup` after provisioning trusted Keychain access; it may require one-time operator authorization. No new signed DMG, GitHub release or Sparkle feed was created during the redesign. Use the current-HEAD `package preview` receipt, rather than an older benchmark candidate, for publication. Existing stashes and rescue archives remain preserved; completed implementation branches were removed.

## Current authority

Use only:

```text
python3 scripts/release/release.py debug [--portable] [--jobs N]
python3 scripts/release/release.py configure-fork --repository OWNER/REPO --product-name NAME --namespace REVERSE_DNS --sparkle-public-key BASE64 --website URL --documentation URL
python3 scripts/release/release.py configure-machine --signing-identity LABEL --team-id TEAM --notary-profile NAME [--profile PATH]
python3 scripts/release/release.py setup [--profile PATH]
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
Doctor, verifies committed dependency manifests, runs the contract-defined focused and
channel gates locally, assembles and smoke/portability-checks the actual
artifact, then writes and verifies it under
`build/Release/<channel>/<40-hex-commit>/`. Publish verifies that receipt before
loading credentials, checks setup proof and feed floors,
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
