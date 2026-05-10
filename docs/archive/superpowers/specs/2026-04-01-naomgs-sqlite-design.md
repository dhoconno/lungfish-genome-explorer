# SQLite-Backed NAO-MGS Data Store + Sample Filtering

**Date**: 2026-04-01
**Status**: Design
**Branch**: `nao-mgs-optimize`

## Problem

The NAO-MGS result viewer has three issues with large datasets:

1. **Crash**: Spawns 10 concurrent `samtools view` processes to render miniBAMs, exhausting file handles and crashing with `NSFileHandleOperationException`
2. **Incorrect counts**: Taxon summaries (hit count, unique reads) are aggregated across all samples, which is meaningless — users need per-sample counts
3. **Poor sample filtering**: Free-text search field requires users to know sample names; no way to browse and select from the sample list

## Design

Replace `virus_hits.json` and the BAM file with a SQLite database (`hits.sqlite`). Taxon summaries are precomputed per (sample, taxon) pair at import time. A popover-based sample picker replaces the free-text search field. The taxonomy table shows one row per (sample, taxon), and each row's detail pane shows the top 5 accessions for that specific sample.

### 1. Database Schema

File: `hits.sqlite` inside the result bundle.

```sql
-- Raw virus hit data (one row per read alignment)
CREATE TABLE virus_hits (
    rowid INTEGER PRIMARY KEY,
    sample TEXT NOT NULL,
    seq_id TEXT NOT NULL,
    tax_id INTEGER NOT NULL,
    subject_seq_id TEXT NOT NULL,
    subject_title TEXT NOT NULL,
    ref_start INTEGER NOT NULL,
    cigar TEXT NOT NULL,
    read_sequence TEXT NOT NULL,
    read_quality TEXT NOT NULL,
    percent_identity REAL NOT NULL,
    bit_score REAL NOT NULL,
    e_value REAL NOT NULL,
    edit_distance INTEGER NOT NULL,
    query_length INTEGER NOT NULL,
    is_reverse_complement INTEGER NOT NULL,
    pair_status TEXT NOT NULL,
    fragment_length INTEGER NOT NULL,
    best_alignment_score REAL NOT NULL
);

CREATE INDEX idx_hits_sample_taxon_accession ON virus_hits(sample, tax_id, subject_seq_id);
CREATE INDEX idx_hits_taxon_accession ON virus_hits(tax_id, subject_seq_id);
CREATE INDEX idx_hits_sample ON virus_hits(sample);

-- Precomputed per-(sample, taxon) summaries
-- Each row is one entry in the taxonomy table
CREATE TABLE taxon_summaries (
    sample TEXT NOT NULL,
    tax_id INTEGER NOT NULL,
    name TEXT NOT NULL,
    hit_count INTEGER NOT NULL,
    unique_read_count INTEGER NOT NULL,
    avg_identity REAL NOT NULL,
    avg_bit_score REAL NOT NULL,
    avg_edit_distance REAL NOT NULL,
    pcr_duplicate_count INTEGER NOT NULL,
    accession_count INTEGER NOT NULL,
    top_accessions_json TEXT NOT NULL,  -- JSON array of top 5 accessions by unique reads
    PRIMARY KEY (sample, tax_id)
);

CREATE INDEX idx_summaries_sample ON taxon_summaries(sample);
CREATE INDEX idx_summaries_hitcount ON taxon_summaries(sample, hit_count DESC);
```

The `taxon_summaries` table is the **primary data source** for the taxonomy table in the viewer. Each row maps directly to one table row. No runtime aggregation needed.

### 2. Import-Time Summary Computation

During `NaoMgsDatabase.create()`, after bulk-inserting all hits:

1. **Group by (sample, tax_id)**: Count hits, compute avg identity/bit score/edit distance
2. **Compute unique reads per (sample, tax_id)**: Group by `(sample, tax_id, subject_seq_id, ref_start, is_reverse_complement, query_length)` — rows with identical values are PCR duplicates. Unique read count = total - duplicates.
3. **Compute top 5 accessions per (sample, tax_id)**: For each (sample, taxon), group hits by `subject_seq_id`, count unique reads per accession, sort descending, take top 5. Store as JSON array.
4. **Insert into `taxon_summaries`**: One row per (sample, tax_id) pair.

