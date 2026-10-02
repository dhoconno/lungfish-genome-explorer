# LungfishNvdUI

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for NVD (Novel Virus Diagnostics) results. It shows contig hits with BLAST evidence, provenance and read extraction. NVD output parsing and its SQLite index live in Sources/LungfishIO/Formats/Nvd.

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit and SwiftUI. Never LungfishApp or another leaf module (memory file project_module_architecture.md).

## Entry points

| Type | Path |
|---|---|
| `NvdResultViewController` | Sources/LungfishNvdUI/NvdResultViewController.swift line 111 |
| `configure(database:manifest:bundleURL:)` and the cached-rows variant | NvdResultViewController.swift lines 564 and 510 |
| Row conversion | `NvdDataConverter`, Sources/LungfishNvdUI/NvdDataConverter.swift line 9 |
| Provenance panel | Sources/LungfishNvdUI/NvdProvenanceView.swift |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+Nvd.swift |

## Contracts this module owns

- The controller reaches app services only through its `on...` callbacks (eight of them), wired by the App glue file.
- Opening NCBI goes through `onOpenURLRequested` when set (NvdResultViewController.swift line 2181). Tests must set it, or a real browser opens (memory file project_test_suite_review.md).
- Read extraction selectors decide which reads are exported. Keep per-classifier tests that diff read IDs (REVIEW.md R14).

## Tests

Target LungfishNvdUITests in Tests/LungfishNvdUITests. Run only it with `swift test --skip-update --filter LungfishNvdUITests`.

## Known traps

| Trap | Evidence |
|---|---|
| Private copies of the extraction dialog and BLAST display that drift from the other classifiers | `presentUnifiedExtractionDialog` at NvdResultViewController.swift line 1627, `showBlastResults` at line 1858 (R14) |
| The App hides this view in 22 places, more than any other viewport | REVIEW.md R1 (`hideNvdView`) |
| Inspector routing picks the tab from the `nvd-` folder prefix | Sources/LungfishApp/App/AppDelegate.swift lines 301 to 305 (R1) |
