# LungfishCore

Line numbers were checked at commit a0eec8b32. When a line has moved, search for the named symbol.

## Purpose

The bottom layer. Sequence and region models, the reference bundle manifest, app settings, notification names, managed storage roots, project locks and the network services for NCBI, ENA, SRA, Pathoplexus and BLAST. Everything else imports it, so a public change here recompiles every target.

## Allowed imports

Foundation and system frameworks, plus Collections and Algorithms from Package.swift. Never another Lungfish module, AppKit or SwiftUI.

## Entry points

| Type | Path |
|---|---|
| `Sequence` | Sources/LungfishCore/Models/Sequence.swift line 24 |
| `GenomicRegion` | Sources/LungfishCore/Models/GenomicRegion.swift line 16 |
| `BundleManifest` (the .lungfishref manifest) | Sources/LungfishCore/Bundles/BundleManifest.swift line 112 |
| `AppSettings` | Sources/LungfishCore/Models/AppSettings.swift line 29 |
| App-wide notification names | Sources/LungfishCore/Models/Notifications.swift |
| `CLICommandIdentity` (executable name) | Sources/LungfishCore/CLICommandIdentity.swift line 6 |
| `ManagedJavaHeapPolicy` (BBTools and Java heap size) | Sources/LungfishCore/Services/ManagedJavaHeapPolicy.swift line 28 |
| `RuntimeResourceLocator` | Sources/LungfishCore/Services/RuntimeResourceLocator.swift line 53 |
| Managed storage and project locks | Sources/LungfishCore/Storage/ManagedStorageConfigStore.swift, ProjectLock.swift |
| BLAST submission | Sources/LungfishCore/Services/Blast/BlastService.swift |
| SRA download checks shared by the window and `fetch sra download` | Sources/LungfishCore/Services/SRA/SRARunReads.swift, SRADownloadMessages.swift, SRAFASTQDownloadRoute.swift, Sources/LungfishCore/Services/ENA/ENAFASTQDownloadValidator.swift |
| `ProvenanceRunClock`, which times provenance runs so a wall-clock step cannot end one before it starts | Sources/LungfishCore/ProvenanceRunClock.swift |
| `ToolProcess`, the one process primitive for every layer (`run` and `runPipeline`, spawned with posix_spawn as one process group per stage, plus `start`, the one run handle `ToolProcessRun`, with a `.stream` stdout read raw and `runBlocking` for synchronous callers, both on GCD with no Swift task), with the tree terminator, line framer and process registry it builds on (`ProcessTreeTerminator`, `ProcessOutputLineFramer`, `NativeProcessRegistry`). Its stops go through the internal `ProcessGroupTerminator`, which waits on one shared timer and ends as soon as the group and tree are gone | Sources/LungfishCore/Process/ToolProcess.swift and the rest of Sources/LungfishCore/Process/ |

## Contracts this module owns

- The reference bundle manifest format. Viewers bind alignments and variants through it, never through a loose BAM (memory file project_viral_recon_results_integration.md).
- The Java heap cap (35 percent of RAM and never more than free memory minus a reserve), which replaced the 60 to 80 percent setting that ran a 48 GB Mac out of memory (memory file known-issues.md).
- Storage roots without spaces, because tools that use shell pipes break on paths with spaces (memory file project_conda_plugins.md).
- SRA downloads. The window's SRA download and `lungfish-cli fetch sra download` keep their own orchestration but take every decision from here. That covers the size and MD5 check of ENA's files, the check that ENA answered with the run asked for (`fastqDownloadRoute(forRun:)`), the lone-mate rule with ENA's or NCBI's layout (`SRARunReads.sorting`), the one-line reasons and the both-failed error (`SRADownloadMessages`, `SRAError.bothArchivesFailed`), the fallback line, the strategy names and the recorded sra-tools version. Change a rule here, never in one surface. `SRADownloadSurfaceParityTests` in LungfishAppTests checks that both surfaces give the same files and provenance for one scripted run (Phase 2.1 lane L1).

## Tests

Target LungfishCoreTests in Tests/LungfishCoreTests. Run only it with `swift test --skip-update --filter LungfishCoreTests`. BundleManifestTests, GenomicRegionTests, RuntimeResourceLocatorTests and SequenceTests are in the smoke tier (scripts/full-suite-gate.sh).

## Known traps

| Trap | Evidence |
|---|---|
| 41 notification names carry payload shapes in doc comments only, and many readers use raw string keys | Sources/LungfishCore/Models/Notifications.swift (R9) |
| Process() is created directly in three services | Services/NCBI/NCBIService.swift, Services/NCBI/SRAService.swift, Services/Blast/BlastService.swift (R7) |
| `String(format:)` with `%s` on a Swift String crashes, use `%@` or interpolation | memory file reference_runtime_patterns.md |
| A ToolProcess descendant that leaves its process group with setsid or setpgid and keeps writing a `.file` output escapes settlement, so it can write after the run returns | Known limits in Sources/LungfishCore/Process/ToolProcess.swift (R7, Phase 2.2 lane 6A) |
| A slow reader of a `.stream` stdout whose writer is a descendant outliving the leader is cut when the drain grace runs out, and the output is reported incomplete | Known limits in Sources/LungfishCore/Process/ToolProcess.swift |
| A pipe is inheritable between pipe() and its close-on-exec fcntl, so a Foundation `Process` spawned in that window can hold it open. The window stays until the last Foundation `Process` spawns move to ToolProcess | `ToolProcessDescriptors.makePipe` in Sources/LungfishCore/Process/ToolProcessStreams.swift, counted by scripts/ratchets/process-spawn.sh |
| Adding a stored property to a public struct can leave a stale test object that crashes in `outlined init with copy`, so delete .build/arm64-apple-macosx/debug.yaml and rebuild | memory file project_test_baseline.md |

The NCBI BLAST database name lives in `BlastDatabaseID` (Models/BlastDatabaseID.swift). Use `BlastDatabaseID.coreNT.rawValue` and never retype the string.
