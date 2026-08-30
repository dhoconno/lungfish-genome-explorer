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

### 1. Three explicit phases

The release flow has three boundaries:

1. **Doctor:** read-only validation of source cleanliness, supported Xcode and
   Swift versions, command availability, scratch-root writability, Developer ID
   identity/team agreement, notary profile access, Sparkle generator and private
   key usability, GitHub authentication, and selected feed build-number state.
2. **Package:** deterministic unsigned Xcode archive and arm64 CLI build,
   channel metadata stamping, bundle assembly, portability scan, and smoke
   tests. It produces a reusable candidate and package manifest without signing,
   notarizing, publishing, tagging, or changing remote state.
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

The unsigned candidate receives a canonical receipt containing the commit and
clean-tree state; channel, version, and build; wrapper and bundle metadata;
package-lock and managed-manifest hashes; release-contract and builder hashes;
Xcode, Swift, SDK, architecture, and deployment target; and hashes for the
archive app, embedded CLI, transformed bootstrap executable, and complete
packaged payload. Candidate reuse is allowed only through an exact matching
receipt. Path-only `--reuse-archive` and `--reuse-built-cli` are retired or
mapped to receipt-validated recovery.

### 3. Signing boundaries

Xcode archive creation always sets `CODE_SIGNING_ALLOWED=NO` and
`CODE_SIGNING_REQUIRED=NO`. The release signer remains the sole authority that
applies Developer ID signatures after bundle assembly and portability checks.
Package-only CI therefore exercises the same archive and assembly path without
requiring private credentials.

### 4. Toolchain policy

The repository declares one supported release Xcode major/minor line and minimum
Swift version in a machine-readable policy file. Doctor and CI read the same
policy. Patch-level Xcode upgrades are accepted within the declared line unless
the policy explicitly pins an exact build; incompatible major/minor versions
fail before compilation with the selected `DEVELOPER_DIR` and observed versions.

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
