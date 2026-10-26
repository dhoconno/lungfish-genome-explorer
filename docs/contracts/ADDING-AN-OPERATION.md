# Adding an operation

This contract binds all new work in Lungfish Genome Explorer (LGE). Part of the contracts index in `docs/contracts/README.md`. Findings R3, R4 and R8 in `docs/reports/2026-10-02-architecture-review/REVIEW.md` explain why each rule exists.

An operation is anything that runs a tool or writes scientific output on behalf of the user. Every operation has one implementation in LungfishWorkflow, one CLI command that drives it, and a thin GUI launcher that runs that CLI command as a subprocess and mirrors its progress into the Operations panel. The GUI never runs the tool itself.

This document first traces one real operation, variant calling, from menu item to bundle on disk. It then states the rules every new operation must meet. Where today's variant-calling code falls short of a rule, the trace says so and names the code that already meets it.

## The variant-calling path, traced through the code

The table follows the calls in order. Every file was read for this trace. Line numbers are correct as of commit a0eec8b32 and drift with edits, so search for the named function when a number is stale.

| Step | What happens | File |
|---|---|---|
| 1. Menu entry | Tools > Variant Calling > Call Variants… is a fixed command that `ToolsMenuLayout` puts first in the Variant Calling submenu. Its action, `showBAMVariantCalling`, calls `presentVariantCallingDialog(bundle:preferredAlignmentTrackID:)` on the Inspector. The Inspector's Analysis section reaches the same method through `runCallVariantsWorkflow()`. | `Sources/LungfishApp/App/ToolsMenuLayout.swift`, `Sources/LungfishApp/App/MainMenu+Tools.swift`, `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` and `Sources/LungfishApp/Views/Inspector/InspectorViewController+MetadataImport.swift` |
| 2. Eligibility and lock pre-check | `presentVariantCallingDialog` asks `BAMVariantCallingEligibility` for analysis-ready BAM tracks, checks `OperationCenter.shared.canStartOperation(on:)`, then presents the dialog. | `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` and `Sources/LungfishApp/Views/BAM/BAMVariantCallingEligibility.swift` |
| 3. Dialog | `BAMVariantCallingDialogPresenter` shows the sheet. `BAMVariantCallingDialogState` collects choices and exposes `pendingRequest`, a `BundleVariantCallingRequest`. | `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogPresenter.swift` and `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift` |
| 4. Request type | `BundleVariantCallingRequest` is a plain `Sendable` value owned by Workflow, so the GUI and the CLI describe a run with the same type. | `Sources/LungfishWorkflow/Variants/BundleVariantCallingModels.swift` |
| 5. argv and command string | `launchVariantCallingOperation(state:)` builds argv once with `CLIVariantCallingRunner.buildCLIArguments(request:)` and passes that array to `beginVariantCallingOperation`, which builds the displayed command from it with `OperationCenter.buildCLICommand(subcommand:args:)`. | `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` and `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift` |
| 6. Operations panel row | `beginVariantCallingOperation(title:detail:bundleURL:cliArguments:routeContext:reporter:launch:)` calls `begin` on an `OperationReporting`, passing `.variantCalling`, the bundle as lock target and the command. It calls its `launch` closure only when the row started, and that closure creates the runner. The pre-check in step 2 stays as the friendly alert. | `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` and `Sources/LungfishKit/OperationReporting.swift` |
| 7. Subprocess | `CLIVariantCallingRunner.run(arguments:onEvent:)` hands argv to `CLISubprocessTransport.run(arguments:isCancelled:onEvent:)`, which finds the binary through `CLIBinaryLocator`, launches it with the managed storage environment, and decodes each stdout line as a `CLIEvent`. | `Sources/LungfishKit/CLISubprocessTransport.swift` and `Sources/LungfishKit/CLIBinaryLocator.swift` |
| 8. Event schema | `CLIEvent` has six cases (`start`, `progress`, `log`, `output`, `complete`, `failed`). The transport folds `complete` into its return value and `failed` into a thrown error, so a caller cannot forget either. | `Sources/LungfishWorkflow/CLIEvents/CLIEvent.swift` |
| 9. Progress into the panel | The launcher's `onEvent` closure, `variantCallingEventHandler(operationID:)`, hands each event to `OperationCenterCLIBridge.onEvent(operationID:)`. The bridge applies the events on the main thread in the order they arrive. It holds the bar, so a lower fraction never moves it back, sets the detail from a progress message and logs that message once when it changes. The closure only clamps the fraction to 0.10 through 0.88, because the caller workflow and the SQLite import each report 0 to 1. | `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` and `Sources/LungfishKit/OperationCenterCLIBridge.swift` |
| 10. Cancel | `OperationCenter.shared.setCancelCallback(for:)` cancels the Swift task and calls `runner.cancel()`, which forwards to the transport's `nonisolated` cancel so it never queues behind the running `run`. | `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift` |
| 11. CLI registration | `VariantsCommand` is listed in the root command's subcommands. `CallSubcommand` defines `lungfish-cli variants call` and its options. | `Sources/LungfishCLI/LungfishCLI.swift` and `Sources/LungfishCLI/Commands/VariantsCommand.swift` |
| 12. CLI execution | `CallSubcommand.execute(runtime:emitEvent:)` resolves the alignment track, reads any primer-trim attestation, builds the same `BundleVariantCallingRequest`, then runs `Runtime.live()`. That runtime checks tools with `NativeToolRunner.shared.findTool` and validates inputs with `BAMVariantCallingPreflight`. | `Sources/LungfishCLI/Commands/VariantsCommand.swift` and `Sources/LungfishWorkflow/Variants/BAMVariantCallingPreflight.swift` |
| 13. Workflow service | `ViralVariantCallingPipeline.run(progress:)` runs the caller through `NativeToolRunner`, normalizes the VCF and records one `VariantCallingProvenanceStep` per tool. `VariantSQLiteImportCoordinator.importNormalizedVCF` builds the SQLite store. | `Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift` and `Sources/LungfishWorkflow/Variants/VariantSQLiteImportCoordinator.swift` |
| 14. Output bundle | `BundleVariantTrackAttachmentService.attach(request:)` moves the VCF.gz, its tabix index and the SQLite database into the bundle's `variants/` folder and saves the bundle manifest atomically. | `Sources/LungfishWorkflow/Variants/BundleVariantTrackAttachmentService.swift` |
| 15. Provenance | The same service's `writeWorkflowProvenance` builds a `WorkflowRun` from the CLI's `VariantCallingWorkflowProvenance`, converts it with `canonicalEnvelope()` and writes `variants/<basename>.lungfish-provenance.json` through `ProvenanceWriter(signingProvider: nil)`. The file is an envelope, so `ProvenanceEnvelopeReader` decodes it as one. | `Sources/LungfishWorkflow/Variants/BundleVariantTrackAttachmentService.swift`, `Sources/LungfishWorkflow/Provenance/ProvenanceRecord.swift`, `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift` and `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelopeReader.swift` |
| 16. Events on the wire | With `--format json` the command maps its `VariantCallingEvent` values onto `CLIEvent` and writes them through `CLIEventEmitter`. Completion carries `[databasePath, vcfPath, tbiPath]` as outputs, a `trackID=... trackName=...` message and one artifact per file with the role `variants-database`, `variants` or `variants-index`, each naming the record. `CLIVariantCallingRunner.parseCompletion` reads each file by role, then by place. | `Sources/LungfishCLI/Commands/VariantsCommand.swift` and `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift` |
| 17. Completion in the GUI | On success the launcher calls `OperationCenter.shared.complete(id:detail:)`, reloads the sidebar, and redisplays the bundle. Cancellation calls `acknowledgeCancellation`. Failure calls `fail` and shows an alert. | `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` |
| 18. Feature registry | The `variants.call` entry lists the entry points, outputs and source files. | `docs/user-manual/features.yaml` |

