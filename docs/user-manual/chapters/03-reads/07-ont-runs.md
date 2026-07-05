---
title: Oxford Nanopore Runs
chapter_id: 03-reads/07-ont-runs
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 7
task: Import an Oxford Nanopore run directory and orient reads against a reference.
tags: [reads, nanopore, ont, long-read, orient, barcoded, demultiplex]
tools: [vsearch, cutadapt]
entry_points:
  - "Import Center (Cmd-Shift-I) > Sequencing Reads > ONT Run Folder"
  - "Tools > FASTQ/FASTA Operations > Read Processing… (then Orient Reads)"
  - "Tools > FASTQ/FASTA Operations > Demultiplexing"
  - "CLI: lungfish fastq import-ont, lungfish fastq orient"
  - "CLI: lungfish fastq demultiplex, lungfish fastq scout"
shots: []
planned_shots:
  - id: ont-import-dialog
    caption: "The Import Center ONT Run Folder tile with a barcoded run directory selected."
illustrations: []
glossary_refs: [FASTQ, basecaller, barcode, Orient Reads]
features_refs: [fastq.demultiplex]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter covers importing an Oxford Nanopore run folder and orienting the reads. For importing single FASTQ files or Illumina pairs see [Importing FASTQ](01-importing-fastq.md).

Oxford Nanopore runs come off the sequencer as a directory tree, not a single
file. The MinKNOW software writes one subfolder per barcode (`barcode01`,
`barcode02`, and so on, plus an `unclassified` folder for reads whose barcode
could not be called) and inside each subfolder it drops a stack of FASTQ files,
typically one per worker thread (one of several parallel processes the
basecaller, the program that turns the sequencer's raw signal into reads, runs
at once). A single 24-barcode run can therefore contain several hundred FASTQ
files spread across two dozen folders, all describing the same physical
flowcell.

Lungfish imports the whole tree in one step through the Import Center. Press
`Cmd-Shift-I`, choose the `Sequencing Reads` tab, and select the
`ONT Run Folder` tile. Lungfish walks the directory, groups every FASTQ under
a given barcode folder into one logical bundle, and creates one bundle per
barcode in the project. The result is one row per barcode in the sidebar,
regardless of how many FASTQ files the basecaller produced. The same import
runs from the command line as `lungfish fastq import-ont <dir> -o <out>`,
which is the path to script for a sequencing core.

ONT reads have two properties that matter immediately. They are long: 1 kb to
100 kb is typical, with mean read length usually 5 to 15 kb depending on
library prep and fragment size. And they are unstranded by default, meaning
the read in the FASTQ may correspond to either strand of the original DNA
molecule, chosen essentially at random by which end of the fragment threaded
into the pore first. For most analyses this is fine because the aligner
figures it out. For amplicon protocols and consensus building it is often
easier to flip the reverse-strand reads up front so every read in the bundle
points the same way. Lungfish does this with the Orient Reads operation,
covered below.

Import the whole run directory once, let Lungfish split it into per-barcode
bundles, record the sample names and basecaller model as metadata, and run
Orient Reads if your downstream step expects consistent strand.

## What you will learn

This chapter gets you to the point of importing a multi-barcode ONT run,
recognizing the resulting bundles as one per barcode, recording per-barcode
sample metadata, running Orient Reads against a reference, and feeding the
oriented bundle into mapping or assembly workflows that expect consistent strand.

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
caller used in [Nanopore Variant Calling](../05-variants/04-nanopore-variant-calling.md),
ships with model-specific parameters and will refuse to run, or produce
silently worse results, if the Medaka model does not match the basecaller
model that produced the reads. For
this reason we recommend recording the basecaller model as bundle metadata
(in the Inspector, or in the CSV you import with `lungfish metadata import`)
right after import. Lungfish does not parse the model from FASTQ headers
(basecaller versions vary in whether they write it), so the metadata you
record now is what later steps will see.

## Procedure

The walk-through below uses a hypothetical 8-barcode SARS-CoV-2 ARTIC run as
the example. The shape is the same for any barcoded ONT run.

### 1. Lay out the run directory

