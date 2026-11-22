---
title: Counting Bulk RNA-seq Reads
chapter_id: 11-rna-seq/02-counting-bulk-reads
audience: bench-scientist
prereqs: [11-rna-seq/01-what-is-rna-seq, 03-reads/01-importing-fastq, 01-foundations/07-plugin-packs]
estimated_reading_min: 28
task: Build a reference set, count bulk RNA-seq reads with salmon on the Mac, plan salmon or STAR counting for a Linux machine, or import counts another tool made.
tags: [rna-seq, bulk, salmon, star, featurecounts, reference-set, quantification, counts, linux]
tools: [salmon, gffread, trim-galore, star, featurecounts]
parameters_refs: []
entry_points:
  - "Tools > RNA-seq > Quantify RNA-seq Reads…"
  - "Import Center > Sequencing Reads > RNA-seq Counts"
  - "Import Center > Sequencing Reads > RNA-seq Plan for a Linux Machine"
  - "Import Center > Sequencing Reads > RNA-seq Linux Run Result"
  - "CLI: lungfish-cli rnaseq reference-set, lungfish-cli rnaseq index, lungfish-cli rnaseq index-plan, lungfish-cli rnaseq index-adopt"
  - "CLI: lungfish-cli rnaseq quant, lungfish-cli import rnaseq"
shots:
  - id: rnaseq-quantify-pane
    caption: "The Quantify RNA-seq Reads pane of the FASTQ/FASTA Operations dialog with the ERCC92 reference set chosen, showing Reference set, k-mer length, Decoys, Trim with Trim Galore, and Poly-G trimming."
  - id: rnaseq-counts-import-sheet
    caption: "The sheet the RNA-seq Counts card of the Import Center opens, with the two salmon quant folders of the SEQC fixture chosen."
  - id: rnaseq-plan-sheet
    caption: "The sheet the RNA-seq Plan for a Linux Machine card of the Import Center opens, set to plan a salmon count of the fixture reads."
illustrations: []
glossary_refs: [fastq, read, fragment, paired-end, interleaved-fastq, bundle, virtual-bundle, genome, fasta, gtf, gff, k-mer, mapping, splice-aware-mapper, trim-galore, poly-g-tail, spike-in-control, plugin-pack, import-center, sample-sheet, operations-panel, provenance]
features_refs: [rnaseq.reference-set, rnaseq.quant, import.rnaseq-counts, import.rnaseq-plan, import.rnaseq-adopt]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Building a reference set, quantifying reads with salmon on the Mac, planning salmon or STAR for a Linux machine, and importing counts another tool made. -->

## What it is

## Why you would do this

## Choosing a tool

## Before you start

## Procedure

### Build a reference set with rnaseq reference-set

### Quantify RNA-seq reads with salmon

<!-- WAIT ux-text TV-SHELL -->

<!-- SHOT: rnaseq-quantify-pane -->

### Import salmon folders or a count table with the RNA-seq Counts card

<!-- SHOT: rnaseq-counts-import-sheet -->

### Plan salmon or STAR counting for a Linux machine

<!-- SHOT: rnaseq-plan-sheet -->

### Adopt the counts a Linux run returned

## Settings

### Quantify RNA-seq Reads settings

<!-- WAIT ux-text TV-SHELL -->

### RNA-seq Counts sheet settings

### RNA-seq plan sheet settings

### RNA-seq Linux Run Result sheet settings

## Reading the results

## What good looks like

## On the command line

## Next