All of this is SQL aggregation within a single transaction. For 8M rows this takes seconds.

### 3. NaoMgsDatabase Class

**New file**: `Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift`

```swift
public final class NaoMgsDatabase: Sendable {
    /// Opens an existing database (for the viewer).
    public init(at url: URL) throws

    /// Creates a new database, inserts hits, and computes summaries (for import).
    public static func create(
        at url: URL,
        hits: [NaoMgsVirusHit],
        progress: (@Sendable (Double, String) -> Void)?
    ) throws -> NaoMgsDatabase

    // -- Sample queries --

    /// Returns all distinct sample names with their total hit counts, sorted by name.
    public func fetchSamples() throws -> [(sample: String, hitCount: Int)]

    // -- Taxonomy table queries --

    /// Returns taxon summary rows for the given samples, sorted by hit count descending.
    /// Each row is a (sample, taxon) pair. If `samples` is nil, returns all rows.
    public func fetchTaxonSummaryRows(
        samples: [String]?
    ) throws -> [NaoMgsTaxonSummaryRow]

    // -- Detail pane queries --

    /// Returns the top 5 accession names for a (sample, taxon) pair.
    /// Read from the precomputed `top_accessions_json` column.
    public func fetchTopAccessions(
        sample: String,
        taxId: Int
    ) throws -> [String]

    /// Returns per-accession read/unique counts for a (sample, taxon) pair.
    /// Only returns accessions in the top-5 list.
    public func fetchAccessionSummaries(
        sample: String,
        taxId: Int
    ) throws -> [NaoMgsAccessionSummary]

    // -- MiniBAM read queries --

    /// Returns hits for a specific (sample, taxon, accession) as AlignedRead objects.
    public func fetchReadsForAccession(
        sample: String,
        taxId: Int,
        accession: String,
        maxReads: Int = .max
    ) throws -> [AlignedRead]

    /// Total hit count across given samples (or all if nil).
    public func totalHitCount(samples: [String]?) throws -> Int
}
```

### 4. Data Types

**NaoMgsTaxonSummaryRow** — one row in the taxonomy table:

```swift
public struct NaoMgsTaxonSummaryRow: Sendable {
    public let sample: String
    public let taxId: Int
    public let name: String
    public let hitCount: Int
    public let uniqueReadCount: Int
    public let avgIdentity: Double
    public let avgBitScore: Double
    public let avgEditDistance: Double
    public let pcrDuplicateCount: Int
    public let accessionCount: Int
    public let topAccessions: [String]  // decoded from JSON
}
```

**NaoMgsAccessionSummary** — per-accession data in the detail pane:

```swift
public struct NaoMgsAccessionSummary: Sendable {
    public let accession: String
    public let readCount: Int
    public let uniqueReadCount: Int
    public let estimatedRefLength: Int
    public let coverageFraction: Double
}
```

### 5. Sample Filter UI

**Replace** the `NSSearchField` (`sampleFilterField`) with an `NSButton` that opens an `NSPopover` containing a sample picker.

#### Button appearance

- Default label: **"All Samples"**
- With selection: **"3 of 199 Samples"** or **"CA_LosAngeles_20260304"** (when 1 selected)
- Style: standard `NSButton`, sits in the filter bar where `sampleFilterField` was

#### Popover content (SwiftUI via NSHostingView)

```
┌─ Samples ──────────────────────────────────────────┐
│ [🔍 Filter...                                    ] │
│                                                     │
│ ☑ Select All                             199 total  │
│ ─────────────────────────────────────────────────── │
│ ☑ CA_LosAngeles_County_20260304           12,340    │
│ ☑ CA_LosAngeles_County_20260308            8,921    │
│ ☑ CA_PaloAlto_RWQCP_20260309              6,453    │
│ ☐ NY_Syracuse_Metro_20260311               4,102    │
│ ☐ TX_Houston_20260315                      3,877    │
│ ☐ Water_20260323                          50,790    │
│   ...                                               │
└─────────────────────────────────────────────────────┘
```

