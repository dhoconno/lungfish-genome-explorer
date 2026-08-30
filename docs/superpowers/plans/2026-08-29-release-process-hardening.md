# Release Process Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Preview and Stable package, sign, notarize, and publish reproducibly from any correctly provisioned release Mac using one drift-resistant workflow.

**Architecture:** A machine-readable release contract feeds a read-only Doctor, a deterministic unsigned package phase, a receipt-validated sign/publish phase, and one coordinator used by manual and scheduled releases. CI invokes the same unsigned package phase and gates the exact tagged SHA before public publication.

**Tech Stack:** Bash, Python 3 standard library, SwiftPM, Xcode command-line tools, GitHub Actions, Apple codesign/notarytool, Sparkle 2.9.6.

**Spec:** `docs/superpowers/specs/2026-08-29-release-process-hardening-design.md`

## Global Constraints

- Preview ships as `Lungfish Preview.app`; Stable ships as `Lungfish.app`; both retain `com.lungfish.browser` for existing Sparkle compatibility.
- Preview uses `sparkle-beta/appcast-beta.xml` and is a prerelease; Stable uses `sparkle-stable/appcast-stable.xml` and is a full release.
- Package-only work never reads private credentials or performs Developer ID/distribution signing, notarizes, tags, publishes, or mutates remote state. It may apply only literal-identity `-`, timestamp-free ad-hoc seals to transformed Mach-O payloads required for exact-payload executable smoke.
- A verified unsigned candidate is signed without rebuilding and is reusable only through an exact matching receipt.
- Release builds never repair tracked lockfiles.
- No credentials, profile contents, private keys, or full signing fingerprints are printed or committed.
- Xcode 26.4.1 or newer within major version 26, Swift 6.2 or newer within major version 6, macOS SDK 26, deployment target 26.0, and arm64 are the supported release line.
- Preview and Stable source/channel metadata must be derived from one machine-readable contract.

---

### Task 1: Machine-readable channel and toolchain contract

**Files:**
- Create: `config/release-contract.json`
- Create: `scripts/release/release_contract.py`
- Create: `scripts/tests/test_release_contract.py`
- Modify: `scripts/release/build-notarized-dmg.sh`
- Modify: `scripts/tests/test_sparkle_release_packaging.py`

**Interfaces:**
- Produces: `load_contract(path: Path) -> ReleaseContract`, `channel(name: str) -> ChannelContract`, and CLI `python3 scripts/release/release_contract.py get --channel preview|stable --field FIELD`.
- Channel fields: `appBundleFilename`, `displayName`, `bundleName`, `bundleIdentifier`, `releaseChannel`, `sparkleRelease`, `appcastFilename`, `githubPrerelease`, `dmgVolumeName`, `legacyBridgeRelease`, and `legacyBridgeAppcastFilename`.
- Toolchain fields: Xcode minimum `26.4.1`, exclusive maximum `27.0`, Swift minimum `6.2`, exclusive maximum `7.0`, SDK major `26`, deployment target `26.0`, architecture `arm64`, and minimum free disk GiB.

- [ ] **Step 1: Write failing behavioral contract tests**

Add table-driven tests that load the real JSON and assert literal Preview and Stable matrices, reject unknown/missing/extra fields, reject duplicate filenames or feeds, and prove the builder’s `--describe-channel preview|stable` JSON output exactly equals the contract rather than independent shell constants. The production break caught is channel/toolchain duplication drifting from the contract.

- [ ] **Step 2: Run the tests and verify RED**

Run: `.ci-python/bin/python -m unittest scripts.tests.test_release_contract`

Expected: FAIL because the contract loader and `--describe-channel` do not exist.

- [ ] **Step 3: Implement the strict contract and builder query**

Use frozen dataclasses and explicit key-set validation. JSON booleans remain booleans. The builder resolves its channel variables by invoking the contract CLI once and parsing shell-safe `KEY=VALUE` lines; it must not retain a second literal channel matrix.

- [ ] **Step 4: Replace source-text assertions with observable behavior**

Update Sparkle packaging tests to invoke `--describe-channel` and compare outputs for both channels. Preserve independent tests for invalid channels and channel-incompatible flags.

