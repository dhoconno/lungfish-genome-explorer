# Task 6 report — final integration and presentation acceptance

Base: `00f5d852a`. Work is confined to the existing three-sheet worktree. Tasks 1–5 and their scientific authority rules were consumed, not restarted. No subagents, native-app control, alternate spreadsheet writer, merge, push or release by this implementer.

## Implementation

- Shipping Python renderer only: adjacent call H1/H2, shared exact palette in calls and matrix, display sample labels, readable widths/wrapping/heights, explicit Excel selection/Note/filter permissions, role-specific metadata and one Scope row.
- Conditional formatting uses opaque foreground AND background differential fills. Parent verified the narrow fix causally in native Excel using the same manual-session Calculate Sheet workflow that failed before it.
- Numeric FP `[n]` and FN `0;-0;"FN"` presentation restored without changing raw support, display masks, exact identity or eligibility. FN carries bold, default `FFF2CC`/`7F6000` and all four `mediumDashed:C65911` edges. Analyst fill/text/italic survive; semantic edge precedence is documented below.
- Backward-compatible optional resolved style fields flow through matrix capture, snapshot, projection, sample slicing, payload and renderer. Actual paint composition includes suppression and support/candidate fallback but excludes selection/hover/preview. Nil/false records suppress fallback; sRGB/alpha handling is deliberate.
- Headless styles resolve per property in LGE order: legacy row, exact row, column, legacy cell, exact cell. Explicit bool overrides beat legacy true/inheritance. No source workbook is used as a science or call-palette authority.
- Current display order uses `MHCAlleleDisplayOrder.compare`; labels use established reference alias/display resolution. Exact scientific loci/raw IDs/stable IDs remain immutable targets. Filtered viewport order is unchanged.
- Existing audit timeline supports Show all / Show recent; ViewInspector proves oldest entry absent/present/absent with 13 unchanged entries. No new Inspector panel. CLI/help and review-reset copy no longer promise removed editing/audit worksheets.
- Malformed structured Notes identify `Genotype Matrix!address`; grammar and import semantics are unchanged. Guidance says edit existing block or add one if absent, never a second block; quoted JSON/newline example and save→LGE review/accept are explicit. Filtered role omits edit/import instructions.

## Deferred assertion mapping

| Task 4 deferred intent | Task 6 evidence |
| --- | --- |
| widths, wrapped sample/allele headers, compact candidate height | production renderer test plus retained viewport export tests; independent all-sheet renders |
| FP8 gray/italic, retained `654321` fill and Note | new `GenotypePivotFilteredCopyTests.testCapturedPaletteAndAttestedReviewStylesSurviveProductionFilteredExport` with observed raw8 |
| FP9, FN0 and old M3/M6 color intent | same authoritative fixture supplies actual captured calls/colors, including font `0432FF` / `595959`; no old source-call inference |
| exact zero FN value/type, four edges/colors, fill/font/bold, OOXML | `testAbsentZeroSupportFalseNegativeUsesExactPortablePresentation` plus shipping renderer and synthetic controller tests |
| analyst fill `FFF2CC`, text `C00000`, border `666666`, bold/italic, Note | `testApplyHaplotypeOverridesWritesMatrixAnnotationsToCurrentWorkbook` checks actual manifest-selected cells before FN, during FN, after clear; explicit false row/column/cell case added |
| FP42, zero FN and incompatible positive FN | `testApplyHaplotypeOverridesFormatsReviewsUsingExactSemanticIdentity`; exact stored value/type/format/font/edge checks |
| invalid review restoration and retained source record | `testReviewBecomingInvalidRestoresPriorManagedPresentation` checks General/non-italic restored rendering and exact submitted sidecar bytes |
| FN bold mutation rejected | restored original `testManagedFalseNegativeStateDigestBindsExpectedBold` |
| name-only candidate colors | original explicit-update tint test plus actual captured tint/contrast tests; no sample spill |
| original biological order | original unchanged expected sequence in `testFullLengthMHCUpdateUsesSpeciesAgnosticBiologicalAlleleOrder` passes |

An Excel cell can display only one style per edge. LGE's separate decorative and semantic inner frames cannot both occupy that edge. Parent approved FN semantic orange dashed edges winning while retaining analyst border in payload/sidecar; exact visible `666666` is tested on the non-FN target and after clear. No styling is silently dropped from the retained record.

