# LungfishPhylogeneticsUI

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for phylogenetic tree bundles. It draws the tree canvas, the node table and the selection state. Tree inference (IQ-TREE) and its dialog cluster stay in LungfishApp, and tree parsing lives in Sources/LungfishIO/Bundles/PhylogeneticTreeParsing.swift (memory file project_module_architecture.md).

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit and SwiftUI. Never LungfishApp or another leaf module.

## Entry points

| Type | Path |
|---|---|
| `PhylogeneticTreeViewController` and `displayBundle(at:)` | Sources/LungfishPhylogeneticsUI/PhylogeneticTreeViewController.swift lines 66 and 150 |
| Canvas color and layout modes | PhylogeneticTreeViewController.swift lines 1542 and 1548 |
| `PhylogeneticTreeSelectionState` | Sources/LungfishPhylogeneticsUI/PhylogeneticTreeSelectionState.swift line 7 |
| Bundle format | Sources/LungfishIO/Bundles/PhylogeneticTreeBundle.swift |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+AlignmentTreeBundles.swift |

## Contracts this module owns

- The controller reaches app services only through `onSelectionStateChanged` and `onTreeBundleOperationRequested` (lines 72 and 73), wired by the App glue file.

## Tests

Target LungfishPhylogeneticsUITests in Tests/LungfishPhylogeneticsUITests. Run only it with `swift test --skip-update --filter LungfishPhylogeneticsUITests`.

## Known traps

| Trap | Evidence |
|---|---|
| `PhylogeneticTreeCanvasView` fills its whole `dirtyRect`, and no view in this module sets `clipsToBounds = true`. On macOS 14 and later that can paint over siblings drawn earlier | PhylogeneticTreeViewController.swift line 1732 (memory file project_msa_clipstobounds_overpaint.md) |
| Phylogenetic trees are one of the four viewports in the hand-written native-bundle check | Sources/LungfishApp/Views/Viewer/ViewerViewController.swift lines 248 to 253 (R1) |
