# Manual Haplotype Assignment UI Verification

Date: 2026-07-27

Branch: `codex/manual-task10-ui-perf`

Baseline commit: `73f7050fe112b94b21fed7ffb28618fc6ee0db18`

## Scope and conclusion

This checkpoint verifies the manual-haplotype assignment experience for typed
genotype-only results. It covers the compact Summary/Audit lens control,
disclosure and editor accessibility, bounded multi-sample presentation,
incremental band redraw, and Release interaction and save-preparation budgets.

The representative 100-sample, seven-locus genotype-only matrix passes all
approved Release budgets:

| Measurement | Result | Budget |
| --- | ---: | ---: |
| Scroll p95 / p99 / regression | 1.396 / 1.588 ms / 8.38% | ≤ 16.7 / 33.4 ms / 10% |
| Reorder p95 / p99 / regression | 3.295 / 3.517 ms / 5.65% | ≤ 16.7 / 33.4 ms / 10% |
| Resize p95 / p99 / regression | 5.193 / 5.743 ms / 3.38% | ≤ 16.7 / 33.4 ms / 10% |
| Fourteen-slot save preparation p99 | 0.059 ms | ≤ 250 ms |

The complete focused Debug gate passed 644 tests with zero failures before the
final matrix-only scroll-cache optimization. On the exact final source, all 497
non-workbook selected tests passed with zero failures, including all 371
viewport tests. The clean direct optimized gate passed eight tests with zero
failures.

## Deterministic fixtures and assertions

`GenotypeManualHaplotypeTask10Fixture` creates 100 samples, seven genotype
rows/loci, and fourteen assignments per sample. The interaction benchmark uses
the same scientific rows and columns for both cases:

- a typed genotype-only result with its pinned manual-assignment band; and
- a workflow-mode-haplotyped result for which the manual-assignment band is
  ineligible.

After warm-up, both matrices execute the same scroll, column-reorder, and
column-resize sequence. The benchmark records 1,200 individual frame
durations—not batch averages—for each matrix and interaction, alternating
which matrix runs first to reduce thermal-order bias. Scroll, reorder, and
resize each independently enforce p95, p99, and no-band p95 regression budgets.

The save-preparation benchmark changes all fourteen locus/slot values and
samples one hundred preparations. Its persistence and reload closures fail the
test if called, ensuring the measured preparation path contains no filesystem
or workbook work.

The regression and accessibility assertions also verify:

- a one-sample assignment edit identifies one changed sample and one visible
  column invalidation rectangle;
- the pinned disclosure is a first-responder-capable, accessibility-operable
  button with the label `Haplotype Assignments`; its expanded and value states
  remain synchronized and an accessibility press toggles the band;
- content typography changes that alter programmatic table-column widths dirty
  the geometry cache and realign the band to the scaled table widths;
- cached-column tooltip tracking follows the document-coordinate overscan
  across horizontal scrolling and is exercised through the registered
  `NSViewToolTipOwner` hit path;
- pinned sample-band cells introduce no focusable controls and are omitted as
  separate accessibility elements, while the sample header summary names all
  seven loci;
- all fourteen editor fields and clear actions have unique locus-and-slot
  labels and identifiers;
- copy-from-sample choices report completeness as `14 of 14 assigned`; and
- a pure 100-sample presentation renders at most twelve sample summaries and
  reports the remaining 88 samples explicitly; and
- a mounted `GenotypeResultViewController` selection of the same 100 columns
  exposes twelve detail summaries, an explicit 88-sample omission row, and no
  assignment editor.

The focused suite additionally preserves these cross-workflow and artifact
requirements:

- `testExplicitFullLengthONTAndMiSeqGenotypeOnlyResultsAreEligible`
- `testCurrentWorkbookSnapshotIncludesGenotypeOnlyManualAssignmentsForONTAndMiSeq`
- `testTypedONTAndMiSeqGenotypeOnlyBundlesMaterializeManualSnapshots`
- `testApplyManualHaplotypeSnapshotWritesFourteenLiteralValuesAndSidecarRevisionProvenance`
- `testHaplotypedResultKeepsLensHeaderAndSideBySideLayout`
- `testHaplotypedResultWithManualAssignmentsPreservesFullCreatorBehavior`
- `testCompleteSevenLocusHaplotypedSnapshotIsNeverInferredAsManual`
- `testManualHaplotypeSaveMarksWorkbookDirtyOnceWithoutProjectionRebuild`
- `testSelectedMultipleColumnsShowBoundedCanonicalManualHaplotypeSummariesWithoutEditor`

These existing tests cover both full-length ONT and miSeq genotype-only
eligibility and snapshots, fourteen literal workbook values plus revision
provenance, unchanged haplotyped behavior, dirty-state propagation without a
matrix projection rebuild, and bounded multi-selection presentation.

## Focused Debug gate

Exact command:

```bash
swift test \
  --filter 'ManualHaplotype|GenotypeResultViewportTests|GenotypeWorkbookRevisionServiceTests'
```

Result:

- 644 tests executed;
- zero failures;
- 296.542 seconds total;
- `GenotypeResultViewportTests`: 371 tests, zero failures, 81.332 seconds;
- `GenotypeWorkbookRevisionServiceTests`: 147 tests, zero failures.

