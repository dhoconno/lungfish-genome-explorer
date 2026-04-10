# Phase Review Reports — Unified Classifier Extraction

This directory holds the adversarial review reports and simplification notes
produced by the four-gate review architecture defined in the implementation plan
at `docs/superpowers/plans/2026-04-08-unified-classifier-extraction.md`.

Each phase produces:

- `phase-N-review-1.md` — First adversarial review (independent, pre-simplification)
- `phase-N-review-2.md` — Second adversarial review (independent, post-simplification)

Phase 0 has no review (it is pre-flight only). Phases 1–7 each produce both files.
Phase 8 is final validation and may produce a single `phase-8-validation.md` report.

Spec: `docs/superpowers/specs/2026-04-08-unified-classifier-extraction-design.md`

## Baseline (Phase 0, 2026-04-09)

Recorded after Phase 0 fixed 4 stale "drift" tests (3 `allCases` count
expectations and 1 URL allowlist) that were unrelated to this work.

- **XCTest:** 6277 tests, 25 skipped, 4 unique failing test methods (counted
  as 7 assertion errors by XCTest because two methods produce multiple errors).
- **swift-testing:** 189 tests in 36 suites, all passing.
- **Build:** clean (only pre-existing warnings in plugins and unrelated tests).

The 4 unique floor failures every Phase Gate 4 must respect (i.e. they may
remain failing but no NEW failures may be introduced):

1. `LungfishAppTests.FASTQProjectSimulationTests.testSimulatedProjectVirtualOperationsCreateConsistentChildBundles`
   — pre-existing relative-path bug in virtual FASTQ child bundles.
2. `LungfishWorkflowTests.NativeToolRunnerTests.testValidateToolsInstallation`
   — environmental: `deacon` is conda-installed and not present in the
   developer's tools directory; passes in CI.
3. `LungfishIOTests.TaxonNodeRegressionTests.testEquatable`
   — pre-existing TaxonNode equality regression (clade/direct counts not
   distinguishing).
4. `LungfishIOTests.TaxonNodeRegressionTests.testHashable`
   — same root cause as `testEquatable`.

Additionally, four NCBI/SRA network-dependent tests in
`LungfishCoreTests.DatabaseServiceIntegrationTests` are flaky and may flicker
red across runs (HTTP 500 / connection failures). They are documented in
MEMORY.md and are NOT counted as the floor — Phase Gate 4 ignores their state.

## Floor amendment after Phase 2 Gate 4 (2026-04-09)

`LungfishIntegrationTests.ReadExtractionServiceTests.testExtractByBAMRegionReportsProgress`
is added to the floor as a **load-dependent intermittent flake**. The test
passes when run in isolation (3-of-3 verified) but fails intermittently in
the full suite. The race lives entirely in the test itself — a fire-and-forget
`Task { await accumulator.append(...) }` inside the progress callback can
race with the immediately-following `await accumulator.getCalls()` if the
last `Task` has not yet completed. Phase 2's added tests (20 new
ClassifierReadResolverTests) increased the parallel test load enough to
expose the race. Phase 2 did NOT modify the test, the production
`extractByBAMRegion` method, or its progress-callback contract. The test
itself should be fixed by whoever owns it (e.g. by removing the inner `Task`
or by adding an explicit synchronization point), but the fix is out of
scope for the unified classifier extraction work.

Future Gate 4 runs in this feature branch should treat this test as
expected-to-flicker; a single run showing it failing is NOT a regression.

## Phase 3 Gate 4 closure (2026-04-09)

Run at commit `6b3b106` (simplification-pass head).

- **Build:** `swift build --build-tests` — clean.
- **swift-testing:** 189 tests in 36 suites — all passing.
- **XCTest:** 6343 tests, 26 skipped, 8 assertion errors across 5 unique
  failing methods.
  - 6343 = 6314 (Phase 2 baseline) + 29 new `ExtractReadsByClassifierCLITests` ✓
  - 26 skipped = unchanged from Phase 2 (no new skips introduced) ✓

### Floor comparison (Phase 2 → Phase 3)