## Acceptance transport and scientific boundaries

`GenotypeThreeSheetCohortAcceptance` is a cohesive test helper replacing obsolete app-test logic. It copies the entire disposable project again, loads only that copy, captures the actual controller UI request, computes the complete snapshot fingerprint/palette, and uses production current-workbook execution with the explicitly selected worktree CLI. A private witness records executable path/version/hash. Filtered export uses the same CLI. No fabricated successful response or installed Preview binary can satisfy this run.

For initial/set/clear: 160×26 = 4,160 filtered and 169×26 = 4,394 current evidence cells; 260 slots per role. Every value/mask/call/cache/color/style is checked, every current label matched to an unfiltered exact-identity LGE row, and raw calls compared after reopening. The set phase imports one direct call, FP, row comment, cell comment. Explicit clear restores pipeline call and original reviews/comments. Original input clone hashes are checked before/after.

No eligible exact zero exists in the cohort; unobserved pairs remain nil. `GenotypeExactZeroWorkbookAcceptanceTests.testAttestedReferenceZeroSurvivesReviewRegenerationReopenAndClear` independently declares CSV/catalog zero, seeds the established initial-current-copy revision pattern, then uses real controller request/execution/import/store/reopen/filtered export for FN set and clear. Current and filtered emitted numeric0/FN are verified, then FN absent on both after clear. Raw CSV is byte-identical. Exact candidate stable-ID collision protection remains in `testApplyHaplotypeOverridesFormatsReviewsUsingExactSemanticIdentity`, `testAmbiguousExistingRowsAreRebuiltFromExactCatalogIdentity`, `testDuplicateStableWorkbookIdentityRebuildsOneExactCatalogRow`, shared eligibility tests, and manifest-target importer tests. No MiSeq candidate visibility claim.

Baseline inputs attest science/payload/layout; renderer/runtime descriptors belong to the revision provenance envelope, not the baseline list. Tests verify the correct locations, all relevant checksums/sizes, exact worktree argv/version/options/runtime/status/time, and retained reviewed XLSX/baseline/receipt replay files. No provenance check was relaxed to hide a missing artifact.

## Independent QA reported by parent

- All three synthetic sheets rendered and inspected with ArtifactTool; dynamic H1 value/color change and independent H2 stability verified in memory.
- Real cohort current/filtered initial sheets rendered. Compact current reference labels, biological sorting, role-specific metadata and fitted source-revision rows passed after corrections.
- Final accepted call region, FP regions in both roles, changed current header band and explicit reset band all passed. Edited homozygous pair colors and reset only affect intended slot; neighboring data unchanged.
- Synthetic reference-zero filtered FN rendered as bold FN, pale fill and dashed orange frame. Parent PNG inspection is separate from emitted numeric0/OOXML assertions.
- Native Excel direct call and traditional Note edits saved; numeric evidence unchanged. Production importer accepts the actual native-saved bytes with matching original manifest.
- Pre-fix native formula caches updated but matrix fill stayed stale. Fresh fixed copy after setting both differential channels rendered correct blue H1 and retained green H2 after Calculate Sheet; calls also correct. User's existing manual calculation setting and unrelated workbook untouched.
- Original project final read-only witness: 636 files unchanged, SHA-256 `bd99dc7a0c29acefae4ac2bd6adb40a95f6e34d6f60de09070e44db33ce9c86c`. Private IDs/paths remain outside committed docs.

## TDD and diagnostic ledger

All runners use `swift test --jobs 6`, one process at a time. `/tmp` logs are local evidence, not repository fixtures. Counts below are executed tests / failures / unexpected errors (unexpected are included in failures).

