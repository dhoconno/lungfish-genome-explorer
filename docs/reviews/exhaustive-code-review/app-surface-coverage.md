# App Surface Coverage Tracker — 2026-04-20

This file tracks red-team review coverage across `Sources/LungfishApp` so future sessions can keep moving toward whole-app audit coverage instead of re-discovering scope from scratch.

## Legend

- `fixed`: reviewed and concrete issues from this pass were fixed
- `reviewed`: reviewed in this wave with no new production change yet
- `open`: concrete findings recorded but not fixed in this wave
- `pending`: not yet reviewed in this tracking pass

## Reviewed Waves

### Wave 1 — Window Shell / XCUI foundation (`fixed`)

Files already hardened in prior passes:

- `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift`
- `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift`
- `Sources/LungfishApp/Views/Results/Assembly/AssemblyContigDetailPane.swift`
- `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift`
- `Sources/LungfishApp/Views/Inspector/Sections/AnalysesSection.swift`
- `Sources/LungfishApp/Views/Inspector/Sections/SampleMetadataSection.swift`
- `Sources/LungfishApp/Views/Workflow/ParameterControlFactory.swift`
- `Sources/LungfishApp/Views/Workflow/ParameterFormView.swift`
- `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowCanvasView.swift`
- `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowNodeView.swift`
- `Sources/LungfishApp/Views/Metagenomics/ClassificationWizardSheet.swift`
- `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`
- `Sources/LungfishApp/Views/Metagenomics/TaxTriageBatchOverviewView.swift`
- `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- `Sources/LungfishApp/Views/Metagenomics/BlastResultsDrawerContainerView.swift`

Key entry points covered:

- window/controller setup and shell layout
- sidebar search/filter interactions
- welcome flow actions
- database search filters and result rows
- assembly result detail pane
- operations dialog shell
- inspector section controls
- workflow configuration control factories
- classifier result split views and drawer affordances

### Wave 2 — Runtime / storage / workflow safety (`fixed`)

Files already hardened in prior passes:

- `Sources/LungfishApp/Services/FASTQDerivativeService.swift`
- `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
- `Sources/LungfishCore/Storage/ProjectStore.swift`
- `Sources/LungfishCore/Storage/ProjectFile.swift`
- `Sources/LungfishPlugin/BuiltIn/PatternSearchPlugin.swift`
- `Sources/LungfishCore/Services/NCBI/SRAService.swift`

Key entry points covered:

- FASTQ derivative generation and paired-end merge flow
- native tool timeout/cancel teardown
- project history/storage persistence
- pattern search plugin safety
- transient SRA fetch retry handling

### Wave 3 — Settings / Import / Viewer secondary surfaces (`fixed`)

Files reviewed and fixed in this pass:

- `Sources/LungfishApp/App/XCUIAccessibilityIdentifiers.swift`
- `Sources/LungfishApp/Views/Settings/SettingsWindowController.swift`
- `Sources/LungfishApp/Views/Settings/SettingsView.swift`
- `Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift`
- `Sources/LungfishApp/Views/Settings/AIServicesSettingsTab.swift`
- `Sources/LungfishApp/Views/ImportCenter/ImportCenterWindowController.swift`
- `Sources/LungfishApp/Views/ImportCenter/ImportCenterView.swift`
- `Sources/LungfishApp/Views/Viewer/OperationPreviewView.swift`
- `Sources/LungfishApp/Views/Viewer/FASTQMetadataDrawerView.swift`
- `Sources/LungfishApp/Views/Viewer/VCFDatasetViewController.swift`

Key functions / entry points covered:

- `SettingsWindowController.init()`
- `SettingsView.body`
- `StorageSettingsTab.makeViewState`
- `StorageSettingsTab.chooseDirectory()`
- `StorageSettingsTab.refreshDisplay()`
- `AIServicesSettingsTab.debouncedStore(_:forKey:task:)`
- `AIServicesSettingsTab.clearAllKeys()`
- `AIServicesSettingsTab.validateKey(_:provider:)`
- `ImportCenterWindowController.init()`
- `ImportCenterView.body`
- `ImportCenterView.cardSection(cards:)`
- `ImportCardView.resolveDroppedURLs(from:)`
- `OperationPreviewView.update(operation:statistics:)`
- `OperationPreviewView.setFASTAContent(_:)`
- `FASTQMetadataDrawerView.configure(fastqURL:metadata:)`
- `FASTQMetadataDrawerView.currentDemuxPlan()`
- `FASTQDrawerDividerView.configureAccessibility()`
- `VCFDatasetViewController.applySortOrder()`

Outcomes:

- Settings and Import windows now have stable XCUI-oriented identifiers
- storage chooser is sheet-modal against the owning window instead of a detached panel path
- AI key management no longer allows stale debounce writes or stale validation results to overwrite current state
- Import Center drag-and-drop URL collection no longer mutates shared state unsafely
- FASTA preview no longer permanently suppresses schematic operation previews
- FASTQ drawer preserves multi-step demultiplex plans instead of truncating them on load/save
- VCF descending sorts no longer use an invalid comparator on ties

### Wave 4 — App shell / document transitions / viewer tool sheets (`fixed`)

Files reviewed and fixed in this pass:

