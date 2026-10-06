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
| Process entry used by the executable | `LungfishCLIMain`, LungfishCLI.swift line 128 |
| Shared options | Sources/LungfishCLI/Options/GlobalOptions.swift |
| Output formatting | Sources/LungfishCLI/Output/CLIOutput.swift |
| Provenance helpers for commands | Sources/LungfishCLI/Support/CLIProvenanceSupport.swift |

The command files live in Sources/LungfishCLI/Commands. Find a subcommand by its type name. Most FASTQ, bundle, fetch and workflow subcommands have a file named for their type, such as FastqTrimSubcommand.swift. A type that uses a file-private helper stays beside the helper. So FastqCommand.swift keeps FastqDemultiplexSubcommand and FastqScoutSubcommand, FetchCommand.swift keeps NCBISubcommand and ENAFastaSubcommand, and MetadataCommand.swift keeps MetadataSetSubcommand and MetadataImportSubcommand.

## Where a Kraken2 run starts in the CLI

`lungfish-cli conda classify` is `ClassifyCommand` (Commands/ClassifyCommand.swift line 62), registered as a `conda` subcommand in Commands/CondaCommand.swift line 41. Its `run` (line 204) resolves the database, materializes virtual FASTQ through `FASTQCLIMaterializer` into `.lungfish-classify-inputs`, plans one input under `--read-format auto`, or a `--paired` pair with `--unpaired` files, through `KrakenReadSetPlanner` (`planReadSet` in Commands/ClassifyCommand+ReadSets.swift), then calls `ClassificationPipeline.shared` (line 422). Kraken2 sits under `conda` rather than at the top level (REVIEW.md R5). EsViritu is `lungfish-cli esviritu detect` (Commands/EsVirituCommand.swift, planning a bundle in Commands/EsVirituCommand+ReadSets.swift) and mapping is `lungfish-cli map` (Commands/MapCommand.swift, which resolves its inputs through `MappingInputResolver`, the call the Map Reads window makes, and calls `ManagedMappingPipeline`). `taxtriage run` plans each sample in Commands/TaxTriageCommand+ReadSets.swift, and `assemble` resolves its reads through `AssemblyReadSetResolution` in Commands/AssembleCommand.swift, with its read-layout helpers in Commands/AssembleCommand+ReadSets.swift.

## Where an IQ-TREE run starts in the CLI

`lungfish-cli tree infer iqtree` is `TreeCommand.InferIQTreeSubcommand` (Commands/TreeInferIQTreeCommand.swift line 8, `run` at line 90), registered in Commands/TreeCommand.swift. Its helpers sit in two files beside it. Commands/TreeInferIQTreeStaging.swift stages the in-scope rows under tip IDs t0001 and onward (`stageIQTreeRows`, line 52), writes artifacts/iqtree/tip-map.tsv (`writeIQTreeTipMap`, line 96), finds the outgroup clade for the reroot (`iqtreeOutgroupRootNodeID`, line 109) and reads the drawn seed from run.log (`parseIQTreeSeed`, line 129). Commands/TreeInferIQTreeInference.swift records the support labels in IQ-TREE's order (`iqtreeSupportLabels`, line 6) and builds the manifest's inference summary from run.iqtree through `IQTreeReportParser` (`iqtreeInferenceSummary`, line 50). Reserved `--extra-args` flags, the model-selection-only rule and the codon frame rule come from `IQTreeOptionRules` in Sources/LungfishIO/Bundles/IQTreeOptionRules.swift, shared with the Build Tree dialog. Line numbers in this section were checked at commit 58370dd8e.

## Contracts this module owns

- The argv a command accepts must match what the GUI records as its cliCommand, so a copied command reruns the same analysis.
- `tree infer iqtree` replays byte for byte only with `--threads 1` and a fixed `--seed`. Without `--threads` it passes `-T AUTO`, and a multithreaded IQ-TREE run gives slightly different branch lengths each time (docs/contracts/CLI-EQUIVALENCE.md, Tests/LungfishAppTests/IQTreeInferenceReplayTests.swift).
- Commands the app drives through `CLISubprocessTransport` emit `CLIEvent` lines (Sources/LungfishWorkflow/CLIEvents/CLIEvent.swift).
- Every scientific top-level command has a provenance policy entry in Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift, checked by ScientificCLIProvenanceCoverageTests.
- Managed tools are resolved through `WorkflowEngineLaunch.resolve`, never `/usr/bin/env <tool>` (memory file project_cli_subprocess_bare_path.md).

## Tests

Target LungfishCLITests in Tests/LungfishCLITests. Run only it with `swift test --skip-update --filter LungfishCLITests`. Process-fork suites (CLIExitCodeProcessTests and others) run in the integration tier, not the unit tier (see Tests/AGENTS.md).

## Known traps

| Trap | Evidence |
|---|---|
| EsViritu CLI writes no SQLite, manifest or batch provenance while the GUI does | Commands/EsVirituCommand.swift compared with Sources/LungfishApp/App/AppDelegate+Classification.swift lines 911 to 1159 (R3) |
| Only 10 of 187 command files emit `CLIEvent` (the count grew when lane 1i split multi-type files), and at least 15 private NDJSON schemas exist | Commands/BAMPrimerTrimSubcommand.swift and others (R16) |
| Global mutable runner overrides | Commands/RunSubcommand.swift lines 32 to 36, Commands/CondaCommand.swift lines 50 to 52 (R10) |
| The app spawns the CLI with Finder's bare PATH, so an unresolved tool exits 127 | memory file project_cli_subprocess_bare_path.md |
| nf-core schemas reject paths with spaces, so inputs are staged | Commands/NFCoreLaunchStaging.swift (memory file project_cli_subprocess_bare_path.md) |
| `GlobalOptions()` direct init crashes, use `GlobalOptions.parse([])` | memory file reference_runtime_patterns.md |
| Very large command files | Commands/MSACommand.swift is 2,958 lines and Commands/ImportCommand.swift is 2,527 lines (R6) |
| A new top-level command without a `cliCommandPolicies` entry fails the coverage test, and one listed in `canonicalCLICommandNames` but not registered fails it as stale. A non-scientific command goes in the test's `nonScientificTopLevelCommands` set | Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift line 86, Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift line 103 |

Commands/WorkflowEngineLaunch.swift is only a typealias for the LungfishWorkflow type of the same name.
