# Agent guide

This is the entry point for any agent working in the Lungfish Genome Explorer (LGE) repository. LGE is a Swift 6.2 macOS 26 app for Apple Silicon plus a headless `lungfish-cli`, both built from one SwiftPM package. Read this file first, then the map, then the module guide for the code you will change.

## Read next

| Document | What it answers |
|---|---|
| [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md) | How the modules fit together, how a request travels, and where to add a format, command, operation, viewport, sidebar kind or tool |
| [docs/architecture/MODULES.md](docs/architecture/MODULES.md) | Generated per-target facts with dependencies, file and line counts, subdirectories, public types and test targets |
| `Sources/<Module>/AGENTS.md` | Module-specific purpose, allowed imports, entry points, owned contracts, test target and known traps |
| [docs/contracts/README.md](docs/contracts/README.md) | Index of the written contracts |
| [docs/contracts/ADDING-AN-OPERATION.md](docs/contracts/ADDING-AN-OPERATION.md) | The full path for a new operation, from Workflow service to CLI command to App runner |
| [docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md](docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md) | The leaf-module recipe for a new result viewer and every App touch point it needs today |
| [docs/contracts/analysis-surface-checklist.md](docs/contracts/analysis-surface-checklist.md) | A copyable checklist to tick per surface |
| [docs/contracts/CONCURRENCY-PLAYBOOK.md](docs/contracts/CONCURRENCY-PLAYBOOK.md) | MainActor dispatch, progress callbacks, generation counters and the ratcheted escape hatches |
| [docs/contracts/SCREENCASTS.md](docs/contracts/SCREENCASTS.md) | How screencasts are made, revised after feedback, narrated and published to the Videos page |
| [docs/user-manual/features.yaml](docs/user-manual/features.yaml) | Every user-reachable feature with its menu path and source files |
| [SKILLS.md](SKILLS.md) | Release commands and large-file storage |

## Layering rule

Modules form a stack. Each row imports only rows above it.

| Row | Targets |
|---|---|
| 1 | LungfishCore |
| 2 | LungfishIO |
| 3 | LungfishWorkflow |
| 4 | LungfishKit |
| 5 | The nine leaves (LungfishAlignmentUI, LungfishAssemblyUI, LungfishEsVirituUI, LungfishGenotypeUI, LungfishNaoMgsUI, LungfishNvdUI, LungfishPhylogeneticsUI, LungfishTaxTriageUI, LungfishTwelveSUI) |
| 6 | LungfishApp |
| 7 | Lungfish (app executable) |

LungfishCLI sits beside the UI stack and imports only Core, IO and Workflow. LungfishCLIExecutable wraps it as `lungfish-cli`.

1. LungfishKit and the leaves never import LungfishApp. A leaf exposes callbacks and the App wires them.
2. LungfishCLI never imports LungfishKit or any UI target.
3. Logic the CLI must also run belongs in LungfishWorkflow or below. New feature UI belongs in a leaf, not in LungfishApp.

## Where to find things

| Looking for | Start at |
|---|---|
| Tool execution and pinned tool versions | `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`, `Sources/LungfishWorkflow/Conda/CondaManager.swift`, `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json` |
| Operations panel and bundle locks | `Sources/LungfishKit/OperationCenter.swift` |
| Running `lungfish-cli` from the app | `Sources/LungfishKit/CLISubprocessTransport.swift` and `Sources/LungfishApp/Services/OperationCenterCLIBridge.swift` |
| FASTQ operations dialog execution | `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`, with `FASTQOperationPlanner`, `FASTQOperationCLIInvocationBuilder` and `FASTQOperationOutputImporter` beside it |
| CLI commands | `Sources/LungfishCLI/Commands`, registered in `Sources/LungfishCLI/LungfishCLI.swift` |
| CLI progress events | `Sources/LungfishWorkflow/CLIEvents/CLIEvent.swift` |
| Provenance | `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift` |
| File formats | `Sources/LungfishIO/Formats` and `Sources/LungfishIO/Registry/FormatRegistry.swift` |
| Sidebar routing | `Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift` and `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift` |
| Viewer slots | `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` and its `ViewerViewController+<Feature>.swift` extensions |
| Menus | `Sources/LungfishApp/App/MainMenu.swift`. Tools menu read tools are generated from `FASTQOperationToolID` in `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift` through `WorkflowLibraryCatalog.builtIn` and `ToolsMenuModel.build`, so add a case and a `toolIDs(for:)` entry, never a menu item |
| Test helpers | `Tests/Support/LungfishTestSupport` |

## Binding rules

These rules are not optional. Each one exists because breaking it caused a shipped defect.

| Rule | What it means |
|---|---|
| `OperationCenter.begin`, never `start` | Register every operation with `OperationCenter.shared.begin(...)` and switch on the result. A `.refused` result means a bundle lock conflicted, so launch nothing. `start` is deprecated, and `scripts/ratchets/unchecked-operation-start.sh` stops new bundle-targeted callers. Always pass `operationType` and `cliCommand`. |
| CLI parity | Every GUI operation must have a `lungfish-cli` equivalent that produces the same result, and the GUI records that command in the Operations panel. Shared logic lives in LungfishWorkflow so both paths run it. |
| Provenance envelope is mandatory | Every operation writes a provenance record through `ProvenanceEnvelope`. A run without provenance is a defect. |
| BAM, never SAM | Alignments are stored as sorted, indexed BAM. Convert any SAM with samtools sort and index, then delete the SAM. |
| Materialize virtual FASTQ first | A virtual FASTQ bundle holds only `preview.fastq`. Materialize it with `FASTQCLIMaterializer` before any classifier or mapper runs. |
| Provenance policy registered | A new top-level CLI command needs an entry in `Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift` or `ScientificCLIProvenanceCoverageTests` fails. A new `NativeTool` case without a `nativeToolPolicies` entry makes `NativeToolRunner` throw `missingProvenancePolicy`. |
| Viral Recon binds `.lungfishref` | The Viral Recon viewport binds a `.lungfishref` bundle whose manifest registers the BAM. It never opens a loose BAM. |

One more habit matters. Call both `OperationCenter.shared.update` and `OperationCenter.shared.log` from a running operation, because only logged lines persist in the row history.

## Gate and check commands

Build and test one change at a time. SwiftPM holds one `.build/.lock` per checkout, so two `swift` runs in one checkout block each other.

```sh
swift build --skip-update
swift test --skip-update --filter LungfishIOTests      # one test target
bash scripts/test-surface.sh VCF                       # one surface by name filter
bash scripts/full-suite-gate.sh --tier unit --quiet    # the gate the pre-push hook runs
python3 scripts/index/generate-module-map.py           # regenerate MODULES.md
python3 scripts/checks/module-map-current.py           # fails when MODULES.md is stale
python3 scripts/checks/features-yaml-entry-points.py   # features.yaml menu paths
bash scripts/install-git-hooks.sh                      # install the pre-push hook
```

The gate tiers are smoke, unit, integration, conformance and full. Full is the stable-release gate. When you add, remove or rename a target, a public type or a source subdirectory, regenerate MODULES.md in the same commit.

## Writing docs

Documentation follows the project prose rules. Use no em dashes, no semicolons and no colons inside a sentence. Avoid every word listed in `docs/user-manual/build/scripts/lint/rules/ai-tells-words.txt`. Write "Lungfish Genome Explorer (LGE)" once, then "LGE". Check a file with `LUNGFISH_MANUAL_STRICT=1 bash docs/user-manual/build/scripts/lint-chapter.sh <file>`.
