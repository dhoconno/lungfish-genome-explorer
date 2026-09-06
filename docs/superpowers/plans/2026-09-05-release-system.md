# Release System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Execute the tasks below with independent review and coordinator-owned builds.

**Goal:** Make local builds fast, release verification headless and repeatable, signing bounded and provisioned, and fork identity configurable without upstream credentials or state collisions.

**Architecture:** A single coordinator selects explicit build/test profiles, creates immutable candidate evidence, and publishes only that candidate. A canonical test catalog replaces implicit scheduling policy. Public product identity and private machine credential selectors are separate.

**Tech Stack:** Python standard library, Bash adapters, Swift/SwiftPM, Xcode, Apple Security/notarytool, pinned Sparkle, GitHub CLI.

**Spec:** `docs/superpowers/specs/2026-09-05-release-system-design.md`

## Global Constraints

- Preserve upstream IDs, Sparkle trust key, migration feeds and persisted data behavior.
- Preserve scientific command behavior and all existing reproducibility provenance.
- macOS deployment 26.0, arm64, supported Xcode 26 and Swift 6 toolchains.
- No secrets in source, command arguments, logs, reports or tests; use fake credential runners for validation.
- No ordinary release UI automation. Existing native UI tests remain explicit diagnostics.
- A failed or incomplete authoritative result cannot be made passing by a retry. Cache records never independently authorize publication.
- Root owns coordinator, public contract integration, commits, builds, publication and final integration. Agents own disjoint files or explicitly assigned sections.
- Work on `codex/release-system-redesign` in the existing checkout to retain compiler intermediates; main's baseline is committed and the previous unsigned candidate is preserved. No additional worktree is needed for concurrent edits with explicit ownership.

### Task 1: One Release compiler graph

Files: `Package.swift`, `Sources/LungfishCLI/Lungfish.swift` (resolve actual current entrypoint), new `Sources/LungfishCLIExecutable/EntryPoint.swift`, `Lungfish.xcodeproj/project.pbxproj`, shared scheme, archive/CLI section of `scripts/release/build-notarized-dmg.sh`, `release_cache_fingerprint.py` and corresponding focused tests.

Interface: preserve executable product `lungfish-cli` and module `LungfishCLI`; expose library product `LungfishCLILibrary`. Public `LungfishCLIMain.main() async` retains the existing body. Both build systems compile a shared thin wrapper:

```swift
import LungfishCLI
@main enum EntryPoint {
    static func main() async { await LungfishCLIMain.main() }
}
```

- [x] Verify current entrypoint and resources; add tests for native target dependency/copy and stable executable product.
- [x] Convert CLI module to library target and add wrapper executable target; add native Xcode CLI target linking the library product.
- [x] Make native Release `build` include the CLI as a dependency; retain a verified archive layout from its app/dSYMs, and remove the second SwiftPM Release build.
- [x] Split compiler cache schema from policy hashes using explicit compiler-recipe inputs; keep receipt hashes comprehensive.
- [x] Validate package/project structure, CLI focused behavior and real one-graph Release build and retained archive layout; report compilation counts and symbols.

### Task 2: Explicit test collections and profiles

Files: new `config/test-catalog.json`, `scripts/test.py`, `scripts/testing/` focused catalog/planner modules, `scripts/full-suite-gate.sh`, `scripts/release/gate_evidence.py`, focused catalog/evidence tests. Root integrates release contract and coordinator calls.

Interface: `scripts/test.py list|audit|run --profile quick|headless|release|extended|ui|tool-conformance`; explicit group membership and resource requirements. The release contract selects the fixed headless source profile; arbitrary diagnostic selections do not create release authority.

- [x] Define catalog schema, exact selection/empty/ambiguous validation and profile composition tests.
- [x] Preserve all suites in documented collections; keep native AppKit and XCUITest in UI diagnostics, expensive exhaustive release transactions in maintainer/extended collection.
- [x] Delegate executions to existing evidence parser, preserving discovered/completed/skip/exit accounting. Avoid independent concurrent Swift builds.
- [x] Provide compatibility for existing tier commands and source checks through behavior-based catalog assertions.
- [x] Validate representative real quick/headless selections and full inventory coverage, recording timings.

### Task 3: Credential configuration and bounded publication

Files: new `scripts/release/release_profiles.py`, credential/process/notarization helpers as needed, `release-doctor.py`, fake-runner tests. Root integrates `release.py` and builder credential call sites.

Interface: load legacy v1 and private v2 profiles into one selector model. V2 selects signing identity/team/keychain, notary profile/keychain, Sparkle account and repository. Configuration writes mode-0600 files below mode-0700 directories without overwriting existing profiles. Committed public key is provided independently to probes.