- [ ] **Step 5: Verify GREEN and commit**

Run: `.ci-python/bin/python -m unittest scripts.tests.test_release_contract scripts.tests.test_sparkle_release_packaging`

Commit: `refactor(release): centralize channel and toolchain contract`

### Task 2: Release Doctor and portable Sparkle tool resolution

**Files:**
- Create: `scripts/release/release-doctor.py`
- Create: `scripts/release/resolve-sparkle-tools.sh`
- Create: `scripts/tests/test_release_preflight.py`
- Modify: `scripts/release/run-nightly-prerelease.sh`
- Modify: `.gitignore` only if a local release-profile path is not already ignored

**Interfaces:**
- CLI: `release-doctor.py --mode package|credentials --channel preview|stable [--signing-identity NAME --team-id ID --notary-profile PROFILE --sparkle-ed-key-file PATH] [--json-report PATH]`.
- Environment: honors a valid `DEVELOPER_DIR`; otherwise selects `/Applications/Xcode.app/Contents/Developer` when present; rejects CommandLineTools-only selection.
- Resolver stdout: absolute `generate_appcast` path, `sign_update` path, and `generate_keys` path as shell-safe key/value output. It may run `swift package resolve` but may not alter tracked lockfiles.
- Tracked nightly wrapper reads non-secret defaults only. Credential/profile names come from explicit flags, environment, or ignored `${HOME}/.config/lungfish/release.env`.

- [ ] **Step 1: Write failing preflight tests**

Use temporary stub executables in `PATH` and literal command results. Cover missing/wrong Xcode, Xcode outside supported range, Swift outside range, SDK mismatch, non-arm64 host, deployment mismatch, insufficient disk, unwritable deterministic scratch root, missing signing identity, Team ID mismatch, locked/missing notary profile, GitHub auth/API failure, missing Sparkle tools, inaccessible Sparkle Keychain key, and a successful Keychain sign/verify probe. Assert every failure occurs before a sentinel release directory is changed.

- [ ] **Step 2: Run and verify RED**

Run: `.ci-python/bin/python -m unittest scripts.tests.test_release_preflight`

Expected: FAIL because Doctor and resolver do not exist.

- [ ] **Step 3: Implement package Doctor**

Read `config/release-contract.json`; resolve/export Xcode; run `xcodebuild -version`, `xcrun swift --version`, `xcrun --sdk macosx --show-sdk-version`, `uname -m`, project deployment-target inspection, free-space and scratch write probes, required-command checks, clean-tree/HEAD checks, and lockfile consistency in fail-only mode. Emit one PASS/FAIL line per check and optional redacted JSON.

- [ ] **Step 4: Implement credentials Doctor**

Add usable Developer ID/Team verification, `notarytool history`, `gh auth status` plus repository API read, and Sparkle `sign_update -p` followed by verification using Keychain unless an explicit mode-0600 key file is supplied. Use a disposable probe file and remove it via a trap/finally block.

- [ ] **Step 5: Resolve pinned Sparkle tools and remove machine constants**

Resolve tools from the pinned package dependency when absent. Update the nightly wrapper so tracked code contains no certificate common name, Team ID, notary profile, local artifact path, or private-key path.

- [ ] **Step 6: Verify GREEN and commit**

Run: `.ci-python/bin/python -m unittest scripts.tests.test_release_preflight scripts.tests.test_script_flag_guards`

Commit: `feat(release): add portable release machine doctor`

### Task 3: Deterministic portability scan and unsigned candidate receipt

**Files:**
- Create: `scripts/release/scan-release-portability.py`
- Create: `scripts/release/release-candidate-receipt.py`
- Create: `scripts/tests/test_release_artifact_receipt.py`
- Modify: `scripts/smoke-test-release-tools.sh`
- Modify: `scripts/tests/test_release_smoke.py`

