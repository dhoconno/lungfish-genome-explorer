# cDNA-relative GenBank comments for MHC extensions

## Goal

Make `_ext` GenBank records describe sequence differences only relative to the
cDNA allele being extended. A genomic reference may still supply exon, intron,
CDS, and translation coordinates, but its sequence differences must not be
presented as candidate changes.

## Extension comment contract

For each compatible cDNA interpretation, the GenBank comments retain:

- the cDNA allele name and raw reference ID;
- cDNA and cluster coverage;
- identity, SNP-substitution count, and ordinary-indel count;
- structural evidence establishing that the genomic consensus extends the cDNA.

When the cDNA substitution count is zero, the record explicitly states that no
SNP-defined amino-acid differences were detected relative to that cDNA. Any
ordinary indel count remains a nucleotide-level cDNA comparison and follows the
existing rule that zero-SNP indel-only relationships are genotypes of the
existing allele.

## Genomic scaffold comment contract

An extension record identifies the selected genomic record as its feature
scaffold and states that it was used only to lift exon, intron, and CDS
coordinates. The record explicitly says that sequence differences relative to
the scaffold are intentionally not reported.

Extension records omit:

- scaffold-relative consequence summaries and individual change comments;
- scaffold-relative reciprocal-alignment CIGAR details;
- scaffold-relative amino-acid length or translation comparisons;
- generic “selected reference” wording that could imply biological identity.

The lifted features, candidate translation, scaffold accession, and orientation
remain available.

## Non-extension behavior

Novel candidates retain the existing genomic-reference consequence reporting,
including nonsynonymous, synonymous, intronic, alignment, and translation
comparison comments. Un-nameable records are unchanged.

## Verification

Tests must demonstrate that:

1. An extension with an exact cDNA interpretation reports zero cDNA
   substitutions and no SNP-defined amino-acid differences.
2. The genomic scaffold is identified only as a feature scaffold.
3. No scaffold-relative CIGAR, consequence prefix, individual consequence, or
   closest-reference translation comparison appears in the extension record.
4. A novel candidate still emits the existing genomic-relative consequence
   comments.
5. GenBank write/read round-tripping preserves the new extension comments.

