# NVD Classification Import & Taxonomy Browser

**Date:** 2026-04-02
**Status:** Design
**Branch:** NVD

## Overview

Add support for importing and browsing NVD (Novel Virus Diagnostics) classification
results. NVD is a Snakemake-based wastewater surveillance pipeline that assembles
contigs from metagenomic reads and classifies them via BLAST against NCBI databases.
Each contig receives up to 5 BLAST hits ranked by e-value.

The implementation follows the established NAO-MGS pattern: SQLite-backed data storage,
multi-sample bundle with sample picker, taxonomy browser with search, MiniBAM detail
pane, and BLAST verification integration.

## Data Source

NVD output directory structure:
```
{experiment}/nvd/
  01_preprocessing/
  02_human_viruses/03_human_virus_results/
    {sample}.human_virus.fasta          <- contig sequences
    {sample}.report                     <- contig list
    mapped_reads/
      {sample}.filtered.bam             <- reads mapped to contigs
      {sample}.filtered.bam.bai
      {sample}_mapped_counts.txt        <- per-contig read counts
  03_megablast_classification/
  04_blastn_classification/
  05_labkey_bundling/
    {experiment}_blast_concatenated.csv  <- all BLAST results
```

### CSV columns (23 fields)

| # | Column | Type | Notes |
|---|--------|------|-------|
| 1 | experiment | TEXT | Run ID, e.g. "32149" |
| 2 | blast_task | TEXT | "megablast" or "blastn" |
| 3 | sample_id | TEXT | e.g. "IL_CHI_Calumet_20260301_S2" |
| 4 | qseqid | TEXT | Contig name (NODE_..._length_..._cov_...) |
| 5 | qlen | INTEGER | Contig length in bp |
| 6 | sseqid | TEXT | GenBank accession |
| 7 | stitle | TEXT | Subject description (may contain commas, quoted) |
| 8 | tax_rank | TEXT | Full lineage string (semicolon-delimited) |
| 9 | length | INTEGER | Alignment length |
| 10 | pident | REAL | Percent identity |
| 11 | evalue | REAL | E-value (scientific notation) |
| 12 | bitscore | REAL | Bit score |
| 13 | sscinames | TEXT | Scientific name |
| 14 | staxids | TEXT | NCBI taxonomy ID |
| 15 | blast_db_version | TEXT | |
| 16 | snakemake_run_id | TEXT | |
| 17 | mapped_reads | INTEGER | Reads mapped to this contig |
| 18 | total_reads | INTEGER | Total reads in sample |
| 19 | stat_db_version | TEXT | |
| 20 | adjusted_taxid | INTEGER | Resolved taxonomy ID |
| 21 | adjustment_method | TEXT | e.g. "dominant" |
| 22 | adjusted_taxid_name | TEXT | Resolved taxon name |
| 23 | adjusted_taxid_rank | TEXT | Resolved rank |

### Key data characteristics

- ~127K rows for 27 samples in a typical run
- Most contigs have exactly 5 BLAST hits; some have 1-4
- BAM reference sequences match qseqid contig names exactly
- Per-sample BAMs are 4KB-54MB (220MB total for 27 samples)
- The `mapped_reads` and `total_reads` fields are per-contig, per-sample

## Bundle Structure

```
nvd-{experiment}/
  manifest.json           <- NvdManifest (instant loading)
  hits.sqlite             <- all BLAST results + sample metadata
  bam/
    {sample}.filtered.bam
    {sample}.filtered.bam.bai
  fasta/
    {sample}.human_virus.fasta
```

Bundles are stored in the project's `Imports/` directory.

## SQLite Schema

### `blast_hits` table

One row per BLAST hit (up to 5 per contig per sample):

| Column | Type | Notes |
|--------|------|-------|
| rowid | INTEGER PK | auto |
| experiment | TEXT | Run ID |
| blast_task | TEXT | "megablast" / "blastn" |
| sample_id | TEXT | Sample identifier |
| qseqid | TEXT | Contig name |
| qlen | INTEGER | Contig length |
| sseqid | TEXT | GenBank accession |
| stitle | TEXT | Subject description |
| tax_rank | TEXT | Full lineage |
| length | INTEGER | Alignment length |
| pident | REAL | Percent identity |
| evalue | REAL | E-value |
| bitscore | REAL | Bit score |
| sscinames | TEXT | Scientific name |
| staxids | TEXT | NCBI tax ID |
| blast_db_version | TEXT | |
| snakemake_run_id | TEXT | |
| mapped_reads | INTEGER | Reads mapped to contig |
| total_reads | INTEGER | Total reads in sample |
| stat_db_version | TEXT | |
| adjusted_taxid | INTEGER | Resolved tax ID |
| adjustment_method | TEXT | |
| adjusted_taxid_name | TEXT | Resolved taxon name |
| adjusted_taxid_rank | TEXT | Resolved rank |
| hit_rank | INTEGER | 1-5, computed at import, ordered by evalue ASC |
| reads_per_billion | REAL | Computed: mapped_reads / total_reads * 1e9 |

