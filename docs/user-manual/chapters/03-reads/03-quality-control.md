---
title: Quality Control for Reads
chapter_id: 03-reads/03-quality-control
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 8
task: Run a fastp QC summary on a FASTQ bundle and read the resulting charts.
tags: [reads, qc, fastp, quality, phred]
tools: [fastp]
entry_points:
  - "Tools > FASTQ/FASTA Operations > QC & Reporting > Refresh QC Summary"
  - "FASTQ viewport > QC tab"
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

Quality control is the step where you decide whether a FASTQ bundle is fit
to analyse. Bad reads produce bad alignments, and bad alignments produce
bad variant calls. The cost of catching a problem now is a few minutes of
inspection; the cost of catching it later is a re-run of every downstream
step and, sometimes, a retracted result. QC pays for itself the first time
it stops you from chasing an artefact.

Lungfish runs `fastp` to compute a per-bundle QC summary. The summary
includes per-base quality (Phred scores across the read length), the read
length distribution, GC content, and adapter contamination indicators.
The operation lives at `Tools > FASTQ/FASTA Operations > QC & Reporting >
Refresh QC Summary`. The result lands in the FASTQ viewport's QC tab as a
set of charts and a structured report.

Reading the charts is mostly pattern recognition. A clean Illumina run
holds Phred scores above Q30 across most of the read length and dips at
the 3' end. A clean run shows a tight length distribution at the expected
read length, often 150 bp for paired-end Illumina. A clean run shows GC
content matching the source organism. Departures from these patterns
suggest adapter contamination, a tired flow cell, or a sample mix-up.
**So what should you do with this?** Run `Refresh QC Summary` on every
new bundle before you align it.

## What you will learn

By the end of this chapter you will be able to run a QC summary on a
FASTQ bundle, read the per-base quality chart and identify low-quality
regions, read the length distribution and identify truncated reads, read
the GC content and identify contamination, and decide whether a bundle is
clean enough to proceed or needs trimming.

## Procedure

1. Select the FASTQ bundle in the project sidebar under `Imports/` or
   `Downloads/`.
2. From the menu bar choose `Tools > FASTQ/FASTA Operations > QC &
   Reporting > Refresh QC Summary`. The Operations Panel shows a new
   `fastp` row that progresses through `running` to `complete` in a few
   seconds for a typical 100 MB bundle.
3. With the same bundle still selected, click the `QC` tab at the top of
   the FASTQ viewport. <!-- planned: fastq-qc-charts -->
4. Read the four panels in this order: per-base quality, length
   distribution, GC content, adapter contamination. Each panel has a
   one-line headline summary above the chart.
5. If any panel reports a flag (Warning or Fail), make a note of it and
   continue to the Interpretation section below before deciding what to
   do.

## Interpretation

The QC tab does not block downstream operations. It informs them. A
bundle with warnings can still be aligned, but the warnings tell you
which artefacts to expect, and which downstream operation will fix them.

### Phred quality thresholds

Phred scores express the probability that a base call is wrong on a
logarithmic scale. A higher score is a more confident base. Three
thresholds matter in practice:

| Threshold | Error rate | Meaning |
|---|---|---|
| Q20 | 1 in 100 | Trim border. Bases below this are usually trimmed by quality. |
| Q30 | 1 in 1000 | Standard. Most Illumina bases on a healthy run sit at or above Q30. |
| Q40 | 1 in 10000 | Excellent. Common on the first 50 bp of a fresh Illumina run; rare beyond read 100. |

A run whose median per-base quality stays above Q30 for the full read
length is healthy. A run that crosses below Q20 before the end of the
read is one that benefits from quality trimming, covered in
[Trimming and Filtering](04-trimming-and-filtering.md).

### What good QC looks like

For a SARS-CoV-2 amplicon library sequenced on a 2x150 bp Illumina MiSeq
or NextSeq run, the QC charts on a healthy bundle show a recognisable
shape. The per-base quality chart sits above Q30 from base 1 through
roughly base 140, then dips toward Q25 at the 3' end of the read. The
length distribution is a single sharp spike at 150 bp on each of read 1
and read 2, with at most a small shoulder of shorter reads from
adapter-read-through. GC content sits at 38 percent, plus or minus 2
percent, matching the SARS-CoV-2 genome. Adapter contamination sits below
1 percent.

A useful rule of thumb: if the bundle's median Phred is at least Q30, the
length spike is at the expected read length, and the GC content is within
3 percent of the source organism's known value, the bundle is ready for
read mapping.

### What bad QC looks like

Three failure modes account for most of the bundles you will see flagged.
Each has a recognisable signature and a known fix.

**Low quality across the read.** The per-base quality chart drops below
Q20 well before the end of the read, sometimes as early as base 60. This
typically means the flow cell was overloaded, the run was extended past
its rated cycle count, or the reagents were near expiry. The fix is
quality trimming: in Lungfish, run `Tools > FASTQ/FASTA Operations >
Trim & Filter` with a minimum quality of Q20 and a sliding window. After
trimming, re-run `Refresh QC Summary` and confirm the chart sits above
Q20 across the retained read length. Trimming is covered in
[Trimming and Filtering](04-trimming-and-filtering.md).

**Length truncation.** The length distribution chart shows a long tail of
short reads instead of (or in addition to) a tight spike at 150 bp. This
is the signature of adapter read-through: the insert was shorter than the
read length, so sequencing ran off the end of the insert and into the
adapter. The fix is adapter trimming, also handled by `Trim & Filter`.
After trimming, the length distribution spreads slightly to the left of
150 bp, which is expected and harmless.

**GC content departure.** The GC content chart is centred at a value far
from the source organism's known GC. For SARS-CoV-2 (38 percent), a peak
at 50 percent suggests human read contamination, and a bimodal
distribution with peaks at both 38 and 50 percent suggests a host plus
target mixture. The fix depends on intent: for a clinical isolate workflow,
host depletion or competitive mapping against a host reference removes
the contaminant; for a metagenomic workflow, the contamination is the
signal and you continue to classification.

### Worked example: SRR36291587

The SRR36291587 fixture, a SARS-CoV-2 amplicon run from the SRA, is a
useful reference point because its QC summary shows the clean shape
described above. Per-base quality stays above Q30 through base 140 on
read 1 and base 135 on read 2, with the read 2 dip slightly earlier and
slightly deeper, which is normal for paired-end Illumina. The length
distribution is a single spike at 150 bp on each read. GC content is
38.1 percent on read 1 and 38.0 percent on read 2. Adapter content is
0.4 percent on read 1 and 0.6 percent on read 2.

If you run `Refresh QC Summary` on this fixture and your numbers differ
by more than a percentage point or two, the deviation is informative.
A higher adapter percentage on a freshly downloaded copy probably means
the SRA uploaded the un-trimmed FASTQ; a lower Q30 fraction probably
means the bundle was re-basecalled with a stricter caller. Both are
benign. A GC shift of more than 5 percent on this fixture is not benign
and is worth investigating before continuing.

### Deciding to proceed

A bundle is clean enough to proceed if the per-base quality is at or
above Q30 across most of the retained read length, the length
distribution is at or near the expected length, the GC content matches
the source organism within a few percent, and adapter contamination is
below a few percent. A bundle that fails on any of these axes goes
through `Trim & Filter` first, then through QC again to confirm the fix
took. Only then do you align.

## Next

Continue to [Trimming and Filtering](04-trimming-and-filtering.md) to
clean up reads that fail QC before mapping them to a reference.
