# Task 5 — shared review eligibility

Scope: `codex/excel-three-sheet-layout`, base `dfc431f7f8105430f42318fbf2c20d461b8c3b65`. Only this worktree and synthetic fixtures were used. No original/private project, release, merge, other worktree, or whole-repository test run was used.

## Changes

- Added `GenotypeMatrixReviewEligibility`: exact MatrixTarget grouping, including stableClusterID; every duplicate withheld; unique FP requires raw support > 0; unique FN requires attested raw support == 0. Nil and negative support are ineligible. Row/column reviews cannot become authoritative cell reviews.
- Shared raw support extraction preserves observed call/candidate/unnameable support and fills missing exact entries from the already loaded validated reviewable catalog. Catalog callID is the target genotype; displayName never grants identity. Unknown cells outside the catalog stay nil. No extra disk reads or synthesized observations.
- Inference applies eligibility before its existing locus normalization. The existing Mafa-A review → MHC-A known-call fixture remains valid, and stable-cluster reviews never exclude a plain call. FN never creates calls. Caller, dropout, normalization, and inference scheduling algorithms were not changed.
- Controller retains arrays of raw reviews per exact target, so eligibility can withhold conflicts while clear/replacement stays available. Change detection compares all raw records and catches one→duplicate→one when the last record is unchanged. Matrix chrome consumes only eligible reviews and caches support on result configuration.
- Store mutation validation uses the shared support rule. Excel imports retain nil support instead of converting it to zero. Existing replay/source/audit preservation is unchanged; provenance now records unknown absent support, attested-zero FN, and eligibility policy version 1.
- Filtered presentation consumes the same raw-support map and eligible-review policy, preserving captured display masks independently. Observed raw positives and explicit zeros remain authoritative without a catalog; unobserved or different stable identities stay unknown.
- Current presentation serializes shared Swift eligibility and policy version into existing retained `presentation-inputs.json`. Python consumes that attested map instead of interpreting duplicates/support independently. Catalog validation, input witnesses, CLI descriptor checks, runtime recording, and publication guards remain intact.
- Removed only the redundant early no-catalog raw-FN semantic preflight, with parent agreement: it rejected duplicate/ineligible annotations before the shared withholding policy could run. Invalid reviews now remain in sidecar while valid raw exports proceed. No evidence rows are synthesized for unknown reviews.

## Test evidence

All commands ran here with one Swift process and `--jobs 6`. No tests were intentionally skipped or weakened. Unchanged Task 6 biological/canonical ordering and FN-bold presentation tests were not addressed.

### Initial focused RED

```sh
swift test --jobs 6 --filter 'GenotypeReviewedHaplotypeEvidenceTests|GenotypeMatrixReviewCapabilityTests' > /tmp/task-5-red.log 2>&1
```

Exit 1: `Executed 15 tests, with 11 failures (0 unexpected)`.
Expected failures demonstrated FP/FP and reversed FP/FN duplicates excluding observed calls, zero-read FP excluding a raw call, last-review UI tokens, incompatible review tokens, and absent support classified as zero. Existing alias and stable/plain separation fixtures stayed in the selection.

### Initial focused GREEN

```sh
swift test --jobs 6 --filter 'GenotypeReviewedHaplotypeEvidenceTests|GenotypeMatrixReviewCapabilityTests' > /tmp/task-5-green.log 2>&1
```

Exit 0: `Executed 15 tests, with 0 failures (0 unexpected)`.

### Affected integration selection

```sh
swift test --jobs 6 --filter 'GenotypeMatrixReviewEligibilityTests|GenotypeReviewedHaplotypeEvidenceTests|GenotypeMatrixReviewCapabilityTests|GenotypeAnnotationStoreTests|GenotypeResultViewportMatrixReviewTests|GenotypeReviewedHaplotypeInferenceTests/testFalsePositive|GenotypeReviewedHaplotypeInferenceTests/testReopening|GenotypeWorkbookRevisionServiceTests/testThreeSheetCurrentWithholds|GenotypeWorkbookRevisionServiceTests/testThreeSheetCurrentWorkbookRetains|GenotypePivotFilteredCopyTests/testThreeSheetFilteredWithholds|GenotypeThreeSheetEditableWorkbookTests/testRejectsFalseNegative' > /tmp/task-5-affected.log 2>&1
```

