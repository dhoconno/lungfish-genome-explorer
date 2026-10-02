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
| 5. argv and command string | `launchVariantCallingOperation(state:)` builds argv once with `CLIVariantCallingRunner.buildCLIArguments(request:)` and builds the displayed command from that same array with `OperationCenter.buildCLICommand(subcommand:args:)`. | `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` and `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift` |
| 6. Operations panel row | The launcher registers the row with `OperationCenter.shared.start(title:detail:operationType:targetBundleURL:cliCommand:routeContext:)`, passing `.variantCalling` and the bundle as lock target. This is the deprecated `start`, guarded by the hand-written pre-check in step 2 (see the gaps below). | `Sources/LungfishKit/OperationCenter.swift` |
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
| `Tests/LungfishAppTests/BAMVariantCallingDialogRoutingTests.swift` | the dialog routes to the right launcher |
| `Tests/LungfishCLITests/VariantsCommandTests.swift` and `Tests/LungfishCLITests/VariantsCallAlignmentTrackResolutionTests.swift` | CLI options, event stream and track resolution |
| `Tests/LungfishWorkflowTests/Variants/ViralVariantCallingPipelineTests.swift` and `Tests/LungfishWorkflowTests/Variants/BundleVariantTrackAttachmentServiceTests.swift` | the pipeline and the bundle write, including provenance |
| `Tests/LungfishIntegrationTests/ReadsToVariantsEndToEndTests.swift` | reads to variants through real tools |

### Where today's path falls short of the rules

Variant calling is the recommended example because its layering is right. It still has four gaps, and a new operation must not copy them.

| Gap | Rule it breaks | Copy this instead |
|---|---|---|
| It calls the deprecated `OperationCenter.shared.start` with a bundle target and relies on a separate `canStartOperation` pre-check. `scripts/ratchets/unchecked-operation-start.sh` counts such sites. | Rule 1 | `runIQTreeInferenceViaCLI` in `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` calls `begin` and switches on `.started` before creating `CLITreeRunner` |
| Its `onEvent` closure and `applyVariantCallingEvent` repeat the event-to-panel mapping by hand. | Rule 8 | `OperationCenterCLIBridge.onEvent(operationID:)` in `Sources/LungfishApp/Services/OperationCenterCLIBridge.swift`, used by `Sources/LungfishApp/Services/CLITreeRunner.swift` |
| It writes the legacy `WorkflowRun` sidecar shape, not a `ProvenanceEnvelope`. | Rule 6 | `CLIProvenanceSupport.recordSingleStepRun` in `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift`, which builds with `ProvenanceRunBuilder` and writes with `ProvenanceWriter` |
| The `variants.call` entry in `docs/user-manual/features.yaml` names `InspectorViewController.swift`, but the launcher lives in the `+VariantWorkflow` extension. | Rule 10 | list the file that holds the launcher |

## Rules

Each rule is a requirement. A reviewer rejects a change that breaks one. The column on the right names the code that shows the rule done correctly today.

