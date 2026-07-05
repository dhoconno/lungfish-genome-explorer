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

A BAM file is a long table: one row per read, each tagged with where it landed
on a reference. The Lungfish alignment viewport turns that table into a
picture. The reference runs left to right along a position ruler at the top, a
coverage histogram sits just below it, and the reads stack underneath as
horizontal bars at their mapped positions. Where reads overlap they pile on top
of one another, which is why a zoomed-in single-base column is called a
**pileup**.

By default, reads are coloured by mapping orientation. Forward-strand reads,
whose sequence matches the reference orientation, take one shade; reverse-strand
reads take another. The coverage histogram splits the same way, stacking
forward-read depth and reverse-read depth as two tinted bands, so the strand
balance reads off the histogram as clearly as off the reads themselves. This is
the cue most readers reach for first. Strand bias at a position, where nearly
all the variant bases come from one direction, is a classic sign that a variant
is an artefact and not a real mutation.

Because strand is carried by colour, the cue alone is not reliable for
colour-blind readers. Two non-colour checks carry the same signal. Forward and
reverse reads point opposite ways, so direction is a shape cue rather than a
hue cue, and the Inspector reports per-strand depth as plain numbers you can
read without seeing the colours. The viewport can also colour reads by other
channels, covered below.

Soft-clipped read ends are drawn lightened. A **soft-clip** is the stretch of a
read the mapper kept in the record but never aligned to the reference, usually
because those bases are primer sequence, adapter remnants, or a low-quality
tail. Lungfish dims those segments so you can spot them at a glance and not
mistake them for matched bases. After primer trimming (the next chapter), the
primer-derived ends become **soft-clipped** too: they stay in the record at
full length and linger faintly at amplicon edges, but pileup and coverage leave
them out. The trim never deletes a base or drops a read. Chapter 03 is the
canonical account of this behaviour.

In practice, when you open a BAM viewport, read the coverage histogram first to
find the regions that dropped out, then zoom into the suspect positions to read
the pileup. The viewport is a diagnostic tool: you are hunting for things that
should not be there.

## What you will learn

Here you will learn to steer a BAM viewport by position from the keyboard, read
the strand-split coverage histogram to find low-coverage regions, pick out
soft-clipped read ends, tell forward reads from reverse ones (and use the
non-colour cues for both), switch the read colour channel, read the aggregate
alignment stats in the Inspector, and launch a downstream operation from the
Inspector's Analysis section.

## Procedure

This procedure assumes you finished the previous chapter and have a minimap2
alignment of the SRR36291587 reads against the SARS-CoV-2 MN908947 reference
attached as a track. If you do not, work through
[Mapping Reads to a Reference](01-mapping-reads-to-a-reference.md) first.

1. **Open the alignment track.** In the sidebar, expand the MN908947
   reference bundle's alignment tracks and click the one you mapped in the
   previous chapter (named "minimap2 Mapping" by default, or whatever you
   renamed it to). The main view switches to the BAM viewport, and the
   Inspector switches to the track's metadata.
   <!-- planned: bam-viewport-overview -->

2. **Read the coverage histogram.** The histogram above the read stack counts
   the reads covering each position, drawn as forward-strand and reverse-strand
   bands stacked together. Tall bars mean deep coverage, short bars thin
   coverage, gaps a region the reads never reached. Hover any bar for the exact
   depth. Without a mouse, jump to the position (step 3) and read depth from
   the status bar and the Inspector instead.

3. **Jump to a position.** Press `Cmd-L` to open the Go to Location prompt,
   type `21618`, and press Return. The viewport recentres on that coordinate.

4. **Zoom in to read individual bases.** Press `Cmd-=` (or `Cmd-+`, or keypad
   `+`) to zoom in and `Cmd--` (or keypad `-`) to zoom out; bare `=` and `-`
   do nothing. **Arrow Up** also zooms in and **Arrow Down** zooms out, usually
   the faster reach, while the Left and Right arrows pan. These match the Zoom
   In and Zoom Out items in the menu bar. Keep zooming in at position 21618
   until each read is tall enough to show its base calls. At single-base
   resolution the reference base sits on the ruler and the stacked read bases
   sit beneath it: a match renders as a small tick, a mismatch as the alternate
   base letter.
   <!-- planned: pileup-zoom -->

5. **Inspect aggregate stats.** Click the Inspector tab if it is not already
   on the alignment track. The summary at the top reports total reads, mapped
   reads, mean coverage across the reference, the split between primary and
   supplementary alignments, and the provenance sidecar from the mapping step:
   which mapper, which preset, which input FASTQ.
   <!-- planned: alignment-inspector -->

## Interpretation

### What the coverage histogram tells you