Features:
- **Search field** at top filters the sample list by substring match
- **"Select All" toggle** selects/deselects all visible samples
- Each row: checkbox + sample display name + hit count (thousands-separated)
- **Common prefix stripping**: If all samples share a prefix (e.g., `MU-CASPER-2026-03-31-a-`), strip it from display. Show stripped prefix as a caption.
- Scrollable list, sorted alphabetically
- Popover dismissal triggers taxonomy table reload with new sample selection

#### State management

- `selectedSamples: Set<String>` on the result view controller
- Default: all samples selected
- When selection changes: re-query `fetchTaxonSummaryRows(samples:)` and reload table

### 6. Taxonomy Table Change

The taxonomy table currently shows one row per taxon. It changes to one row per **(sample, taxon)** pair:

| Column | Source |
|--------|--------|
| Taxon | `name` from `taxon_summaries` |
| Sample | `sample` from `taxon_summaries` (display name, prefix-stripped) |
| Hits | `hit_count` |
| Unique | `unique_read_count` |
| Refs | `accession_count` |
| Avg Identity | `avg_identity` |

Add a **Sample** column to the table. When only one sample is selected, this column can be hidden (since all rows are the same sample).

Sorting: default by hit count descending. The table supports clicking column headers to sort.

### 7. Detail Pane Change

When the user clicks a taxonomy table row, the detail pane shows data for that **(sample, taxon)** pair:

- Accession summaries from `db.fetchAccessionSummaries(sample:taxId:)` — only the top 5 accessions
- MiniBAMs from `db.fetchReadsForAccession(sample:taxId:accession:)` — reads for that sample only

### 8. Bundle Structure Change

**Before:**
```
naomgs-{sample}/
  ├── manifest.json
  ├── virus_hits.json           ← REMOVED
  ├── {sample}.sorted.bam       ← REMOVED
  ├── {sample}.sorted.bam.bai   ← REMOVED
  └── references/
```

**After:**
```
naomgs-{sample}/
  ├── manifest.json             (unchanged)
  ├── hits.sqlite               (NEW)
  └── references/
```

### 9. Import Flow Change

In `MetagenomicsImportService.importNaoMgs()`:

**Remove:**
- Writing `virus_hits.json`
- SAM conversion (`convertToSAM`)
- `samtools sort` + `samtools index`
- `includeAlignment` parameter

**Replace with:**
- `NaoMgsDatabase.create(at: hitsDBURL, hits: filteredHits, progress: progress)`

This call:
1. Creates the SQLite database with WAL mode
2. Bulk-inserts all hits in a single transaction
3. Computes per-(sample, taxon) summaries including unique reads and top-5 accessions
4. Creates indices after insert
5. Reports progress during bulk insert and summary computation

### 10. Import Sheet Change

- Remove the "Convert to SAM for alignment view" toggle (`convertToSAM` state)
- Remove `convertToSAM` from the `onImport` callback parameters

### 11. Parameter Chain Cleanup

Remove `includeAlignment` / `convertToSAM` from:

- `NaoMgsImportSheet.onImport` callback signature
- `AppDelegate.importNaoMgsResultFromURL` parameters
- `MetagenomicsImportHelperClient.NaoMgsOptions.includeAlignment`
- `MetagenomicsImportHelper` argument parsing (`--include-alignment`)
- `MetagenomicsImportService.importNaoMgs` parameter
- `ImportCommand.NaoMgsSubcommand` CLI flag (`--sam`, `--include-alignment`)
- `NaoMgsCommand.ImportSubcommand` CLI flag (`--sam`)

### 12. MiniBAM Viewer Change

Add `MiniBAMViewController.displayReads(reads:contig:contigLength:)`:
- Sets `allReads` directly from the provided `[AlignedRead]` array
- Runs duplicate detection and layout
- No `AlignmentDataProvider`, no samtools, no subprocess

The existing `displayContig(bamURL:...)` method remains for other use cases (EsViritu, regular BAM viewing). The new method is used only by the NAO-MGS detail pane.

