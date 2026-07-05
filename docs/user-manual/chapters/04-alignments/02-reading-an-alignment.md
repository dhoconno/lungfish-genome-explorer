---
title: Reading an Alignment
chapter_id: 04-alignments/02-reading-an-alignment
audience: bench-scientist
prereqs: [01-foundations/04-alignment-files, 04-alignments/01-mapping-reads-to-a-reference]
estimated_reading_min: 8
task: Open and navigate the BAM viewport, read coverage, and inspect a pileup.
tags: [alignments, bam, viewport, coverage, pileup]
tools: []
entry_points:
  - "Click an alignment track in the sidebar"
shots: []
planned_shots:
  - id: bam-viewport-overview
    caption: "The BAM viewport showing reads stacked on the reference with a coverage histogram."
  - id: pileup-zoom
    caption: "Zoomed pileup view at a single position showing per-read base calls."
  - id: alignment-inspector
    caption: "The Inspector for an alignment track, with aggregate stats and the Analysis section."
illustrations: []
glossary_refs: [BAM, coverage, pileup, soft-clip, strand, strand-bias, supplementary-alignment, mapq]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A BAM file is a long table of reads with positions on a reference. The
Lungfish alignment viewport renders that table as a picture: the reference
runs left to right along a position ruler at the top, a coverage histogram
sits just below the ruler, and individual reads stack underneath as
horizontal bars at their mapped positions. Reads that overlap pile on top of
one another, which is why a zoomed-in single-base column is called a
**pileup**.

By default, reads are colour-coded by mapping orientation. Forward-strand
reads (the read sequence matches the reference orientation) render in one
shade and reverse-strand reads in another. The coverage histogram is split the
same way: forward-read depth and reverse-read depth stack as two tinted bands,
so you can read the strand balance from the histogram as well as from the
reads. This strand cue is the one most readers reach for first. Strand bias at
a position, where almost all variant bases come from one strand, is a classic
sign that the variant is an artefact rather than a real mutation.

Strand is encoded by colour, so the strand cue alone is not reliable for
colour-blind readers. Two non-colour checks carry the same information:
forward and reverse reads point opposite ways (read direction is a shape cue,
not a hue cue), and the Inspector reports per-strand depth as numbers you can
read without seeing the colours. The viewport can also colour reads by other
channels, covered below.

Soft-clipped read ends are drawn lightened. A **soft-clip** is the part of a
read that the mapper kept in the record but did not align to the reference,
typically because the bases are primer sequence, adapter remnants, or
low-quality tails. Lungfish dims those segments so you can see at a glance
that they exist without mistaking them for matched bases. After primer
trimming (the next chapter), the primer-derived ends become **soft-clipped**:
they stay in the record at their original length and remain faintly visible at
amplicon edges, but pileup and coverage exclude them. The trim never deletes
bases or removes reads. Chapter 03 is the canonical explanation of this
behaviour.

In practice, when you open a BAM viewport, look at the coverage histogram
first to find regions that dropped out, then zoom into suspect positions to
read the pileup. The viewport is a diagnostic tool:
you are looking for things that should not be there.

## What you will learn

Here you will learn to navigate a BAM viewport by position with the keyboard,
read the strand-split coverage histogram to find low-coverage regions,
identify soft-clipped read ends, recognize forward versus reverse strand reads
(and the non-colour cues for them), switch the read colour channel, read
aggregate alignment stats from the Inspector, and launch a downstream
operation from the Inspector's Analysis section.

## Procedure

This procedure assumes you completed the previous chapter and have a
minimap2 alignment of the SRR36291587 reads against the SARS-CoV-2 MN908947
reference attached as a track. If you do not, follow
[Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) first.

1. **Open the alignment track.** In the sidebar, expand the MN908947
   reference bundle's alignment tracks and click the track you mapped in the
   previous chapter (named "minimap2 Mapping" by default, or whatever you
   renamed it to). The main view switches to the BAM viewport and the
   Inspector switches to the alignment track's metadata.
   <!-- planned: bam-viewport-overview -->

2. **Read the coverage histogram.** The histogram above the read stack is
   the count of reads covering each position, drawn as forward-strand and
   reverse-strand bands stacked together. Tall bars mean deep coverage, short
   bars mean thin coverage, and gaps mean a region the reads did not reach.
   Hover any bar to see the exact depth. Without a mouse, jump to the position
   (step 3) and read depth from the status bar and the Inspector instead.

3. **Jump to a position.** Press `Cmd-L` to open the Go to Location prompt,
   type `21618`, and press Return. The viewport recentres on that coordinate.

4. **Zoom in to read individual bases.** Press `Cmd-=` (or `Cmd-+`, or keypad
   `+`) to zoom in and `Cmd--` (or keypad `-`) to zoom out; bare `=` and `-`
   do nothing. **Arrow Up** also zooms in and **Arrow Down** zooms out, which
   is usually the faster reach; the Left and Right arrows pan. These match the
   Zoom In and Zoom Out items in the menu bar. Keep zooming in at position
   21618 until each read is tall enough to show its base calls. At single-base
   resolution the reference base sits on the ruler and the stacked read bases
   sit under it: matches render as a small tick, mismatches render as the
   alternate base letter.
   <!-- planned: pileup-zoom -->

