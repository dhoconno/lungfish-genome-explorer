# Classification Review

## What it is

Classifier results are candidate evidence. Kraken2, TaxTriage, NAO-MGS, EsViritu, NVD, and imported CZ-ID reports each summarize read or contig support in different ways.

Treat a taxon call as stronger when read support, coverage, identity, and independent verification agree.

## Procedure

1. Open the classifier result from the project sidebar.
2. Use search or sample filters to focus the table.
3. Compare total reads, unique reads, coverage, identity, and confidence fields.
4. Use BLAST Verify when a selected organism or contig needs independent sequence review.
5. Use Extract FASTQ when you need the reads behind a selected taxon or organism.

## Interpretation

Reads alone can overstate evidence when duplicates, repeats, or multi-mapping are present. Unique reads and broad coverage usually support a call more strongly than a narrow high-depth region.

BLAST support depends on sampled reads, query length, database state, and hit thresholds. A high-identity hit over most of the read is stronger evidence than a short high-identity match.

## Provenance

Classifier imports, exports, read extractions, and derived bundles should keep provenance for source files, databases, command arguments, checksums, and stored payload paths. Missing provenance is a blocking defect for scientific interpretation.