### `samples` table

One row per sample:

| Column | Type | Notes |
|--------|------|-------|
| sample_id | TEXT PK | |
| bam_path | TEXT | Relative path: "bam/{sample}.filtered.bam" |
| fasta_path | TEXT | Relative path: "fasta/{sample}.human_virus.fasta" |
| total_reads | INTEGER | |
| contig_count | INTEGER | Unique contigs for this sample |
| hit_count | INTEGER | Total BLAST hits for this sample |

### Indices

- `idx_hits_sample` on `(sample_id)` — sample filtering
- `idx_hits_contig` on `(sample_id, qseqid)` — contig detail queries
- `idx_hits_taxon` on `(adjusted_taxid_name)` — taxon grouping + search
- `idx_hits_experiment` on `(experiment)` — experiment filtering
- `idx_hits_rank` on `(adjusted_taxid_rank)` — rank filtering
- `idx_hits_evalue` on `(sample_id, qseqid, evalue)` — best hit per contig
- `idx_hits_stitle` on `(stitle)` — subject description search

### Key queries

- **Best hits per contig**: `SELECT * FROM blast_hits WHERE hit_rank = 1 AND sample_id IN (...) ORDER BY evalue`
- **Child hits for contig**: `SELECT * FROM blast_hits WHERE sample_id = ? AND qseqid = ? ORDER BY evalue`
- **Taxon grouping**: `SELECT adjusted_taxid_name, COUNT(DISTINCT qseqid) as contig_count, ... FROM blast_hits WHERE hit_rank = 1 AND sample_id IN (...) GROUP BY adjusted_taxid_name`
- **Search**: `WHERE adjusted_taxid_name LIKE ? OR stitle LIKE ? OR sseqid LIKE ? OR qseqid LIKE ?`
- **Sample BAM lookup**: `SELECT bam_path FROM samples WHERE sample_id = ?`

## Manifest

```swift
struct NvdManifest: Codable, Sendable {
    var formatVersion: String          // "1.0"
    var experiment: String             // "32149"
    var importDate: Date
    var sampleCount: Int
    var contigCount: Int               // unique contigs across all samples
    var hitCount: Int                  // total BLAST hit rows
    var blastDbVersion: String?
    var snakemakeRunId: String?
    var sourceDirectoryPath: String    // original NVD run path
    var samples: [NvdSampleSummary]
    var cachedTopContigs: [NvdContigRow]?
}

struct NvdSampleSummary: Codable, Sendable {
    var sampleId: String
    var contigCount: Int
    var hitCount: Int
    var totalReads: Int
    var bamRelativePath: String
    var fastaRelativePath: String
}

struct NvdContigRow: Codable, Sendable {
    var sampleId: String
    var qseqid: String
    var qlen: Int
    var adjustedTaxidName: String
    var adjustedTaxidRank: String
    var sseqid: String
    var stitle: String
    var pident: Double
    var evalue: Double
    var bitscore: Double
    var mappedReads: Int
    var readsPerBillion: Double
}
```

Two-phase loading: manifest provides `cachedTopContigs` for instant table display;
SQLite opens asynchronously for full query support.

## Import Workflow

### Import Sheet (NvdImportSheet.swift)

SwiftUI wizard dialog (~500x450px):
- Header: custom "Nvd" badge icon + "NVD Import" (.headline) + "Novel Virus Diagnostics" (.caption) + dataset name (top-right)
- Input: Browse button for NVD run directory
- Auto-discovery of `*_blast_concatenated.csv`, FASTA files, BAM files
- Preview: experiment ID, sample count, contig count, hit count, total BAM size
- Buttons: Cancel / Run

### Import Pipeline

1. Parse `*_blast_concatenated.csv`:
   - Standard CSV parsing with quoted field handling
   - Compute `hit_rank` per (sample_id, qseqid) group ordered by evalue ASC
   - Compute `reads_per_billion = mapped_reads / total_reads * 1e9`
