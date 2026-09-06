# Test and release gate architecture proposal

Read-only assessment, 2026-09-05. No builds, tests, or production edits made. Examined release contract, full-suite gate, gate_evidence.py, release.py, representative Python and Swift tests, and retained release-01lf_ff5 evidence. This proposes replacement policy under the user's authorized redesign; it does not reinterpret a failed old gate as passing.

## Measured baseline

Evidence root `.build/gate-logs/release-01lf_ff5`:

| Step | Wall seconds | Evidence |
|---|---:|---|
| Python release maintainer contracts | 644.3 | python/gate.result.json (269 cases; runner's 643.7 excludes surrounding work) |
| Unit discovery | 11.8 | swift-0 discovery command records |
| Unit primary | 300.0 | swift-0 authoritative attempt |
| Integration discovery | 9.5 | swift-1 discovery command records |
| Integration primary | 235.0 | swift-1 authoritative attempt |
| Entire gate sequence | about 1,203 | outer result timestamps |

More than half the gate time is rerunning tests of the release machinery, rather than checking this candidate. Python logs have no per-case timestamps, so attributing the 644 seconds to individual Python modules would be invented. Add case/subtest setup/run/teardown timings before assigning a module cost budget. The builder and nightly fixture suites repeatedly create repositories and execute complete mock release transactions; these are obvious profiling candidates, not yet proven individual cost totals.

Swift XCTest xUnit durations include harness/process overhead and overlap. Ranked cumulative xUnit seconds: FullLengthONTMHCGenotypingPipelineTests 615.0 (96 cases); GenotypeWorkbookRevisionServiceTests 403.9 (156); PluginPackStatusServiceTests 275.5 (38); GenotypeResultViewportArtifactsAndOutlineTests 96.1 (82); FullLengthONTMHCCandidateArtifactWriterTests 62.6 (41). These sums are NOT wall time or guaranteed removable savings. Case terminal records report respectively 469.9, 377.8, 222.0, 84.2, 56.2 seconds. Both rank the first three as primary investigation targets. Integration's terminal records put ClassificationPipelineProvenanceSourceTests 32.1 seconds, FileSystemWatcherTests 31.7, and ONTBarcodeDemuxGenotypingPipelineTests 29.6 highest.

The existing unit profile is not unit-only: it contains view creation, native panels, process launches, and large workflow tests. The serial integration tier includes unrelated tests simply because they flake with concurrent processes. Stable's `full` then `conformance` repeats conformance selections. SwiftPM skip-based serial selection exceeds ARG_MAX at this scale. These are scheduling/model problems, not reasons to remove scientific assertions.

## Proposed canonical model

Create `config/test-catalog.json` (versioned schema) and `scripts/testing/{catalog,planner,runner,evidence,artifact_checks}.py`; preserve `scripts/full-suite-gate.sh` as a thin compatibility adapter during migration. Put test-profile references in release-contract.json; remove copied shell regexes from CI. Catalog defines collections separately from profiles and scheduling.

Collection fields: stable ID, purpose/domain, harness, suite selectors and explicit case overrides, resource requirements, isolation mode, fixture inputs, skip policy, owner, and outcome requirements. Each discovered case resolves to exactly one primary collection; tags may overlap. Audit fails on undiscovered selectors, unassigned discovered cases, ambiguous primary assignments, and empty required collections. Avoid guessing solely from names such as `Integration` or `UI`: audit actual dependencies. Mixed suites need per-case assignment initially, then source splits when worthwhile.

Recommended primary collections:

- `core`: pure models, parsing, coordinates, schema compatibility, serialization.
- `scientific-contracts`: payload correctness, provenance completeness/lineage/final stored paths, failure and cancellation semantics using deterministic fixtures.
- `storage-process`: filesystem transactions, subprocess protocols, cancellation, concurrent ownership; isolated per-test temporary roots and defaults.
- `app-state`: navigation, document lifecycle/state, window ownership decisions and status projection below native AppKit surfaces.
- `tool-conformance`: real pinned executable/runtime behavior; declared required fixtures and tool identity; zero skips when required.
- `release-engine`: release parser/planner/security/evidence/phase orchestration tests using fake services.
- `artifact`: direct checks of the actual candidate and its shipped CLI/resources; this is executable verification, not unittest testing the checker.
- `ui-diagnostics`: native AppKit rendering/layout/panels plus XCUITest launch/menu/open/save/accessibility/visual interactions; specialized explicit use only.
- `extended`: stress, large trees, timing/performance, exhaustive fixture matrices, compatibility corpus and maintainer end-to-end mock release scenarios.

Collection membership is not a claim of cheapness. Domain tags should remain available within extended and diagnostics.

Recommended profiles:

| Profile | Selection and purpose | Release authority |
|---|---|---|
| quick | small deterministic core + scientific sentinel + release policy checks; optional affected collection selection for local feedback | none by itself |
| headless | all core/scientific-contracts/storage-process/app-state, plus inexpensive release-engine contracts; no WindowServer/UI, external network or real tool installs | source validation |
| release | headless + direct artifact verification; preview/stable policy adds required tool conformance by channel | candidate authority only when complete |
| extended | all headless + stress/exhaustive/maintainer transaction matrices | scheduled/explicit maintainer confidence |
| ui | only explicit native AppKit and XCUITest diagnostics | diagnostic report, never hidden prerequisite |
| tool-conformance | pinned installed real tools and fixtures; fail missing prerequisites and skips | required where channel says so |

Do not set new numeric timing claims before the first measured run. Suggested initial feedback objectives are warm quick under a minute and no gate execution on an unchanged package retry; broader budgets should use p50/p95 measurements. Removing UI from routine gates is deliberate requested policy, documented in receipt policy version. It removes release UI automation guarantees; headless replacement covers semantic invariants but does not prove WindowServer rendering or native interactions.

Interfaces: `scripts/test.py list --profile headless --json`, `scripts/test.py audit`, `scripts/test.py run --profile quick`, `scripts/test.py run --profile headless --reuse exact`, `scripts/test.py run --profile ui --collection native-document`, and `scripts/release/release.py package preview --test-profile release`. Prefer a fixed default channel profile with any overrides explicitly nonpublishable; public arbitrary selectors must not manufacture release authority. UI configuration and account provisioning remain callable from the diagnostics front door.

## Scheduling and isolation

Build tests once for the input identity, discover both frameworks once, persist exact test IDs, plan bounded shards, then invoke `--skip-build`. Run bounded XCTest suite/case shards so argument length is independent of total test count. Run Swift Testing separately from XCTest to make each harness's concurrency and completion explicit. Preserve ABI JSON and XCTest completion accounting.

Resource requirements are orthogonal to logical domain: `window-server`, `shared-defaults:<domain>`, `filesystem:<root>`, `managed-environment:<id>`, CPU/memory weight and `network`. A process/session resource lock must span all conflicting shards; `.serialized` alone does not serialize unrelated Swift Testing suites. Limit concurrency using observed cost rather than starting enough child processes to make three-second fake-process readiness deadlines fail.

For headless admission, inject unique UserDefaults suites and temporary storage roots; reset environment and test state via scoped helpers; use readiness handshakes and injected clocks instead of sleeps. Leave unavoidable native UI behavior in diagnostics. Separate fake-process protocol behavior from OS subprocess integration and run only the latter through real child processes. Do not relax deadlines blindly or let a serial rerun change the primary verdict.

## Candidate checks versus maintainer tests

Package should directly validate its real output: bundle and channel identity, expected resources and tool inventory, executable architecture/deployment target, dependency receipt and hashes, CLI startup/version and fixture contract, provenance including final payload pointers, portability, unsigned/signed policy as applicable, and receipt binding. Publish validates exact candidate bytes, signature/notarization/Sparkle/feed state as applicable. These checks run for every new artifact identity, even with cached source tests.

Tests that deliberately corrupt receipts, simulate failed uploads, mock notary tools, or check every coordinator phase are essential tests OF release machinery. Run exhaustive matrices when maintaining that machinery or explicitly requesting extended confidence, not on every packaging retry. Keep a compact outcome-based security/evidence suite in headless; retain all existing maintainer coverage in extended until replacement review establishes equivalence.

Current implementation-mirroring examples: `test_full_suite_gate_tiers.py` pins literal shell variables and CI regex copies; `test_sparkle_release_packaging.py` frequently asserts literal shell snippets and variable assignment spelling. Replace duplicated-source pinning with one catalog plus behavior tests proving discovery partition, profile composition, expected external command ordering/arguments and actual packaged metadata. Keep security boundary assertions, path safety, receipt tamper rejection and negative outcomes. Consolidate channel/invalid-value variants as tables where each row remains separately identifiable. Do not delete cases merely to reduce count: map each old assertion to its retained requirement or demonstrate that it asserts only an implementation detail. Behavioral builder tests and source-string tests are candidates for redundant coverage review, not established interchangeable tests.

## Safe exact-input evidence reuse

Current `run_local_gates` creates a new directory and unconditionally reruns all gates. Current manifest validation binds clean commit, channel, option selections and log hashes; runtime is retained but not matched to a desired runtime. That is insufficient as a new general reuse key.

Introduce evidence schema v2 with an immutable input document and hash covering: clean source tree/commit (initial conservative policy), tests/helpers/gate implementation and policy digest; package lock and all dependency/fixture bytes; exact toolchain/compiler/SDK/build configuration/architecture; test executable and linked resource hashes; selected test IDs and selection digest; concurrency/isolation/options; relevant environment allowlist values, tool executable/container identities, OS identity and prerequisite receipts. Store paths where needed for path-sensitive tests. No raw credentials enter logs or key documents; tests must run with credential-free environment. For mutable network/tool state, require fresh verification or explicitly disable reuse.

A cached passing source result may be reused only if every declared input matches and complete selected/executed/skipped/failure accounting, original exit, all log hashes and authorization validate. Failed/incomplete/retried authoritative evidence stays failed and is never composed with later successes. Keep reuse audit records pointing to immutable original evidence; a cache hit is not a newly executed test. Verify input state before and after execution to detect mutation.

Stage source evidence and artifact evidence separately. Source evidence authorizes the source/test build; artifact evidence binds the archive/app/DMG digest actually delivered. A new packaging attempt may reuse source evidence for the same exact inputs but reruns its actual artifact checks. Changed source or policy initially invalidates all source evidence, even a comment change. Broader dependency-aware cross-commit reuse is a later feature requiring an explicit dependency model; do not smuggle it in via path heuristics. Revalidate live publication state and credential availability at publish even when local evidence is unchanged.

## Migration and acceptance

1. Instrument existing gate timings and expose catalog/discovery audit in shadow mode. No membership changes yet.
2. Create canonical data model and profile planner, replacing shell/CI string duplication with compatibility adapters. Prove old selections equal catalog's legacy profiles and every discovered case is accounted for.
3. Add bounded harness shards/resource scheduling. Test missing/truncated completion, crashes, duplicate/unexpected test IDs and diagnostic retry rejection using compact fixture-driven evidence tests.
4. Add exact-input evidence v2 and package retry reuse. Test a valid hit and each meaningful invalidation class (source, executable, toolchain, dependency, fixture, selection, policy, environment, artifact mutation). Preserve v1 evidence as historical, not silently upgrade it.
5. Adopt new profiles under explicit policy version; move real UI to diagnostics and large/exhaustive maintainer matrices to extended. Headless semantic replacements must preserve document/storage/provenance invariants. Measure before claiming time savings.
6. Consolidate implementation-mirroring tests after a coverage mapping review; gradually modernize expensive mixed Swift suites, rather than wholesale framework conversion.

Acceptance: unchanged package retry does not rerun passed source tests; modified relevant input cannot hit cache; every new artifact is checked; no missing/skipped required provenance/conformance coverage passes; UI never launches in quick/headless/release; all retained tests remain reachable through some documented profile; selection audit finds every case; release credentials unavailable in tests/forks unless separately explicitly configured for publishing.

## Primary-source recommendations and version caveat

Apple documents parallel-by-default Swift Testing, suite-contained `.serialized` behavior and the fact it does not constrain unrelated suites: https://developer.apple.com/documentation/testing/parallelization . Apply resource isolation outside the trait where needed.

Apple documents suite traits inherited by contained tests and separate instance initialization for instance tests: https://developer.apple.com/documentation/testing/organizingtests . Use suite/tag organization for new tests with catalog adapters for XCTest.

Apple supports incremental XCTest migration, recommends struct/actor suites for concurrency enforcement, and explains the main actor difference: https://developer.apple.com/documentation/testing/migratingfromxctest . Its current documentation includes cross-framework assertion interoperability introduced at Swift 6.4; current gate is Swift 6.2.4, where default interoperability is none. Do not share XCTest assertion helpers inside Swift Testing tests without compatible failure propagation; migrate assertions with tests or keep separate helpers. Do not assume current documentation's newer features exist in the pinned release toolchain.

Apple still positions XCTest for UI automation: https://developer.apple.com/documentation/xcode/testing . Retain XCUITest as the specialized diagnostic implementation. Framework replacement alone is not a test architecture or performance solution.
