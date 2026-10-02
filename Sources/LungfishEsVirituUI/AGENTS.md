# LungfishEsVirituUI

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for EsViritu viral detection results. It shows the viral detection outline, coverage sparklines, segment completeness, the detail pane, batch tables, BLAST verification and read extraction. Detection runs in `EsVirituPipeline` (Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift line 338).

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit and SwiftUI. Never LungfishApp or another leaf module (memory file project_module_architecture.md).

## Entry points

| Type | Path |
|---|---|
| `EsVirituResultViewController` and `configureFromDatabase` | Sources/LungfishEsVirituUI/EsVirituResultViewController.swift lines 179 and 501 |
| Detection table | `ViralDetectionTableView`, Sources/LungfishEsVirituUI/ViralDetectionTableView.swift line 48 |
| Detail pane | `EsVirituDetailPane`, Sources/LungfishEsVirituUI/EsVirituDetailPane.swift line 40 |
| Batch table | Sources/LungfishEsVirituUI/BatchEsVirituTableView.swift |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift |

## Contracts this module owns

- The controller reaches app services only through its `on...` callbacks, wired by the App glue file.
- Results load from the esviritu.sqlite index that the GUI run builds.
- Read extraction selectors decide which reads are exported. Keep per-classifier tests that diff read IDs (REVIEW.md R14).

## Tests

Target LungfishEsVirituUITests in Tests/LungfishEsVirituUITests. Run only it with `swift test --skip-update --filter LungfishEsVirituUITests`. EsVirituViewControllerBatchModeTests in LungfishAppTests is in PARALLEL_HAZARD_SUITES (scripts/full-suite-gate.sh line 151).

## Known traps

| Trap | Evidence |
|---|---|
| The GUI run builds esviritu.sqlite, the batch manifest and provenance, while `lungfish-cli esviritu detect` does not, so a CLI result tree may not open here | Sources/LungfishApp/App/AppDelegate+Classification.swift lines 1042 to 1290 and Sources/LungfishCLI/Commands/EsVirituCommand.swift (R3) |
| A CLI run on a `.lungfishfastq` bundle keeps its materialized reads in `.lungfish-esviritu-inputs` and records the bundle in provenance, while a GUI run materializes into a temporary folder it deletes and records the deleted file | `execute(pipeline:materializer:)` in Sources/LungfishCLI/Commands/EsVirituCommand.swift, `runEsViritu` in Sources/LungfishApp/App/AppDelegate+Classification.swift (R3) |
| Private copies of the extraction dialog and BLAST display | `presentUnifiedExtractionDialog` at EsVirituResultViewController.swift line 1448, `showBlastResults` at line 1592 (R14) |
| The App has 51 files that mention EsViritu, so the leaf did not remove App coupling | REVIEW.md R1 |
