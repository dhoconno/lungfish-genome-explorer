# Architecture

This is the narrative map of the Lungfish Genome Explorer (LGE) source tree. It explains how the modules fit together, where a request travels, and which file owns each kind of change today. For exact counts, dependencies and public types per target, read the generated [MODULES.md](MODULES.md). For the step-by-step recipes, read the contracts under [docs/contracts](../contracts/README.md). For module-specific traps, read the `AGENTS.md` file inside each `Sources/<Module>/` directory.

## The package

LGE is one SwiftPM package (`Package.swift`) that builds a macOS 26 app for Apple Silicon and a headless command-line tool. It uses Swift 6.2 with strict concurrency. Two executables ship from it. `Lungfish` is the graphical app. `lungfish-cli` is the command-line tool, built from the `LungfishCLIExecutable` target. The XCUITest suite under `Tests/LungfishXCUITests` is built by `Lungfish.xcodeproj`, not by SwiftPM.

## Layering

Modules form a strict stack. Each row may import only the rows above it.

| Layer | Targets | Role |
|---|---|---|
| Core | LungfishCore | Models, bundle manifests, project storage, metadata, notification names |
| IO | LungfishIO | File-format readers and writers, indexes, bundle and analysis folder readers, SQLite stores |
| Workflow | LungfishWorkflow | Tool execution, conda and container runtimes, pipelines, provenance, CLI event protocol |
| Kit | LungfishKit | Shared UI kernel with OperationCenter, CLI subprocess transport, drawers, pickers, brand colors |
| Leaves | LungfishAlignmentUI, LungfishAssemblyUI, LungfishEsVirituUI, LungfishGenotypeUI, LungfishNaoMgsUI, LungfishNvdUI, LungfishPhylogeneticsUI, LungfishTaxTriageUI, LungfishTwelveSUI | One result viewer per target |
| App | LungfishApp | Composition roots that wire leaves to app services |
| Executables | Lungfish, LungfishCLI, LungfishCLIExecutable | The app entry point and the CLI library plus its entry point |

Three rules follow from the stack and from `Package.swift`.

1. LungfishKit and the leaves never import LungfishApp. A leaf exposes callbacks and the App wires them.
2. LungfishCLI imports Core, IO and Workflow only. It never imports LungfishKit or any UI target.
3. Logic that the CLI must also run belongs in LungfishWorkflow or below, never in LungfishApp.

The test-only target `LungfishTestSupport` lives at `Tests/Support/LungfishTestSupport` and depends on Core, IO and Workflow.

## What each target holds

LungfishCore holds plain models with no UI. Bundle manifests live in `Sources/LungfishCore/Bundles/BundleManifest.swift`, and app-wide notification names live in `Sources/LungfishCore/Models/Notifications.swift`.

LungfishIO holds parsers under `Sources/LungfishIO/Formats` (BED, FASTA, FASTQ, GFF, GenBank, SAM, VCF and the classifier report formats). The format registry is `Sources/LungfishIO/Registry/FormatRegistry.swift`. Bundle and analysis folder types live under `Sources/LungfishIO/Bundles`, including `AnalysesFolder.swift`, which owns the project `Analyses/` directory. The analysis kinds it recognises come from `AnalysisToolRegistry` in `Sources/LungfishIO/Analysis/`, one descriptor per kind.

LungfishWorkflow is the largest target. Tool execution sits in `Sources/LungfishWorkflow/Native/NativeToolRunner.swift` and `Sources/LungfishWorkflow/Conda/CondaManager.swift`. Tool versions are pinned in `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`, and `Sources/LungfishWorkflow/Dependencies/ManagedToolVersionProbe.swift` holds how to ask each locked tool for its version. Provenance lives under `Sources/LungfishWorkflow/Provenance`, and the CLI event protocol lives in `Sources/LungfishWorkflow/CLIEvents/CLIEvent.swift`. Domain subtrees include Mapping, Metagenomics, Variants, ONTGenotyping, PrimerDesign, MSA, TwelveS and ViralRecon.