**Interfaces:**
- Scanner CLI: `scan-release-portability.py APP --allowed-swiftpm-fallback ABSOLUTE_PATH`; exit 0 prints `PASS portability`; exit 1 prints at most 20 `relative-path:byte-offset:pattern` records and a summary.
- Receipt CLI: `release-candidate-receipt.py create --app APP --output JSON --channel NAME --scratch-path PATH` and `... verify --app APP --receipt JSON --channel NAME --scratch-path PATH`.
- Receipt binds the exact fields specified by the design, uses canonical sorted JSON, hashes regular-file contents plus relative paths and executable mode, and rejects symlinks escaping the app.

- [ ] **Step 1: Write failing scanner and receipt tests**

Test a real binary fixture containing a user path, repo path, random `/tmp/lungfish-*`, DerivedData, worktree, and Homebrew strings; prove concise output. Test that the single exact SwiftPM generated resource fallback is allowed only in the CLI and every other `/private/var/tmp` occurrence fails. Mutate commit, channel, build, lock hash, contract hash, toolchain, CLI byte, bootstrap byte/mode, app byte, and symlink target independently; every receipt verify must fail.

- [ ] **Step 2: Run and verify RED**

Run: `.ci-python/bin/python -m unittest scripts.tests.test_release_smoke scripts.tests.test_release_artifact_receipt`

Expected: FAIL because the scanner and receipt do not exist.

- [ ] **Step 3: Implement bounded binary scanning**

Read files in chunks with overlap, report byte offsets without emitting binary contents, and accept only the computed fallback `${scratch}/arm64-apple-macosx/release/LungfishGenomeBrowser_LungfishWorkflow.bundle` in `Contents/MacOS/lungfish-cli`. Replace the ripgrep portability loop with this scanner.

- [ ] **Step 4: Implement canonical receipt creation and verification**

Record transformed micromamba and CLI hashes separately from upstream manifest hashes. Refuse dirty source, missing fields, unknown receipt schema, changed toolchain, or payload differences.

- [ ] **Step 5: Verify GREEN and commit**

Run: `.ci-python/bin/python -m unittest scripts.tests.test_release_smoke scripts.tests.test_release_artifact_receipt`

Commit: `feat(release): bind unsigned candidates to provenance receipts`

### Task 4: Package-first builder and receipt-validated resume

**Files:**
- Modify: `scripts/release/build-notarized-dmg.sh`
- Create: `scripts/tests/test_release_builder_phases.py`
- Modify: `scripts/tests/test_release_smoke.py`
- Modify: `scripts/tests/test_sparkle_release_packaging.py`

**Interfaces:**
- New modes: `--package-only`, `--resume-candidate RECEIPT`, and default credentialed completion.
- Default scratch: `${LUNGFISH_RELEASE_SCRATCH_ROOT:-/private/var/tmp/lungfish-release-swiftpm}/<repository-key>/<commit>`; it is absolute, deterministic, and created only after Doctor.
- Package-only output: unsigned archive app plus `${release-dir}/unsigned-candidate-receipt.json` and `${release-dir}/package-metadata.txt`.
- Credentialed completion either packages once then signs, or consumes `--resume-candidate`; it never rebuilds after receipt verification.

- [ ] **Step 1: Write failing phase-order tests**

Run the builder with stub `xcodebuild`, `swift`, `codesign`, `notarytool`, and `gh`. Prove package-only needs no credential flags and calls only literal-identity `-`, timestamp-free ad-hoc sealing before smoke—never Developer ID/distribution signing, notary, or GitHub; archive arguments contain `CODE_SIGNING_ALLOWED=NO` and `CODE_SIGNING_REQUIRED=NO`; package lock consistency is fail-only; the deterministic scratch is passed to both SwiftPM and scanner; exact-payload executable smoke and receipt creation follow ad-hoc sealing; output cleanup occurs only after Doctor; Developer ID signing follows receipt verification; and resume rejects a changed receipt before codesign.

- [ ] **Step 2: Run and verify RED**

Run: `.ci-python/bin/python -m unittest scripts.tests.test_release_builder_phases`

Expected: FAIL because the phase flags and receipt behavior do not exist.

- [ ] **Step 3: Implement package-only flow**

