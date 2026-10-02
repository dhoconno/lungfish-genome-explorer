# LungfishTaxTriageUI

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for TaxTriage results (an nf-core metagenomic triage pipeline). It shows the batch overview, per-sample organism tables with confidence, strain comparison, BLAST verification, read extraction and batch export. The pipeline runs in Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift.

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit and SwiftUI. Never LungfishApp or another leaf module (memory file project_module_architecture.md).

## Entry points

| Type | Path |
|---|---|
| `TaxTriageResultViewController` and `configureFromDatabase` | Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift lines 189 and 2928 |
| Batch table | `BatchTaxTriageTableView`, Sources/LungfishTaxTriageUI/BatchTaxTriageTableView.swift line 40 |
| Row commands for menus and accessibility | Sources/LungfishTaxTriageUI/TaxTriageRowCommands.swift |
| Batch export | `TaxTriageBatchExporter`, Sources/LungfishTaxTriageUI/TaxTriageBatchExporter.swift line 19 |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift |

## Contracts this module owns

- The controller reaches app services only through its `on...` callbacks, wired by the App glue file.
- Read extraction selectors decide which reads are exported. Keep per-classifier tests that diff read IDs (REVIEW.md R14).

## Tests

Target LungfishTaxTriageUITests in Tests/LungfishTaxTriageUITests. Run only it with `swift test --skip-update --filter LungfishTaxTriageUITests`.

## Known traps

| Trap | Evidence |
|---|---|
| The view controller is 5,918 lines, too large to read whole | TaxTriageResultViewController.swift (R6) |
| Private copies of the extraction dialog and BLAST display | `presentUnifiedExtractionDialog` at TaxTriageResultViewController.swift line 4045, `showBlastResults` at line 2818 (R14) |
| The pipeline builds its own Nextflow environment with no JAVA_HOME | Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift lines 1500 to 1562 (R7) |
| A "Database build failed" overlay once persisted over another viewport, so every viewport switch clears transient state | Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift line 526 (memory file known-issues.md) |
| Never retype the BLAST database name. Use `BlastDatabaseID.coreNT.rawValue` from LungfishCore | TaxTriageRowCommands.swift and TaxTriageResultViewController.swift (R2) |
