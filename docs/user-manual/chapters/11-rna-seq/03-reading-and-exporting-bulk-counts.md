---
title: Reading and Exporting Bulk RNA-seq Counts
chapter_id: 11-rna-seq/03-reading-and-exporting-bulk-counts
audience: bench-scientist
prereqs: [11-rna-seq/01-what-is-rna-seq, 11-rna-seq/02-counting-bulk-reads]
estimated_reading_min: 20
task: Read a bulk RNA-seq result, check its quality table and sample correlation, and export its counts for DESeq2, edgeR, or limma.
tags: [rna-seq, bulk, counts, quality, correlation, export, deseq2, edger, limma, differential-expression]
tools: []
parameters_refs: []
entry_points:
  - "Sidebar: select an RNA-seq result (.lungfishrnaseq) of bulk modality"
  - "Tools > RNA-seq > Export RNA-seq Counts…"
  - "CLI: lungfish-cli rnaseq quality, lungfish-cli rnaseq export"
shots:
  - id: rnaseq-bulk-view
    caption: "A bulk RNA-seq result of the SEQC fixture open in its viewer, with the header that names the result, modality, origin, route, and sample count above the count table tab."
  - id: rnaseq-correlation-tab
    caption: "The Correlation tab of the same result, showing Pearson r of log2(CPM + 1) between each pair of samples."
  - id: rnaseq-export-dialog
    caption: "The Export RNA-seq Counts pane of the Workflow Operations dialog with the SEQC result chosen and a design and one contrast filled in."
illustrations: []
glossary_refs: [library, ribosomal-rna, spike-in-control, mapping, sample-sheet, sample-metadata, tsv, manifest, checksum, provenance, inspector, operations-panel]
features_refs: [viewport.rnaseq-result, rnaseq.bulk-view, rnaseq.quality, rnaseq.export]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Reading a bulk RNA-seq result, its quality table, and its sample correlation, and exporting counts for DESeq2, edgeR, and limma. -->

## What it is

### Design, contrasts, and batch effects

## Why you would do this

## Choosing a tool

## Before you start

## Procedure

### Open a bulk RNA-seq result

<!-- WAIT ux-text TV-SCVIEW -->

<!-- SHOT: rnaseq-bulk-view -->

### Export counts with Export RNA-seq Counts

<!-- WAIT ux-text TV-PSEUDOBULK -->

<!-- SHOT: rnaseq-export-dialog -->

## Settings

### Export RNA-seq Counts settings

<!-- WAIT ux-text TV-PSEUDOBULK -->

## Reading the results

### The count table tabs of the bulk view

### The Quality tab of the bulk view

### The Correlation tab of the bulk view

<!-- SHOT: rnaseq-correlation-tab -->

### The RNA-seq export folder

### The Inspector on an RNA-seq result

<!-- WAIT ux-text TV-INSPECT -->

## What good looks like

## On the command line

## Next
