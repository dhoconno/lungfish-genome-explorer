# Release Process Hardening Design

## Purpose

Make Lungfish preview and stable releases reproducible on any macOS release
machine that has the supported Xcode installation and the correct Developer ID,
notarization, Sparkle, and GitHub credentials. A release must fail before remote
publication when the machine, source, package, or credentials are unsuitable.

Preview and Stable are intentionally distinct applications on disk:

- Preview ships as `Lungfish Preview.app`, displays “Lungfish Genome Explorer
  Preview,” uses the preview Sparkle feed, and is a GitHub prerelease.
- Stable ships as `Lungfish.app`, displays “Lungfish Genome Explorer,” uses the
  stable Sparkle feed, and is a full GitHub release.
- Both retain bundle identifier `com.lungfish.browser` for Sparkle update
  compatibility. Their different filenames permit side-by-side installation.

Debug is a third build profile, but it is deliberately not a release channel.
It ships only as a local, ad-hoc-signed `Lungfish Debug.app`, displays
“Lungfish Genome Explorer Debug,” uses bundle name `Lungfish Debug`, bundle
identifier `com.lungfish.browser.debug`, and metadata channel `debug`. It has
no Sparkle feed or public key and cannot be signed, notarized, tagged, uploaded,
or published through the release transaction.

## Problems to Correct

1. The release builder defaults to a SwiftPM scratch path that its own
   portability scanner rejects.
2. SwiftPM-generated `Bundle.module` accessors embed their build resource
   fallback as a literal, which compiler prefix maps do not rewrite.
3. The archive phase relies on ambient Xcode signing behavior even though the
   release pipeline signs nested code and the app explicitly afterward.
4. Preview publication is the first time CI or the release machine exercises
   the assembled release package and portability scanner.
5. Release-machine prerequisites are checked piecemeal and the selected Xcode
   toolchain is not validated against the supported release toolchain policy.
6. The manual instructions, nightly coordinator, release skill, release agent,
   and updater documentation have contradictory ordering and coexistence rules.
7. A test that manages process timeouts can hang under parallel suite load.
8. Existing archive/CLI reuse flags trust filesystem paths without proving the
   commit, channel, dependency locks, toolchain, or unsigned payload identity.
9. Stable heavy CI currently starts after public publication, so it can report
   a release defect but cannot prevent one.

## Architecture

### 0. A first-class non-release Debug profile

The strict release contract has separate `channels` and `buildProfiles`
namespaces. Preview and Stable remain the only release channels. Debug is the
only non-release profile, and its contract requires `isRelease`, `publishable`,
and `updaterEnabled` to be false. Extra feed, public-key, GitHub, tag, DMG, or
publication fields fail schema validation rather than being ignored.

`scripts/build-app.sh` consumes that profile and the shared selected-Xcode
resolver. Its former public `--release` mode fails with migration guidance to
the package-only release builder. It may apply only a local `codesign -`
signature, and the produced plist contains no Sparkle update or public-key
keys. This keeps the local helper structurally outside Developer ID, notary,
tag, GitHub, and Sparkle publication paths.

Runtime app identity is exact and closed: Debug, Preview, and Stable metadata
map to explicit cases, while unknown app metadata is rejected. Debug derives
separate managed-storage configuration and default roots, Application Support
and window-state paths, caches or temporary roots where present, and Keychain
service names. Preview and Stable retain their existing state behavior, and
explicitly injected paths/services remain authoritative for tests and callers.

The Debug bundle includes every SwiftPM/runtime resource under canonical
`Contents/Resources` paths. Owned production resource lookups use
`RuntimeResourceLocator`; direct `Bundle.module` overloads remain only as
injected test seams. Relocation smoke copies the real app, makes the compiling
`.build` unavailable, and exercises resources from outside the checkout without
launching user UI or reading production state. This layout also keeps the app
wrapper sealable: resource bundles are not duplicated or symlinked into its root.

### 1. Three explicit phases

The release flow has three boundaries:

