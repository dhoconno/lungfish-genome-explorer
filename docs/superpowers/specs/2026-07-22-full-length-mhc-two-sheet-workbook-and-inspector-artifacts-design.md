# Full-length MHC two-sheet workbook and Inspector artifacts design

Date: 2026-07-22

## Scope

This change applies only to newly generated full-length ONT MHC genotype result bundles and their explicit workbook-update action. It does not change the scientific genotype calls, raw reference identities, candidate classification, BAM evidence, or other LGE result surfaces.

The change has three goals:

1. Make known-allele labels in Excel match the GenBank-derived allele labels shown in the LGE viewport.
2. Replace the legacy multi-sheet full-length MHC workbook with two purpose-built worksheets.
3. Show the declared candidate and un-nameable GenBank artifacts in the Inspector.

## Source identity and display names

Known calls retain the raw reference sequence identifier, such as `NHP01220`, as their durable call identity. The user-facing display label is resolved through the embedded reference record store's `feature.allele` field, using the same raw-ID-to-GenBank-value join as the viewport. For example, `NHP01220` remains the call identity while its displayed allele is `Mafa-A2*05:07:01:01`.

Missing or blank GenBank allele values fall back to the raw reference identifier. Candidate alleles continue to use their provisional `_nov` or `_ext` names and stable cluster IDs. Distinct raw known references and distinct candidate sequences are not conflated merely because their display labels collide.

## Workbook structure

New full-length MHC workbooks contain exactly two worksheets.

### Unified Genotype Pivot

The first worksheet combines the useful sample header block from the existing `Genotyping pivot` with the unified known/candidate genotype matrix.

The top block contains the existing analyst-facing sample information, including:

- client and sample identifiers;
- mapped read counts;
- total read counts and percent unmapped;
- per-locus haplotype 1 and haplotype 2 rows;
- comments.

After a visual separator, the genotype table contains the current unified metadata columns and per-sample read-count columns. Known rows keep their raw call ID but use the GenBank allele value in `display_name`. Candidate rows retain their stable cluster ID, classification, support class, closest reference, occurrence count, sample count, total reads, and per-sample reads.

An explicit workbook update refreshes computed metrics and genotype rows while preserving nonblank analyst-entered haplotype assignments and comments from the top block. Generated values may populate blank cells, but they do not replace analyst-entered values.

### Unmatched Alleles

The second worksheet contains one row per stable unmatched sequence across both classified candidates and un-nameable clusters. Candidate and un-nameable rows share a single schema and are distinguished by an explicit record-category column.

Required columns include:

- record category (`candidate` or `un-nameable`);
- provisional allele name when available;
- stable cluster ID;
- locus when available;
- candidate classification or un-nameable reason;
- closest reference allele and raw reference ID when available;
- SNP, insertion, deletion, long-gap, and comparable-base summaries when available;
- support class, independent sample count, occurrence count, total reads, supporting sample IDs, and per-sample reads;
- FASTA record ID and sequence SHA-256;
- `Nucleotide Sequence` containing only the nucleotide cluster sequence;
- `Putative Amino Acid Translation` containing only the putative translated amino-acid sequence;
- `Translation Status`.

The nucleotide and putative amino-acid sequences are always stored in separate columns. They are never combined into one cell.

Translation status is one of:

- `full-length`: a trustworthy complete lifted CDS has an intact reading frame and no internal stop;
- `pseudogene`: the lifted CDS has an ORF-disrupting frameshift or internal stop;
- `incomplete/unresolved`: sequence coverage or lifted annotation is insufficient to judge a complete ORF.

The generated candidate and un-nameable GenBank records are the authoritative source for lifted CDS structure and putative translations. A compact workbook projection prepared in Swift supplies normalized rows to both initial workbook generation and explicit workbook updates, avoiding a second ad hoc GenBank parser in the Excel update script.

## Removed worksheets

New full-length MHC workbooks no longer contain the legacy interpretation, sample, genotype, unmatched-detail, unmatched-pivot, or separate candidate/un-nameable worksheets. The scientific CSV, JSON, FASTA, BAM/BAI, GenBank, statistics, and provenance files remain durable bundle artifacts and are not deleted or reduced.

## Inspector artifacts

The genotype result Inspector adds optional rows for:

- `Candidate Alleles GenBank`;
- `Un-nameable Clusters GenBank`.

Each URL is resolved from its checksummed `mhcCandidateArtifacts` manifest declaration using validated bundle-member path handling. Missing optional declarations produce no row. Both the SwiftUI document Inspector and the legacy in-viewport artifact lens use the same labels and resolved files.

## Provenance

Workbook projection and workbook-generation provenance records the candidate JSON/FASTA/GenBank and un-nameable JSON/FASTA/GenBank inputs used to populate `Unmatched Alleles`, plus the embedded reference metadata used for known display-name projection. Existing full-length MHC provenance requirements remain blocking.

## Error handling

- A missing GenBank allele display value falls back to the raw known-reference ID.
- A missing trustworthy translation produces a blank putative translation and `incomplete/unresolved` status.
- A declared but invalid GenBank artifact remains a bundle-load integrity error under existing validation rules; the Inspector does not bypass validation.
- Explicit workbook update fails before publishing a replacement when the compact workbook projection is malformed or inconsistent with stable sequence identities.

## Testing

Tests must be written before production changes and cover:

1. Raw known IDs remain call identities while mapped `Mafa-*` values populate workbook display labels, with raw-ID fallback when metadata is absent.
2. The workbook contains exactly `Unified Genotype Pivot` and `Unmatched Alleles`.
3. The unified sheet includes the sample/header block, known and candidate rows, and numeric per-sample read counts.
4. Explicit update preserves nonblank analyst haplotype assignments and comments while refreshing generated cells.
5. The unmatched sheet retains every candidate and un-nameable stable ID exactly once.
6. Nucleotide sequence, putative amino-acid translation, and translation status occupy distinct columns.
7. Full-length, pseudogene, and incomplete/unresolved status rules are exercised.
8. Both GenBank artifacts appear in both Inspector artifact surfaces when declared and disappear when absent.
9. Inspector paths cannot escape the result bundle.
10. The existing full-length MHC pipeline, workbook update, viewport, bundle validation, and provenance suites remain green.

