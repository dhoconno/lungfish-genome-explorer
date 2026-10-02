# LungfishGenotypeUI

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for MHC genotype results from ONT and MiSeq amplicon genotyping. It holds the three-lens viewport (Summary, Review, Audit), the comparison matrix, the haplotype tape, manual haplotyping, call overrides, Smart Cohorts and the Excel and matrix exports (memory file project_mhc_genotype_inspector_v2.md). Calls are computed in Sources/LungfishWorkflow/ONTGenotyping and Sources/LungfishIO/Bundles, never here.

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit and SwiftUI. Never LungfishApp or another leaf module (memory file project_module_architecture.md).

## Entry points

| Type | Path |
|---|---|
| `GenotypeResultViewController` and `configure(result:)` | Sources/LungfishGenotypeUI/GenotypeResultViewController.swift lines 138 and 1245 |
| Comparison matrix | Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift |
| Annotation sidecar store | Sources/LungfishGenotypeUI/GenotypeAnnotationStore.swift, backed by Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift |
| Export snapshot and service | Sources/LungfishGenotypeUI/GenotypeViewportExportSnapshot.swift, GenotypeViewportExportService.swift |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+Genotype.swift |

## Contracts this module owns

- Workbook and matrix exports stay byte-identical across any move or refactor. Call status, ambiguity tokens and per-locus denominators are scientific output (REVIEW.md R6).
- Review eligibility and matrix projection already have IO types (GenotypeMatrixReviewEligibility.swift and GenotypeMatrixBaseProjection.swift in Sources/LungfishIO/Bundles). New logic of that kind goes there, not into the view controller, where export logic has caused repeated parity fixes (REVIEW.md R6).
- User annotations live in the bundle's annotations.json sidecar, peer to genotype-result.json.

## Tests

Target LungfishGenotypeUITests in Tests/LungfishGenotypeUITests. Run only it with `swift test --skip-update --filter LungfishGenotypeUITests`. About 23 genotype test files still sit in Tests/LungfishAppTests and belong here (R11). Several genotype suites are in PARALLEL_HAZARD_SUITES (scripts/full-suite-gate.sh line 151).

## Known traps

| Trap | Evidence |
|---|---|
| The two largest files in the repo, about 125K tokens for the first | GenotypeResultViewController.swift is 11,937 lines, GenotypeComparisonMatrixView.swift is 9,386 (R6) |
| Hundreds of testing-only identifiers and 54 `#if DEBUG` blocks inside production views | REVIEW.md R6 |
| A test that leaves a manual-haplotype draft unsaved while the controller sits in a window reaches the real save alert, which hangs the suite unless the test installs a decision provider or an alert presenter double | `testingSetManualHaplotypeDraftDecisionProvider` and `manualHaplotypeDraftAlertPresenter`, GenotypeResultViewController.swift (R10) |
| A notebook-compatible MHC-A rule is hard-coded in the analyzer | Sources/LungfishIO/Bundles/GenotypeHaplotypeAnalyzer.swift lines 709 to 722 (R18) |

The App has 72 files that mention Genotype (R1). Extraction by responsibility is Phase 4 work, behind byte-identical export fixtures.
