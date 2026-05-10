# Universal ReadExtractionService

**Date:** 2026-04-03
**Branch:** `feature/classifier-interface-parity` (continuing)
**Scope:** Centralize all read extraction and FASTQ source resolution into one service used by classifiers, mappers, and assemblers.

---

## Problem

Read extraction is implemented ad-hoc in 3+ places:
- `TaxonomyExtractionPipeline` (Kraken2 — seqkit grep by read ID)
- `EsVirituResultViewController.runBamExtractionPipeline` (BAM region extraction)
- `NaoMgsDatabase.fetchReadsForAccession` (SQLite query)

Each has its own error handling, BAM reference matching, FASTQ source resolution, and bundle creation logic. Bugs in one (e.g., BAM reference name mismatch) get fixed locally without benefiting others. Virtual FASTQ materialization is scattered across `AppDelegate`, `FASTQDerivativeService`, and individual pipelines.

## Design

### ReadExtractionService (Actor)

A single actor in `LungfishWorkflow/Extraction/` that handles all read extraction.

```swift
/// Universal service for extracting reads from any tool's output.
///
/// Three extraction strategies behind a common interface:
/// 1. Read ID filtering (seqkit grep) — Kraken2 + any per-read classification
/// 2. BAM region extraction (samtools view + fastq) — EsViritu, TaxTriage, mappers, assemblers
/// 3. Database query (SQLite) — NAO-MGS
public actor ReadExtractionService {
    public static let shared = ReadExtractionService()

    // MARK: - Extraction Methods

    /// Extract reads matching a set of read IDs from FASTQ file(s).
    public func extractByReadIDs(
        _ config: ReadIDExtractionConfig,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> ExtractionResult

    /// Extract reads from BAM regions using samtools.
    public func extractByBAMRegion(
        _ config: BAMRegionExtractionConfig,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> ExtractionResult

    /// Extract reads from a SQLite database (NAO-MGS pattern).
    public func extractFromDatabase(
        _ config: DatabaseExtractionConfig,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> ExtractionResult

    // MARK: - Bundle Creation

    /// Wrap extracted FASTQ(s) into a .lungfishfastq bundle.
    public func createBundle(
        from result: ExtractionResult,
        bundleName: String,
        parentDirectory: URL,
        metadata: ExtractionMetadata
    ) throws -> URL
}
```

### FASTQSourceResolver

Centralized FASTQ source resolution replacing ad-hoc materialization:

```swift
/// Resolves readable FASTQ file(s) for any bundle type.
///
/// Handles physical FASTQs, virtual subsets, trim derivatives,
/// demux bundles, and multi-file concatenations. Materializes
/// virtual bundles to temporary files when needed.
public actor FASTQSourceResolver {
    public static let shared = FASTQSourceResolver()

    /// Resolve the actual readable FASTQ file(s) for a bundle.
    ///
    /// - Parameters:
    ///   - bundleURL: The .lungfishfastq bundle URL
    ///   - tempDirectory: Where to write materialized files
    ///   - progress: Progress callback
    /// - Returns: One or two FASTQ file URLs (single/paired-end)
    public func resolve(
        bundleURL: URL,
        tempDirectory: URL,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> [URL]
}
```

Resolution order:
1. Check for physical FASTQ file in bundle → return directly
2. Check for `derived.manifest.json` → materialize from root bundle + read IDs/trim positions
3. Check for `source-files.json` → resolve multi-file virtual concatenation
4. Fallback: scan bundle directory for any .fastq/.fastq.gz file

### Configuration Types