2. Create `nvd-{experiment}/` bundle in project `Imports/`
3. Create SQLite database with WAL mode + memory pragmas for bulk insert
4. Bulk insert all hits into `blast_hits` table
5. Compute and insert `samples` table rows
6. Copy BAM + BAI files into `bam/` subdirectory
7. Copy FASTA files into `fasta/` subdirectory
8. Write `manifest.json` with summary stats and cached top contig rows
9. Report progress via OperationCenter (update + log)

### CLI

`lungfish import nvd <path> --output-dir <dir> [--name <preferred-name>]`

Registered as subcommand of `ImportCommand`.

### Import Center

Add NVD entry to "Classification Results" tab in Import Center, alongside
NAO-MGS, Kraken2, EsViritu, TaxTriage.

## Taxonomy Browser

### NvdResultViewController

Layout follows the NAO-MGS pattern:

```
+----------------------------------------------------------+
| Summary Bar (48pt)                                        |
|   Experiment: 32149 | Samples: 27 | Contigs: 28,461      |
+----------------------------------------------------------+
| Detail Pane (40%)    |  NSOutlineView (60%)               |
|                      |                                    |
|  [Summary info]      |  Search: [________________]        |
|  - Classification    |                                    |
|  - Accession         |  > NODE_1183 (227bp)  Picorna...   |
|  - % Identity        |    Hit 1: ON161844.1  95.6%        |
|  - E-value           |    Hit 2: MW345621.1  93.2%        |
|  - Mapped reads      |    Hit 3: ...                      |
|  - Reads/billion     |  > NODE_1137 (231bp)  Norovirus... |
|                      |  > NODE_9 (3148bp)  Enterovirus... |
|  [MiniBAM viewer]    |                                    |
|  +----------------+  |                                    |
|  | reads pileup   |  |                                    |
|  +----------------+  |                                    |
+----------------------------------------------------------+
| Action Bar (36pt)  [BLAST Verify] [Export] [NCBI]        |
+----------------------------------------------------------+
```

### Outline view columns (default visible)

| Column | Source | Notes |
|--------|--------|-------|
| Contig | qseqid | Display-trimmed (e.g. "NODE_1183 (227bp)") |
| Length | qlen | bp |
| Classification | adjusted_taxid_name | Resolved taxon |
| Rank | adjusted_taxid_rank | species, clade, family, etc. |
| Accession | sseqid | GenBank accession |
| Subject | stitle | BLAST hit description (truncated) |
| % Identity | pident | |
| E-value | evalue | Scientific notation |
| Bit Score | bitscore | |
| Mapped Reads | mapped_reads | Raw count |
| Reads/Billion | reads_per_billion | Computed normalization |
| Coverage | length/qlen | Alignment coverage fraction |

Hidden by default (available via column header right-click):
- blast_task, total_reads, blast_db_version, full tax_rank lineage, hit_rank

### Grouping modes

Controlled by "Group by" segmented control in Document Inspector:

**By Sample (default):** Sample picker selects samples. Table shows flat contig
list (best hit, hit_rank=1). Expanding a contig row reveals child hits (hit_rank 2-5).
Two nesting levels: contig > hit.

**By Taxon:** Sample picker selects samples. Table shows taxon group rows
(adjusted_taxid_name with aggregate contig count). Expanding a taxon reveals its
contigs. Expanding a contig reveals child hits. Three nesting levels: taxon > contig > hit.

### Child hit rows

Same columns as parent but styled with secondary label color to visually
distinguish from best-hit rows.

### Detail pane

When a contig is selected:
- **Top**: Summary card — classification, accession, % identity, e-value, bit score,
  mapped reads, reads/billion, contig length, full lineage
- **Bottom**: MiniBAM viewer — opens per-sample BAM file at the selected contig
  reference. The BAM reference names match qseqid exactly.

### Search

Debounced text field filters across: adjusted_taxid_name, stitle, sseqid, qseqid.
SQL LIKE queries against indexed columns. Preserves selection when possible.

### BLAST verification

Right-click contig row > "BLAST Verify Sequence":
1. Extract contig sequence from bundle's `fasta/{sample}.human_virus.fasta`
   by scanning for the matching FASTA header (qseqid matches the `>NODE_...` header)
2. Submit sequence to NCBI BLAST via existing BlastService
3. Show results in bottom drawer (same as NAO-MGS pattern)

