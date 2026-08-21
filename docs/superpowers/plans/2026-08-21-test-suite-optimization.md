# Test Suite Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute all three phases of the 2026-08-21 test-suite review: mechanical speed fixes, a named tier system wired into the release skill, and structural consolidation of redundant test code.

**Architecture:** The tier system lives in `scripts/full-suite-gate.sh` as `--tier` (filter/skip regexes composed from shared variables), pinned by a Python drift test in `scripts/tests/`. Production seams (`onOpenURLRequested`, Core-level formatters) follow patterns already proven in the repo (TwelveS, LungfishKit). Test consolidation flows into `Tests/Support/LungfishTestSupport`.

**Tech Stack:** Swift 6.2 / SwiftPM, XCTest + swift-testing, bash, Python unittest (scripts/tests).

**Spec:** `docs/reports/2026-08-21-test-suite-review.md` (the review report; its §5 tier model and §6 action plan are the binding requirements).

## Global Constraints

- SwiftPM holds one `.build/.lock` per checkout: NEVER run two `swift build`/`swift test` concurrently; implementers run only the filtered commands their task names, with `--skip-update`.
- Layering: leaf modules and `LungfishKit` never reference `LungfishApp` types; `LungfishCLI` never imports `LungfishKit` (Core/IO/Workflow only).
- Do not enable `swift test --parallel` by default anywhere before Task 12's measurement; until then it is an opt-in flag.
- Never delete a test without either (a) a behavioral equivalent existing/added, or (b) an explicit dispositions entry in the task report.
- Existing drift tests must stay green: `scripts/tests/test_ci_workflow.py` parses the literal `CONFORMANCE_ALLOWLIST=` line in `full-suite-gate.sh` and compares CI filter regexes; do not rename or restructure that line.
- Worktree: `/Users/dho/Documents/lungfish-genome-explorer/.claude/worktrees/test-suite-optimization-b43a51`, branch `claude/test-suite-optimization-b43a51`. Commit per task with conventional prefixes (`test:`, `feat:`, `fix:`, `docs:`, `ci:`).
- macOS 26 API rules apply (no deprecated AppKit patterns).

---

### Task 1: Tier flag in the full-suite gate

**Files:**
- Modify: `scripts/full-suite-gate.sh`
- Modify: `scripts/install-git-hooks.sh` (pre-push hook → `--tier unit`)
- Create: `scripts/tests/test_full_suite_gate_tiers.py`

**Interfaces:**
- Produces: `full-suite-gate.sh --tier smoke|unit|integration|conformance|full`, `--parallel` (opt-in; rejected for `integration`/`full`), `--xunit-output` always written next to the gate log. Tier regex shell variables `SMOKE_FILTER`, `CONFORMANCE_FILTER`, `STORAGE_SUITES`, `CLI_E2E_SUITES`, `INTEGRATION_FILTER` (Tasks 5 and 12 reference these).

- [ ] **Step 1: Add tier definitions to `full-suite-gate.sh`** above `CONFORMANCE_ALLOWLIST` (leave that line byte-identical):

```bash
# --- Green bar (canonical definition) ---------------------------------------
# A run is GREEN iff this gate exits 0: zero XCTest failures, zero swift-testing
# failures, and (under --require-tools) zero skips in the conformance suites.
# There are no standing known-environmental failures: the formerly-failing
# environmental tests (GenotypeRealBundleSmokeTests, ZhangArtifactCanaryTests,
# VCFRobustnessTests) now skip cleanly when their env vars/fixtures are absent.

# --- Tiers ------------------------------------------------------------------
# smoke        provenance + core-model spot checks (mirrors the CI smoke regex)
# unit         everything EXCEPT integration/conformance suites (skip-composed)
# integration  LungfishIntegrationTests + CLI process-fork suites + storage suites
# conformance  real-tool suites (combine with --require-tools to forbid skips)
# full         the entire suite (default when no --tier/--filter is given)
SMOKE_FILTER='^(LungfishCoreTests\.(BundleManifestTests|GenomicRegionTests|RuntimeResourceLocatorTests|SequenceTests)|LungfishWorkflowTests\.(BAMPrimerTrimProvenanceTests|MappingProvenanceTests|ScientificProvenancePolicyTests)|LungfishCLITests\.ScientificCLIProvenanceCoverageTests)(/|$)'
CONFORMANCE_FILTER='Conformance|FASTQToolIntegrationTests|RecipeIntegrationTests|NativeToolRunnerTests|MAFFTAlignmentPipelineTests|ClassificationPipelineIntegrationTests|ReadsToVariantsEndToEndTests|BAMPrimerTrimSubcommandTests|IVarConverterViralReconParityTests|FASTQIngestionPipelineTests|FASTQBatchImporterRecipeIntegrationTests|GenotypeWorkbookManagedRuntimeProbeTests|FASTQOperationRoundTripTests|FastqGenotypingCommandTests|PrimerTrimThenIVarTests|ExtractReadsByIdBAMProcessTests'
STORAGE_SUITES='ProjectStorageScannerLargeTreeTests|ProjectStorageScannerTests|ProjectStorageCleanupPreparationLargeTreeTests|ProjectStorageCleanupProvenanceTests|ProjectStoragePublishedCleanupOutcomeReaderTests|ProjectStorageAutomaticCleanupServiceTests|ProjectStoragePerformanceTests|ProjectTempCleanupTests'
CLI_E2E_SUITES='CLIExitCodeProcessTests|ToolsCommandTests|DbCommandUpdateTargetTests|ImportFastqE2ETests|CLIBAMFilteringIntegrationTests|MarkdupCommandTests'
INTEGRATION_FILTER="^LungfishIntegrationTests\\.|${CLI_E2E_SUITES}|${STORAGE_SUITES}"
```