LungfishKit is the shared kernel for every UI target. It owns `Sources/LungfishKit/OperationCenter.swift`, `Sources/LungfishKit/CLISubprocessTransport.swift` and `Sources/LungfishKit/ResultViewportController.swift`, plus drawers, pickers and split-pane helpers.

The nine leaves each hold one result viewer, its display state and its export service. LungfishGenotypeUI is by far the largest. LungfishAlignmentUI is a single file.

LungfishApp holds the six composition-root families. These are AppDelegate and its extensions under `Sources/LungfishApp/App`, MainSplitViewController and MainWindowController under `Sources/LungfishApp/Views/MainWindow`, ViewerViewController and its per-feature extensions under `Sources/LungfishApp/Views/Viewer`, InspectorViewController under `Sources/LungfishApp/Views/Inspector`, and SidebarViewController under `Sources/LungfishApp/Views/Sidebar`. `Sources/LungfishApp/Services` holds operation services, most of which do not need AppKit.

LungfishCLI defines every `lungfish-cli` command under `Sources/LungfishCLI/Commands` and registers them in `Sources/LungfishCLI/LungfishCLI.swift`. LungfishCLIExecutable is the eight-line entry point. Lungfish is the app entry point and the only target that links Sparkle.

## How a request travels

### An analysis started from the GUI

A menu item in `Sources/LungfishApp/App/MainMenu.swift` calls an AppDelegate action, for example in `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift` or `Sources/LungfishApp/App/AppDelegate+Classification.swift`. The Tools menu entries for read tools are not written by hand. `ToolsMenuModel.build` in `Sources/LungfishApp/App/ToolsMenuModel.swift` reads `WorkflowLibraryCatalog.builtIn` in `Sources/LungfishApp/Services/WorkflowLibrary.swift`, which maps over `FASTQOperationToolID.allCases`, and `Sources/LungfishApp/App/MainMenu+Tools.swift` builds one submenu per category in the groups of `Sources/LungfishApp/App/ToolsMenuLayout.swift`, with one item per tool in `FASTQOperationDialogState.toolIDs(for:)`. Both types live in `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`. The action shows a dialog, then registers the run with `OperationCenter.shared.begin(...)` and switches on the returned `OperationStartResult`. A refused result means a bundle lock conflicted, so nothing may launch.

Read tools launched from the FASTQ operations dialog take a separate path through `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`, which spawns `lungfish-cli` with its own `Process` (finding R7, retired in Phase 2). `docs/contracts/ADDING-AN-OPERATION.md` traces it and says which family a new operation joins.

The preferred path for any other operation spawns `lungfish-cli` through `CLISubprocessTransport` and maps each decoded `CLIEvent` onto the Operations panel with `Sources/LungfishApp/Services/OperationCenterCLIBridge.swift`. `runIQTreeInferenceViaCLI` in `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` shows the whole path. It calls `begin`, then runs `Sources/LungfishApp/Services/CLITreeRunner.swift`. `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift` uses the same transport, and its caller in `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift` registers its row through `beginVariantCallingOperation`, which calls `begin`. Older surfaces still run a Workflow pipeline in-process. Review finding R3 records where the two paths differ.

### The same analysis from the CLI

A command under `Sources/LungfishCLI/Commands` parses arguments, calls the Workflow service, and emits `CLIEvent` lines on stdout. For variant calling the command is `Sources/LungfishCLI/Commands/VariantsCommand.swift` and the service is `Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift`.

### Results reaching the screen

Outputs land in a project folder. Analyses go under `Analyses/<tool>-<timestamp>/`, and the sidebar finds them through `Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift`. A selected sidebar item is routed by `displayContent(for:)` in `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift` and by `Sources/LungfishApp/Views/MainWindow/AnalysisResultDisplayRoute.swift`. ViewerViewController then installs the matching viewer through one of its `ViewerViewController+<Feature>.swift` extensions.

## Authoritative implementations

These files own a scientific computation. Change behaviour here, never in a copy.