Exit 1: `Executed 121 tests, with 7 failures (1 unexpected)`.
The new duplicate-state/invalidation test, helper, inference, adapter parity, catalog authority, sidecar preservation, and serialized eligibility checksum checks passed. Failures were classified before changes:

1. FN sparse rendering and menu/keyboard fixtures assumed absent support was zero (four assertions). Added validated exact catalog-zero authority, preserving their rendering and successful mutation assertions.
2. Filtered-highlight fixture marked a positive 1-read cell FN (two assertions). Changed the fixture to observed explicit zero, preserving FN/selection/comment chrome assertions.
3. `testWritableNonseedingOpenPreservesSidecarAndProvenanceUntilExplicitMutation` seeded literal non-JSON `existing provenance`, then expected a successful comment publication. The unchanged provenance reader threw Cocoa JSON error 3840. Parent approved replacing only that fixture with supported provenance generated by `GenotypeAnnotationStore(...seedBuiltInSmartCohorts: false).saveSmartCohort`. Byte-identical opening and successful mutation/audit assertions remain. No production parser/validation change. This classification is source evidence, not a claim of a baseline test run.

### Legacy current adapter RED

```sh
swift test --jobs 6 --filter 'GenotypeWorkbookRevisionServiceTests/testThreeSheetLegacyWitnessedEvidence' > /tmp/task-5-adapter-red.log 2>&1
```

Exit 1: `Executed 1 test, with 1 failure (1 unexpected)`; the obsolete preflight threw `False-negative workbook updates require an attested reviewable-row catalog or an exact zero-support row in the witnessed CSV evidence.` Fixture includes positive duplicate FP/FN in both orders, witnessed explicit-zero FN, and an unknown candidate FN. This failure happened before rendering, as expected. Two earlier test-compilation typos (initializer argument label and force-unwrapping a nonoptional manifest path) were corrected before this behavioral RED run.

### Amended integration GREEN

```sh
swift test --jobs 6 --filter 'GenotypeWorkbookRevisionServiceTests/testThreeSheetLegacyWitnessedEvidence|GenotypeWorkbookRevisionServiceTests/testThreeSheetCurrentWithholds|GenotypeResultViewportMatrixReviewTests/testDuplicateReviews|GenotypeResultViewportMatrixReviewTests/testMatrixFalseNegativeKeeps|GenotypeResultViewportMatrixReviewTests/testMatrixFilteredHighlight|GenotypeResultViewportMatrixReviewTests/testMatrixMenuAndKeyboard|GenotypeAnnotationStoreTests/testWritableNonseeding|GenotypeReviewedHaplotypeInferenceTests/testFalsePositive|GenotypeMatrixReviewCapabilityTests' > /tmp/task-5-amended-green.log 2>&1
```

Exit 0: `Executed 17 tests, with 0 failures (0 unexpected)`.
This covers all seven initial failures and the legacy preflight correction. Controller clear preserves both duplicate original reviews in the replay payload. The valid inference fixture now also changes visual read/percent thresholds and captures an export, asserting exactly zero inference runs through existing performance instrumentation.

### Filtered observed-support amendment

```sh
swift test --jobs 6 --filter 'GenotypePivotFilteredCopyTests/testThreeSheetFilteredUsesObservedRawSupport' > /tmp/task-5-filtered-red.log 2>&1
swift test --jobs 6 --filter 'GenotypePivotFilteredCopyTests|GenotypeWorkbookRevisionServiceTests/testThreeSheetLegacyWitnessedEvidence|GenotypeWorkbookRevisionServiceTests/testThreeSheetCurrentWithholds|GenotypeMatrixReviewEligibilityTests' > /tmp/task-5-filtered-green.log 2>&1
```

First run: 1 test / 2 assertions failed. Broader adapter amendment run: 14 tests / 3 assertions failed. These exposed two test fixture problems: generic genotype names inferred locus Unknown while the new targets claimed MHC-A, and exact path equality ignored provenance recorder path normalization. Corrected only the new observed-support fixture to real Mafa-A1 tokens with literal expected counts 500 and 0. The raw source descriptor lookup uses the exact g.csv filename and input role, retaining exact checksum/size assertions. The g.csv bytes contain the five matching makeResult raw calls/counts, rather than a dummy descriptor.

```sh
swift test --jobs 6 --filter 'GenotypePivotFilteredCopyTests/testThreeSheetFilteredUsesObservedRawSupport|GenotypePivotFilteredCopyTests/testThreeSheetFilteredPreservesCapturedMask' > /tmp/task-5-filtered-amended-green.log 2>&1
```