```swift
/// Configuration for read-ID-based extraction (Kraken2 pattern).
public struct ReadIDExtractionConfig: Sendable {
    public let sourceFASTQs: [URL]           // One or two FASTQ files
    public let readIDs: Set<String>          // Read IDs to extract
    public let keepReadPairs: Bool           // Strip /1 /2 suffixes (default true)
    public let outputDirectory: URL
    public let outputBaseName: String
}

/// Configuration for BAM-region-based extraction.
public struct BAMRegionExtractionConfig: Sendable {
    public let bamURL: URL
    public let regions: [String]             // Reference names or genomic regions
    public let outputDirectory: URL
    public let outputBaseName: String
}

/// Configuration for database-based extraction (NAO-MGS pattern).
public struct DatabaseExtractionConfig: Sendable {
    public let databaseURL: URL
    public let sampleId: String
    public let taxIds: [Int]
    public let accessions: [String]
    public let maxReads: Int?                // nil = all reads
    public let outputDirectory: URL
    public let outputBaseName: String
}

/// Result from any extraction method.
public struct ExtractionResult: Sendable {
    public let fastqURLs: [URL]              // Extracted FASTQ file(s)
    public let readCount: Int
    public let pairedEnd: Bool
    public let provenance: ProvenanceRecord?
}

/// Metadata for the output bundle.
public struct ExtractionMetadata: Sendable {
    public let sourceDescription: String     // "Kraken2 classification", "EsViritu BAM", etc.
    public let toolName: String
    public let extractionDate: Date
    public let parameters: [String: String]  // Tool-specific key-value pairs
}
```

### BAM Region Matching (Centralized)

The multi-strategy BAM reference matching logic moves from `EsVirituResultViewController` to `ReadExtractionService`:

```swift
/// Match requested regions against BAM @SQ reference names.
///
/// Tries multiple strategies in order:
/// 1. Exact match
/// 2. Prefix match (handles version suffixes)
/// 3. Contains match (handles embedded accessions)
/// 4. Fallback: extract all reads (BAM may already be pre-filtered)
private func matchRegionsToBAM(
    regions: [String],
    bamURL: URL
) async throws -> RegionMatchResult
```

All tools that extract from BAM (EsViritu, TaxTriage, NVD, mappers, assemblers) benefit from this single, well-tested matching logic.

### CLI Integration (REQUIRED)

**Every extraction capability must be CLI-backed.** The GUI calls the same `ReadExtractionService` that the CLI uses. No GUI-only features.

#### Command Structure

```
lungfish extract reads --by-id \
    --ids read-ids.txt \
    --source input.fastq \
    [--source-r2 input_R2.fastq] \
    [--keep-read-pairs | --no-keep-read-pairs] \
    -o output.fastq

lungfish extract reads --by-region \
    --bam aligned.bam \
    --region NC_005831.2 [--region NC_001477.1 ...] \
    -o output.fastq

lungfish extract reads --by-db \
    --database results.naomgs.db \
    --sample S1 \
    --taxid 12345 [--taxid 67890 ...] \
    [--accession GCF_000870785.1 ...] \
    [--max-reads 10000] \
    -o output.fastq
```

All three strategies exposed as subcommands under `lungfish extract reads`. Each uses the same `ReadExtractionService` actor as the GUI.

#### CLI-GUI Parity Rule

The Operations Panel log for every GUI extraction must show the equivalent CLI command that would reproduce the same result. Pattern:

```
lungfish extract reads --by-region --bam /path/to/sample.bam --region NC_005831.2 -o /path/to/output.fastq
```

This replaces all `"(CLI command not yet available — use GUI)"` placeholders. If a GUI action cannot be expressed as a CLI command, that is a design bug that must be fixed before shipping.

#### Existing `lungfish conda extract` Migration

The existing `CondaExtractCommand` (Kraken2-specific) is superseded by `lungfish extract reads --by-id`. The old command should remain as a deprecated alias that delegates to the new command, with a deprecation warning printed to stderr.

#### Bundle Creation via CLI

```
lungfish extract reads --by-region --bam sample.bam --region NC_005831.2 \
    -o output.fastq \
    --bundle                         # Wrap output in a .lungfishfastq bundle
    --bundle-name "sample_virus_extract"  # Optional display name
```

The `--bundle` flag triggers `ReadExtractionService.createBundle()`. Without it, the CLI outputs raw FASTQ files (useful for pipelines). The GUI always uses `--bundle` implicitly.

#### File

- Create: `Sources/LungfishCLI/Commands/ExtractReadsCommand.swift` — ArgumentParser command with 3 strategy subcommands

### Bundle and Display Naming

Extraction output names must be informative in the sidebar — never "materialized", "extracted", "output", or other generic names. The `createBundle()` method enforces a naming convention:

**Pattern:** `{sourceName}_{selectionDescription}_extract`