After the final scroll-cache implementation changed from per-frame dictionary
translation to document-coordinate bounds movement, the current-source rerun
passed the 492 tests scheduled before the workbook suite with zero failures,
including `GenotypeResultViewportTests` at 371 tests in 77.181 seconds. The five
alphabetically later `ManualHaplotypeAssignmentTests` also passed separately.
The unchanged 147-test workbook suite could not be repeated under the current
managed workspace profile because its detached-attestation fixtures write to
`~/Library/Application Support/Lungfish`, which the profile denies; the failure
was environmental (`EPERM`) before workbook assertions. No workbook or
transaction source changed in the final optimization.

The review-driven benchmark rerun also reports in Debug, without enforcing
Release frame ceilings:

| Measurement | Debug observation |
| --- | ---: |
| Scroll p95 / p99 / regression | 1.982 / 2.166 ms / 9.19% |
| Reorder p95 / p99 / regression | 4.592 / 4.810 ms / 2.62% |
| Resize p95 / p99 / regression | 7.060 / 7.544 ms / 2.77% |
| Aggregate p95 / p99 / regression | 6.741 / 7.243 ms / 3.17% |
| Save preparation p99 | 0.080 ms |

## Optimized Release gate

The required plain command was attempted first:

```bash
swift test -c release \
  --filter 'GenotypeManualHaplotypePerformanceTests|GenotypeManualHaplotypeAccessibilityTests'
```

It failed while compiling package test targets, before running the selected
tests, because `swift test --filter` still compiles every package test target
and existing tests reference helpers compiled only under `#if DEBUG`.
Representative first-pass missing APIs included
`ONTGenotypeResultBundle.resetArtifactValidationCacheForTesting`,
`ClassifierReadResolver.testingResolveBAMURL`, and provenance `.fixture`.

A contained repair was investigated. Exposing only those internal hooks let the
same plain command advance to guarded `GenomicSummaryCardBar` test metrics;
exposing that group advanced to guarded `AlignmentResultViewController` test
metrics; exposing that group then exposed dozens of guarded
`LungfishAssemblyUI` controller, table, detail, typography, and accessibility
hooks. The source tree contains approximately 200 `#if DEBUG` partitions.
Those investigative changes were reverted in full. A clean plain Release
wrapper therefore requires a package-wide Release-test architecture cleanup,
not a Task 10 product change.

This limitation predates this work and is also documented in
`docs/verification/2026-07-25-genotype-matrix-projection-legacy-baseline.md`.
The approved Task 10 refinement preserves the optimized Release product
evidence below and defers package-wide Release-test-hook cleanup as separate
work. The direct results do not claim that the plain wrapper exited zero.

The established optimized workaround built the selected tests with test hooks:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/task10-clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/task10-swiftpm-cache" \
LUNGFISH_RELEASE_PERFORMANCE_TEST=1 \
swift test --disable-sandbox -c release -Xswiftc -DDEBUG \
  --filter 'GenotypeManualHaplotypePerformanceTests|GenotypeManualHaplotypeAccessibilityTests'
```

All eight selected tests passed in the optimized bundle. As with the repository
baseline, the SwiftPM wrapper subsequently exited nonzero because it forwarded
`-Xswiftc` to the `lungfish-cli` executable, which rejected the option. The
cached optimized XCTest bundle was therefore executed directly for a clean
process result:

```bash
LUNGFISH_RELEASE_PERFORMANCE_TEST=1 xcrun xctest \
  -XCTest LungfishGenotypeUITests.GenotypeManualHaplotypeAccessibilityTests \
  .build/arm64-apple-macosx/release/LungfishGenomeBrowserPackageTests.xctest

LUNGFISH_RELEASE_PERFORMANCE_TEST=1 xcrun xctest \
  -XCTest LungfishGenotypeUITests.GenotypeManualHaplotypePerformanceTests \
  .build/arm64-apple-macosx/release/LungfishGenomeBrowserPackageTests.xctest
```

Clean direct result:

- accessibility: five tests, zero failures, 0.518 seconds;
- performance: three tests, zero failures, 21.660 seconds.

| Measurement | Optimized result |
| --- | ---: |
| Scroll p95 | 1.396 ms |
| Scroll p99 | 1.588 ms |
| Scroll no-band p95 | 1.288 ms |
| Scroll regression | 8.38% |
| Reorder p95 | 3.295 ms |
| Reorder p99 | 3.517 ms |
| Reorder no-band p95 | 3.119 ms |
| Reorder regression | 5.65% |
| Resize p95 | 5.193 ms |
| Resize p99 | 5.743 ms |
| Resize no-band p95 | 5.023 ms |
| Resize regression | 3.38% |
| Aggregate p95 | 5.001 ms |
| Aggregate p99 | 5.327 ms |
| Aggregate no-band p95 | 4.827 ms |
| Aggregate regression | 3.61% |
| Save preparation p99 | 0.059 ms |

## UX and implementation notes

Typed genotype-only results expose a compact native segmented control with
Summary and Audit. Review remains a haplotyping-only lens. Haplotyped results
retain the existing three-lens control and header geometry.

The manual-assignment band caches a small overscanned set of document-coordinate
column geometry and advances its bounds origin during ordinary horizontal
scrolling, avoiding per-frame dictionary reconstruction. It recomputes only
after structural column changes or when scrolling exhausts the overscan, skips
work while hidden or empty, and invalidates only changed visible sample
rectangles. This preserves matrix space and avoids a projection rebuild for
assignment-only edits. Programmatic typography width changes explicitly dirty
the cache so the next layout uses the new table geometry. Tooltip tracking uses
the cached column-frame union, so it remains valid while the bounds origin moves
and refreshes only when that overscanned geometry changes.
