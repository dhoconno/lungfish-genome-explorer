---
title: Reading the Genotype Comparison Viewport
chapter_id: 09-genotyping/03-reading-the-genotype-comparison
audience: bench-scientist
prereqs: [09-genotyping/02-running-genotyping]
estimated_reading_min: 10
task: Read the genotype comparison matrix, haplotype tape, cohort summary, and per-sample call evidence, and apply manual haplotyping and annotation overrides.
tags: [genotyping, mhc, haplotype, matrix, cohort, viewport, macaque]
tools: []
entry_points:
  - "Open a genotype result bundle from the sidebar"
shots: []
planned_shots:
  - id: genotype-matrix-overview
    caption: "The genotype comparison viewport with the allele-by-sample matrix, one row per allele target and one column per sample."
  - id: genotype-haplotype-tape
    caption: "The haplotype tape above the matrix showing the H1 and H2 called M-family haplotype per locus for a selected sample."
  - id: genotype-cohort-summary
    caption: "The cohort summary panel tallying haplotype calls across every sample in the run."
  - id: genotype-call-evidence
    caption: "The per-sample call-evidence panel listing observed target IDs, read counts, and the rationale behind a called haplotype."
  - id: genotype-manual-haplotyping
    caption: "The manual haplotyping control overriding an unresolved locus slot with an analyst-set M-family call."
illustrations: []
glossary_refs: [genotype, haplotype, mhc, allele, cohort, genotype-matrix]
features_refs: [viewport.genotype-matrix]
fixtures_refs: []
brand_reviewed: true
lead_approved: false
---

!!! note "Newer workflow area"
    MHC genotyping is a newer part of Lungfish, and no MCM MHC example dataset
    ships with this manual yet. The sample names, target IDs, read counts, and
    calls in this chapter are illustrative. They show how the dashboard reads,
    not a fixture you can open and match cell for cell.

## What it is

The genotype comparison viewport is the dashboard where you read a genotype
result bundle. It is a comparison surface, not a genome view: it does not draw a
coordinate axis, and it is deliberately not one of the five genomic viewport
classes (sequence, alignment, variant, taxonomy, assembly). Instead it lays out
allele-target rows against sample columns and layers the M-family calls on top.

<!-- planned: genotype-matrix-overview -->

The dashboard has three regions that answer three different questions. The
comparison matrix answers "which targets did each sample show, and how
strongly." The haplotype tape answers "which M-family did each locus resolve
to." The cohort summary answers "across all my samples, what needs attention."
Selecting a sample or a locus in one region updates the others, so you move
between the raw evidence and the finished call without leaving the viewport.

So what should you do with this: read the tape for the finished call, drop into
the matrix and call evidence when a call looks surprising, and let the cohort
summary steer you to the samples that need a human.

## What you will learn

By the end of this chapter you will be able to read the comparison matrix and
the haplotype tape, open the per-sample call evidence to see which targets and
read counts drove a call, recognise the overcall guard when it fires, and apply
a manual haplotyping override or an annotation to a locus slot.

## The genotype comparison matrix

The matrix is the raw evidence layer. Each row is an allele target from the
reference library, written with its target ID and source label such as
`0068[MHC-A1]`. Each column is a sample. A filled cell means that sample showed
that target, and the cell carries the retained read count behind it. Reading a
column top to bottom tells you every target a sample produced. Reading a row
left to right tells you which samples share a target.

Cells are colored by the M-family they support, using a fixed palette so the
same family reads the same way everywhere in the report. When a target is shared
by more than one family, Lungfish colors it as a resolved family only when the
surrounding primary evidence or a linked locus settles which family it belongs
to. Otherwise the cell is marked shared or ambiguous rather than being given a
misleading color. The matrix never modifies the bundle: sorting, filtering, and
selecting are display state only.

## The haplotype tape

The haplotype tape sits above the matrix and shows the finished call. For the
selected sample it lays out the six MHC loci (MHC-A, MHC-E, MHC-B, MHC-DR,
MHC-DQ, and MHC-DP), each with two slots labelled H1 and H2. Each slot holds an
M-family name or a `?` when the slot is unresolved.

<!-- planned: genotype-haplotype-tape -->

The two slots are report positions, nothing more. Lungfish swaps H1 and H2
freely to keep the same M-family aligned down a column of loci, because an intact
family is the common case. A `?` is not a failure: it is an honest statement that
the evidence at that slot did not resolve to one family. Clicking a slot selects
that locus and pulls its supporting targets into focus in the matrix and the
call-evidence panel.