### 13. Virus Hit to AlignedRead Conversion

`fetchReadsForAccession` converts each `virus_hits` row:

| virus_hits column | AlignedRead field | Notes |
|---|---|---|
| `seq_id` | `name` | Read name |
| `is_reverse_complement` | `flag` | 0x10 if true, 0 otherwise |
| `subject_seq_id` | `chromosome` | Reference accession |
| `ref_start` | `position` | 0-based |
| `bit_score / 5` capped at 60 | `mapq` | Same derivation as SAM conversion |
| `cigar` | `cigar` | Parse via `CIGAROperation.parse()` |
| `read_sequence` | `sequence` | |
| `read_quality` | `qualities` | Convert Phred+33 chars to UInt8 array |
| `edit_distance` | `editDistance` | |
| `fragment_length` | `insertSize` | |

Other `AlignedRead` fields set to nil/defaults (single-end data).

## Files Modified

| File | Change |
|------|--------|
| `Sources/LungfishIO/Formats/NaoMgs/NaoMgsDatabase.swift` | **Create** — SQLite database wrapper |
| `Sources/LungfishIO/Formats/NaoMgs/NaoMgsResultParser.swift` | Remove `convertToSAM` method |
| `Sources/LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift` | Replace JSON+BAM with SQLite; remove `includeAlignment` |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsImportSheet.swift` | Remove "Convert to SAM" toggle |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift` | Use NaoMgsDatabase; per-(sample,taxon) table; sample picker |
| `Sources/LungfishApp/Views/Metagenomics/NaoMgsSamplePickerView.swift` | **Create** — SwiftUI popover for sample multi-select |
| `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift` | Add `displayReads(reads:contig:contigLength:)` |
| `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` | Update NAO-MGS loading to use database |
| `Sources/LungfishApp/App/AppDelegate.swift` | Remove `convertToSAM` from import call |
| `Sources/LungfishApp/App/MetagenomicsImportHelper.swift` | Remove `--include-alignment` parsing |
| `Sources/LungfishApp/Services/MetagenomicsImportHelperClient.swift` | Remove `includeAlignment` from NaoMgsOptions |
| `Sources/LungfishCLI/Commands/ImportCommand.swift` | Remove `--sam`/`--include-alignment` flags |
| `Sources/LungfishCLI/Commands/NaoMgsCommand.swift` | Remove `--sam` flag |
| `Tests/LungfishIntegrationTests/NaoMgsImportOptimizationTests.swift` | Update tests for SQLite; add sample filtering tests |
| `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsImportServiceTests.swift` | Update existing test |

## Testing

### Automated (using toy fixture — needs update for multi-sample)

The toy fixture currently has 1 sample. Add 2-3 more sample names to the fixture rows to test per-sample behavior. Alternatively, create synthetic inline test data with multiple samples.

- `NaoMgsDatabase.create` produces valid database with correct row counts
- `fetchSamples` returns correct distinct sample list with hit counts
- `fetchTaxonSummaryRows(samples: nil)` returns one row per (sample, taxon) pair
- `fetchTaxonSummaryRows(samples: ["X"])` returns only rows for that sample
- `unique_read_count` is correct (< `hit_count` when duplicates exist)
- `top_accessions_json` contains at most 5 accessions per (sample, taxon)
- `fetchAccessionSummaries` returns correct per-accession counts for a (sample, taxon)
- `fetchReadsForAccession` returns `AlignedRead` objects with correct fields
- Full `importNaoMgs` pipeline produces `hits.sqlite` (no `virus_hits.json`, no BAM)
- Update existing tests that check for `virus_hits.json` or BAM files

### Manual

- Import CASPER dataset (199 samples, 8M reads)
- Verify taxonomy table loads instantly with per-(sample, taxon) rows
- Open sample picker, verify 199 samples listed with hit counts and common prefix stripped
- Select 2-3 samples, verify table filters to those samples
- Click a taxon row, verify detail pane shows top 5 accessions for that (sample, taxon)
- Verify miniBAMs render without timeouts or crashes
- Select single sample, verify Sample column hides