Examples:
- Kraken2 single taxon: `SRR35520572_Human_coronavirus_OC43_extract.lungfishfastq`
- Kraken2 multi-taxon: `SRR35520572_3_taxa_extract.lungfishfastq`
- EsViritu assembly: `sample1_Rift_Valley_fever_virus_extract.lungfishfastq`
- TaxTriage organism: `sample1_E_coli_extract.lungfishfastq`
- NAO-MGS taxon: `sample1_Influenza_A_extract.lungfishfastq`
- Mapper region: `sample1_chr1_1000_2000_extract.lungfishfastq`

**Source name resolution:** The `sourceName` component comes from the FASTQ bundle's sidebar display name (via `FASTQDisplayNameResolver`), NOT from internal file paths or temp file names. If the source is a virtual FASTQ, the display name from its `FASTQDerivedBundleManifest.name` is used.

**Selection description:** The caller provides a human-readable description of what was selected (taxon name, organism name, region). For multi-select, use count: "3 taxa", "5 organisms".

**Sanitization:** Bundle names are filesystem-safe: spaces → underscores, strip special characters, truncate to 200 chars.

The `createBundle()` method:
1. Builds the name from source + selection
2. Writes a `FASTQDerivedBundleManifest` with the display name (so the sidebar shows a readable title)
3. Writes `ExtractionMetadata` sidecar with full provenance
4. Never uses temp file names in any user-visible context

**`FASTQSourceResolver` temp files:** When materializing virtual FASTQs, temp files use UUIDs (not "materialized.fastq"). These temp files are intermediate — they're consumed by the extraction tool and deleted. They never become bundle names.

### File Structure

```
Sources/LungfishWorkflow/Extraction/
    ReadExtractionService.swift      — Main actor (3 extraction methods + bundle creation)
    FASTQSourceResolver.swift        — Centralized materialization/resolution
    ExtractionConfig.swift           — Config types (ReadID, BAMRegion, Database)
    ExtractionResult.swift           — Result type + metadata
    BAMRegionMatcher.swift           — Multi-strategy BAM reference matching
```

### Migration

| Current Code | Moves To |
|-------------|----------|
| `TaxonomyExtractionPipeline.extract()` | `ReadExtractionService.extractByReadIDs()` |
| `TaxonomyExtractionPipeline.buildReadIdSet()` | Stays (read ID parsing is Kraken2-specific) |
| `EsVirituResultVC.runBamExtractionPipeline()` | `ReadExtractionService.extractByBAMRegion()` |
| EsViritu multi-strategy BAM matching | `BAMRegionMatcher` |
| `ViewerVC+Taxonomy.createExtractedFASTQBundle()` | `ReadExtractionService.createBundle()` |
| `AppDelegate.materializeInputFilesIfNeeded()` | `FASTQSourceResolver.resolve()` |
| `FASTQDerivativeService.materializeDatasetFASTQ()` | Called by `FASTQSourceResolver` internally |

Existing callers (VCs, pipelines) become thin wrappers that build config structs and call the service. `TaxonomyExtractionPipeline` remains for Kraken2-specific read ID parsing but delegates the actual extraction + bundling to the service.

### What Stays Tool-Specific

- **Kraken2:** Parsing per-read classification TSV to build read ID sets
- **EsViritu:** Determining which accessions map to which assemblies
- **TaxTriage:** Looking up organism → reference accession mappings
- **NAO-MGS:** SQL queries against the database schema
- **NVD:** Contig name extraction from outline view items

These remain in their respective VCs/pipelines. Only the common extraction, matching, and bundling moves to the service.

## Non-Goals

- Changing how tools produce their output (BAM, TSV, SQLite) — those stay as-is
- Changing the sidebar discovery mechanism
- Refactoring FASTQDerivativeService internals (the resolver wraps it, doesn't replace it)

## Hard Requirements

- **CLI parity:** Every extraction operation available in the GUI MUST have a CLI equivalent. The GUI and CLI share the same `ReadExtractionService` actor.
- **Reproducible CLI commands:** The Operations Panel MUST log the CLI command for every extraction. No "(CLI command not yet available)" placeholders.

## Testing

- Unit tests for `BAMRegionMatcher` — exact, prefix, contains, fallback strategies
- Unit tests for `FASTQSourceResolver` — physical FASTQ, virtual subset, multi-file
- Integration tests: extract from test fixtures BAM with known regions
- Regression: existing `TaxonomyExtractionTests` must continue passing