- [x] Add loader/migration tests for v1/v2, unsafe paths, invalid selectors and cross-repository mismatch.
- [x] Implement explicit machine configuration and setup/readiness distinction; do not silently perform credential import/unlock/rotation.
- [x] Validate Sparkle selected public key against candidate public key; verify disposable signatures independently.
- [x] Supervise credentialed process groups with phase budgets, closed stdin and safe logs. A timeout is a failure/recoverable state, never a permission bypass.
- [x] Persist notarization ID/artifact hash before bounded polling; retry reuses submission. Test timeout, descendants, invalid result and ambiguous upload states with fake tools.
- [x] Document unavoidable one-time OS provisioning and the precise limitations of unattended readiness.

### Task 4: Fork runtime identity

Files: `Sources/LungfishCore/AppIdentity.swift`, managed-storage legacy migration guards, product URL/help consumers, identity tests. Build team/root supply matching compact CLI metadata.

Interface: existing identity fields plus explicit `LungfishIdentitySchemaVersion=1` and `LungfishRuntimeNamespace` for forks. `from(infoDictionary:)` remains strict; upstream exact tuples retain old behavior. Fork namespace derives isolated application support/cache/storage/Keychain paths and disallows upstream legacy migration. Embedded/copyable CLI metadata carries the same identity.

- [x] Add behavior tests for accepted/rejected fork metadata, all isolated paths, upstream compatibility and embedded/enclosing mismatch.
- [x] Implement strict identity parsing/resolution and legacy migration policy.
- [x] Route fork product URLs/help identity through validated metadata; preserve scientific format names.
- [x] Validate app and embedded/copied CLI identity with packaged fixtures and unchanged upstream identity tests.

### Task 5: Coordinator, contract, evidence and operator workflow

Files: `scripts/release/release.py`, `release_contract.py`, `config/release-contract.json`, candidate receipt integration, build/smoke frontend adapters, new focused coordinator tests.

- [x] Add committed public identity: repository, Sparkle key, optional fork namespace and channel names/IDs/feeds. Validate it before build and bind it in candidate evidence.
- [x] Add public configuration commands for reviewable fork identity and private machine selectors; retain existing default profile compatibility.
- [x] Separate fast Debug checks from optional full portable Debug diagnostics; package is optimized/headless and publish uses exact candidate.
- [x] Replace unconditional exhaustive release-maintainer tests with declared routine source checks and actual artifact checks; retain extended diagnostics.
- [x] Reuse an existing candidate only after exact source/policy/artifact/evidence verification. Gate reuse must match all declared runtime/test-binary inputs or be disabled.
- [x] Add named phase timings and persistent failure/recovery metrics with redacted arguments.
- [x] Integrate credential selectors, bounded signing/notary, public key verification and fork metadata into artifact creation/publication.

### Task 6: Independent review, documentation and measured validation

Files: release skill/validator, `SKILLS.md`, release agent instructions, release docs, CI/nightly adapters, release notes and `docs/reports/2026-09-05-release-redesign/`.

- [x] Run independent build-graph, test-policy, security and fork-runtime reviews; resolve correctness findings.
- [x] Update every operator front door and remove stale claims that all tests/UI are mandatory for release.
- [x] Run changed-area behavioral tests and one exhaustive release-maintainer validation for the redesigned machinery; retain all failures and resolutions.
- [x] Measure warm Debug and incremental Release/candidate retry timings on this host; distinguish cold builds from warm and source tests from artifact checks.
- [x] Verify fork initialization in a temporary repository with fake selectors/public key, without using upstream private credentials.
- [x] Merge completed work to main and clean only owned worktrees/branches as previously authorized. Preserve stashes and baseline artifacts.
- [ ] Finish Preview publication if real unattended credential readiness and all new candidate checks pass; otherwise retain the exact candidate and report the specific external provisioning blocker without a hanging prompt.

## Verification handoff

Real Preview candidate qualification passed at `c8d6b8126fc5f1297d0ef5fffc78a86937f9e53b`; exact candidate reuse took 1.474 seconds. Main integration and owned-branch cleanup are complete. Publication remains blocked by missing private setup proof, detected before credential access. See the implementation report and current-HEAD candidate receipt for the final artifact disposition.

## Incremental archive correction

The first candidate and exact reuse passed, but a separate new-candidate experiment exposed Xcode archive-action cleanup: its archive-specific intermediate subtree was recreated, all compiler arguments matched, and external C/Swift targets rebuilt. Packaging therefore uses the supported native Release `build` action, then validates/copies the app and symbols into its retained archive layout. The 15m8 archive-action measurement is historical; final first/warm build measurements must come from this corrected path.