- `Sources/LungfishApp/App/DocumentManager.swift`
- `Sources/LungfishApp/App/AppDelegate.swift`
- `Sources/LungfishApp/App/MainMenu.swift`
- `Sources/LungfishApp/App/AboutWindowController.swift`
- `Sources/LungfishApp/App/ThirdPartyLicensesWindowController.swift`
- `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
- `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift`
- `Sources/LungfishApp/Views/TranslationTool/TranslationToolView.swift`
- `Sources/LungfishApp/Views/Extraction/ExtractionConfigurationView.swift`

Key functions / entry points covered:

- `DocumentManager.createProject(at:name:description:author:)`
- `DocumentManager.openProject(at:)`
- `DocumentManager.loadDocument(at:)`
- `DocumentManager.closeDocument(_:)`
- `AppDelegate.application(_:openFiles:)`
- `AppDelegate.canQueueDocumentOpen(at:)`
- `AppDelegate.ensureMainWindowForDocumentOpen()`
- `AppDelegate.openDocument(at:)`
- `MainMenu.createApplicationMenu()`
- `MainMenu.createFileMenu()`
- `MainMenu.createToolsMenu()`
- `MainMenu.createOperationsMenu()`
- `MainMenu.createHelpMenu()`
- `SequenceViewerView.configureAccessibility()`
- `DrawerDividerView.configureAccessibility()`
- `TranslationToolView.body`
- `ExtractionConfigurationView.body`

Outcomes:

- project creation/open now replaces stale document state instead of leaking previous documents across project switches
- active-document transitions now consistently go through notification-posting paths when the active document changes
- Finder-driven file opens now preflight unsupported or unreadable inputs and route `.lungfish` project opens through the dedicated project-open path
- top-level menus and key shell actions now expose stable identifiers for XCUI instead of relying on visible titles alone
- About and third-party licensing windows expose stable AX/XCUI hooks for their roots and interactive controls
- sequence viewer and annotation drawer resize affordances now have explicit accessibility metadata
- translation and extraction sheets now expose stable identifiers for their main controls, making the full workflow targetable in future XCUI coverage

### Wave 5 — Plugin / AI management surfaces (`fixed`)

Files reviewed and fixed in this pass:

- `Sources/LungfishApp/Views/AI/AIAssistantPanel.swift`
- `Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift`
- `Sources/LungfishApp/Views/PluginManager/PluginManagerWindowController.swift`

Key functions / entry points covered:

- `AIAssistantWindowController.showPanel()`
- `AIAssistantViewController.setupUI()`
- `AIAssistantViewController.showThinkingIndicator()`
- `AIAssistantViewController.refreshSuggestedQueries()`
- `AIAssistantViewController.suggestedQueryTapped(_:)`
- `PluginManagerAccessibilityID` row/action identifier helpers
- `InstalledTabView.emptyPlaceholder`
- `EnvironmentRow.body`
- `PackCard.body`
- `DatabasesTabView.databaseHeader`
- `DatabasesTabView.storageFooter`
- `DatabaseRow.body`
- `DatabaseRow.actionView`

Outcomes:

- AI assistant window, root, status, thinking indicator, and suggested query controls now have stable identifiers instead of ad hoc or content-coupled IDs
- suggested query actions now carry the real prompt text via `toolTip`, so XCUI identifiers can stay stable without changing behavior
- Plugin Manager now exposes stable row-level and action-level identifiers for environment removal, pack install/remove, database download/cancel/remove, dismiss-error, and storage navigation flows
- future XCUI coverage for plugin/database lifecycle workflows no longer has to rely on row index order or visible button titles alone

## Open Findings From This Review Wave

### App shell / document domain (`open`)

- `Sources/LungfishApp/App/AppDelegate.swift`
  - sync loader logic diverges from `DocumentLoader` coverage

### Import Center follow-up (`open`)

- `Sources/LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`
  - `dispatchFileImport(urls:action:)` still records optimistic success after dispatch rather than outcome
  - `openWizardSheet(action:)` still closes the window before delegate-side preflight failures can be surfaced cleanly

### Viewer follow-up (`open`)

- `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`
  - category expansion/disclosure path appears to be dead complexity and should either be removed or fully implemented

## Remaining Domain Backlog

### Pending / not yet re-reviewed in this tracker

- `Sources/LungfishApp/Views/FASTQ/*` dialog surfaces outside the drawer-specific fixes above
- `Sources/LungfishApp/Services/*` not already called out in Waves 1-3

## Regression Tests Added In This Wave

- `Tests/LungfishAppTests/SettingsAndImportXCUIReadinessTests.swift`
- `Tests/LungfishAppTests/ViewerRegressionTests.swift`
- `Tests/LungfishAppTests/VCFDashboardTests.swift` updated with deterministic descending-tie coverage
- `Tests/LungfishAppTests/DocumentManagerTests.swift` updated with project transition regressions
- `Tests/LungfishAppTests/ImportCenterMenuTests.swift` updated with stable main-menu identifier checks
- `Tests/LungfishAppTests/AppShellAccessibilityTests.swift`
- `Tests/LungfishAppTests/ViewerAccessibilityReadinessTests.swift`
- `Tests/LungfishAppTests/WindowAppearanceTests.swift` updated with plugin-manager/AI accessibility source assertions