- [ ] **Step 2: Parse `--tier`, `--parallel`** in the arg loop (same guarded style as `--filter`); after the loop resolve:

```bash
if [ -n "$TIER" ] && [ -n "$FILTER" ]; then
    echo "--tier and --filter are mutually exclusive" >&2; exit 64
fi
case "$TIER" in
    "") ;;
    smoke)        FILTER="$SMOKE_FILTER" ;;
    unit)         SKIP="${INTEGRATION_FILTER}|${CONFORMANCE_FILTER}" ;;
    integration)  FILTER="$INTEGRATION_FILTER" ;;
    conformance)  FILTER="$CONFORMANCE_FILTER" ;;
    full) ;;
    *) echo "unknown tier: $TIER (smoke|unit|integration|conformance|full)" >&2; exit 64 ;;
esac
if [ "$PARALLEL" -eq 1 ] && { [ "$TIER" = "integration" ] || [ "$TIER" = "full" ] || [ -z "$TIER$FILTER" ]; }; then
    echo "--parallel is not allowed for tiers containing the ProjectStorage suites (integration/full)" >&2; exit 64
fi
```

In `run_gate`, append `--skip "$SKIP"` when non-empty, `--parallel` when requested, and always `--xunit-output "$LOG_DIR/gate-${STAMP}-${SHA}.xunit.xml"`. Log the tier in the header block. Update the usage comment at the top of the file.

- [ ] **Step 3: Point the pre-push hook at the unit tier** — in `scripts/install-git-hooks.sh`, change the gate invocation to `full-suite-gate.sh --tier unit` and update its comment to say the full tier remains the stable-release gate.

- [ ] **Step 4: Write `scripts/tests/test_full_suite_gate_tiers.py`** (unittest, style-matched to `test_ci_workflow.py`), asserting: (a) the gate defines exactly the five tiers; (b) `CONFORMANCE_FILTER` in the gate equals the `toolset-conformance` job's `--filter` string in `.github/workflows/ci.yml`; (c) `SMOKE_FILTER` equals the CI smoke-step regex; (d) `STORAGE_SUITES` equals the CI project-storage `--no-parallel` filter; (e) the unit tier's skip is the literal composition `${INTEGRATION_FILTER}|${CONFORMANCE_FILTER}`; (f) `--parallel` is rejected for integration/full (assert the guard text exists).

- [ ] **Step 5: Verify** — `bash -n scripts/full-suite-gate.sh`; `python3 -m unittest discover -s scripts/tests -p 'test_full_suite_gate_tiers.py' -v`; `python3 -m unittest discover -s scripts/tests -v` (all existing script tests still pass); `scripts/full-suite-gate.sh --tier bogus` exits 64; `scripts/full-suite-gate.sh --tier full --parallel` exits 64.

- [ ] **Step 6: Commit** — `ci: add named test tiers to the full-suite gate`

### Task 2: URL-open seam for NaoMgs and Nvd result view controllers

