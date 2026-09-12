# Unified One-Way Excel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. User approved expert-supervised implementation; proceed without another execution-choice prompt.

**Goal:** Replace editable/synchronized Excel with one immutable report containing all and filtered genotype matrices and optional actual haplotype results.

**Architecture:** A versioned IO snapshot owns both matrix projections and one common call/palette authority. Workflow constructs and writes the snapshot with durable provenance; CLI, GUI and scientific producers use that same service. Switch consumers before retiring current-workbook/import code so each task remains buildable.

**Tech Stack:** Swift/AppKit/SwiftUI, XCTest, managed Python/openpyxl, existing provenance services.

**Spec:** `docs/superpowers/specs/2026-09-12-unified-one-way-excel-design.md`

## Global Constraints

- One workbook contains, in order: `Haplotype Calls` when actual content exists, `Genotype Matrix - All`, `Genotype Matrix - Filtered`, `Export Metadata`. Without haplotype content there are three sheets and no haplotype bands.
- One immutable scientific snapshot and one matrix renderer; static literal calls/colors, no import actions, editable Notes grammar, formulas or cache repair in the new export.
- All means all authoritative genotype-matrix evidence in the selected analysis. Filtered means exactly the viewport's captured sample/row order, stable identities and displayed cell values after all active filters.
- Both matrix bands and the calls sheet use the same effective H1/H2 values, statuses, sources and palette, including homozygotes, swaps, manual changes, explicit absence, and errors.
- Actual manual assignments and analyzed unresolved/error results establish content; empty manually eligible placeholders do not.
- Retain FP/FN, comments, explicit styles, candidate stable IDs, ONT support semantics, and true denominator/filter metadata. Unknown is not zero; FP requires positive support, FN requires attested zero.
- Every scientific export must retain reproducible final-path provenance: workflow/version, argv/replay command, options/defaults, runtime, input/output checksums/sizes, exit status, elapsed time and useful stderr. Reject incoherent or changed scientific snapshots; do not publish partial reports.
- No Excel import/backward-edit compatibility or ongoing current.xlsx lifecycle. Preserve native curation, accepted annotations/audit, scientific artifacts, shared publication locks, interrupted project recovery and cheap historical manifest fields.
- UI has one export action and clearly discloses both all and filtered data and one-way snapshot semantics. CSV/TSV remain separate supported formats.
- Work only in `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/excel-three-sheet-layout`, branch `codex/excel-three-sheet-layout`. Use apply_patch. Do not merge/push/release or touch unrelated worktrees/original private projects. No nested subagents.
- Run one Swift build/test process at a time with `--jobs 6`. Record RED/GREEN commands, summaries and log paths. Read TDD/writing-good-tests before tests. Use literal independently derived expectations. Commit each reviewed task.

## File and dependency boundaries

IO owns public serializable values and the static Python renderer. Workflow owns result/sidecar interpretation, witness capture, runtime execution and publication. UI owns settled viewport state and the save dialog; CLI owns argument parsing. No Workflow → UI/CLI dependency. Existing editable APIs can coexist only until Task 4 retires consumers; no final compatibility bridge.

### Task 1: Versioned snapshot and static shared workbook renderer

**Files:**
- Modify `Sources/LungfishIO/Bundles/GenotypeWorkbookPresentation.swift` (reuse Style/Sample/Target/Cell/Row/Slot/Call/Color values).
- Create `Sources/LungfishIO/Bundles/GenotypeWorkbookSnapshot.swift` and `GenotypeWorkbookSnapshot+Script.swift` for neutral snapshot contract/static renderer.
- Create `Tests/LungfishIOTests/GenotypeWorkbookSnapshotTests.swift`.

**Interfaces:** `GenotypeWorkbookPresentation.Matrix` is Codable/Sendable with samples, loci, rows. `GenotypeWorkbookPresentation.Snapshot` is Codable/Sendable with schemaVersion=3, generatedAt, sourceRevision, allMatrix, filteredMatrix, calls, colors, hasHaplotypeContent, metadata. Store scientific witnesses in sourceRevision/metadata and the durable capture receipt; do not create a second editable manifest. Public initializers and immutable properties. `GenotypeWorkbookPresentation.snapshotPythonScript` defines `render_genotype_snapshot(payload, output_path)` and a single `_render_matrix(...)` used twice. The renderer returns a compact sheet/row/cell summary, not an edit-import manifest.

- [ ] Write a real openpyxl fixture test first using the existing presentation-test process harness pattern. Hand-derived example: sample S1/S2, locus A, homozygous S1 M4A/M4A; S2 M1A/M3A; All counts [1,5], Filtered [nil,5]. Assert literal values and identical call fills in all three locations, no formula XML, no validation/import columns, and sheet order.

