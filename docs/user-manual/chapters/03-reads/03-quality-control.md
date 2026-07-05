---
title: Quality Control for Reads
chapter_id: 03-reads/03-quality-control
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 8
task: Run a QC summary on a FASTQ bundle and read the resulting charts.
tags: [reads, qc, quality, phred]
tools: []
entry_points:
  - "Tools > FASTQ/FASTA Operations > QC & Reporting… (then Refresh QC Summary)"
  - "FASTQ viewport > QC tab"
  - "CLI: lungfish fastq qc-summary"
shots: []
planned_shots:
  - id: fastq-qc-charts
    caption: "The FASTQ viewport showing per-base quality, length distribution, and GC content charts."
illustrations: []
glossary_refs: [Phred-score, FASTQ, read-length]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter is about inspecting read quality. To act on what QC shows you, whether trimming, adapter and primer removal, or length filtering, see [Trimming and Filtering](04-trimming-and-filtering.md).

Quality control is where you decide whether a FASTQ bundle is fit
to analyse. Bad reads breed bad alignments, and bad alignments breed
bad variant calls. Catch the problem now and it costs a few minutes of
inspection. Catch it later and it costs a re-run of every downstream
step, and sometimes a retracted result. QC pays for itself the first time
it stops you chasing an artefact.

Lungfish computes a per-bundle QC summary by scanning the reads directly,
with no external tool required. The summary covers per-base quality across the
read length, reported as Phred scores, the standard log scale for base-call
confidence, plus the read-length distribution, GC content, and adapter
contamination indicators. To run it, choose `Tools > FASTQ/FASTA Operations >
QC & Reporting…`, then pick `Refresh QC Summary` from the operations list in the
dialog that opens. The result lands in the FASTQ viewport's QC tab as a set
of charts and a structured report.

Reading the charts is mostly pattern recognition. A clean Illumina run
holds Phred scores above Q30 across most of the read length and dips at
the 3' end. Its length distribution is a tight cluster at the expected
read length, often 150 bp for paired-end Illumina. Its GC content matches the
source organism. Stray from these patterns and the likely culprits are
adapter contamination, a tired flow cell, the consumable chip that
holds the sequencing lanes, or a sample mix-up. Run `Refresh QC Summary` on
every new bundle, and read it before you spend compute on aligning it.

## What you will learn

Once you have read this chapter, you can run a QC summary on a
FASTQ bundle, read the per-base quality chart and spot low-quality
regions, read the length distribution and spot truncated reads, read
the GC content and spot contamination, and judge whether a bundle is
clean enough to proceed or needs trimming.

## Procedure

1. Select the FASTQ bundle in the project sidebar under `Imports/` or
   `Downloads/`.
2. From the menu bar choose `Tools > FASTQ/FASTA Operations > QC &
   Reporting…`. A dialog opens with the QC & Reporting operations listed
   inside it.
3. Select `Refresh QC Summary` in the dialog and click `Run`. The Operations
   Panel shows a new row that moves from `running` to `complete` in a
   few seconds for a typical 100 MB bundle.
4. With the same bundle still selected, click the `QC` tab at the top of
   the FASTQ viewport. <!-- planned: fastq-qc-charts -->
5. Read the panels in this order: per-base quality, length distribution, GC
   content, adapter contamination. When a panel raises a flag, note it and
   read the Interpretation section below before you decide what to do.

To get the same summary as a standalone JSON file, for a pipeline log or
an external dashboard, run `lungfish fastq qc-summary <reads.fastq> -o
qc.json`. It takes several inputs at once and writes one report.

## Interpretation

The QC tab does not block downstream operations. It informs them. A
bundle with warnings can still be aligned; the warnings simply tell you
which artefacts to expect, and which downstream operation will clear them.

### Phred quality thresholds

Phred scores put the probability that a base call is wrong on a
logarithmic scale. The higher the score, the more confident the base. Three
thresholds matter in practice:

| Threshold | Error rate | Meaning |
|---|---|---|
| Q20 | 1 in 100 | Trim border. Bases below this are usually trimmed by quality. |
| Q30 | 1 in 1000 | Standard. Most Illumina bases on a healthy run sit at or above Q30. |
| Q40 | 1 in 10000 | Excellent. Common on the first 50 bp of a fresh Illumina run; rare beyond read 100. |

