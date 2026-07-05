---
title: Subsetting and Extraction
chapter_id: 03-reads/06-subsetting-and-extraction
audience: bench-scientist
prereqs: [03-reads/01-importing-fastq]
estimated_reading_min: 6
task: Subsample reads, extract reads by header or motif, select reads by sequence, and make virtual subset bundles.
tags: [reads, subsample, extract, motif, sequence-filter, virtual-bundle]
tools: [seqkit, bbduk]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Search & Subsetting… (then pick the operation)"
  - "CLI: lungfish fastq subsample, search-text, search-motif, sequence-filter"
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

This chapter covers taking a subset of reads from a bundle. For cleaning reads before analysis see [Trimming and Filtering](04-trimming-and-filtering.md) and [Decontamination](05-decontamination.md).

Subsetting takes a subset of reads from a bundle. There are several reasons a
bench scientist usually reaches for it: testing a pipeline quickly on a
manageable slice of a large run, balancing two samples to the same depth
before a side-by-side comparison, pulling out the specific reads whose header
matched a classifier or aligner hit, asking whether any reads contain a
particular sequence motif (a primer, a known variant, a probe target), and
keeping or discarding reads that carry an adapter or barcode sequence at a
read end.

Lungfish exposes five operations for this. Choose
`Tools > FASTQ/FASTA Operations > Search & Subsetting…` and pick the
operation from the list inside the dialog. Two are random samplers (by
proportion or by count), two are targeted extractors (by read header text or
by a sequence motif), and one is a sequence-presence filter (Select Reads by
Sequence). Each produces a new FASTQ bundle in the sidebar; the parent bundle
is never modified.

| Operation | Input | Output | Use it when |
|---|---|---|---|
| Subsample by Proportion | Fraction (for example, 0.1) | Roughly that fraction of reads | You want a fast test slice that stays proportional to the original. |
| Subsample by Count | Integer (for example, 100000) | About N reads | You want to normalize two samples to a similar depth. |
| Extract Reads by ID | A query string matched against the header | Reads whose header matches | You have a header substring or pattern from a classifier, mapper, or BLAST. |
| Extract Reads by Motif | A sequence pattern | Reads containing the motif | You want to verify a primer is present, or pull reads that overlap a hotspot. |
| Select Reads by Sequence | A sequence (or FASTA) plus tolerance | Reads with (or without) the sequence at an end | You want to keep or discard reads carrying an adapter or barcode. |

Subset bundles are virtual by default. Only a small preview FASTQ of about
1000 reads lives on disk. The full FASTQ is reconstructed on demand the
first time a downstream operation needs it. This is a deliberate tradeoff:
many test slices of the same parent bundle stay cheap on disk, and the
preview is enough for QC charts and the FASTQ viewport. Reach for
subsample-by-count when you want comparable depth, subsample-by-proportion
when you want a quick test run, and the search operations when you have a
specific header, motif, or end-sequence in hand.

## Procedure

All five operations share one dialog and the same four moves: select a FASTQ
bundle in the sidebar (paired-end is supported, and pairs stay paired),
choose `Tools > FASTQ/FASTA Operations > Search & Subsetting…`, select the
operation from the list, set the fields the table below lists for that
operation, then click **Run**. The new bundle appears under `Imports/`. Only
the parameter fields differ between operations, so the table is the fastest
way to see what each one asks for.

| Operation | Fields you set | Default | Notes |
|---|---|---|---|
| Subsample by Count | `Count`: target read count (for example `10000`) | none | Returns about that many reads, or fewer if the input has fewer. |
| Subsample by Proportion | `Proportion`: a fraction between 0 and 1 (for example `0.1` for 10%) | none | Returns roughly that fraction of the input. |
| Extract Reads by ID | `Query`: a substring or pattern of the header; `Field` picker (`ID` up to the first whitespace, or `Description`); `Use Regular Expression` toggle | `Field` = ID, regex off | Matches a query string against the header, not a file of IDs. For paired data both mates of a matched read are kept. |
| Extract Reads by Motif | `Pattern`: a DNA string (for example a primer sequence); `Use Regular Expression` toggle | regex off | Searches the read sequence, not the header. No mismatch budget and no strand option. |
| Select Reads by Sequence | `Sequence or FASTA Path`; `Search End` picker (5' End or 3' End); `Min Overlap`; `Error Rate`; `Search Reverse Complement` toggle; `Keep Matched Reads` toggle | Min Overlap 8, Error Rate 0.1, both toggles off | Tolerant, end-anchored matching of an adapter or barcode. Turn on `Keep Matched Reads` to keep the reads that carry the sequence instead of discarding them. |

