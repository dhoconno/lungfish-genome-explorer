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

The 104 command files live in Sources/LungfishCLI/Commands, one top-level command or subcommand per file.

## Where a Kraken2 run starts in the CLI

`lungfish-cli conda classify` is `ClassifyCommand` (Commands/ClassifyCommand.swift line 62), registered as a `conda` subcommand in Commands/CondaCommand.swift line 41. Its `run` (line 204) resolves the database, materializes virtual FASTQ through `FASTQCLIMaterializer` into `.lungfish-classify-inputs`, then calls `ClassificationPipeline.shared` (line 422). Kraken2 sits under `conda` rather than at the top level (REVIEW.md R5). EsViritu is `lungfish-cli esviritu detect` (Commands/EsVirituCommand.swift) and mapping is `lungfish-cli map` (Commands/MapCommand.swift, which calls `ManagedMappingPipeline` at line 395).

## Contracts this module owns

- The argv a command accepts must match what the GUI records as its cliCommand, so a copied command reruns the same analysis.
- Commands the app drives through `CLISubprocessTransport` emit `CLIEvent` lines (Sources/LungfishWorkflow/CLIEvents/CLIEvent.swift).
- Every scientific top-level command has a provenance policy entry in Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift, checked by ScientificCLIProvenanceCoverageTests.
- Managed tools are resolved through `WorkflowEngineLaunch.resolve`, never `/usr/bin/env <tool>` (memory file project_cli_subprocess_bare_path.md).

## Tests

Target LungfishCLITests in Tests/LungfishCLITests. Run only it with `swift test --skip-update --filter LungfishCLITests`. Process-fork suites (CLIExitCodeProcessTests and others) run in the integration tier, not the unit tier (see Tests/AGENTS.md).

## Known traps

| Trap | Evidence |
|---|---|
| EsViritu CLI writes no SQLite, manifest or batch provenance while the GUI does | Commands/EsVirituCommand.swift compared with Sources/LungfishApp/App/AppDelegate+Classification.swift lines 1042 to 1290 (R3) |
| Only 9 of 104 command files emit `CLIEvent`, and at least 15 private NDJSON schemas exist | Commands/BAMCommand.swift and others (R16) |
| Global mutable runner overrides | Commands/WorkflowCommand.swift lines 85 to 89, Commands/CondaCommand.swift lines 50 to 52 (R10) |
| The app spawns the CLI with Finder's bare PATH, so an unresolved tool exits 127 | memory file project_cli_subprocess_bare_path.md |
| nf-core schemas reject paths with spaces, so inputs are staged | Commands/NFCoreLaunchStaging.swift (memory file project_cli_subprocess_bare_path.md) |
| `GlobalOptions()` direct init crashes, use `GlobalOptions.parse([])` | memory file reference_runtime_patterns.md |
| Very large command files | Commands/FastqCommand.swift is 4,114 lines (R6) |
| A new top-level command without a `cliCommandPolicies` entry fails the coverage test, and one listed in `canonicalCLICommandNames` but not registered fails it as stale. A non-scientific command goes in the test's `nonScientificTopLevelCommands` set | Sources/LungfishWorkflow/Provenance/ScientificProvenancePolicy.swift line 86, Tests/LungfishCLITests/ScientificCLIProvenanceCoverageTests.swift line 103 |
| `provision-tools` is the only route into Native/ToolProvisioning | Commands/ProvisionToolsCommand.swift (R15) |

Commands/WorkflowEngineLaunch.swift is only a typealias for the LungfishWorkflow type of the same name.
