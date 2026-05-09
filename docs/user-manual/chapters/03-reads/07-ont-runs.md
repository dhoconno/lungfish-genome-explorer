---
title: Oxford Nanopore Runs
chapter_id: 03-reads/07-ont-runs
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 7
task: Import an Oxford Nanopore run directory and orient reads against a reference.
tags: [reads, nanopore, ont, long-read, orient, barcoded]
tools: []
entry_points:
  - "File > Import ONT Run"
  - "Tools > FASTQ/FASTA Operations > Read Processing > Orient Reads"
shots: []
planned_shots:
  - id: ont-import-dialog
    caption: "The Import ONT Run dialog with a barcoded run directory selected."
illustrations: []
glossary_refs: [FASTQ, basecaller, barcode, Orient Reads]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

Oxford Nanopore runs come off the sequencer as a directory tree, not a single
file. The MinKNOW software writes one subfolder per barcode (`barcode01`,
`barcode02`, and so on, plus an `unclassified` folder for reads whose barcode
could not be called) and inside each subfolder it drops a stack of FASTQ files,
typically one per worker thread that was basecalling at the time. A single
24-barcode run can therefore contain several hundred FASTQ files spread across
two dozen folders, all describing the same physical flowcell.

Lungfish imports the whole tree in one step through `File > Import ONT Run`.
The dialog walks the directory, groups every FASTQ under a given barcode
folder into one logical bundle, and creates one bundle per barcode in the
project. If you point it at a sample sheet (a CSV mapping barcode to sample
name and any other metadata you want to carry forward), Lungfish attaches that
metadata to each bundle as it is created. The result is one row per sample in
the sidebar, regardless of how many FASTQ files the basecaller produced.

ONT reads have two properties that matter immediately. They are long: 1 kb to
100 kb is typical, with mean read length usually 5 to 15 kb depending on
library prep and fragment size. And they are unstranded by default. The read
in the FASTQ may correspond to either strand of the original DNA molecule,
chosen essentially at random by which end of the fragment threaded into the
pore first. For most analyses this is fine because the aligner figures it out.
For amplicon protocols and consensus building it is often easier to flip the
reverse-strand reads up front so every read in the bundle points the same way.
Lungfish does this with the Orient Reads operation, covered below.

So what should you do with this? Import the whole run directory once, let
Lungfish split it into per-barcode bundles, attach a sample sheet so the
bundles carry the right names, and run Orient Reads if your downstream step
expects consistent strand.

## What you will learn

By the end of this chapter you will be able to import a multi-barcode ONT run,
recognize the resulting bundles as one per barcode, attach sample metadata
from a sample sheet, run Orient Reads against a reference, and feed the
oriented bundle into mapping or assembly workflows that expect consistent
strand.

## How ONT compares to Illumina

The two platforms produce FASTQ files that look identical on the surface but
behave very differently in practice. The table below summarises the
differences that change how you handle the data. The numbers are
approximations, not specifications: throughput and cost depend on flowcell
type, library, and run length.

| Property | Oxford Nanopore (R10.4.1) | Illumina (NovaSeq / MiSeq) |
|---|---|---|
| Read length | 1 to 100 kb, mean 5 to 15 kb | 75 to 300 bp, fixed per run |
| Per-base error | Q15 to Q20 with modern basecallers | Q30 to Q40 |
| Strand | Unstranded; either strand may appear | Stranded (R1 and R2 have defined orientation) |
| Throughput per run | 10 to 100 Gb (PromethION); 1 to 10 Gb (MinION) | 1.5 Tb (NovaSeq); 15 Gb (MiSeq) |
| Approximate cost per Mb | A few cents to ~$0.10 | Fractions of a cent (NovaSeq) to ~$0.05 (MiSeq) |

The practical consequences for analysis: ONT's longer reads make assembly and
structural variant detection much easier, but its higher per-base error rate
means that single-read variant calls are unreliable, and most variant callers
(Medaka, Clair3) rely on the read pile-up rather than individual reads. For
amplicon work the long reads usually span the entire amplicon, which
simplifies primer trimming and consensus calling but makes strand orientation
worth normalizing first.

## A note on basecaller models

Every ONT FASTQ was produced by a specific basecaller (Guppy or its successor
Dorado) running a specific model. The model name encodes the chemistry, the
flowcell, and the accuracy mode. Examples include
`dna_r10.4.1_e8.2_400bps_sup` for super-accuracy basecalling on R10.4.1
chemistry and `dna_r9.4.1_e8_hac` for older R9 high-accuracy.

The model matters downstream. Medaka, the ONT-aware consensus and variant
caller used in [Variants](../04-variants/), ships with model-specific
parameters and will refuse to run, or produce silently worse results, if the
Medaka model does not match the basecaller model that produced the reads. For
this reason we recommend recording the basecaller model in your sample sheet
or in the Inspector metadata field at import time. Lungfish does not parse the
model from FASTQ headers (basecaller versions vary in whether they write it),
so the metadata you record now is what later steps will see.