**Files:**
- Modify: `Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift` (open calls at ~:2373, :2388, :2395)
- Modify: `Sources/LungfishNvdUI/NvdResultViewController.swift` (`contextViewAccessionOnNCBI` ~:2076, `contextSearchPubMed` ~:2083)
- Modify: `Tests/LungfishNaoMgsUITests/NaoMgsResultViewControllerSmokeTests.swift` (test at ~:1179)
- Test: add URL-capture tests in the NaoMgs and Nvd test targets

**Interfaces:**
- Produces: `public var onOpenURLRequested: ((URL) -> Void)?` on both view controllers — identical to `TwelveSAmpliconResultViewController.swift:328`.

- [ ] **Step 1:** Read the proven pattern first: `Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift:328` and `:1097`, and `Tests/LungfishTwelveSUITests/TwelveSCopyMenuTests.swift:98-110`.
- [ ] **Step 2:** Add to both VCs: `public var onOpenURLRequested: ((URL) -> Void)?`. At every `NSWorkspace.shared.open(url)` call site in the two VCs replace with:

```swift
if let handler = onOpenURLRequested { handler(url) } else { NSWorkspace.shared.open(url) }
```

- [ ] **Step 3:** Rewrite `testViewAccessionOnNCBIDoesNotCrashForMalformedAccession`: install `vc.onOpenURLRequested = { opened.append($0) }` before triggering the menu action; assert `opened.count == 1` and `opened[0].absoluteString.contains("ncbi.nlm.nih.gov/nuccore")` (Foundation percent-encodes the spaces; assert containment, not equality). Add a well-formed-accession sibling test asserting the exact URL. Add equivalent capture tests for the two Nvd context actions in `Tests/LungfishNvdUITests/`.
- [ ] **Step 4:** Verify: `swift test --skip-update --filter 'LungfishNaoMgsUITests|LungfishNvdUITests'` — all pass, and no browser window opens during the run.
- [ ] **Step 5:** Commit — `fix: inject URL opening in NaoMgs/Nvd result VCs so tests stop launching the browser`

### Task 3: Process-wait and CLI-binary-resolution overhead

**Files:**
- Modify: `Tests/Support/LungfishTestSupport/ToolAvailability.swift:132-135`
- Modify: `Tests/LungfishCLITests/CLIExitCodeProcessTests.swift:11`

**Interfaces:** none new; `ProcessRunner.run` keeps its exact signature and timeout semantics.

- [ ] **Step 1:** In `ProcessRunner.run`, replace the 50 ms `Thread.sleep` poll loop with a `DispatchSemaphore` signaled from `process.terminationHandler` (set before launch), waiting with `.now() + remaining`; on timeout, keep the existing terminate/kill behavior exactly.
- [ ] **Step 2:** In `CLIExitCodeProcessTests`, change the computed `cliBinaryURL` property to a cached `static let` (resolve once per class).
- [ ] **Step 3:** Verify: `swift test --skip-update --filter 'ToolAvailabilityTests|CLIExitCodeProcessTests'`.
- [ ] **Step 4:** Commit — `test: event-driven process waits and cached CLI binary resolution`

### Task 4: Cap the worst unconditional sleeps

**Files (exact sites, from the review):**
- `Tests/LungfishWorkflowTests/SavontClusteringPipelineTests.swift:825` — 60 s → 5 s
- `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseInstallerTests.swift:716` — 60 s → 5 s
- `Tests/LungfishAppTests/ProjectStorageSheetViewModelTests.swift:1200,2112` — 30 s → 5 s
- `Tests/LungfishAppTests/AlignmentScientificActionCoordinatorTests.swift:119` (10 s), `:483` (5 s) → 2 s each
- `Tests/LungfishAppTests/FASTACollectionViewerRoutingTests.swift:130` — 10 s → 2 s
- `Tests/LungfishWorkflowTests/Mapping/MappingSummaryBuilderTests.swift:422` — 5 s → 2 s
- `Tests/LungfishWorkflowTests/PluginPackStatusServiceTests.swift` — the two 500 ms sleeps → 50 ms polling loops with a 2 s deadline

**Rules:** These long sleeps sit inside tasks the test cancels, so they only cost time when cancellation regresses — the change bounds the failure mode. Do NOT touch `Tests/LungfishAppTests/FileSystemWatcherTests.swift` (FSEvents settle times are empirical; that file is flake-sensitive). Do not change any assertion.

