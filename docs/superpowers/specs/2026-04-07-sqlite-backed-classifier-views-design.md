# SQLite-Backed Classifier Views

**Date:** 2026-04-07
**Status:** Draft

## Overview

Replace the JSON manifest / in-memory parsing approach for TaxTriage, EsViritu, and Kraken2 batch views with SQLite databases. The databases are built by the CLI as a post-processing step after pipeline completion, or by the app on first open if the DB is missing. Unique reads (TaxTriage, EsViritu) are computed from BAM files during DB construction, not during browsing. The app queries the DB directly for instant display.

After DB construction, intermediate pipeline files are cleaned up (conservative mode) to reclaim disk space — raw FASTQ copies, filtered reads, per-read Kraken2 output, and other intermediate files are removed. Only the SQLite DB, BAM files, reports, logs, and provenance files are retained.

## Schema

### TaxTriage — `taxtriage.sqlite`

```sql
CREATE TABLE taxonomy_rows (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sample TEXT NOT NULL,
    organism TEXT NOT NULL,
    tax_id INTEGER,
    status TEXT,
    tass_score REAL NOT NULL,
    reads_aligned INTEGER NOT NULL,
    unique_reads INTEGER,
    pct_reads REAL,
    pct_aligned_reads REAL,
    coverage_breadth REAL,
    mean_coverage REAL,
    mean_depth REAL,
    confidence TEXT,
    k2_reads INTEGER,
    parent_k2_reads INTEGER,
    gini_coefficient REAL,
    mean_baseq REAL,
    mean_mapq REAL,
    mapq_score REAL,
    disparity_score REAL,
    minhash_score REAL,
    diamond_identity REAL,
    k2_disparity_score REAL,
    siblings_score REAL,
    breadth_weight_score REAL,
    hhs_percentile REAL,
    is_annotated INTEGER,
    ann_class TEXT,
    microbial_category TEXT,
    high_consequence INTEGER,
    is_species INTEGER,
    pathogenic_substrains TEXT,
    sample_type TEXT,
    bam_path TEXT,
    bam_index_path TEXT,
    primary_accession TEXT,
    accession_length INTEGER,
    UNIQUE(sample, organism)
);

CREATE INDEX idx_tt_sample ON taxonomy_rows(sample);
CREATE INDEX idx_tt_organism ON taxonomy_rows(organism);
CREATE INDEX idx_tt_tass ON taxonomy_rows(tass_score);

CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT
);
```

All columns sourced from `report/multiqc_data/multiqc_confidences.txt` (34 TSV columns). `unique_reads` computed from BAM deduplication. BAM pointer columns (`bam_path`, `bam_index_path`, `primary_accession`, `accession_length`) resolved during DB construction.

### EsViritu — `esviritu.sqlite`

```sql
CREATE TABLE detection_rows (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sample TEXT NOT NULL,
    virus_name TEXT NOT NULL,
    description TEXT,
    contig_length INTEGER,
    segment TEXT,
    accession TEXT NOT NULL,
    assembly TEXT NOT NULL,
    assembly_length INTEGER,
    kingdom TEXT,
    phylum TEXT,
    tclass TEXT,
    torder TEXT,
    family TEXT,
    genus TEXT,
    species TEXT,
    subspecies TEXT,
    rpkmf REAL,
    read_count INTEGER NOT NULL,
    unique_reads INTEGER,
    covered_bases INTEGER,
    mean_coverage REAL,
    avg_read_identity REAL,
    pi REAL,
    filtered_reads_in_sample INTEGER,
    bam_path TEXT,
    bam_index_path TEXT,
    UNIQUE(sample, accession)
);

CREATE INDEX idx_ev_sample ON detection_rows(sample);
CREATE INDEX idx_ev_virus ON detection_rows(virus_name);
CREATE INDEX idx_ev_assembly ON detection_rows(assembly);
CREATE INDEX idx_ev_reads ON detection_rows(read_count);

CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT
);
```

All columns sourced from `<sample>.detected_virus.info.tsv` (23 TSV columns). `unique_reads` computed from BAM deduplication. BAM at `<sample>_temp/<sample>.third.filt.sorted.bam`.

### Kraken2 — `kraken2.sqlite`

```sql
CREATE TABLE classification_rows (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sample TEXT NOT NULL,
    taxon_name TEXT NOT NULL,
    tax_id INTEGER NOT NULL,
    rank TEXT,
    rank_display_name TEXT,
    reads_direct INTEGER NOT NULL,
    reads_clade INTEGER NOT NULL,
    percentage REAL NOT NULL,
    UNIQUE(sample, tax_id)
);

CREATE INDEX idx_kr_sample ON classification_rows(sample);
CREATE INDEX idx_kr_taxon ON classification_rows(taxon_name);
CREATE INDEX idx_kr_reads ON classification_rows(reads_clade);

CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT
);
```

