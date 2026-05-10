# Project-Local Temporary Directory

**Date**: 2026-04-03
**Status**: Proposed
**Scope**: All temp file operations across LungfishWorkflow, LungfishApp, LungfishCore, LungfishCLI

## Problem

Lungfish writes temporary files (extraction intermediates, materialized FASTQs, pipeline working directories, symlink workarounds) to the system `/tmp` via `FileManager.default.temporaryDirectory`. This causes three problems:

1. **Cross-volume penalty**: When the project lives on an external SSD, temp files are written to the internal drive. Large materializations (multi-GB FASTQ) must be copied back across volumes, wasting time and doubling disk usage.
2. **Orphaned files**: If the app crashes or is force-quit, temp files are never cleaned up. The existing `TempFileManager` scans system temp on launch, but only catches files with known prefixes.
3. **Bundle output misplacement**: Extraction bundles were placed outside the project because the project root derivation was wrong (fixed in the preceding commit, but the underlying temp-dir pattern is still fragile).

## Design

### 1. Project Temp Root: `project.lungfish/.tmp/`

A hidden directory at the project root holds ALL temp files for that project. The dot prefix hides it from Finder casual browsing and the sidebar (which already skips hidden files). It is fully accessible via CLI, terminal, and LLM tools.

Structure:
```
myproject.lungfish/
  .tmp/
    esviritu-extract-A1B2C3D4/
    lungfish-classify-E5F6G7H8/
    lungfish-spades-I9J0K1L2/
    ...
  Downloads/
  Imports/
  Reference Sequences/
  Assemblies/
  metadata.json
```

### 2. `ProjectTempDirectory` Utility (LungfishIO)

New public enum in `LungfishIO` (no app dependency, usable from all modules):

```swift
public enum ProjectTempDirectory {
    /// Returns project.lungfish/.tmp/
    public static func tempRoot(for projectURL: URL) -> URL

    /// Creates .tmp/{prefix}-{UUID}/ and returns the URL.
    /// Falls back to system temp with a logger warning if projectURL is nil.
    public static func create(prefix: String, in projectURL: URL?) throws -> URL

    /// Removes the entire .tmp/ directory.
    public static func cleanAll(in projectURL: URL) throws

    /// Returns the total size in bytes of the .tmp/ directory.
    public static func diskUsage(in projectURL: URL) -> UInt64
}
```

The `create(prefix:in:)` method accepts an optional project URL. When nil (pre-project context like database downloads), it falls back to system temp. This is the ONLY sanctioned fallback path.

### 3. Caller Migration (~40 sites)

Every `FileManager.default.temporaryDirectory` and `NSTemporaryDirectory()` call that operates within a project context is replaced with `ProjectTempDirectory.create(prefix:in:)`. The project URL is threaded through from the caller's existing context (bundle URL, config output directory, etc.).

#### LungfishWorkflow (pipeline layer)

| File | Sites | Current prefix | Notes |
|------|-------|---------------|-------|
| `ReadExtractionService.swift` | 3 | `lungfish-extract-`, `lungfish-bam-dedup-`, `lungfish-bam-extract-` | Config already has `outputDirectory` — derive project from it |
| `EsVirituPipeline.swift` | 2 | `esviritu-` redirect, `_input_links` | Config has `outputDirectory` |
| `TaxTriagePipeline.swift` | 2 | `taxtriage-` redirect | Config has `outputDirectory` |
| `SPAdesAssemblyPipeline.swift` | 1 | `lungfish-spades-` | Config has `outputDirectory` |
| `OrientPipeline.swift` | 1 | `lungfish-orient-` | Config has `outputDirectory` |
| `DemultiplexingPipeline.swift` | 1 | `lungfish-demux-` | Config has `outputDirectory` |
| `DemultiplexingPipeline+Scout.swift` | 1 | `lungfish-scout-` | Config has `outputDirectory` |

#### LungfishApp (UI/service layer)