- [ ] **Step 1:** Apply the listed reductions; where a sleep is a genuine wait-for-condition (PluginPackStatusServiceTests), convert to a polling loop.
- [ ] **Step 2:** Verify: `swift test --skip-update --filter 'SavontClusteringPipelineTests|MetagenomicsDatabaseInstallerTests|ProjectStorageSheetViewModelTests|AlignmentScientificActionCoordinatorTests|FASTACollectionViewerRoutingTests|MappingSummaryBuilderTests|PluginPackStatusServiceTests'`.
- [ ] **Step 3:** Commit — `test: bound worst-case sleep ceilings in cancellation tests`

### Task 5: Release skill conforms to the tier model

**Files:**
- Modify: `.codex/skills/releasing-lungfish/SKILL.md` (Gate 5, Gate 9/Evidence)
- Modify: `.codex/skills/releasing-lungfish/scripts/validate.py`

**Interfaces:**
- Consumes: Task 1's `--tier` flag.

- [ ] **Step 1:** Rewrite SKILL.md Gate 5's test sentence to be channel-conditional: preview channel = focused release tests + `bash scripts/full-suite-gate.sh --tier unit` + `bash scripts/full-suite-gate.sh --tier integration`; stable channel = focused release tests + `bash scripts/full-suite-gate.sh --tier full` + `bash scripts/full-suite-gate.sh --tier conformance --require-tools` + the XCUI pass via `scripts/testing/run-macos-xcui.sh`. Keep every non-test clause of Gate 5 (diff check, old-version scans, validator, preflights) intact for both channels. Add the XCUI result to the Evidence Report list.
- [ ] **Step 2:** In `validate.py`, append to `REQUIRED_FILES`: `scripts/full-suite-gate.sh`, `scripts/testing/run-macos-xcui.sh`; add a check that the gate script text contains `--tier` and all five tier names; append `--tier unit`, `--tier full`, `--tier conformance --require-tools`, `run-macos-xcui.sh` to `REQUIRED_SKILL_MARKERS`.
- [ ] **Step 3:** Verify: `python3 .codex/skills/releasing-lungfish/scripts/validate.py --repo-root "$PWD"` passes; `python3 -m unittest discover -s scripts/tests -v` still passes.
- [ ] **Step 4:** Commit — `docs: tier-aware release gates in the releasing-lungfish skill`

### Task 6: ENA mock coverage and NCBI transient wrappers

**Files:**
- Create: `Tests/LungfishCoreTests/Services/ENAServiceTests.swift`
- Modify: `Tests/LungfishCoreTests/Services/DatabaseServiceIntegrationTests.swift`

**Interfaces:**
- Consumes: `MockHTTPClient` (`Tests/LungfishCoreTests/Services/Mocks/MockHTTPClient.swift`), `ENAService` (`Sources/LungfishCore/Services/` — injectable `httpClient:`).

- [ ] **Step 1:** TDD `ENAServiceTests` against `MockHTTPClient` covering each public `ENAService` behavior (`search`, `searchReads`, `searchReadsBatch`, `fetchFASTA`): a happy path with a canned realistic payload, an HTTP-error path, and a malformed-payload path each. Mirror the structure of `NCBIServiceTests` in the same directory.
- [ ] **Step 2:** In `DatabaseServiceIntegrationTests`, wrap the bodies of the 6 tests lacking transient handling (`testNCBIFetchGenBank`, `testENASearch`, `testENAFetchFASTA`, `testNCBIFetchRawGenBankPreservesAnnotations`, `testDownloadGenBankToFile`, `testDownloadToTemporaryFile`) with the same `transientLiveNCBISkipReason(_:)` do/catch pattern `testNCBISearch` already uses.
- [ ] **Step 3:** Verify: `swift test --skip-update --filter 'ENAServiceTests|DatabaseServiceIntegrationTests'` (the live tests skip; the mocks pass).
- [ ] **Step 4:** Commit — `test: mocked ENAService coverage; transient-skip wrappers for live NCBI tests`

### Task 7: Finish the formatter consolidation (production fix)

**Files:**
- Create: `Sources/LungfishCore/LungfishFormatters.swift` (moved from Kit)
- Delete: `Sources/LungfishKit/Formatters.swift`
- Modify: the 7 LungfishApp private copies (`AppDelegate`, `BundleBuildHelpers`, `ProvenanceInspectorViewModel` ×2, `PluginManagerView`, `FASTQImportConfigSheet`, `NvdImportSheet`) and `Sources/LungfishCLI/CondaCommand` — call `LungfishFormatters` instead
- Modify: `Tests/LungfishKitTests/LungfishFormattersTests.swift` (imports `LungfishCore`; keep all assertions)
- Modify: `Tests/LungfishAppTests/ProjectTempCleanupTests.swift:283-318` — delete the 5 duplicate `formatBytes` tests