Move all destructive output preparation after package Doctor. Build an unsigned arm64 archive, build/install/sanitize the CLI and bootstrap tools, apply only identity-free ad-hoc seals to transformed Mach-O payloads, stamp contract-derived channel/Sparkle metadata, run portability and complete exact-payload executable smoke tests, and write the receipt/metadata before returning without credential access.

- [ ] **Step 4: Implement receipt-validated signing flow**

Run credentials Doctor, verify the exact unsigned receipt, then sign nested code/framework/app, notarize/staple app, create/sign/notarize/staple DMG, generate Sparkle data, and publish. Remove raw path-based trust; compatibility flags must resolve to and verify a receipt or fail with a migration message.

- [ ] **Step 5: Run a real local package regression**

Run package-only for both channels with the selected supported Xcode. Stage both produced apps into one temporary directory and run metadata, portability, CLI version, resource-resolution, and smoke checks. Permit only the package phase's identity-free ad-hoc seals; do not perform Developer ID/distribution signing, tag, publish, or touch `/Applications`.

- [ ] **Step 6: Verify GREEN and commit**

Run: `.ci-python/bin/python -m unittest scripts.tests.test_release_builder_phases scripts.tests.test_release_smoke scripts.tests.test_sparkle_release_packaging`

Commit: `refactor(release): package and verify before signing`

### Task 5: One coordinator and exact-SHA CI gate