## Sidebar Integration

- Scan for `nvd-*/` directories with `manifest.json` in `Imports/`
- New `SidebarItemType.nvdResult` enum case
- Icon: custom "Nvd" text badge (Lungfish Orange tint)
- Display text: "NVD: {experiment}"
- Skip in-progress imports via OperationMarker check

## Inspector Integration

- Case `.nvdResult` -> "NVD Classification Result"
- Metadata: experiment, sample count, contig count, total hits, import date,
  BLAST DB version, Snakemake run ID
- Sample picker popover (synced with NvdResultViewController)
- "Group by" segmented control: Sample | Taxon

## Viewer Integration (ViewerViewController+Nvd.swift)

- `displayNvdResult(_ controller:)` — same pattern as NAO-MGS
- Hides other overlay views, sets contentMode to .metagenomics
- Wires `onBlastVerification` callback to BlastService
- Two-phase loading: manifest (instant) -> SQLite (full queries)

## Custom Text Badge Icons

Shared `TextBadgeIcon` renderer for both "Nao" and "Nvd" icons:
- Small rounded rectangle with text inside
- Lungfish Orange fill color, white text
- Used in sidebar, import sheet header, Import Center tabs
- Replaces the current "n.circle" SF Symbol for NAO-MGS

## NAO-MGS Changes

- Remove min % identity slider from `NaoMgsImportSheet.swift`
- Remove `minIdentity` parameter from import callback chain
  (NaoMgsImportSheet -> AppDelegate -> MetagenomicsImportHelperClient -> CLI)
- Replace "n.circle" sidebar/import icon with "Nao" text badge icon

## New Files

**LungfishIO:**
- `Sources/LungfishIO/Formats/Nvd/NvdManifest.swift`
- `Sources/LungfishIO/Formats/Nvd/NvdDatabase.swift`
- `Sources/LungfishIO/Formats/Nvd/NvdResultParser.swift`

**LungfishApp:**
- `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`
- `Sources/LungfishApp/Views/Metagenomics/NvdImportSheet.swift`
- `Sources/LungfishApp/Views/Metagenomics/NvdDataConverter.swift`
- `Sources/LungfishApp/Views/Metagenomics/NvdSamplePickerView.swift`
- `Sources/LungfishApp/Views/Metagenomics/NvdChartViews.swift`
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+Nvd.swift`
- `Sources/LungfishApp/Views/Metagenomics/TextBadgeIcon.swift`

**LungfishCLI:**
- `Sources/LungfishCLI/Commands/NvdCommand.swift`

**Modified files:**
- `SidebarViewController.swift` — nvdResult type, discovery, Nao icon update
- `MainSplitViewController.swift` — displayNvdResultFromSidebar(at:)
- `InspectorViewController.swift` — NVD case, Group by control
- `DocumentSection.swift` — .nvdResult case
- `ImportCenterView.swift` / `ImportCenterViewModel.swift` — NVD tab
- `AppDelegate.swift` — importNvdResultFromURL(_:)
- `NaoMgsImportSheet.swift` — remove min % identity slider
- `NaoMgsResultViewController.swift` — Nao badge icon
- `AboutWindowController.swift` — add NVD acknowledgement
- `ImportCommand.swift` — register NVD subcommand

**Tests:**
- `Tests/LungfishIntegrationTests/NvdDatabaseTests.swift`
- `Tests/LungfishIntegrationTests/NvdResultParserTests.swift`

## Test Coverage

### NvdResultParserTests
- Parse valid CSV with header detection
- Handle quoted fields (stitle contains commas)
- Compute hit_rank correctly (ordered by evalue per contig group)
- Compute reads_per_billion correctly
- Handle contigs with fewer than 5 hits
- Handle megablast vs blastn rows
- Skip malformed rows gracefully
- Empty file / header-only file

### NvdDatabaseTests
- Create database and verify schema (tables, indices)
- Bulk insert and query best hits (hit_rank = 1)
- Query child hits for a specific contig
- Sample filtering queries
- Taxon grouping queries
- Search across adjusted_taxid_name, stitle, sseqid, qseqid
- Sample metadata table (bam_path, fasta_path, counts)
- Reads per billion values stored correctly
- Large dataset performance (full 127K rows, verify query speed)

### Test Fixture
Small CSV subset: 3 samples, 10 contigs each, varying hit counts (1-5),
mix of megablast and blastn rows. Self-contained in `Tests/Fixtures/nvd/`.