**Interfaces:**
- Produces: `LungfishFormatters` now lives in `LungfishCore` (CLI may import Core; Kit clients gain it transitively but add explicit `import LungfishCore` where the compiler requires it).

- [ ] **Step 1:** `git mv` the enum to Core; fix imports across Kit/App/CLI until `swift build --skip-update` is clean.
- [ ] **Step 2:** For each replaced private copy, first compare its output behavior against `LungfishFormatters` (rounding, unit thresholds, zero/negative handling). If any copy differs, KEEP its call sites' visible behavior by noting the difference in the report and asserting the canonical behavior in a new test — do not silently change user-visible strings without flagging it.
- [ ] **Step 3:** Verify: `swift test --skip-update --filter 'LungfishFormattersTests|ProjectTempCleanupTests|CondaManagerTests'`.
- [ ] **Step 4:** Commit — `fix: complete formatter consolidation onto LungfishCore (F44-F46)`

### Task 8: Shared fixtures — temp dirs and genotype builders

**Files:**
- Create: `Tests/Support/LungfishTestSupport/TestTempDirectory.swift`
- Create: `Tests/Support/LungfishTestSupport/GenotypeTestFixtures.swift`
- Modify: `Package.swift` — add `"LungfishTestSupport"` to the dependencies of `LungfishCoreTests`, `LungfishKitTests`, `LungfishGenotypeUITests`
- Modify: genotype-cluster test files in IO/GenotypeUI/CLI/App/Workflow that define private `makeCall`/`makeResult` builders — adopt the shared ones

**Interfaces:**
- Produces:

```swift
public enum TestTempDirectory {
    /// Creates a unique directory under FileManager's temporaryDirectory and
    /// returns it; caller removes it in defer/tearDown (helper also provides
    /// `cleanup(_:)` that ignores errors).
    public static func make(prefix: String = "lungfish-test") throws -> URL
    public static func cleanup(_ url: URL)
}
```

and `GenotypeTestFixtures` exposing the canonical `makeCall(...)`/`makeResult(...)` builders with the superset of parameters the five private copies use (defaulted so existing call sites map 1:1).

- [ ] **Step 1:** Inventory the private `makeCall`/`makeResult` builders across the five targets (grep `func makeCall`/`func makeResult` under Tests/); design the shared signatures as the parameter superset.
- [ ] **Step 2:** Implement the two Support files; wire Package.swift.
- [ ] **Step 3:** Migrate the genotype-cluster files (all files matching `*Genotype*` in Tests/ that define private builders) to the shared fixtures; migrate per-test temp-dir helpers to `TestTempDirectory` in the same files while there. Do not chase the long tail outside the genotype cluster in this task.
- [ ] **Step 4:** Verify: `swift test --skip-update --filter 'Genotype'` (the full genotype cluster) passes with identical test counts before/after (capture counts from the run tail).
- [ ] **Step 5:** Commit — `test: shared temp-dir and genotype fixture builders in LungfishTestSupport`

### Task 9: Split the 26K-line viewport test file

**Files:**
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift` → split into ~8 files, each its own `XCTestCase` class named `GenotypeResultViewport<Aspect>Tests`, grouped by test-name prefix/topic; shared helpers move to `Tests/LungfishGenotypeUITests/GenotypeResultViewportTestSupport.swift`.

**Rules:** Pure mechanical move — no test body changes, no renames of test methods. New classes enable future per-class parallelism.

- [ ] **Step 1:** Record the before count: `swift test --skip-update list 2>/dev/null | grep -c 'GenotypeResultViewport'` (or run the filter and read the executed count).
- [ ] **Step 2:** Split; keep `setUp` logic in the shared support file (each class subclasses a common base or calls shared helpers).
- [ ] **Step 3:** Verify: same command shows an identical test count; `swift test --skip-update --filter 'GenotypeResultViewport'` passes.
- [ ] **Step 4:** Commit — `test: split GenotypeResultViewportTests into per-aspect classes`

### Task 10: Retire the worst source-text assertion files

**Files (this tranche — the four worst + next six by count):** `Tests/LungfishAppTests/WindowAppearanceTests.swift` (64), `Tests/LungfishAppTests/FASTQOperationToolPanesSourceTests.swift` (43), `Tests/LungfishAppTests/SettingsAndImportXCUIReadinessTests.swift` (41), `Tests/LungfishAppTests/GenotypeCallEvidenceViewTests.swift` (40), then the next six files by `source.contains` count (grep to enumerate).

**Rubric (binding, per assertion):**
1. If a behavioral test for the same behavior already exists (search the target for the SUT symbol), delete the source-text assertion.
2. If the behavior is testable through an existing runtime seam (a view model property, an injected closure, an accessibility identifier), convert to a behavioral assertion.
3. If there is no runtime seam and adding one is out of scope, keep the assertion and tag it `// source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3`.
4. Record a dispositions table (file → deleted/converted/kept counts) in the task report.

