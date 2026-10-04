# Adding an operation

This contract binds all new work in Lungfish Genome Explorer (LGE). Part of the contracts index in `docs/contracts/README.md`. Findings R3, R4 and R8 in `docs/reports/2026-10-02-architecture-review/REVIEW.md` explain why each rule exists.

An operation is anything that runs a tool or writes scientific output on behalf of the user. Every operation has one implementation in LungfishWorkflow, one CLI command that drives it, and a thin GUI launcher that runs that CLI command as a subprocess and mirrors its progress into the Operations panel. The GUI never runs the tool itself.

This document first traces one real operation, variant calling, from menu item to bundle on disk. It then states the rules every new operation must meet. Where today's variant-calling code falls short of a rule, the trace says so and names the code that already meets it.

## The variant-calling path, traced through the code

The table follows the calls in order. Every file was read for this trace. Line numbers are correct as of commit a0eec8b32 and drift with edits, so search for the named function when a number is stale.

| Step | What happens | File |
|---|---|---|
| 1. Menu entry | The Tools menu action calls `presentVariantCallingDialog(bundle:preferredAlignmentTrackID:)` on the Inspector. The Inspector's Analysis section reaches the same method through `runCallVariantsWorkflow()`. | `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` and `Sources/LungfishApp/Views/Inspector/InspectorViewController+MetadataImport.swift` |
| 2. Eligibility and lock pre-check | `presentVariantCallingDialog` asks `BAMVariantCallingEligibility` for analysis-ready BAM tracks, checks `OperationCenter.shared.canStartOperation(on:)`, then presents the dialog. | `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` and `Sources/LungfishApp/Views/BAM/BAMVariantCallingEligibility.swift` |
| 3. Dialog | `BAMVariantCallingDialogPresenter` shows the sheet. `BAMVariantCallingDialogState` collects choices and exposes `pendingRequest`, a `BundleVariantCallingRequest`. | `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogPresenter.swift` and `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift` |
| 4. Request type | `BundleVariantCallingRequest` is a plain `Sendable` value owned by Workflow, so the GUI and the CLI describe a run with the same type. | `Sources/LungfishWorkflow/Variants/BundleVariantCallingModels.swift` |
| 5. argv and command string | `launchVariantCallingOperation(state:)` builds argv once with `CLIVariantCallingRunner.buildCLIArguments(request:)` and passes that array to `beginVariantCallingOperation`, which builds the displayed command from it with `OperationCenter.buildCLICommand(subcommand:args:)`. | `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` and `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift` |
| 6. Operations panel row | `beginVariantCallingOperation(title:detail:bundleURL:cliArguments:routeContext:reporter:launch:)` calls `begin` on an `OperationReporting`, passing `.variantCalling`, the bundle as lock target and the command. It calls its `launch` closure only when the row started, and that closure creates the runner. The pre-check in step 2 stays as the friendly alert. | `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` and `Sources/LungfishKit/OperationReporting.swift` |
| 7. Subprocess | `CLIVariantCallingRunner.run(arguments:onEvent:)` hands argv to `CLISubprocessTransport.run(arguments:isCancelled:onEvent:)`, which finds the binary through `CLIBinaryLocator`, launches it with the managed storage environment, and decodes each stdout line as a `CLIEvent`. | `Sources/LungfishKit/CLISubprocessTransport.swift` and `Sources/LungfishKit/CLIBinaryLocator.swift` |
| 8. Event schema | `CLIEvent` has six cases (`start`, `progress`, `log`, `output`, `complete`, `failed`). The transport folds `complete` into its return value and `failed` into a thrown error, so a caller cannot forget either. | `Sources/LungfishWorkflow/CLIEvents/CLIEvent.swift` |
| 9. Progress into the panel | The launcher's `onEvent` closure hops to the main thread with `DispatchQueue.main.async` and `MainActor.assumeIsolated`, then `applyVariantCallingEvent(_:operationID:)` calls both `OperationCenter.shared.update` and `OperationCenter.shared.log`. | `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` |
| 10. Cancel | `OperationCenter.shared.setCancelCallback(for:)` cancels the Swift task and calls `runner.cancel()`, which forwards to the transport's `nonisolated` cancel so it never queues behind the running `run`. | `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift` |
| 11. CLI registration | `VariantsCommand` is listed in the root command's subcommands. `CallSubcommand` defines `lungfish-cli variants call` and its options. | `Sources/LungfishCLI/LungfishCLI.swift` and `Sources/LungfishCLI/Commands/VariantsCommand.swift` |
| 12. CLI execution | `CallSubcommand.execute(runtime:emitEvent:)` resolves the alignment track, reads any primer-trim attestation, builds the same `BundleVariantCallingRequest`, then runs `Runtime.live()`. That runtime checks tools with `NativeToolRunner.shared.findTool` and validates inputs with `BAMVariantCallingPreflight`. | `Sources/LungfishCLI/Commands/VariantsCommand.swift` and `Sources/LungfishWorkflow/Variants/BAMVariantCallingPreflight.swift` |
| 13. Workflow service | `ViralVariantCallingPipeline.run(progress:)` runs the caller through `NativeToolRunner`, normalizes the VCF and records one `VariantCallingProvenanceStep` per tool. `VariantSQLiteImportCoordinator.importNormalizedVCF` builds the SQLite store. | `Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift` and `Sources/LungfishWorkflow/Variants/VariantSQLiteImportCoordinator.swift` |
| 14. Output bundle | `BundleVariantTrackAttachmentService.attach(request:)` moves the VCF.gz, its tabix index and the SQLite database into the bundle's `variants/` folder and saves the bundle manifest atomically. | `Sources/LungfishWorkflow/Variants/BundleVariantTrackAttachmentService.swift` |
| 15. Provenance | The same service's `writeWorkflowProvenance` builds a `WorkflowRun` from the CLI's `VariantCallingWorkflowProvenance` and writes `variants/<basename>.lungfish-provenance.json` with `WorkflowRun.writeSidecar(to:)`. Readers load it through `ProvenanceEnvelopeReader`, which converts it with `canonicalEnvelope()`. | `Sources/LungfishWorkflow/Variants/BundleVariantTrackAttachmentService.swift`, `Sources/LungfishWorkflow/Provenance/ProvenanceRecord.swift` and `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelopeReader.swift` |
| 16. Events on the wire | With `--format json` the command encodes its internal `VariantCallingEvent` values as `CLIEvent` in `cliEvent(from:)`. Completion carries `[databasePath, vcfPath, tbiPath]` as outputs and a `trackID=... trackName=...` message, which `CLIVariantCallingRunner.parseCompletion` reads back. | `Sources/LungfishCLI/Commands/VariantsCommand.swift` and `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift` |
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

