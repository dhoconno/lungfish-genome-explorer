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

Subsetting pulls a subset of reads out of a bundle. Bench scientists reach for
it for a handful of reasons: to test a pipeline fast on a manageable slice of a
large run, to balance two samples to the same depth before a side-by-side
comparison, to pull out the exact reads whose header matched a classifier or
aligner hit, to ask whether any reads carry a particular sequence motif (a
primer, a known variant, a probe target), and to keep or discard reads bearing
an adapter or barcode at a read end.

Lungfish offers five operations for this. Choose
`Tools > FASTQ/FASTA Operations > Search & Subsetting…` and pick one from the
list inside the dialog. Two are random samplers, by proportion or by count.
Two are targeted extractors, by read header text or by a sequence motif. One
is a sequence-presence filter, Select Reads by Sequence. Each produces a new
FASTQ bundle in the sidebar, and the parent bundle is never touched.

| Operation | Input | Output | Use it when |
|---|---|---|---|
| Subsample by Proportion | Fraction (for example, 0.1) | Roughly that fraction of reads | You want a fast test slice that stays proportional to the original. |
| Subsample by Count | Integer (for example, 100000) | About N reads | You want to normalize two samples to a similar depth. |
| Extract Reads by ID | A query string matched against the header | Reads whose header matches | You have a header substring or pattern from a classifier, mapper, or BLAST. |
| Extract Reads by Motif | A sequence pattern | Reads containing the motif | You want to verify a primer is present, or pull reads that overlap a hotspot. |
| Select Reads by Sequence | A sequence (or FASTA) plus tolerance | Reads with (or without) the sequence at an end | You want to keep or discard reads carrying an adapter or barcode. |

Subset bundles are virtual by default. Only a small preview FASTQ of about
1000 reads sits on disk. The full FASTQ is rebuilt on demand the first time a
downstream operation needs it. The tradeoff is deliberate: many test slices of
the same parent bundle stay cheap on disk, and the preview is enough for QC
charts and the FASTQ viewport. Reach for subsample-by-count when you want
comparable depth, subsample-by-proportion when you want a quick test run, and
the search operations when you have a specific header, motif, or end-sequence
in hand.

## Procedure

All five operations share one dialog and the same four moves: select a FASTQ
bundle in the sidebar (paired-end is supported, and pairs stay paired),
choose `Tools > FASTQ/FASTA Operations > Search & Subsetting…`, pick the
operation from the list, set the fields the table below lists for it, then
click **Run**. The new bundle appears under `Imports/`. Only the parameter
fields change between operations, so the table is the fastest way to see what
each one asks for.

| Operation | Fields you set | Default | Notes |
|---|---|---|---|
| Subsample by Count | `Count`: target read count (for example `10000`) | none | Returns about that many reads, or fewer if the input has fewer. |
| Subsample by Proportion | `Proportion`: a fraction between 0 and 1 (for example `0.1` for 10%) | none | Returns roughly that fraction of the input. |
| Extract Reads by ID | `Query`: a substring or pattern of the header; `Field` picker (`ID` up to the first whitespace, or `Description`); `Use Regular Expression` toggle | `Field` = ID, regex off | Matches a query string against the header, not a file of IDs. For paired data both mates of a matched read are kept. |
| Extract Reads by Motif | `Pattern`: a DNA string (for example a primer sequence); `Use Regular Expression` toggle | regex off | Searches the read sequence, not the header. No mismatch budget and no strand option. |
| Select Reads by Sequence | `Sequence or FASTA Path`; `Search End` picker (5' End or 3' End); `Min Overlap`; `Error Rate`; `Search Reverse Complement` toggle; `Keep Matched Reads` toggle | Min Overlap 8, Error Rate 0.1, both toggles off | Tolerant, end-anchored matching of an adapter or barcode. Turn on `Keep Matched Reads` to keep the reads that carry the sequence instead of discarding them. |

The subsample operations have no random-seed control, so do not record a seed
in your methods for a Lungfish subsample. If a reviewer needs the exact draw,
archive the output bundle itself.

Extract Reads by Motif carries no mismatch budget and no strand option. When
you need tolerant matching, with an error rate and a reverse-complement search,
use Select Reads by Sequence instead.

The command-line forms are `lungfish fastq subsample` (with `--proportion`
or `--count`), `lungfish fastq search-text` (Extract Reads by ID, with
`--query` and `--field id|description`), `lungfish fastq search-motif`
(Extract Reads by Motif, with `--pattern`), and `lungfish fastq
sequence-filter` (Select Reads by Sequence, with `--search-end`,
`--min-overlap`, `--error-rate`, `--search-rc`, and `--keep-matched`). On the
command line `--search-end` takes `left`, `right`, or `both` (default `both`),
where `left` is the 5' end and `right` is the 3' end the GUI picker labels.

### Extract reads by an ID list (CLI)

