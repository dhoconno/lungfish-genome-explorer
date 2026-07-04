---
title: What Is Amplicon MHC Genotyping
chapter_id: 09-genotyping/01-what-is-mhc-genotyping
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 01-foundations/03-amplicon-vs-shotgun, 01-foundations/06-the-lungfish-project]
estimated_reading_min: 7
task: Understand what amplicon MHC genotyping is, how alleles differ from haplotypes, and when to use the Lungfish genotyping workflows.
tags: [genotyping, mhc, immunogenetics, haplotype, amplicon, macaque]
tools: []
entry_points:
  - "Workflow Library > miSeq amplicon MHC genotyping"
shots: []
planned_shots:
  - id: workflow-library-genotyping
    caption: "The Workflow Library with the miSeq amplicon, ONT, and full-length ONT MHC genotyping workflows listed in the genotyping group."
  - id: alleles-vs-haplotypes-schematic
    caption: "A schematic contrasting individual MHC alleles at one locus with a named M-family haplotype that spans MHC-A, MHC-E, MHC-B, MHC-DR, MHC-DQ, and MHC-DP."
illustrations: []
glossary_refs: [amplicon, allele, haplotype, mhc, immunogenetics, reference-bundle]
features_refs: [genotype.amplicon, genotype.full-length-ont-mhc, viewport.genotype-matrix]
fixtures_refs: []
brand_reviewed: true
lead_approved: false
---

!!! note "Newer workflow area"
    MHC genotyping is a newer part of Lungfish than the alignment and variant
    workflows. No Mauritian cynomolgus macaque MHC example dataset ships with
    this manual yet, so every genotype, allele-target ID, and read count you
    see here is drawn from the reference definition set purely to illustrate
    the shape of a result. Read the numbers as representative, not as output
    you can reproduce from a bundled fixture.

## What it is

Amplicon MHC genotyping reads the immune-recognition region of a genome by
sequencing many short, targeted PCR products and matching each read against a
library of known allele sequences. An amplicon is a short stretch of DNA copied
from one defined region by PCR. The reads arrive as FASTQ files (the standard
text format holding sequencing reads and their quality scores), and the library
they are matched against is a FASTA file (a plain-text file listing each
sequence). The MHC (major histocompatibility complex) is the dense cluster of
immune-system genes that a genotyping assay is trying to characterise. The
worked organism throughout this chapter is the Mauritian cynomolgus macaque,
abbreviated MCM, because its MHC region is unusually well catalogued and its
haplotypes are named and stable.

The genotyping workflows live together in the Workflow Library, alongside the
short-amplicon miSeq route, which expects reads from a MiSeq (an Illumina
short-read platform), and the full-length Oxford Nanopore (ONT) route, which
expects long reads.

<!-- planned: workflow-library-genotyping -->

The important difference from ordinary variant calling is the question the
assay asks. Ordinary variant calling lines your reads up against one reference
genome and lists every position where the sample differs from it. That list is
a VCF (a variant-call file recording positions where a sample differs from a
reference). Amplicon MHC genotyping asks something else entirely. It does not
hunt for per-position differences against a single reference. Instead, for each
of the hundreds of known MHC allele sequences held in a curated library, it
asks one plain question: is this allele present in this animal, and how many
reads support it? The result is a presence-and-support matrix across an allele
library, not a list of coordinate differences.

So what should you do with this? The one habit to carry into every later
chapter is to keep the allele-versus-family distinction straight from the
outset, because almost every way a genotype result gets misread traces back to
blurring those two units. With that in hand, work out which route your reads
belong to and continue to [Running Amplicon MHC
Genotyping](02-running-genotyping.md).

## What you will learn

This chapter builds the vocabulary the rest of the section leans on. You will
come away able to say what a genotyping run consumes and produces, to tell an
individual allele apart from a named M-family haplotype, and to judge which
parts of a result Lungfish settles on its own versus which it hands back for a
person to curate. It also lays out how to choose between the miSeq and ONT
routes before you commit reads to either.

## Alleles versus haplotypes

Mauritian cynomolgus macaques descend from a small group of founders that
reached the island only a few centuries ago. That genetic bottleneck left the
whole colony carrying just a handful of MHC variants. Because the region is
passed down as one long block rather than reshuffled gene by gene, the entire
MHC of a Mauritian animal is almost always one of a small, fixed set of blocks
named M1 through M7. Each of these M-families is a whole-region haplotype: a
single set of alleles inherited together as a block, spanning all six MHC loci
(a locus is the spot on a chromosome where a particular gene sits). Those six
are three class I loci (MHC-A, MHC-E, and MHC-B) and three class II loci
(MHC-DR, MHC-DQ, and MHC-DP). This is why the rest of these chapters can name a
family such as M1 and treat it as a single unit. In this population it
effectively is one.