| Log | Result and interpretation |
| --- | --- |
| `task6-presentation-red.log` | 4 / 19 / 0: renderer geometry/markers plus original order/bold regressions |
| `task6-presentation-green.log` | 10 / 1 / 0: original 3 regressions green; cache regex needed style-attribute tolerance |
| `task6-style-red.log` | 3 / 6 / 2: missing resolved style fields |
| `task6-audit-red.log` | 1 / 1 / 1: missing Show all button |
| `task6-style-green-note-red.log` | 6 / 8 / 1: style-state/alpha fixture corrections, Note repair context, current font/border |
| `task6-cf-red-style-green.log` | 7 / 2 / 0: styles/audit/Note/current green; differential-channel assertions red |
| `task6-native-green-integration-red.log` | 10 / 9 / 0: native importer + 7 renderer tests green; old v1 post-migration addressing red |
| `task6-cohort-focused.log` | 3 / 1 / 1: both inference migration tests green; cohort fixture zero assumption failed |
| `task6-cohort-focused2.log` | 1 / 1 / 1: primary `StopIteration` selecting nonexistent eligible zero surfaced |
| `task6-cohort-display-red.log` | 2 / 2 / 0: compact display and filtered guidance failures reproduced |
| `task6-focused-green3.log` | 17 / 3 / 2: cohort set parity passed; wrong provenance-list assumption and absent fixture sample assertion |
| `task6-focused-green4.log` | 3 / 1 / 1: complete cohort initial/set/clear green; synthetic noncanonical fixture locus rejected |
| `task6-focused-green5.log` | compile error only: unnecessary force unwrap in new test helper; no executed tests |
| `task6-focused-green6.log` | 7 / 9 / 1: exact FN OOXML/non-FN border/reset/false-override tests green; fixture authority/color-space corrections remained |
| `task6-focused-green7.log` | 3 / 1 / 1: authoritative captured palette+review and tint tests green; missing bundle suffix fixture rejected |
| `task6-zero-green8.log` | 1 / 1 / 1: suffix corrected; initial-current-copy attestation absent in fixture |
| `task6-zero-green9.log` | 2 / 1 / 1: generation/import/current green; unsupported MiSeq candidate omitted by filtered view, as designed; row/column conflict green |
| `task6-zero-green10.log` | 1 / 0 / 0, 16.887 s: supported reference-zero end-to-end set/clear green |
| `task6-role-red.log` | 1 / 1 / 0, 3.012 s: unsupported-call current role mislabeled filtered, corrected with role-aware guidance only |
| `task6-covering-green.log` | 12 / 1 / 0, 32.356 s: 8 renderer tests, native importer, reference-zero controller and exact-locus helper pass; one omitted-optional-revision assertion remains |
| `task6-final-fixture-green.log` | 1 / 0 / 0, 0.907 s: exact active-analysis export, absent transient revision and provenance checks pass |

Several deliberately throwing controller tests initially displayed a secondary AppKit/SwiftUI `InvalidTransition { phase: idle, targetPhase: failed(deinit) }` during teardown. This is distinct from the primary fixture `StopIteration`, CLI validation or provenance QA error. Contextual error/stderr logging exposed the primary causes. No speculative production view-lifecycle change was made. New fixture corrections preserve all catalog, CLI, attestation and visibility guards.

## Integrated command and result

Environment: `LUNGFISH_EXCEL_QA_PROJECT` / `LUNGFISH_EXCEL_QA_BUNDLE` point to the disposable project/analysis; `LUNGFISH_EXCEL_NATIVE_QA` points to the private original-manifest/native-edited fixture directory. Managed Python is the existing openpyxl environment. No optional QA test is intentionally skipped.

```sh
swift test --jobs 6 --filter 'GenotypeWorkbookPresentationTests|GenotypeThreeSheetEditableWorkbookTests|GenotypeEditableWorkbookTests|GenotypePivotFilteredCopyTests|GenotypeWorkbookRevisionServiceTests|GenotypeViewportExcelExportTests|GenotypeReviewedHaplotypeInferenceTests|GenotypeEffectiveHaplotypeProjectionTests|GenotypeCurrentWorkbookInputFingerprintTests|GenotypeCurrentWorkbookSyncCoordinatorTests|GenotypeExcelDialogBehaviorTests|GenotypeAuditTimelineExpansionTests|GenotypeReviewedHaplotypeEvidenceTests|GenotypeMatrixReviewCapabilityTests|GenotypeAnnotationStoreTests|GenotypeResultViewportMatrixReviewTests|GenotypeMatrixReviewEligibilityTests|GenotypeViewportStyleCaptureTests|GenotypeExactZeroWorkbookAcceptanceTests|GenotypeResultViewportHaplotypeDefinitionSearchTests/testMatrixStylePrecedenceCombinesRowAndColumnAndLetsCellOverride|GenotypeResultViewportHaplotypeDefinitionSearchTests/testMatrixCellStyleCanClearInheritedBold|GenotypeResultViewportSelectionAndComparisonTests/testFilteredSampleCellsCanHideManualRowHighlights|GenotypeResultViewportCandidateDetailTests/testAutomaticSupportFillIsUniformAcrossEveryProjectedAlleleKindForGenotypeOnlyONTAndMiSeq|GenotypeResultViewportCandidateDetailTests/testAuthoritativeHaplotypedResultRetainsFractionBasedSupportFill|GenotypeResultViewportCandidateDetailTests/testCandidateTintContrastUsesCompositedNameCellBackgroundAndManualTextWins|GenotypeResultViewportCandidateDetailTests/testMHCCandidateTintsAreExactAndOnlyColorAlleleNameCells' > /tmp/task6-integrated.log 2>&1
```

