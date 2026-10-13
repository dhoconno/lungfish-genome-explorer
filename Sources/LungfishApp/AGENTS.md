# LungfishApp

Line numbers were checked at commit a0eec8b32, and the family sizes and the Kraken2 path again in Phase 1 lane 1a.3. When a line has moved, search for the named symbol.

## Purpose

The composition root of the macOS app. It wires windows, menus, the sidebar, the viewer, the Inspector and the operation launches to the leaf modules and to LungfishWorkflow. It holds about 590 files. New feature logic belongs in a leaf module or in LungfishWorkflow, never here. Add only the registration glue that wires a leaf in (see docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md for the touch-point list).

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow, LungfishOperations, LungfishKit and the nine leaf UI modules, plus AppKit and SwiftUI. Never Sparkle (that stays in the Lungfish executable) and never LungfishCLI. Leaves and LungfishKit must never import this module (memory file project_module_architecture.md).

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

1. The Tools menu item calls `launchFASTQOperationToolFromMenu` (App/AppDelegate+ToolsMenu.swift line 85) and the sidebar Run button calls `launchKraken2Classification` (App/AppDelegate+Classification.swift line 20). Both open the FASTQ operations dialog with tool `.kraken2` through `showFASTQOperationsDialog` (AppDelegate+ToolsMenu.swift line 107).
2. On submit the dialog hands `pendingClassificationConfigs` to `launchClassification(configs:...)` (App/AppDelegate+ClassifierLaunchRouting.swift), which forwards to `runClassificationThroughCLI` (App/AppDelegate+ClassificationCLIRoute.swift). That function runs `lungfish-cli kraken2 classify --project ... --format json`, with `--batch` for several samples, through `CLIClassifierRunner` over `CLISubprocessTransport`, and shows the command's events in the row. It is the only route. The in-process route and the hidden keys that chose between the two went in Phase 2.9 (E14).
3. A launch with no project open takes no route. `refuseClassifierLaunchWithoutProject` (App/AppDelegate+ClassifierLaunchRouting.swift) shows the `No Project Open` sheet and starts nothing, because the command writes its result into the project's Analyses folder (decision L1). The TaxTriage launch takes the same refusal.
4. EsViritu follows the same path through `launchEsViritu` and `runEsVirituThroughCLI`, which run `lungfish-cli esviritu detect`. The `begin*Operation` helpers of App/AppDelegate+ClassificationOperationBegin.swift, `resolvedKraken2Config` (App/AppDelegate+ClassificationReadSets.swift) and `resolvedEsVirituConfig` have no launch that calls them now, and tests use them as the reference rows the CLI route must match. TaxTriage still runs in process through `runTaxTriage` (AppDelegate+Classification.swift line 57), plans its samples through `resolvedTaxTriageConfig` in App/AppDelegate+ClassificationSamplesheetReadSets.swift, and moves to the CLI route in Phase 2.10 (T1). A TaxTriage run of several samples records no command yet (`cli-parity-gap` marker `taxtriage-multi-sample`).

The pipeline side is in Sources/LungfishWorkflow/AGENTS.md and the CLI side in Sources/LungfishCLI/AGENTS.md.

## Where an IQ-TREE run starts in the GUI

Line numbers in this section were checked at commit 85cf913f6.

