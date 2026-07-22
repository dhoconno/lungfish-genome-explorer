# Forward MHC Extension Classification and Workbook Numeric-Type Hardening

## Scope

This change applies only to new full-length ONT MHC analyses and the current two-sheet workbook (`Unified Genotype Pivot` and `Unmatched Alleles`). It does not migrate, reinterpret, or clean up historical nine-sheet workbooks, legacy reporting worksheets, or other vestigial workflows.

The existing reciprocal candidate classifier remains the sole user-facing authority for whether a sequence is a known genotype, a provisional novel allele, an extension, or un-nameable. Preliminary closest-hit metadata may continue to support trimming and evidence discovery, but it must not determine the classification shown in the current app viewport or current workbook.

## Confirmed Historical Failure

The supplied July 16 workbook was produced before the reciprocal candidate classifier was introduced. Its older closest-hit rule labeled every unmatched zero-SNP alignment as an extension without requiring a cDNA reference, complete reference coverage, intron filling, or absence of terminal truncation. This explains both reported false extensions:

- `8cc8b3d2-9696-5112-a902-aadad44b5e5d` was labeled as an A2*24 extension even though the sequence lacks the 5′ end of the allele.
- `0b9c9d93-4df5-5566-bcc8-9b73f1fc8924` was labeled as an A1*003 extension even though its relationship to the genomic reference is a zero-SNP, one-base deletion.

The current classifier already distinguishes genomic from cDNA references and requires complete cDNA coverage for extensions. This work makes the desired indel rule explicit and adds regressions so it cannot silently change.

## Authoritative Forward Classification

An eligible reciprocal alignment is classified in this order:

1. A zero-SNP alignment to a genomic-DNA reference is a known genotype, regardless of insertion or deletion differences.
2. A zero-SNP alignment to a cDNA reference is an extension when it:
   - spans the complete cDNA reference;
   - spans the complete query cluster without soft clipping;
   - contains at least one internal query insertion at or above the configured intron-gap threshold;
   - contains no SNP substitutions; and
   - contains no skipped reference interval.
3. Ordinary non-intron insertions and deletions are permitted in an otherwise valid cDNA extension and remain recorded in the candidate metrics. They do not create an `_Nnt_nov` name because `N` counts substitutions only.
4. A zero-SNP cDNA relationship that lacks complete cDNA coverage or lacks internal intron filling is a genotype of the existing allele, subject to the existing eligibility thresholds.
5. An eligible relationship with one or more SNP substitutions is a novel candidate named `_Nnt_nov`, where `N` counts SNP substitutions only.
6. Alignments that fail the existing aligned-base, identity, coverage, or reference-resolution thresholds remain un-nameable.

This produces the intended outcomes for the reported shapes:

- Complete cDNA coverage plus filled introns and a one-base indel: `_ext`.
- One-base indel against an existing genomic reference: known genotype.
- Missing terminal cDNA reference sequence: not `_ext`; it falls through to the existing zero-SNP genotype rule when otherwise eligible.
- Any SNP substitution: never `_ext`.

The existing support policy is unchanged. Singleton and shared candidates remain visible separately, while only candidates supported by two or more samples are eligible for future reference-database inclusion.

## Current Workbook Numeric Types

New two-sheet workbooks must store semantically numeric values as Excel numeric cells rather than strings. This includes:

- `Mapped Read Count` total, average, and per-sample values;
- `total_read_count` per-sample values;
- `percent_reads_unmapped` per-sample values;
- Unified table occurrence, sample, total-read, and per-sample counts; and
- Unmatched Alleles SNP/indel/alignment/support/read-count fields.

The latter two groups are already numeric and must remain so. The first three analyst-summary rows are the current defect.

Identifiers remain text even when they contain only digits or leading zeroes. This includes sample identifiers, raw reference IDs, cluster IDs, allele names, haplotypes, and comments. The implementation must use typed source fields rather than generically converting numeric-looking strings.

Explicit workbook updates must preserve the same numeric-cell contract as initial workbook creation.

## Current Workbook Documentation

The current workflow's interpretation text must state that:

- known genomic calls permit zero-SNP indel-only differences;
- cDNA extensions require complete cDNA coverage and intron filling;
- non-intron indels are allowed in extensions; and
- SNP substitutions prevent extension classification.

No historical workbook is rewritten.

## Testing

Regression tests must cover:

- a complete cDNA extension containing an internal intron-sized insertion and an ordinary one-base insertion or deletion;
- a terminally truncated cDNA relationship with intron filling that must not be an extension;
- a zero-SNP genomic one-base indel that remains known;
- a cDNA sequence with intron filling and a SNP that becomes `_1nt_nov`, not `_ext`;
- typed `Mapped Read Count`, `total_read_count`, and `percent_reads_unmapped` cells in the in-memory current workbook projection;
- numeric OOXML cells for the same summary statistics in the exported workbook;
- numeric cells after an explicit current-workbook update; and
- preservation of text typing for numeric-looking identifiers.

Focused classifier, workbook projection, workbook revision, pipeline, viewport, and debug-identity suites must pass. A fresh debug build must be created and launched after each implementation set, with the final instance named `Lungfish Debug`.

## Provenance

The existing full-length MHC workflow provenance remains authoritative and must continue to capture the workflow version, argv and resolved defaults, runtime identity, input/output paths, checksums, file sizes, exit status, wall time, and useful stderr. The current workbook and candidate artifacts must remain represented by final bundle paths and checksums. No provenance schema change is required because the classification is part of the versioned workflow implementation rather than a new user option.
