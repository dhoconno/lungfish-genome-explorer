# Task 1 report: exact effective calls and filtered workbook parity

## Outcome

Implemented the shared effective-call and filtered-workbook authority. Effective H2 homozygous display normalization now happens in `GenotypeEffectiveCallAuthority` after override resolution. Raw pipeline baselines and sources remain unchanged, while an explicit analyst `"-"` keeps `noHaplotype` status and wins. The two UI-only normalizers were removed.

New typed filtered exports contain only a clean `Genotype Matrix` rebuilt from projected cells, a compact complete scoped `Haplotype Calls`, and `Export Metadata`. They do not retain template companion sheets, haplotype headers, totals, raw summaries, or other unfiltered template data. Legacy projections without the new call payload retain prior copy behavior. Cell values come directly from the projection; the writer does not re-threshold them. Text payload cells are forced to string type, including leading `=`.

Current workbooks now retain every exact locus, add a compact exact `Haplotype Calls` sheet, populate DR/DRB legacy overview rows where present, and no longer perform writer-only homozygous-family inference. DQA/DQB/DQ and DPA/DPB/DP remain distinct in exact authority; legacy combined overview cells remain explicitly derived presentation aliases.

## Exact shared APIs for Tasks 2–3

- `GenotypeEffectiveCallAuthority.resolve(analysis: GenotypeHaplotypeAnalysis, sidecar: GenotypeAnnotationSidecar) -> Resolution`
  - `Resolution.value(sample:locus:slot:) -> SlotValue?`
  - `Resolution.locusValue(sample:locus:) -> LocusValue?`
  - `SlotValue` exposes `baseline`, normalized `effective`, per-slot `status`, `source`, and `authoritativeOverride`.
- `GenotypeViewProjection.init(..., haplotypeCalls: [GenotypeViewProjectionHaplotypeCall]? = nil, sourceRevision: GenotypeViewProjectionSourceRevision? = nil, filterContext: [String:String]? = nil)`.
- `GenotypeViewProjectionHaplotypeCall.init(sample:locus:haplotype1:haplotype2:haplotype1Status:haplotype2Status:haplotype1Source:haplotype2Source:baselineHaplotype1:baselineHaplotype2:comment:)`.
- `GenotypeViewProjectionSourceRevision.init(assayID:analysisRevisionID:definitionSetID:)`.
- `GenotypeViewportExportSnapshot.init(..., annotationSidecarData: Data? = nil, haplotypeCalls: [... ]? = nil, sourceRevision: ...? = nil, haplotypeSampleScope: [String]? = nil, haplotypeLocusScope: [String]? = nil)`.
  - `annotationSidecarData` freezes all matrix reviews/comments and overrides at capture. Export writes `<output>.annotations.json` and uses that durable input instead of rereading the live bundle path.
  - Semantic haplotype scope is separate from matrix axes. The special haplotype-definition view supplies its visible sample/locus scope while export uses a compatible genotype-matrix projection rather than allele IDs as workbook sample columns.

All new projection fields decode as nil when omitted, preserving legacy JSON compatibility.

## TDD and verification evidence

- Baseline supplied by parent: `swift test --jobs 6 --filter 'GenotypeMatrixBaseProjectionTests|GenotypeEffectiveHaplotypeProjectionTests'`: 16 passed, 0 failed; `/tmp/lge-excel-baseline.log`.
- RED: `swift test --jobs 6 --filter GenotypeEffectiveHaplotypeProjectionTests`: 11 executed, 3 expected failures. Pipeline H2 remained `"-"`; explicit absence was normalized to empty.
- GREEN: same command: 11 passed, 0 failed.
- Projection RED: focused serializer test failed to compile because exact call/revision APIs did not exist.
- Projection GREEN: focused serializer test passed, 1/1.
- Real openpyxl filtered writer: `GenotypePivotFilteredCopyTests/testViewportProjectionControlsVisibleRowsColumnsValuesAndAnnotations` passed and asserts only three sheets, clean matrix, exact DRB homozygote, literal leading-`=` comment, preserved FP/FN/comments, and blank/10 projected boundary cells.
- Boundary smoke: 18 passed, 0 failed (`/tmp/lge-task1-boundary.log`), including frozen sidecar bytes and current DRB parity.
- Full required focus: `swift test --jobs 6 --filter 'GenotypeEffective|GenotypeViewportPivotExportTests|GenotypePivotFilteredCopyTests|GenotypeWorkbookRevisionServiceTests'`: 192 passed, 0 failed in 266.472 seconds (`/tmp/lge-task1-focused-green.log`).
- Final post-origin/clean-matrix checks: 19 passed, 0 failed (`/tmp/lge-task1-final-targeted.log`). Hand-derived min-read boundary test covers 1/4/5/6 at threshold 5.
- `git diff --check`: clean.

## Diagnostic and artifact evidence

The confirmed selected-pivot leak was retained unfiltered companion/template content, not projected cell filtering. The first retained artifact exposed additional stale pivot headers and raw totals; the writer was tightened to rebuild a clean typed matrix. Final synthetic output: `/tmp/lge-task1-filtered-view-clean.xlsx`. Parent visual QA passed for the clean matrix, metadata, and compact calls sheets; screenshots are `/tmp/lge-excel-qa.dHpUIY/filtered-matrix-clean.png`, `/tmp/lge-excel-qa.dHpUIY/filtered-metadata-clean.png`, and `/tmp/lge-excel-qa.dHpUIY/filtered-haplotypes.png`.

The private source cohort was never written. A deterministic hash over its sorted file hashes after work is `0890f87ec7c0372b63aee4c3e4f91edcf43ab0184154fc08b9da17817c6956a7`.

## Changed files

- `Sources/LungfishIO/Bundles/GenotypeEffectiveCallAuthority.swift`
- `Sources/LungfishIO/Bundles/GenotypeViewProjection.swift`
- `Sources/LungfishGenotypeUI/GenotypeViewportExportSnapshot.swift`
- `Sources/LungfishGenotypeUI/GenotypeViewportExportService.swift`
- `Sources/LungfishGenotypeUI/GenotypeHaplotypeDefinitionMatrixView.swift`
- `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- `Sources/LungfishCLI/Commands/GenotypeExportPivotXlsxSubcommand.swift`
- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift`
- Tests in CLI, Genotype UI, and Workflow suites named in the task brief.

## Concerns / handoff

- Task 3 must capture only after committing valid numeric drafts, then pass this immutable snapshot unchanged. The byte-freeze boundary exists; dialog timing still owns when it is invoked.
- Legacy combined DQ/DP overview cells intentionally remain derived aliases and can collapse exact calls for presentation. Editing authority must use the exact `Haplotype Calls` identities, never those combined cells.
- Existing pre-task Swift concurrency warnings remain; no new test errors or warnings attributable to this task were observed.
