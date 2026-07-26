# Genotype Matrix Projection Legacy Baseline

Date: 2026-07-25

Branch: `codex/genotype-view-accessibility-filters`

Baseline commit: `587d69097dd153e26475341b39bf3943e0b7cb4b`

## Scope and conclusion

This checkpoint records the legacy Release observations available before Task
6 replaces the synchronous genotype matrix projection. It changes no
production or test code.

The repository contains the approved fixture shapes:

- `testConfigureRetainedDemuxSizedBundleDoesNotBlockViewportLoad` creates 52
  samples × 120 rows = 6,240 calls, configures the result controller, and
  renders 30 visible rows.
- `testComparisonMatrixShowsEverySampleColumnByDefault` creates the existing
  150-sample column stress matrix and asserts that all 150 columns are
  instantiated without column windowing.

The legacy fixtures do **not** isolate a threshold projection or expose the
Task 6 timers and operation counters. Therefore, the values below are whole
XCTest-case observations only. They are not evidence for the approved
post-Task-6 budgets of a maximum 50 ms derived pass or 100 ms visible settle.

## Runtime context

| Item | Value |
| --- | --- |
| Hardware | Apple M4 Pro, 14 physical/logical CPUs |
| Memory | 51,539,607,552 bytes (48 GiB) |
| Architecture | arm64 |
| macOS | 26.5.2 (25F84) |
| Xcode | 26.6 (17F113) |
| Swift | 6.3.3 (`swiftlang-6.3.3.1.3 clang-2100.1.1.101`) |
| Swift target | `arm64-apple-macosx26.0` |
| Configuration | SwiftPM Release (`-O`) with `-DDEBUG` solely to include the repository's existing test hooks |
| Test bundle | `.build/arm64-apple-macosx/release/LungfishGenomeBrowserPackageTests.xctest` |

## Build caveats

A plain Release invocation was attempted first:

```bash
/usr/bin/time -lp swift test -c release \
  --filter GenotypeResultViewportTests.testConfigureRetainedDemuxSizedBundleDoesNotBlockViewportLoad
```

It failed before running the selected test because package tests reference
helpers compiled under `#if DEBUG`. Representative failures included missing
`AlignmentResultViewController.testSummaryFontPointSize`,
`GenomicSummaryCardBar.testingTypographyMetrics`, and
`ClassifierReadResolver.testingResolveBAMURL`. The failed command took 319.76
seconds while building and is excluded from all benchmark aggregates.

The optimized test bundle was then built by:

```bash
swift test -c release -Xswiftc -DDEBUG \
  --filter GenotypeResultViewportTests.testConfigureRetainedDemuxSizedBundleDoesNotBlockViewportLoad
```

The selected test passed in 0.472 seconds, but the SwiftPM wrapper subsequently
forwarded `-Xswiftc` to the `lungfish-cli` product, which rejected it. Because
the wrapper did not terminate cleanly, its 691.04-second cold-build wall time
is build context only and is excluded from benchmark aggregates. The cached
optimized XCTest bundle was executed directly for the clean runs below.

## Clean Release fixture observations

### 52-sample × 120-row retained-demux fixture

Exact command:

```bash
for run_index in 1 2 3; do
  echo "RUN ${run_index}"
  /usr/bin/time -lp xcrun xctest \
    -XCTest LungfishGenotypeUITests.GenotypeResultViewportTests/testConfigureRetainedDemuxSizedBundleDoesNotBlockViewportLoad \
    .build/arm64-apple-macosx/release/LungfishGenomeBrowserPackageTests.xctest
done
```

All three runs passed.

| Run | XCTest case | Command wall | Maximum RSS |
| ---: | ---: | ---: | ---: |
| 1 | 0.459 s | 0.55 s | 165,134,336 B |
| 2 | 0.458 s | 0.53 s | 165,265,408 B |
| 3 | 0.464 s | 0.54 s | 165,068,800 B |
| Aggregate | 1.381 s | 1.62 s | — |
| Maximum | 0.464 s | 0.55 s | 165,265,408 B |

