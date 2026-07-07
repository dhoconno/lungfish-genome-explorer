# Accessibility and tone review: genotyping, 12S, and AI Assistant chapters

**Date:** 2026-07-04
**Method:** Three simulated reader panels read the six chapters added in the
2026-07-04 functionality-coverage pass and reported honest reactions. The
target standard was a college-level biology student, with a secondary goal of
prose that reads as human-written rather than templated. The panels were an
undergraduate biology group (sophomore through senior), a wet-lab group (a
master's student and a new immunogenetics technician with bench but no
bioinformatics experience), and a plain-language tone critic.

## Chapters reviewed

- `09-genotyping/01-what-is-mhc-genotyping`
- `09-genotyping/02-running-genotyping`
- `09-genotyping/03-reading-the-genotype-comparison`
- `09-genotyping/04-haplotype-definitions-and-export`
- `06-classification/10-twelve-s-metabarcoding`
- `appendices/ai-assistant`

## Headline finding

The 12S metabarcoding chapter and the AI Assistant appendix cleared the
college-biology bar and were named the in-house style model: they gloss every
load-bearing term inline at first use and explain why before how. The four
genotyping chapters were rated Rough for two separable reasons. First,
accessibility: undefined file-format and platform acronyms, and a missing
biological foundation. Second, artificiality: scaffolding phrases repeated
verbatim across chapters.

## Accessibility fixes applied

The keystone fix was a new paragraph in chapter 01 explaining why Mauritian
cynomolgus macaques carry a small set of fixed MHC haplotype blocks (a founder
bottleneck), so that "M-family" reads as biology rather than software jargon.
Everything downstream (the H1 and H2 report slots, the haplotype tape, the
overcall guard) depends on that paragraph. The diploid foundation, that an
animal inherits at most two MHC haplotypes, was stated explicitly wherever the
H1 and H2 slots and the overcall guard appear, which turns the overcall guard
from an arbitrary threshold into an obvious biological check.

Core acronyms (FASTQ, FASTA, VCF, ONT, MiSeq, indel, consensus sequence) and
concepts (locus, haplotype, barcode, demultiplex, cohort, provenance, headless)
now carry a one-line inline gloss at first use in chapters 01 and 02, in the
12S chapter's parenthetical style. The `0068[MHC-A1]` allele-target notation is
decoded at first appearance, and the term "allele target" is used consistently
for a reference allele in the library. Chapter 02 now answers where the
`.lungfishmhcref` reference bundle comes from. Chapter 03 drops an insider
negative definition and reframes the overcall example as hypothetical. Chapter
04 gained a short "who this chapter is for" note and glosses for LabKey,
long-format export, and workbook revisions.

## Tone fixes applied

The four repeated "So what should you do with this" closers and the repeated
"By the end of this chapter you will be able to" openers were each reworded so
no two chapters share the stamped phrasing. Lockstep triads (the "the matrix
answers, the tape answers, the summary answers" construction, and the 12S
"first, second, third" checklist) were varied. The four copies of the "newer
workflow area" note were differentiated. Self-narrating filler and soft hedges
were replaced with direct statements.

## What the panels asked to preserve

The amplicon and MHC opening definitions; the alleles-versus-haplotypes section
and its worked notation; the three-route table; the clustering motivation; the
three-regions dashboard framing and the reassurance that a `?` is not a
failure; the rulebook metaphor and the inline definition of deterministic; and
the AI Assistant can-do and cannot-do split. These were left intact.