Even coverage across the reference is what you want and almost never what you
get. Real amplicon and capture data carry their own signatures: amplicon panels
show a sawtooth, each amplicon deeper in the middle than at its ends, and
shotgun libraries dip in AT-rich and GC-rich stretches from GC bias. A flat
band of zero coverage between two covered regions is an **amplicon dropout**,
and it means a primer pair failed, usually because its binding site mutated.

A useful rule of thumb: positions with fewer than about ten reads are not
reliable for variant calling, because a single sequencing error can dominate
the column. The variant caller will flag low-depth positions on its own, but
knowing in advance which regions of your reference run thin keeps you from
over-reading a call there.

### What the pileup at position 21618 shows

A healthy fixed-mutation column looks like this: the reference base is one
letter, say `C`, most reads carry the alternate, say `T`, and that alternate
shows up on forward-strand and reverse-strand reads alike. Support from both
strands and a near-100% allele fraction are the signatures of a real fixed
mutation rather than a sequencing artefact. Position 21618 in the SRR36291587
worked example sits inside the spike gene and gets called as a variant in the
next chapter; navigate there, zoom in, and read the pattern for yourself.

Set that against an artefact: an alternate base seen on one strand only, or
only at the very ends of reads where soft-clipping took over, or only on reads
with low mapping quality. The viewport hands you those cues in colour and
shading, with nothing to compute.

### What the Inspector summary tells you

The Inspector's aggregate panel is the single most useful sanity check for a
new alignment. Glance at these fields every time.

| Field | What to look for |
|---|---|
| Total reads | Should match the input FASTQ read count, modulo any pre-mapping filtering |
| Mapped reads | Percentage of total that aligned. For on-target amplicon data, expect well above 90%. For shotgun environmental data, much lower is normal. |
| Mean coverage | Average depth across the reference. Compare against your design depth. |
| Primary vs supplementary | Supplementary alignments are split-read evidence (one read mapping in two pieces). A high supplementary fraction can indicate structural variants or chimeric reads. |
| Provenance sidecar | Records the mapper, preset, and input FASTQ. This is your audit trail and the reason you can reproduce the analysis later. |

### Launching downstream work from the Inspector

The Inspector's Analysis section is the launch point for every
alignment-driven operation, not only the two you need next. The full set of
buttons: **Primer-trim BAM…** (soft-clips primer bases, chapter 03),
**Call Variants…** (runs a variant caller, chapter 5), **Mark Duplicates in
Bundle Tracks** and **Create Deduplicated Bundle** (duplicate handling,
[Alignment Quality](04-alignment-quality.md)), **Create Filtered Alignment**
(derive a QC-subset track, also chapter 04), **Convert Mapped Reads to
Annotations**, and **Extract Consensus…**. Once you know the section holds all
of them, you stop hunting the menu bar for an alignment operation.

The first two matter most right now. **Primer-trim BAM** clears primer-derived
bases from amplicon reads using a primer scheme. **Call Variants** runs a
variant caller (iVar by default for amplicon SARS-CoV-2 data, bcftools for
general short-read data) and produces a VCF track on the same reference.

Launch from the Inspector and the dialog opens with this BAM already set as
input, sparing you the re-selection. The provenance sidecar rides along, so the
resulting VCF or trimmed BAM records the full chain of inputs back to the
original FASTQ.

### Strand colour, soft-clipping, and what they mean together

The viewport uses two visual channels you can read together:

- **Strand colour** separates forward reads from reverse. A pileup column
  that is all one colour is a strand-bias warning; an evenly mixed one is the
  healthy case. Read direction and the per-strand depth in the Inspector carry
  the same signal without leaning on hue.
- **Soft-clip lightening** separates aligned bases from unaligned read ends.
  When a column near the start or end of an amplicon is mostly lightened, those
  bases are primer-derived and have no business in a variant call. Trimming, in
  the next chapter, fixes that.

Reading both at once is the bench-scientist counterpart to the numeric QC
summaries analyst tools spit out. The picture scans faster and misleads less
often.

### Colour channels beyond strand

Strand is the default, not the only option. For paired-end shotgun data, the
other channels are how you catch structural problems at a glance:

- **By pair** tints first-of-pair and second-of-pair reads differently.
- **By insert size** flags pairs whose mates map too close, too far, onto the
  wrong chromosome, or in the wrong orientation, in the IGV convention. It is
  the fastest way to spot a deletion, insertion, or inversion.
- **By split read** highlights reads whose two halves land in separate places,
  the signature of a chimera or a structural breakpoint.
- **By read group** tints each read group on its own, so a multi-library BAM
  shows which library contributed which reads.

A reader chasing a structural variant usually switches from strand to insert
size; a reader auditing a merged BAM switches to read group.

## Next

Continue to [Primer Trimming](03-primer-trimming.md) for amplicon
workflows, or skip to [Alignment Quality](04-alignment-quality.md) for QC
checks before variant calling.
