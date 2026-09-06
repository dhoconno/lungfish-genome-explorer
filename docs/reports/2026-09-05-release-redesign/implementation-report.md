# Release system redesign: implementation and review

This report covers the release-system redesign requested after the earlier Preview attempt consumed roughly six hours across builds, tests and recovery. It preserves the preceding scientific and user-interface remediation. The earlier unsigned candidate at commit `00ca859472e08232334e9cce49321749b29cb835` remains retained; it is not a published release.

## Measured problem and result

The preceding successful candidate transaction spent approximately 644 seconds in 269 Python tests, 313 seconds in the unit gate, 245 seconds in integration, about twelve minutes archiving, and another 487 seconds compiling the CLI through a second Release graph. These are retained phase measurements, not a claim that one successful build itself took six hours. Repeated failures, duplicated checks and recovery contributed to the longer session.

The redesigned warm Debug front door completed in **17.001 seconds**, including assembly, local ad-hoc signing and headless artifact checks. An explicit portable Debug run completed in **23.708 seconds**. Both used existing compiler intermediates on the current Apple-silicon host with Xcode 26.6; these are warm measurements, not first-install promises. Metrics are emitted under `.build/release-metrics/` with phase, elapsed time and exit status. The first optimized Preview package in the new compiler namespace completed in **908.350 seconds (15 minutes 8 seconds)**. Its Python gate took 20.782 seconds, Swift gate 75.377 seconds, and archive/assembly/artifact phase 808.199 seconds. Repeating the exact package command verified and reused the candidate in **1.474 seconds**, without compiling or rerunning source tests. The previous successful path spent approximately 40 minutes across its measured source and compiler phases, before retries.

## Implemented workflow

| Operation | Work performed | Credential or UI requirement |
| --- | --- | --- |
| `release.py debug` | One incremental SwiftPM graph, app assembly, ad-hoc seal, identity/CLI/resource checks | No release credentials or UI automation |
| `release.py debug --portable` | Debug plus relocation and checkout-independence checks | No release credentials or UI automation |
| `release.py package preview\|stable` | Compact source gate, one Xcode archive graph containing app and CLI, actual-artifact checks, immutable candidate evidence | Credentialless and headless |
| Repeated exact `package` | Verify source, policy, evidence and artifact before reuse | No rebuild for a valid exact candidate |
| `release.py configure-fork` | Validate and write public fork identity for review/commit | No secret access |
| `release.py configure-machine` | Create private repository-specific credential selectors | No import, unlock, probe or overwrite |
| `release.py setup` | Explicit provisioning checks and disposable credential tests | May require one-time macOS authorization |
| `release.py doctor` / `publish` | Check matching readiness proof; publish uses verified candidate and retained signing stages | Fail early when readiness is absent; bounded credential processes |

The existing `lungfish-cli` product and `LungfishCLI` module remain available. A thin shared executable wrapper permits both Xcode and SwiftPM to compile the same implementation. Xcode archives the CLI as an app dependency, removing the second optimized SwiftPM compilation. Compiler identity excludes unrelated signing/test-policy changes, while candidate evidence continues to bind the full source and policy. General cross-commit source-test reuse remains deliberately disabled because no complete test-runtime/binary binding has been established.

## Test policy

`config/test-catalog.json` is the canonical collection/profile authority. The initial audited inventory accounted for 15,026 test identifiers; subsequent discovery audits include newly added regressions automatically. Routine `quick` and `release` select 186 deterministic ownership, failure and provenance sentinels, with four test workers; the release contract additionally runs compact Python policy/evidence tests. The old tiers remain compatible. Broad headless, extended, native UI and real-tool conformance checks remain available explicitly. No tests were deleted to make a release appear passing.

Release readiness still requires actual app/CLI identity, embedded resources, portability, signatures, notarization and exact remote asset checks. A compact source gate does not establish exhaustive feature correctness. Native graphical diagnostics still require the documented disposable macOS account, but they are no longer a routine Preview or Stable release prerequisite. CI is advisory and manual diagnostics select one requested profile instead of launching every expensive option.

Evidence validation rejects changed canonical dependency pins, relabelled installation receipts, missing/duplicate/out-of-order test terminals, and watchdog intervention even when a terminated child reports exit zero. Dependency-lock evidence is explicitly typed; it does not claim that external scientific tools were installed or exercised. Real-tool conformance remains the appropriate explicit check for that claim.