```python
assert wb.sheetnames == ['Haplotype Calls', 'Genotype Matrix - All', 'Genotype Matrix - Filtered', 'Export Metadata']
assert not any(c.data_type == 'f' for ws in wb for row in ws for c in row)
assert all(not ws.data_validations.count for ws in wb)
```

- [ ] Run focused RED. Implement the schema and script using `_literal`, resolved style/review rendering and generated read-only comments from the prior renderer, without its edit grammar/formula logic. Reuse existing value types rather than duplicate science. Validate duplicate/unknown sample, row and call identities; cell roster and nonnegative integer raw/display values; filtered identity subset and consistency; baseline/status types; metadata strings. Fail before saving invalid output.
- [ ] Add behavioral fixtures for absent content (3 sheets/no bands), analyzed unresolved and manual-only content (4 sheets), sparse loci/samples, masked support, FP/FN/unknown and invalid reviews, explicit style clearing, duplicate candidate labels with different stable IDs, literal formula-like sample/comment/call text, empty filtered axes, and color parity. Supply hasHaplotypeContent explicitly; producers in Task 2 decide capability from actual authority rather than count of placeholders.
- [ ] GREEN: `swift test --jobs 6 --filter 'GenotypeWorkbookSnapshotTests|GenotypeWorkbookPresentationTests'`. Existing three-sheet tests remain until retirement. Self-review and commit. Report exact new initializer/function signatures for Task 2.

### Task 2: Shared scientific snapshot builder, export service and CLI routing

**Files:**
- Create `Sources/LungfishWorkflow/ONTGenotyping/GenotypeExcelSnapshotBuilder.swift` (scientific projection and capture validation).
- Create `Sources/LungfishWorkflow/ONTGenotyping/GenotypeExcelExportService.swift` (runtime and atomic report/provenance publication).
- Modify `Sources/LungfishCLI/Commands/GenotypeExportPivotXlsxSubcommand.swift`, `GenotypeExportPivotXlsxSubcommand+Presentation.swift`, `GenotypeExportSubcommand.swift`, `GenotypeExportXlsxSubcommand.swift`, `Sources/LungfishCLI/Support/GenotypeXlsxWorkbookWriter.swift` to route genotype XLSX output through the common service.
- Reuse/extract scientific DTOs/input validation from `GenotypeWorkbookRevisionService.swift` and its `+PresentationScript.swift`; do not call the revision updater from the new service.
- Create `Tests/LungfishWorkflowTests/GenotypeExcelExportServiceTests.swift`; modify `Tests/LungfishCLITests/GenotypePivotFilteredCopyTests.swift`, `GenotypePivotThresholdTests.swift` and existing genotype XLSX CLI tests.

**Interfaces:** Consume Task 1 Snapshot/Matrix and existing `ONTGenotypeResultBundleData`, `GenotypeAnnotationSidecar`, `GenotypeViewProjection`. Provide public `GenotypeExcelSnapshotBuilder.capture(result:sidecar:allProjection:filteredProjection:generatedAt:) throws -> GenotypeWorkbookPresentation.Snapshot` where the two projections are optional; a supplied allProjection must be complete, and a supplied filteredProjection must be identity/evidence coherent. Full call authority always comes from full analysis/native assignments, not filtered projection scope or genotype-derived fake haplotypes. Provide `GenotypeExcelExportService(pythonExecutableURL:)` and an async `export(snapshot:outputURL:provenance:)` returning final output/receipt URLs; define a typed nested provenance request with witnessed input bytes/files, invocation/options/defaults, runtime context. Publish these exact public signatures and any additional typed initializer in the task report for later tasks.

- [ ] Write RED fixtures exercising the production builder and service, not only the Python renderer: genotype-only empty assignments yields 3 sheets; manual assignment yields 4; unresolved analysis yields 4; M4 homozygote repeats faithfully; one-read cell hidden at threshold 5 remains only in All; distinct duplicate-label candidates and exact zero stay correct. CLI tests should inspect emitted workbook values, not grep source.
- [ ] Derive all evidence from authoritative raw-support/catalog inputs and preserve user ordering/styles without active visibility restrictions. A provided complete allProjection is a capture aid, not authority to invent raw support. Resolve reviews with `GenotypeMatrixReviewEligibility`, comments/styles via the existing authority helpers, and calls with native effective/manual authority. Validate full input coherence; do not infer actual calls from the old manual-placeholder adapter.
- [ ] Build both projections from one input snapshot. When no GUI projection is supplied, resolve explicit/default CLI filters; both matrices may legitimately match. Preserve known-call vs candidate support and denominator semantics. No source-workbook copy or current.xlsx lookup in new XLSX export.
- [ ] Write a durable snapshot plus replay script/receipt at final output-adjacent paths using existing provenance/publication patterns. Capture checksums of exact bytes used; verify mutable scientific inputs across capture; preserve previous successful output on renderer/provenance failure. Workbook generation must work from explicit in-memory captured inputs so pipelines can use it before their final manifest exists.