- [ ] **Step 1:** Enumerate the tranche: `grep -rc 'source.contains' Tests/LungfishAppTests --include='*.swift' | sort -t: -k2 -rn | head -10`.
- [ ] **Step 2:** Apply the rubric file by file.
- [ ] **Step 3:** Verify: `swift test --skip-update --filter '<the modified classes joined by |>'`.
- [ ] **Step 4:** Commit — `test: replace source-text assertions with behavioral checks (tranche 1)`

### Task 11: Split AppKit-view tests out of LungfishAppTests

**Files:**
- Modify: `Package.swift` — new test target:

```swift
.testTarget(
    name: "LungfishAppViewTests",
    dependencies: ["LungfishApp", "LungfishKit", "LungfishCLI", "LungfishNvdUI", "LungfishNaoMgsUI", "LungfishTaxTriageUI", "LungfishEsVirituUI", "LungfishGenotypeUI", "LungfishPhylogeneticsUI", "LungfishTestSupport"],
    path: "Tests/LungfishAppViewTests"
),
```

- Move (git mv): the LungfishAppTests files that instantiate `NSWindow`/`NSViewController`/`NSApplication.shared` (~44 files; enumerate by grep) into `Tests/LungfishAppViewTests/`.

**Rules:** Helpers used by both halves move to `LungfishTestSupport` (or are duplicated only if <20 lines and Support promotion would drag App-only types). `@testable import LungfishApp` continues to work in both targets. Test bodies unchanged.

- [ ] **Step 1:** Enumerate movers: `grep -rlE 'NSWindow\(|NSViewController\(|NSApplication\.shared' Tests/LungfishAppTests --include='*.swift'`. Files matched only via helper usage stay put unless compilation forces the move.
- [ ] **Step 2:** Add the target, `git mv` the files, resolve helper fallout.
- [ ] **Step 3:** Verify: `swift test --skip-update --filter '^LungfishAppViewTests\.'` passes and `swift test --skip-update --filter '^LungfishAppTests\.'` passes; combined executed count matches the pre-split count for the same set (record both).
- [ ] **Step 4:** Commit — `test: extract AppKit-view tests into LungfishAppViewTests`

### Task 12: Measure and adopt parallel execution

**Files:**
- Modify: `scripts/full-suite-gate.sh` (only if measurement is green: make `--tier unit` default to `--parallel`, add `--serial` escape)
- Modify: `docs/reports/2026-05-31-fast-iteration-workflow.md` (document tier usage + timings)

- [ ] **Step 1:** Timed serial baseline: `time bash scripts/full-suite-gate.sh --tier unit`.
- [ ] **Step 2:** Timed parallel run: `time bash scripts/full-suite-gate.sh --tier unit --parallel`. Compare failures: any test failing in parallel but passing serial is a parallelism hazard — list them; if ≤5 hazards, mark those classes into the integration tier's skip-composition instead of blocking adoption; if more, do NOT flip the default and record the hazard list.
- [ ] **Step 3:** If green: flip unit's default to parallel (with `--serial` escape) and update the drift test. Record both timings in the workflow doc.
- [ ] **Step 4:** Commit — `ci: adopt parallel unit tier (measured)` or `docs: record parallel-tier measurement (not adopted)` as measured.

### Task 13: Final verification and campaign report

- [ ] **Step 1:** Run the canonical serial full gate: `bash scripts/full-suite-gate.sh --tier full --bg`, monitor to completion; GREEN per the gate's definition.
- [ ] **Step 2:** Run `python3 -m unittest discover -s scripts/tests -v` and the release-skill validator one final time.
- [ ] **Step 3:** Append a results addendum to `docs/reports/2026-08-21-test-suite-review.md` (what shipped, timings, dispositions, what remains of items 9/11 long tails).
- [ ] **Step 4:** Commit — `docs: test-suite optimization campaign results`
