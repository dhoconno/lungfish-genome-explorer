# LungfishApp

Line numbers were checked at commit a0eec8b32, and the family sizes and the Kraken2 path again in Phase 1 lane 1a.3. When a line has moved, search for the named symbol.

## Purpose

The composition root of the macOS app. It wires windows, menus, the sidebar, the viewer, the Inspector and the operation launches to the leaf modules and to LungfishWorkflow. It holds about 551 files. New feature logic belongs in a leaf module or in LungfishWorkflow, never here. Add only the registration glue that wires a leaf in (see docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md for the touch-point list).

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishKit and the nine leaf UI modules, plus AppKit and SwiftUI. Never Sparkle (that stays in the Lungfish executable) and never LungfishCLI. Leaves and LungfishKit must never import this module (memory file project_module_architecture.md).

## The six composition-root families

| Family | Main file | Size |
|---|---|---|
| AppDelegate | Sources/LungfishApp/App/AppDelegate.swift and 17 `AppDelegate+*.swift` extensions | 14,631 lines |
| MainSplitViewController | Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift and 11 extensions | 8,656 lines |
| ViewerViewController | Sources/LungfishApp/Views/Viewer/ViewerViewController.swift and 25 extensions | 11,995 lines |
| MainWindowController | Sources/LungfishApp/Views/MainWindow/MainWindowController.swift | 1,149 lines |
| InspectorViewController | Sources/LungfishApp/Views/Inspector/InspectorViewController.swift and 10 extensions | 5,388 lines |
| SidebarViewController | Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift, SidebarItem.swift, SidebarProjectScanner.swift | 5,614 lines in the controller family |

Each leaf is wired by one `ViewerViewController+<Feature>.swift` file in Views/Viewer that connects the leaf's callbacks to app services.

## Where a Kraken2 run starts in the GUI

1. The Tools menu item calls `launchFASTQOperationToolFromMenu` (App/AppDelegate+ToolsMenu.swift line 85) and the sidebar Run button calls `launchKraken2Classification` (App/AppDelegate+Classification.swift line 188). Both open the FASTQ operations dialog with tool `.kraken2` through `showFASTQOperationsDialog` (AppDelegate+ToolsMenu.swift line 107).
2. On submit the dialog hands `pendingClassificationConfigs` to `runClassification(configs:...)` in the same ToolsMenu file.
3. `runClassification(config:...)` (AppDelegate+Classification.swift line 646) creates the `kraken2` analysis folder and registers the operation through `beginClassificationOperation` (AppDelegate+ClassificationOperationBegin.swift), which calls `begin` with the command from `ClassificationCLIInvocationBuilder` and runs its launch closure only when the row started. The closure materializes virtual inputs through `resolveInputFiles` (line 633), then runs `ClassificationPipeline` in process.
4. Batches go through `runClassificationBatch` (line 1285). EsViritu and TaxTriage follow the same file (`runEsViritu`, `runTaxTriage`).

The pipeline side is in Sources/LungfishWorkflow/AGENTS.md and the CLI side in Sources/LungfishCLI/AGENTS.md.

## Operation launch pattern for new code

A standalone operation calls `OperationCenter.shared.begin` with operationType and cliCommand, then runs `lungfish-cli` through `CLISubprocessTransport` and maps events with `OperationCenterCLIBridge` (Services/OperationCenterCLIBridge.swift line 20). The reference pair is Views/Inspector/InspectorViewController+MSAPairwiseIdentity.swift line 41 and Services/CLIMSAActionRunner.swift.

A read tool joins the FASTQ operation dialog family instead. Its Tools menu item is generated from `FASTQOperationToolID` (Views/FASTQ/FASTQOperationDialogState.swift line 1970) and `toolIDs(for:)`, and it runs through Services/FASTQOperationPlanner.swift, FASTQOperationCLIInvocationBuilder.swift, FASTQOperationExecutionService.swift and FASTQOperationOutputImporter.swift. Dialogs live under Views/<Area>/, such as Views/Mapping/MappingWizardSheet.swift. docs/contracts/ADDING-AN-OPERATION.md has the full list.

## Tests

Targets LungfishAppTests (589 files), LungfishAppViewTests and LungfishAppWorkflowTests. A whole-target filter is a selection large enough to hit ARG_MAX when run serially, so iterate per suite with `swift test --skip-update --filter LungfishAppTests.<SuiteName>` (memory file reference_swiftpm_tooling_gotchas.md).

## Known traps

| Trap | Evidence |
|---|---|
| SidebarItemType has 71 cases and routing is a chain of type checks | Views/Sidebar/SidebarItem.swift line 40, Views/MainWindow/MainSplitViewController+ContentDisplay.swift lines 16 to 222 (R1) |
| 13 optional child viewports and hand-written hide lists that drift | Views/Viewer/ViewerViewController.swift lines 207 to 253, ViewerViewController+TwelveS.swift lines 8 to 32 omit `hidePrimerAnalysisView` (R1) |
| Inspector tab chosen by folder-name prefix | App/AppDelegate.swift lines 301 to 305 (R1) |
| A new analysis tool needs `AnalysesFolder.knownTools`, `displayName`, `SidebarProjectScanner.analysisIcon` and `analysisItemType` plus a route case, or its node never opens | Views/Sidebar/SidebarProjectScanner.swift lines 914 and 939, Views/MainWindow/AnalysisResultDisplayRoute.swift line 4 (memory file project_viral_recon_results_integration.md) |
| EsViritu GUI and CLI write different result trees | App/AppDelegate+Classification.swift lines 911 to 1159 against Sources/LungfishCLI/Commands/EsVirituCommand.swift (R3) |
| View controllers run tools in process | Views/Viewer/FASTQDatasetViewController.swift lines 1378, 1535 and 1643 (R3) |
| FASTQ-family and Workflow Operations runners start their own `Process` instead of using `CLISubprocessTransport`. Do not copy this into a new runner | `LungfishCLIProcessRunner` in Services/FASTQOperationExecutionService.swift line 800, `ProcessViralReconWorkflowProcessRunner` in Services/ViralReconWorkflowExecutionService.swift line 772 (R7, Phase 2) |
| A test that routes a file to Quick Look starts real Quick Look in the test process unless it installs a preview renderer double | `embeddedFilePreviewRenderer` in Views/Viewer/ViewerViewController.swift and `RecordingFilePreviewRenderer` in Tests/LungfishAppTests (R10) |

Every viewport switch clears transient state through `clearTransientViewportState` (Views/MainWindow/MainSplitViewController.swift line 526, memory file known-issues.md).