### Tests that pin this path

| Test file | What it protects |
|---|---|
| `Tests/LungfishAppTests/CLIVariantCallingRunnerTests.swift` | argv construction per caller, completion parsing, cancel kills the process tree |
| `Tests/LungfishAppTests/CLIRunnerArgvRoundTripTests.swift` | the argv the GUI runs and displays also parses through the real `CallSubcommand` |
| `Tests/LungfishAppTests/InspectorVariantWorkflowOperationTests.swift` | a held bundle lock refuses the row and launches nothing, and the recorded command parses through the real CLI parser with the run's values |
| `Tests/LungfishAppTests/BAMVariantCallingDialogRoutingTests.swift` | the dialog routes to the right launcher |
| `Tests/LungfishCLITests/VariantsCommandTests.swift` and `Tests/LungfishCLITests/VariantsCallAlignmentTrackResolutionTests.swift` | CLI options, event stream and track resolution |
| `Tests/LungfishWorkflowTests/Variants/ViralVariantCallingPipelineTests.swift` and `Tests/LungfishWorkflowTests/Variants/BundleVariantTrackAttachmentServiceTests.swift` | the pipeline and the bundle write, including provenance |
| `Tests/LungfishIntegrationTests/ReadsToVariantsEndToEndTests.swift` | reads to variants through real tools |

### Where today's path falls short of the rules

Variant calling is the recommended example because its layering is right. It still has one gap, and a new operation must not copy it.

| Gap | Rule it breaks | Copy this instead |
|---|---|---|
| It builds the record as a legacy `WorkflowRun` and converts it with `canonicalEnvelope()`, where Rule 6 asks for `ProvenanceRunBuilder`. The sidecar has been an envelope since sub-phase 2.4, but its steps and parameters still come from the old model. | Rule 6 | `CLIProvenanceSupport.recordSingleStepRun` in `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift`, which builds with `ProvenanceRunBuilder` and writes with `ProvenanceWriter` |

## Which launch family a new operation joins

Variant calling is a standalone runner. Most read-processing tools instead belong to the FASTQ operation dialog family, which has its own menu wiring, request type and execution service. Pick the family before writing code.

| The operation | Family | Model to copy |
|---|---|---|
| reads FASTQ or FASTA datasets and is launched from the FASTQ operations dialog (Tools menu categories such as Clustering, Mapping, Assembly or Trimming & Filtering) | FASTQ operation dialog family | Savont, traced below |
| takes any other input (a reference bundle, an alignment track, a variant track, an MSA, a tree) | standalone runner | a new `CLIFooRunner` modelled on `CLITreeRunner` in `Sources/LungfishApp/Services/CLITreeRunner.swift` |

### The Savont path, traced through the code

Line numbers are correct as of commit 9569fe2b6.

| Step | What happens | File |
|---|---|---|
| 1. Menu entry | `ToolsMenuModel.build` starts from `WorkflowLibraryCatalog.builtIn`, which maps over `FASTQOperationToolID.allCases`. `MainMenu.createToolsMenu` builds one submenu per category entry in `ToolsMenuLayout.groups`, and `MainMenu.operationMenuItems(for:)` adds one item per tool listed by `FASTQOperationDialogState.toolIDs(for:)`. Every item calls `launchFASTQOperationToolFromMenu`, which opens `showFASTQOperationsDialog` with the tool preselected. No menu item is written by hand. | `Sources/LungfishApp/App/ToolsMenuModel.swift`, `Sources/LungfishApp/Services/WorkflowLibrary.swift` line 165, `Sources/LungfishApp/App/ToolsMenuLayout.swift`, `Sources/LungfishApp/App/MainMenu+Tools.swift` line 89, `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` line 85 |
| 2. Dialog and request | The Savont pane collects settings. `launchRequestForSelectedTool()` returns `FASTQOperationLaunchRequest.savont`, which the dialog exposes as `pendingLaunchRequest`. | `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift` and `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift` line 455 |
| 3. Launcher | The dialog's completion hands the request to `runFASTQOperationLaunchRequest`, which registers a `.fastqOperation` row with `beginFASTQLaunchRequestOperation` and calls `trackAnalysisOutput`. The row's command names `<derived>` for the output until the run succeeds, and then `FASTQOperationRowCommand` refines it with `setCommand`, as `docs/contracts/CLI-EQUIVALENCE.md` describes. | `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift`, `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift` and `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplayOperationBegin.swift` |
| 4. Plan | `FASTQOperationPlanner` picks the output mode, makes one execution plan per input with `makeExecutionPlans`, and later finds outputs with `discoverOutputs`. | `Sources/LungfishApp/Services/FASTQOperationPlanner.swift` |
| 5. argv | `FASTQOperationCLIInvocationBuilder.buildInvocation` turns the request into `lungfish-cli fastq savont-cluster` arguments. The launcher builds the displayed command from the same invocation. | `Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift` |
| 6. Subprocess | `FASTQOperationExecutionService.execute` materializes inputs and runs each invocation through `LungfishCLIProcessRunner`. That runner finds the binary with `LungfishCLIRunner.findCLI`, launches it on `CLIProcessLauncher` with `operationGrace` and `operationDrain`, and decodes `CLIEvent` lines on the channel that the leaf's row of `CLIEventContractTable` names. | `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift` lines 749 and 780 |
| 7. Import | `BundleFASTQOperationImporter` turns the discovered outputs into project bundles. | `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift` line 438 |