A run whose median per-base quality holds above Q30 for the full read
length is healthy. A run that slips below Q20 before the read ends is one
that gains from quality trimming, covered in
[Trimming and Filtering](04-trimming-and-filtering.md).

### What good QC looks like

For a SARS-CoV-2 amplicon library sequenced on a 2x150 bp Illumina MiSeq
or NextSeq run, a healthy bundle's QC charts take a recognisable
shape. The per-base quality chart sits above Q30 from base 1 through
roughly base 140, then dips toward Q25 at the 3' end. The
length distribution is a single sharp spike at 150 bp on each of read 1
and read 2, with at most a small shoulder of shorter reads from adapter
read-through, where the insert was shorter than the read, so sequencing ran
off the end of the fragment and into the adapter. GC content sits at 38
percent, give or take 2, matching the SARS-CoV-2 genome. Adapter
contamination stays below 1 percent.

A useful rule of thumb: when the bundle's median Phred is at least Q30, the
length spike sits at the expected read length, and the GC content lands within
3 percent of the source organism's known value, the bundle is ready for
read mapping.

### What bad QC looks like

Three failure modes account for most of the flagged bundles you will meet.
Each carries a recognisable signature and a known fix.

**Low quality across the read.** The per-base quality chart drops below
Q20 well before the read ends, sometimes as early as base 60. Usually this
means the flow cell was overloaded, the run ran past
its rated cycle count, or the reagents were near expiry. The fix is
quality trimming: choose `Tools > FASTQ/FASTA Operations >
Trimming & Filtering…` and run a quality trim with a Q20 floor and a sliding
window. Then re-run `Refresh QC Summary` and confirm the chart
sits above Q20 across the retained read length. Trimming is covered in
[Trimming and Filtering](04-trimming-and-filtering.md).

**Length truncation.** The length distribution shows a long tail of
short reads instead of a tight spike at 150 bp, or alongside one. That
is the signature of adapter read-through. The fix is adapter trimming, also
handled from `Trimming & Filtering…`. After trimming, the distribution
spreads a little to the left of 150 bp, which is expected and
harmless.

**GC content departure.** The GC content chart centres on a value far
from the source organism's known GC. For SARS-CoV-2, whose GC is 38 percent,
a peak at 50 percent points to human read contamination, and a bimodal
distribution with peaks at both 38 and 50 percent points to a host-plus-target
mixture. The fix follows your intent: in a clinical isolate workflow,
host depletion or competitive mapping against a host reference strips
the contaminant; in a metagenomic workflow, the contamination is the
signal, and you carry on to classification.

### Worked example: SRR36291587

The SRR36291587 fixture, a SARS-CoV-2 amplicon run from the SRA, makes a
handy reference point, because its QC summary shows exactly the clean shape
described above. Per-base quality holds above Q30 through base 140 on
read 1 and base 135 on read 2, the read 2 dip landing a little earlier and
a little deeper, as is normal for paired-end Illumina. The length
distribution is a single spike at 150 bp on each read. GC content is
38.1 percent on read 1 and 38.0 percent on read 2. Adapter content is
0.4 percent on read 1 and 0.6 percent on read 2.

Run `Refresh QC Summary` on this fixture, and if your numbers stray
by more than a percentage point or two, the gap itself is informative.
A higher adapter percentage on a freshly downloaded copy probably means
the SRA served the un-trimmed FASTQ; a lower Q30 fraction probably
means the bundle was re-basecalled with a stricter caller. Both are
benign. A GC shift of more than 5 percent on this fixture is not, and
is worth chasing down before you continue.

### Deciding to proceed

A bundle is clean enough to proceed when the per-base quality holds at or
above Q30 across most of the retained read length, the length
distribution sits at or near the expected length, the GC content matches
the source organism within a few percent, and adapter contamination stays
below a few percent. A bundle that fails on any of these axes goes
through `Trimming & Filtering…` first, then back through QC to confirm the
fix took. Only then do you align.

## Next

Continue to [Trimming and Filtering](04-trimming-and-filtering.md) to
clean up reads that fail QC before you map them to a reference.