1. Tools > Alignment & Phylogenetics > Build Tree with IQ-TREE… is hand-written, not built from `FASTQOperationToolID`, because its input is a `.lungfishmsa`. `makeBuildTreeItem()` in App/MainMenu+TreeNode.swift builds it, and App/ToolsMenuLayout.swift places it as the trailing fixed command of the alignment category (`.category(.alignment, trailing: [.buildTree])`).
2. `showIQTreeInference(_:)` (App/AppDelegate+TreeInference.swift line 55) and the menu validation (App/AppDelegate.swift line 2494) share `resolveTreeInferenceBundleURL` (line 16) and `treeInferenceRequest(in:)` (line 34). The resolver takes the displayed alignment, else exactly one alignment selected in the sidebar, else nil. AppDelegate conforms to `NSMenuItemValidation` (AppDelegate.swift line 32). Before that conformance AppKit never called its `validateMenuItem`, so check it is still there when an AppDelegate menu rule seems dead.
3. The MSA viewport's context menu and its AX custom action call the same request through `treeInferenceRequest()` in Views/Viewer/MultipleSequenceAlignmentViewController+TreeInference.swift.
4. `inferTreeFromMSAViaCLI` (Views/Viewer/ViewerViewController+TreeInference.swift line 11) presents the dialog (Views/Phylogenetics/IQTreeInferenceDialog.swift, state and readiness rules in IQTreeInferenceDialogState.swift). On Build Tree, `runIQTreeInferenceViaCLI` (line 41) builds the argv once with `IQTreeInferenceLaunch.make` (Views/Phylogenetics/IQTreeInferenceOptions.swift), which draws a blank seed before `begin` and always records `--seed` and `--threads`, then runs `lungfish-cli tree infer iqtree` through `CLITreeRunner`. The argv order is `buildIQTreeInferenceArguments` in Services/CLIMSAActionCommandBuilder.swift line 153, which matches the CLI's canonical argv.
5. The dialog's reserved Advanced flags and model and codon rules come from `IQTreeOptionRules` in Sources/LungfishIO/Bundles/IQTreeOptionRules.swift, the table the CLI uses.

Selection > Tree Node is built by `makeTreeNodeMenuItem()` in App/MainMenu+TreeNode.swift from `PhylogeneticTreeViewController.nodeMenuBarSections` (Sources/LungfishPhylogeneticsUI/AGENTS.md). The Inspector's Inference section for trees is Views/Inspector/Sections/PhylogeneticTreeInferenceSection.swift.

## Operation launch pattern for new code

A standalone operation calls `OperationCenter.shared.begin` with operationType and cliCommand, then runs `lungfish-cli` through `CLISubprocessTransport` and maps events with `OperationCenterCLIBridge` (Services/OperationCenterCLIBridge.swift line 54). The reference pair is Services/MSADistanceMatrixExportCoordinator.swift (`run`) and Services/CLIMSAActionRunner.swift.

The bridge holds the bar, so a lower fraction after a higher one leaves it alone, logs a progress message once when it changes, and takes an optional overlay closure that runs only while the row runs. A runner that fits two phases into one bar clamps the fraction before it hands the event over, as `variantCallingEventHandler` does. The bridge logs plain standard error at info level, so that text never makes a row Completed with Warnings, and `OperationCenterCLIBridgeTests` pins the rule and the label a run ends on. A runner completes the row with paths from the transport's `outputs` only. When the CLI types its outputs, the runner reads each artifact by a role from `CLIEventArtifact.Role` and falls back to the path's place in `outputs` for an older CLI, as Services/CLIPrimerTrimRunner.swift does for `bam primer-trim`.

A read tool joins the FASTQ operation dialog family instead. Its Tools menu item is generated from `FASTQOperationToolID` (Views/FASTQ/FASTQOperationDialogState.swift line 1895) and `toolIDs(for:)`, so a new tool is a case plus a `toolIDs(for:)` entry and needs no menu code. App/MainMenu+Tools.swift builds the Tools menu from the groups in App/ToolsMenuLayout.swift, one submenu per category in `FASTQOperationCategoryID` order. A new category also needs a `displayName` arm in Views/FASTQ/FASTQOperationsCatalog.swift and an entry in `ToolsMenuLayout.groups`, and `testLayoutNamesEveryCategoryExactlyOnce` in Tests/LungfishAppViewTests/ToolsMenuStructureTests.swift fails until the layout lists it in the enum's order. A command that no catalog generates, such as Call Variants…, MHC Haplotype Definitions… or Build Tree with IQ-TREE…, is a `ToolsMenuLayout.FixedCommand` placed before or after a category's tools. A read tool runs through Services/FASTQOperationPlanner.swift, FASTQOperationCLIInvocationBuilder.swift, FASTQOperationExecutionService.swift and FASTQOperationOutputImporter.swift. Dialogs live under Views/<Area>/, such as Views/Mapping/MappingWizardSheet.swift. docs/contracts/ADDING-AN-OPERATION.md has the full list.

