# LungfishPhylogeneticsUI

Line numbers were checked at commit 58370dd8e (IQ-TREE session). When a line has moved, search for the named symbol.

## Purpose

Leaf UI module for phylogenetic tree bundles. It draws the tree canvas, the node table and the selection state. Tree inference (IQ-TREE) and its dialog cluster stay in LungfishApp, and tree parsing lives in Sources/LungfishIO/Bundles/PhylogeneticTreeParsing.swift (memory file project_module_architecture.md).

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit, AppKit and SwiftUI. Never LungfishApp or another leaf module.

## Entry points

| Type | Path |
|---|---|
| `PhylogeneticTreeViewController` and `displayBundle(at:)` | Sources/LungfishPhylogeneticsUI/PhylogeneticTreeViewController.swift lines 66 and 151 |
| Canvas color and layout modes | PhylogeneticTreeViewController.swift lines 1604 and 1610 |
| The tree canvas, `PhylogeneticTreeCanvasView`, and its node AX elements, `PhylogeneticTreeNodeAccessibilityElement` (press selects the node, node commands as custom actions) | Sources/LungfishPhylogeneticsUI/PhylogeneticTreeCanvasView.swift lines 24 and 15 |
| Support presentation, `PhylogeneticTreeSupportPresentation` (one column per recorded support label, the raw pair text such as 99/100, Support Type, strength thresholds UFBoot 95, SH-aLRT 80 and aBayes 0.95, the legend text and `rootingText(isRooted:)`) | Sources/LungfishPhylogeneticsUI/PhylogeneticTreeSupportPresentation.swift line 13 |
| Node table support columns, `configureSupportPresentation()` | Sources/LungfishPhylogeneticsUI/PhylogeneticTreeViewController+SupportColumns.swift line 35 |
| Selection > Tree Node twins, `nodeMenuBarSections`, and the focus rule in `validateMenuItem(_:)` | PhylogeneticTreeViewController.swift lines 915 and 940. The menu is built by `makeTreeNodeMenuItem()` in Sources/LungfishApp/App/MainMenu+TreeNode.swift |
| `PhylogeneticTreeSelectionState` | Sources/LungfishPhylogeneticsUI/PhylogeneticTreeSelectionState.swift line 7 |
| Bundle format | Sources/LungfishIO/Bundles/PhylogeneticTreeBundle.swift |
| App glue | Sources/LungfishApp/Views/Viewer/ViewerViewController+AlignmentTreeBundles.swift |

## Contracts this module owns

- The controller reaches app services only through `onSelectionStateChanged` and `onTreeBundleOperationRequested` (lines 72 and 73), wired by the App glue file.
- The node context menu, the Selection > Tree Node menu-bar items and the canvas node AX custom actions all come from the same `NodeAction` list, so a new node command is added once and appears in all three. Menu-bar items are enabled only while the node table or the canvas has keyboard focus and a node is selected.
- Support text and colour read `manifest.supportLabels`. A bundle without labels keeps the single Support column and the old 0 to 1 gradient, and an integer 0 or 1 is never called a posterior when labels are recorded.

## Tests

Target LungfishPhylogeneticsUITests in Tests/LungfishPhylogeneticsUITests. Run only it with `swift test --skip-update --filter LungfishPhylogeneticsUITests`.

## Known traps

| Trap | Evidence |
|---|---|
| `PhylogeneticTreeCanvasView` fills its whole `dirtyRect`, and no view in this module sets `clipsToBounds = true`. On macOS 14 and later that can paint over siblings drawn earlier | PhylogeneticTreeCanvasView.swift line 226 (memory file project_msa_clipstobounds_overpaint.md) |
| The canvas accepts first responder and takes focus on a click, so a click on the canvas changes which view the menu-bar validation sees | PhylogeneticTreeCanvasView.swift line 239 (`acceptsFirstResponder`) |
| Phylogenetic trees are one of the four viewports in the hand-written native-bundle check | Sources/LungfishApp/Views/Viewer/ViewerViewController.swift lines 248 to 253 (R1) |
