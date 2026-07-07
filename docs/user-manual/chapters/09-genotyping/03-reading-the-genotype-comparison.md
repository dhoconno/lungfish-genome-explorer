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
    MHC genotyping arrived in Lungfish after the alignment and variant tools.
    This manual still lacks a bundled MCM MHC example dataset, so the sample
    names, allele-target IDs, read counts, and calls shown here are invented to
    demonstrate how the dashboard reads, not cells you can match one for one.

## What it is

The genotype comparison viewport is the dashboard where you read a genotype
result bundle. Think of it as a comparison surface, not a genome view. There is
no coordinate axis. Instead it lays out allele-target rows against sample columns
and layers the M-family calls on top.

<!-- planned: genotype-matrix-overview -->

The dashboard has three regions, and it helps to know what each is for before
you open one. The comparison matrix is the raw evidence: which allele targets
each sample showed, and how strongly. Above it sits the haplotype tape, which
collapses that evidence into the finished call, the M-family each locus resolved
to. Off to one side, the cohort summary scans every sample at once and
points you toward the ones that need attention. Selecting a sample or a locus in
one region updates the others, so you move between the raw evidence and the
finished call without leaving the viewport.

The practical takeaway: trust the tape for
routine calls, and reach past it, into the matrix and the call evidence, only
when something looks off. The cohort summary is what tells you where that closer
look is worth spending.

## What you will learn

This chapter works from the finished call back down to the evidence beneath it.
First the matrix and the haplotype tape, which is where a call is stated. Then
the per-sample call evidence, which shows the allele targets and read counts a
call rested on. Along the way you will learn to spot the overcall guard when it
fires, and to step in yourself with a manual override or an annotation.

## Switching lenses

The viewport opens on one of three lenses, chosen from a segmented control at the
top right. Each answers a different question about the same bundle.

- Summary is the dashboard this chapter describes: the matrix, the haplotype
  tape, and the cohort summary.
- Review is a queue that walks the flagged samples one at a time, with the call
  evidence for each within reach.
- Audit lays out the haplotype definitions and the run artifacts the calls rest
  on.

Within Summary, an Outline and Matrix toggle switches how the samples are laid
out. Outline is the default for a run that carries haplotype calls, and Matrix is
the default for a run that produced raw calls but no haplotype analysis. Outline
is the compact per-sample rollup. Matrix is the full allele-target grid this
chapter walks through below.

The Review lens is built for clearing the flagged queue without leaving the
keyboard. Each sample's call-evidence panel carries Confirm and Skip buttons, and
four shortcuts act on the selected sample:

- Cmd-R marks it reviewed.
- Cmd-K marks it confirmed.
- Cmd-Shift-F flags it as needing review.
- Cmd-Shift-O opens the Sample Detail sheet with the override editor.

## The genotype comparison matrix

Everything else builds on the matrix, the raw evidence layer. Each row is an
allele target from the reference library, written with its identifier and source
label such as `0068[MHC-A1]`. Each column is a sample. A filled cell means that sample showed
that allele target, and the cell carries the retained read count behind it.
Reading a column top to bottom tells you every allele target a sample produced.
Reading a row left to right tells you which samples share an allele target.

Cells are colored by the M-family they support, using a fixed palette so the
same family reads the same way everywhere in the report. When an allele target
is shared by more than one family, Lungfish colors it as a resolved family only
when the surrounding primary evidence or a linked locus (a neighbouring locus
that tends to be inherited alongside it) settles which family it belongs to.
Otherwise the cell is marked shared or ambiguous rather than being given a
misleading color. The matrix never modifies the bundle: sorting, filtering, and
selecting are display state only.

## The haplotype tape

The haplotype tape sits above the matrix and shows the finished call. For the
selected sample it lays out the six MHC loci (MHC-A, MHC-E, MHC-B, MHC-DR,
MHC-DQ, and MHC-DP), each with two slots labelled H1 and H2. Each slot holds an
M-family name or a `?` when the slot is unresolved.

<!-- planned: genotype-haplotype-tape -->