## Tests

Targets LungfishAppTests (597 files), LungfishAppViewTests and LungfishAppWorkflowTests. A whole-target filter is a selection large enough to hit ARG_MAX when run serially, so iterate per suite with `swift test --skip-update --filter LungfishAppTests.<SuiteName>` (memory file reference_swiftpm_tooling_gotchas.md).

## Known traps

| Trap | Evidence |
|---|---|
| SidebarItemType has 71 cases and routing is a chain of type checks | Views/Sidebar/SidebarItem.swift line 40, Views/MainWindow/MainSplitViewController+ContentDisplay.swift lines 16 to 222 (R1) |
| 13 optional child viewports and hand-written hide lists that drift | Views/Viewer/ViewerViewController.swift lines 207 to 253, ViewerViewController+TwelveS.swift lines 8 to 32 omit `hidePrimerAnalysisView` (R1) |
| Inspector tab chosen by folder-name prefix | App/AppDelegate.swift lines 301 to 305 (R1) |
| A new analysis tool needs `AnalysesFolder.knownTools`, `displayName`, `SidebarProjectScanner.analysisIcon` and `analysisItemType` plus a route case, or its node never opens | Views/Sidebar/SidebarProjectScanner.swift lines 914 and 939, Views/MainWindow/AnalysisResultDisplayRoute.swift line 4 (memory file project_viral_recon_results_integration.md) |
| EsViritu GUI and CLI write different result trees | App/AppDelegate+Classification.swift lines 911 to 1159 against Sources/LungfishCLI/Commands/EsVirituCommand.swift (R3) |
| The FASTQ dataset dashboard runs no tool. Its read preview and its FASTA preview read the first 1,000 records with `FASTQReader` off the main actor, keep mates in file order and write no file. Its derivative run path was deleted in Phase 1.5 (lane L12), so every FASTQ operation runs from the FASTQ operations dialog through `lungfish-cli` | Views/Viewer/FASTQDatasetViewController.swift, `firstRecords` and `loadReadPreview`, pinned by Tests/LungfishAppTests/FASTQDatasetPreviewTests.swift (R3, Phase 2.10 S37) |
| A FASTQ operations dialog row records `<derived>` for its output at `begin`. After a successful run `FASTQOperationRowCommand` refines it with `setCommand` to the commands the imported bundles' manifests record, or Savont's executed invocations, and a grouped result such as a demultiplex keeps the placeholder | Services/FASTQOperationRowCommand.swift, `beginFASTQLaunchRequestOperation` in Views/MainWindow/MainSplitViewController+GenomicsDisplayOperationBegin.swift (lane L12) |
| FASTQ-family and Workflow Operations runners start their own `Process` instead of using `CLISubprocessTransport`. Do not copy this into a new runner | `LungfishCLIProcessRunner` in Services/FASTQOperationExecutionService.swift line 800, `ProcessViralReconWorkflowProcessRunner` in Services/ViralReconWorkflowExecutionService.swift line 772 (R7, Phase 2) |
| A test that routes a file to Quick Look starts real Quick Look in the test process unless it installs a preview renderer double | `embeddedFilePreviewRenderer` in Views/Viewer/ViewerViewController.swift and `RecordingFilePreviewRenderer` in Tests/LungfishAppTests (R10) |

Every viewport switch clears transient state through `clearTransientViewportState` (Views/MainWindow/MainSplitViewController.swift line 526, memory file known-issues.md).
