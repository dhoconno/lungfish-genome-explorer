# Excel integration QA — release blocked

Base production commit: `638b9a3dc`. This report contains no private cohort identities or paths. QA changed tests only; release identity edits belong to the parent task.

Actual controller capture was exported through the default production viewport service and CLI. A separately cloned disposable bundle was refreshed through the production current-workbook revision service. The comparison checked 4,160 filtered matrix cells, all 130 exact filtered calls including per-slot status/source/baseline/comment, all 130 canonical current calls, source/filter metadata, projected fills, and 4,394 unfiltered evidence cells. Independent read-count controls confirmed that 1 and 4 reads are blank in the filtered workbook, 5 and 6 remain, and all four values remain in canonical current.xlsx. The original project and prepared comparison copy each retained identical full-tree witnesses: 470 entries, unchanged SHA-256.

Two blocking defects were reproduced:

- Accepting an Excel false-positive review leaves the controller's pre-review inference and contaminant evidence visible until reopening. This occurs both for review-only import and a mixed review/manual-call/comment batch. A meaningful distinct manual override and comment survive fresh-controller recomputation; no loss of that override is claimed.
- A legacy abbreviated-allele current workbook does not map the captured exact raw review identity back to its evidence cell. Its Matrix Annotations sheet marks the review invalid, and Edit Matrix contains column/bundle targets but no evidence-cell targets. All numeric/call comparisons pass before this annotation check fails.

The opt-in test `GenotypeViewportExcelExportTests.testDisposableRealBundleControllerAndProductionExcelParity` takes `LUNGFISH_EXCEL_QA_BUNDLE`, clones the supplied disposable bundle again, and retains actual workbooks, captured projection/annotations, and a complete values/style/comment dump in the system temporary directory. The caller-supplied source receives a before/after recursive file hash assertion. The test intentionally remains RED on the mapping defect. Two synthetic controller-import regressions remain RED on stale review inference.

Final bounded command used `swift test --jobs 6 --filter` with these suites:

| Suite | Tests | Result |
|---|---:|---|
| AppVersionTests | 1 | Pass |
| GenotypeAnnotationStoreCallOverrideTests | 19 | Pass |
| GenotypeCurrentWorkbookSyncCoordinatorTests | 42 | Pass |
| GenotypeExcelDialogBehaviorTests | 11 | Pass |
| GenotypePivotFilteredCopyTests | 5 | Pass |
| GenotypePivotThresholdTests | 19 | Pass |
| GenotypeResultViewportSelectionAndComparisonTests | 77 | Pass |
| GenotypeResultViewportWorkbookPublicationTests | 17 | Pass |
| GenotypeReviewedHaplotypeInferenceTests | 4 | Two new failures; two existing pass |
| GenotypeViewportExcelExportTests | 10 | New cohort mapping failure; nine existing pass |
| GenotypeViewportPivotExportTests | 14 | Pass |
| GenotypeWorkbookRevisionServiceTests.testCurrentWorkbookScientificAndEditingTablesRetainEveryExactLocus | 1 | Pass |

Total: 220 tests, 217 passing test cases, three failing cases, six assertion failures (one Python assertion is reported by XCTest as unexpected), zero skips. Build completed. Existing unrelated compiler warnings remain. Formatting-only acceptance and refresh/retry routing passed through the existing annotation-store and synchronization-coordinator tests.

Filtered provenance records final output/checksum/size, exact CLI argv, minReads=5, percent defaults, captured projection/annotation/definition inputs, Python 3.12.13 and openpyxl 3.1.5, zero exit status, elapsed time and captured deprecation stderr. Canonical writer provenance records the final stored workbook identity and input witnesses. Runtime labels reflect the debug CLI/XCTest execution, not a packaged release.

Limits: no claim of annotation parity for the defective current mapping; this cohort has no matrix comments. Synthetic comment import is covered. The import regressions exercise production acceptance and controller reload/recomputation but do not complete a persisted bundle/workbook refresh transaction after acceptance. Complete that lifecycle after the source fix. Native PNG capture and full release-profile validation were deferred to avoid delaying the consolidated fix. No production app, private desktop, merge, package, publication, or cleanup operation was performed.
