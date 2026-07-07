---
title: Read Processing
chapter_id: 03-reads/08-read-processing
audience: bench-scientist
prereqs: [03-reads/01-importing-fastq]
estimated_reading_min: 7
task: Merge overlapping pairs, correct sequencing errors, reverse-complement reads, repair paired-end files, and interleave or deinterleave FASTQ.
tags: [reads, merge, error-correct, reverse-complement, repair, interleave]
tools: [bbmerge, tadpole, repair.sh, reformat]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Read Processing… (then pick the operation)"
  - "CLI: lungfish fastq merge, error-correct, reverse-complement, repair, interleave, deinterleave"
shots: []
planned_shots: []
illustrations: []
glossary_refs: []
features_refs: [fastq.read-processing]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter covers reshaping reads rather than cleaning them. To trim or
filter reads see [Trimming and Filtering](04-trimming-and-filtering.md), and to
take a subset see [Subsetting and Extraction](06-subsetting-and-extraction.md).

Read Processing gathers the operations that change the form of a read or a read
pair without judging its quality. You reach for these when a downstream tool
wants reads in a shape the sequencer did not hand you: overlapping pairs
collapsed into single fragments, obvious sequencing errors smoothed out before
assembly, reads flipped to the opposite strand, mates put back in register after
an upstream step desynchronized them, or paired files toggled between the
two-file and single interleaved layouts. Choose
`Tools > FASTQ/FASTA Operations > Read Processing…` and pick one from the list
inside the dialog. Each operation writes a new FASTQ bundle and leaves the input
untouched. Orient Reads lives in this category too and is covered in
[Oxford Nanopore Runs](07-ont-runs.md); Translate is covered with the sequence
tools.

| Operation | Tool | Input | Use it when |
|---|---|---|---|
| Merge Overlapping Pairs | bbmerge | Paired-end reads | Insert is shorter than the two reads combined, so mates overlap and can join into one fragment. |
| Correct Sequencing Errors | tadpole | Single or paired reads | You want to smooth random substitution errors before assembly using k-mer coverage. |
| Reverse Complement | native | Any reads | You need reads on the opposite strand, quality included. |
| Repair Paired-End Files | repair.sh | Interleaved pairs | An upstream step left mates out of order or dropped one mate of a pair. |

## What you will learn

You will come away able to merge overlapping paired-end reads with bbmerge,
correct sequencing errors with tadpole, reverse-complement reads together with
their quality scores, repair desynchronized paired-end files while keeping the
orphaned singletons, and move reads between the paired two-file layout and the
single interleaved layout on the command line.

## Procedure

Every operation in the dialog follows the same four moves: select a FASTQ
bundle in the sidebar, choose
`Tools > FASTQ/FASTA Operations > Read Processing…`, pick the operation from the
list, set the fields the table below lists for it, then click **Run**. Only the
parameter fields change between operations, so the table is the fastest way to
see what each one asks for.

| Operation | Fields you set | Default | Notes |
|---|---|---|---|
| Merge Overlapping Pairs | `Strictness` (Normal or Strict); `Min Overlap` | Strictness Normal, Min Overlap 12 | Strict mode makes fewer false merges. The output holds the merged fragments followed by any pairs that did not overlap. |
| Correct Sequencing Errors | `K-mer` size | 50 (valid range 1 to 62) | tadpole runs in correction mode and uses k-mer coverage to fix isolated substitutions. |
| Reverse Complement | none | none | Reverses each read and reverses its quality string to match. |
| Repair Paired-End Files | none | none | Restores pairing order and keeps reads whose mate is missing as singletons in the output. |

Merge Overlapping Pairs and Repair Paired-End Files operate on interleaved
paired-end reads, where R1 and R2 alternate in one file. The dialog handles the
interleaving for a paired-end bundle. On the command line you pass a single
interleaved FASTQ, so convert a two-file pair first with `interleave` if needed.

The command-line forms are `lungfish fastq merge <interleaved.fastq>` (with
`--min-overlap`, `--strict`, and `--count-duplicates`, which collapses identical
merged sequences and encodes each group's support as `size=N`),
`lungfish fastq error-correct <input>` (with `--kmer`),
`lungfish fastq reverse-complement <input>`, and
`lungfish fastq repair <interleaved.fastq>`. Two more utilities have no dialog
and exist only on the command line:
`lungfish fastq interleave --in1 <R1> --in2 <R2> -o <out>` folds a two-file pair
into one interleaved file, and
`lungfish fastq deinterleave <interleaved.fastq> --out1 <R1> --out2 <R2>` splits
it back into separate R1 and R2 files.

## Interpretation

Every operation logs to the Operations Panel and writes a provenance sidecar
inside the new bundle, so the parameters you set and the input checksum stay
recoverable later. A few results are worth reading closely.

Merge Overlapping Pairs only joins mates that actually overlap. A read pair
whose insert is longer than the combined read length cannot merge, and those
pairs pass through to the output unchanged rather than being dropped. If almost
nothing merges, the insert size is probably larger than your reads span, and
merging is not the right step. Raise `Min Overlap` or switch to Strict when you
would rather reject a doubtful join than accept a wrong one.

Correct Sequencing Errors leans on k-mer coverage, so it helps most on
higher-coverage data where a true base is seen many times and an error is seen
once. On thin coverage there is not enough signal to separate error from
variation, and correction can do more harm than good. Repair Paired-End Files is
for the specific failure where mates fall out of order or one mate goes missing:
it re-pairs what it can and sets the orphaned reads aside as singletons in the
same output, so no read is silently lost.

## Next

This is the last chapter in [Reads (FASTQ)](.). Continue to
[Alignments](../04-alignments/) to map your processed reads to a reference.
