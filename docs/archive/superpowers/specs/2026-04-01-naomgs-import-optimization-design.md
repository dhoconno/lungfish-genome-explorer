# NAO-MGS Import Optimization

**Date**: 2026-04-01
**Status**: Design
**Branch**: `nao-mgs-optimize`

## Problem

Importing a large NAO-MGS dataset (e.g., `virus_hits_final.tsv.gz` with ~70k unique accessions) has three issues:

1. **No preview progress**: The import sheet shows an indeterminate spinner while parsing the TSV. For large files this takes a long time with no indication of progress.
2. **Glacially slow reference fetch**: Every unique accession triggers an individual NCBI efetch request. With 70k accessions at ~3 req/sec, this would take hours or days. Most of these references are unnecessary — only the top accessions per taxon are displayed.
3. **No cleanup on cancellation**: When the user cancels (or the import fails), the partially-created result directory remains on disk. The sidebar tries to load it, causing hangs.

## Design

### 1. Preview Line Counter

**Files changed**: `NaoMgsResultParser.swift`, `NaoMgsImportSheet.swift`

Add an optional `lineProgress` callback to `parseVirusHits()`:

```swift
public func parseVirusHits(
    at url: URL,
    lineProgress: (@Sendable (Int) -> Void)? = nil
) async throws -> [NaoMgsVirusHit]
```

The parser calls `lineProgress?(lineNumber)` every 1,000 lines during parsing. This avoids flooding the UI while still showing rapid updates.

In `NaoMgsImportSheet`:
- Add `@State private var linesScanned: Int = 0`
- `scanResults()` passes a `lineProgress` closure that updates `linesScanned` on the main actor
- The preview section replaces the indeterminate `ProgressView()` spinner with: `"Scanning... 142,000 lines"` (formatted with thousands separators), still with a small indeterminate spinner alongside for visual activity

The callback is `@Sendable` and the sheet updates via `MainActor.run` to stay off the parser's thread. Update throttling is handled by only calling back every 1,000 lines.

### 2. Top-5 Accessions Per Taxon + Chunked Bulk Fetch

**Files changed**: `MetagenomicsImportService.swift`

#### 2a. Accession Filtering

Replace the current accession extraction:

```swift
// BEFORE: all unique accessions
let accessions = Array(Set(result.virusHits.map(\.subjectSeqId).filter { !$0.isEmpty })).sorted()
```

With a top-5-per-taxon selection:

1. Group hits by `(taxId, subjectSeqId)` — count hits per accession per taxon
2. For each taxon, sort accessions by hit count descending, keep top 5
3. Union across all taxa and deduplicate

This reduces 70k accessions to typically a few hundred (number of taxa * 5, minus shared accessions).

#### 2b. Chunked Bulk efetch

Replace `fetchNaoMgsReferences()` (which does one request per accession) with a chunked approach:

```swift
private static func fetchNaoMgsReferences(
    accessions: [String],
    into referencesDirectory: URL,
    progress: (@Sendable (Double, String) -> Void)?
) async -> [String]
```

Implementation:
- Split accessions into chunks of 200 (NCBI practical limit for comma-separated IDs in a GET request)
- For each chunk, call `NCBIService.efetch(database: .nucleotide, ids: chunk, format: .fasta)`
- The response is a concatenated multi-record FASTA. Split on lines starting with `>` to identify record boundaries.
- Extract the accession from each `>` header line (first whitespace-delimited token after `>`), write to `references/{accession}.fasta`
- If a chunk request fails, fall back to fetching that chunk's accessions individually (best-effort)
- Progress updates per chunk: `"Fetched references chunk N/M (X accessions)"`

This turns ~350 individual requests into ~2 bulk requests.

#### 2c. Store top accessions in taxon summaries

The `NaoMgsTaxonSummary.accessions` array currently contains ALL accessions for a taxon. The filtering happens only for reference fetching — the full accession list is preserved in the summaries for display. A new field `topAccessions: [String]` is not needed; the existing `accessions` array is kept intact and the filtering is local to the fetch function.

### 3. Cleanup on Cancellation/Failure

**Files changed**: `MetagenomicsImportHelperClient.swift`, `AppDelegate.swift`

#### 3a. Service returns result directory in errors

`MetagenomicsImportService.importNaoMgs()` creates the result directory early (before BAM conversion and reference fetching). If the function throws after directory creation, the caller has no way to know the path to clean up.

Fix: add a new error case to `MetagenomicsImportError`:

```swift
case importAborted(resultDirectory: URL, underlying: Error)
```