Each locus gets two slots because an animal inherits at most two MHC haplotypes,
one from each parent. Expecting H1 to be the family from one parent and H2 the
family from the other is natural, but that is not what they are. The two
slots are report positions, nothing more. Lungfish reorders H1 and H2 freely to
keep the same M-family aligned down a column of loci, because an intact family is
the common case, so a slot carries no parental origin. A `?` is not a failure: it
is an honest statement that the evidence at that slot did not resolve to one
family. Clicking a slot selects that locus and pulls its supporting allele
targets into focus in the matrix and the call-evidence panel.

## The cohort summary

For a multi-sample run, the cohort summary is the triage layer. It tallies the
run rather than any single sample: how many samples fell below the read-support
threshold, how many carry errors, how the quality-control statuses are
distributed, and how many analyst annotations exist. Each tally names its samples
when you hover the count, so you can jump straight to the ones that need work.

<!-- planned: genotype-cohort-summary -->

The summary is where you start on a fresh cohort. A run of forty animals might
have five that need a human, and the summary is how you find those five without
opening all forty.

## Filtering the dashboard

Summary and Review share a filter bar above the content. Its search field is
sample-oriented: it matches animal IDs, haplotype names, comments, genotype
strings, and imported metadata. A `field=value` query such as `Cohort=Kenyon20`
narrows to samples whose metadata field contains that value. Beside the field is
a pill bar of one-click sample predicates: Has errors, Homozygous, Recombinant,
Bw6+, Has comments, and Duplicate. Smart Cohorts save a filter for reuse, and the
built-in "Needs review" cohort is the one the Review lens activates to populate
its queue.

The Matrix view adds its own row filter, a field reading "Filter genotypes, loci,
or samples", which also understands `field=value` metadata queries, alongside an
All Loci popup that restricts the grid to a single locus. Because the Matrix
instantiates only a capped window of sample columns, a wide cohort shows a
"Showing N of M samples" banner with a Show all button. The hidden columns are
display only, so export, sort, and selection still read every sample.

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

When a tape slot reads `?`, click it. The matrix highlights the allele targets
that locus does have, so you can see whether the slot is empty for lack of reads
or unresolved because the evidence is split.

### Step 3. Read per-sample call evidence

The call-evidence panel is where you see the reasoning behind a call. For a
selected sample and locus it lists the observed allele-target IDs, their read
counts, and a short rationale for the call. The rationale is what turns a set of
matches into a defensible family assignment.

<!-- planned: genotype-call-evidence -->

Four rationale categories cover most calls. This is a simplification of a longer
internal set, kept short here because these four are the ones you act on:

- `direct-primary`: a defining allele target for the family is present with
  credible support, so the family is called directly.
- `shared-resolved`: an allele target shared by several families was resolved to
  one family by neighbouring primary or linked-locus evidence.
- `secondary-rescued`: primary allele targets could not settle the locus, so
  additional workbook-mapped targets (targets recorded in the run's workbook, its
  saved table of per-sample evidence) rescued the call under strict support rules.
- `overcall-human-curation`: too many families have credible support, so the
  locus is reported `?/?` and handed to a human.

The overcall guard behind that last category is the workflow's refusal to guess,
and it rests on simple biology. A single animal has two MHC haplotypes, one from
each parent, so at any one locus it can genuinely carry at most two families.
Before ranking any calls, Lungfish checks whether the sample is even consistent
with that. If three or more M-families have credible support at a locus, the
extra families cannot all be real in one animal. Lungfish does not treat a third
or fourth family as a weak extra call to keep. It treats it as a sign that the
sample itself is the problem, and reports the locus as `?/?`.

Picture a hypothetical animal we will call LF2840, showing credible support for
nearly every family, M1 through M7, repeated across many loci. No single macaque
carries seven haplotypes. That pattern fits a mixed or cross-contaminated sample
far better than a rich genotype, so all six loci report `?/?` with the rationale
`overcall-human-curation` naming the excess families, rather than being squeezed
down to the two highest-scoring ones.

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
