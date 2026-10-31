# LungfishTaxonomyUI

Line numbers were checked at commit ecf04ab0c. When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for Kraken2 taxonomy results and for imported CZ-ID results. It shows the taxonomy table, the sunburst, the breadcrumb and summary bars, the batch table of Kraken2 batch mode, the Taxa Collections drawer, the BLAST verification pane and the provenance views. The CZ-ID view wraps the same taxonomy view around an imported result.

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit and SwiftUI. Never LungfishApp or another leaf module (memory file project_module_architecture.md).

## Entry points

| Type | Path |
|---|---|
| `TaxonomyViewController`, `configure(result:)` and `configureFromDatabase` | Sources/LungfishTaxonomyUI/TaxonomyViewController.swift lines 94, 418 and 487 |
| Table | `TaxonomyTableView`, Sources/LungfishTaxonomyUI/TaxonomyTableView.swift line 47 |
| Batch table | `BatchClassificationTableView`, Sources/LungfishTaxonomyUI/BatchClassificationTableView.swift line 30 |
| Taxa Collections drawer | `TaxaCollectionsDrawerView`, Sources/LungfishTaxonomyUI/TaxaCollectionsDrawerView.swift line 51 |
| CZ-ID result view | `CzIdResultViewController`, Sources/LungfishTaxonomyUI/CzIdResultViewController.swift line 11 |
| `Kraken2Surface`, the ViewportHost surface the App registers for `.analysis(.kraken2)`, whose drawer is the Collections and BLAST Results drawer | Sources/LungfishTaxonomyUI/Kraken2Surface.swift |
| Sample folder of a Kraken2 sample | `kraken2SampleResultDirectory`, Sources/LungfishTaxonomyUI/Kraken2SampleResultDirectory.swift line 19 |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift and ViewerViewController+CzId.swift |

## Contracts this module owns

- The controller reaches app services only through its `on...` callbacks, wired by the App glue files. `onExtractionRequested` (TaxonomyViewController.swift line 312) hands the Extract Reads request to the App, which shows the dialog with `presentClassifierExtractionDialog(_:)`. `onBlastVerification` and `blastVerificationDirectoryResolver` serve BLAST verification, and `onBatchExtract` serves the Extract button of the Collections drawer.
- `BatchClassificationTableView` keeps the layout key `LungfishApp.BatchClassificationTableView` through `layoutKeyTypeName`, so the saved column layout of the Kraken2 batch table does not reset. Never rename it. MetadataLayoutKeyShapePinTests and BatchClassificationTableLayoutKeyTests pin it.
- Read extraction selectors decide which reads are exported. Keep per-classifier tests that diff read IDs (REVIEW.md R14).

## Tests

No test target of its own. The moved classes run in LungfishAppTests and LungfishAppViewTests through `@testable import LungfishTaxonomyUI`. Run one with `swift test --skip-update --filter TaxonomyViewControllerTests`.

## Known traps

| Trap | Evidence |
|---|---|
| The view controller is over 1,800 lines, too large to read whole | TaxonomyViewController.swift (file-size ratchet) |
| A controller with no `onExtractionRequested` extracts nothing, so a test that opens the dialog from a bare controller wires it the way the App does | TaxonomyViewControllerTests, the two Extract Reads tests |
| The Collections drawer finds a sample's folder with the same helper as the viewer's BLAST callback | Kraken2SampleResultDirectory.swift and ViewerViewController+Taxonomy.swift |
