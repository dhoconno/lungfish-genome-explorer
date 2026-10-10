# LungfishGenotypeUI

Line numbers were checked at commit 770ae1a92. When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for MHC genotype results from ONT and MiSeq amplicon genotyping. It holds the three-lens viewport (Summary, Review, Audit), the comparison matrix, the haplotype tape, manual haplotyping, call overrides, Smart Cohorts and the Excel and matrix exports (memory file project_mhc_genotype_inspector_v2.md). Calls are computed in Sources/LungfishWorkflow/ONTGenotyping and Sources/LungfishIO/Bundles, never here.

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit and SwiftUI. Never LungfishApp or another leaf module (memory file project_module_architecture.md).

## Entry points

| Type | Path |
|---|---|
| `GenotypeResultViewController` and `configure(result:)` | Sources/LungfishGenotypeUI/GenotypeResultViewController.swift lines 78 and 1197 |
| `GenotypeViewportExportCoordinator`, the Excel export path, the one GUI export since 24fe49f05 (CSV and TSV come from `lungfish-cli genotype export`) | Sources/LungfishGenotypeUI/GenotypeViewportExportCoordinator.swift. The controller creates one through its `viewportExportCoordinator` property and keeps `presentExcelExportPanel` and `captureExcelExportSnapshot` as forwarders. The manual haplotype definitions export (`exportManualDefinitions` and `writeManualDefinitionsExport`) stays in the controller until Phase 4a moves the manual haplotyping slice |
| Comparison matrix | Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift |
| Annotation sidecar store | Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift, backed by Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift |
| Export snapshot and service | Sources/LungfishGenotypeUI/GenotypeViewportExportSnapshot.swift, GenotypeViewportExportService.swift |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+Genotype.swift installs the controller. Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift wires `onExcelExportRequested` and `onExcelExportEvent` |

## Contracts this module owns

- Workbook and matrix exports stay byte-identical across any move or refactor. Call status, ambiguity tokens and per-locus denominators are scientific output (REVIEW.md R6).
- Review eligibility and matrix projection already have IO types (GenotypeMatrixReviewEligibility.swift and GenotypeMatrixBaseProjection.swift in Sources/LungfishIO/Bundles). New logic of that kind goes there, not into the view controller, where export logic has caused repeated parity fixes (REVIEW.md R6).
- New export logic belongs in `GenotypeViewportExportCoordinator`, not in the view controller. The coordinator reads controller state only through the forwarder block at the end of its file, so a new controller dependency is one new forwarder line there, and the test seams `excelSavePanelPresenter`, `viewportExportRunner` and `onExcelExportEvent` stay on the controller, where the coordinator reads them at call time (REVIEW.md R6).
- User annotations live in the bundle's annotations.json sidecar, peer to genotype-result.json.
- Opening a `GenotypeAnnotationStore` writes nothing. A haplotyped bundle shows the four built-in smart cohorts (`builtInSmartCohorts`) from memory, `lastPersistedSidecar` stays equal to the file, and the first edit that publishes the whole sidecar through `persist` writes the cohorts with itself. A replayed edit (`mutateCallOverrides`, the matrix review and comment mutations and `replaceManualHaplotypeAssignments`) publishes exactly its replayed result, so the cohorts stay in memory after it. A call override or a manual haplotype replacement on a bundle with no sidecar publishes the viewed sidecar first through `preparePriorSidecarForReplay`, because its replay starts from the bytes of the file, so its record names that sidecar, written just before, as the prior. A genotype-only result has no sidecar until its first edit. A store for a bundle on screen passes `seedBuiltInSmartCohorts: hasHaplotypingResult` and no initializer may write. The Excel capture holds the viewed sidecar under the name `annotations.json`, and the export record says how it stands against the file. Undoing that first edit removes only the edit, so the cohorts stay in the file and its earlier bytes do not come back, and a built-in cohort the analyst deleted returns on the next open until 2.6 records deletions.

## Tests

Target LungfishGenotypeUITests in Tests/LungfishGenotypeUITests. Run only it with `swift test --skip-update --filter LungfishGenotypeUITests`. About 23 genotype test files still sit in Tests/LungfishAppTests and belong here (R11). Several genotype suites are in PARALLEL_HAZARD_SUITES (scripts/full-suite-gate.sh line 151).

## Known traps