| Rule | Requirement | Reference |
|---|---|---|
| 1. `begin`, never `start` | Register the row with `OperationCenter.shared.begin(...)`, switch on the result, and launch nothing (no subprocess, no bundle write) unless it is `.started`. The `.refused` case already shows a visible "Bundle is busy" row. | `begin` in `Sources/LungfishKit/OperationCenter.swift`, `runIQTreeInferenceViaCLI` in `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` |
| 2. Type and command always passed | Pass an explicit `operationType` and a non-nil `cliCommand` on every call. Both still have defaults (`.download` and `nil`), so the compiler will not catch an omission. Build `cliCommand` with `OperationCenter.buildCLICommand(subcommand:args:)` from the exact argv array you execute, and add an `OperationType` case if none fits. | `OperationType` and `buildCLICommand` in `Sources/LungfishKit/OperationCenter.swift` |
| 3. Lock scope declared | Pass the bundle the operation writes as `targetBundleURL` (exact lock). Pass every other bundle it writes, or whose contents must not change mid-run, in `additionalLockedBundleURLs` (whole-tree lock). An operation that writes no bundle says so in review. | `insertOperation` in `Sources/LungfishKit/OperationCenter.swift` |
| 4. Analysis directory created without `try?` | Create an `Analyses/` result folder with `AnalysesFolder.createAnalysisDirectory(tool:in:isBatch:date:command:)` inside a `do` block and fail the operation when it throws. A `try?` hides the error and the run writes somewhere unexpected. On failure or cancel, call `AnalysesFolder.discardFailedAnalysisDirectory`. | `Sources/LungfishIO/Bundles/AnalysesFolder.swift`, called through `MappingResultLayoutService.createAnalysisDirectory` in `Sources/LungfishCLI/Commands/MapCommand.swift` |
| 5. Analysis directory tracked and completed | The CLI or Workflow producer calls `AnalysesFolder.markAnalysisComplete` as its last successful step. The GUI launcher calls `OperationCenter.shared.trackAnalysisOutput(_:for:)` for the folder. Without both, the run record stays and the sidebar hides the result. | `Sources/LungfishCLI/Commands/MapCommand.swift`, `trackAnalysisOutput` in `Sources/LungfishKit/OperationCenter.swift`, `Sources/LungfishCore/Services/AnalysisRunRecord.swift` |
| 6. Provenance through the envelope | Write a `ProvenanceEnvelope` with `ProvenanceRunBuilder` and `ProvenanceWriter` (or `CLIProvenanceSupport.recordSingleStepRun` from a CLI command). Record argv, resolved defaults, tool version, runtime identity, input and output checksums, exit status and wall time. Use `ProvenanceRecorder.provenanceFilename` or `ProvenanceRecorder.fileSidecarURL(for:)`. Never add a new sidecar filename or a private `writeProvenance` copy. | `Sources/LungfishWorkflow/Provenance/ProvenanceRunBuilder.swift`, `Sources/LungfishWorkflow/Provenance/ProvenanceWriter.swift`, `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift` |
| 7. Virtual FASTQ materialized first | A derived FASTQ bundle holds only `preview.fastq` (about 1,000 reads). Before any tool sees FASTQ input, check `SequenceInputResolver.unmaterializedDerivedBundleURL(for:)` and materialize with `FASTQCLIMaterializer`. Never pass `FASTQBundle.resolvePrimaryFASTQURL` output straight to a tool. | `Sources/LungfishIO/Formats/Common/SequenceInputResolver.swift`, `Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift`, its use in `Sources/LungfishCLI/Commands/MapCommand.swift` |
| 8. One event schema, one bridge | The CLI command emits `CLIEvent` lines through `CLIEventEmitter` when asked for JSON. The GUI decodes them in `CLISubprocessTransport` and maps them with `OperationCenterCLIBridge`, which calls both `update` and `log` so the expanded row keeps its history. Never declare a private NDJSON event struct. | `Sources/LungfishWorkflow/CLIEvents/CLIEvent.swift`, `Sources/LungfishApp/Services/OperationCenterCLIBridge.swift` |
| 9. CLI parity | The GUI runs the CLI command through `CLISubprocessTransport` and never calls `NativeToolRunner`, `CondaManager` or a pipeline type in process. Both paths produce the same output tree and provenance. The displayed command reproduces the GUI result when pasted into a terminal. | `Sources/LungfishApp/Services/CLITreeRunner.swift`, `Tests/LungfishAppTests/CLIRunnerArgvRoundTripTests.swift` |
| 10. Registered and tested | Add or update the feature entry in `docs/user-manual/features.yaml` with every source file, including the launcher. Add an argv round-trip test, a CLI test, and a Workflow test on a fixture whose expected output is checked by value. | the tests listed in the trace above |

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
| Request type and service | new `FooRequest` and `FooPipeline` types in a domain folder under `Sources/LungfishWorkflow/` |
| Tool availability | the lock manifest `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`, and either a `NativeTool` case in `Sources/LungfishWorkflow/Native/NativeToolRunner.swift` or a conda environment run through `Sources/LungfishWorkflow/Conda/CondaManager.swift` (Phase 2 replaces both with one tool descriptor) |
| CLI command | a new `FooCommand` in `Sources/LungfishCLI/Commands/`, registered in `Sources/LungfishCLI/LungfishCLI.swift` |
| Operation type | a case in `OperationType` in `Sources/LungfishKit/OperationCenter.swift` if none fits |
| GUI runner and launcher | a new `CLIFooRunner` in `Sources/LungfishApp/Services/` modeled on `Sources/LungfishApp/Services/CLITreeRunner.swift`, plus a launcher in the owning leaf or App extension (see `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md`) |
| Result recognition | the tool tables listed in `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md` until Phase 2 replaces them |
| Registry and tests | `docs/user-manual/features.yaml`, plus tests under `Tests/LungfishWorkflowTests`, `Tests/LungfishCLITests` and `Tests/LungfishAppTests` |

## What changes later in the program

Phase 1 removes the `operationType` and `cliCommand` defaults and migrates the remaining `start` calls. Phase 2 adds a shared run executor that owns the analysis-directory lifecycle and one process primitive, and it reduces provenance writing to one API on the existing `ProvenanceRecorder` actor in `Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift` that writes the envelope only. Phase 3 adds an `OperationSpec` value and an `OperationLauncher` that becomes the only caller of `begin`. When those land, this document is rewritten around them, and the rules above stay true.