Wrap errors thrown after directory creation in this case so the directory path is preserved. The helper can then include the `resultPath` in its "error" event.

#### 3b. Helper emits resultPath on error

In `MetagenomicsImportHelper`, the `catch` block currently emits `resultPath: nil`. Change it to extract the directory from `MetagenomicsImportError.importAborted`:

```swift
} catch {
    let partialPath: String?
    if case .importAborted(let dir, _) = error as? MetagenomicsImportError {
        partialPath = dir.path
    } else {
        partialPath = nil
    }
    emit(Event(event: "error", ..., resultPath: partialPath, error: error.localizedDescription))
}
```

#### 3c. Client exposes partial path on failure

In `MetagenomicsImportHelperClient`, the "error" event handler already stores `helperError`. Also capture `resultPath` from error events into `ParseState.resultPath`.

Add a new error case:

```swift
case helperFailed(String, partialResultDirectory: URL?)
```

When building the error on non-zero exit, check if `ParseState.resultPath` is set and include it.

#### 3d. Cleanup in AppDelegate

In `importClassifierResultFromURL()`, the `catch` block:

```swift
} catch {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            OperationCenter.shared.fail(id: opID, detail: detail)
            // Cleanup partial result directory
            if let partialDir = (error as? MetagenomicsImportHelperClientError)?.partialResultDirectory {
                try? FileManager.default.removeItem(at: partialDir)
            }
            self?.showAlert(...)
        }
    }
}
```

A convenience computed property on `MetagenomicsImportHelperClientError`:

```swift
var partialResultDirectory: URL? {
    if case .helperFailed(_, let dir) = self { return dir }
    return nil
}
```

## Files Modified

| File | Change |
|------|--------|
| `Sources/LungfishIO/Formats/NaoMgs/NaoMgsResultParser.swift` | Add `lineProgress` callback to `parseVirusHits()` |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsImportSheet.swift` | Line counter UI, pass callback to parser |
| `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift` | Top-5 accession filter, chunked bulk efetch, `importAborted` error |
| `Sources/LungfishApp/Services/MetagenomicsImportHelperClient.swift` | Capture resultPath from error events, expose path in error |
| `Sources/LungfishApp/App/AppDelegate.swift` | Cleanup partial directory on failure |
| `Sources/LungfishApp/App/MetagenomicsImportHelper.swift` | Extract partialPath from `importAborted`, emit in error event |
| `Tests/Fixtures/naomgs/virus_hits_final.tsv.gz` | Toy dataset fixture |
| `Tests/LungfishIntegrationTests/TestFixtures.swift` | Add `naomgs` accessor group |

## Test Fixture: NAO-MGS Toy Dataset

### Source

Derived from the real CASPER dataset (`MU-CASPER-2026-03-31-a.3.0.1.20250825.virus_hits_final.tsv.gz`). Contains 35 real rows selected to exercise all code paths.

### Location

`Tests/Fixtures/naomgs/virus_hits_final.tsv.gz` (~5 KB compressed, ~26 KB uncompressed)

### Composition

| Taxon ID | Accessions | Reads | Purpose |
|----------|-----------|-------|---------|
| 28875 | 9 (KU048583.1, KU048553.1, KR705168.1, KY055429.1, KP882222.1, KP198630.1, JN258371.1, KJ752320.1, KU356637.1) | 20 | Tests top-5 filtering: top 5 have 3 reads each, bottom 4 have 1 read each. After filtering, only the top 5 accessions should be selected for reference fetch. |
| 10941 | 3 (KP198630.1, LC105580.1, LC105591.1) | 6 | Below 5-accession threshold: all kept. KP198630.1 is **shared with taxon 28875** — tests cross-taxon deduplication. |
| 2748378 | 2 (MH617353.1, MH617681.1) | 6 | Simple case: 2 accessions, both kept. |
| 1187973 | 1 (JQ776552.1) | 3 | Single-accession taxon from UP/DP pair status rows. |

### Properties tested

- **Top-5 accession filtering**: Taxon 28875 has 9 accessions; only top 5 by hit count should be fetched
- **Cross-taxon deduplication**: KP198630.1 appears in both 28875 (rank 6, should be filtered out) and 10941 (rank 1, should be kept). Net: fetched exactly once.
- **Pair status variety**: CP (32), UP (2), DP (1)
- **Forward/reverse strand**: Both True and False `prim_align_query_rc` values
- **v2 format**: All rows use the v2 column schema (`aligner_taxid_lca`, `prim_align_*`, etc.)

### Expected accessions after top-5-per-taxon filter

Taxon 28875 hit counts per accession: KR705168.1 (4), KU048583.1 (3), KU048553.1 (3), KY055429.1 (3), KP882222.1 (3), KP198630.1 (3), JN258371.1 (1), KJ752320.1 (1), KU356637.1 (1). Top 5: KR705168.1, then 4 of the 5 tied-at-3 accessions (tie-broken by sort order). KP198630.1 may or may not be in 28875's top 5 depending on tie-breaking — but it is always in 10941's set (rank 1 with 3 hits), so it will be fetched regardless.

Total: 5 (28875) + 3 (10941) + 2 (2748378) + 1 (1187973) = **11 unique accessions** (KP198630.1 counted once even if selected by both taxa).

### Type-safe accessors

Add to `TestFixtures.swift`:

```swift
public enum naomgs {
    private static let dir = "naomgs"