| # | Test | Phase 2 | Phase 3 | Status |
|---|------|---------|---------|--------|
| 1 | `FASTQProjectSimulationTests.testSimulatedProjectVirtualOperationsCreateConsistentChildBundles` | failing (3 assertion errors) | failing (3 assertion errors) | floor, unchanged |
| 2 | `NativeToolRunnerTests.testValidateToolsInstallation` | failing (2 assertion errors) | failing (2 assertion errors) | floor, unchanged |
| 3 | `TaxonNodeRegressionTests.testEquatable` | failing | failing | floor, unchanged |
| 4 | `TaxonNodeRegressionTests.testHashable` | failing | failing | floor, unchanged |
| 5 | `ReadExtractionServiceTests.testExtractByBAMRegionReportsProgress` | failing (load-dependent flake) | **passing** | floor flake, passed this run |

Network-dependent `DatabaseServiceIntegrationTests.testSRASearch` failed
this run with `fetchFailed("Failed to fetch run info")` — documented as
an NCBI/SRA network flake, NOT counted as the floor per the Phase 0
baseline note above.

### Filtered suite

`swift test --filter LungfishCLITests` — **363 tests, 0 failures**.
`swift test --filter ExtractReadsByClassifierCLITests` — **29 tests, 0 failures**.

### Gate 4 verdict

**PASS.** Phase 3 closes cleanly. The 4 permanent floor failures are
unchanged. The 5th (load-dependent flake) passed in this run.
No new failures introduced by Phase 3. All 29 new
`ExtractReadsByClassifierCLITests` pass. Build clean.

**Phase 3 is closed. Phase 4 may begin.**

## Phase 4 Gate 4 closure (2026-04-09)

Run at commit `4598784` (Gate-3 critical fix head).

- **Build:** `swift build --build-tests` — clean.
- **swift-testing:** 189 tests in 36 suites — all passing.
- **XCTest:** 6367 tests, 26 skipped, 7 assertion errors across 4 unique
  failing methods.
  - 6367 = 6343 (Phase 3 baseline) + 24 new `ClassifierExtractionDialogTests` ✓
  - 26 skipped = unchanged from Phase 3 (no new skips introduced) ✓

### Floor comparison (Phase 3 → Phase 4)

| # | Test | Phase 3 | Phase 4 | Status |
|---|------|---------|---------|--------|
| 1 | `FASTQProjectSimulationTests.testSimulatedProjectVirtualOperationsCreateConsistentChildBundles` | failing (3 assertion errors) | failing (3 assertion errors) | floor, unchanged |
| 2 | `NativeToolRunnerTests.testValidateToolsInstallation` | failing (2 assertion errors) | failing (2 assertion errors) | floor, unchanged |
| 3 | `TaxonNodeRegressionTests.testEquatable` | failing | failing | floor, unchanged |
| 4 | `TaxonNodeRegressionTests.testHashable` | failing | failing | floor, unchanged |
| 5 | `ReadExtractionServiceTests.testExtractByBAMRegionReportsProgress` | passing (flake) | **passing** | floor flake, passed this run |

The network-dependent `DatabaseServiceIntegrationTests.testSRASearch`
passed this run (it failed in the Phase 3 Gate 4 run due to an NCBI
API flake; it is not counted as the floor).

### Filtered suites

- `swift test --filter ClassifierExtractionDialogTests` — **24 tests, 0 failures**.
- `swift test --filter LungfishCLITests` — **363 tests, 0 failures** (Phase 3 CLI contract intact).

### Gate 4 verdict

**PASS.** Phase 4 closes cleanly. The 4 permanent floor failures are
unchanged. The 5th (load-dependent flake) passed again. The NCBI SRA
network flake also passed this run (down from the Phase 3 Gate 4 run
where it fired). No new failures introduced by Phase 4. All 24 new
`ClassifierExtractionDialogTests` pass. Build clean.

**Phase 4 is closed. Phase 5 may begin.**

## Phase 5 Gate 4 closure (2026-04-09)

Run at commit `451b557` (Gate-3 critical fix for Kraken2 layout
mis-classification).

- **Build:** `swift build --build-tests` — clean.
- **swift-testing:** 189 tests in 36 suites — all passing.
- **XCTest:** 6371 tests, 26 skipped, 7 assertion errors across 4 unique
  failing methods (same 4 as Phase 4).
  - 6371 = 6367 (Phase 4 baseline) + 4 new `ClassifierToolLayoutTests` ✓
  - 26 skipped = unchanged from Phase 4 (no new skips introduced) ✓

### Floor comparison (Phase 4 → Phase 5)