1. **Doctor:** read-only validation of source cleanliness, supported Xcode and
   Swift versions, command availability, scratch-root writability, Developer ID
   identity/team agreement, notary profile access, Sparkle generator and private
   key usability, GitHub authentication, and selected feed build-number state.
2. **Package:** deterministic unsigned Xcode archive and arm64 CLI build,
   channel metadata stamping, bundle assembly, identity-free ad-hoc sealing of
   transformed Mach-O payloads, portability scan, and smoke tests. It produces
   a reusable candidate and package manifest without Developer ID/distribution
   signing, private credentials, notarizing, publishing, tagging, or changing
   remote state.
3. **Sign and publish:** consume the exact verified candidate without rebuilding,
   sign nested code and the app, notarize and staple app and DMG, verify the
   signed artifact, atomically publish the immutable release and mutable Sparkle
   feeds, then independently verify remote state.

Manual and scheduled releases use the same coordinator and phase interfaces.
The coordinator builds and verifies before it pushes the version tag or creates
a GitHub release. Recovery consumes recorded metadata and proves commit,
candidate, tag, and remote identity before continuing.

The repository stores one machine-readable `config/release-contract.json`.
Channel identity, toolchain policy, gates, filenames, feeds, public updater
configuration, and retention live there. Scripts and validators consume this
contract instead of independently repeating its values.

### 2. Deterministic SwiftPM resource behavior

The builder owns the CLI scratch directory. Callers do not need to invent a
path. The default is a deterministic, writable system build location outside
the repository and user home, scoped by repository identity and release commit
to avoid collisions.

The generated resource accessor’s fallback is treated explicitly:

- The app-relative `Bundle.main` resource path is required and smoke-tested.
- The fallback may contain only the builder-owned deterministic scratch root.
- No user home, repository checkout, random temporary directory, DerivedData,
  Homebrew Cellar, or worktree path may be embedded.
- The scanner reports concise file/offset evidence and does not dump an entire
  binary.

This rule is tested by building the real CLI, not by checking shell source text.

The unsigned-for-distribution candidate receives a canonical receipt containing the commit and
clean-tree state; channel, version, and build; wrapper and bundle metadata;
package-lock and managed-manifest hashes; release-contract and builder hashes;
Xcode, Swift, SDK, architecture, and deployment target; and hashes for the
archive app, embedded CLI, transformed bootstrap executable, and complete
packaged payload. Candidate reuse is allowed only through an exact matching
receipt. Path-only `--reuse-archive` and `--reuse-built-cli` are retired or
mapped to receipt-validated recovery.

### 3. Signing boundaries

Xcode archive creation always sets `CODE_SIGNING_ALLOWED=NO` and
`CODE_SIGNING_REQUIRED=NO`. Sanitization changes Mach-O bytes, so package-only
applies only literal-identity `-`, timestamp-free ad-hoc seals to those
transformed executables before exact-payload smoke tests. These seals use no
Keychain identity or private credential, are bound by the receipt, and are not
distribution signatures. The release signer remains the sole authority that
applies Developer ID signatures, replacing the ad-hoc seals only after receipt
verification. Package-only CI therefore exercises the same archive and
assembly path without private credentials.

### 4. Toolchain policy

The repository declares one supported release Xcode major/minor line and minimum
Swift version in a machine-readable policy file. Doctor and CI read the same
policy. Patch-level Xcode upgrades are accepted within the declared line unless
the policy explicitly pins an exact build; incompatible major/minor versions
fail before compilation with the selected `DEVELOPER_DIR` and observed versions.

The Xcode selection is a parent-process boundary, not state local to Doctor.
One shared resolver canonicalizes a valid explicit `DEVELOPER_DIR`, otherwise
prefers `/Applications/Xcode.app/Contents/Developer` when it is a full Xcode,
and only then considers `xcode-select`. The coordinator, direct builder,
candidate receipt, source gates, Sparkle resolver, and nightly entry point all
inherit the same exported value. An ambient Command Line Tools selection
therefore cannot leak back in after Doctor accepts the installed full Xcode.

