# LungfishRNASeqUI

When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for RNA-seq results, the `.lungfishrnaseq` folder that `lungfish-cli import rnaseq` writes. It shows what the result's manifest says and hosts the bulk or the single-cell view by modality. It computes no number. The domain code (writer, quantifier, quality) is the folder `Sources/LungfishWorkflow/RNASeq/`, which is not a target, and the reader is `RNASeqResultBundle` in LungfishIO.

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit and SwiftUI. Never LungfishApp or another leaf module.

## Entry points

| Type | Path |
|---|---|
| `RNASeqResultSurface`, its factory, `RNASeqResultFacts` and `RNASeqResultViewController` | Sources/LungfishRNASeqUI/RNASeqResultSurface.swift |
| The bulk view (RS-BULK-VIEW-M2 fills it) | Sources/LungfishRNASeqUI/Bulk/RNASeqBulkViewController.swift |
| The single-cell view (RS-SC-VIEW fills it) | Sources/LungfishRNASeqUI/SingleCell/RNASeqSingleCellViewController.swift |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+RNASeq.swift, the registration line in ViewerViewController+Surfaces.swift, and `updateRNASeqResultDocument` in InspectorViewController+PublicAPI.swift |

## Contracts this module owns

- The surface reads the folder with `RNASeqResultBundle.load(from:)` off the main actor and writes nothing. A newer schema or an unreadable manifest shows the words of `RNASeqResultError` (`docs/formats/rnaseq-bundle.md`) in the view and never throws into the route's "Unable to open" line.
- Nothing in the module offers a file of the result for edit, rename or move, and no number on screen is computed here. A view shows what the CLI wrote.
- The module talks to the app only through `RNASeqResultSurface.onLoaded`. The App glue file wires it.

## Tests

Target LungfishRNASeqUITests in Tests/LungfishRNASeqUITests. Run only it with `swift test --skip-update --filter LungfishRNASeqUITests`.

## Known traps

| Trap | Evidence |
|---|---|
| The registered-bundle route does not set the viewer's content mode, so the App glue sets `.genomics` in `onLoaded`, which gives the Inspector its Provenance tab | `wireRNASeqResult` in Sources/LungfishApp/Views/Viewer/ViewerViewController+RNASeq.swift |
| The Inspector Document tab has no block for this kind. A block there needs `DocumentSection.swift`, which no 5.4 milestone owns | Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift |
