# LungfishAlignmentUI

Line numbers were checked at commit a0eec8b32.

## Purpose

Alignment-derived views: the BAM summary viewport and the MSA pairwise distance matrix pane. Pileup and coverage drawing live in the genome browser code in Sources/LungfishApp/Views/Viewer, not here (REVIEW.md R13). The MSA viewport itself stays in LungfishApp. It hosts the distance pane and wires its callbacks.

## Allowed imports

LungfishWorkflow, LungfishKit, LungfishCore, LungfishIO and AppKit, as declared in Package.swift. Never LungfishApp or another leaf module.

## Entry points

| Type | Path |
|---|---|
| `AlignmentResultViewController` and `configure(result:)` | Sources/LungfishAlignmentUI/AlignmentResultViewController.swift lines 68 and 257 |
| Result type it renders | `Minimap2Result`, from Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift |
| `MSADistanceMatrixPaneView`, the Distances pane: `init(pasteboard:model:)`, `load(bundleURL:alphabet:)`, `reflectAlignmentSelection(_:)`, `maxRowsForInlineMatrix`, callbacks `onSequencesSelected`, `onRevealPair`, `onExportRequested`, `onFocusedPairChanged` | Sources/LungfishAlignmentUI/MSADistanceMatrix/MSADistanceMatrixPaneView.swift |
| `MSADistanceMatrixPaneModel`, options persisted under `msaDistanceMatrix.*`, off-main compute with a generation counter | Sources/LungfishAlignmentUI/MSADistanceMatrix/MSADistanceMatrixPaneModel.swift |
| `MSADistanceMatrixGridView`, the custom-drawn grid. Responder actions `copy(_:)`, `selectAll(_:)`, `revealPairInAlignment(_:)`, `copyMatrix(_:)`, `exportDistanceMatrix(_:)` validate menu items with a nil target | Sources/LungfishAlignmentUI/MSADistanceMatrix/MSADistanceMatrixGridView.swift, AX table in MSADistanceMatrixGridView+Accessibility.swift |
| Pure pieces: `MSADistanceMatrixSelection`, `MSADistanceColorScale`, `MSADistanceMatrixClipboard`, `MSADistanceMatrixText` | Sources/LungfishAlignmentUI/MSADistanceMatrix/ |

## Contracts this module owns

- Shows a summary of a sorted, indexed BAM. It never writes alignments.
- The distance pane computes only through `MSADistanceMatrix` in LungfishIO, the code `lungfish-cli msa distance` runs. Copy Matrix writes the same bytes as the CLI for the same options. Export is a callback, so the App runs the CLI and records it in OperationCenter.
- Matrix rows map to alignment rows by input record index (`recordIndices`), never by name.
- Every context-menu command on a cell is also an AX custom action and a responder action an App menu item can reach. Selection is shown by outlines and bold headers, never by colour alone. Cell text keeps at least 4.5:1 contrast on every ramp fill in light and dark mode.

## Tests

Target LungfishAlignmentUITests in Tests/LungfishAlignmentUITests. Run only it with `swift test --skip-update --filter LungfishAlignmentUITests`. The distance pane suites all start with `MSADistance`: selection algebra, colour ramp contrast, copy TSV shapes and AX strings, grid AX table and drawing, and pane model and view (stale results dropped, options persisted, Copy Matrix equals the matrix TSV).

## Known traps

| Trap | Evidence |
|---|---|
| No file in Sources/LungfishApp imports this module at a0eec8b32, so the viewport is not reachable from the app today | grep for `import LungfishAlignmentUI` finds only tests. The review plans to fold or fill it (R13) |
| `Minimap2Pipeline` survives as this view's result type although the live mapping path is `ManagedMappingPipeline` | Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift (R15). Phase 0 keeps both untouched |
| Splice-aware views for RNA-seq would land in the App renderer, which has no plug-in seam | Sources/LungfishApp/Views/Viewer/ReadTrackRenderer.swift lines 312 to 328 handle CIGAR N and D (R13) |
| AppKit declares the `NSAccessibilityElement` getters outside the main actor, so a `@MainActor` element subclass fails to compile when it returns main-actor values | The distance grid's virtual elements are nonisolated and read the grid through `axOnMain` in MSADistanceMatrixGridView+Accessibility.swift |