Against that backdrop, two units of evidence run through every genotyping
result, and it pays to keep them straight from the start. The first is the
allele target: one reference allele sequence in the library, the thing a read
either matches or does not. Each allele target has an identifier such as
`0068[MHC-A1]`, where `0068` is that sequence's catalogue number in the library
and the bracketed part names its locus. The second unit is the named haplotype,
an M-family (M1 through M7 for MCM) that spans all six loci at once. Reads match
allele targets directly. M-families are the interpretation Lungfish builds on
top of those matches. Throughout these chapters, "allele target" always means
one reference sequence in the library, and "allele" on its own means a sequence
actually observed in an animal.

The illustrative block below shows one allele target and the family it helps
define. The M1 family is spread across the six loci in the MCM miSeq definition
set, so a run does not "see" M1 as a single thing. It sees the individual
allele targets and assembles the family from them.

```text
Allele target (one library sequence):  0068[MHC-A1]
Named haplotype (M-family):            M1

M1 across the six MCM miSeq loci (illustrative):
  MHC-A    0068[MHC-A1], 0129[MHC-K], 0079[MHC-AG1]
  MHC-E    0010
  MHC-B    0073[MHC-B], 0065[MHC-B]
  MHC-DR   0169[MHC-DRB], 0166[MHC-DRB]
  MHC-DQ   0173[MHC-DQB1]
  MHC-DP   0007[MHC-DPA1], 0154[MHC-DPB1]
```

<!-- planned: alleles-vs-haplotypes-schematic -->

Because of that founder history, MCM M-families are usually intact: the same
family tends to hold together across neighbouring loci, and Lungfish prefers to
keep a family intact when the evidence allows, since an intact pattern is the
common biological case. It does not force an intact pattern over strong direct
evidence to the contrary. When a locus carries an allele target that clearly
belongs to a different family, that evidence stays visible and the locus is
marked discordant or unresolved rather than smoothed into a tidy family call.

## What Lungfish does and does not do

Within a genotyping run, Lungfish matches reads to the MHC allele library,
tallies per-allele-target read support, presents the results as a comparison
matrix, assembles the supported allele targets into named M-family calls for
each locus, and exports the reviewed result. Each locus gets two report slots,
labelled H1 and H2. Two slots is not an arbitrary number: an animal inherits at
most two MHC haplotypes, one from each parent, so at any locus there are at most
two families to show.

It is tempting to read H1 as the family from one parent and H2 as the family
from the other. Resist that. H1 and H2 are report positions, nothing more.
Lungfish reorders them freely to keep the same M-family aligned down a column of
loci, so a slot carries no parental origin, and an unresolved slot is written as
`?`.

Those two slots also set up the workflow's main guardrail. A single diploid
animal cannot genuinely carry three or more different M-families at one locus,
because it has only two haplotypes to give. So when three or more families turn
up with credible support at a locus, Lungfish does not quietly pick the two
strongest and move on. It reports `?/?` and flags the locus for a person,
because an excess of well-supported families usually means the sample is mixed
or contaminated rather than richly heterozygous. That behaviour is the overcall
guard, covered in detail in [Reading the Genotype Comparison
Viewport](03-reading-the-genotype-comparison.md). A fourth or fifth strongly
supported family is not a weak extra call to discard. It is a reason for a human
to look.

## When to use amplicon MHC genotyping

The choice between the two routes comes down to read length and the panel you
ran. The short-amplicon miSeq route expects paired Illumina reads from the
established MCM miSeq amplicon panel. It maps short reads to the allele library
and counts exact and indel-aware matches per allele target, where an indel is a
small insertion or deletion. Use it when your wet-lab protocol is the miSeq
amplicon panel and you want fast, well-calibrated calls against the curated
allele set.

The full-length ONT route expects long Oxford Nanopore reads that span whole
allele sequences. It first clusters reads into consensus sequences (a consensus
sequence is a single cleaned-up sequence built from many overlapping noisy
reads), using Savont or pbAA, and then genotypes those consensus sequences
against the allele library. Use it when your reads are long enough to cover a
full allele, when you want full-length allele resolution, or when you are
working outside the fixed miSeq panel. Both routes end in the same place: a
genotype result bundle you open in the comparison dashboard.

## Next

Continue to [Running Amplicon MHC Genotyping](02-running-genotyping.md) to
launch a run, or skip ahead to
[Reading the Genotype Comparison Viewport](03-reading-the-genotype-comparison.md)
if you already have a result bundle to open.
</content>
</invoke>