The GUI Extract Reads by ID matches a query against read headers. A separate
command-line tool, `lungfish extract reads --by-id`, does the complementary
job: it pulls the reads whose identifiers appear in a text file, one ID per
line. Reach for it when a classifier, mapper, or upstream script hands you an
explicit list of read names rather than a header pattern.

```bash
lungfish extract reads --by-id --ids read_ids.txt --source input.fastq -o out.fastq
```

`--ids` points at the ID file. `--source` names the FASTQ to pull from and
repeats for paired-end data: pass `--source R1.fastq --source R2.fastq` and
both mates are handled together. With more than one source `--keep-read-pairs`
is the default, so a hit on either mate keeps the pair. Pass
`--no-keep-read-pairs` to emit only the exact reads whose IDs matched. Add
`--bundle`, or `--bundle-name <name>` which implies it, to wrap the output as a
sidebar `.lungfishfastq` bundle instead of a bare FASTQ.

## Interpretation

Every subset operation logs to the Operations Panel and writes a provenance
sidecar inside the new bundle, so the parameter you set and the input
checksum stay recoverable later. The new bundle's QC charts (read length,
per-base quality, GC) reflect the subset, not the parent.

A virtual bundle carries a small badge in the sidebar and reports the full
read count in its Inspector, even though only the preview is on disk.
Right-click and choose **Reveal in Finder** and the bundle folder holds
`preview.fastq` rather than the full file. That is normal. The first time
you run any downstream pipeline (mapping, classification, assembly) on a
virtual bundle, Lungfish materializes the full FASTQ as the first step,
runs the workflow, and clears the temporary file when the workflow ends.
You never trigger materialization by hand. If you want the full FASTQ written
out ahead of time, to pre-stage a large slice for instance, the command
`lungfish fastq materialize <bundle> -o <out>` realizes it on demand.

An exact-motif extraction returns zero reads more often than people expect,
because Extract Reads by Motif matches the pattern exactly on the read as
written. If the library is unstranded (either strand of the molecule may show
up in the read) or you expect a base or two of sequencing error, use Select
Reads by Sequence instead: it offers an error-rate tolerance and a
reverse-complement search. Try it with `Search Reverse Complement` on and the
default 0.1 error rate before you conclude a sequence is absent.

### Worked example: normalize two samples to equal depth

Say you have two FASTQ bundles for a comparison study: `SampleA` with about
1,000,000 reads and `SampleB` with about 100,000 reads. Compare their
classifier hit counts or coverage head to head and depth alone will skew the
result. To put them on equal footing:

1. Select `SampleA` and run **Subsample by Count** with a target of `100000`.
2. Leave `SampleB` as is.
3. Run the downstream comparison (classification, mapping, or whatever the
   study calls for) on the new subset bundle and on `SampleB`.
4. To make the draw reproducible for a reviewer, archive the output bundle
   itself (there is no seed to record).

Subsample by Count returns about the target number of reads, or fewer if the
input holds fewer. Subsample by Proportion would instead draw a fraction of
whatever the input held, which is not what you want when the two inputs start
at different depths.

### Worked example: a quick test slice of an SRA run

You have just downloaded `SRR36291587` and want to dry-run an assembly
pipeline before committing to the full run. Select the bundle, choose
**Subsample by Count**, enter `10000`, and click **Run**. Feed the resulting
virtual subset to the assembly pipeline. The materialization step rebuilds the
10,000-read FASTQ at the start of the run, and the assembly itself finishes in
a fraction of the full job's wall time. If the dry run looks right, re-run the
assembly against the full bundle.

### Worked example: verify primer presence

You suspect a sample was prepared with the ARTIC v3 scheme, but you want to
confirm before running primer trim. Pick a high-yield primer sequence from
the scheme (a left primer near the start of ORF1ab, for example), choose
**Select Reads by Sequence**, paste the sequence, keep the default 0.1 error
rate, tick `Search Reverse Complement`, and tick `Keep Matched Reads`. If a
meaningful fraction of reads come back, anything above background, the primer
is present. Repeat for a second primer if you want stronger evidence. For an
exact, header-free spot check that a known motif appears at all, a variant
hotspot before assembly for instance, Extract Reads by Motif is the quicker
tool.

## What you will learn

After this chapter you can subsample a bundle to a
target read count for fast pipeline testing, normalize two samples to a
comparable depth, extract reads by a header query, extract reads that contain a
specific sequence motif, select reads carrying an adapter or barcode with
Select Reads by Sequence, and recognize that a virtual subset bundle keeps its
full FASTQ off disk until a downstream operation forces materialization.

## Next

Continue to [Oxford Nanopore Runs](07-ont-runs.md) for ONT-specific import
workflows, or jump to
[Mapping](../04-alignments/01-mapping-reads-to-a-reference.md) to map your
subset to a reference.
