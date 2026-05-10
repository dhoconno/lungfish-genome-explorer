# NAO-MGS Sample-Partitioned Import Design

## Goal

Redesign NAO-MGS import so large multi-sample datasets complete reliably in the GUI and CLI without changing the final user-facing result format. The final output must remain a single `naomgs-*` bundle containing one merged `hits.sqlite`, one `manifest.json`, per-sample BAMs, and optional fetched references.

This design addresses two observed problems in the current importer:

1. Large GUI imports do not reliably complete.
2. Large GUI imports take excessively long, with major cost outside SQLite insertion alone.

## Current Problems

The current importer streams rows from one monolithic TSV into a single SQLite database, but it also accumulates per-hit in-memory structures while parsing. Those structures scale with the total number of rows across all samples, not with the largest sample. For very large mixed-sample inputs, peak memory grows until the helper subprocess is likely memory-pressured or killed.

Even when parsing succeeds, the importer does additional heavyweight work inline:

- taxon name resolution
- optional reference fetching
- manifest caching
- BAM materialization
- duplicate marking
- database shrinking via `DELETE` + `VACUUM`

This means the total runtime is driven by a pipeline of expensive stages rather than by SQLite insertion alone.

## Design Summary

The importer will be restructured into two phases:

1. Partition phase:
   - stream the source TSV once
   - split it into temporary per-sample TSV files
   - import each sample independently and sequentially into temporary per-sample result directories
2. Assembly phase:
   - create the final single output bundle
   - merge per-sample SQLite summaries into one final `hits.sqlite`
   - copy per-sample BAMs into the final bundle
   - compute globally selected references from merged data
   - fetch references once
   - write the final manifest

This changes the memory profile from "total rows across the entire input" to approximately "largest sample currently being imported" plus fixed assembly overhead.

## Non-Goals

- No change to the final GUI contract or final bundle format
- No parallel sample import in v1
- No direct streaming fan-out into per-sample SQLite workers in v1
- No changes to GUI filtering/subsetting behavior
- No redesign of BAM or markdup semantics in v1

## Final Output Contract

The final output remains one `naomgs-*` directory containing:

- `hits.sqlite`
- `manifest.json`
- `bams/<sample>.bam`
- `bams/<sample>.bam.bai` or `.csi`
- `references/*.fasta` when reference fetching is enabled

The GUI should not need any structural changes to consume the final bundle.

## Phase 1: Partition Input By Sample

### Input Handling

The partitioner will accept the same source forms as the existing NAO-MGS importer:

- one monolithic `virus_hits_final.tsv`
- one monolithic `virus_hits_final.tsv.gz`
- a directory or set of files that resolve to one or more NAO-MGS TSVs

Directory input is a first-class case. In that mode, one logical sample may be represented across multiple TSV files, and those files must be treated as one combined row stream for partitioning purposes.

The partitioner will stream rows from the resolved input TSVs once and write rows into temporary per-sample TSV files.

### Sample Identity

Sample identity will use the same sample normalization rule already used by the importer. Rows that normalize to the same sample name must land in the same temporary TSV.

This ensures lane-specific suffixes continue to collapse into one biological sample where current behavior already expects that.

This rule applies across the entire resolved input set, not per source file. If sample `X` appears in three different TSV files under an input directory, all rows for normalized sample `X` must be written into the same temporary per-sample TSV.

### Temporary Layout

Temporary staging will live under a scratch directory inside the destination bundle workspace or sibling temporary area, for example:

- `.naomgs-import-staging/partitioned/<sample>.tsv`
- `.naomgs-import-staging/imports/<sample>/...`

The exact path may vary, but the structure must clearly separate:

- partitioned per-sample TSVs
- temporary per-sample import results

### Partitioning Rules

Each per-sample TSV must:

- preserve the original header exactly once
- contain only rows for that normalized sample
- preserve row order within that sample as encountered in the source stream
- allow rows for the same sample to originate from multiple input TSV files

When input is a directory of TSV files, the partitioner must iterate all resolved TSVs and append rows for the same normalized sample into the same destination file. It must not assume "one source TSV equals one sample."

The partitioner must not attempt to hold all rows in memory. It should keep only:

- the header
- a map of sample name -> open file handle or lazily opened writer

## Phase 2: Sequential Per-Sample Import

Each temporary per-sample TSV will be imported sequentially using the existing NAO-MGS import logic as much as possible.

### Sequential Execution

Imports run one sample at a time in v1.

Rationale:

- minimizes peak CPU, memory, and disk contention
- is easier to debug
- isolates failures cleanly
- still fixes the main memory-scaling problem

### Per-Sample Import Behavior

For each sample:

- invoke NAO-MGS import against the sample TSV
- pass the explicit sample name
- generate that sample's SQLite summaries
- generate that sample's BAM and BAM index
- do not fetch references during this step

Each sample produces an intermediate result directory that is valid enough to extract:

- `taxon_summaries`
- `accession_summaries`
- `reference_lengths` fallback values
- BAM file and index
- sample-local counts needed for the final manifest

### Temporary Import Contract

The temporary per-sample import does not need to be user-visible or discoverable by the GUI. It is an internal artifact only.

It may still use the existing importer's bundle structure if that reduces implementation risk.

## Phase 3: Final Bundle Assembly

After all sample imports succeed, create the final single `naomgs-*` bundle.

### Final SQLite Creation

The final `hits.sqlite` is created from scratch. It will not merge `virus_hits` rows.

It will contain:

- merged `taxon_summaries`
- merged `accession_summaries`
- merged `reference_lengths`
- per-sample BAM path metadata in `taxon_summaries`

### Merge Semantics

#### `taxon_summaries`

Append rows from each per-sample database directly.