| File | Sites | Current prefix | Notes |
|------|-------|---------------|-------|
| `FASTQDerivativeService.swift` | 8 | `lungfish-virtual-orient-`, `lungfish-demux-trim-`, `lungfish-trim-`, `lungfish-fasta-*`, `bbduk-primer-`, `makeTemporaryDirectory` | Bundle URL available in all call paths |
| `AppDelegate.swift` materialization | 5 | `lungfish-minimap2-`, `lungfish-orient-`, `lungfish-classify-`, `lungfish-esviritu-`, `lungfish-taxtriage-` | Project URL available from bundle context |
| `AppDelegate.swift` export/import | 3 | `export-`, `export-decomp-`, VCF import log | Project URL available |
| `AlignmentDuplicateService.swift` | 1 | `.markdup-` | Output URL available |
| `ReferenceBundleImportService.swift` | 1 | `lungfish-ref-import-` | Output directory parameter |
| Classifier result controllers | 4 | `esviritu-extract-`, `naomgs-extract-`, `taxtriage-extract-`, `nvd-extract-` | `bundleURL` / `findProjectRoot` available |
| `FASTQIngestionService.swift` | 1 | `lungfish-fastq-ingest-` | Input URL available for same-volume optimization |
| `FASTQDatasetViewController.swift` | 1 | `lungfish-fasta-preview-` | Bundle URL available |
| `AssemblyConfigurationViewModel.swift` | 1 | `lungfish-assembly-` | Bundle URL available for materialization |
| `GenBankBundleDownloadViewModel.swift` | 2 | `lungfish-genbank-`, `lungfish-sequence-` | Output directory available |
| `GenomeDownloadViewModel.swift` | 1 | `lungfish-genome-` | Output directory available |
| `DatabaseBrowserViewController.swift` | 1 | `lungfish-batch-` | Output directory available |
| `MainSplitViewController.swift` | 1 | `lungfish-ref-` | Project URL available |

#### LungfishCore (services)

| File | Sites | Notes |
|------|-------|-------|
| `BlastService.swift` | 2 | BLAST debug + ZIP decompression — no project context, stays in system temp |
| `NCBIService.swift` | 1 | URLSession delegate copy — framework requirement, stays in system temp |
| `SRAService.swift` | 1 | Download staging — no project context until download completes, stays in system temp |

#### LungfishCLI

| File | Sites | Notes |
|------|-------|-------|
| `ImportCommand.swift` | 1 | `lungfish-cli-ref-import-` — has output directory parameter |
| `FastqCommand.swift` | 2 | `bbmerge-`, `bbrepair-` — has output path to derive project |
| `FetchCommand.swift` | 1 | `.lungfish-temp-` — genome fetch workspace |

#### LungfishWorkflow (additional)

| File | Sites | Current prefix | Notes |
|------|-------|---------------|-------|
| `FASTQIngestionPipeline.swift` | 1 | `lungfish-bbtools-` | Symlink workaround — config has output dir |
| `NativeToolRunner.swift` | 1 | `lungfish-bbtools-` | Symlink workaround for BBTools spaces |

### 4. What Stays in System Temp

These legitimately have no project context:

- **BLAST service**: Queries happen before any project association
- **NCBI/SRA downloads**: URLSession delegate copies (framework pattern — file immediately moved)
- **Database downloads**: Metagenomics DB downloads happen in Plugin Manager, no project
- **Tool version checks**: No files written, just working directory for Process
- **nf-core schema parsing**: One-shot schema file, no project context

### 5. Cleanup Strategy

**On app launch**: `TempFileManager.cleanupOnLaunch()` is updated to call `ProjectTempDirectory.cleanAll(in:)` for the currently-open project (if any). The entire `.tmp/` directory is deleted — aggressive cleanup as specified.

**Menu item**: File > "Clear Temporary Files..." (or under the project menu if one exists). Shows a confirmation alert with the current `.tmp/` size via `ProjectTempDirectory.diskUsage()`, then calls `cleanAll()`. Available when a project is open.

**Long-running session handling**: A periodic timer (every 4 hours while the app is running) scans `.tmp/` and removes subdirectories older than 24 hours. This prevents accumulation during multi-day sessions without relaunch. Only stale subdirectories are removed — active operations are not interrupted because their temp dirs are younger than 24h.

### 6. Debug Guard Assertion

