# Excel integration QA — final fix verification

Production baseline: `638b9a3dc`; test baseline: `c0714cf9f`; parent version-only commit: `d05eca19b`. This report contains no private cohort identities or paths. Packaging, release approval and final independent review belong to the parent task.

## Final disposition

The six consolidated findings are fixed: immediate reviewed-inference/full-workbook refresh, frozen empty annotation capture and cleared managed formatting, non-MiSeq effective-call parity, scoped legacy manual-only calls, exact legacy CSV-to-workbook review identities, and readable labels/headers. Editable matrix targets now have an immutable readable label with sample/locus/allele context; machine identities remain attested. Legacy manual-only call import remains intentionally read-only. Ambiguous identity mappings and unsupported false-negative targets fail closed.

The complete disposable-project test passed through actual controller capture, production filtered export, canonical workbook generation, four accepted Excel edits (new FP, zero-support FN, row comment, cell comment), full canonical refresh, fresh-controller reopen and final filtered export. Both before and after edits it checked 4,160 filtered matrix cells, all 130 exact filtered calls with per-slot status/source/baseline/comment, all 130 current calls, and 4,394 recoverable unfiltered evidence cells. Original numeric evidence is checked separately from FP/FN presentation. Existing reviews remain valid. Synthetic real-bundle tests additionally complete set/clear review imports and canonical refreshes, verifying same-locus recomputation and preservation of a meaningful distinct manual override/comment.

The opt-in test `GenotypeViewportExcelExportTests.testDisposableRealBundleControllerAndProductionExcelParity` accepts `LUNGFISH_EXCEL_QA_PROJECT` and `LUNGFISH_EXCEL_QA_BUNDLE`. It clones the entire supplied disposable project, preserving the exact historical reference definition and native relative paths, and asserts caller input hashes before/after. An earlier analysis-only clone lost reference context; that was a QA harness limitation, not an original-project missing-definition defect. The whole-project test also exposed and fixed capture provenance for reference-bundle definitions. No substitute definition was introduced.

## Exact covering-test disposition

All commands used `swift test --jobs 6`, one build/test process at a time. Results below are split-run evidence, not a claim that one final full-suite invocation ran green.

| Run | Actual result | Final disposition |
|---|---|---|
| Seven targeted finding regressions | 7/7 pass | RED/GREEN established |
| Revision-service covering run plus two expanded UI lifecycle cases | 165 cases, 162 pass, 3 fail | One real FN preflight regression fixed and retested green; two test-only noncanonical workbook paths corrected and lifecycle tests passed |
| Integrated covering selection | 251 cases, 249 pass, 2 fail | Obsolete empty-manual-slot assertion corrected; missing reference-definition capture provenance fixed |
| Final affected-suite retest | 11/11 pass, zero skips, 69.543 seconds | Entire viewport Excel export suite including whole-project edit lifecycle, plus corrected manual-slot test |

Thus all failures from the bounded covering selections were resolved and affected cases retested. The 162 unchanged revision-service cases retain their passing evidence (identity, recovery, no-clobber, candidates and raw-evidence coverage). This is not a full repository test run. Existing unrelated compiler warnings remain.

Integrated selection:

```sh
LUNGFISH_EXCEL_QA_PROJECT='<disposable whole project>' LUNGFISH_EXCEL_QA_BUNDLE='<analysis inside that project>' swift test --jobs 6 --filter 'GenotypeViewportExcelExportTests|GenotypeViewportPivotExportTests|GenotypeExcelDialogBehaviorTests|GenotypeReviewedHaplotypeInferenceTests|GenotypeResultViewportSelectionAndComparisonTests|GenotypeResultViewportWorkbookPublicationTests|GenotypeAnnotationStoreCallOverrideTests|GenotypeCurrentWorkbookSyncCoordinatorTests|GenotypePivotThresholdTests|GenotypePivotFilteredCopyTests|GenotypeEffectiveHaplotypeProjectionTests|GenotypeEffectiveHaplotypeEditorTests|GenotypeEditableWorkbookTests|GenotypeWorkbookRevisionServiceTests.testLegacyCSVIdentitiesSeedEditableMatrixAndMapCompactReportLabels|GenotypeWorkbookRevisionServiceTests.testFalseNegativeWithoutAttestedReviewableRowCatalogFailsBeforeStagingOrMutation|AppVersionTests'
```

Final affected selection uses the same opt-in inputs:

```sh
swift test --jobs 6 --filter 'GenotypeViewportExcelExportTests|GenotypeResultViewportSelectionAndComparisonTests.testControllerExportSnapshotWithoutHaplotypeAnalysisRetainsEmptyManualSlots'
```

## Artifacts, provenance and integrity

Retained private temporary artifacts include before/after filtered/current workbooks, complete independent values/style/comment dumps, captured projections/annotations, accepted edit evidence and operation provenance, and the additional working project clone. Filtered export records exact CLI argv and durable replay command, explicit options/resolved defaults including minReads=5, captured annotation/projection/definition inputs, runtime identity, checksums/sizes, exit status and wall time. Canonical and acceptance provenance point to final stored payloads and retain the accepted workbook and per-operation witnesses. Parent independently verified all six checksum-bearing outputs across final filtered, refreshed-current and accepted-edit provenance against actual bytes/sizes; all exit statuses are zero. The exact definition input checksum/size was also verified.

The original project and prepared copy retain identical full-tree witnesses: 470 entries, unchanged SHA-256. The final test adds fresh before/after whole-project equality and asserts unchanged raw calls/CSV evidence. The original project was never passed to a loader, controller or writer.

Parent read-only artifact rendering passed the affected long-label matrix, fitted headers, readable Edit Matrix targets, current/filtered calls, metadata, Edit Calls and Editing Guide, including the final after-edit artifacts. These checks do not claim a packaged native-app launch. Runtime labels reflect debug CLI/XCTest execution, not a released app. No original-project mutation, release, merge, packaging, publication or cleanup was performed by this fix owner.