All columns sourced from per-sample `classification.kreport` files (6-column TSV). No BAM pointers (Kraken2 doesn't produce BAMs). No unique reads computation.

## CLI Commands

```
lungfish build-db taxtriage <result-dir>
lungfish build-db esviritu <result-dir>
lungfish build-db kraken2 <result-dir>
```

### TaxTriage Build Flow

1. Parse `report/multiqc_data/multiqc_confidences.txt` (or `report/all.organisms.report.txt`) for all rows
2. For each sample, locate BAM at `minimap2/<sample>.<sample>.dwnld.references.bam` and index (`.csi` or `.bai`)
3. For each sample, parse `combine/<sample>.combined.gcfmap.tsv` to map organisms to accessions
4. For each (sample, organism), run `samtools idxstats` on the BAM to get accession lengths, then fetch reads and deduplicate (position-strand fingerprint) for `unique_reads`
5. Resolve `primary_accession` (first accession for the organism from gcfmap) and `accession_length`
6. Write all rows plus metadata to `<result-dir>/taxtriage.sqlite`

### EsViritu Build Flow

1. Enumerate sample subdirectories
2. For each sample, parse `<sample>.detected_virus.info.tsv` for all contig-level rows
3. Locate BAM at `<sample>_temp/<sample>.third.filt.sorted.bam` and index `.bai`
4. For each (sample, accession), fetch reads from BAM and deduplicate for `unique_reads`
5. Write all rows plus metadata to `<result-dir>/esviritu.sqlite`

### Kraken2 Build Flow

1. Enumerate sample subdirectories in the batch result directory
2. For each sample, parse `classification.kreport` (6-column TSV) into flat rows
3. Extract `classification-result.json` sidecar for provenance (tool version, database, config)
4. No BAM processing needed (Kraken2 doesn't produce BAMs)
5. Write all rows plus metadata to `<result-dir>/kraken2.sqlite`

### Common CLI Behavior

- Progress reported to stdout (for Operations Panel capture)
- Exit 0 on success, non-zero on failure
- If DB already exists, skip (use `--force` to rebuild)
- Metadata table stores: tool version, build timestamp, source file paths, row count, sample count

## Post-Build Cleanup

After the SQLite DB is successfully created, the CLI performs a conservative cleanup of intermediate pipeline files that are no longer needed by the app. This is part of the `build-db` command (not a separate step).

### Cleanup Rules

**Kraken2 — removes ~40 GB for 149 samples:**
- DELETE: `<sample>/classification.kraken` (per-read output, ~700 MB/sample)
- DELETE: `<sample>/classification.kraken.idx.sqlite` + WAL (index DB, ~350 MB/sample)
- KEEP: `<sample>/classification.kreport` (source data, ~272 KB/sample)
- KEEP: `<sample>/classification-result.json` (provenance sidecar)
- KEEP: `kraken2.sqlite` (the new DB)
- KEEP: batch manifest JSON (if present)

**TaxTriage — removes ~33 GB for 149 samples:**
- DELETE: `count/` (raw FASTQ copies, ~17 GB)
- DELETE: `fastp/` filtered FASTQs only; keep `.html` and `.json` QC reports
- DELETE: `filterkraken/`, `get/`, `map/`, `samtools/`, `bedtools/`, `top/`, `mergedsubspecies/`, `mergedkrakenreport/` (intermediate pipeline dirs)
- KEEP: `minimap2/` (BAM files + indices)
- KEEP: `report/` (organism reports, confidences — source data)
- KEEP: `combine/` (gcfmap files — source data for accession mapping)
- KEEP: `pipeline_info/`, `nextflow.log`, `trace.txt` (provenance)
- KEEP: `taxtriage.sqlite` (the new DB)
- KEEP: `taxtriage-result.json`, `taxtriage-launch-command.*`, `samplesheet.csv`
- KEEP: `download/` (downloaded reference sequences)
- KEEP: `alignment/` (alignment stats)
- KEEP: `kraken2/`, `kreport/` (Kraken2 reports, small)

**EsViritu — removes ~200 MB for 149 samples:**
- DELETE: `<sample>/<sample>.fastp.html`, `<sample>.fastp.json` (QC reports — not needed for browsing)
- DELETE: `<sample>/<sample>_esviritu.readstats.yaml` (pipeline stats)
- DELETE: `<sample>/<sample>_final_consensus.fasta` (consensus sequences — derivable from BAM)
- KEEP: `<sample>/<sample>_temp/<sample>.third.filt.sorted.bam` + `.bai` (BAM files)
- KEEP: `<sample>/<sample>.detected_virus.info.tsv` (source data)
- KEEP: `<sample>/<sample>.virus_coverage_windows.tsv` (coverage data for plots)
- KEEP: `<sample>/<sample>.detected_virus.assembly_summary.tsv` (assembly data)
- KEEP: `<sample>/<sample>.tax_profile.tsv` (taxonomy profile)
- KEEP: `esviritu.sqlite` (the new DB)
- KEEP: batch manifest JSON (if present)

### Cleanup Safety

- Cleanup only runs after the DB is verified (row count > 0, schema correct)
- A `--no-cleanup` flag skips cleanup entirely
- Cleanup is logged to stdout so the Operations Panel shows what was removed
- If any delete fails, the error is logged but the command still exits 0 (DB was built successfully)

## App Integration

### Opening a Result

1. Sidebar click triggers display method
2. Check for `taxtriage.sqlite` / `esviritu.sqlite` in the result directory
3. **If DB exists:** Open it, create the VC, call `configureFromDatabase(_:)`. Instant.
4. **If DB missing:** Show placeholder viewport, run `lungfish build-db` as subprocess via Operations Panel. When complete, replace placeholder with DB-backed view.

### Placeholder Viewport

When the user clicks a result that lacks a SQLite DB:

- Viewport shows a centered placeholder (same pattern as "Select an organism to view details"):
  - Icon: `gearshape.2` SF Symbol
  - Title: "Building database for TaxTriage results..."
  - Subtitle: "Check the Operations Panel for progress."
- Operations Panel shows live progress: "Building TaxTriage database (42/149 samples...)"
- User can navigate away freely — the build continues in background
- When build completes and user is still viewing this result, placeholder is replaced with the full DB-backed view
- On failure, placeholder shows error message with "Retry" button

### View Controller Changes

**TaxTriageResultViewController:**
- New `configureFromDatabase(_ db: TaxTriageDatabase)` method replaces `configure(result:)` for multi-sample and `configureBatchGroup()`
- Queries `db.fetchRows(samples:)` filtered by `ClassifierSamplePickerState.selectedSamples`
- Row selection provides `bam_path`, `bam_index_path`, `primary_accession`, `accession_length` directly from the row — no lookups needed for miniBAM

**EsVirituResultViewController:**
- New `configureFromDatabase(_ db: EsVirituDatabase)` method replaces `configureBatch()`
- Same query/filter/display pattern

### What Gets Replaced

- JSON manifests: `taxtriage-batch-manifest.json`, `esviritu-batch-aggregated.json`, `batch-unique-reads.json`
- In-memory TSV parsing in `configureBatch`/`configureBatchGroup`/`enableMultiSampleFlatTableMode`
- Background unique reads computation in the app (`scheduleBatchPerSampleUniqueReadComputation`, `scheduleBatchUniqueReadComputation`)
- `perSampleDeduplicatedReadCounts` dictionary and `syncUniqueReadsToFlatTable`
- `persistDeduplicatedReadCounts`, `persistBatchUniqueReads`, `updateBatchManifestUniqueReads`
- "Recompute Unique Reads" button (replaced by `lungfish build-db --force`)

### What Stays

- `BatchTableView` base class and subclasses (display layer)
- Inspector sections (operation details, sample picker, source samples, metadata import)
- `ClassifierSamplePickerState` filtering
- Summary bars
- Single-sample Kraken2 (kreport tree view for individual samples — DB used only for batch/multi-sample flat table)
- MiniBAM viewer (receives data from DB rows instead of dictionary lookups)
- `MetadataColumnController` for dynamic columns

### Kraken2 View Controller Changes

**TaxonomyViewController:**
- New `configureFromDatabase(_ db: Kraken2Database)` method replaces `configureBatch(batchURL:manifest:projectURL:)`
- Queries `db.fetchRows(samples:)` for flat table display
- No BAM pointers (Kraken2 has no BAMs)
- Single-sample mode still uses `configure(result:)` with kreport tree view (no change)

## Database Classes

### TaxTriageDatabase

Located in `Sources/LungfishIO/Formats/TaxTriage/TaxTriageDatabase.swift`. Follows the `NaoMgsDatabase` and `NvdDatabase` patterns:

- `init(at: URL)` — opens existing DB
- `static func create(at: URL)` — creates new DB with schema
- `func fetchRows(samples: [String]) -> [TaxTriageTaxonomyRow]`
- `func fetchSamples() -> [(sample: String, organismCount: Int)]`
- `func fetchMetadata() -> [String: String]`
- `func insertRow(_:)` / `func insertRows(_:)`
- `func setMetadata(key:value:)`

### EsVirituDatabase

Located in `Sources/LungfishIO/Formats/EsViritu/EsVirituDatabase.swift`. Same pattern:

- `init(at: URL)` / `static func create(at: URL)`
- `func fetchRows(samples: [String]) -> [EsVirituDetectionRow]`
- `func fetchSamples() -> [(sample: String, detectionCount: Int)]`
- `func fetchMetadata() -> [String: String]`
- `func insertRow(_:)` / `func insertRows(_:)`

### Kraken2Database

Located in `Sources/LungfishIO/Formats/Kraken2/Kraken2Database.swift`. Same pattern:

- `init(at: URL)` / `static func create(at: URL)`
- `func fetchRows(samples: [String]) -> [Kraken2ClassificationRow]`
- `func fetchSamples() -> [(sample: String, taxonCount: Int)]`
- `func fetchMetadata() -> [String: String]`
- `func insertRow(_:)` / `func insertRows(_:)`

## Testing Strategy

### Test Fixtures

Extract a small subset (3-5 samples) from the existing results at `/Volumes/nvd_remote/TGS-air-VSP2.lungfish/Analyses/`:

- `Tests/Fixtures/taxtriage-mini/`: confidence TSV, per-sample organism reports, gcfmap files, minimal BAM (subset to a few contigs using `samtools view -h -o mini.bam ref1 ref2`)
- `Tests/Fixtures/esviritu-mini/`: per-sample detection TSVs, coverage windows, minimal BAM
- `Tests/Fixtures/kraken2-mini/`: per-sample kreport files, classification-result.json sidecars

Committed to the repo for reproducible testing. BAM fixtures should be small (a few KB) — subset to 2-3 contigs with minimal reads.

### Test Levels

**1. Database unit tests** (`TaxTriageDatabaseTests`, `EsVirituDatabaseTests`, `Kraken2DatabaseTests`):
- Schema creation
- Insert and query rows
- Sample filtering (`fetchRows(samples:)`)
- Sorting by each column
- Metadata round-trip
- Unique reads storage and retrieval (TaxTriage, EsViritu)
- BAM path storage and retrieval (TaxTriage, EsViritu)

**2. CLI integration tests** (`BuildDbCommandTests`):
- `lungfish build-db taxtriage <fixture-dir>` produces valid `taxtriage.sqlite`
- `lungfish build-db esviritu <fixture-dir>` produces valid `esviritu.sqlite`
- `lungfish build-db kraken2 <fixture-dir>` produces valid `kraken2.sqlite`
- Row counts match expected
- Unique reads are non-zero where BAMs exist (TaxTriage, EsViritu)
- BAM paths correctly resolved (TaxTriage, EsViritu)
- `--force` rebuilds existing DB
- Skip when DB already exists

**3. Cleanup tests** (`BuildDbCleanupTests`):
- Kraken2: `.kraken` and `.idx.sqlite` files deleted after build
- TaxTriage: `count/` and `fastp/` FASTQs deleted; reports/BAMs preserved
- EsViritu: fastp reports deleted; BAMs and detection TSVs preserved
- `--no-cleanup` flag prevents deletion
- Cleanup skipped if DB creation fails (row count = 0)

**4. VC integration tests** (`TaxTriageDatabaseViewTests`, `EsVirituDatabaseViewTests`, `Kraken2DatabaseViewTests`):
- `configureFromDatabase` populates the flat table correctly
- Sample filtering via `ClassifierSamplePickerState` queries the DB
- Row selection provides correct BAM path for miniBAM (TaxTriage, EsViritu)
- Placeholder shown when DB missing
- Placeholder replaced when DB build completes

**5. Regression tests**:
- No viewport bounce
- Unique reads match between table and miniBAM
- No stale data issues
- Single-sample mode unaffected

## Scope

### In Scope

- SQLite databases for TaxTriage, EsViritu, and Kraken2 batch/multi-sample views
- CLI `build-db` commands for all three tools
- App-side DB opening and querying
- Automatic DB build on first open (non-blocking, with placeholder)
- All fields from TSV/kreport output stored in DB
- BAM coordinate pointers in DB rows (TaxTriage, EsViritu)
- Unique reads computed from BAM during DB build (TaxTriage, EsViritu)
- Post-build conservative cleanup of intermediate pipeline files
- Comprehensive test suite with real data fixtures
- Operations Panel progress during DB build
- Provenance metadata in DB

### Out of Scope

- Pivot table feature (separate spec)
- NVD-style filter bars on all columns (separate spec)
- Changes to single-sample Kraken2 tree viewing (unchanged)
- Changes to single-sample EsViritu/TaxTriage viewing (unchanged)
