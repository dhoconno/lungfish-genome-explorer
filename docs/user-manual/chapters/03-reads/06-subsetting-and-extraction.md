---
title: Subsetting and Extraction
chapter_id: 03-reads/06-subsetting-and-extraction
audience: bench-scientist
prereqs: [03-reads/01-importing-fastq]
estimated_reading_min: 6
task: Subsample reads, extract reads by ID or motif, and make virtual subset bundles.
tags: [reads, subsample, extract, motif, virtual-bundle]
tools: [seqkit, fastp]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Search & Subsetting > Subsample by Proportion"
  - "Tools > FASTQ/FASTA Operations > Search & Subsetting > Subsample by Count"
  - "Tools > FASTQ/FASTA Operations > Search & Subsetting > Extract Reads by ID"
  - "Tools > FASTQ/FASTA Operations > Search & Subsetting > Extract Reads by Motif"
  - "CLI: lungfish fastq"
shots: []
planned_shots: []
illustrations: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Subsetting takes a subset of reads from a bundle. There are four reasons a
bench scientist usually reaches for it: testing a pipeline quickly on a
manageable slice of a large run, balancing two samples to the same depth
before a side-by-side comparison, pulling out the specific reads that
already came back hit by a classifier or aligner, and asking whether any
reads contain a particular sequence motif (a primer, a known variant, a
probe target).

Lungfish exposes four operations for this, all under
**Tools > FASTQ/FASTA Operations > Search & Subsetting**. Two are random
samplers (by proportion or by count), and two are targeted extractors (by a
list of read IDs or by a sequence motif). Each operation produces a new
FASTQ bundle in the sidebar; the parent bundle is never modified.

| Operation | Input | Output | Use it when |
|---|---|---|---|
| Subsample by Proportion | Fraction (for example, 0.1) | Random 10% of reads | You want a fast test slice that stays proportional to the original. |
| Subsample by Count | Integer (for example, 100000) | Exactly N reads | You want to normalize two samples to the same depth. |
| Extract Reads by ID | A text file of read names | Only the listed reads | You have a hit list from a classifier, mapper, or BLAST. |
| Extract Reads by Motif | A short sequence (and mismatch budget) | Reads containing the motif | You want to verify a primer is present, or pull reads that overlap a hotspot. |

Subset bundles are virtual by default. Only a small preview FASTQ of about
1000 reads lives on disk. The full FASTQ is reconstructed on demand the
first time a downstream operation needs it. This is a deliberate tradeoff:
many test slices of the same parent bundle stay cheap on disk, and the
preview is enough for QC charts and the FASTQ viewport. So what should you
do with this? Reach for subsample-by-count when you want apples-to-apples
depth, subsample-by-proportion when you want a quick test run, and the two
extractors when you have a specific list or motif in hand.

## Procedure

The four operations share one wizard layout: pick the source bundle, set
the parameter, name the output, and click **Run**. The differences are in
the parameter field.

### Subsample by Count

1. Select a FASTQ bundle in the sidebar (paired-end is supported; pairs stay paired).
2. Choose **Tools > FASTQ/FASTA Operations > Search & Subsetting > Subsample by Count**.
3. Enter a target read count (for example, `10000`).
4. Optionally set a random seed if you need a reproducible draw across runs.
5. Click **Run**. The new bundle appears under `Imports/` with a name like `<parent>-sub10k`.

### Subsample by Proportion

1. Select the source bundle.
2. Choose **Subsample by Proportion**.
3. Enter a fraction between 0 and 1 (for example, `0.1` for 10%).
4. Click **Run**.

### Extract Reads by ID

1. Prepare a plain-text file with one read ID per line. The IDs must match
   the FASTQ header up to the first whitespace (no `@` prefix, no `/1` or
   `/2` suffix).
2. Choose **Extract Reads by ID** and pick the source bundle.
3. Drop the ID list into the file picker.
4. Click **Run**. For paired data, both mates of any matched ID are kept.

### Extract Reads by Motif