Exit 0: `Executed 2 tests, with 0 failures (0 unexpected)`.
The other 12 adapter amendment tests passed, including current input role, final stored path, SHA and file-size checks. The corrected observed-support fixture also verifies nil captured masks, distinct stable identity withholding, unknown FN withholding, and unchanged sidecar record count.

To establish valid RED evidence with the corrected exact-locus fixture, temporarily restored the old catalog-required boundary (`result.reviewableRowCatalog == nil ? [:] : ...`), then restored the final shared observed-support implementation:

```sh
swift test --jobs 6 --filter 'GenotypePivotFilteredCopyTests/testThreeSheetFilteredUsesObservedRawSupport' > /tmp/task-5-filtered-corrected-red.log 2>&1
swift test --jobs 6 --filter 'GenotypePivotFilteredCopyTests/testThreeSheetFilteredUsesObservedRawSupport' > /tmp/task-5-filtered-corrected-green.log 2>&1
```

Corrected-fixture RED exit 1: `Executed 1 test, with 2 failures (0 unexpected)`. Actual raw supports `[nil, nil, nil, nil]` versus expected `[500, 0, nil, nil]`; actual review tokens all nil versus expected `[false-positive, false-negative, nil, nil]`.
Restored final implementation GREEN exit 0: `Executed 1 test, with 0 failures (0 unexpected)`. Neither final narrow run emitted a compiler warning. The temporary catalog gate was removed before this GREEN and is not in the commit.

All failures in the affected and amendment selections are resolved by the covering passing reruns described above. `git diff --check` passed after restoration and final self-review. This reports per-selection evidence rather than claiming a new whole-suite run.

## Files

- Sources/LungfishIO/Bundles/GenotypeMatrixReviewEligibility.swift (new)
- Sources/LungfishIO/Bundles/GenotypeReviewedHaplotypeEvidence.swift
- Sources/LungfishGenotypeUI/GenotypeMatrixReviewCapability.swift
- Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift
- Sources/LungfishGenotypeUI/GenotypeResultViewController.swift
- Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift
- Sources/LungfishCLI/Commands/GenotypeExportPivotXlsxSubcommand+Presentation.swift
- Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift
- Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+PresentationScript.swift
- Tests/LungfishIOTests/GenotypeMatrixReviewEligibilityTests.swift (new)
- Tests/LungfishIOTests/GenotypeReviewedHaplotypeEvidenceTests.swift
- Tests/LungfishGenotypeUITests/GenotypeMatrixReviewCapabilityTests.swift
- Tests/LungfishGenotypeUITests/GenotypeAnnotationStoreTests.swift
- Tests/LungfishGenotypeUITests/GenotypeResultViewportMatrixReviewTests.swift
- Tests/LungfishGenotypeUITests/GenotypeReviewedHaplotypeInferenceTests.swift
- Tests/LungfishCLITests/GenotypePivotFilteredCopyTests.swift
- Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift
- This report.

## Self-review and limits

Exact grouping precedes alias normalization; support remains optional; no reads or scientific rows are fabricated; clear/replacement sees raw conflicts; selection duplicates cannot create duplicate raw review records; raw-support maps are cached rather than rebuilt on selection/filter changes. Existing source/audit/replay retention was inspected and current/filtered final stored input descriptors were exercised. Current Python no longer has independent review semantics. No calling/dropout/locus algorithm or scheduling change was made. The large controller/store/current-service files remain large existing files; changes are focused.

No biological algorithm change, private dataset QA, release, or whole-repository validation is claimed. Existing deferred Task 6 presentation work is outside this task. No remaining known eligibility invariant is intentionally deferred.

Compilation output is not pristine: existing unrelated warnings include async-without-await, unused variables/results, actor isolation/Sendable warnings and deprecated cleanup APIs. Initial broad dependency recompilation printed 4,976 lines containing `warning:` (repeated diagnostic and source-line copies), initial RED 220, affected run 36, adapter RED 36, amended GREEN 2, filtered adapter run 36. These are log-line counts, not unique warnings. The 36-line batches refer to existing ProjectStorageCleanupExecutorTests unused `execute` results; no new helper/adapter diagnostic was observed. Test output also includes existing synthetic export summaries and a matrix benchmark. No XCTest skip was reported in the recorded selections.