Variant calling is the recommended example because its layering is right. It still has two gaps, and a new operation must not copy them.

| Gap | Rule it breaks | Copy this instead |
|---|---|---|
| Its `onEvent` closure and `applyVariantCallingEvent` repeat the event-to-panel mapping by hand. | Rule 8 | `OperationCenterCLIBridge.onEvent(operationID:)` in `Sources/LungfishApp/Services/OperationCenterCLIBridge.swift`, used by `Sources/LungfishApp/Services/CLITreeRunner.swift` |
| It writes the legacy `WorkflowRun` sidecar shape, not a `ProvenanceEnvelope`. | Rule 6 | `CLIProvenanceSupport.recordSingleStepRun` in `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift`, which builds with `ProvenanceRunBuilder` and writes with `ProvenanceWriter` |

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
| 1. Menu entry | `ToolsMenuModel.build` starts from `WorkflowLibraryCatalog.builtIn`, which maps over `FASTQOperationToolID.allCases`. `MainMenu.operationMenuItems(for:)` adds one item per tool listed by `FASTQOperationDialogState.toolIDs(for:)`. Every item calls `launchFASTQOperationToolFromMenu`, which opens `showFASTQOperationsDialog` with the tool preselected. No menu item is written by hand. | `Sources/LungfishApp/App/ToolsMenuModel.swift`, `Sources/LungfishApp/Services/WorkflowLibrary.swift` line 165, `Sources/LungfishApp/App/MainMenu.swift` line 983, `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` line 85 |
| 2. Dialog and request | The Savont pane collects settings. `launchRequestForSelectedTool()` returns `FASTQOperationLaunchRequest.savont`, which the dialog exposes as `pendingLaunchRequest`. | `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift` and `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift` line 455 |
| 3. Launcher | The dialog's completion hands the request to `runFASTQOperationLaunchRequest`, which registers a `.fastqOperation` row with `beginFASTQLaunchRequestOperation` and calls `trackAnalysisOutput`. The row's command names `<derived>` for the output until the run succeeds, and then `FASTQOperationRowCommand` refines it with `setCommand`, as `docs/contracts/CLI-EQUIVALENCE.md` describes. | `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift`, `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift` and `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplayOperationBegin.swift` |
| 4. Plan | `FASTQOperationPlanner` picks the output mode, makes one execution plan per input with `makeExecutionPlans`, and later finds outputs with `discoverOutputs`. | `Sources/LungfishApp/Services/FASTQOperationPlanner.swift` |
| 5. argv | `FASTQOperationCLIInvocationBuilder.buildInvocation` turns the request into `lungfish-cli fastq savont-cluster` arguments. The launcher builds the displayed command from the same invocation. | `Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift` |
| 6. Subprocess | `FASTQOperationExecutionService.execute` materializes inputs, runs each invocation through `LungfishCLIProcessRunner`, and decodes `CLIEvent` lines. That runner finds the binary with `LungfishCLIRunner.findCLI` and starts its own `Process`. It does not use `CLISubprocessTransport`. | `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift` lines 774 and 800 |
| 7. Import | `BundleFASTQOperationImporter` turns the discovered outputs into project bundles. | `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift` line 438 |

