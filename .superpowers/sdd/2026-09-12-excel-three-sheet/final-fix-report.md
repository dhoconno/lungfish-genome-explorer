# Grouped final-review fix report

Base: `0310f76468cbedd2be1d2c3b8eded9e75e824bbc`.
Workspace: `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/excel-three-sheet-layout`.
Scope: I1–I3 and M1–M2 from `final-review.md`; no new features, calling rules, inference scheduling, cohort QA, or native-app interaction.
Status: DONE. All five findings addressed; no remaining correctness concern identified in self-review.

## Implemented

- **I1:** `--presentation-colors` is optional. Omission resolves the active definition set through the existing resolver and each definition's `effectiveFillColor`, including overrides. Explicit `[]` is decoded as the captured empty palette. The command resolves once and passes the same array to annotation-only fingerprint inputs and the renderer; the retained `presentation-inputs.json` and payload carry it. The attempt receipt records the canonical resolved array. Original argv preserves omission; durable CLI replay pins the resolved array so future definition changes cannot silently change replay colors. Definition resolution never invokes active-analysis inference.
- **I2:** The production Python renderer receives explicit payload and layout output paths, in addition to the workbook path. Staging argv names staged JSON outputs; durable argv names JSON outputs in the retained update generation and the workbook at `artifacts/workbooks/current.xlsx`. Existing output descriptors, checksums, sizes, workflow/runtime/status information and actual execution argv remain intact.
- **I3:** Supported literal text/null types are checked before the blank-slot no-op. Numeric and Boolean entries reject the complete inspection with `Haplotype Calls!D2` repair context and text-entry guidance. Genuine null blanks remain no-ops; literal text `123` remains a valid proposed call. Both invalid types are exercised alone and alongside a valid Note edit.
- **M1:** All user-editable Note semantic validation errors now include the worksheet/address. Tests cover nonempty keep, clear carrying a value, and unsupported review values, alongside the existing malformed-grammar case.
- **M2:** The existing FP → invalid FN fixture seeds its analyst style exclusively in the annotation sidecar. It now asserts raw numeric 42, General format, exact text color `123456`, fill `DDEEFF`, four `thin:654321` borders, false bold/italic, invalid review withholding and byte-identical submitted sidecar retention. This was a coverage-only change and passed before production changes.

## TDD and focused verification

All commands below ran from the workspace above, with one Swift runner at a time and `--jobs 6`.

Initial grouped RED:

```sh
swift test --jobs 6 --filter 'FastqGenotypingCommandTests/testCurrentCLIResolvesOmittedPaletteAndPreservesExplicitEmptyThroughAnnotationRefresh|GenotypeThreeSheetEditableWorkbookTests/testSemanticNoteErrorsIdentifyRepairCell|GenotypeThreeSheetEditableWorkbookTests/testTypedNonemptyBlankSlotEditsRejectWholeInspectionWithRepairContext|GenotypeWorkbookRevisionServiceTests/testThreeSheetCurrentRefreshRetainsSemanticCallsAndCachedBand|GenotypeWorkbookRevisionServiceTests/testReviewBecomingInvalidRestoresPriorManagedPresentation' > /tmp/lungfish-final-fix-red.log 2>&1
```

Result: 5 tests, 9 failures, 2 categorized by XCTest as unexpected. The seven importer assertions reproduced I3/M1: four unsupported typed edits were silently ignored, and three semantic errors omitted `Genotype Matrix!D5`. The replay command completed, then the independent test asserted that the declared retained `presentation-payload.json` was missing; its Python assertion is surfaced by the existing helper as an unexpected XCTest error. The other unexpected failure was **fixture setup**, not I1: the reused CLI fixture CSV lacked `passed_unique_reads`. The new test now writes a valid synthetic CSV locally without altering the shared helper or production validation. M2 passed as expected.

Corrected CLI RED, before palette production changes:

```sh
swift test --jobs 6 --filter 'FastqGenotypingCommandTests/testCurrentCLIResolvesOmittedPaletteAndPreservesExplicitEmptyThroughAnnotationRefresh' > /tmp/lungfish-final-fix-red-cli.log 2>&1
```

Result: 1 test, 6 failures, 0 unexpected. Both omitted-palette generations produced `[]`, the synthesized argv incorrectly included `--presentation-colors`, and resolved receipts were empty. Both explicit-empty controls passed. This is the meaningful I1 RED evidence.

The grouped command above was then run with the respective output paths `/tmp/lungfish-final-fix-green.log` and `/tmp/lungfish-final-fix-green-confirmed.log`. Both runs passed the four importer/replay/restoration tests and failed only two CLI assertions. Those were new test overconstraints, not remaining production defects: static openpyxl RGB values carry a `00` alpha prefix, and each colored call has a separate neutral fallback conditional rule. A subsequent CLI-only run using `/tmp/lungfish-final-fix-green-cli.log` exposed the same inappropriate alpha constraint on font colors. The final test checks RGB color components for static fills/fonts, locates the exact positive conditional formula for every slot, and requires opaque `FF336699` foreground **and background** for its differential fill. The production renderer was not changed for these assertion corrections.

The CLI test also now supplies an independently specified literal expected palette to the annotation-only fingerprint attestation, and verifies original versus durable provenance argv. Final focused CLI GREEN:

```sh
swift test --jobs 6 --filter 'FastqGenotypingCommandTests/testCurrentCLIResolvesOmittedPaletteAndPreservesExplicitEmptyThroughAnnotationRefresh' > /tmp/lungfish-final-fix-green-cli-confirmed.log 2>&1
```