| Computation | Owning file |
|---|---|
| Read mapping | `Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift` |
| Kraken2 classification | `Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift` |
| EsViritu detection | `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift` |
| Viral variant calling | `Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift` |
| Provenance record format | `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift` |
| Virtual FASTQ materialization | `Sources/LungfishWorkflow/Extraction/FASTQCLIMaterializer.swift` |
| FASTQ input resolution | `Sources/LungfishWorkflow/Extraction/FASTQSourceResolver.swift` |
| BAM registration in a reference bundle | `Sources/LungfishWorkflow/Mapping/BAMImportService.swift` |
| Nextflow and Snakemake launch environment | `Sources/LungfishWorkflow/WorkflowEngineLaunch.swift` |

## Domain invariants

These behaviours are frozen. Tests guard them, and no refactor may change them.

1. Alignments are stored as sorted, indexed BAM. A SAM file is never kept as an output.
2. A virtual FASTQ bundle holds only `preview.fastq`. It is materialized before any classifier or mapper reads it.
3. The Viral Recon viewport binds a `.lungfishref` bundle whose manifest registers the alignment. It never opens a loose BAM.
4. Every operation records a non-nil CLI command and writes a provenance envelope.
5. The lock manifest is the single source of tool versions.

## Where to add X

Each row names the files that own the change today and the contract that will replace them. Read the linked contract before editing.

| To add | Owning files today | Contract today | Replaced by |
|---|---|---|---|
| A file format | A reader under `Sources/LungfishIO/Formats`, a descriptor in `Sources/LungfishIO/Registry/FormatRegistry+BuiltInDescriptors.swift`, and for a bundle its manifest in `Sources/LungfishCore/Bundles/BundleManifest.swift` | [ADDING-AN-ANALYSIS-SURFACE.md](../contracts/ADDING-AN-ANALYSIS-SURFACE.md) | A BundleKind registry in LungfishIO (Phase 2, finding R16) |
| A CLI command | A new file under `Sources/LungfishCLI/Commands`, registered in `Sources/LungfishCLI/LungfishCLI.swift`, emitting `CLIEvent` from `Sources/LungfishWorkflow/CLIEvents/CLIEvent.swift` | [ADDING-AN-OPERATION.md](../contracts/ADDING-AN-OPERATION.md) | CLIEvent v2 with typed artifact and provenance cases (Phase 2, finding R16) |
| An operation | A Workflow service, a CLI command, and an App runner that calls `OperationCenter.begin` in `Sources/LungfishKit/OperationCenter.swift` with `Sources/LungfishApp/Services/OperationCenterCLIBridge.swift`, modelled on `Sources/LungfishApp/Services/CLITreeRunner.swift` | [ADDING-AN-OPERATION.md](../contracts/ADDING-AN-OPERATION.md) | OperationSpec and OperationLauncher (Phase 3, finding R4) and AnalysisRunExecutor (Phase 2, finding R3) |
| A viewport | A new leaf target with its own test target, glue in a new `ViewerViewController+<Feature>.swift`, and a slot and hide call in `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` | [ADDING-AN-ANALYSIS-SURFACE.md](../contracts/ADDING-AN-ANALYSIS-SURFACE.md) and [analysis-surface-checklist.md](../contracts/analysis-surface-checklist.md) | ResultViewport protocol and SurfaceRegistry in LungfishKit (Phase 3, finding R1) |
| An analysis kind (a result type under `Analyses/`) | One `AnalysisToolDescriptor` in `AnalysisToolRegistry.all` in `Sources/LungfishIO/Analysis/AnalysisToolRegistry.swift`, then the pins that hold the 21 ids, names, badges and icons. `knownTools`, `displayName`, the sidebar badge and the sidebar icon read it | [ADDING-AN-ANALYSIS-SURFACE.md](../contracts/ADDING-AN-ANALYSIS-SURFACE.md) | The remaining tables read the descriptor in 2.6 and later (finding R2) |
| A sidebar kind | A case in `SidebarItemType` in `Sources/LungfishApp/Views/Sidebar/SidebarItem.swift`, `analysisItemType` in `Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift`, the analysis kind above, and a route in `Sources/LungfishApp/Views/MainWindow/AnalysisResultDisplayRoute.swift` | [ADDING-AN-ANALYSIS-SURFACE.md](../contracts/ADDING-AN-ANALYSIS-SURFACE.md) | Sidebar routing registry (Phase 3, finding R1) |
| A tool invocation | A call to `NativeToolRunner`, `CondaManager.runTool`, `ProcessManager`, `CLIProcessLauncher` or, for anything else, `ToolProcess` in `Sources/LungfishCore/Process/ToolProcess.swift`. Never a new `Process()`, because `scripts/ratchets/process-spawn.sh` counts them | [RUNNING-A-TOOL.md](../contracts/RUNNING-A-TOOL.md) | Stays on `ToolProcess` |
| A managed tool (a lock entry) | An entry in `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`, the package lists in `Sources/LungfishWorkflow/Conda/PluginPack.swift`, one entry in the probe table in `Sources/LungfishWorkflow/Dependencies/ManagedToolVersionProbe.swift`, and either a `NativeTool` case with its `managedToolID` arm in `Sources/LungfishWorkflow/Native/NativeTool+ManagedTool.swift` or a `CondaManager.runTool` call. `ToolRegistryAgreementTests` fails until they agree | [RUNNING-A-TOOL.md](../contracts/RUNNING-A-TOOL.md) | Probe parsing and recorded versions in 2.6 and 2.7 (finding R2) |
| A read-processing tool in the Tools menu | A `FASTQOperationToolID` case and its `toolIDs(for:)` entry in `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`, a pane in `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift`, and a `FASTQOperationCategoryID` in `Sources/LungfishApp/Views/FASTQ/FASTQOperationsCatalog.swift` (a new category also needs a `displayName` arm there and an entry in `ToolsMenuLayout.groups` in `Sources/LungfishApp/App/ToolsMenuLayout.swift`, which `Tests/LungfishAppViewTests/ToolsMenuStructureTests.swift` enforces) | [ADDING-AN-OPERATION.md](../contracts/ADDING-AN-OPERATION.md) | OperationSpec and OperationLauncher (Phase 3, finding R4) |
| A provenance policy | A `cliCommandPolicies` and `canonicalCLICommandNames` entry for a new top-level command and a `nativeToolPolicies` entry for a new `NativeTool` case, in `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift` | [ADDING-AN-OPERATION.md](../contracts/ADDING-AN-OPERATION.md) | Unchanged |
| A user-visible feature | An entry in `docs/user-manual/features.yaml` with its menu path and source files | [README.md](../contracts/README.md) | Unchanged |
| Concurrency-sensitive code | The patterns in the playbook | [CONCURRENCY-PLAYBOOK.md](../contracts/CONCURRENCY-PLAYBOOK.md) | Unchanged |