## Unattended operation and forks

Committed identity includes the repository, public Sparkle key, product URLs and an isolated fork namespace. Public configuration is validated against Swift runtime constraints, safe filename rules and channel-derived identifiers. Fork app/Help metadata and embedded/copied CLI identity agree; preferences, storage and Keychain service names are isolated. Upstream identifiers, persisted locations, trust key and legacy migration behavior remain unchanged. Fork initial feeds may be absent; upstream migration floors remain required.

Private v2 profiles select certificate/keychain, Team ID, notarization profile/keychain and Sparkle account. Existing v1 profiles remain readable. Profile files are create-only, owned mode 0600 under private mode 0700 directories. They contain selectors, not passwords or private-key payloads. Setup independently verifies the configured Sparkle public key and disposable signature, as well as actual signing-team identity. Readiness is bound to repository, selectors, tool hashes, host/user and boot; there is no arbitrary daily expiration.

Signing uses a private, receipt-bound transaction journal. Completed signed inputs and notarization submission IDs survive interruption. App ZIP and DMG submissions retain immutable original bytes; stapling operates on distribution copies. Pending submissions resume polling their recorded UUID. Lost submission responses remain explicitly ambiguous and require reconciliation instead of blind resubmission. Changed input bytes, mismatched response IDs and changed retained stages fail closed.

Closing stdin or imposing a timeout does not suppress macOS Keychain dialogs. Provisioning trusted credential access remains a one-time operator responsibility. A matching setup observation cannot guarantee that a Keychain will not later relock or its access policy change. The workflow avoids routine UI tests and repeated credential probes, rejects absent readiness before publication, and bounds actual credential processes instead of waiting indefinitely or scripting passwords.

## Independent review and validation

Separate build, test-policy, signing and runtime reviews found and corrected: duplicate Release compilation, duplicate Debug relocation checks, fork feed initialization failures, unsafe configuration filenames, Python/Swift identity-boundary mismatches, stale fork metadata on upstream stamping, a native fork startup crash from using its bundle identifier as a custom preferences suite, unbound notarization responses, incomplete test evidence, and an unsafe synthetic mount fixture fallback. The latter could copy an unintended directory during tests; its inputs are now required to identify a nonempty, non-root fixture directory.

Focused Swift identity, storage, Keychain namespace and CLI regression checks passed. A real fork Debug rebuild then reproduced and resolved the preferences-suite startup failure: the corrected app stayed running during an eight-second startup check, and both embedded and copied CLI checks passed. Fork preferences now use a distinct `.preferences` suite. The public-key-only CryptoKit verifier typechecks with the selected Xcode. Configuration tests use fake selectors and no real credential services. Credential/recovery tests exercise bounded subprocesses and fake signing/notary tools; these do not claim that real Apple publication succeeded. Documentation authority, fork mutations, CI policy and nightly recovery/profile tests also passed. The real optimized archive and candidate at `c8d6b8126fc5f1297d0ef5fffc78a86937f9e53b` passed portability, micromamba and CLI version/tools/QC-summary checks. Source qualification executed 159 XCTest cases and 27 Swift Testing cases, with no failures or skips. The archive compiled the shared Core, IO, Workflow and CLI modules once each. Doctor then reported Package READY and Publish NOT READY because the private credential setup proof is missing; it failed before credential access. No new GitHub release, signed DMG or Sparkle feed was published. Final current-HEAD artifacts remain identified by their receipt and transaction logs.

No scientific algorithms, argument normalization or data provenance contracts were changed by this infrastructure redesign. Earlier retained stashes, rescue archives and unsigned artifacts are not cleanup targets.

## Integration and remaining external step

The redesign and preceding application remediation are integrated into `main`. The two completed Codex implementation branches were removed; only the primary checkout remains. Existing stashes and rescue archives were preserved.

The remaining publication prerequisite is explicit `python3 scripts/release/release.py setup` on the release Mac after its trusted Keychain access has been provisioned. This step may need the operator once; it was not invoked in an unattended session merely to trigger another authorization dialog. After setup succeeds, `doctor`, `package preview` and `publish preview` use the documented workflow. The current version remains 2026.9.9 Preview and must still pass the live collision/feed checks before publication.
