# LungfishRNASeqUI

When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for RNA-seq results, the `.lungfishrnaseq` folder that `lungfish-cli import rnaseq` writes. It shows what the result's manifest says and hosts the bulk or the single-cell view by modality. It computes no number. The domain code (writer, quantifier, quality) is the folder `Sources/LungfishWorkflow/RNASeq/`, which is not a target, and the reader is `RNASeqResultBundle` in LungfishIO.

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit, QuartzCore (the embedding plot's layer) and SwiftUI. Never LungfishApp or another leaf module.

## Entry points

| Type | Path |
|---|---|
| `RNASeqResultSurface`, its factory, `RNASeqResultFacts` and `RNASeqResultViewController` | Sources/LungfishRNASeqUI/RNASeqResultSurface.swift |
| The bulk view: its controller, its model (`RNASeqBulkModel`) and the correlation plot | Sources/LungfishRNASeqUI/Bulk/RNASeqBulkViewController.swift, Sources/LungfishRNASeqUI/Bulk/RNASeqBulkModel.swift, Sources/LungfishRNASeqUI/Bulk/RNASeqCorrelationPlotView.swift |
| The single-cell view: its controller, the summary and the pages (`RNASeqSingleCellSummary`), the charts and the cells table | Sources/LungfishRNASeqUI/SingleCell/RNASeqSingleCellViewController.swift, Sources/LungfishRNASeqUI/SingleCell/RNASeqSingleCellSummary.swift, Sources/LungfishRNASeqUI/SingleCell/RNASeqSingleCellCharts.swift, Sources/LungfishRNASeqUI/SingleCell/RNASeqSingleCellCellsTable.swift, and the reads of `cells.sqlite` in Sources/LungfishIO/Bundles/RNASeqCellsDatabase+Bins.swift |
| The cell-map view: its controller, its model and reads (`RNASeqCellMapLoader`), the CPU raster with its hit-test grid, the plot, the legend, the words, the gene picker (it reads the cell map's `features` and colours by one gene through the same colour helper as the count colourings) and the point size control (LungfishKit's shared slider in a hosting view) | Sources/LungfishRNASeqUI/CellMap/RNASeqCellMapViewController.swift, Sources/LungfishRNASeqUI/CellMap/RNASeqCellMapModel.swift, Sources/LungfishRNASeqUI/CellMap/RNASeqEmbeddingRaster.swift, Sources/LungfishRNASeqUI/CellMap/RNASeqEmbeddingPlotView.swift, Sources/LungfishRNASeqUI/CellMap/RNASeqEmbeddingLegend.swift, Sources/LungfishRNASeqUI/CellMap/RNASeqEmbeddingWords.swift, Sources/LungfishRNASeqUI/CellMap/RNASeqEmbeddingGenePicker.swift, Sources/LungfishRNASeqUI/CellMap/RNASeqCellMapPointSize.swift, the selection (lasso, legend and keyboard, its words, its request to the App) in Sources/LungfishRNASeqUI/CellMap/RNASeqEmbeddingSelection.swift, and the reads of `cellmap.sqlite` in Sources/LungfishIO/Bundles/RNASeqCellMapDatabase+Read.swift |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+RNASeq.swift, the registration line in ViewerViewController+Surfaces.swift, `updateRNASeqResultDocument` and `updateRNASeqCellMapFacts` in Sources/LungfishApp/Views/Inspector/InspectorViewController+RNASeq.swift, and the Bundle tab's block (`RNASeqResultDocumentState`) in Sources/LungfishApp/Views/Inspector/Sections/DocumentSection+RNASeq.swift |

## Contracts this module owns

- The surface reads the folder with `RNASeqResultBundle.load(from:)` off the main actor and writes nothing. A newer schema or an unreadable manifest shows the words of `RNASeqResultError` (`docs/formats/rnaseq-bundle.md`) in the view and never throws into the route's "Unable to open" line.
- Nothing in the module offers a file of the result for edit, rename or move, and no number on screen is computed here. A view shows what the CLI wrote.
  - The count of selected cells and the highlight of a cell map's view come from LungfishIO's one membership function, `RNASeqCellMapSelection`, on the Float32 points of `coordinates(embedding:)`, the function `lungfish-cli rnaseq cell-map select` runs (5.5 S2). The view simplifies a lasso to at most `RNASeqCellMapSelection.maximumVertices` vertices by one fixed rule (`RNASeqEmbeddingLasso`) before it draws the highlight and hands the polygon on. Selecting writes nothing (5.5 S1).
- The module talks to the app only through four closures of `RNASeqResultSurface`: `onLoaded`, `onCellMapFacts`, `onWillDeactivate` and `onSelectionAction`. The App glue file wires all four. `onLoaded` and `onCellMapFacts` give the Inspector's Bundle tab the result's facts and a cell map's fact lines, and `onWillDeactivate` takes them out when the view goes. `onSelectionAction` hands over Save Selection as Labels Table… and Pseudobulk Selected Cells… with the selection as one `cell-map select` form, and the App launches that leaf (Sources/LungfishApp/Services/RNASeqCellMapSelectRun.swift), so the module writes no table.

## Tests

Target LungfishRNASeqUITests in Tests/LungfishRNASeqUITests. Run only it with `swift test --skip-update --filter LungfishRNASeqUITests`.

## Known traps

| Trap | Evidence |
|---|---|
| The registered-bundle route does not set the viewer's content mode, so the App glue sets `.genomics` in `onLoaded`, which gives the Inspector its Provenance tab | `wireRNASeqResult` in Sources/LungfishApp/Views/Viewer/ViewerViewController+RNASeq.swift |
| A FASTQ dataset or a classifier result sets no Inspector document of its own, so the RNA-seq rows would stay over it. The surface's `willDeactivate` runs `onWillDeactivate` with the shown folder, and the App clears only that result's rows | `clearRNASeqResultDocument(ifShowing:)` in Sources/LungfishApp/Views/Inspector/Sections/DocumentSection+RNASeq.swift |
