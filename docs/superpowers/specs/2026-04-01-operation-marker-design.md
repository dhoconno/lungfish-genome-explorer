# Shared OperationMarker for In-Progress Directory Hiding

**Date**: 2026-04-01
**Status**: Design
**Branch**: `nao-mgs-optimize`

## Problem

Long-running operations (imports, pipelines, FASTQ processing) create output directories early in their lifecycle. The sidebar's FileSystemWatcher sees these directories and displays them before the operation completes. This confuses users — they see incomplete results, and in some cases (e.g., NAO-MGS with a partial `manifest.json`), the app hangs trying to load half-written data.

FASTQ bundles already have a `.processing` marker file that hides them from the sidebar during ingestion. No other operation type has this protection.

## Design

### 1. Shared OperationMarker Utility

**New file**: `Sources/LungfishCore/Services/OperationMarker.swift`

A simple enum with static methods, using the same `.processing` sentinel filename already established by FASTQBundle:

```swift
public enum OperationMarker {
    /// Sentinel filename placed inside directories that are still being built.
    /// The sidebar hides any directory containing this file.
    ///
    /// **Convention**: Every operation that creates a user-visible directory
    /// (result folders, FASTQ bundles, reference bundles, derivative outputs)
    /// MUST call `markInProgress` immediately after directory creation and
    /// `clearInProgress` on successful completion. On failure, either clean up
    /// the directory entirely or leave the marker so the sidebar ignores it.
    public static let filename = ".processing"

    public static func isInProgress(_ directoryURL: URL) -> Bool
    public static func markInProgress(_ directoryURL: URL, detail: String = "Processing…")
    public static func clearInProgress(_ directoryURL: URL)
}
```

- `isInProgress`: checks if `.processing` exists in the directory
- `markInProgress`: writes `.processing` with a human-readable detail string
- `clearInProgress`: deletes `.processing`

### 2. Refactor FASTQBundle

`FASTQBundle` currently has its own independent implementation of the same pattern. Refactor to delegate:

- `FASTQBundle.isProcessing(_:)` → calls `OperationMarker.isInProgress(_:)`
- `FASTQBundle.markProcessing(_:detail:)` → calls `OperationMarker.markInProgress(_:detail:)`
- `FASTQBundle.clearProcessing(_:)` → calls `OperationMarker.clearInProgress(_:)`
- `FASTQBundle.processingState(of:)` → stays on FASTQBundle (returns bundle-specific `ProcessingState` enum), but reads the file via the same `.processing` path
- `FASTQBundle.processingMarkerFilename` → delegates to `OperationMarker.filename`

No behavioral change. All existing callers continue to work.

### 3. Sidebar Filtering

Each collector method in `SidebarViewController` adds an `OperationMarker.isInProgress` check to skip in-progress directories. Directories with the marker are **completely hidden** (not shown with a badge) because the Operations Panel already displays progress.

Methods to update:
- `collectClassificationResults(in:)` — skip `classification-*` dirs with marker
- `collectClassificationBatchResults(in:)` — skip `classification-batch-*` dirs with marker
- `collectEsVirituResults(in:)` — skip `esviritu-*` dirs with marker
- `collectEsVirituBatchResults(in:)` — skip `esviritu-batch-*` dirs with marker
- `collectTaxTriageResults(in:)` — skip `taxtriage-*` dirs with marker
- `collectNaoMgsResults(in:)` — skip `naomgs-*` dirs with marker
- `buildRootItems` / `buildSidebarTree` — existing `FASTQBundle.isProcessing` calls already work (they delegate to the same utility)

The check goes right after the directory prefix check and before any sidecar validation, e.g.:

```swift
guard childURL.lastPathComponent.hasPrefix("naomgs-") else { continue }
guard !OperationMarker.isInProgress(childURL) else { continue }  // NEW
```

### 4. Pipeline & Service Integration

Every service that creates a user-visible directory calls `markInProgress` immediately after creation and `clearInProgress` on success.

