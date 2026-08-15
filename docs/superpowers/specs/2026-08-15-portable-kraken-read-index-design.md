# Portable Kraken Read Index Design

## Problem

Kraken2 read extraction fails for analyses stored on ExFAT with `Query failed: disk I/O error`. The per-sample `classification.kraken.gz.idx.sqlite` builder enables WAL mode, checkpoints it, but leaves WAL as the database's persistent journal mode. A normal read-only SQLite connection then needs WAL shared-memory coordination that ExFAT does not reliably support. The affected indexes are complete and have absent or empty WAL sidecars, so the scientific classification data is intact.

Batch extraction also reports an estimate of zero because the estimator loads the batch root as a single `ClassificationResult` instead of loading each selected sample directory.

## Design

### New index publication

`KrakenIndexDatabase.build` will continue using WAL for bulk-import performance. Before reporting success it will require a successful truncate checkpoint, switch the database to `journal_mode=DELETE`, and verify that SQLite reports `delete`. Any failure at this boundary is a build failure. A successfully built index is therefore a standalone portable SQLite file with no required WAL or shared-memory sidecars.

### Legacy index compatibility

The read-only initializer will inspect the adjacent WAL sidecar. When the WAL is absent or exactly empty, it will open the database through an SQLite URI with `immutable=1`. This tells SQLite that the completed index cannot change and prevents creation or use of `-shm` on ExFAT. A nonempty WAL will never use immutable mode because it may contain uncheckpointed data; it will use normal read-only SQLite semantics instead.

The same open policy will be used by index validity checks so a valid legacy index remains usable on ExFAT.

### Correctness fallback

`TaxonomyExtractionPipeline` will treat both index-open and index-query failures as a failed optimization. It will close the index, log the reason, and stream the authoritative `classification.kraken` or `classification.kraken.gz` file using the existing parser. This preserves correctness for malformed indexes and databases with nonempty WAL files that cannot be read on the current filesystem.

### Batch estimate

The Kraken2 estimator will group selectors by sample. In batch mode it will load `resultPath/<sampleId>` and sum the selected taxa's clade counts for each sample; in single-sample mode it will continue loading `resultPath`. A sample that cannot be loaded contributes zero and is logged, matching the existing best-effort estimate contract.

## Provenance and data safety

Extraction output provenance remains on the existing GUI/CLI path and continues to identify the classification result, source FASTQ payloads, exact options, output, checksums, runtime, exit status, and timing. The compatibility reader is read-only and does not rewrite existing analysis indexes or scientific payloads. New index provenance continues to describe the final standalone index.

## Tests

- Prove new builds are `journal_mode=delete` and leave no WAL/SHM dependency.
- Construct a legacy checkpointed WAL-mode fixture with an empty WAL and prove the reader queries it without creating `-shm`.
- Prove an index query failure falls back to the raw Kraken output.
- Prove a batch-root estimate loads the selected sample directory and returns its nonzero clade count.
- Run the complete Kraken index, taxonomy extraction, classifier resolver, provenance, and app dialog suites, then verify extraction against the real SILVA analysis without modifying it.
