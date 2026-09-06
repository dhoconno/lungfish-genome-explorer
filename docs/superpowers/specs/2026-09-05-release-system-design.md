# Release system redesign

The user authorizes autonomous architectural decisions and implementation. This replaces the old release policy deliberately; it never turns failed evidence into a pass. Existing source data/provenance semantics and upstream installation identities remain compatible.

## Decisions

1. Keep one operator coordinator. Add explicit local build and diagnostic verification profiles; publication accepts only a complete optimized portable candidate. Debug does not run the full suite or UI automation. Separate cheap local startup/resource checks from optional full relocation diagnostics.
2. Use a single Xcode archive dependency graph for Release GUI and CLI. Keep LungfishCLI as a library module with a shared thin executable entrypoint, preserving command behavior and tests. Retain one SwiftPM graph for incremental Debug. Compiler cache identity contains compiler inputs, not release-policy/signing changes; artifact receipts still bind all policy and source inputs.
3. Replace the ad hoc unit/integration gate definition with a canonical catalog of logical collections and explicit resource classes. Routine release verification uses the 186-test headless sentinel profile plus compact Python policy checks. Canonical dependency-lock evidence is typed separately from installed-runtime evidence; real-tool conformance is explicit. Native AppKit/XCUITest checks are explicit diagnostics. Exhaustive maintainer transaction matrices and stress tests remain available, not rerun for every package. Preserve provenance/failure/ownership contracts and exact selected/completed accounting. No failed diagnostic retry authorizes a release.
4. Separate source verification from actual-artifact checks. Reuse only an unchanged, independently verified exact candidate. General source-gate reuse is disabled until runtime and test-binary inputs can be completely bound. Every new artifact gets identity/resource/executable/portability checks. Every publish verifies candidate identity, signatures, notarization and exact remote assets. UI tests are not part of Preview or Stable release authority.
5. Make committed public identity the authority for fork repository, names/IDs, runtime namespace, Sparkle public key, and migration feeds. Private per-repository machine profiles contain only credential selectors. Support the existing v1 profile without rewriting it. Fork initialization creates reviewable configuration; keys and credentials are never silently generated, exported, or rotated.
6. Preserve upstream runtime paths exactly. Explicit fork metadata selects separate application support, caches, managed storage and Keychain namespaces, including the embedded CLI; forks never consume upstream legacy storage. Do not rename scientific format identifiers.
7. Separate one-time interactive provisioning from unattended operation. Validate exact selected key/account/team, use real disposable signing probes only in an explicit setup context, and require readiness for unattended publication. Timeouts alone cannot suppress macOS dialogs; state this limitation. Never disable OS security, automate passwords, or grant every application access. Bound credentialed children and terminate process trees on timeout. Persist notarization submission identity before polling so recovery does not blindly resubmit.
8. Record named phase timings, cache hits, commands with nonsecret selectors, exits and recovery state. Benchmark cold/warm Debug and Release, policy-only changes and exact candidate retries. Report measured results, not promises about all-core CPU use.

## Implementation boundaries

- Build team: Package.swift; CLI entrypoint/wrapper; Xcode project/scheme; archive compile/embed block; compiler fingerprint and focused tests.
- Test team: test catalog/planner/runner and evidence compatibility; full-suite adapter; collection/profile behavior tests. Coordinate contract changes with root.
- Signing team: private profile v2/configuration/provisioning/readiness, bounded credential process runner and durable notary helper; focused fake-runner tests. Root integrates coordinator/contract and builder call sites.
- Runtime team: AppIdentity, embedded CLI identity resolution, upstream migration guards and fork-safe product URLs; generic identity tests.
- Root: public contract, coordinator/front door, phase/reuse integration, skill/docs/CI authority, integration review, measurements and final release disposition.

## Acceptance

- Warm local build avoids exhaustive gates, native UI automation, signing/notary access and redundant executable graphs.
- Release candidate requires the declared headless policy and fresh actual-artifact checks; optional diagnostics cannot silently authorize publication.
- All retained tests are discoverable through documented profiles; classification is explicit and no empty required selection passes.
- Wrong Sparkle key/team/repository and changed candidate or policy fail before publication; credentials never enter argv/logs.
- Fork fixture identity works in app and embedded CLI with isolated storage and unchanged upstream behavior.
- Public/private configuration survives a fresh fork and a second machine without upstream private credentials.
- Signing/notary timeouts preserve recoverable evidence; one-time OS setup requirements are documented honestly.
- New build graph produces portable arm64 app and CLI, correct resource bundles, entitlements, signatures and symbols.