This is safe because the key is `(sample, tax_id)`.

#### `accession_summaries`

Append rows from each per-sample database directly.

This is safe because the key is `(sample, tax_id, accession)`.

#### `reference_lengths`

Merge by accession rather than raw append.

Use `INSERT OR REPLACE` or `MAX(length)` semantics so that duplicate accessions across samples collapse to one row in the final table.

`MAX(length)` is preferred because fallback lengths may differ slightly and the longer value is the safer conservative choice for BAM headers and coverage interpretation.

#### `bam_path` and `bam_index_path`

After BAMs are copied into the final bundle, update the merged `taxon_summaries` rows for each sample with bundle-relative paths:

- `bams/<sample>.bam`
- `bams/<sample>.bam.bai` or `.csi`

### BAM File Assembly

Copy per-sample BAMs and indices from temporary import outputs into the final bundle's `bams/` directory.

No BAM re-materialization occurs during final assembly.

This avoids rebuilding a large combined row set and preserves the memory benefit of sample partitioning.

## Phase 4: Global Reference Fetching

Reference fetching moves to the end of the process and operates from merged data.

### Reference Selection

After the final `hits.sqlite` is assembled, select the top five reference accessions by mapped read count from merged data.

This selection is global across the final merged database, not per sample.

### Rationale

This avoids:

- downloading the same accession multiple times for different samples
- performing duplicate FASTA indexing work
- storing duplicate reference state during temporary sample imports

### Reference Update Flow

After fetching:

- write FASTAs into the final `references/` directory
- derive actual reference lengths from indexed FASTAs
- update `reference_lengths`
- refresh accession summary reference length fields if required by the existing schema behavior

## Manifest Construction

The final `manifest.json` is written only after final SQLite assembly succeeds.

### Manifest Fields

- `sampleName`
  - for multi-sample imports, retain the current top-level naming convention used by NAO-MGS bundles
- `sourceFilePath`
  - points to the original input source, not a temporary file
- `hitCount`
  - sum of per-sample hit counts
- `taxonCount`
  - count of distinct `tax_id` values across merged `taxon_summaries`
- `topTaxon`, `topTaxonId`
  - computed from merged data
- `cachedTaxonRows`
  - loaded from the final merged database
- `fetchedAccessions`
  - union of globally fetched reference accessions

## Failure Handling

### Default Failure Policy

If any per-sample import fails, the entire import fails.

Rationale:

- the final bundle is conceptually one analysis result
- partial results would be misleading unless the GUI explicitly represented partial import state
- v1 should prefer correctness and simplicity

### Partial Output Visibility

The final bundle should not be created in its user-visible final form until:

- partitioning succeeds
- all per-sample imports succeed
- final merge succeeds

This prevents the GUI from discovering half-assembled results.

### Cleanup

On failure:

- remove temporary per-sample TSVs
- remove temporary per-sample import directories
- remove any partially assembled final bundle directory

Cleanup should be best-effort but aggressive.

## Progress Reporting

Progress reporting should become stage-aware and sample-aware.

Suggested stages:

1. partitioning input by sample
2. importing sample `n/N`
3. assembling merged database
4. fetching references
5. writing manifest and finalizing

The current helper protocol can continue to emit simple progress events, but messages should reflect the new structure so GUI users can distinguish:

- slow parsing
- sample import work
- final assembly work
- reference fetch work

## Performance Expectations

Expected gains:

- peak memory scales with the largest sample being imported rather than the total multi-sample input
- large imports complete more reliably in the GUI
- duplicate reference downloads are removed

Expected costs:

- extra temporary disk usage for per-sample TSVs and intermediate imports
- some additional disk I/O from writing and rereading partitioned files

This tradeoff is acceptable for v1 because the current failure mode is dominated by memory growth and long-running monolithic processing.

## Alternatives Considered

### Keep Monolithic Import And Optimize SQLite Inserts

Rejected for v1.

Investigation showed the importer spends substantial time outside SQLite inserts, and the main completion risk comes from memory growth in streaming accumulators plus post-insert BAM and cleanup stages.

### Split By Sample But Write Directly Into One Shared Final DB

Rejected for v1.

This complicates coordination, failure recovery, and bundle assembly while providing little additional architectural validation over temp per-sample outputs.

### Direct Streaming Fan-Out Into Per-Sample Workers

Rejected for v1.

This is a promising long-term optimization but is a larger rewrite than needed to validate the per-sample architecture.

## Testing Strategy

Add tests for:

- partitioning one monolithic TSV into per-sample temp TSVs
- preserving header and row membership per sample
- partitioning a directory of TSV files where the same sample appears in multiple source files
- coalescing rows from multiple source TSVs into one per-sample temp TSV
- multi-sample import producing one final bundle
- merged `taxon_summaries` row counts
- merged `accession_summaries` row counts
- merged `reference_lengths` semantics for duplicate accessions
- BAM paths correctly populated in merged `taxon_summaries`
- reference fetching occurs once from merged top accessions, not per sample
- cleanup of staging artifacts on injected failure

Integration coverage should include:

- existing tiny fixture
- a synthetic multi-sample TSV
- subsetted large-file scenarios that previously stressed memory

## Open Implementation Notes

- Reusing the existing NAO-MGS importer for per-sample imports is preferred where possible, but it may need a mode that skips final reference fetching and exposes enough metadata for assembly.
- If the current importer always shrinks databases aggressively after BAM generation, that behavior may need a temporary-import-aware path so intermediate merge data remains available in the expected tables.
- The final assembler should use explicit SQL transactions when appending rows from per-sample databases.

## Recommendation

Implement the sample-partitioned sequential import architecture as the next step.

It is the smallest design change that directly addresses the observed failure mode while preserving the single-bundle output expected by the GUI.
