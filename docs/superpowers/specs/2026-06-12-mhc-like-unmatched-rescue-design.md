# MHC-Like Unmatched Rescue Workbook Design

## Summary

The full-length ONT MHC genotyping workbook currently reports unmatched clusters and, when the original genotyping SAM contains a non-exact reference alignment, closest-match metadata. Inspection of NB13 showed that this misses biologically MHC-like unmatched clusters when the original minimap2 pass does not retain the hit. Add a deterministic local rescue comparison against the same reference FASTA and add MHC-like-only workbook sheets.

## Matching Semantics

The existing exact genotype caller and existing `Unmatched Clusters` and `Unmatched Shared Pivot` sheets remain unchanged.

For unmatched clusters whose original closest-match metadata is blank, run a local BLAST rescue pass against the resolved MHC reference FASTA:

- query: unmatched cluster FASTA records without an original closest match;
- subject: resolved reference FASTA used by the genotyping workflow;
- task: `blastn`;
- output: tabular fields sufficient to reproduce the selected hit: query id, subject id, percent identity, aligned length, mismatches, gap opens, query start/end, subject start/end, e-value, bit score, query length, subject length.

A rescue hit is accepted as MHC-like when all thresholds pass:

- query coverage is at least 70%;
- aligned length is at least 1,000 bp;
- percent identity is at least 75%;
- e-value is at most `1e-20`.

When multiple rescue hits pass, choose the best hit by:

1. lower e-value;
2. higher bit score;
3. higher query coverage;
4. higher percent identity;
5. longer aligned length;
6. subject/reference name using localized standard sort.

## Workbook Contract

Add two worksheets after the existing unmatched worksheets:

- `MHC-like Unmatched Clusters`
- `MHC-like Unmatched Pivot`

The MHC-like detail sheet uses the same core columns as `Unmatched Clusters`, plus rescue-specific evidence columns:

- `match_source`: `genotyping-sam` for original closest-match evidence or `local-blast-rescue` for rescue evidence;
- `closest_reference`;
- `percent_identity`;
- `query_coverage`;
- `evalue`;
- `bitscore`;

The MHC-like pivot sheet groups only MHC-like unmatched records by `unmatched_sequence_id`, preserving occurrence count, total reads, closest-match summary, source, BLAST evidence summary, and per-sample read counts.

Rows with no original closest match and no accepted rescue hit remain only in the original all-unmatched sheets.

## Provenance

The BLAST rescue pass is a scientific data transformation. It must be recorded in the output bundle provenance with:

- `blastn` tool name and version when available;
- exact argv;
- user-visible thresholds and resolved defaults;
- input unmatched-rescue FASTA and reference FASTA paths;
- output TSV path;
- checksums and sizes through the existing provenance file descriptor path;
- exit status, wall time, and useful stderr.

The generated workbook and existing provenance sidecar remain the durable report outputs.

