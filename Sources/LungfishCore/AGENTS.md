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

## Contracts this module owns

- The reference bundle manifest format. Viewers bind alignments and variants through it, never through a loose BAM (memory file project_viral_recon_results_integration.md).
- The Java heap cap (35 percent of RAM and never more than free memory minus a reserve), which replaced the 60 to 80 percent setting that ran a 48 GB Mac out of memory (memory file known-issues.md).
- Storage roots without spaces, because tools that use shell pipes break on paths with spaces (memory file project_conda_plugins.md).

## Tests

Target LungfishCoreTests in Tests/LungfishCoreTests. Run only it with `swift test --skip-update --filter LungfishCoreTests`. BundleManifestTests, GenomicRegionTests, RuntimeResourceLocatorTests and SequenceTests are in the smoke tier (scripts/full-suite-gate.sh).

## Known traps

| Trap | Evidence |
|---|---|
| 41 notification names carry payload shapes in doc comments only, and many readers use raw string keys | Sources/LungfishCore/Models/Notifications.swift (R9) |
| Process() is created directly in three services | Services/NCBI/NCBIService.swift, Services/NCBI/SRAService.swift, Services/Blast/BlastService.swift (R7) |
| `String(format:)` with `%s` on a Swift String crashes, use `%@` or interpolation | memory file reference_runtime_patterns.md |
| Adding a stored property to a public struct can leave a stale test object that crashes in `outlined init with copy`, so delete .build/arm64-apple-macosx/debug.yaml and rebuild | memory file project_test_baseline.md |

The NCBI BLAST database name lives in `BlastDatabaseID` (Models/BlastDatabaseID.swift). Use `BlastDatabaseID.coreNT.rawValue` and never retype the string.