```swift
let snapshot = try GenotypeExcelSnapshotBuilder.capture(
    result: result, sidecar: sidecar, allProjection: nil,
    filteredProjection: capturedView, generatedAt: capturedAt)
// Serialize this snapshot once; the writer must not reload the source bundle.
```

- [ ] Switch all genotype CLI XLSX entry points to the same schema/service. Keep CSV/TSV behavior and native scientific apply/replay commands intact. Update obsolete source-workbook options/help and tests to the one-way contract without a legacy Excel bridge.
- [ ] GREEN focused Workflow/CLI tests; add changed-input rejection, nonmutation, literal-text, output-path/provenance hash, rerunnable durable receipt tests. Self-review and commit, reporting covering test commands and interfaces.

### Task 3: One Inspector action and simultaneous GUI capture

**Files:**
- Modify `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`, `GenotypeComparisonMatrixView.swift`, `GenotypeViewportExportSnapshot.swift`, `GenotypeViewportExportService.swift`, `GenotypeResultDocumentSection.swift`, `GenotypeResultDisplaySection.swift` and existing projection serializer where defined.
- Modify `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift` Excel action routing.
- Remove `Sources/LungfishGenotypeUI/GenotypeExcelExportChoice.swift` when callers/tests have switched.
- Modify `Tests/LungfishGenotypeUITests/GenotypeExcelDialogBehaviorTests.swift`, `GenotypeViewportPivotExportTests.swift`, `GenotypeResultViewportWorkbookPublicationTests.swift`, `Tests/LungfishAppTests/GenotypeViewportExcelExportTests.swift`.

**Interfaces:** Consume Task 2 builder/service. `GenotypeViewportExportSnapshot` carries a frozen unified Snapshot for XLSX alongside unchanged delimiter-export data. Capture full and filtered projections without changing live UI filters or displaying a second viewport. Event/state becomes last successful Excel export, not filtered/current role.

- [ ] RED mounted Inspector/dialog and production capture tests: one action; no role choice/review-sync controls; five-read threshold + search/sample/locus/manual row visibility captured exactly; All remains complete; filtering does not truncate the common call authority; pending native edits settle before capture.
- [ ] Replace the dialog with the ordinary save panel and concise accessory: `Includes all results and the current filtered view. This is a snapshot; make edits in LGE and export again. Filtering does not remove data from the All worksheet.` Timestamp the default filename. Keep cancellation, progress/errors, and last-success status; do not require source-project write ownership for standalone export.
- [ ] Add pure unfiltered projection/capture using the same matrix model and style resolver while retaining exact current viewport mask/order for Filtered. Capture sidecar/calls/palette/raw-evidence witnesses together, then serialize the unified snapshot. Do not defer raw-evidence loading until the CLI subprocess. Use the shared service or its snapshot-input CLI path; keep durable GUI provenance and rollback.
- [ ] Disconnect GUI Excel review/update/open-current callbacks and six sync-state UI. Leave definitions only while Task 4 retires backend consumers. Preserve native save/curation/dropout/call-order updates. Do not broaden ONT curation UX beyond preserving existing functionality.
- [ ] GREEN focused UI/App export tests including readable source to external destination, cancelled export, no background regeneration after native edit, and unchanged captured output after later edit. Self-review and commit.

### Task 4: Switch scientific producers and remove the entire active Excel lifecycle