1. Choose **Extract Reads by Motif** and pick the source bundle.
2. Enter the motif as a DNA string (for example, a primer sequence).
3. Set the mismatch budget (0 for exact match, 1 or 2 for a tolerant match).
4. Choose whether to search both strands (default) or only the forward strand.
5. Click **Run**.

The CLI mirror is `lungfish fastq subsample`, `lungfish fastq extract-ids`,
and `lungfish fastq extract-motif`; the same parameters apply.

## Interpretation

Every subset operation logs to the Operations Panel and writes a provenance
sidecar inside the new bundle, so the seed, the parameter, and the input
checksum are recoverable later. The new bundle's QC charts (read length,
per-base quality, GC) reflect the subset, not the parent.

A virtual bundle shows a small badge in the sidebar and reports the full
read count in its Inspector even though only the preview is on disk. If you
right-click and choose **Reveal in Finder**, the bundle folder will contain
`preview.fastq` rather than the full file. This is normal. The first time
you run any downstream pipeline (mapping, classification, assembly) on a
virtual bundle, Lungfish materializes the full FASTQ as the first step,
runs the workflow, and cleans up the temporary file when the workflow ends.
You do not need to trigger materialization manually.

A motif extraction returns zero reads more often than people expect. Two
common causes: the motif was searched only on the forward strand when the
library is unstranded, and the mismatch budget was too tight for typical
sequencing error. Re-run with both strands and one mismatch before
concluding a motif is absent.

### Worked example: normalize two samples to equal depth

Suppose you have two FASTQ bundles for a comparison study: `SampleA` with
about 1,000,000 reads and `SampleB` with about 100,000 reads. A direct
comparison of classifier hit counts or coverage between them would be
biased by depth. To put them on equal footing:

1. Select `SampleA` and run **Subsample by Count** with a target of
   `100000` and a fixed seed (for example, `42`).
2. Leave `SampleB` as is.
3. Run the downstream comparison (classification, mapping, or whatever the
   study calls for) on the new `SampleA-sub100k` bundle and on `SampleB`.
4. Record the seed in your methods so the draw is reproducible.

Subsample-by-count uses reservoir sampling, so the result is exactly
100,000 reads (or fewer, if the input has fewer). Subsample-by-proportion
would have produced a draw with size proportional to the input, which is
not what you want for normalization.

### Worked example: a quick test slice of an SRA run

You have just downloaded `SRR36291587` and want to dry-run an assembly
pipeline before committing to the full run. Select the bundle, choose
**Subsample by Count**, enter `10000`, and click **Run**. Use the resulting
virtual subset as the input to the assembly pipeline. The materialization
step reconstructs the 10,000-read FASTQ at the start of the run; the
assembly itself finishes in a fraction of the wall time of the full job.
If the dry run looks right, re-run the assembly against the full bundle.

### Worked example: verify primer presence

You suspect a sample was prepared with the ARTIC v3 scheme but you want to
confirm before running primer trim. Pick a high-yield primer sequence from
the scheme (for example, a left primer near the start of ORF1ab), choose
**Extract Reads by Motif**, paste the sequence, set mismatches to 1, and
search both strands. If a meaningful fraction of reads come back (anything
above background), the primer is present. Repeat for a second primer if
you want stronger evidence. Motif extraction is also useful for pulling
reads near a known variant hotspot before assembly, when you want to spot
check whether the region was sequenced at all.

## What you will learn

By the end of this chapter you will be able to subsample a bundle to a
fixed read count for fast pipeline testing, normalize two samples to a
common depth, extract reads matching a list of IDs (useful for chasing
specific reads through a workflow), extract reads containing a specific
sequence motif, and recognize that a virtual subset bundle does not have
its full FASTQ on disk until a downstream operation forces materialization.

## Next

Continue to [Oxford Nanopore Runs](07-ont-runs.md) for ONT-specific import
workflows, or jump to
[Mapping](../04-alignments/01-mapping-reads-to-a-reference.md) to map your
subset to a reference.