### 5. CI coverage

The main-branch gate retains fast structural tests. A package-smoke job also
builds unsigned Preview and Stable candidates, assembles the real CLI and
resources, relocates both apps into one staging directory, runs portability and
release smoke tests, and uploads concise diagnostics. It must use the same
package phase as a credentialed release; CI must not maintain a second
approximation of release assembly.

This job does not sign, notarize, tag, publish, or access private credentials.
For an immutable release candidate, tag-push CI runs the channel-appropriate
source and dependency gates for the exact tagged SHA. The coordinator waits for
that exact run before public GitHub or Sparkle publication. Stable heavy gates
therefore block publication rather than merely detecting defects afterward.

### 6. Release-machine doctor

Doctor supports two modes:

- `--package-only` validates toolchain, commands, source, writable deterministic
  scratch storage, and public packaging inputs. This runs in CI.
- `--credentials` additionally validates Developer ID/private-key availability,
  Team ID agreement, notary profile usability, GitHub release permissions, and
  Sparkle signing by signing and verifying a disposable probe payload without
  printing secrets.

Doctor is idempotent and read-only except for private temporary probe files that
it removes. Sleeping or relocking the Mac results in an actionable credential
failure before a release commit, tag, or expensive archive build.

Doctor resolves Sparkle command-line tools from the pinned package dependency
when they are absent, rather than requiring a lucky pre-existing DerivedData or
`.build/artifacts` path. Scheduled-machine credential names and local overrides
live in an ignored local profile or explicit environment, never in the tracked
nightly wrapper.

The common coordinator is the only credentialed release entry point. It runs
credentials Doctor before any source gate, compilation, tag creation, or remote
mutation, and repeats it after exact-SHA CI. The phase builder accepts direct
package-only and contract-description requests, but refuses every direct
credentialed prepare, resume, recovery, signing, notarization, or publication
request with an instruction to use `release.py`. The coordinator supplies a
fresh per-child internal capability only to its credentialed builder child;
that capability is never ambient in Doctor, source-gate, or package children.

Before packaging, the coordinator also requires a non-shallow checkout on the
configured main branch and proves the selected remote main is an ancestor of
the local release-preparation commit. This permits the intentional unpushed
release commit while rejecting stale or unrelated history. The coordinator
owns the live Sparkle build-number policy. Preview checks its contract-declared
legacy Alpha bridge and Beta feed strictly. Stable checks the same Alpha and
Beta migration floors strictly, then checks the Stable feed and allows 404 only
for an as-yet-uninitialized Stable feed. A missing legacy floor in the contract
is a hard failure. Resume repeats source-history verification and checks these
feeds against the verified candidate receipt build, so a standalone
package-only run cannot bypass either gate.

After exact-SHA CI and the second credentials Doctor, the coordinator rechecks
every applicable receipt-bound feed immediately before starting the
credentialed builder. The builder applies the same contract-derived checks
again immediately before the first Developer ID signature and after
signing/notarization immediately before any versioned or mutable-feed
publication. This closes the long CI and signing/notary intervals. A narrow
network response-to-next-command race remains because GitHub release asset
replacement offers no compare-and-swap precondition; eliminating it requires a
future publication split with server-side conditional mutable-asset updates,
not another earlier read-only check.

### 7. One release authority

The coordinator and its machine-readable policy are authoritative. Human docs,
the Codex skill, the release agent, and tests describe or validate that same
flow. The validator must reject these forms of drift:

- claiming Preview and Stable replace one another;
- instructing manual publication before package verification;
- using a different test tier or toolchain policy from the coordinator;
- describing a scratch-path default rejected by portability policy;
- bypassing package-only verification with a separate CI assembly recipe.

Release builds check `Package.resolved` consistency without repairing tracked
files. Repair remains a deliberate development command outside the release
transaction.

## Test Strategy

All behavior changes follow red/green TDD.

1. Behavioral script tests run Doctor and package helpers in controlled temporary
   repositories with real files and stub only external Apple/GitHub services.
