# Partial MHC Extension Design

## Goal

Represent a zero-SNP match across shared genomic sequence as a distinct
**partial extension** when the available evidence does not establish an exact,
end-to-end match to both the reference and observed candidate. This preserves
the exact shared-sequence relationship without overstating an incomplete match
as a known allele. Qualifying cDNA extension evidence is retained when present,
but is not required because short class II amplicons may omit part of the cDNA.

## Biological classification

Lungfish will add `partial-extension` to the candidate classification schema.
The user-facing provisional name will be `<allele>_partial_ext`.

Classification order for eligible reciprocal alignments will be:

1. Collect strong cDNA extension interpretations using the existing rule:
   zero SNPs, at least 95% cDNA reference coverage, no cDNA deficit segment of
   20 bases or more, no hard clipping, and at least one candidate structural
   segment of 20 bases or more.
2. If there is an exact, end-to-end zero-SNP genomic match, retain the existing
   known-allele classification. An exact genomic match must cover the complete
   candidate and complete genomic reference with no insertion, deletion,
   skipped-reference, soft-clipped, or hard-clipped bases.
3. If a zero-SNP genomic comparison has no insertion, deletion, or skipped
   reference event but does not cover both ends of the reference and candidate,
   publish a `partial-extension` candidate instead of a known allele. Preserve
   any compatible cDNA interpretations on that record.
4. If strong cDNA extension evidence exists and there is no zero-SNP genomic
   hit, retain the existing `extension` classification.
5. Zero-SNP genomic relationships containing internal insertion, deletion, or
   skipped-reference events retain existing behavior unless qualifying cDNA
   extension evidence independently supports an extension.

This rule is deliberately limited to exact shared genomic sequence with an
end-coverage limitation. A weak, SNP-containing, or internally gapped genomic
match alone is not sufficient to claim a partial extension.

## Data model and compatibility

`ONTMHCCandidateClassification` will gain the raw value `partial-extension`.
Existing `novel` and `extension` documents continue to decode unchanged. The
candidate document schema version will be incremented because a new enum value
is emitted. Older bundles remain readable by the updated application.

Partial-extension records will retain the same structured evidence already
stored for extensions:

- every compatible allele interpretation in `extension_of`;
- per-reference cDNA coverage and structural metrics;
- the selected genomic or cDNA reciprocal evidence locator;
- SNP, indel, comparable-base, support, and stable-sequence identity fields.

No diagnostic allele definitions or new import format will be introduced.

Canonical publication may encounter two raw consensus records that trim to the
same published sequence: one classified as a partial extension and one as a
novel sequence because its raw-only terminal bases contain a substitution. They
will be consolidated as one partial extension only when both interpretations
name the same genomic allele and locus and neither contains an insertion,
deletion, or skipped-reference segment. The raw classifications and source
cluster identities remain in the internal source map for audit. Different
allele interpretations still block publication rather than being conflated.

## Presentation and exports

The viewport and detail pane will label the category **Partial extension** and
show the `_partial_ext` provisional name. It will use the established extension
color family so novel and extension candidates remain visually consistent,
while the explicit name and badge distinguish the partial interpretation.

FASTA, GenBank, EMBL, workbook rows, and current-workbook regeneration will
carry the same provisional name and classification. GenBank and EMBL comments
will state that:

- the genomic comparison is zero-SNP across its shared sequence but is not
  exact and end-to-end;
- any qualifying cDNA structural-extension relationship, when present;
- which candidate/reference bases were inserted, deleted, skipped, clipped, or
  outside the aligned span;
- missing sequence was not imputed.

Existing missing-exon, missing-intron, and partial-reference comments remain in
place when annotated genomic projection is available.

## Provenance

The classification transformation will record:

- the exact end-to-end genomic-match rule;
- the partial-extension rule and precedence;
- the unchanged cDNA extension thresholds;
- counts of known, extension, partial-extension, novel, and un-nameable
  outcomes;
- the canonical partial-extension reconciliation rule and the number of
  published records that used it;
- all existing command, runtime, input/output, checksum, timing, and exit
  information required by Lungfish provenance policy.

## Verification

Tests will cover:

- exact genomic plus cDNA extension evidence remains known;
- incomplete zero-SNP genomic shared sequence becomes `partial-extension` and
  receives `_partial_ext`, with or without qualifying cDNA evidence;
- the same qualifying cDNA evidence without a zero-SNP genomic hit remains a
  normal extension;
- SNP-containing or internally gapped genomic evidence alone does not become a
  partial extension;
- JSON round-trip, workbook projection, viewport labels, sequence-detail
  comments, and provenance;
- backward decoding of prior candidate documents.

The four reported DRB samples (`CN29`, `CN54`, `CY44`, and `DI20`) will be run
against `IPD-MHC_NHKIR_Mamu-DRB.v3.17.0.0.2.lungfishref` in a temporary
validation bundle. Their known, extension, partial-extension, novel, and
un-nameable outcomes will be inspected together with GenBank/EMBL comments and
the provenance envelope. Every exported un-nameable sequence will also be
queried against NCBI core-nt to check for overlooked MHC-DRB sequence. The
deduplicated unmatched set must be accounted for by viewport-visible candidate
or reviewable incomplete rows; an empty un-nameable set is recorded explicitly
rather than submitted as an empty BLAST query. Temporary validation output will
be moved to Trash after inspection.