5. **Inspect aggregate stats.** Click the Inspector tab if it is not
   already showing the alignment track. The summary at the top reports
   total reads, mapped reads, mean coverage across the reference, the split
   between primary and supplementary alignments, and the provenance
   sidecar from the mapping step (which mapper, which preset, which input
   FASTQ).
   <!-- planned: alignment-inspector -->

## Interpretation

### What the coverage histogram tells you

Even coverage across the reference is what you want and almost never what
you get. Real amplicon and capture data have characteristic coverage
patterns: amplicon panels show a sawtooth where each amplicon's middle is
deeper than its ends, and shotgun libraries show GC-bias dips in
AT-rich and GC-rich regions. A flat region of zero coverage between two
covered regions is an **amplicon dropout** and means a primer pair failed,
typically because the primer-binding site mutated.

A useful rule of thumb: positions with fewer than about ten reads of
coverage are not reliable for variant calling because a single sequencing
error can dominate the column. The variant caller will flag low-depth
positions, but it helps to know in advance which regions of your reference
are thin so you do not over-interpret a call there.

### What the pileup at position 21618 shows

A healthy fixed-mutation column looks like this: the reference base is one
letter (say `C`), most reads carry the alternate (say `T`), and the alternate
appears on both forward-strand and reverse-strand reads. Both-strand support
and near-100% allele fraction are the signatures of a real fixed mutation
rather than a sequencing artefact. Position 21618 in the SRR36291587 worked
example sits inside the spike gene and will be called as a variant in the
next chapter; navigate there and zoom in to see the pattern for yourself.

Compare that to what an artefact looks like: an alternate base seen on only
one strand, or only at the very ends of reads where soft-clipping took
over, or only on reads with low mapping quality. The viewport gives you
those cues by colour and shading without you having to compute anything.

### What the Inspector summary tells you

The Inspector's aggregate panel is the single most useful sanity check for
a new alignment. The fields you should glance at every time are listed
here.

| Field | What to look for |
|---|---|
| Total reads | Should match the input FASTQ read count, modulo any pre-mapping filtering |
| Mapped reads | Percentage of total that aligned. For on-target amplicon data, expect well above 90%. For shotgun environmental data, much lower is normal. |
| Mean coverage | Average depth across the reference. Compare against your design depth. |
| Primary vs supplementary | Supplementary alignments are split-read evidence (one read mapping in two pieces). A high supplementary fraction can indicate structural variants or chimeric reads. |
| Provenance sidecar | Records the mapper, preset, and input FASTQ. This is your audit trail and the reason you can reproduce the analysis later. |

### Launching downstream work from the Inspector

The Inspector's Analysis section is the launch point for every
alignment-driven operation, not just the two you need next. The full set of
buttons is: **Primer-trim BAM…** (soft-clips primer bases, chapter 03),
**Call Variants…** (runs a variant caller, chapter 5), **Mark Duplicates in
Bundle Tracks** and **Create Deduplicated Bundle** (duplicate handling,
[Alignment Quality](04-alignment-quality.md)), **Create Filtered Alignment**
(derive a QC-subset track, also chapter 04), **Convert Mapped Reads to
Annotations**, and **Extract Consensus…**. Knowing the section holds all of
these means you do not go hunting in the menu bar for an alignment operation.

The two most relevant at this stage are the first two. **Primer-trim BAM**
removes primer-derived bases from amplicon reads using a primer scheme.
**Call Variants** runs a variant caller (iVar by default for amplicon
SARS-CoV-2 data, bcftools for general short-read data) and produces a VCF
track on the same reference.

Launching from the Inspector pre-fills the dialog with this BAM as input,
which saves you from re-selecting it. The provenance sidecar carries
forward, so the resulting VCF or trimmed BAM records the full chain of
inputs back to the original FASTQ.

### Strand colour, soft-clipping, and what they mean together

The viewport uses two visual channels you can read together:

- **Strand colour** distinguishes forward from reverse reads. A pileup
  column that is all-one-colour is a strand-bias warning. A column that is
  evenly mixed is the healthy case. Read direction and the per-strand depth
  in the Inspector carry the same signal without relying on hue.
- **Soft-clip lightening** distinguishes aligned bases from unaligned read
  ends. If a column near the start or end of an amplicon shows mostly
  lightened bases, those are primer-derived and should not be used for
  variant calling. Trimming, in the next chapter, fixes that.

Reading both at once is the bench-scientist version of the QC summaries
that analyst tools produce as numbers. The picture is faster to scan and
harder to misinterpret.

### Colour channels beyond strand

Strand is the default, but it is not the only thing the viewport can colour by.
For paired-end shotgun data the other channels are how you spot structural
problems at a glance:

- **By pair** tints first-of-pair and second-of-pair reads differently.
- **By insert size** flags pairs whose mates map too close, too far, on the
  wrong chromosome, or in the wrong orientation, in the IGV convention. This
  is the fastest way to spot a deletion, insertion, or inversion.
- **By split read** highlights reads whose two halves map to separate places,
  the signature of a chimera or a structural breakpoint.
- **By read group** tints each read group separately, so a multi-library BAM
  shows which library contributed which reads.

A reader chasing a structural variant typically switches from strand to insert
size; a reader auditing a merged BAM switches to read group.

## Next

Continue to [Primer Trimming](03-primer-trimming.md) for amplicon
workflows, or skip to [Alignment Quality](04-alignment-quality.md) for QC
checks before variant calling.