Integrated result: **442 tests, 5 assertion failures in 2 methods, 0 unexpected, 0 skips, 486.987 seconds**. Of the selected tests, 440 passed immediately, including the entire real-cohort round trip, FN controller acceptance, native importer, shared eligibility, style captures and safety gates. Failure details:

- `GenotypeViewportExcelExportTests.testReviewedActiveAnalysisReachesProductionFilteredWorkbookAndProvenance`: four stale physical-layout assertions. Extraction now uses call header names and retained payload identity to select actual evidence cells; structured Source revision JSON is decoded directly. Effective/baseline calls, both thresholds/denominators, retained exact row, active definition and provenance assertions remain intact.
- `GenotypeWorkbookRevisionServiceTests.testCurrentWorkbookScientificAndEditingTablesRetainEveryExactLocus`: H2 helper still read old column 9, now status. Both slot addresses are now selected by the current trusted manifest; all ten exact loci and H1/H2 values remain required.

After the integrated run, self-review found unsupported-call editable-current guidance mislabeled the role as filtered. A focused RED reproduced it; only the Editing text branch changed. Covering command (native fixture environment enabled):

```sh
swift test --jobs 6 --filter 'GenotypeWorkbookPresentationTests|GenotypeViewportExcelExportTests/testReviewedActiveAnalysisReachesProductionFilteredWorkbookAndProvenance|GenotypeWorkbookRevisionServiceTests/testCurrentWorkbookScientificAndEditingTablesRetainEveryExactLocus|GenotypeExactZeroWorkbookAcceptanceTests|GenotypeThreeSheetEditableWorkbookTests/testNativeExcelSavedCallsAndNotesRemainReviewable' > /tmp/task6-covering-green.log 2>&1
```

That run passed 11 of 12 tests (0 skips, 0 unexpected). The remaining app-fixture assertion assumed empty-string metadata rather than an omitted optional transient revision. The fixture independently requires the captured transient revision to be nil, asserts its absence in emitted structured metadata, and retains the exact active-definition ID check. Final focused command:

```sh
swift test --jobs 6 --filter GenotypeViewportExcelExportTests/testReviewedActiveAnalysisReachesProductionFilteredWorkbookAndProvenance > /tmp/task6-final-fixture-green.log 2>&1
```

Final focused result: **1 test passed, 0 failures, 0 unexpected, 0 skips, 0.907 seconds**. All integrated failures are accounted for by fresh passing checks. The integrated run was not repeated or represented as clean. Existing unrelated test-build warnings concern unused cleanup executor results, a FileManager Sendable conformance, and a redundant `public` modifier at `Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift:738` (covering log line 13); no unrelated fixes were made. These diagnostics are not claimed pristine. Parent final whole-branch review remains pending and is not represented as completed by this task.

## Self-review and handoff

Reviewed the scoped source/test diff and checked whitespace with `git diff --check`. Exact science/eligibility/no-clobber/provenance boundaries remain unchanged. No native retest is inferred from library output. All optional cohort/native cases were enabled. Both requested reports omit private paths/IDs. Independent QA artifact locations were delivered to the parent through the task channel and are retained outside the repository. Only final whole-branch review remains a separate parent-owned acceptance gate.

## Review fix round 1 — I1 and accepted-input byte binding

Fix base: `7de7c192eb5e5bb53f23c89290bdb84db72f27cb`. Read the formal Task 6 review. This wave changes tests/documentation only; no production calling, support, eligibility, scheduling, exporter or importer behavior changes. M1/M2 are explicitly deferred to parent final-review triage. M3 is addressed by adding the existing redundant-public warning category above and in the sanitized QA ledger.

