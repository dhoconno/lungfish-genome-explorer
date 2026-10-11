# LungfishCLI

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

The `lungfish-cli` command tree, built on swift-argument-parser. Every GUI operation has a CLI command that reproduces it (CLI parity), and the app runs many operations by spawning this binary. Commands parse options, materialize inputs, call a LungfishWorkflow pipeline and report progress. Scientific logic belongs in LungfishWorkflow, not in a command.

## Allowed imports

LungfishCore, LungfishIO, LungfishWorkflow and ArgumentParser. Never LungfishKit, a leaf UI module, LungfishApp, AppKit or SwiftUI (memory file project_module_architecture.md).

## Entry points

| Type | Path |
|---|---|
| Root command and subcommand list | `LungfishCLI`, Sources/LungfishCLI/LungfishCLI.swift line 19 |
| Process entry used by the executable | `LungfishCLIMain`, LungfishCLI.swift line 129 |
| Shared options | Sources/LungfishCLI/Options/GlobalOptions.swift |
| Output formatting | Sources/LungfishCLI/Output/CLIOutput.swift |
| Provenance helpers for commands | Sources/LungfishCLI/Support/CLIProvenanceSupport.swift |
| What each leaf command writes for a machine reader, one row per leaf | `CLIEventContractTable`, Sources/LungfishCLI/Support/CLIEventContract.swift |

The command files live in Sources/LungfishCLI/Commands. Find a subcommand by its type name. Most FASTQ, bundle, fetch and workflow subcommands have a file named for their type, such as FastqTrimSubcommand.swift. A type that uses a file-private helper stays beside the helper. So FastqCommand.swift keeps FastqDemultiplexSubcommand and FastqScoutSubcommand, FetchCommand.swift keeps NCBISubcommand and ENAFastaSubcommand, and MetadataCommand.swift keeps MetadataSetSubcommand and MetadataImportSubcommand.

## Where a Kraken2 run starts in the CLI

`lungfish-cli kraken2 classify` is `ClassifyCommand` (Commands/ClassifyCommand.swift line 31), the one subcommand of the `Kraken2Command` group (Commands/Kraken2Command.swift) that `LungfishCLI` lists beside `esviritu` and `taxtriage`. `lungfish-cli conda classify` is the same type, still registered as a `conda` subcommand in Commands/CondaCommand.swift line 41. Both spellings register `ClassifyCommand` itself and never a wrapper, because tests, `RecordedCLICommand` among them, cast a parsed root to it, and `Kraken2ClassifyCommandTests` pins that they parse to equal options. A run records the command line as typed, so a `kraken2 classify` run records that spelling. Since Phase 2.7 (decision E11) the Kraken2 rows the classification wizard starts, `ClassificationCLIInvocationBuilder` and the batch replay command name `kraken2 classify`. The FASTQ operations dialog still runs `conda classify` (`FASTQOperationCLIInvocationBuilder` in Sources/LungfishApp/Services), and the goldens keep that spelling until lane G captures them again. Its `run` (line 155) builds `Kraken2AnalysisRunTool` (Sources/LungfishWorkflow/Metagenomics/Kraken2AnalysisRunTool.swift, with the unit in Kraken2AnalysisRunTool+Unit.swift and the finalize in Kraken2AnalysisRunTool+Finalize.swift) and runs it through `AnalysisRunExecutor` with `Kraken2ResultIndexer` (Commands/ClassifyCommand+Index.swift line 17). The unit materializes virtual FASTQ through `FASTQCLIMaterializer` into `<root>/.lungfish-classify-inputs/`, which the result folder keeps (decision E3), plans one input under `--read-format auto`, or a `--paired` pair with `--unpaired` files, through `KrakenReadSetPlanner` (`Kraken2RunRequest.planReadSet` in Sources/LungfishWorkflow/Metagenomics/Kraken2RunRequest+Planning.swift line 115, which `planReadSet` in Commands/ClassifyCommand+ReadSets.swift line 78 calls), then runs `ClassificationPipeline.shared`. EsViritu is `lungfish-cli esviritu detect` (`EsVirituCommand.DetectSubcommand`, Commands/EsVirituCommand.swift line 73), which runs `EsVirituAnalysisRunTool` through the same executor and plans a bundle in Commands/EsVirituCommand+ReadSets.swift. Mapping is `lungfish-cli map` (Commands/MapCommand.swift, which resolves its inputs through `MappingInputResolver`, the call the Map Reads window makes, and calls `ManagedMappingPipeline`). `taxtriage run` plans each sample in Commands/TaxTriageCommand+ReadSets.swift, and `assemble` resolves its reads through `AssemblyReadSetResolution` in Commands/AssembleCommand.swift, with its read-layout helpers in Commands/AssembleCommand+ReadSets.swift. Line numbers in this section were checked at commit 9b9752074.

## Where an IQ-TREE run starts in the CLI

`lungfish-cli tree infer iqtree` is `TreeCommand.InferIQTreeSubcommand` (Commands/TreeInferIQTreeCommand.swift line 8, `run` at line 90), registered in Commands/TreeCommand.swift. Its helpers sit in two files beside it. Commands/TreeInferIQTreeStaging.swift stages the in-scope rows under tip IDs t0001 and onward (`stageIQTreeRows`, line 52), writes artifacts/iqtree/tip-map.tsv (`writeIQTreeTipMap`, line 96), finds the outgroup clade for the reroot (`iqtreeOutgroupRootNodeID`, line 109) and reads the drawn seed from run.log (`parseIQTreeSeed`, line 129). Commands/TreeInferIQTreeInference.swift records the support labels in IQ-TREE's order (`iqtreeSupportLabels`, line 6) and builds the manifest's inference summary from run.iqtree through `IQTreeReportParser` (`iqtreeInferenceSummary`, line 50). Reserved `--extra-args` flags, the model-selection-only rule and the codon frame rule come from `IQTreeOptionRules` in Sources/LungfishIO/Bundles/IQTreeOptionRules.swift, shared with the Build Tree dialog. Line numbers in this section were checked at commit 58370dd8e.