The case-level mean was 0.460 seconds. The test's internal timer covers
controller configuration plus visible-cell rendering, but the test does not
print that timer; XCTest's reported duration additionally includes fixture
construction and assertions.

### 150-sample column stress fixture

Exact command:

```bash
for run_index in 1 2 3; do
  echo "RUN ${run_index}"
  /usr/bin/time -lp xcrun xctest \
    -XCTest LungfishGenotypeUITests.GenotypeResultViewportTests/testComparisonMatrixShowsEverySampleColumnByDefault \
    .build/arm64-apple-macosx/release/LungfishGenomeBrowserPackageTests.xctest
done
```

All three runs passed.

| Run | XCTest case | Command wall | Maximum RSS |
| ---: | ---: | ---: | ---: |
| 1 | 0.085 s | 0.16 s | 90,636,288 B |
| 2 | 0.085 s | 0.16 s | 90,832,896 B |
| 3 | 0.083 s | 0.15 s | 90,636,288 B |
| Aggregate | 0.253 s | 0.47 s | — |
| Maximum | 0.085 s | 0.16 s | 90,832,896 B |

The case-level mean was 0.084 seconds. This fixture validates column
materialization only; it does not apply a threshold change.

## Legacy operation-counter availability

| Required Task 6 observation | Legacy baseline |
| --- | --- |
| Base-projection builds | Unavailable: the legacy implementation has no base-projection object or counter. |
| Derived filter passes | Unavailable: threshold changes call `rebuildRowsFromResult()` synchronously and there is no derived-pass counter. |
| Aggregate/max derived-pass duration | Unavailable: no threshold-pass timer exists. |
| Commit-to-visible settle duration | Unavailable: no commit/visible instrumentation exists. |
| Full pinned/sample table reloads | A DEBUG-only table reload counter exists, but neither representative fixture resets, reads, or prints it. No baseline count can be recovered from the executed tests. |
| Column rebuilds | Unavailable: `rebuildColumns()` has no counter. |
| Layout applications | Unavailable: `applyLayoutPreference()` has no counter. |
| Anchor/Consumer or other unrelated-lens rebuilds | Unavailable for the threshold path: no complete counter snapshot is exposed by either representative fixture. |
| Latest value after twenty drafts | Not exercised by either legacy fixture. |
| Selection/sort/scroll/order/width retention | Not exercised by either legacy fixture during threshold mutation. |

Static inspection confirms the legacy threshold path: a
`requiresMatrixRowRebuild` state change calls `rebuildRowsFromResult()`, which
re-reads `result.locusSummaries`, filters all calls, recomputes summaries and
support lookups, and then proceeds through matrix filtering/reload. Static
control flow is not reported as a measured counter.

## Task 6 comparison requirement

Before claiming Task 6 performance budgets, add the planned instrumentation and
run the new 52×120 rapid-draft benchmark plus the separate 150-sample column
stress benchmark in Debug and Release. The comparison must report:

- aggregate and maximum derived-pass time;
- maximum commit-to-visible settle;
- base-build and derived-pass counts;
- pinned/sample full reloads;
- column rebuilds;
- layout applications;
- unrelated-lens rebuilds; and
- latest-value and retained viewport-state assertions.

The fixture-level observations in this document may be compared only with
equivalent whole-case measurements after Task 6.

## Task 6 cached-projection verification

Task 6 replaces repeated whole-result projection with one immutable base
projection and one derived threshold pass after the twenty-draft debounce. The
scientific-equivalence tests compare complete ordered rows and occurrence
support, hidden and total counts, and both support-fraction maps against a
test-only implementation of the legacy algorithm. The comparison covers both
denominators, combined thresholds, duplicate call occurrences, known and
candidate rows, explicit-zero and missing denominators, and a candidate with no
observed support.