| Trap | Evidence |
|---|---|
| The two largest files in the repo, about 120K tokens for the first | GenotypeResultViewController.swift is 11,352 lines, GenotypeComparisonMatrixView.swift is 9,351 (R6) |
| Hundreds of testing-only identifiers and 54 `#if DEBUG` blocks inside production views | REVIEW.md R6 |
| A test that leaves a manual-haplotype draft unsaved while the controller sits in a window reaches the real save alert, which hangs the suite unless the test installs a decision provider or an alert presenter double. The export path reaches the same alert through `deferManualHaplotypeTransition` | `testingSetManualHaplotypeDraftDecisionProvider` and `manualHaplotypeDraftAlertPresenter`, GenotypeResultViewController.swift (R10) |
| A notebook-compatible MHC-A rule is hard-coded in the analyzer | Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalyzer.swift lines 709 to 722 (R18) |
| The export coordinator reads the controller through an unowned reference. The four `[weak self]` captures on its export path, the refused-export handler among them, must stay weak, and no callback the path calls (`originStillCurrent`, `settleDisplayState`, `onExcelExportEvent`, `excelSavePanelPresenter`) may release the controller synchronously | The comment at `host` in GenotypeViewportExportCoordinator.swift, and `GenotypeViewportExportCoordinatorLifetimeTests` |

The App has 72 files that mention Genotype (R1). Extraction by responsibility is Phase 4 work, behind byte-identical export fixtures.

## Responsibility anchors for Phase 4a

Lane L6 of Phase 2.3 mapped the three responsibilities that leave the controller and the matrix view next, and pinned each one in Tests/Fixtures/golden/genotype-gui. These are names, not line numbers. Search for them.

- Matrix projection, pinned by `matrix-projection.json`.
  - Matrix view. `configure`, `applyDisplayState`, `applyAnnotationSidecar`, `applySharedSearchConstraints`, `rebuildBaseProjection`, `applyDerivedProjection`, `rebuildSupportLookup`, `applyFilterAndSort`, `activeSampleNames`, `samplesInPreferredColumnOrder`, `rebuildColumns`, `cellValue`, `displaySummary`, `exportSnapshot` and its export helpers.
  - Matrix view state. `baseProjection`, `allRows`, `visibleRows`, `supportByRowAndSample`, `supportFractionByCell`, `displayState`, `visibilityState`.
  - Controller. `applyComparisonMatrixCohortFilter`, `ensureComparisonMatrixConfigured`, `comparisonMatrixPresentationResult`, `normalizedDisplayState`, `applyDisplayState`, `projectedSearchRows`.
- Review eligibility, pinned by `review-eligibility.json` and `review-eligibility-read-only.json`. The rules already live in LungfishIO as `GenotypeMatrixReviewEligibility`.
  - Matrix view. `reviewRawSupport`, `sidecarCellReviews`, `applyMatrixReviewCapability`, `reviewDisposition`, `semanticCellState`, `contextMenu`, `performMatrixContextMenuCommand`, `validateMenuItem`, `updateReviewLegend` and the `GenotypeMatrixReviewMenuActions` conformance.
  - Controller. `matrixEvidenceIndex`, `matrixReviewCapability`, `rebuildMatrixEvidenceIndex`, `rebuildMatrixAnnotationIndexes`, `publishMatrixReviewCapability`, both `applyMatrixReview`, both `editMatrixComment`, `applicableCommentTargets`.
- Haplotype-band disclosure, pinned by `haplotype-band.effective.json` and `haplotype-band.manual.json`.
  - Matrix view. `haplotypeBandMode`, `effectiveHaplotypeBandSnapshot`, `manualHaplotypeBandSnapshot`, `setHaplotypeBand`, `updateManualHaplotypeBand`, `activeHaplotypeBandLoci`, `activeHaplotypeBandValues`, `applyManualHaplotypeBandPresentation`, `setManualHaplotypeBandExpandedPreservingViewport` and the `haplotypeLocusScope` of `exportSnapshot`.
  - Controller. `manualHaplotypeBandDisclosureStore`, `effectiveHaplotypeProjection`, `rebuildEffectiveHaplotypeProjectionIfNeeded`, `applyComparisonMatrixHaplotypeBandProjection`, `orderedLoci`, `effectiveIncludedLoci`, `defaultIncludedLoci`, `selectHaplotypeBandTarget` and the display state's `manualHaplotypeBandExpanded`, `includedLoci` and `showsAncillaryLoci`.
- The export is the fourth responsibility and already has its type, `GenotypeViewportExportCoordinator`, pinned by the `*.excel-capture.json` files.
