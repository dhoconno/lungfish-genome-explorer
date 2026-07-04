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
    this manual yet, so every genotype, target ID, and read count in this
    chapter is drawn from the reference definition set as an illustrative
    example. Treat these values as representative of the shape of a result, not
    as a guaranteed output you can reproduce from a bundled fixture.

## What it is

Amplicon MHC genotyping reads the immune-recognition region of a genome by
sequencing many short, targeted PCR products and matching each read against a
library of known allele sequences. An amplicon is a short stretch of DNA copied
from one defined region by PCR. The MHC (major histocompatibility complex) is
the dense cluster of immune-system genes that a genotyping assay is trying to
characterise. The worked organism throughout this chapter is the Mauritian
cynomolgus macaque, abbreviated MCM, because its MHC region is unusually well
catalogued and its haplotypes are named and stable.

The genotyping workflows live together in the Workflow Library, alongside the
short-amplicon miSeq route and the full-length ONT route.

<!-- planned: workflow-library-genotyping -->

The important difference from ordinary variant calling is what the assay
compares against. GATK germline calling (see
[HaplotypeCaller](../06-human-germline-variants/01-haplotype-caller.md))
compares your reads to one reference genome and reports the positions where
they differ, as a VCF. Amplicon MHC genotyping does not look for per-position
differences against a single reference. It asks, for each of hundreds of known
MHC allele sequences in a curated library, whether that allele is present in
this animal and with how much read support. The result is a presence-and-support
matrix across an allele library, not a list of coordinate variants.

So what should you do with this: read this chapter to decide whether your data
belongs in the short-amplicon miSeq route or the full-length ONT route, then
move to [Running Amplicon MHC Genotyping](02-running-genotyping.md).

## What you will learn

By the end of this chapter you will be able to say what an amplicon MHC
genotyping run consumes and produces, tell the difference between an individual
allele and a named M-family haplotype, describe what Lungfish decides
automatically and what it hands back for human curation, and choose between the
miSeq and ONT routes for your own reads.

## Alleles versus haplotypes

Two units of evidence run through every genotyping result, and keeping them
distinct is the single most useful habit for reading one. An allele here is an
individual MiSeq target: one sequence in the reference library, written with its
target ID and a source label, such as `0068[MHC-A1]`. A named haplotype is an
M-family (M1 through M7 for MCM) that spans all six MHC loci at once: MHC-A,
MHC-E, MHC-B, MHC-DR, MHC-DQ, and MHC-DP. Alleles are what the reads match
directly. M-families are the interpretation Lungfish builds on top of those
matches.

The illustrative block below shows one allele target and the family it helps
define. The M1 family is spread across the six loci in the MCM MiSeq definition
set, so a run does not "see" M1 as a single thing. It sees the individual
targets and assembles the family from them.

```text
Allele (one MiSeq target):   0068[MHC-A1]
Named haplotype (M-family):  M1

M1 across the six MCM MiSeq loci (illustrative):
  MHC-A    0068[MHC-A1], 0129[MHC-K], 0079[MHC-AG1]
  MHC-E    0010
  MHC-B    0073[MHC-B], 0065[MHC-B]
  MHC-DR   0169[MHC-DRB], 0166[MHC-DRB]
  MHC-DQ   0173[MHC-DQB1]
  MHC-DP   0007[MHC-DPA1], 0154[MHC-DPB1]
```

<!-- planned: alleles-vs-haplotypes-schematic -->

MCM M-families are usually intact: the same family tends to hold together across
neighbouring loci. Lungfish prefers to keep a family intact when the evidence
allows, because an intact pattern is the common biological case. It does not
force an intact pattern over strong direct contradictory evidence. When a locus
carries a target that clearly belongs to a different family, that direct
evidence stays visible and the locus is marked discordant or unresolved rather
than being smoothed into a tidy family call.

## What Lungfish does and does not do

Within a genotyping run, Lungfish matches reads to the MHC allele library, tallies
per-target read support, presents the results as a comparison matrix, assembles
the supported targets into named M-family calls for each locus, and exports the
reviewed result. Each locus gets two report slots, labelled H1 and H2. These are
presentation slots only: Lungfish swaps them freely to keep the same M-family
aligned across loci, and an unresolved slot is written as `?`.

Two limits are worth stating plainly, because they are where a reader's
expectations most often diverge from what the workflow produces.

- Lungfish does not describe the two slots as separate physical arrangements of
  DNA. H1 and H2 are report columns, nothing more.
- When more than two M-families have credible, non-trivial support at a locus,
  Lungfish does not force the two strongest into H1 and H2. It reports `?/?` and
  flags the locus for human curation, because too many credible families is a
  signal that the sample is not confidently interpretable by this workflow.

That second behaviour is the overcall guard, and it is covered in detail in
[Reading the Genotype Comparison Viewport](03-reading-the-genotype-comparison.md).
The short version: a fourth or fifth strongly supported family is not a weak
extra call to be discarded. It is evidence that a human should look.

## When to use amplicon MHC genotyping

The choice between the two routes comes down to read length and the panel you
ran. The short-amplicon miSeq route expects paired Illumina reads from the
established MCM MiSeq target panel. It maps short reads to the allele library and
counts exact and indel-aware matches per target. Use it when your wet-lab
protocol is the miSeq amplicon panel and you want fast, well-calibrated calls
against the curated target set.

The full-length ONT route expects long Oxford Nanopore reads that span whole
allele sequences. It clusters reads into consensus sequences first, with Savont
or pbAA, and then genotypes those consensus sequences against the allele
library. Use it when your reads are long enough to cover a full allele, when you
want full-length allele resolution, or when you are working outside the fixed
miSeq panel. Both routes end in the same place: a genotype result bundle you
open in the comparison dashboard.

## Next

Continue to [Running Amplicon MHC Genotyping](02-running-genotyping.md) to
launch a run, or skip ahead to
[Reading the Genotype Comparison Viewport](03-reading-the-genotype-comparison.md)
if you already have a result bundle to open.