| Service | Method | Directory |
|---------|--------|-----------|
| `ClassificationPipeline` | `runPipeline()` | `classification-*` output dir |
| `EsVirituPipeline` | `detect()` | `esviritu-*` output dir |
| `TaxTriagePipeline` | `run()` | `taxtriage-*` output dir |
| `SPAdesAssemblyPipeline` | `createWorkspace()` | `assembly-*` output dir |
| `Minimap2Pipeline` | workspace creation | `mapping-*` output dir |
| `MetagenomicsImportService.importKraken2` | after `ensureDirectoryExists(resultDirectory)` | `classification-*` |
| `MetagenomicsImportService.importEsViritu` | after `ensureDirectoryExists(resultDirectory)` | `esviritu-*` |
| `MetagenomicsImportService.importTaxTriage` | after `ensureDirectoryExists(resultDirectory)` | `taxtriage-*` |
| `MetagenomicsImportService.importNaoMgs` | after `ensureDirectoryExists(resultDirectory)` | `naomgs-*` |
| `FASTQIngestionService` | `runIngestAndBundle()` | `.lungfishfastq` (already has marker — refactored to delegate) |
| `FASTQDerivativeService` | orient/demux/virtual outputs | derivative `.lungfishfastq` bundles |
| `BAMImportService` | `importBAM()` | alignment dirs inside bundles |
| `ReferenceBundleImportService` | `importAsReferenceBundle()` | `.lungfishref` bundles |

Pattern at each call site:

```swift
try ensureDirectoryExists(resultDirectory)
OperationMarker.markInProgress(resultDirectory, detail: "Importing Kraken2 results…")
defer { OperationMarker.clearInProgress(resultDirectory) }
// ... do work ...
```

The `defer` ensures the marker is cleared on both success and failure paths. On failure, if the cleanup code (from the earlier `importAborted` work) deletes the entire directory, the marker goes with it. If the directory is left behind for any reason, the marker keeps it hidden from the sidebar.

### 5. Failure Behavior

Three scenarios on operation failure:

1. **Directory deleted by cleanup** (e.g., `importAborted` + AppDelegate cleanup): Marker removed with directory. Sidebar never sees it.
2. **Directory left behind, marker still present**: Sidebar hides it. User can manually delete via Finder if desired.
3. **Directory left behind, marker absent** (shouldn't happen with `defer`): Sidebar shows incomplete results — but this is the current behavior, not a regression.

Scenario 2 is the safe fallback. The `defer` pattern makes scenario 3 nearly impossible.

## Files Modified

| File | Change |
|------|--------|
| `Sources/LungfishCore/Services/OperationMarker.swift` | **Create** — shared marker utility |
| `Sources/LungfishIO/Formats/FASTQ/FASTQBundle.swift` | Refactor processing marker to delegate to OperationMarker |
| `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` | Add `isInProgress` checks in all collector methods |
| `Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift` | Add marker around pipeline run |
| `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift` | Add marker around detect |
| `Sources/LungfishWorkflow/TaxTriage/TaxTriagePipeline.swift` | Add marker around run |
| `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift` | Add marker around workspace creation |
| `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift` | Add marker in all four import methods |
| `Sources/LungfishApp/Services/FASTQIngestionService.swift` | Refactor to use OperationMarker (via FASTQBundle delegation) |
| `Sources/LungfishApp/Services/FASTQDerivativeService.swift` | Add marker for derivative bundle creation |
| `Sources/LungfishApp/Services/BAMImportService.swift` | Add marker for alignment directory |
| `Sources/LungfishApp/Services/ReferenceBundleImportService.swift` | Add marker for reference bundle |
| `Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift` | Add marker around mapping run |

## Testing

- Unit test: `OperationMarker.markInProgress` / `isInProgress` / `clearInProgress` round-trip
- Unit test: `FASTQBundle.isProcessing` still works after refactor (delegates correctly)
- Unit test: `OperationMarker.isInProgress` returns false for directory without marker
- Integration test: `importNaoMgs` with marker — verify marker exists during import and is cleared after
- Manual test: run a long operation (NAO-MGS import of CASPER dataset), verify sidebar does not show the result directory until complete