A typical MinKNOW output for an 8-barcode run looks like this. Folder names
follow the `barcodeNN` convention, and each folder contains one or more
`.fastq.gz` files written by the basecaller's worker threads.

```
artic-run-2026-04-12/
  fastq_pass/
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

### 2. Open the ONT Run Folder importer

Press `Cmd-Shift-I` to open the Import Center, choose the `Sequencing Reads`
tab, and select the `ONT Run Folder` tile. Point it at the `fastq_pass/`
parent directory (or at a single `barcodeNN/` folder if you only want one).
Lungfish walks the tree and concatenates the per-barcode FASTQ chunks into one
bundle per barcode.

<!-- planned: ont-import-dialog -->

### 3. Decide whether to include unclassified

By default the importer skips the `unclassified` folder, because those reads
carry no barcode and are usually noise. Include them only when you are
troubleshooting demultiplexing. On the command line this is the
`--include-unclassified` flag; the default is to skip.

### 4. Run the import

Complete the import. Lungfish creates one bundle per barcode under `Imports/`
in the sidebar, named `barcodeNN`. For this example you should see eight new
bundles (plus an `unclassified` bundle only if you opted it in). The
equivalent command-line import is:

```sh
lungfish fastq import-ont artic-run-2026-04-12/fastq_pass -o Imports/
```

Two CLI options change how the reads are stored. `--storage-mode` (`chunked`,
the default, or `flattened`) controls whether the per-barcode chunks are kept
separate or concatenated into one payload, and `--optimize-storage` (with
`--storage-mode flattened`) runs clumpify to reorder reads for better
compression. `--quality-binning` (`none`, the default, or `illumina4` /
`eightLevel`) re-quantises base qualities to shrink the bundle. The defaults
leave the read bytes unchanged; the binning and reordering options change them.

### 5. Record sample metadata

The ONT import names bundles `barcodeNN`, not by sample. To attach sample
names and the basecaller model, prepare a CSV keyed by bundle name and import
it with `lungfish metadata import`, or edit each bundle's metadata in the
Inspector. A useful CSV carries one row per barcode with at least a
`basecaller_model` column, because Medaka downstream needs it (see the note
above).

```csv
sample_name,sample,collection_date,basecaller_model
barcode01,COV-2026-001,2026-04-10,dna_r10.4.1_e8.2_400bps_sup
barcode02,COV-2026-002,2026-04-10,dna_r10.4.1_e8.2_400bps_sup
```

### 6. Orient the reads

Open one of the new bundles and choose
`Tools > FASTQ/FASTA Operations > Read Processing…`, then select `Orient
Reads` in the dialog. Select a reference FASTA in the Inputs section (the
SARS-CoV-2 reference, MN908947.3 or equivalent, for this example) and click
`Run`. Lungfish runs vsearch to compare each read to the reference and flips
reverse-strand reads to their reverse complement, writing a new bundle. The
original bundle is preserved.

The Orient Reads pane exposes three controls: `Word Length` (the length of the
short exact match, called a seed, that vsearch uses to anchor a read against
the reference before it decides the read's strand, default 12), a
`Database Mask` picker (`dust` masks low-complexity regions such as long
single-base or dinucleotide runs so they do not produce spurious matches, or
`none` to mask nothing), and an `Extra arguments` field for additional vsearch
flags. There is no keep-or-drop
checkbox in the pane; how vsearch handles a read it cannot orient is a vsearch
behavior, not a Lungfish setting.

To orient all eight bundles in one pass, multi-select them in the sidebar
before launching the operation. Lungfish queues one Orient Reads job per
selected bundle.

## Interpretation

After import you should see one bundle per barcode, each named `barcodeNN`.
Opening a bundle shows the FASTQ viewport with combined read-length and
quality histograms across all the per-thread FASTQ files Lungfish merged
behind the scenes. The read counts in the sidebar are the totals across every
chunk in that barcode folder.

After Orient Reads, the new bundle holds the oriented reads in forward
orientation relative to the reference. Whether a read that vsearch cannot
confidently orient is dropped or carried through unchanged is a vsearch
`--orient` behavior, not a checkbox in Lungfish. If keeping non-orientable
reads matters for your workflow, set the relevant vsearch flag in the `Extra
arguments` field and confirm the output read count against the input.

If a bundle has unexpectedly few reads, the most common causes are
demultiplexing that classified reads into `unclassified` instead of the
expected barcode, or a barcode folder that was empty at import. The Operations
Panel shows the per-step log for each bundle's import and orient operations.

If MinKNOW did not demultiplex the run (a single `fastq_pass/` with no
per-barcode subfolders), or you want to re-split with a different kit, Lungfish
can demultiplex from the command line: `lungfish fastq demultiplex` and
`lungfish fastq scout` carry the ONT barcode kits (for example `ont-nbd114`,
`ont-rbk114-24`, `ont-16s114-24`). Run `lungfish fastq demultiplex --help`
for the kit list.

## Re-demultiplexing a barcoded run

Demultiplexing is the step that sorts a pool of reads into per-sample bins by
reading the short barcode sequence attached to each read. MinKNOW usually does
this during the run, which is why an ONT import already arrives split into
`barcodeNN` folders. Sometimes you need to redo it: MinKNOW wrote a single
undemultiplexed `fastq_pass/`, the run used barcodes MinKNOW does not know, or
you want to split on a second, internal barcode. Lungfish demultiplexes from the
command line and from `Tools > FASTQ/FASTA Operations > Demultiplexing` in the
app.

In practice, reach for demultiplexing only when the
per-barcode split you need is missing or wrong. If MinKNOW already produced the
right barcode folders, import those directly instead.

### Previewing barcodes with the scout

Before committing to a full run, scan a sample of reads to see which barcodes
are actually present. This is the barcode scout:

```bash
lungfish fastq scout reads.fastq.gz --kit ont-nbd114 -o scout-result.json
```

The scout reads up to 10,000 reads by default (`--read-limit`), counts hits for
every barcode in the kit, and writes a `scout-result.json` with a suggested
accept or reject for each barcode. A barcode with at least `--accept-threshold`
hits (default 10) is marked accepted, one with at most `--reject-threshold` hits
(default 3) is marked rejected, and the rest are left undecided for you to
judge. Use it to confirm the kit is right and to spot barcodes that were
expected but never appear.

### Running the demultiplex

Point the demultiplexer at a FASTQ (or a `.lungfishfastq` bundle) and name a
barcode kit:

```bash
lungfish fastq demultiplex reads.fastq.gz --kit ont-nbd114 -o demux-out/
```

`--kit` takes a built-in kit ID or a path to a custom CSV/TSV barcode file with
`id,sequence[,secondary_sequence][,sample_name]` columns. Lungfish runs cutadapt
(the barcode-matching tool) to sort the reads and writes one `.lungfishfastq`
bundle per barcode under the output directory, plus a `demux-manifest.json`
recording the per-barcode read counts and the exact command. A few options
adjust matching:

- `--location`: where the barcode sits, `5prime`, `3prime`, or `bothends` (default).
- `--error-rate`: how much mismatch to tolerate (default 0.15).
- `--no-trim`: keep the barcode bases in the output reads instead of cutting them.
- `--discard-unassigned`: drop reads that matched no barcode (see below).
- `--threads`: cutadapt thread count (default 4).

### Reads that match no barcode

Reads whose barcode could not be called go to a bin named `unassigned`, the same
idea as MinKNOW's `unclassified`. By default Lungfish keeps this bin as its own
bundle so you can inspect it. Pass `--discard-unassigned` to throw it away. A
large unassigned fraction usually means the wrong kit, too strict an error rate,
or barcodes at an end you did not search. The scout above is the quickest way to
catch that before a full run.

### Splitting on two barcodes in sequence

Some libraries carry two barcodes, for example an outer ONT native barcode and
an inner index. Lungfish supports multi-step demultiplexing: it splits the raw
reads on the first kit, then splits each resulting bin again on the second kit.
For a combinatorial dual-index kit supplied without explicit sample
assignments, Lungfish auto-scouts each step to discover which barcode pairs
actually occur rather than expanding every possible combination. The result is
one bundle per final barcode combination.

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
