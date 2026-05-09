# Foundations focus group 4: power users

**Date:** 2026-05-09
**Method:** Five experienced power-user personas (15+ years, PIs, consultants, tool developers) reading the eight foundations chapters as a unit. See `synthesis.md` for cross-cutting issues.

## Key findings from this group

- iVar QUAL/FILTER attribution is wrong. iVar emits TSV; Lungfish's converter chooses the QUAL semantics.
- CIGAR example with N-padded bases is factually wrong. Soft-clipped bases retain their original calls.
- Plugin pack version pins recipe but not full conda environment. Clinical reproducibility needs OCI image or lockfile.
- The Methods Section export is dangerous. Will be pasted verbatim into papers without review.
- Q-score table dating: Oxford Nanopore Q10-Q25 raw is dated; modern R10.4.1 simplex is Q20+, duplex is Q30+.

## What worked

- Provenance sidecar is the standout reason senior readers would adopt the tool.
- Chapter 7's "why conda not pip" rationale is the only respectful explanation power users had seen.
- Chapter 5's two-row PASS/ft contrast and haploid AF section.
- Honest "what does not capture" section in chapter 8 is best-in-class.

## Personas

1. Dr. Margaret Chen, senior staff scientist, sequencing core (15+ years)
2. Prof. James Okonkwo, PI, viral surveillance lab (20+ years)
3. Sara Linhardt, bioinformatics consultant for clinical labs (10 years)
4. Dr. Aaron Vinokur, postdoc, computational biology (8 years)
5. Lin Patel, bioinformatics engineer, sequencing company

Full transcripts in the synthesis document.