**Files:**
- Create: `scripts/release/release.py`
- Modify: `scripts/release/nightly_prerelease_release.py`
- Modify: `scripts/release/run-nightly-prerelease.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `scripts/tests/test_nightly_prerelease_release.py`
- Modify: `scripts/tests/test_ci_workflow.py`

**Interfaces:**
- Manual CLI: `release.py preview|stable --prepare|--resume RECEIPT [credential/profile options]`.
- Coordinator order: Doctor → required source/dependency gates → package-only → verify receipt → create/push annotated tag → wait for exact tagged SHA CI gates → resume candidate for sign/notary → publish immutable GitHub release → publish mutable feed(s) → independent verification.
- Nightly retains branch/worktree integration and version preparation, then calls the same coordinator interface once.
- CI package matrix calls `build-notarized-dmg.sh --package-only --channel preview|stable`; tag candidate jobs parse the committed release note’s exact `Channel:` field and run the contract-defined gates.

- [ ] **Step 1: Write failing delegation/order tests**

Prove manual and nightly produce the same coordinator plan; package completes before tag push; exact SHA/tag CI success is awaited before credentialed resume; cancelled, skipped, wrong-SHA, or failed CI blocks publication; Stable selects full+conformance and Preview selects unit+integration; dependency receipt and focused release tests are mandatory; recovery never rebuilds; publication happens only once.

- [ ] **Step 2: Write failing CI contract tests**

Parse the workflow YAML. Prove main pushes run unsigned dual-channel package smoke using the repository builder; `v*` tag pushes run channel-selected gates; jobs have read-only contents permission and no secrets; Stable public release-event jobs are defense-in-depth rather than the first heavy gate.

- [ ] **Step 3: Run and verify RED**

Run: `.ci-python/bin/python -m unittest scripts.tests.test_nightly_prerelease_release scripts.tests.test_ci_workflow`

Expected: FAIL because the common coordinator and tag-candidate gate do not exist.

- [ ] **Step 4: Implement the common coordinator**

Use subprocess argument arrays, structured receipt/metadata parsing, bounded GitHub Actions polling by exact workflow/head SHA, and idempotent recovery states. Remove duplicate GitHub/Sparkle publication from nightly.

- [ ] **Step 5: Implement package and tag-candidate CI**

Reuse the builder package phase, contract, and release notes. Upload package metadata/receipt/logs on failure and success; do not upload private or signed artifacts from credentialless CI.

- [ ] **Step 6: Verify GREEN and commit**

Run: `.ci-python/bin/python -m unittest scripts.tests.test_nightly_prerelease_release scripts.tests.test_ci_workflow`

Commit: `feat(release): unify coordination and gate exact release SHA`

#### Post-Task 5 P0 wiring repair

- Resolve and export one canonical full-Xcode `DEVELOPER_DIR` in the parent
  before nightly Sparkle resolution and every coordinator, Doctor, gate,
  builder, and receipt child command; cover ambient Command Line Tools with a
  valid default Xcode.
- Use the builder's validator-approved defaults (`build/Release`, its nested
  archive, and `.build/release-derived-data`) from the coordinator and CI;
  write CI logs outside the unmarked release directory.
- Require full history, the configured main branch, and remote-main ancestry
  before packaging. Run credentials Doctor before compilation/tag mutation and
  again after exact-SHA CI before signing.
- Own live Sparkle build-number validation in the common coordinator for both
  prepare and receipt-bound resume. Stable checks the Preview migration floor
  strictly and permits 404 only for an uninitialized Stable feed.

#### Post-Task 5 P0 review repair

- Refuse every direct credentialed builder prepare, resume, and recovery path;
  permit only package-only/contract queries or a credentialed child carrying a
  fresh coordinator-only capability. Run source-history verification on resume
  as well as prepare.
- Derive the complete live-floor set from the contract: Alpha and Beta are
  strict migration floors, and only Stable's own absent feed may return 404.
  Reject a contract that omits the legacy Alpha floor.
- Recheck receipt-bound floors after exact-SHA CI immediately before invoking
  the credentialed builder, immediately before its first Developer ID
  signature, and again after signing/notarization before any publication.
  Record the remaining response-to-command race and defer its elimination to a
  server-side conditional publication split.

### Task 6: Reconcile release authorities and stabilize process-tree regression

**Files:**
- Modify: `.codex/skills/releasing-lungfish/SKILL.md`
- Modify: `.codex/agents/release-agent.md`
- Modify: `docs/release/sparkle-updates.md`
- Modify: `docs/release/NEXT-RELEASE-HANDOFF.md`
- Modify: `SKILLS.md`
- Modify: `.codex/skills/releasing-lungfish/scripts/validate.py`
- Modify: `scripts/tests/test_releasing_lungfish_skill.py`
- Modify: the exact process-tree test/gate file identified by reproducing the parallel hang

**Interfaces:**
- Validator loads `config/release-contract.json` and checks semantic channel facts and phase ordering across authorities.
- Release documentation names only `scripts/release/release.py` as the manual/scheduled entry point.
- Process-tree regression is placed in a serialized release-gate group or rewritten to use condition-based waiting and guaranteed cleanup, based on reproduction evidence.

- [ ] **Step 1: Write failing semantic drift tests**

Create temporary mutated copies that say channels replace one another, swap filenames/feeds/prerelease state, instruct publication before package verification, use raw reuse paths, or prescribe gates/toolchains different from the contract. Each mutation must make validation fail for its semantic reason.

- [ ] **Step 2: Reproduce the process-tree hang before changing it**

Run the implicated test repeatedly alone and under the unit tier’s parallel load while collecting PID/process-group evidence. If it cannot be reproduced, do not guess at production behavior; isolate the test in the gate and record the evidence/rationale.

- [ ] **Step 3: Run and verify RED**

Run: `.ci-python/bin/python -m unittest scripts.tests.test_releasing_lungfish_skill`

Expected: FAIL against contradictory existing authorities.

- [ ] **Step 4: Reconcile all authorities from the contract**

State clearly that Preview and Stable coexist by distinct on-disk names while retaining the shared identifier for updater migration. Document shared identifier implications without claiming replacement. Describe Doctor, package receipt, exact-SHA gate, signing resume, recovery, and Keychain-first Sparkle usage.

- [ ] **Step 5: Stabilize the implicated process-tree test**

Apply the smallest evidence-based change: condition polling and `defer` cleanup inside the test, or explicit serial execution in `full-suite-gate.sh`. Add a test for the gate classification if serialization is chosen.

- [ ] **Step 6: Verify GREEN and commit**

Run: `.ci-python/bin/python -m unittest scripts.tests.test_releasing_lungfish_skill scripts.tests.test_full_suite_gate_tiers`

Run: `python3 .codex/skills/releasing-lungfish/scripts/validate.py --repo-root "$PWD"`

Commit: `docs(release): align authorities with robust coexistence flow`

### Task 7: Whole-branch verification

**Files:**
- Verify only; modify files only for findings through the review loop.

**Interfaces:**
- Produces fresh evidence for every success criterion and a Sol whole-branch review.

- [ ] **Step 1: Run all release Python tests**

Run: `.ci-python/bin/python -B -m unittest discover -s scripts/tests`

- [ ] **Step 2: Run validators and static checks**

Run: `python3 .codex/skills/releasing-lungfish/scripts/validate.py --repo-root "$PWD"`

Run: `bash -n scripts/release/*.sh scripts/*.sh`

Run: `git diff --check`

- [ ] **Step 3: Run real unsigned package verification**

Run the common coordinator/package interface for Preview and Stable with no credential flags, using isolated release directories and no remote mutation. Verify receipts, relocation, complete smoke tests, distinct app filenames, channel metadata, and absence of signing/publishing calls.

- [ ] **Step 4: Run focused Swift release tests and the implicated process test**

Run: `swift test --filter ReleaseBuildConfigurationTests`

Run the stabilized process-tree test repeatedly in its final gate configuration.

- [ ] **Step 5: Obtain Sol whole-branch review and resolve findings**

Review against the spec, plan, branch diff, and test evidence. Resolve all Critical/Important findings and re-review the fix range once.

- [ ] **Step 6: Verify the primary checkout remains clean and present integration options**

Run: `git status --short --branch` in both the worktree and primary checkout. Do not push, publish, sign, notarize, or remove the existing 2026.8.14 release artifacts as part of this implementation.

### Core follow-on Task 8: Add a strict non-release Debug build profile

**Files:**
- Modify: `config/release-contract.json`
- Modify: `scripts/release/release_contract.py`
- Modify: `scripts/build-app.sh`
- Modify: `Lungfish-Info.plist`
- Modify: `Lungfish.xcodeproj/project.pbxproj`
- Modify: focused Python and Swift build-configuration tests

**Interfaces:**
- `buildProfiles.debug` is separate from the Preview/Stable `channels` map and
  exposes only exact identity plus false release/publication/updater booleans.
- `build-app.sh` produces `build/Debug/Lungfish Debug.app` through the shared
  Xcode resolver and refuses its former release mode.

- [x] **Step 1: Write failing strict-contract, version-range, identity, and retired-mode tests**
- [x] **Step 2: Implement the closed Debug profile and strict loader/CLI**
- [x] **Step 3: Make plist/Xcode/build-app identity exact and updater-free**
- [x] **Step 4: Verify focused Python and Swift tests, syntax, and diff checks**

### Core follow-on Task 9: Isolate and relocate the self-contained Debug app

**Files:**
- Modify: App identity and state-path implementations/tests
- Modify: Keychain service selection/tests
- Modify: Debug resource packaging
- Add: a non-UI Debug relocation/resource smoke helper and tests

**Interfaces:**
- Runtime metadata maps exactly to Debug, Preview, or Stable and rejects unknown
  app metadata instead of defaulting to Stable.
- Every Debug default state namespace is distinct while injected overrides and
  Preview/Stable defaults remain unchanged.
- A moved Debug wrapper resolves all runtime resources with the checkout and
  compiling `.build` unavailable.

- [x] **Step 1: Write failing identity and default-state isolation tests**
- [x] **Step 2: Implement explicit Debug identity and derived state namespaces**
- [x] **Step 3: Write failing relocated-resource smoke and implement bundle layout**
- [x] **Step 4: Run real Debug build/relocation smoke and focused verification**

### Core follow-on Task 10: Correct independent Debug review findings

- [x] **Step 1: Write adversarial smoke tests for signatures, executable probing, locking, restoration, and recovery conflicts**
- [x] **Step 2: Write traversal, symlink, case-alias, and standalone-CLI resource lookup tests and harden exact containment**
- [x] **Step 3: Isolate PBAA/TaxTriage Nextflow homes, preset storage, and the legacy database default while preserving Preview/Stable**
- [x] **Step 4: Correct current Debug facts in the release skill/catalog and make their validator reject the stale claims**
- [x] **Step 5: Re-run focused Swift/Python tests and a real build/relocation smoke, then commit the clean correction**