## Procedure

The walk-through below uses a hypothetical 8-barcode SARS-CoV-2 ARTIC run as
the example. The shape is the same for any barcoded ONT run.

### 1. Lay out the run directory

A typical MinKNOW output for an 8-barcode run looks like this. Folder names
follow the `barcodeNN` convention, and each folder contains one or more
`.fastq.gz` files written by the basecaller's worker threads.

```
artic-run-2026-04-12/
  barcode01/
    FAW12345_pass_barcode01_a1b2c3_0.fastq.gz
    FAW12345_pass_barcode01_a1b2c3_1.fastq.gz
  barcode02/
    FAW12345_pass_barcode02_a1b2c3_0.fastq.gz
  ...
  barcode08/
    FAW12345_pass_barcode08_a1b2c3_0.fastq.gz
  unclassified/
    FAW12345_pass_unclassified_a1b2c3_0.fastq.gz
```

Alongside the run directory, prepare a sample sheet. The format is a CSV with
at least a `barcode` column and a `sample` column; any extra columns become
Inspector metadata. We recommend a `basecaller_model` column.

```csv
barcode,sample,collection_date,basecaller_model
barcode01,COV-2026-001,2026-04-10,dna_r10.4.1_e8.2_400bps_sup
barcode02,COV-2026-002,2026-04-10,dna_r10.4.1_e8.2_400bps_sup
...
barcode08,COV-2026-008,2026-04-11,dna_r10.4.1_e8.2_400bps_sup
```

### 2. Open the Import ONT Run dialog

Choose `File > Import ONT Run`. Click "Choose Run Folder" and select the
top-level run directory (`artic-run-2026-04-12/` in the example). The dialog
scans the tree and lists every barcode folder it finds, with a read count and
total base count next to each row.

<!-- planned: ont-import-dialog -->

If a sample sheet is present, click "Attach Sample Sheet" and select the CSV.
The dialog matches sample-sheet rows to barcode rows by the `barcode` column
and previews the merged metadata. Rows that fail to match are flagged in Warm
Grey so you can correct them before import.

### 3. Choose what to import

By default every detected barcode is selected. You can deselect
`unclassified` if you do not want it as a bundle (it is often noise, but for
troubleshooting demultiplexing it is worth keeping). For most projects, leave
all real barcodes selected.

### 4. Run the import

Click "Run". Lungfish creates one bundle per selected barcode under
`Imports/` in the sidebar, each named after the `sample` column from the
sheet (or `barcodeNN` if no sheet was attached). For our example you should
see eight new bundles, plus optionally an `unclassified` bundle, appear in the
sidebar.

### 5. Orient the reads

Open one of the new bundles and choose
`Tools > FASTQ/FASTA Operations > Read Processing > Orient Reads`. Pick a
reference sequence (the SARS-CoV-2 reference, MN908947.3 or equivalent, for
this example) and click "Run". Lungfish aligns each read to the reference,
flips reverse-strand reads to their reverse complement, and writes a new
bundle with `-oriented` appended to the name. The original bundle is
preserved.

To orient all eight bundles in one pass, multi-select them in the sidebar
before launching the operation. Lungfish queues one Orient Reads job per
selected bundle.

## Interpretation

After import you should see one bundle per barcode you selected, each
populated with the metadata you provided. Opening a bundle shows the FASTQ
viewport with combined read-length and quality histograms across all the
per-thread FASTQ files Lungfish merged behind the scenes. Read counts in the
sidebar should match the totals shown in the import dialog.

After Orient Reads, the new `-oriented` bundle contains the same number of
reads as the input, but every read is now in forward orientation relative to
the reference. Reads that did not align to the reference are dropped by
default; if you need to keep unmapped reads (for example to chase
contamination), the Orient Reads dialog has a "Keep unmapped reads" checkbox
that retains them in their original orientation.

If a bundle has unexpectedly few reads, the most common causes are an
incorrect barcode in the sample sheet, demultiplexing that classified reads
into `unclassified` instead of into the expected barcode, or a sample-sheet
row that did not match because of whitespace in the `barcode` column. The
Operations Panel shows the per-step log for each bundle's import and orient
operations.

## What this chapter does not cover

ONT generates several layers of data beyond FASTQ that Lungfish does not
import directly. POD5 and FAST5 files contain the raw electrical signal
(squiggle) traces and are needed for re-basecalling with a newer model or for
modified-base calling. Real-time analysis hooks (MinKNOW's live basecalling
output, ReadFish-style streaming) operate while the run is in progress and
require a different integration. Adaptive Sampling, where the sequencer
rejects reads matching or not matching a target in real time, is configured
in MinKNOW before the run starts and is invisible to Lungfish at import time
(its effect shows up as biased coverage in the FASTQ).

If you need any of these, do the signal-level or real-time work outside
Lungfish, and import the resulting FASTQ here.

## Next

This is the last chapter in [Reads (FASTQ)](.). Continue to
[Alignments](../04-alignments/) to map reads to a reference.