Some tools leave this path early in `showFASTQOperationsDialog`, and none of them is a model for new work. Mapping tools (minimap2, BWA-MEM2, Bowtie2, BBMap) set `pendingMappingRequest`, and `runManagedMapping` in `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` still runs `ManagedMappingPipeline` in process, which breaks Rule 9 (finding R3). The classifiers set their own pending configurations, and `Sources/LungfishApp/App/AppDelegate+ClassifierLaunchRouting.swift` runs them through `lungfish-cli`, with no hidden key and no in-process route since 2.12 (K1). Viral Recon runs through `Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift`. Workflow Library items with the `.workflowOperations` capability (`ontGenotyping`, titled MiSeq Amplicon MHC Genotyping, Full-Length ONT MHC Genotyping and 12S Amplicon Matching) open the Workflow Operations window and run through `WorkflowOperationExecutionService` in `Sources/LungfishApp/Services/WorkflowOperationExecutionService.swift`, which also starts its own `Process`.

### What a new FASTQ-input tool adds

| Piece | File | What to add |
|---|---|---|
| Tool identity | `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift` | a `FASTQOperationToolID` case and its arms. Bowtie2 has 14 switch arms (9 in the enum's own properties, 2 in the dialog state, 3 in the panes file) plus one entry in `toolIDs(for:)`. A switch with a `default` arm compiles without the new case, so search for an existing tool's case and add the new one beside every hit. |
| Menu placement | `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift` | the tool in `toolIDs(for:)` for its category, which is what puts it in the Tools menu and the dialog sidebar. A new tool is that case plus that entry. Where the category sits in the Tools menu comes from `ToolsMenuLayout.groups` in `Sources/LungfishApp/App/ToolsMenuLayout.swift`, so a tool in an existing category changes no menu code |
| Category | `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift` | an existing `FASTQOperationCategoryID`. A new category is a case placed in Tools menu order with `displayName`, `requiredPackIDs` and `defaultToolID` arms there, a `toolIDs(for:)` arm, symbol and tooltip arms in `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`, and an entry in `ToolsMenuLayout.groups` in `Sources/LungfishApp/App/ToolsMenuLayout.swift`. `displayName` is the one name the Tools menu, the dataset launchers and the Workflow Library show, and the dialog's uppercase `title` derives from it. `testLayoutNamesEveryCategoryExactlyOnce` in `Tests/LungfishAppViewTests/ToolsMenuStructureTests.swift` fails until the layout lists the case in the enum's order. `accessibilityNamespace()` in `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialog.swift` has a `default` arm, so decide its namespace by hand |
| Settings pane | `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift` | an arm in `FASTQOperationToolPanes.body` and in the primary and advanced settings sections. A tool with a large form embeds its own sheet there, as mapping embeds `MappingWizardSheet` |
| Request and argv | `FASTQOperationLaunchRequest` in `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift` and `Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift` | a request case and its invocation |
| Outputs | `Sources/LungfishApp/Services/FASTQOperationPlanner.swift` and `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift` | the output mode, output discovery and import arms |

### The runner of the FASTQ family

`LungfishCLIProcessRunner` launches `lungfish-cli` on `CLIProcessLauncher` with `operationGrace` and `operationDrain` since Phase 2.10 (lane A41), as the Viral Recon and Local Workflow runner does, so finding R7 is retired. A new tool in the FASTQ family adds its request case and invocation and runs on that runner. A new standalone runner never starts a `Process`. It runs `lungfish-cli` through `CLISubprocessTransport`, or through `CLIProcessLauncher` when it reads the output itself, as Rule 9 and the Runner row below require.

## Rules

Each rule is a requirement. A reviewer rejects a change that breaks one. The column on the right names the code that shows the rule done correctly today.

| Rule | Requirement | Reference |
|---|---|---|
| 1. Register with `begin` | Register the row with `begin` on an `OperationReporting`, which production code defaults to `OperationCenter.shared`. Switch on the result, and launch nothing (no subprocess, no bundle write) unless it is `.started`. The `.refused` case already shows a visible "Bundle is busy" row. Put the call in a begin helper with a launch closure, as "Registering an operation with begin()" below describes, so a test can check it. | `Sources/LungfishKit/OperationReporting.swift`, `beginVariantCallingOperation` in `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` |
| 2. Type and command always passed | Pass an explicit `operationType` and a `cliCommand` on every call. Neither `OperationCenter.begin` nor the `begin` that `OperationReporting` adds has a default for either, so the compiler catches an omission. The command is non-nil whenever a CLI command reproduces the run. A run that none reproduces passes `nil` explicitly, names the closest command in its helper's doc comment and pins the gap with a test, as "Registering an operation with begin()" below describes. A run out of scope under `docs/contracts/CLI-EQUIVALENCE.md` passes `nil` with the marker `cli-parity-exempt: not-scientific-data` and adds no gap. Build `cliCommand` with `OperationCenter.buildCLICommand(subcommand:args:)` from the exact argv array you execute, and add an `OperationType` case if none fits. | `OperationType` and `buildCLICommand` in `Sources/LungfishKit/OperationCenter.swift` |
| 3. Lock scope declared | Pass the bundle the operation writes as `targetBundleURL` (exact lock). Pass every other bundle it writes, or whose contents must not change mid-run, in `additionalLockedBundleURLs` (whole-tree lock). An operation that writes no bundle says so in review. | `insertOperation` in `Sources/LungfishKit/OperationCenter.swift` |
| 4. Analysis directory created without `try?` | Create an `Analyses/` result folder with `AnalysesFolder.createAnalysisDirectory(tool:in:isBatch:date:command:)` inside a `do` block and fail the operation when it throws. A `try?` hides the error and the run writes somewhere unexpected. On failure or cancel, call `AnalysesFolder.discardFailedAnalysisDirectory`. | `Sources/LungfishIO/Bundles/AnalysesFolder.swift`, called through `MappingResultLayoutService.createAnalysisDirectory` in `Sources/LungfishCLI/Commands/MapCommand.swift` |
| 5. Analysis directory tracked and completed | The CLI or Workflow producer calls `AnalysesFolder.markAnalysisComplete` as its last successful step. The GUI launcher calls `OperationCenter.shared.trackAnalysisOutput(_:for:)` for the folder. Without both, the run record stays and the sidebar hides the result. | `Sources/LungfishCLI/Commands/MapCommand.swift`, `trackAnalysisOutput` in `Sources/LungfishKit/OperationCenter.swift`, `Sources/LungfishCore/Services/AnalysisRunRecord.swift` |
| 6. Provenance through the envelope | Write a `ProvenanceEnvelope` with `ProvenanceRunBuilder` and `ProvenanceWriter` (or `CLIProvenanceSupport.recordSingleStepRun` from a CLI command). Record argv, resolved defaults, tool version, runtime identity, input and output checksums, run status, exit status and wall time. Use `ProvenanceRecorder.provenanceFilename` or `ProvenanceRecorder.fileSidecarURL(for:)`. Never write a bare `WorkflowRun`, add a new sidecar filename or add a private `writeProvenance` copy. `docs/contracts/RECORDING-PROVENANCE.md` holds the full rules, and `scripts/ratchets/provenance-writers.sh` fails the pre-push hook when the count of a frozen writer rises. | `docs/contracts/RECORDING-PROVENANCE.md`, `Sources/LungfishWorkflow/Provenance/ProvenanceRunBuilder.swift`, `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift`, `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift` |
| 7. Virtual FASTQ materialized first | A derived FASTQ bundle holds only `preview.fastq` (about 1,000 reads). Before any tool sees FASTQ input, check `SequenceInputResolver.unmaterializedDerivedBundleURL(for:)` and materialize with `FASTQCLIMaterializer`. Never pass `FASTQBundle.resolvePrimaryFASTQURL` output straight to a tool. | `Sources/LungfishIO/Formats/Common/SequenceInputResolver.swift`, `Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift`, its use in `Sources/LungfishCLI/Commands/MapCommand.swift` |
| 8. One event schema, one bridge | The CLI command emits `CLIEvent` lines through `CLIEventEmitter` when asked for JSON, and it writes human text to standard error. `CLISubprocessTransport` decodes each line of any schema version through `CLIEventLine`. `OperationCenterCLIBridge` maps the events onto the row in the order they arrive. It holds the bar, sets the detail from a progress message and logs that message once when it changes, so the expanded row keeps its history, and it logs plain standard error at info level. "What a CLI route's row shows" below states the whole rule. The transport's result holds `outputs` and the typed artifacts of the completion. A command that types its outputs keeps `outputs` in the order it documents. Its runner reads each artifact by a role from `CLIEventArtifact.Role` and falls back to the path's place in `outputs` for an older CLI. A runner imports only `outputs`. `bam primer-trim` and `CLIPrimerTrimRunner` are the example. Never declare a private NDJSON event struct. | `docs/formats/cli-events.md`, `Sources/LungfishWorkflow/CLIEvents/CLIEventLine.swift`, `Sources/LungfishKit/CLISubprocessTransport.swift`, `Sources/LungfishKit/OperationCenterCLIBridge.swift`, `Sources/LungfishApp/Services/CLIPrimerTrimRunner.swift` |
| 9. CLI parity | The GUI runs the CLI command as a subprocess and never calls `NativeToolRunner`, `CondaManager` or a pipeline type in process. A standalone runner uses `CLISubprocessTransport`. A FASTQ-family tool goes through `FASTQOperationExecutionService`, whose runner launches the CLI on `CLIProcessLauncher`. Both paths produce the same output tree and provenance. The displayed command reproduces the GUI result when pasted into a terminal. The recorded command meets `docs/contracts/CLI-EQUIVALENCE.md`. An edit of a bundle in place whose only inputs are the bundle and values the user typed or selected, and which runs no tool, sends no request and ends inside the bundle lock, may instead call, in process, the Workflow function its leaf calls, with a parse test of its row and a unit-tier replay of the row's command on a copy of the bundle, while an edit that parses a file from outside the bundle launches its leaf (decision C3 of `docs/plans/2026-10-13-phase-2-10.md`). | `Sources/LungfishApp/Services/CLITreeRunner.swift`, `Tests/LungfishAppTests/CLIRunnerArgvRoundTripTests.swift`, for an edit in place `Tests/LungfishAppTests/AnnotationEditRouteParityTests.swift` and `Sources/LungfishApp/Services/CLIBundleEditRunner.swift` |
| 10. Registered and tested | Add or update the feature entry in `docs/user-manual/features.yaml` with every source file, including the launcher. Add an argv round-trip test, a CLI test, and a Workflow test on a fixture whose expected output is checked by value. Add a replay test that runs the recorded command on a copy of the fixture and compares the two results with `OutputEquivalence.assertSame`, as `docs/contracts/CLI-EQUIVALENCE.md` describes. | the tests listed in the trace above |
| 11. Provenance policy registered | A new top-level CLI command goes in `ScientificProvenancePolicy.canonicalCLICommandNames` and gets a `cliCommandPolicies` entry, or `ScientificCLIProvenanceCoverageTests` fails. A command that writes no scientific data instead gets a reason in that test's `recordsNothing` table, keyed by its name. A subcommand that needs its own policy goes in `cliCommandPathPolicies`. A leaf takes the row of its longest registered prefix there, else the entry of its top-level command, and never the entry of its last component. `ScientificProvenancePolicyLeafTests` walks `LungfishCLI.configuration` and pins the entry of every registered leaf, so a new leaf needs a row in that test in the commit that registers it, and its help index check fails until `Tests/Fixtures/golden/cli-help` is recaptured. A leaf that resolves to no entry needs a reason in `recordsNothing`, by its own path or by its command, and a leaf below `conda`, `debug`, `demo` or `storage` that writes data needs its own row in `cliCommandPathPolicies`. A new `NativeTool` case needs a `nativeToolPolicies` entry, or every `NativeToolRunner.run` call for it throws `missingProvenancePolicy` (`requireProvenancePolicy`). | `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift`, `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`, `Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift`, `Tests/LungfishCLITests/ScientificProvenancePolicyLeafTests.swift` |

### Scientific rules that apply to every operation

These come from the invariants in the architecture review and from incidents in the project's history.

- Alignments are written as sorted, indexed BAM. An intermediate SAM is deleted.
- A scientific parameter is never changed to make the UI simpler, faster or fit in memory. If a resource limit forces a change, the user approves it and provenance records it.
- Bioinformatics tools get paths without spaces. Stage inputs through `ProjectTempDirectory` in `Sources/LungfishIO/Bundles/ProjectTempDirectory.swift` when a project path contains one.
- A Nextflow launch goes through `WorkflowEngineLaunch.resolve` in `Sources/LungfishWorkflow/WorkflowEngineLaunch.swift`, never `which nextflow` from the inherited PATH.
- Viral Recon binds a `.lungfishref` manifest, never a loose BAM.

## File list for a new operation

A new operation named Foo that writes an `Analyses/` folder touches these places. Rows that say "new" create files, and every other path already exists.

| Layer | File |
|---|---|
| Request type and service | new `FooRequest` and `FooPipeline` types in a domain folder under `Sources/LungfishWorkflow/` (see "Where a new domain goes" below) |
| Tool availability | the lock manifest `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`, and either a `NativeTool` case in `Sources/LungfishWorkflow/Native/NativeToolRunner.swift` or a conda environment run through `Sources/LungfishWorkflow/Conda/CondaManager.swift` (Phase 2 replaces both with one tool descriptor). Both launch through `ToolProcess`, and `docs/contracts/RUNNING-A-TOOL.md` says which entry point to use, how cancellation works and how to pin the tool with a golden |
| Provenance policy | the CLI command and any `NativeTool` case in `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift` (Rule 11) |
| CLI command | a new `FooCommand` in `Sources/LungfishCLI/Commands/`, registered in `Sources/LungfishCLI/LungfishCLI.swift` |
| Operation type | a case in `OperationType` in `Sources/LungfishKit/OperationCenter.swift` if none fits |
| GUI runner and launcher, standalone family | a new `CLIFooRunner` in `Sources/LungfishApp/Services/` modeled on `Sources/LungfishApp/Services/CLITreeRunner.swift`, plus a launcher in the owning leaf or App extension (see `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md`) |
| GUI wiring, FASTQ family | the rows in "What a new FASTQ-input tool adds" above, with no new runner and no hand-written menu item |
| Result recognition | the tool tables listed in `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md` until Phase 2 replaces them |
| Registry and tests | `docs/user-manual/features.yaml`, plus tests under `Tests/LungfishWorkflowTests`, `Tests/LungfishCLITests` and `Tests/LungfishAppTests` |

### Smaller touch points that are easy to miss

| Touch point | File | When it applies |
|---|---|---|
| Analysis entry on the source bundle | `AnalysisManifestStore.recordAnalysis(_:bundleURL:)` in `Sources/LungfishIO/Bundles/AnalysisManifest.swift`, which the Inspector reads in `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift` | the run reads a project bundle and should appear in that bundle's analysis history. The mapping launchers in `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` record it directly or through `MappingResultLayoutService.recordAnalysisManifest`. |
| Deterministic UI-test backend | `AppUITestConfiguration` in `Sources/LungfishKit/AppUITestConfiguration.swift` and a per-tool backend such as `Sources/LungfishApp/UITestSupport/AppUITestMappingBackend.swift` | the operation is driven by an XCUI test. The launcher checks `backendMode == .deterministic` and writes a fixed result instead of running the tool. |
| Managed tool display name and smoke test | `displayName` and `smokeTest` in `Sources/LungfishWorkflow/Conda/ManagedToolLock.swift` | optional. Both have a `default` arm, so add an arm only when the capitalized lock id reads badly or the tool needs a version probe. |
| Dialog location | `Sources/LungfishApp/Views/<Area>/`, for example `Sources/LungfishApp/Views/Mapping/MappingWizardSheet.swift` | the operation has its own dialog or sheet |

### Where a new domain goes

Today a new domain is a folder under `Sources/LungfishWorkflow/`, beside Mapping, Variants and TwelveS. Phase 4d of `docs/plans/2026-10-02-architecture-program.md` splits LungfishWorkflow into a core target and domain targets and creates an empty LungfishRNASeq target. Domain code moves into its target when that target exists. RNA-seq work waits for the Phase 5 prerequisites listed in "Prerequisites that must exist first" in `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md`.

## The recipe of a new CLI route

Phase 2.10 moves the operations that still run in the app onto `lungfish-cli`, one family of commands at a time. Every new route takes the same parts, so a cancel, a progress line and a recorded command behave alike on all of them. Decision C5 of `docs/plans/2026-10-13-phase-2-10.md` names the parts, and lane S30 built the shared ones. A family lane pins today's behaviour first only where it is scientific output, then changes the command, moves the route and writes the family's tests. Decision G1 holds for science only, and the parts below are one set for a family of commands, not a set for each route (`docs/contracts/SCOPE-AND-DELIVERY.md`).

| Part | What the route does | Model to copy |
|---|---|---|
| Command | A command that writes a record, a bundle or scratch turns SIGTERM into a cancel. It scopes `SIGTERMCancellation(cancelling:secondSignalEndsProcess: true)` around its task, hands the cancel to its services, records its run as cancelled with the status taken from the request and exits 125, `CLIExitCode.cancelled`. A second SIGTERM ends it at once. A leaf that does not convert SIGTERM claims no record. | `launchCancellingOnSIGTERM` in `Sources/LungfishCLI/Commands/RunSubcommand+Cancellation.swift` and `Sources/LungfishCLI/Support/SIGTERMCancellation.swift` |
| Runner | One standalone runner per family runs the command on `CLISubprocessTransport`, or on `CLIProcessLauncher.spec` and `CLIProcessLauncher.run` when it reads the command's output itself. It never starts a `Process`. | `Sources/LungfishApp/Services/CLITreeRunner.swift`, `Sources/LungfishApp/Services/CLIImportRunner.swift` and `Sources/LungfishApp/Services/ProcessViralReconWorkflowProcessRunner.swift` |
| Grace and drain | The runner passes `CLIProcessLauncher.operationGrace`, 6 seconds, as its `terminationGracePeriod` and `CLIProcessLauncher.operationDrain`, 500 milliseconds, as its `drainGracePeriod`. The command records its cancel inside the grace, and both nest inside the ten seconds `OperationCenter` gives a cancelling row. The launcher and the transport default to no grace, which kills the command at once, so a runner moves to the grace in the lane that makes its command convert SIGTERM (decision P2). A command that runs a cleanup tool after its SIGTERM, as `taxtriage run` runs `docker` to remove the run's containers, has its runner pass `signalsCommandFirst: true` to the transport. The transport then sends SIGTERM to the command alone and SIGKILL to its group and tree at the end of the grace, since the default SIGTERM to every descendant would stop the cleanup tool (Phase 2.11 U30 walk, W2). | `terminationGracePeriod`, `signalsCommandFirst` and `drainGracePeriod` in `Sources/LungfishApp/Services/CLIClassifierRunner.swift` |
| Cancel | The row's cancel callback calls the runner's `nonisolated` `cancel()`, which reaches `CLIRunCancellation` from any thread. Cancelling only the Swift task is not enough. | `cancel()` in `Sources/LungfishApp/Services/CLIImportRunner.swift` and `Sources/LungfishKit/CLISubprocessTransport.swift` |
| Recorded command | The launcher builds the argv once. The runner runs that array, and the begin helper records it with `OperationCenter.buildCLICommand(subcommand:args:)` as the row's `cliCommand` (Rules 1 and 2). A parse test reads the row back with `RecordedCLICommand.parse(_:as:)`. | `beginVariantCallingOperation` in `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` and `Tests/LungfishAppTests/RecordedCLICommand.swift` |
| Progress | The command writes `CLIEvent` lines on standard output under `--format json` and human text on standard error. The runner hands the events to `OperationCenterCLIBridge` in the order they arrive (Rule 8). | `Sources/LungfishKit/OperationCenterCLIBridge.swift` |
| Writes | The command publishes outputs and records through `DurableReplace` or `PortableRename` from scratch that `ProjectTempDirectory.create(prefix:in:)` makes under `<project>/.tmp/`, and leaves no stage file inside a bundle. The app writes nothing after the command exits, so the command writes every sidecar, manifest, run history entry and index itself. | `Sources/LungfishCore/Storage/DurableReplace.swift`, `Sources/LungfishIO/Bundles/ProjectTempDirectory.swift` and `docs/contracts/EXTERNAL-VOLUMES.md` |
| SIGTERM test | A CLI test starts the built CLI with `CLISIGTERMHarness.launchCLI`, waits until the command is at work, for example for a pid file that a stand-in tool writes, and calls `CLISIGTERMHarness.assertSIGTERMCancels` with a closure that reads the record's status. It sends one SIGTERM to the CLI alone and asserts exit 125 inside `operationGrace`, a record that reads `cancelled` and no process of the command's tree left. Each wait is 30 seconds and ends as soon as its condition holds. A viewer export leaf writes its payload and its record in one `writeAtomically` transaction and rolls that transaction back on a cancel, so its test asserts that neither the output nor its sidecar is left, in place of a record that reads `cancelled`. The bulk form of `bundle export-graphic` stages its folder of figures with the folder's record and publishes them through `writeFolderAtomically`, so its test `testACancelledBulkExportLeavesNoFolderAndNoStagedFolder` asserts that neither the folder nor a `.<name>.<UUID>.export.tmp` folder is left. In a debug build a leaf whose environment sets `LUNGFISH_VIEWER_EXPORT_HOLD_FILE` creates the file it names once the payload is staged and holds inside the transaction until the cancel, so the test sends its SIGTERM after that file appears. | `Tests/Support/LungfishTestSupport/CLISIGTERMHarness.swift` and `Tests/LungfishCLITests/WorkflowRunSIGTERMTests.swift`, and for a viewer export `testACancelledExportExits125AndLeavesNoFileAndNoRecord` in `Tests/LungfishAppTests/EsVirituExportCLIGUIParityReplayTests.swift` |
| Parity class | The family's `<Family>CLIGUIParityReplayTests` class in `Tests/LungfishAppTests/` runs sides A, C and C' on `RouteParityHarness`, which lane Q30 adds in `Tests/Support/LungfishKitTestSupport/`, with the CLI from `CLITestBinaryResolver`. Its cancel check goes through the real transport and calls the assertions of `CLISIGTERMHarness`. A class whose name ends in `ReplayTests` runs serially in the integration tier, so it needs no gate edit. | `docs/contracts/CLI-EQUIVALENCE.md` |
| Gap marker | The commit that moves the route removes the site's `cli-parity-gap: <ID>` marker and its `assertCLIParityGap` pin together, adds the parse and replay tests and lowers `scripts/ratchets/cli-parity-gaps.baseline` by exactly the IDs it closed, in one reviewed `--update`. A new leaf also takes its provenance policy row (Rule 11). | `docs/contracts/CLI-EQUIVALENCE.md` and `assertCLIParityGap` in `Tests/LungfishAppTests/RecordedCLICommand.swift` |

## What a CLI route's row shows

A route that runs `lungfish-cli` keeps the row its in-process route showed. Decision E15 of `docs/plans/2026-10-11-phase-2-7.md` has the CLI route repeat today's end of run and keep today's label rules, and decision W3 of `docs/plans/2026-10-13-phase-2-10.md` keeps each failure sheet's words until the lane that rewrites them. A move to the CLI therefore changes only the parts in the table below, and it changes them the same way on every route. Decisions W2, C5 and N5 of the Phase 2.10 plan set those parts, and the classifier route is the model to copy. A new route reads the command's events through `OperationCenterCLIBridge` and keeps no copy of the held bar, the once rule or the label rule. The classifier route predates this rule and still holds its own bar in `CLIClassifierRowEvents` and feeds its overlay from `CLIClassifierRunner`, so a new route copies it for the title, the end and the failure and takes the bar, the log and the overlay from the bridge.

| Part | What the row shows | Model to copy |
|---|---|---|
| Title and first detail | The begin helper passes today's title and today's first detail, so the row shows the same words from the launch. The bridge sets the row's detail from the command's `start` message. A runner that keeps the begin text as the first detail drops the `start` event or hands it over as a log event. | `beginClassifierCLIRouteOperation` in `Sources/LungfishApp/App/AppDelegate+ClassificationCLIRoute.swift`, `Sources/LungfishApp/Services/CLIClassifierRowEvents.swift` and `Sources/LungfishApp/Services/CLINativeBundleImportRunner.swift` |
| Held bar | A progress event moves the bar to its fraction only when that is higher than the bar. A lower fraction leaves the bar alone and a start event never moves it back. A fraction outside 0 to 1 is clamped as the row clamps it. A command that reports two phases from 0 to 1 has its runner clamp the fraction into one range before it hands the event over, as variant calling does, and the bar then holds at the top of that range through the later phase. The held value is the row's `progress`. The Operations Panel draws a bar only for progress evidence (`OperationsPanelViewController.swift:773-776`) and the bridge records none, so a bridged row shows its state and its detail with no bar. A drawn bar needs evidence with an honest basis and a panel decision that covers every bridged route. | `OperationCenterCLIBridge` and `variantCallingEventHandler` in `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` |
| Detail and log | A progress message becomes the row's detail and is logged at info once. The bridge skips it when the row's log already ends with it at info, so a command that repeats a line adds one entry. An empty message changes the bar only. A log event is logged at its own level, as written. A progress event and an info log event with the same words right after it give one entry for the pair, and a warning or an error is always logged. | `OperationCenterCLIBridgeTests` |
| Overlay | A route that shows the message in the viewer's progress overlay passes the bridge's optional `overlay` closure. The bridge calls it on the main actor with each non-empty progress message the row takes, and only while the row runs. A message that arrives once a cancel has moved the row to Cancelling reaches neither the row nor the overlay, and the log keeps it. A route feeds the overlay only where its in-process route did. | `onEvent(operationID:overlay:)` in `Sources/LungfishKit/OperationCenterCLIBridge.swift` |
| Copy CLI Command | The row records the argv the transport runs, and the recorded command meets `docs/contracts/CLI-EQUIVALENCE.md`. A result in a project takes `--project`, so a replay in Terminal makes a new result and leaves the old one alone. The command names no scratch file. | the Recorded command part above |
| Cancel | The row's cancel callback reaches the runner's `cancel()`. The command gets SIGTERM and the 6 second grace, records its run as cancelled and exits 125, and the row reads Cancelled with no sheet. | the Grace and drain and Cancel parts above |
| End | The command wrote the result, its records and its manifest entries before it exited, so the app writes nothing after the exit. The runner reads what it needs back from disk off the main actor, completes the row with today's detail and then reloads or reveals the sidebar. The row finishes whether or not the app delegate that launched the run is still there. | `finishClassifierThroughCLI` in `Sources/LungfishApp/App/AppDelegate+ClassificationCLIRoute.swift` |
| Failure | The row takes the failed event's message and, where the route shows them, its error message and error detail. The sheet keeps today's words, which are the message alone with no tail, until the lane that rewrites that sheet. The command keeps a failed result hidden with its records. | `failClassifierThroughCLI` in `Sources/LungfishApp/App/AppDelegate+ClassificationCLIRoute.swift` |
| Label | A row reads Completed with Warnings only when a `log` event at level warning arrived or the route calls `completeWithWarning`. Plain standard error stays at info, and so do Docker and conda lines. A line that today's row marks as a warning, such as an ignored task or a failed sample, stays a warning event in the command. Lane A30 gives the Viral Recon runner this rule, so a line of Nextflow on standard error no longer turns its row to Completed with Warnings. | `OperationCenterCLIBridgeTests` |

The command's side of the row has four rules. Every message the row shows today is a progress event with the same words, so the detail does not change. With `--format json` the command writes only events on standard output and its human text on standard error, and nothing prints before the JSON. A refusal exits 3 before any folder exists, a failure exits 64 and a cancel exits 125, and the text names the fix. The closing text line names what was written, as `TaxTriage completed in <t>s` does, and holds no full path that a row detail would show.

## Registering an operation with begin()

Every launch site registers its row with `begin` through a begin helper, a launch closure and two kinds of test. Phase 1 gave every existing site that shape, and the table at the end of this section names the one to copy for each kind of site.

### 1. Write a begin helper

Add a static function on the type that owns the launch site, named `begin<Name>Operation`. It takes the values the run uses, then `reporter` and `launch`. It registers the row and calls `launch` only when the row started.

```swift
@discardableResult
static func beginPrimerTrimOperation(
    title: String,
    bundleURL: URL,
    cliArguments: [String],
    routeContext: OperationRouteContext?,
    reporter: any OperationReporting = OperationCenter.shared,
    launch: (UUID) -> Void
) -> OperationStartResult {
    let result = reporter.begin(
        title: title,
        detail: "Preparing primer trim...",
        operationType: .bamPrimerTrim,
        targetBundleURL: bundleURL,
        cliCommand: OperationCenter.buildCLICommand(
            subcommand: "bam primer-trim",
            args: Array(cliArguments.dropFirst(2))
        ),
        routeContext: routeContext
    )
    switch result {
    case .started(let operationID):
        launch(operationID)
    case .refused:
        break // The panel already shows the refused row. Nothing was launched.
    }
    return result
}
```

| Helper rule | Reason |
|---|---|
| Name `operationType` and `cliCommand` in the call. Keep today's operation type, title, detail and `routeContext`. | `begin` has no default for type or command, and a changed panel label is a behaviour change. |
| Keep exactly the lock targets the site declares today, in `targetBundleURL` and `additionalLockedBundleURLs`. Add none and remove none. | Lock scope is a reviewed decision (Rule 3). |
| Build `cliCommand` inside the helper from the same values the run uses, with the existing builder. | The helper's tests then cover the builder too. |
| Call `launch` only for `.started`. | A refused row launches nothing and changes nothing. |
| Default `reporter` to `OperationCenter.shared`. | Production call sites stay short, and tests pass their own reporter. |

`scripts/ratchets/file-size.sh` lets no file listed in `scripts/ratchets/file-size.baseline` grow, and no other Swift file pass 800 lines. Keep the helper beside its launch site only when that file is not in the baseline and stays at or under 800 lines. Otherwise put it in a sibling file in the same folder named `<Type>+OperationBegin.swift`. One sibling can hold the helpers of several launch-site files of its type. `InspectorViewController+OperationBegin.swift` holds the primer-trim, filter and annotation helpers for the baselined `InspectorViewController+TrimDuplicateWorkflows.swift`, while the variant-calling helpers stay in `InspectorViewController+VariantWorkflow.swift`, which is not baselined. Batches that run at the same time never create the same new file, so when another running batch also migrates sites of your type, name the sibling after your launch-site file, `<Type>+<Feature>OperationBegin.swift` for `<Type>+<Feature>.swift`. Lower the baseline with `python3 scripts/ratchets/file-size.sh --update` when your files shrank, and never use it to raise one.

### 2. Move the launch into the closure

At the call site, everything that starts work goes inside the closure. That covers the running flag in the view model, the activity indicator, the `Task`, the runner and `setCancelCallback`. A pre-check that only shows an alert, such as `canStartOperation`, stays before the call. Inside the closure, progress and terminal calls may keep using `OperationCenter.shared`, the object production passes as `reporter`, until the Phase 3 launcher replaces them.

```swift
Self.beginPrimerTrimOperation(
    title: "Primer-trimming with \(scheme.manifest.displayName)",
    bundleURL: bundleURL,
    cliArguments: cliArguments,
    routeContext: operationRouteContext(for: bundleURL)
) { opID in
    let runner = CLIPrimerTrimRunner()
    let task = Task(priority: .userInitiated) { /* run, then complete or fail opID */ }
    OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
}
```

A call site that must undo its own state on refusal switches on the returned result. `TaxonomyReadExtractionAction` returns its dialog to idle that way. A `var` that the closure hands to a detached task becomes a `let` before the call, or strict concurrency rejects the capture.

An async service entry point that returns a value takes `reporter` as a parameter and sends every report through it. It ends its `begin` call with `.requireStarted()`, which returns the operation ID or throws `OperationRefusedError` on `.refused`. `ReferenceBundleMergeRoute.merge` is the model.

### 3. Make the command reproduce the run

The recorded command is the `lungfish-cli` invocation built from the configuration the GUI executes. When today's command leaves out a flag the run uses, fix the builder. The Kraken2 BLAST command gained `--result-dir`, and the classifier bundle extraction now names its `-o` file inside the project's Extractions folder, where the app writes the bundle. When no CLI command reproduces the run, record nil and put the marker `cli-parity-gap: <ID>` in the helper's doc comment, with the closest command and why it falls short. Never record a descriptive text, a note or another program's command. Never invent a command. `docs/contracts/CLI-EQUIVALENCE.md` lists the rules and the ratchet that counts the gaps.

### 4. Test the site

Put the tests in Tests/LungfishAppTests, one file per migrated source file, named after it with an `OperationTests` suffix (for example `InspectorVariantWorkflowOperationTests.swift`). The file imports LungfishKitTestSupport for the recording reporter and uses `@testable import LungfishCLI` for the parse. No test touches `OperationCenter.shared`.

| Test | Applies to | How |
|---|---|---|
| Refused lock launches nothing | sites that declare a lock | Make a fresh `OperationCenter()` hold the lock through its own `begin`. Pass that center as `reporter` with a launch closure that sets a flag. Assert `.refused` and that the flag is still false. |
| Recorded row | every site | Call the helper with a `RecordingOperationReporter()`. Assert that the launch closure received the item's ID and that `operationType`, `targetBundleURL` and `additionalLockedBundleURLs` match today's values. |
| Command parses | sites with a CLI equivalent | `RecordedCLICommand.parse(_:as:)` splits the recorded string, applies the shipped binary's argument normalization and runs `LungfishCLI.parseAsRoot`. `RecordedCLICommand.parseScript(_:)` does the same for each line of a command script. Assert that the parsed values equal the run's configuration. |
| Parity gap pinned | sites with no CLI equivalent | Assert `assertCLIParityGap(item.cliCommand, id: "<ID>")` with the ID of the helper's marker. It checks that the row records nil. A CLI command added later fails this test, which prompts a parse test and a replay test in its place. |

A real held lock proves the site declares the lock it should. `RecordingOperationReporter(lockHeldBy:)` refuses every `begin` instead, which suits a site with no lock whose refusal branch still needs a test, such as the merge service's `OperationRefusedError`. A test of the Operations panel itself needs only a row to update, complete or fail. It calls `begin` on a fresh `OperationCenter()` and reads `rowID` from LungfishKitTestSupport, which is the started row's ID or the refused row's ID.

### 5. Check the change

Run `python3 scripts/ratchets/unchecked-operation-start.sh`, which stays as a guard and must report 0. Run the new test file and the existing suites for the feature, one `swift test` at a time.

### The exemplar sites

| Shape of site | Model | File |
|---|---|---|
| `lungfish-cli` runner with a bundle lock | `beginPrimerTrimOperation` in a sibling file, `beginVariantCallingOperation` beside its launch site | `Sources/LungfishApp/Views/Inspector/InspectorViewController+OperationBegin.swift` and `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` |
| In-process service with a bundle lock and a new command builder | `beginFilteredAlignmentWorkflowOperation` and `beginMappedReadsAnnotationWorkflowOperation` | `Sources/LungfishApp/Views/Inspector/InspectorViewController+OperationBegin.swift` |
| No lock, and the old command missed a flag the run used | `beginKraken2BlastVerificationOperation` | `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift` |
| No lock and no CLI equivalent | `beginTaxaCollectionExtractionOperation` | `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift` |
| Async service entry point that returns a value | `ReferenceBundleMergeRoute.merge` with `requireStarted()` | `Sources/LungfishApp/Services/ReferenceBundleMergeRoute.swift` |
| Command built by the caller and reused as provenance, with the dialog reset on refusal | `beginExtractionOperation` | `Sources/LungfishApp/Views/Metagenomics/TaxonomyReadExtractionAction+OperationBegin.swift` |

The protocol is in `Sources/LungfishKit/OperationReporting.swift`, the recording reporter in `Tests/Support/LungfishKitTestSupport/RecordingOperationReporter.swift` and the parse helper in `Tests/LungfishAppTests/RecordedCLICommand.swift`.

## What changes later in the program

Phase 2 added one process primitive, `ToolProcess`, in sub-phase 2.2, and sub-phase 2.4 stopped LGE writing a bare `WorkflowRun` or a run nested in an envelope. The rest of Phase 2 adds a shared run executor that owns the analysis-directory lifecycle. Sub-phase 2.7 rebuilds the `ProvenanceRecorder` actor in `Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift` on `ProvenanceRunBuilder` beside the executor, and the ToolProcess observer hook feeds it. `docs/contracts/RECORDING-PROVENANCE.md` says what each step covers and what is deferred. Phase 3 adds an `OperationSpec` value and an `OperationLauncher` that becomes the only caller of `begin`. When those land, this document is rewritten around them, and the rules above stay true.
