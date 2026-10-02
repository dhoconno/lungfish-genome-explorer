# LungfishNaoMgsUI

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for NAO-MGS metagenomic surveillance results. It shows per-accession hits, charts, provenance, BLAST verification and read extraction. Result parsing and the SQLite index live in Sources/LungfishIO/Formats/NaoMgs, and import runs through Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift.

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit and SwiftUI. Never LungfishApp or another leaf module (memory file project_module_architecture.md).

## Entry points

| Type | Path |
|---|---|
| `NaoMgsResultViewController` | Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift line 49 |
| `configure(database:manifest:bundleURL:)` and `configure(result:bundleURL:)` | NaoMgsResultViewController.swift lines 445 and 491 |
| Row conversion | `NaoMgsDataConverter`, Sources/LungfishNaoMgsUI/NaoMgsDataConverter.swift line 57 |
| Shared configure and TSV export helpers | Sources/LungfishNaoMgsUI/NaoMgsResultViewController+ResultViewport.swift |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+NaoMgs.swift |

## Contracts this module owns

- The controller reaches app services only through its `on...` callbacks, wired by the App glue file.
- External links go through `onOpenURLRequested` when set (NaoMgsResultViewController.swift lines 2264, 2523 and 2538). Tests must set it, or a real browser opens at an NCBI page (memory file project_test_suite_review.md).
- Read extraction selectors decide which reads are exported. Keep per-classifier tests that diff read IDs (REVIEW.md R14).

## Tests

Target LungfishNaoMgsUITests in Tests/LungfishNaoMgsUITests. Run only it with `swift test --skip-update --filter LungfishNaoMgsUITests`.

## Known traps

| Trap | Evidence |
|---|---|
| NaoMgsResultViewControllerSmokeTests once opened the real default browser through `NSWorkspace.shared.open` | memory file project_test_suite_review.md |
| Private copies of the extraction dialog and BLAST display | `presentUnifiedExtractionDialog` at NaoMgsResultViewController.swift line 1953, `showBlastResults` at line 2055 (R14) |
| Never retype the BLAST database name. Use `BlastDatabaseID.coreNT.rawValue` from LungfishCore | NaoMgsResultViewController.swift (R2) |
| Inspector routing picks the tab from the `naomgs-` folder prefix | Sources/LungfishApp/App/AppDelegate.swift lines 301 to 305 (R1) |