**Files:**
- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline+Reports.swift`, `FullLengthONTMHCGenotypingPipeline+Publication.swift`, `ONTBarcodeDemuxGenotypingPipeline.swift`, corresponding CLI output consumers and pipeline tests.
- Modify `Sources/LungfishApp/Services/WorkflowOperationExecutionService.swift`, native annotation store workbook-only methods, remaining current-workbook callback/registration consumers and their tests.
- Remove importer modules `GenotypeEditableWorkbookService.swift`, `+Script.swift`, `+ThreeSheet.swift`, `Sources/LungfishApp/Views/Inspector/GenotypeExcelReviewPresenter.swift`.
- Remove `GenotypeCurrentWorkbookSyncCoordinator.swift`, `GenotypeCurrentWorkbookUpdateExecutionService.swift`, `GenotypeCurrentWorkbookOpenHandoff.swift`, `FastqUpdateCurrentWorkbookSubcommand.swift`, `GenotypeCurrentWorkbookInputFingerprint.swift`, `GenotypeWorkbookUpdateAttemptRecorder.swift` after consumers switch.
- Retire `GenotypeWorkbookRevisionService.swift`, `+PresentationScript.swift`, unused `+OverrideScript.swift`, old `GenotypeWorkbookPresentation+Script.swift` and its obsolete Payload once scientific reusable DTO/helpers are extracted to neutral files. Keep shared simple presentation value types used by new Snapshot.
- Retain shared `ONTGenotypeBundlePublicationLock`, `ONTGenotypeWorkbookUpdateTransaction.swift`/cleanup machinery needed for interrupted historical scientific publication, bundle loading and project storage. Historical optional manifest fields need not be removed.

**Interfaces:** New initial scientific report output is the Task 2 service output; producer manifests/provenance point at final relocated report payloads, not temporary paths. No active currentWorkbook update/dirty/fingerprint lifecycle remains. Native scientific editing/replay/publication APIs retain behavior.

- [ ] RED production pipeline/AI completion fixtures demonstrating no current.xlsx copy/automatic updater and a unified report for both full-length ONT and MiSeq/barcode genotype-only. Verify accepted native annotation/audit records and active analysis/definition artifacts survive cutover.
- [ ] Replace initial-copy/decorated-current helpers with shared report capture/write before manifest finalization using explicit pipeline state. Preserve scientific analysis/definition artifacts previously created inside those helpers. Update descriptors, returned CLI URLs and relocated provenance together. AI completion publishes its scientific result without automatic current.xlsx regeneration; report remains explicit export unless that producer already promises an initial report.
- [ ] Delete active importer/synchronizer modules and references; extract only demonstrably shared scientific helpers. Remove old importer/state-machine tests whose contract was retired; port their raw evidence/review/provenance and native authority assertions to new service/capture tests. Remove stale public help/docs about editing Excel, source-workbook copies and review sync.
- [ ] GREEN pipeline, AI completion, native curation/replay and shared recovery/cleanup selections; compile App and CLI. Source inventory classifies remaining workbook references as historical scientific inputs/recovery or unrelated non-genotyping export; no active alternate genotype XLSX renderer or update registration remains. Self-review and commit, reporting deletion footprint and retained dependencies.

### Task 5: Independent cross-workflow acceptance and visual QA

**Files:**
- Add/modify `Tests/LungfishAppTests/GenotypeUnifiedExcelAcceptanceTests.swift`, Workflow and CLI export tests as necessary to exercise production captures.
- Create `docs/reviews/2026-09-12-unified-one-way-excel-qa.md` with sanitized evidence, commands, retained limitations and source witness; no private project data.

**Interfaces:** Production UI/CLI/pipeline service only; use Task 1 reader assertions with an independently built evidence oracle, not production adapter-generated expected values. Tests exercising removed Excel import behavior are out of scope.

- [ ] RED independent fixtures for real failure classes: drop a sample/row, mutate support consistently across both outputs, convert unknown to zero, retarget stable candidate identity, diverge H2/palette between matrices/calls. Oracle must reject each corruption.
- [ ] Run synthetic end-to-end exports for haplotyped MiSeq, full-length ONT, genotype-only no calls, manual calls and analyzed unresolved status. Assert sheet count/order, literal cell types, palette/status/source parity, complete All evidence and exact Filtered masks/annotations with min reads 5 plus combined visibility controls.
- [ ] Run supplied Biomere2 cohort only on a new disposable clone of `/tmp/lge-three-sheet-qa.XyCN2M/cohort.lungfish`. Never load the original. Compare all evidence against raw inputs and filtered against captured LGE, including homozygotes and all five loci. Verify original read-only witness remains SHA-256 `bd99dc7a0c29acefae4ac2bd6adb40a95f6e34d6f60de09070e44db33ce9c86c` using the existing witness walker; do not commit identifying data.
- [ ] Follow spreadsheets skill for artifact inspection; render the new four-sheet and genotype-only three-sheet outputs and inspect actual images. Verify metadata readability and full-data disclosure, both matrix bands, same call colors, FP/FN/comments, no overflowing headers. Check durable replay after temporary staging removal, final checksums/sizes/runtime/options/defaults and no source mutations. Native Excel inspection is read-only on disposable files; do not touch the user's open workbook.
- [ ] Run one consolidated covering suite for the new surface plus preserved native authority/recovery. If a failure appears, diagnose before fixes and retain concrete evidence. Self-review and commit QA/regression tests. Final whole-branch review follows this task; packaging/publication requires later user authorization.