`GenotypeFullCurrentEvidenceOracle.capture` freezes the validated raw LGE evidence model before current generation or accepted edits. Catalog rows/support are authoritative when present; otherwise exact raw reference/candidate/unnameable identities and observations establish the evidence map. No presentation builder, output manifest, source XLSX or viewport filter establishes this oracle. The phase's accepted LGE call records may add a call-only sample but cannot attest missing support. A shared checker requires complete unique row/sample sets, the full exact `(locus, genotype, stableClusterID, sample)` Cartesian roster and every payload rawSupport/displayValue. It independently checks the trusted manifest's semantic roster and unique addresses, then reads each corresponding XLSX cell. All existing filtered projection/style/call/provenance checks remain in place.

The same set/clear acceptance check now also hashes retained `input.xlsx` directly against that phase's accepted `Inspection.workbookSHA256`, in addition to existing receipt-descriptor checks.

Commands below ran serially from the task worktree. The cohort command used `LUNGFISH_EXCEL_QA_PROJECT` and `LUNGFISH_EXCEL_QA_BUNDLE` assigned to the same private disposable fixture described above; literal private values are omitted. The test itself makes another whole-project clone and verifies its source witness before/after. Python uses the existing managed openpyxl environment. No native app or other worktree was touched.

```sh
swift test --jobs 6 --filter GenotypeFullCurrentEvidenceOracleTests > /tmp/task6-fix1-oracle-red.log 2>&1
swift test --jobs 6 --filter GenotypeFullCurrentEvidenceOracleTests > /tmp/task6-fix1-oracle-green.log 2>&1
swift test --jobs 6 --filter GenotypeViewportExcelExportTests/testDisposableRealBundleControllerAndProductionExcelParity > /tmp/task6-fix1-cohort.log 2>&1
```

RED: **1 test, 1 expected failure, 0 unexpected/skips, 3.250 seconds**, exit 1. With the checker absent, actual shipping-rendered XLSX files remained internally consistent with their mutated payloads and the test reported `independent oracle accepted coherent corruption` for all five corruptions. GREEN: **1 test, 0 failures/unexpected/skips, 0.378 seconds**, exit 0. Exact output:

```text
REJECTED drop-row: payload row roster differs from raw authority
REJECTED drop-sample: payload sample roster differs from raw authority
REJECTED coherent-count: ('rawSupport', ('MHC-A', 'Candidate', 'cluster-a', 'S1'), 7, 700)
REJECTED unknown-to-zero: ('rawSupport', ('MHC-A', 'Reference', None, 'CallOnly'), None, 0)
REJECTED retarget-stable-id: payload row roster differs from raw authority
Accepted exact zero/sparse/call-only baseline; rejected all five coherent mutations
```

The mutation fixture first verifies that each actual XLSX agrees with its own payload, including the coerced count, before invoking the independent checker. It uses only the shipping Python renderer to author artifacts. Literal expected source values and stable identities are separate from that payload. The positive control preserves explicit zero, sparse unknowns and all-unknown call-only samples; two identically named candidate rows remain distinct by stable ID.

Sole actual-cohort rerun: **1 test, 0 failures/unexpected/skips, 88.216 seconds**, exit 0. Initial, set and clear each reported:

```json
{"filtered":{"rows":160,"samples":26,"slots":260,"evidenceCells":4160},"current":{"rows":169,"samples":26,"slots":260,"evidenceCells":4394},"independentRawEvidence":{"rows":169,"samples":26,"evidenceCells":4394,"knownCells":1909,"unknownCells":2485}}
```

Both accepted phases printed `input.xlsx SHA256 equals accepted Inspection.workbookSHA256`. No raw support was synthesized for the 2,485 unknown pairs. The existing no-attested-zero cohort guard, set/clear/reopen parity and original disposable-source before/after witness all passed. Final artifact root (including `raw-evidence-oracle.json`, per-phase dumps, current/filtered workbooks, CLI witness and retained accepted evidence) was delivered privately to the parent, not committed. Prior native/visual evidence is unchanged; this fix does not claim additional native testing.

The two GREEN selections total **2 tests, 0 failures/unexpected/skips**, with the intentional RED recorded separately. The integrated suite was not rerun. Existing FileManager Sendable diagnostics appeared during focused compilation; all pre-existing warning categories remain disclosed above. Self-review checked complete exact identities, unknown preservation, unchanged filtered assertions, accepted-input hash linkage, absence of production edits and `git diff --check`. Parent owns final whole-branch acceptance and deferred minor triage.