Result: 1 test passed, 0 failures/0 unexpected, exit 0. Its four scenarios cover initial and annotation-only output with both omitted and explicitly empty palettes. Together with the four passing focused regressions above, this establishes GREEN for all five findings before the single covering run.

## Covering selection

```sh
LUNGFISH_EXCEL_NATIVE_QA=/tmp/lge-three-sheet-qa.XyCN2M swift test --jobs 6 --filter 'GenotypeCurrentWorkbookInputFingerprintTests|GenotypeWorkbookPresentationTests|GenotypeThreeSheetEditableWorkbookTests|FastqGenotypingCommandTests/test(UpdateCurrentWorkbook(Parses|Rejects|AttestationFlagsHaveHelpText|ProvenanceDescribesExactImmutableCLIInputPaths)|AnnotationOnlyUsesDisplayedCallsOnlyForSemanticFingerprint|CurrentCLIResolvesOmittedPaletteAndPreservesExplicitEmptyThroughAnnotationRefresh|ManagedRuntimeResolutionFailureRecordsResolvedDefaultsAndRuntimeIntent|ValidBundleInvalidOptionRecordsExactArgvAndNormalizedCommand)|GenotypeWorkbookRevisionServiceTests/test(ThreeSheet|ReviewBecomingInvalidRestoresPriorManagedPresentation|ApplyHaplotypeOverridesWritesMatrixAnnotationsToCurrentWorkbook|ApplyHaplotypeOverridesProvenanceNamesFinalStoredSidecarAndWorkbook|AnnotationOnlyUpdateAttestsFullSemanticCallsAndRetainsTheirProvenance)' > /tmp/lungfish-final-fix-covering.log 2>&1
```

Result: 69 tests, 68 passed, 1 failure, 0 unexpected, 0 skips, exit 1. Breakdown: 10 CLI tests (one failed), 24 fingerprint tests passed, 16 importer tests passed, 8 renderer tests passed, and 11 current/replay/restoration tests passed. The sole failure was the older exact runtime-failure receipt-options expectation omitting `presentationColors`; it now includes `resolve-active-definitions`, the honest unresolved intent when runtime resolution fails before palette resolution. The rest of its expected map and all runtime/status/input assertions were preserved. No production change followed this covering run.

As directed by the parent, only that amended assertion's test was rerun:

```sh
swift test --jobs 6 --filter 'FastqGenotypingCommandTests/testManagedRuntimeResolutionFailureRecordsResolvedDefaultsAndRuntimeIntent' > /tmp/lungfish-final-fix-runtime-receipt-green.log 2>&1
```

Result: 1 test passed, 0 failures/0 unexpected/0 skips, exit 0. Thus the covering run's 68 passes stand, and its only failure has a focused passing rerun. This is **not** represented as a fresh clean 69-test run. `git diff --check` passed after the final test edit.

The parent authorized use of the already saved synthetic native fixture for importer coverage. The directory contains `native-task6-original.xlsx`, `native-task6-original-manifest.json`, and `native-excel-task6.xlsx`. This exercises importing previously saved native bytes; it is not a fresh Excel-native interaction run. No cohort test, private project, CUA tool or global Excel setting was used.

## Replay evidence and output locations

The replay regression copies its synthetic bundle to a sibling `replay.lungfishgenotype` inside the test's disposable `GenotypeWorkbookRevisionServiceTests-<UUID>` directory. It rebases durable absolute paths, deletes all three expected output files in that copy, and verifies absence before invoking the retained production script's `durableReplayArgv`. It requires all three outputs at their declared relative locations:

- `artifacts/workbooks/current.xlsx`
- `artifacts/workbooks/updates/<generation>/presentation-payload.json`
- `artifacts/workbooks/updates/<generation>/presentation-layout.json`

Recreated payload/layout JSON contents are compared against the original generation. Every populated workbook cell is compared by coordinate, physical type and value in both formula and `data_only` modes, covering scientific values, formulas and initial caches. Existing literal `Exact-A` call/cache assertions and final stored output checksum/size checks remain. Actual execution argv must differ from durable replay argv. No checks rely merely on pre-existing retained output files. Test fixture directories clean themselves up; the logs above are the durable test evidence.

## Files and self-review

Production files changed:

- `Sources/LungfishCLI/Commands/FastqUpdateCurrentWorkbookSubcommand.swift`
- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeEditableWorkbookService+ThreeSheet.swift`
- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+PresentationScript.swift`
- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`

Test files changed:

- `Tests/LungfishCLITests/FastqGenotypingCommandTests.swift`
- `Tests/LungfishWorkflowTests/GenotypeThreeSheetEditableWorkbookTests.swift`
- `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`

Self-review checked the complete diff, nil-versus-empty transport, annotation-only fingerprint precedence, exact-locus definition colors, durable output argument ordering, unchanged provenance output descriptors, typed call validation before no-op handling, whole-inspection failure, and sidecar-authoritative style restoration. No raw-count edit permission, importer trust boundary, unknown-versus-zero rule, duplicate-review policy, captured filter mask, v1 pending-edit guard or inference scheduling was changed. The existing large revision service/test files were edited narrowly rather than restructured.

Pre-existing build warnings remain: unused `execute` results in `ProjectStorageCleanupExecutorTests.swift` and the redundant `public` modifier in `ProvenanceRecorder.swift:738` appeared in the build logs. No unrelated warning cleanup was performed and no pristine-build claim is made. Final scoped review belongs to the parent. No push, merge or release was performed.
