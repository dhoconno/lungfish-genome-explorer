# SRA Download → CLI Import Pipeline Integration

**Date**: 2026-04-05
**Branch**: `fastq-vsp2-optimization`
**Status**: Design

## Goal

Route SRA-downloaded FASTQ files through the same CLI-backed import pipeline used for disk imports. Users get the same config sheet (platform, recipe, compression) for SRA downloads as for local FASTQ imports.

## Current Flow

```
User selects SRA records → Download FASTQ from ENA → FASTQIngestionPipeline (clumpify only, hardcoded Illumina4) → Bundle in Downloads/
```

No recipe selection, no platform choice, no compression option. Hardcoded defaults.

## New Flow

```
User selects SRA records → FASTQImportConfigSheet (platform from ENA, recipe picker) → Download FASTQ from ENA → CLIImportRunner (full pipeline) → Bundle in Downloads/
```

## Changes

### 1. Show config sheet before download

In `DatabaseBrowserViewController`, when the user clicks "Download", present `FASTQImportConfigSheet` before starting the download. The sheet is pre-populated with:

- **Platform**: mapped from `ENAReadRecord.instrumentPlatform`:
  - `"ILLUMINA"` → `.illumina`
  - `"OXFORD_NANOPORE"` → `.oxfordNanopore`
  - `"PACBIO_SMRT"` → `.pacbio`
  - `"ULTIMA"` → `.ultima`
  - Other/nil → `.unknown`
- **Recipe**: from `RecipeRegistryV2.allRecipes(platform:)` filtered to the detected platform
- **Pairing**: from `ENAReadRecord.libraryLayout` (`"PAIRED"` → paired-end, else single-end)

The user can override any of these. The resulting `FASTQImportConfiguration` is passed to the download task.

### 2. Replace FASTQIngestionPipeline with CLIImportRunner

In the post-download section of `DatabaseBrowserViewController` (currently ~lines 1896-2028), replace:

```swift
let pipeline = FASTQIngestionPipeline()
let ingestionResult = try await pipeline.run(config: ingestionConfig)
```

With the same `CLIImportRunner`-based approach used in `FASTQIngestionService.ingestAndBundle()`:

```swift
let args = CLIImportRunner.buildCLIArguments(
    r1: r1URL, r2: r2URL,
    projectDirectory: projectDirectory,
    platform: importConfig.confirmedPlatform,
    recipeName: importConfig.recipeName,
    qualityBinning: importConfig.qualityBinning.rawValue,
    optimizeStorage: !importConfig.skipClumpify,
    compressionLevel: importConfig.compressionLevel?.rawValue ?? "balanced"
)
let runner = CLIImportRunner()
await runner.run(arguments: args, operationID: opID, ...)
```

### 3. Preserve ENA metadata

After `CLIImportRunner` creates the bundle, write ENA-specific metadata:

```swift
var metadata = FASTQMetadataStore.load(for: bundleFASTQURL) ?? PersistedFASTQMetadata()
metadata.enaReadRecord = readRecord
metadata.downloadDate = Date()
metadata.downloadSource = "ENA"
metadata.sequencingPlatform = detectedPlatform
FASTQMetadataStore.save(metadata, for: bundleFASTQURL)
```

This augments the metadata the CLI already wrote (ingestion, stats, recipe).

### 4. Bundle destination stays Downloads/

The CLI creates bundles in `Imports/`. The existing AppDelegate `handleMultipleDownloadsSync` handler moves them to `Downloads/`. No change needed here.

## Non-Goals

- Changing the ENA download mechanism (HTTP streaming stays as-is)
- Modifying the Database Browser search/filter UI
- Adding per-record config overrides (global config applies to batch)

## File Changes

| File | Changes |
|------|---------|
| `Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift` | Show config sheet before download, pass config to download task, replace FASTQIngestionPipeline with CLIImportRunner |

## Testing

- Download an SRA record with recipe selected → verify pipeline steps appear in Operations Panel
- Check Document Inspector → verify recipe steps, ENA metadata, and stats all present
- Verify bundle appears in Downloads/ (not Imports/)