There is no random-seed control on the subsample operations, so do not record
a seed in your methods for a Lungfish subsample. If a reviewer needs the exact
draw, archive the output bundle itself.

Extract Reads by Motif has no mismatch budget and no strand option. When you
need tolerant matching with an error rate and a reverse-complement search, use
Select Reads by Sequence instead.

The command-line forms are `lungfish fastq subsample` (with `--proportion`
or `--count`), `lungfish fastq search-text` (Extract Reads by ID, with
`--query` and `--field id|description`), `lungfish fastq search-motif`
(Extract Reads by Motif, with `--pattern`), and `lungfish fastq
sequence-filter` (Select Reads by Sequence, with `--search-end`,
`--min-overlap`, `--error-rate`, `--search-rc`, and `--keep-matched`). On the
command line `--search-end` takes `left`, `right`, or `both` (default `both`),
where `left` is the 5' end and `right` is the 3' end the GUI picker labels.

## Interpretation

Every subset operation logs to the Operations Panel and writes a provenance
sidecar inside the new bundle, so the parameter you set and the input
checksum are recoverable later. The new bundle's QC charts (read length,
per-base quality, GC) reflect the subset, not the parent.

A virtual bundle shows a small badge in the sidebar and reports the full
read count in its Inspector even though only the preview is on disk. If you
right-click and choose **Reveal in Finder**, the bundle folder will contain
`preview.fastq` rather than the full file. This is normal. The first time
you run any downstream pipeline (mapping, classification, assembly) on a
virtual bundle, Lungfish materializes the full FASTQ as the first step,
runs the workflow, and cleans up the temporary file when the workflow ends.
You do not need to trigger materialization manually. If you want the full
FASTQ written out ahead of time (to pre-stage a large slice, for example),
the command `lungfish fastq materialize <bundle> -o <out>` realizes it on
demand.

An exact-motif extraction returns zero reads more often than people expect,
because Extract Reads by Motif matches the pattern exactly on the read as
written. If the library is unstranded (either strand of the molecule may
appear in the read) or you expect a base or two of sequencing error, use
Select Reads by Sequence instead: it offers an error-rate tolerance and a
reverse-complement search. Try it with `Search Reverse Complement` on and the
default 0.1 error rate before concluding a sequence is absent.

### Worked example: normalize two samples to equal depth

Suppose you have two FASTQ bundles for a comparison study: `SampleA` with
about 1,000,000 reads and `SampleB` with about 100,000 reads. A direct
comparison of classifier hit counts or coverage between them would be
biased by depth. To put them on equal footing:

1. Select `SampleA` and run **Subsample by Count** with a target of `100000`.
2. Leave `SampleB` as is.
3. Run the downstream comparison (classification, mapping, or whatever the
   study calls for) on the new subset bundle and on `SampleB`.
4. To make the draw reproducible for a reviewer, archive the output bundle
   itself (there is no seed to record).

Subsample by Count gives you about the target number of reads (or fewer, if
the input has fewer). Subsample by Proportion would instead draw a fraction
of whatever the input held, which is not what you want when the two inputs
start at different depths.

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
**Select Reads by Sequence**, paste the sequence, keep the default 0.1 error
rate, tick `Search Reverse Complement`, and tick `Keep Matched Reads`. If a
meaningful fraction of reads come back (anything above background), the
primer is present. Repeat for a second primer if you want stronger evidence.
For an exact, header-free spot check that a known motif appears at all (a
variant hotspot before assembly, for instance), Extract Reads by Motif is the
quicker tool.

## What you will learn

After this chapter you can subsample a bundle to a
target read count for fast pipeline testing, normalize two samples to a
comparable depth, extract reads by a header query, extract reads containing a
specific sequence motif, select reads that carry an adapter or barcode with
Select Reads by Sequence, and recognize that a virtual subset bundle does not
have its full FASTQ on disk until a downstream operation forces materialization.

## Next

Continue to [Oxford Nanopore Runs](07-ont-runs.md) for ONT-specific import
workflows, or jump to
[Mapping](../04-alignments/01-mapping-reads-to-a-reference.md) to map your
subset to a reference.