The phases refer to `docs/plans/2026-10-02-architecture-program.md`, and the findings refer to `docs/reports/2026-10-02-architecture-review/REVIEW.md`.

## Tests

Each library target has a test target named `<Target>Tests` under `Tests/`. LungfishApp is also covered by LungfishAppViewTests, LungfishAppWorkflowTests and LungfishIntegrationTests. MODULES.md lists the exact mapping. LungfishCLIExecutable and the app entry point have no test target.

The gate is `scripts/full-suite-gate.sh`. Its tiers are smoke, unit, integration, conformance and full. The pre-push hook installed by `scripts/install-git-hooks.sh` runs the ratchets under `scripts/ratchets`, the checks under `scripts/checks`, then the unit tier. For a fast loop on one surface, `scripts/test-surface.sh <filter>` runs only matching tests.

SwiftPM holds one `.build/.lock` per checkout, so two `swift build` or `swift test` runs in one checkout block each other. Run them one at a time.

## Indices and their checks

| Index | Generated or written | Kept current by |
|---|---|---|
| `docs/architecture/MODULES.md` | Generated by `scripts/index/generate-module-map.py` | `scripts/checks/module-map-current.py` |
| `docs/user-manual/features.yaml` | Written by hand | `scripts/checks/features-yaml-entry-points.py` and `scripts/checks/features-yaml-sources.py` |
| `Sources/<Module>/AGENTS.md` | Written by hand | Path checks in the pre-push hook |
| This file | Written by hand | Path checks in the pre-push hook |

When a target, a public type or a subdirectory changes, run `python3 scripts/index/generate-module-map.py` and commit the result with the change.
