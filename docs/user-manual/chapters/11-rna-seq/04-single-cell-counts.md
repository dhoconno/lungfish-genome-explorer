---
title: Single-Cell RNA-seq Counts
chapter_id: 11-rna-seq/04-single-cell-counts
audience: bench-scientist
prereqs: [11-rna-seq/01-what-is-rna-seq]
estimated_reading_min: 28
task: Import Cell Ranger or STARsolo counts, plan a STARsolo run, read the single-cell view, pseudobulk cells by label, and export the counts for Seurat or Scanpy.
tags: [rna-seq, single-cell, cell-ranger, starsolo, barcodes, umi, pseudobulk, seurat, scanpy, ambient-rna]
tools: [star]
parameters_refs: []
entry_points:
  - "Import Center > Sequencing Reads > Single-cell Counts"
  - "Import Center > Sequencing Reads > Single-cell Plan for a Linux Machine"
  - "Open an RNA-seq result from the sidebar"
  - "Tools > RNA-seq > Pseudobulk RNA-seq Cells…"
  - "Tools > RNA-seq > Export RNA-seq Counts…"
  - "CLI: lungfish-cli import rnaseq, lungfish-cli rnaseq solo-plan, lungfish-cli rnaseq pseudobulk, lungfish-cli rnaseq export"
shots:
  - id: single-cell-counts-import-sheet
    caption: "The sheet the Single-cell Counts card of the Import Center opens, with the STARsolo folder of the pbmc_1k_v3 fixture chosen."
  - id: single-cell-view
    caption: "The pbmc_1k_v3 single-cell result open in its viewer, with the cell summary, the quality table, the rank plot, and the histograms of UMIs and genes per cell."
  - id: pseudobulk-dialog
    caption: "The Pseudobulk RNA-seq Cells pane of the Workflow Operations dialog with the pbmc_1k_v3 result and its labels table chosen."
illustrations: []
glossary_refs: [umi, barcode, cdna, library-prep, read, reference-genome, bam, sample-sheet, import-center, operations-panel, tsv]
features_refs: [import.rnaseq-counts, import.rnaseq-plan, viewport.rnaseq-result, rnaseq.pseudobulk, rnaseq.export]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Importing Cell Ranger or STARsolo counts, planning a STARsolo run, reading the single-cell view, pseudobulking cells, and exporting for Seurat and Scanpy. -->

## What it is

### Cells, barcodes, and UMIs

### Ambient RNA and the not-host flags

## Why you would do this

## Choosing a tool

## Before you start

## Procedure

### Import Cell Ranger or STARsolo counts with the Single-cell Counts card

<!-- SHOT: single-cell-counts-import-sheet -->

### Plan a STARsolo count for a Linux machine

### Pseudobulk cells by label with Pseudobulk RNA-seq Cells

<!-- WAIT ux-text TV-PSEUDOBULK -->

<!-- SHOT: pseudobulk-dialog -->

### Export single-cell counts for Seurat or Scanpy

## Settings

### Single-cell Counts sheet settings

### Single-cell plan sheet settings

### Pseudobulk RNA-seq Cells settings

<!-- WAIT ux-text TV-PSEUDOBULK -->

### Single-cell export settings

## Reading the results

### The single-cell view

<!-- WAIT ux-text TV-SCVIEW -->

<!-- SHOT: single-cell-view -->

### The rank plot of cells by UMIs

### The cells table and its not-host flags

### The Seurat and Scanpy export folder

### The Inspector on a single-cell result

<!-- WAIT ux-text TV-INSPECT -->

## What good looks like

## On the command line

## Next
