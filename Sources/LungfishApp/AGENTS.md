# LungfishApp

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

The composition root of the macOS app. It wires windows, menus, the sidebar, the viewer, the Inspector and the operation launches to the leaf modules and to LungfishWorkflow. It holds about 533 files. New feature logic belongs in a leaf module or in LungfishWorkflow, never here. Add only the registration glue that wires a leaf in (see docs/plans/2026-10-02-architecture-program.md, Lane D, for the touch-point list).

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit and the nine leaf UI modules, plus AppKit and SwiftUI. Never Sparkle (that stays in the Lungfish executable) and never LungfishCLI. Leaves and LungfishKit must never import this module (memory file project_module_architecture.md).

## The six composition-root families

| Family | Main file | Size |
|---|---|---|
| AppDelegate | Sources/LungfishApp/App/AppDelegate.swift and 11 `AppDelegate+*.swift` extensions | 13,967 lines |
| MainSplitViewController | Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift and 10 extensions | 8,484 lines |
| ViewerViewController | Sources/LungfishApp/Views/Viewer/ViewerViewController.swift and 21 extensions | 11,409 lines |
| MainWindowController | Sources/LungfishApp/Views/MainWindow/MainWindowController.swift | 1,149 lines |
| InspectorViewController | Sources/LungfishApp/Views/Inspector/InspectorViewController.swift and 9 extensions | 5,150 lines |
| SidebarViewController | Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift, SidebarItem.swift, SidebarProjectScanner.swift | 5,614 lines in the controller family |

Each leaf is wired by one `ViewerViewController+<Feature>.swift` file in Views/Viewer that connects the leaf's callbacks to app services.

## Where a Kraken2 run starts in the GUI

1. The Tools menu item calls `launchFASTQOperationToolFromMenu` (App/AppDelegate+ToolsMenu.swift line 85) and the sidebar Run button calls `launchKraken2Classification` (App/AppDelegate+Classification.swift line 188). Both open the FASTQ operations dialog with tool `.kraken2` through `showFASTQOperationsDialog` (AppDelegate+ToolsMenu.swift line 107).
2. On submit the dialog hands `pendingClassificationConfigs` to `runClassification(configs:...)` in the same ToolsMenu file.
3. `runClassification(config:...)` (AppDelegate+Classification.swift line 800) creates the `kraken2` analysis folder, registers the operation with `OperationCenter.shared.start` and the command from `ClassificationCLIInvocationBuilder`, materializes virtual inputs through `resolveInputFiles` (line 762), then runs `ClassificationPipeline` in process.
4. Batches go through `runClassificationBatch` (line 1331). EsViritu and TaxTriage follow the same file (`runEsViritu`, `runTaxTriage`).

The pipeline side is in Sources/LungfishWorkflow/AGENTS.md and the CLI side in Sources/LungfishCLI/AGENTS.md.

## Operation launch pattern for new code

Call `OperationCenter.shared.begin` with operationType and cliCommand, then run `lungfish-cli` through `CLISubprocessTransport` and map events with `OperationCenterCLIBridge` (Services/OperationCenterCLIBridge.swift line 20). The reference pair is Views/Inspector/InspectorViewController+MSAPairwiseIdentity.swift line 41 and Services/CLIMSAActionRunner.swift.

## Tests

Targets LungfishAppTests (515 files), LungfishAppViewTests and LungfishAppWorkflowTests. A whole-target filter is a selection large enough to hit ARG_MAX when run serially, so iterate per suite with `swift test --skip-update --filter LungfishAppTests.<SuiteName>` (memory file reference_swiftpm_tooling_gotchas.md).

## Known traps

| Trap | Evidence |
|---|---|
| SidebarItemType has 71 cases and routing is a chain of type checks | Views/Sidebar/SidebarItem.swift line 40, Views/MainWindow/MainSplitViewController+ContentDisplay.swift lines 16 to 222 (R1) |
| 13 optional child viewports and hand-written hide lists that drift | Views/Viewer/ViewerViewController.swift lines 207 to 253, ViewerViewController+TwelveS.swift lines 8 to 32 omit `hidePrimerAnalysisView` (R1) |
| Inspector tab chosen by folder-name prefix | App/AppDelegate.swift lines 301 to 305 (R1) |
| A new analysis tool needs `AnalysesFolder.knownTools`, `displayName`, `SidebarProjectScanner.analysisIcon` and `analysisItemType` plus a route case, or its node never opens | Views/Sidebar/SidebarProjectScanner.swift lines 914 and 939, Views/MainWindow/AnalysisResultDisplayRoute.swift line 4 (memory file project_viral_recon_results_integration.md) |
| EsViritu GUI and CLI write different result trees | App/AppDelegate+Classification.swift lines 1042 to 1290 against Sources/LungfishCLI/Commands/EsVirituCommand.swift (R3) |
| View controllers run tools in process | Views/Viewer/FASTQDatasetViewController.swift lines 1378, 1535 and 1643 (R3) |
| Scoped notifications fail open in seven copied filters | Views/MainWindow/MainSplitViewController.swift line 817 and six others (R9) |
| Test runner code inside production | App/AppDelegate.swift line 2723 (R10) |

Every viewport switch clears transient state through `clearTransientViewportState` (Views/MainWindow/MainSplitViewController.swift line 526, memory file known-issues.md).