2. A real CLI packaging regression builds into a deliberately hostile absolute
   scratch location and proves the assembled candidate contains only allowed
   deterministic prefixes and resolves bundled resources from the app.
3. Archive command tests execute the command-construction interface and assert
   unsigned Xcode settings from observable arguments, rather than grepping the
   script.
4. Debug tests validate the exact non-release contract and plist identity,
   reject unknown runtime metadata, prove all default state roots and Keychain
   service are isolated, and run a real relocated resource smoke from an
   isolated home/storage root with the compiling `.build` unavailable.
4. Coordinator tests prove package verification precedes tag/push/publication
   and that recovery never rebuilds a verified candidate.
5. CI contract tests prove the package-smoke job invokes the repository package
   phase and has no signing or publishing permissions.
6. Skill validation tests pressure-test Preview/Stable coexistence and ordering
   claims across all release authorities.
7. The process-timeout regression is marked or invoked serially and is run under
   the same parallel conditions that previously hung.
8. Receipt tests mutate every bound input independently and require recovery to
   fail before signing.
9. A dual-channel staging test launches or probes both installed paths and
   confirms their independent names, feeds, release-channel metadata, and
   updater host paths while retaining the shared bundle identifier required by
   existing Sparkle users.

## Failure and Recovery Rules

- Doctor or package failure creates no tag, GitHub release, or feed mutation.
- Signing or notarization failure retains the verified local candidate and
  metadata for retry; it does not rebuild.
- Publication recovery requires exact commit, version tag, candidate SHA-256,
  channel, unsigned-candidate receipt, and remote-target agreement.
- Mutable Sparkle feeds update only after the immutable versioned DMG exists and
  independently verifies.
- Logs are bounded and redact credentials and private key material.

## Success Criteria

1. A clean release invocation on a correctly provisioned Mac needs no wrapper,
   custom scratch path, manual Xcode selection workaround, or Desktop key file.
2. Preview and Stable install side-by-side using their documented filenames and
   channel-specific metadata.
3. Package-only CI exercises the real release archive, CLI assembly,
   portability, and smoke-test path without credentials.
4. The default builder path passes its own portability policy on supported
   Xcode/Swift versions.
5. A locked/missing credential or unsupported toolchain fails during Doctor,
   before compilation or remote mutation, with a direct remediation message.
6. Manual and scheduled releases invoke the same coordinator and phase order.
7. All release authorities and validators agree with this specification.
8. Stable source/conformance gates pass for the exact tagged SHA before the
   versioned GitHub release becomes public.
9. Reusing a candidate whose receipt differs in any bound input is rejected
   before signing.

## Non-goals

- Changing the shared bundle identifier or migrating existing Sparkle users.
- Automating installation of private certificates or exporting private keys.
- Publishing a new release while implementing this hardening.
- Replacing Apple notarization or GitHub Releases with another distribution
  system.

## Debug independent-review hardening

The relocated Debug smoke owns an exclusive repository-scoped lock before it
hides the compiling `.build`. Its exit trap restores only into an absent
destination; if another process recreates `.build`, both trees are preserved
and the smoke fails with the original tree's manual recovery path. The smoke
requires regular app and CLI executables, deeply verifies a valid exact ad-hoc
signature with no TeamIdentifier, and executes both binaries without opening
the UI.

Production resource lookup accepts only nonempty relative paths without dot
components. It resolves roots and candidates through symlinks and requires
exact containment beneath the case-exact `Contents/Resources` root when inside
an app. Source-tree fallback is an explicit test-only injection; standalone
production CLI processes must use packaged resource bundles or fail.

Debug Nextflow state lives beneath
`~/Library/Caches/com.lungfish.debug/nextflow`; Preview and Stable retain
`~/.nextflow`. Metadata presets and the legacy `AppSettings` database default
derive from the identity-aware managed-storage root. Remaining `.lungfish` and
`.nextflow` literals are project/bundle format markers, per-run output names,
container examples, or deliberate legacy migration detection rather than
cross-profile user defaults.

