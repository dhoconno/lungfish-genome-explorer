# LungfishTwelveSUI

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for 12S amplicon results (vertebrate species detection from mitochondrial 12S reads). It shows the target and unresolved tables, the per-sample matrix, the detail pane and export. Read classification and abundance reassignment are computed in Sources/LungfishWorkflow/TwelveS, not here.

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit and SwiftUI. Never LungfishApp or another leaf module (memory file project_module_architecture.md).

## Entry points

| Type | Path |
|---|---|
| `TwelveSAmpliconResultViewController` and `configure(result:)` | Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift lines 178 and 482 |
| Display state and filters | Sources/LungfishTwelveSUI/TwelveSResultDisplayState.swift line 45 |
| Row aggregation across samples | Sources/LungfishTwelveSUI/TwelveSRowAggregator.swift |
| Export | Sources/LungfishTwelveSUI/TwelveSAmpliconResultExportService.swift |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+TwelveS.swift |

## Contracts this module owns

- The controller talks to the app only through its `on...` callbacks (`onUnresolvedBlastRequested`, `onOpenURLRequested` and others, lines 315 to 332). The App glue file wires them.
- "Learn More" (NCBI Taxonomy) and "View Photo" (Wikipedia) open the browser immediately, with no confirmation (memory file feedback_external_link_opening.md). Tests must inject `onOpenURLRequested` so no real browser opens (memory file project_test_suite_review.md).
- Reads moved by abundance reassignment stay a visible, separate evidence channel. A donor species zeroed by reassignment must not vanish from the table (memory file project_twelve_s_abundance_reassignment.md, computed in Sources/LungfishWorkflow/TwelveS/TwelveSAbundanceReassigner.swift).

## Tests

Target LungfishTwelveSUITests in Tests/LungfishTwelveSUITests. Run only it with `swift test --skip-update --filter LungfishTwelveSUITests`.

## Known traps

| Trap | Evidence |
|---|---|
| The App glue's hide list has 18 calls and omits `hidePrimerAnalysisView`, so a primer view can stay installed | Sources/LungfishApp/Views/Viewer/ViewerViewController+TwelveS.swift lines 8 to 32 (R1) |
| TwelveS is one of the four viewports in the hand-written native-bundle check | Sources/LungfishApp/Views/Viewer/ViewerViewController.swift lines 248 to 253 (R1) |
| BLAST result display is copied in each classifier leaf | `showBlastResults`, TwelveSAmpliconResultViewController.swift line 969 (R14) |
| Abundance reassignment must be decided per sample, never from global totals | memory file project_twelve_s_abundance_reassignment.md |

TwelveS is the first viewport scheduled to move to the Phase 3 ResultViewport contract (plan Phase 3).