## The cohort summary

The cohort summary is the triage layer for a multi-sample run. It tallies the
run rather than any single sample: how many samples fell below the read-support
threshold, how many carry errors, how the quality-control statuses are
distributed, and how many analyst annotations exist. Each tally names its samples
when you hover the count, so you can jump straight to the ones that need work.

<!-- planned: genotype-cohort-summary -->

The summary is where you start on a fresh cohort. A run of forty animals might
have five that need a human, and the summary is how you find those five without
opening all forty.

## Procedure

### Step 1. Open a genotype result bundle

Open your project and click the genotype result bundle in the sidebar. The
viewport switches to the comparison dashboard, with the cohort summary and the
sample list populated. If the bundle does not appear, its run has not finished;
wait for the Operations Panel row to turn green.

### Step 2. Read the matrix and the haplotype tape

Read the finished call first, then the evidence behind it. Because the intact
M-family is the common pattern, a healthy sample usually shows the same family
running down the H1 slots of several loci and a second family running down H2.
Select a sample from the list. Read its haplotype tape across the six loci, then
glance at the matrix below: the colored cells under that sample column should
cluster into the same one or two families the tape names.

When a tape slot reads `?`, click it. The matrix highlights the targets that
locus does have, so you can see whether the slot is empty for lack of reads or
unresolved because the evidence is split.

### Step 3. Read per-sample call evidence

The call-evidence panel is where a call explains itself. For a selected sample
and locus it lists the observed target IDs, their read counts, and a short
rationale for the call. The rationale is what turns a set of matches into a
defensible family assignment.

<!-- planned: genotype-call-evidence -->

Four rationale categories cover most calls. This is a simplification of a longer
internal set, kept short here because these four are the ones you act on:

- `direct-primary`: a defining target for the family is present with credible
  support, so the family is called directly.
- `shared-resolved`: a target shared by several families was resolved to one
  family by neighbouring primary or linked-locus evidence.
- `secondary-rescued`: primary targets could not settle the locus, so additional
  workbook-mapped targets rescued the call under strict support rules.
- `overcall-human-curation`: too many families have credible support, so the
  locus is reported `?/?` and handed to a human.

The overcall guard behind that last category is worth understanding, because it
is where the workflow refuses to guess. Before ranking any calls, Lungfish asks
whether the sample looks like one interpretable animal at all. If more than two
M-families have credible, non-trivial support at a locus, a fourth or fifth
family is not treated as a weak extra heterozygous call. It is treated as
evidence that the sample is not confidently interpretable, and the locus is
reported `?/?`. The archetype is an LF2840-like sample: credible support for
nearly every family, M1 through M7, repeated across many loci. That pattern is
more consistent with a mixed sample or cross-sample carryover than with a rich
genotype, so all six loci report `?/?` with the rationale
`overcall-human-curation` naming the excess families, rather than being reduced
to the two highest-scoring families.

### Step 4. Apply manual haplotyping and annotation overrides

When you have read the evidence and disagree with a slot, you set the call
yourself. Select the sample and locus, then use the override control in the
call-evidence panel to set a slot to the M-family the evidence supports. Your
override is recorded with your name, a timestamp, the original call, and your
stated reason, so the audit trail shows both the pipeline call and the human
decision. Overrides merge over the pipeline result: the exported call is the
active, post-override call, and the original is never lost.

<!-- planned: genotype-manual-haplotyping -->

You can also annotate the matrix without changing a call. Select cells, rows, or
columns to add a color, a note, or a comment that travels with the bundle and
into the exports. Use overrides to change what the call is, and annotations to
record why a cell deserves a second look.

## Interpretation

A well-behaved sample reads cleanly: one or two M-families run intact down the
loci, the tape has few `?` slots, and the call evidence rests on `direct-primary`
or cleanly `shared-resolved` rationales. A sample worth pausing on shows one of
two shapes. A locus with a single strong family and no credible second signal is
an apparent single-family locus, which is normal and not an error. A sample where
the summary flags many families across many loci, and the loci report `?/?` with
`overcall-human-curation`, is the workflow telling you the input state is the
problem. Do not override those slots into a best-two call. Trace the sample back
to the wet lab instead.

## Next

Continue to
[Haplotype Definitions, AI-Assisted Haplotyping, and Export](04-haplotype-definitions-and-export.md)
to edit the named haplotypes behind these calls and to export the reviewed
bundle.