## What each leaf writes for a machine reader

Every leaf command has one row in `CLIEventContractTable`. The row says whether the leaf emits events, prints one JSON result, prints a private stream shape that a later sub-phase retires, or prints human text only. A command that is added, renamed or removed edits its row in the same commit, or `CLIEventContractCoverageTests` fails. A new private stream shape is a `.legacy` row with the sub-phase that retires it, and the test that lists the shapes left fails until its list says so too. A leaf that emits events also needs a transcript under Tests/Fixtures/cli-events/commands, and docs/formats/cli-events.md describes the table.

## Contracts this module owns

- The argv a command accepts must match what the GUI records as its cliCommand, so a copied command reruns the same analysis.
- `tree infer iqtree` replays byte for byte only with `--threads 1` and a fixed `--seed`. Without `--threads` it passes `-T AUTO`, and a multithreaded IQ-TREE run gives slightly different branch lengths each time (docs/contracts/CLI-EQUIVALENCE.md, Tests/LungfishAppTests/IQTreeInferenceReplayTests.swift).
- Commands the app drives through `CLISubprocessTransport` emit `CLIEvent` lines (Sources/LungfishWorkflow/CLIEvents/CLIEvent.swift). The app reads them from a pipe, where `print` buffers, so write each event line with `printEventLine` (Output/CLIOutput.swift), which flushes it. An unflushed event reaches the Operations Panel only when the command exits. `LungfishCLIMain` installs `CLITerminationSignals` (Support/CLITerminationSignals.swift) before any command runs, so SIGINT, SIGTERM and SIGHUP stop every tool tree in `NativeProcessRegistry` and the CLI ends by that signal. `import fastq` and `workflow run` turn the first SIGTERM into task cancellation through `SIGTERMCancellation` so their cleanup runs, and a cancelled `workflow run` exits 125 (`CLIExitCode.cancelled`). A new long-running command that owns child tools follows `docs/contracts/RUNNING-A-TOOL.md`.
- Every scientific top-level command has a provenance policy entry in Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift, checked by ScientificCLIProvenanceCoverageTests. `cliCommand(path:)` takes the exact row of `cliCommandPathPolicies`, else the row of the path's longest registered prefix, else the entry of the group that starts the path, and never the entry of its last component (2.7 E16). `kraken2 classify` and `conda classify` hold one exact row, and a leaf of `conda`, `debug`, `demo` or `storage` holds no entry unless a row names it. Tests/LungfishCLITests/ScientificProvenancePolicyLeafTests.swift pins the entry of every leaf of the help golden, so a new leaf needs a row there once the golden lists it. The entries set no field a run records, since nothing outside tests reads them.
- Managed tools are resolved through `WorkflowEngineLaunch.resolve`, never `/usr/bin/env <tool>` (memory file project_cli_subprocess_bare_path.md).

## Tests

Target LungfishCLITests in Tests/LungfishCLITests. Run only it with `swift test --skip-update --filter LungfishCLITests`. Process-fork suites (CLIExitCodeProcessTests and others) run in the integration tier, not the unit tier (see Tests/AGENTS.md).

## Known traps

| Trap | Evidence |
|---|---|
| EsViritu CLI writes no SQLite, manifest or batch provenance while the GUI does | Commands/EsVirituCommand.swift compared with Sources/LungfishApp/App/AppDelegate+Classification.swift lines 911 to 1159 (R3) |
| Some leaf commands still print a private stream shape or a JSON result instead of `CLIEvent` lines. `CLIEventContractTable` lists every leaf with what it writes, its `.legacy` rows count the private shapes left, and the `.text` leaves that list `--format json` and print text anyway wait for 2.10 to 2.12 | Support/CLIEventContract.swift, Tests/LungfishCLITests/CLIEventContractCoverageTests.swift (R16) |
| Global mutable runner overrides | Commands/RunSubcommand.swift lines 32 to 36, Commands/CondaCommand.swift lines 50 to 52 (R10) |
| The app spawns the CLI with Finder's bare PATH, so an unresolved tool exits 127 | memory file project_cli_subprocess_bare_path.md |
| nf-core schemas reject paths with spaces, so inputs are staged | Commands/NFCoreLaunchStaging.swift (memory file project_cli_subprocess_bare_path.md) |
| `GlobalOptions()` direct init crashes, use `GlobalOptions.parse([])` | memory file reference_runtime_patterns.md |
| Very large command files | Commands/MSACommand.swift is 2,958 lines and Commands/ImportCommand.swift is 2,527 lines (R6) |
| A new top-level command without a `cliCommandPolicies` entry fails the coverage test, and one listed in `canonicalCLICommandNames` but not registered fails it as stale. A non-scientific command goes in the test's `nonScientificTopLevelCommands` set | Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift line 91, Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift line 103 |
| The root command count is pinned, so a new top-level command also moves it | `SubcommandRegistrationTests.testTotalSubcommandCount` in Tests/LungfishCLITests/NewCommandTests.swift |

Commands/WorkflowEngineLaunch.swift is only a typealias for the LungfishWorkflow type of the same name.