In `TempFileManager`, add a `#if DEBUG` check that runs on a 60-second timer:

```swift
#if DEBUG
// Scan system temp for lungfish-* directories that should be in project .tmp/
// Log a warning with the offending path and callsite hint
#endif
```

This catches new code that accidentally uses system temp instead of `ProjectTempDirectory`. The check is development-only and has no production impact.

### 7. Container Mount Updates

**SPAdes (Docker)**: Currently mounts system temp as a bind mount. Change to mount `project.lungfish/.tmp/lungfish-spades-{UUID}/` instead. Since it's on the same volume as the project, no cross-volume penalty.

**TaxTriage (Nextflow/Docker)**: The space-in-path redirect already creates a temp dir and copies results back. Change the temp dir to be inside `.tmp/`. The Nextflow working directory (`-work-dir`) is also redirected to `.tmp/`.

**EsViritu (conda)**: The `_input_links` symlink directory is already created inside the output directory. The safe-output redirect (for spaces) moves to `.tmp/`.

### 8. Thread Safety

`ProjectTempDirectory` is a stateless enum with static methods — no shared mutable state. Directory creation uses `createDirectory(withIntermediateDirectories: true)` which is filesystem-atomic. UUID suffixes prevent collisions between concurrent operations.

### 9. CLI Support

The CLI commands (`lungfish extract`, `lungfish fastq`) don't always have a project context. When `--output` points into a `.lungfish` project, temp files go to that project's `.tmp/`. Otherwise, system temp is used. No special flags needed.

## Appendix A: Complete Operations Registry

Every GUI operation type that may create temp files (from `OperationType` enum):

| Operation Type | Temp Prefix(es) | Migration Target |
|---------------|-----------------|-----------------|
| `classification` | `lungfish-classify-` | Project `.tmp/` |
| `taxonomyExtraction` | `esviritu-extract-`, `naomgs-extract-`, `taxtriage-extract-`, `nvd-extract-` | Project `.tmp/` |
| `fastqOperation` | `lungfish-trim-`, `lungfish-virtual-orient-`, `lungfish-demux-`, `lungfish-scout-`, `bbduk-primer-`, `lungfish-fasta-*` | Project `.tmp/` |
| `assembly` | `lungfish-spades-`, `lungfish-assembly-` | Project `.tmp/` |
| `ingestion` | `lungfish-fastq-ingest-`, `lungfish-bbtools-` | Project `.tmp/` |
| `bamImport` | `.markdup-` | Project `.tmp/` |
| `vcfImport` | VCF import log | Project `.tmp/` |
| `bundleBuild` | `lungfish-genbank-`, `lungfish-sequence-`, `lungfish-ref-` | Project `.tmp/` |
| `download` | `lungfish-genome-` | Project `.tmp/` |
| `export` | `export-`, `export-decomp-` | Project `.tmp/` |
| `blastVerification` | `blast-zip-`, `lungfish-blast-debug` | System temp (no project context) |

## Appendix B: Complete CLI Command Registry

Every CLI command that creates temp files:

| Command | Subcommand | Temp Prefix | Migration Target |
|---------|-----------|-------------|-----------------|
| `lungfish extract reads` | `--by-id` | `lungfish-extract-` | Project `.tmp/` via `--output` path |
| `lungfish extract reads` | `--by-region` | `lungfish-bam-extract-`, `lungfish-bam-dedup-` | Project `.tmp/` via `--output` path |
| `lungfish import fasta` | | `lungfish-cli-ref-import-` | Project `.tmp/` via output dir |
| `lungfish fastq merge` | | `bbmerge-` | Project `.tmp/` via `--output` path |
| `lungfish fastq repair` | | `bbrepair-` | Project `.tmp/` via `--output` path |
| `lungfish fetch genome` | | `.lungfish-temp-` | Project `.tmp/` via `--output` path |
| `lungfish assemble` | | `lungfish-spades-` | Project `.tmp/` via output dir |
| `lungfish classify` | | `lungfish-classify-` | Project `.tmp/` via output dir |
| `lungfish esviritu` | | `esviritu-` | Project `.tmp/` via output dir |
| `lungfish taxtriage` | | `taxtriage-` | Project `.tmp/` via output dir |
| `lungfish orient` | | `lungfish-orient-` | Project `.tmp/` via output dir |
| `lungfish map` | | `lungfish-minimap2-` | Project `.tmp/` via output dir |