The second independent review closes two narrower trust-boundary gaps.
Production standalone executables do not scan adjacent SwiftPM bundles at all;
only explicit developer/test injection enables adjacent or checkout discovery,
while app executables remain confined to the exact, non-symlinked canonical
`Contents/Resources` root. The relocation smoke inventories every discoverable
signed nested code object and container and requires each identity to be ad-hoc
with no TeamIdentifier. Skill validation rejects semantic, case-insensitive
contradictions about Debug signing, self-containment, checkout dependence,
wrapper name, or display name while allowing the accurate statement that Debug
is distribution-unsigned and not Developer ID signed.

## Supported operator front door

The coordinator exposes only four supported operations: `debug`, `package`,
`publish`, and `doctor`. `debug` is structurally limited to the focused Debug
configuration gate, `build-app.sh --debug`, and the relocation smoke. `package`
is profile-free and credentialless; it sanitizes credential and coordinator
capability environment values, runs package Doctor and contract-selected gates,
delegates to the internal package-only builder, and verifies the resulting
receipt. Candidates live at
`build/Release/<channel>/<full-commit>/`, with matching channel/commit-scoped
candidate outputs. DerivedData is independently compiler-fingerprint-scoped,
so compatible adjacent candidates can reuse intermediates while incompatible
toolchains cannot collide.

`publish` derives that exact current-HEAD/channel receipt and verifies source,
channel, and payload before credential checks. It then loads only the strict v1
JSON machine profile at `~/.config/lungfish/release.json` (or an explicit
`--profile`), repeats the existing source/dependency/feed/CI gates, and resumes
the existing receipt-bound signing transaction without rebuilding. Re-running
the same command is the only public recovery interface. No coordinator or
nightly path invokes release retention or pruning.

The profile schema has exactly `schemaVersion`, `repository`,
`signingIdentity`, `teamId`, and `notaryProfile`. The file is a current-user
regular non-symlink at mode `0600` beneath a private current-user directory; v1
rejects unknown keys and control characters. Sparkle tools are resolved from
the pinned dependency after Xcode selection, and the private Sparkle key stays
in Keychain. `doctor` reports package readiness without loading ambient release
credentials and adds publish readiness only when the JSON profile is present
and safe.

## Multi-Mac compiler-cache and readiness boundary

Release packaging reuses only disposable SwiftPM and Xcode compiler state. A
single canonical v1 JSON document binds the canonical GitHub repository,
Xcode version/build, full Swift identity and its SHA-256, macOS SDK
version/build, arm64 architecture, deployment target, Release products,
Package.resolved, release contract, and an explicit hashed build recipe. Its
SHA-256 selects
`/private/var/tmp/lungfish-release-cache/v1/<repository-key>/<fingerprint>/`,
with `swiftpm` and `derived-data` children. User, home, checkout, Xcode install
path, channel, and commit are deliberately absent; compiler-compatibility
changes select a sibling rather than deleting or overwriting another key.

The root and namespace are owner-controlled, non-symlink trust boundaries.
Every existing entry is checked before reuse, and one private advisory lock
serializes builders sharing a fingerprint. Candidate apps, receipts, signed or
notarized outputs, credentials, DMGs, and feeds never enter this cache. The
candidate receipt records the exact canonical fields and fingerprint, and
verification recomputes both against the selected toolchain and payload, so
cached bytes never become release authority.

Package Doctor now checks the selected full Xcode and first-launch state,
compatible (not pinned-exact) Xcode/Swift policy, exact SDK identity, arm64,
deployment settings, Python/local commands, fail-only dependency locks, both
cache and output disk floors, and a bounded private-cache write probe. A
missing default profile reports package READY and publish NOT READY with exit
zero; an explicitly requested missing/unsafe profile or failed credential
probe is publish NOT READY and nonzero. Doctor neither installs nor repairs
software and credential mode remains the existing signing/notary/GitHub/
Sparkle verification boundary.