The representative workloads now run through
`GenotypeResultViewController`, not a bare matrix. Every run asserts:

- one cumulative base-projection build and one derived pass after counter reset;
- zero column, Anchor, Consumer, cohort-summary, and layout rebuilds;
- no more than one full reload in either pinned or sample table;
- the twentieth draft is the committed threshold;
- stable selection, sort, semantic scroll anchor, surviving row order, sample
  order, and column widths; and
- a visible-settle sample taken on the next main-run-loop turn after layout.

The full Debug viewport gate passed 285 tests with zero failures in 64.276
seconds. Its representative measurements were:

| Fixture | Derived aggregate/max | Visible aggregate/max | Debug ceiling |
| --- | ---: | ---: | ---: |
| 52 samples × 120 rows, 20 drafts | 53.316 ms / 53.316 ms | 17.938 ms / 17.938 ms | 500 ms |
| 150 sample columns, 20 drafts | 1.312 ms / 1.312 ms | 22.067 ms / 22.067 ms | 500 ms |

### Clean direct optimized Release runs

The final optimized test bundle was built with:

```bash
swift test -c release -Xswiftc -DDEBUG \
  --filter 'GenotypeResultViewportTests.test(RapidTwentyDraft|OneHundredFiftyColumn|ProjectionRowDiff|CombinedCandidateVisibility|SidecarVisibilityAndStyle)'
```

All five selected tests passed. As in the legacy baseline, the SwiftPM wrapper
then exited nonzero because it forwarded `-Xswiftc` to `lungfish-cli`, which
reported `Unknown option '-Xswiftc'`. The cached optimized XCTest bundle was
therefore run directly for the clean measurements:

```bash
for run_index in 1 2 3; do
  xcrun xctest \
    -XCTest LungfishGenotypeUITests.GenotypeResultViewportTests/testRapidTwentyDraftThresholdEditsUseOneCachedDerivedPassAndPreserveMatrixState \
    .build/arm64-apple-macosx/release/LungfishGenomeBrowserPackageTests.xctest
done

for run_index in 1 2 3; do
  xcrun xctest \
    -XCTest LungfishGenotypeUITests.GenotypeResultViewportTests/testOneHundredFiftyColumnThresholdStressDoesNotRebuildColumnsOrLoseWidths \
    .build/arm64-apple-macosx/release/LungfishGenomeBrowserPackageTests.xctest
done
```

All six direct runs passed.

| Fixture/run | Derived | Visible settle |
| --- | ---: | ---: |
| 52×120 run 1 | 20.140 ms | 27.343 ms |
| 52×120 run 2 | 20.121 ms | 29.314 ms |
| 52×120 run 3 | 20.162 ms | 31.095 ms |
| **52×120 aggregate** | **60.423 ms** | **87.752 ms** |
| **52×120 maximum** | **20.162 ms** | **31.095 ms** |
| 150-column run 1 | 0.468 ms | 32.842 ms |
| 150-column run 2 | 0.415 ms | 26.027 ms |
| 150-column run 3 | 0.457 ms | 27.967 ms |
| **150-column aggregate** | **1.340 ms** | **86.836 ms** |
| **150-column maximum** | **0.468 ms** | **32.842 ms** |

The optimized maximums pass the approved ceilings of 50 ms per derived pass
and 100 ms per visible settle. A separate row-diff regression verifies that
transient AppKit selection callbacks are suppressed only during insert/remove
transactions and resume immediately afterward. Rendered-cell regressions also
verify that a combined candidate visibility/tint transition redraws a surviving
candidate and that a sidecar visibility/style replacement refreshes surviving
AppKit chrome even when candidate tints are unchanged.

These timings isolate the new threshold projection and visibility settlement.
They must not be treated as directly comparable to the legacy whole-case
durations earlier in this document.