## Appendix C: Complete Temp Prefix Registry

All 30 known prefixes, their purpose, and migration status:

| Prefix | Purpose | Cleanup | Migrates to `.tmp/`? |
|--------|---------|---------|---------------------|
| `lungfish-extract-` | Read ID filtering | defer | Yes |
| `lungfish-bam-dedup-` | BAM deduplication | defer | Yes |
| `lungfish-bam-extract-` | BAM region extraction | defer | Yes |
| `lungfish-genbank-` | GenBank downloads | defer | Yes |
| `lungfish-genome-` | Genome downloads | defer | Yes |
| `lungfish-batch-` | Batch downloads | implicit | Yes |
| `lungfish-sequence-` | Sequence materialization | defer | Yes |
| `lungfish-ref-` | Reference downloads | defer | Yes |
| `lungfish-ref-import-` | Reference import | defer | Yes |
| `lungfish-cli-ref-import-` | CLI reference import | defer | Yes |
| `lungfish-assembly-` | Assembly materialization | defer | Yes |
| `lungfish-spades-` | SPAdes workspace | managed | Yes |
| `lungfish-classify-` | Classification materialization | defer | Yes |
| `lungfish-esviritu-` | EsViritu materialization | defer | Yes |
| `lungfish-taxtriage-` | TaxTriage materialization | defer | Yes |
| `lungfish-minimap2-` | Minimap2 materialization | defer | Yes |
| `lungfish-orient-` | Orientation workspace | defer | Yes |
| `lungfish-virtual-orient-` | Virtual FASTQ orientation | defer | Yes |
| `lungfish-trim-` | FASTQ trimming | defer | Yes |
| `lungfish-fasta-trim-` | FASTA trimming | defer | Yes |
| `lungfish-fasta-postrim-` | Post-trim FASTA ops | defer | Yes |
| `lungfish-fasta-preview-` | FASTA preview generation | defer | Yes |
| `lungfish-demux-` | Demultiplexing | defer | Yes |
| `lungfish-scout-` | Scout scouting | defer | Yes |
| `lungfish-demux-trim-` | Demux trim positions | defer | Yes |
| `lungfish-bbtools-` | BBTools symlink workaround | array | Yes |
| `lungfish-fastq-ingest-` | FASTQ ingestion fallback | implicit | Yes |
| `.lungfish-temp-` | CLI fetch workspace | defer | Yes |
| `esviritu-extract-` / `naomgs-extract-` / etc. | Classifier extraction temp | implicit | Yes |
| `export-` / `export-decomp-` | Export compression | defer | Yes |
| `.markdup-` | Duplicate marking | defer | Yes |
| `esviritu-` | EsViritu safe output redirect | manual | Yes |
| `taxtriage-` | TaxTriage safe output redirect | manual | Yes |
| `blast-zip-` | BLAST ZIP extraction | defer | No (no project context) |
| `lungfish-blast-debug` | BLAST debug output | persistent | No (no project context) |
| `bbduk-primer-` | BBDuk primer FASTA | defer | Yes |

## Testing

### Unit Tests

- `ProjectTempDirectory.tempRoot(for:)` returns correct path
- `ProjectTempDirectory.create(prefix:in:)` creates directory with correct structure
- `ProjectTempDirectory.create(prefix:in: nil)` falls back to system temp
- `ProjectTempDirectory.cleanAll(in:)` removes `.tmp/` and all contents
- `ProjectTempDirectory.diskUsage(in:)` returns correct byte count

### Integration Tests

- Extraction tests verify output files land inside project (already covered by `ReadExtractionServiceTests`)
- Pipeline tests verify intermediates are created in `.tmp/` not system temp
- Container mount tests verify Docker bind paths reference `.tmp/`

### Guard Assertion Test

- In debug builds, create a temp file via system temp with a `lungfish-` prefix and verify the guard fires