    /// Toy NAO-MGS virus_hits_final.tsv.gz (35 rows, v2 format, 4 taxa).
    public static var virusHitsTsvGz: URL { fixture("virus_hits_final.tsv.gz") }

    private static func fixture(_ name: String) -> URL {
        // same pattern as sarscov2
    }
}
```

## Testing Strategy

### Principle: CLI-first functional testing

All import logic lives in `MetagenomicsImportService` (shared by CLI and GUI). The GUI only adds UI chrome (sheets, operation center). Therefore:

1. **Automated tests exercise the CLI code path** — same service, same arguments
2. **Manual testing in the GUI** is only for UI-specific behavior (progress display, cancellation UX)
3. Test fixtures must be small enough for git and fast enough for CI

### Automated tests (Swift Testing, `LungfishWorkflowTests`)

All tests use the toy fixture at `Tests/Fixtures/naomgs/virus_hits_final.tsv.gz` and run with `fetchReferences: false` (no network) unless specifically testing the fetch path.

**1. Preview line progress callback**

```
Test: parseVirusHits calls lineProgress at expected intervals
Input: fixture virus_hits_final.tsv.gz
Assert: lineProgress called with values > 0, final call value == total lines parsed
Assert: returned hits count == 35
```

**2. Top-5 accession filtering**

```
Test: selectTopAccessionsPerTaxon returns correct accessions
Input: fixture parsed hits
Assert: taxon 28875 contributes exactly 5 accessions (the 5 with highest hit counts)
Assert: taxon 10941 contributes all 3 accessions (below threshold)
Assert: taxon 2748378 contributes all 2 accessions
Assert: taxon 1187973 contributes 1 accession
Assert: total unique accessions == 11
```

**3. Chunked bulk FASTA splitting**

```
Test: splitMultiRecordFASTA correctly parses concatenated FASTA
Input: synthetic multi-record FASTA string (>acc1\nACGT\n>acc2\nTGCA\n)
Assert: returns dict mapping accession -> full FASTA record text
Assert: handles accessions with version numbers (NC_045512.2)
Assert: handles multi-line sequences
```

**4. Full import pipeline (no network)**

```
Test: importNaoMgs with fetchReferences=false creates valid bundle
Input: fixture virus_hits_final.tsv.gz
Assert: result directory contains manifest.json, virus_hits.json
Assert: manifest.hitCount == 35, taxonCount == 4
Assert: virus_hits.json taxonSummaries sorted by hitCount descending
```

**5. Full import pipeline with alignment**

```
Test: importNaoMgs with includeAlignment=true creates BAM
Input: fixture virus_hits_final.tsv.gz
Assert: result directory contains {sample}.sorted.bam and .bam.bai
Assert: BAM is valid (samtools quickcheck or file size > 0)
```

**6. Cleanup on failure**

```
Test: importAborted error carries result directory path
Setup: trigger a failure after directory creation (e.g., invalid samtools path)
Assert: error is MetagenomicsImportError.importAborted with valid directory URL
Assert: caller can delete directory using the URL from the error
```

**7. Identity filtering with fixture**

```
Test: minIdentity filter reduces hit count
Input: fixture virus_hits_final.tsv.gz, minIdentity=99
Assert: result hitCount < 35 (some rows filtered out)
Assert: all remaining hits have percentIdentity >= 99
```

### Manual testing (GUI)

After automated tests pass:

1. Import the toy fixture via File > Import > Classification Results > NAO-MGS
   - Verify line counter appears during preview scan
   - Verify preview shows 35 hits, 4 taxa
2. Import the large CASPER dataset
   - Verify line counter updates during multi-million-row scan
   - Verify reference fetch completes in minutes (not hours)
   - Cancel mid-fetch and verify no stale directory in sidebar
