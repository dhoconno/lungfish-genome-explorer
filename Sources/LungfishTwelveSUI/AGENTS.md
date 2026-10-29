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
| Export | Sources/LungfishTwelveSUI/TwelveSAmpliconResultExportService.swift (format and snapshot), Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController+ExportOperationBegin.swift (the Operations row that runs `lungfish-cli fastq 12s-export`) |
| Status line and provenance popover, with the pairs a run left out | Sources/LungfishTwelveSUI/TwelveSReadFateSummary.swift |
| Reads or fragments wording of every count label | Sources/LungfishTwelveSUI/TwelveSCountUnit.swift |
| The result as a `ViewportHost` surface, with the factory the App registers | `TwelveSSurface`, Sources/LungfishTwelveSUI/TwelveSSurface.swift |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+TwelveS.swift, and the registration line in Sources/LungfishApp/Views/Viewer/ViewerViewController+Surfaces.swift |

## Contracts this module owns

- The controller talks to the app only through its `on...` callbacks (`onUnresolvedBlastRequested`, `onOpenURLRequested` and others, lines 315 to 332). The App glue file wires them.
- "Learn More" (NCBI Taxonomy) and "View Photo" (Wikipedia) open the browser immediately, with no confirmation (memory file feedback_external_link_opening.md). Tests must inject `onOpenURLRequested` so no real browser opens (memory file project_test_suite_review.md).
- Reads moved by abundance reassignment stay a visible, separate evidence channel. A donor species zeroed by reassignment must not vanish from the table (memory file project_twelve_s_abundance_reassignment.md, computed in Sources/LungfishWorkflow/TwelveS/TwelveSAbundanceReassigner.swift).
- Counts are fragments, computed in Sources/LungfishWorkflow/TwelveS. `TwelveSReadFateSummary` owns the status line and the provenance popover, and it adds the unmerged pairs a run left out because their mates disagreed, with the reasons in a fixed order, only when there are any. The line is `... | 2 discordant pairs left out (1 pair with different targets, 1 pair with one mate unresolved)`, and the popover gains a Left Out row. Results written before fragment counting read 0 and show neither.
- `TwelveSCountUnit` owns the reads or fragments wording. It is `.fragments` when `read-fate.json` records `pairedFragments` above 0, and it drives the status line, the popover, both tables' count columns and their header help, the Inspector detail and result filters, and the Copy Rows headers. Merged-only and older results keep "reads". The controller sets the unit before `resultIdentity` in `configure(result:)`, because `BatchTableView` keeps the title each column has at its first filter pass for its filter mark, and the Inspector's first display summary passes the unit too. The tables that the export workflow writes keep Exact Reads and Reads.

## Tests

Target LungfishTwelveSUITests in Tests/LungfishTwelveSUITests. Run only it with `swift test --skip-update --filter LungfishTwelveSUITests`.

## Known traps

| Trap | Evidence |
|---|---|
| The hand-written native-bundle check counts any installed host surface, 12S among them, so the parent annotation drawer stays hidden under each | `isNativeBundleViewportInstalled` in Sources/LungfishApp/Views/Viewer/ViewerViewController.swift (R1) |
| BLAST result display is copied in each classifier leaf | `showBlastResults`, TwelveSAmpliconResultViewController.swift line 969 (R14) |
| Abundance reassignment must be decided per sample, never from global totals | memory file project_twelve_s_abundance_reassignment.md |

TwelveS is the first viewport on the Phase 3 `ViewportHost` (task 3a). Its viewer is installed only through `TwelveSSurface`, and `hideTwelveSAmpliconResultView()` is a one-line shim over the host until Phase 3.2 deletes the hide list.