| # | Test | Phase 4 | Phase 5 | Status |
|---|------|---------|---------|--------|
| 1 | `FASTQProjectSimulationTests.testSimulatedProjectVirtualOperationsCreateConsistentChildBundles` | failing (3 errors) | failing (3 errors) | floor, unchanged |
| 2 | `NativeToolRunnerTests.testValidateToolsInstallation` | failing (2 errors) | failing (2 errors) | floor, unchanged |
| 3 | `TaxonNodeRegressionTests.testEquatable` | failing | failing | floor, unchanged |
| 4 | `TaxonNodeRegressionTests.testHashable` | failing | failing | floor, unchanged |
| 5 | `ReadExtractionServiceTests.testExtractByBAMRegionReportsProgress` | passing (flake) | passing (flake) | floor flake, passed |

The network-dependent `DatabaseServiceIntegrationTests.testSRASearch`
passed this run.

### Filtered suites

- `swift test --filter ClassifierToolLayoutTests` — **4 tests, 0 failures**.
- `swift test --filter ClassifierExtractionDialogTests` — **24 tests, 0 failures** (Phase 4 contract intact).
- `swift test --filter ExtractReadsByClassifierCLITests` — **29 tests, 0 failures** (Phase 3 contract intact).
- `swift test --filter TaxonomyViewControllerTests` — **20 tests, 0 failures**.

### Phase 5 stub eradication

`swift build --build-tests 2>&1 | grep "phase5: old extraction sheet removed"` → **0 hits**. All 5 Phase 1 stubs (EsViritu, TaxTriage, NAO-MGS, NVD, Kraken2/TaxonomyViewController) are gone. The classifier VCs all route through `TaxonomyReadExtractionAction.shared.present(...)`.

### Per-classifier line counts (≤ 40 line target)

| Classifier | Helpers | Wiring | Total | vs 40 |
|------------|--------:|-------:|------:|------:|
| EsViritu   | 16      | 12     | 28    | OK    |
| TaxTriage  | 21      |  9     | 30    | OK    |
| NAO-MGS    | 26      |  6     | 32    | OK    |
| NVD        | 22      | 15     | 37    | OK    |
| Kraken2    | 26      | 14     | 40    | OK (exactly at target) |

All 5 classifiers within budget. The shared
`NSViewController.presentClassifierExtractionDialog` extension
(`ClassifierExtractionDialogPresenting.swift`) shrinks each VC's
`presentUnifiedExtractionDialog` from ~15 to ~5 lines. Kraken2's
`buildKraken2Selectors(explicit:)` override fixes the
chart-context-menu filter regression that review-1 caught.

### Gate 4 verdict

**PASS.** Phase 5 closes cleanly. The 4 permanent floor failures are
unchanged. No new failures introduced by Phase 5. All 4 new
`ClassifierToolLayoutTests` pass, all 24 `ClassifierExtractionDialogTests`
still pass (Phase 4 contract intact), all 29
`ExtractReadsByClassifierCLITests` still pass (Phase 3 contract intact).
Build clean. All 5 classifiers under the 40-line budget. Zero `phase5:`
warnings remain. The AppDelegate auto-extract path at line 5305 is
rewired to call `TaxonomyReadExtractionAction.shared.present(...)`.

**Phase 5 is closed. Phase 6 may begin.**

## Phase 6 Gate 4 closure (2026-04-09)

Run after Phase 6 simplification pass (commit `3aa8c62`, review-1 disposition).

- **Build:** `swift build --build-tests` — clean.
- **swift-testing:** 189 tests — all passing.
- **XCTest:** 6395 tests, 27 skipped, 7 assertion errors across the same 4 unique Phase 5 floor methods.
  - 6395 = 6371 (Phase 5 baseline) + 24 new `ClassifierExtractionInvariantTests` ✓
  - 27 skipped = 26 (Phase 5) + 1 new (Kraken2 I7 round-trip, fixture incomplete per Phase 7) ✓
- **Invariant suite runtime:** ~2.4s (48% of the 5-second budget).

### I4 fixture teeth verified

Augmented `Tests/Fixtures/sarscov2/test.paired_end.sorted.markers.bam`:
- raw total: 203
- `-F 0x404` filtered: 199
- `-F 0x400` filtered: 202
- Contains 1 secondary (0x100), 1 supplementary (0x800), 1 duplicate (0x400), 3 unmapped (0x004).

The Phase 2 review-2 forwarded I4 fixture-teeth requirement is **resolved**. Any regression that removes the `0x404` mask from the resolver or MarkdupService will now fail the I4 invariant.

### Floor comparison (Phase 5 → Phase 6)

Same 4 unique failing methods as Phase 5. Zero new regressions.

**Phase 6 is closed. Phase 7 may begin.**