Some tools leave this path early in `showFASTQOperationsDialog`, and none of them is a model for new work. Mapping tools (minimap2, BWA-MEM2, Bowtie2, BBMap) set `pendingMappingRequest`, and `runManagedMapping` in `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` still runs `ManagedMappingPipeline` in process, which breaks Rule 9 (finding R3). The classifiers set their own pending configurations and run through `Sources/LungfishApp/App/AppDelegate+Classification.swift`, and Viral Recon runs through `Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift`. Workflow Library items with the `.workflowOperations` capability (ONT genotyping, full-length ONT MHC genotyping, 12S amplicon matching) open the Workflow Operations window and run through `WorkflowOperationExecutionService` in `Sources/LungfishApp/Services/WorkflowOperationExecutionService.swift`, which also starts its own `Process`.

### What a new FASTQ-input tool adds

| Piece | File | What to add |
|---|---|---|
| Tool identity | `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift` | a `FASTQOperationToolID` case and its arms. Bowtie2 has 14 switch arms (9 in the enum's own properties, 2 in the dialog state, 3 in the panes file) plus one entry in `toolIDs(for:)`. A switch with a `default` arm compiles without the new case, so search for an existing tool's case and add the new one beside every hit. |
| Menu placement | `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift` | the tool in `toolIDs(for:)` for its category, which is what puts it in the Tools menu and the dialog sidebar |
| Category | `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift` | an existing `FASTQOperationCategoryID`. A new category also needs `title` and `requiredPackIDs` arms there, a `toolIDs(for:)` arm, and a `menuTitle` arm in `Sources/LungfishApp/App/ToolsMenuModel.swift` |
| Settings pane | `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift` | an arm in `FASTQOperationToolPanes.body` and in the primary and advanced settings sections. A tool with a large form embeds its own sheet there, as mapping embeds `MappingWizardSheet` |
| Request and argv | `FASTQOperationLaunchRequest` in `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift` and `Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift` | a request case and its invocation |
| Outputs | `Sources/LungfishApp/Services/FASTQOperationPlanner.swift` and `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift` | the output mode, output discovery and import arms |

### The known gap in the FASTQ family

`LungfishCLIProcessRunner` and the Workflow Operations runner each build their own `Process`, apart from `CLISubprocessTransport`. Finding R7 records this, and Phase 2 (task 2a, the `ToolProcess` primitive) retires it. A new tool in the FASTQ family inherits this runner until then. A new standalone runner never copies it. It runs `lungfish-cli` through `CLISubprocessTransport` as Rule 9 requires.

## Rules

Each rule is a requirement. A reviewer rejects a change that breaks one. The column on the right names the code that shows the rule done correctly today.

| Rule | Requirement | Reference |
|---|---|---|
| 1. Register with `begin` | Register the row with `begin` on an `OperationReporting`, which production code defaults to `OperationCenter.shared`. Switch on the result, and launch nothing (no subprocess, no bundle write) unless it is `.started`. The `.refused` case already shows a visible "Bundle is busy" row. Put the call in a begin helper with a launch closure, as "Registering an operation with begin()" below describes, so a test can check it. | `Sources/LungfishKit/OperationReporting.swift`, `beginVariantCallingOperation` in `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` |
| 2. Type and command always passed | Pass an explicit `operationType` and a `cliCommand` on every call. Neither `OperationCenter.begin` nor the `begin` that `OperationReporting` adds has a default for either, so the compiler catches an omission. The command is non-nil whenever a CLI command reproduces the run. A run that none reproduces passes `nil` explicitly, names the closest command in its helper's doc comment and pins the gap with a test, as "Registering an operation with begin()" below describes. Build `cliCommand` with `OperationCenter.buildCLICommand(subcommand:args:)` from the exact argv array you execute, and add an `OperationType` case if none fits. | `OperationType` and `buildCLICommand` in `Sources/LungfishKit/OperationCenter.swift` |
| 3. Lock scope declared | Pass the bundle the operation writes as `targetBundleURL` (exact lock). Pass every other bundle it writes, or whose contents must not change mid-run, in `additionalLockedBundleURLs` (whole-tree lock). An operation that writes no bundle says so in review. | `insertOperation` in `Sources/LungfishKit/OperationCenter.swift` |
| 4. Analysis directory created without `try?` | Create an `Analyses/` result folder with `AnalysesFolder.createAnalysisDirectory(tool:in:isBatch:date:command:)` inside a `do` block and fail the operation when it throws. A `try?` hides the error and the run writes somewhere unexpected. On failure or cancel, call `AnalysesFolder.discardFailedAnalysisDirectory`. | `Sources/LungfishIO/Bundles/AnalysesFolder.swift`, called through `MappingResultLayoutService.createAnalysisDirectory` in `Sources/LungfishCLI/Commands/MapCommand.swift` |
| 5. Analysis directory tracked and completed | The CLI or Workflow producer calls `AnalysesFolder.markAnalysisComplete` as its last successful step. The GUI launcher calls `OperationCenter.shared.trackAnalysisOutput(_:for:)` for the folder. Without both, the run record stays and the sidebar hides the result. | `Sources/LungfishCLI/Commands/MapCommand.swift`, `trackAnalysisOutput` in `Sources/LungfishKit/OperationCenter.swift`, `Sources/LungfishCore/Services/AnalysisRunRecord.swift` |
| 6. Provenance through the envelope | Write a `ProvenanceEnvelope` with `ProvenanceRunBuilder` and `ProvenanceWriter` (or `CLIProvenanceSupport.recordSingleStepRun` from a CLI command). Record argv, resolved defaults, tool version, runtime identity, input and output checksums, exit status and wall time. Use `ProvenanceRecorder.provenanceFilename` or `ProvenanceRecorder.fileSidecarURL(for:)`. Never add a new sidecar filename or a private `writeProvenance` copy. | `Sources/LungfishWorkflow/Provenance/ProvenanceRunBuilder.swift`, `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift`, `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift` |
| 7. Virtual FASTQ materialized first | A derived FASTQ bundle holds only `preview.fastq` (about 1,000 reads). Before any tool sees FASTQ input, check `SequenceInputResolver.unmaterializedDerivedBundleURL(for:)` and materialize with `FASTQCLIMaterializer`. Never pass `FASTQBundle.resolvePrimaryFASTQURL` output straight to a tool. | `Sources/LungfishIO/Formats/Common/SequenceInputResolver.swift`, `Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift`, its use in `Sources/LungfishCLI/Commands/MapCommand.swift` |
| 8. One event schema, one bridge | The CLI command emits `CLIEvent` lines through `CLIEventEmitter` when asked for JSON. The GUI decodes them in `CLISubprocessTransport` and maps them with `OperationCenterCLIBridge`, which calls both `update` and `log` so the expanded row keeps its history. Never declare a private NDJSON event struct. | `Sources/LungfishWorkflow/CLIEvents/CLIEvent.swift`, `Sources/LungfishApp/Services/OperationCenterCLIBridge.swift` |
| 9. CLI parity | The GUI runs the CLI command as a subprocess and never calls `NativeToolRunner`, `CondaManager` or a pipeline type in process. A standalone runner uses `CLISubprocessTransport`. A FASTQ-family tool goes through `FASTQOperationExecutionService` until Phase 2 replaces its runner. Both paths produce the same output tree and provenance. The displayed command reproduces the GUI result when pasted into a terminal. The recorded command meets `docs/contracts/CLI-EQUIVALENCE.md`. | `Sources/LungfishApp/Services/CLITreeRunner.swift`, `Tests/LungfishAppTests/CLIRunnerArgvRoundTripTests.swift` |
| 10. Registered and tested | Add or update the feature entry in `docs/user-manual/features.yaml` with every source file, including the launcher. Add an argv round-trip test, a CLI test, and a Workflow test on a fixture whose expected output is checked by value. Add a replay test that runs the recorded command on a copy of the fixture and compares the two results with `OutputEquivalence.assertSame`, as `docs/contracts/CLI-EQUIVALENCE.md` describes. | the tests listed in the trace above |
| 11. Provenance policy registered | A new top-level CLI command goes in `ScientificProvenancePolicy.canonicalCLICommandNames` and gets a `cliCommandPolicies` entry, or `ScientificCLIProvenanceCoverageTests` fails. A command that writes no scientific data is instead added to that test's non-scientific set with a reason. A subcommand that needs its own policy goes in `cliCommandPathPolicies`. A new `NativeTool` case needs a `nativeToolPolicies` entry, or every `NativeToolRunner.run` call for it throws `missingProvenancePolicy` (`requireProvenancePolicy`, line 1145). | `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift`, `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`, `Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift` |

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
| Tool availability | the lock manifest `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`, and either a `NativeTool` case in `Sources/LungfishWorkflow/Native/NativeToolRunner.swift` or a conda environment run through `Sources/LungfishWorkflow/Conda/CondaManager.swift` (Phase 2 replaces both with one tool descriptor) |
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

An async service entry point that returns a value takes `reporter` as a parameter and sends every report through it. It ends its `begin` call with `.requireStarted()`, which returns the operation ID or throws `OperationRefusedError` on `.refused`. `ReferenceBundleMergeService.merge` is the model.

### 3. Make the command reproduce the run

The recorded command is the `lungfish-cli` invocation built from the configuration the GUI executes. When today's command leaves out a flag the run uses, fix the builder. The Kraken2 BLAST command gained `--result-dir`, and the classifier bundle extraction now names its `-o` file inside the project's Extractions folder, where the app writes the bundle. When no CLI command reproduces the run, record nil and put the marker `cli-parity-gap: <ID>` in the helper's doc comment, with the closest command and why it falls short. Never record a descriptive text, a note or another program's command. Never invent a command. `docs/contracts/CLI-EQUIVALENCE.md` lists the rules and the ratchet that counts the gaps.

### 4. Test the site

Put the tests in Tests/LungfishAppTests, one file per migrated source file, named after it with an `OperationTests` suffix (for example `InspectorVariantWorkflowOperationTests.swift`). The file imports LungfishKitTestSupport for the recording reporter and uses `@testable import LungfishCLI` for the parse. No test touches `OperationCenter.shared`.

| Test | Applies to | How |
|---|---|---|
| Refused lock launches nothing | sites that declare a lock | Make a fresh `OperationCenter()` hold the lock through its own `begin`. Pass that center as `reporter` with a launch closure that sets a flag. Assert `.refused` and that the flag is still false. |
| Recorded row | every site | Call the helper with a `RecordingOperationReporter()`. Assert that the launch closure received the item's ID and that `operationType`, `targetBundleURL` and `additionalLockedBundleURLs` match today's values. |
| Command parses | sites with a CLI equivalent | `RecordedCLICommand.parse(_:as:)` splits the recorded string, applies the shipped binary's argument normalization and runs `LungfishCLI.parseAsRoot`. `RecordedCLICommand.parseScript(_:)` does the same for each line of a command script. Assert that the parsed values equal the run's configuration. |
| Parity gap pinned | sites with no CLI equivalent | Assert `XCTAssertNil(item.cliCommand)` and `assertCLIParityGap(item.cliCommand, id: "<ID>")` with the ID of the helper's marker. A CLI command added later fails this test, which prompts a parse test and a replay test in its place. |

A real held lock proves the site declares the lock it should. `RecordingOperationReporter(lockHeldBy:)` refuses every `begin` instead, which suits a site with no lock whose refusal branch still needs a test, such as the merge service's `OperationRefusedError`. A test of the Operations panel itself needs only a row to update, complete or fail. It calls `begin` on a fresh `OperationCenter()` and reads `rowID` from LungfishKitTestSupport, which is the started row's ID or the refused row's ID.

### 5. Check the change

Run `python3 scripts/ratchets/unchecked-operation-start.sh`, which stays as a guard and must report 0. Run the new test file and the existing suites for the feature, one `swift test` at a time.

### The exemplar sites

| Shape of site | Model | File |
|---|---|---|
| `lungfish-cli` runner with a bundle lock | `beginPrimerTrimOperation` in a sibling file, `beginVariantCallingOperation` beside its launch site | `Sources/LungfishApp/Views/Inspector/InspectorViewController+OperationBegin.swift` and `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` |
| In-process service with a bundle lock and a new command builder | `beginFilteredAlignmentWorkflowOperation` and `beginMappedReadsAnnotationWorkflowOperation` | `Sources/LungfishApp/Views/Inspector/InspectorViewController+OperationBegin.swift` |
| Bundle lock with no CLI equivalent | `beginGATKVariantCallingOperation` | `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` |
| No lock, and the old command missed a flag the run used | `beginKraken2BlastVerificationOperation` | `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift` |
| No lock and no CLI equivalent | `beginTaxaCollectionExtractionOperation` | `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift` |
| Async service entry point that returns a value | `ReferenceBundleMergeService.merge` with `requireStarted()` | `Sources/LungfishApp/Services/ReferenceBundleMergeService.swift` |
| Command built by the caller and reused as provenance, with the dialog reset on refusal | `beginExtractionOperation` | `Sources/LungfishApp/Views/Metagenomics/TaxonomyReadExtractionAction+OperationBegin.swift` |

The protocol is in `Sources/LungfishKit/OperationReporting.swift`, the recording reporter in `Tests/Support/LungfishKitTestSupport/RecordingOperationReporter.swift` and the parse helper in `Tests/LungfishAppTests/RecordedCLICommand.swift`.

## What changes later in the program

Phase 2 adds a shared run executor that owns the analysis-directory lifecycle and one process primitive, and it reduces provenance writing to one API on the existing `ProvenanceRecorder` actor in `Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift` that writes the envelope only. Phase 3 adds an `OperationSpec` value and an `OperationLauncher` that becomes the only caller of `begin`. When those land, this document is rewritten around them, and the rules above stay true.
