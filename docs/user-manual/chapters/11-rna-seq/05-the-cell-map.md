---
title: The Cell Map
chapter_id: 11-rna-seq/05-the-cell-map
audience: bench-scientist
prereqs: [11-rna-seq/04-single-cell-counts]
estimated_reading_min: 26
task: Import or compute a cell embedding, then color, read, and select cells on the cell map.
tags: [rna-seq, single-cell, cell-map, embedding, umap, tsne, pca, leiden, clusters, scanpy, selection, pseudobulk]
tools: [scanpy, leidenalg, umap-learn, python-igraph]
parameters_refs: []
entry_points:
  - "Tools > RNA-seq > Import Embedding…"
  - "Cell map view > Save Selection as Labels Table…"
  - "Cell map view > Pseudobulk Selected Cells…"
  - "CLI: lungfish-cli rnaseq cell-map import, lungfish-cli rnaseq cell-map compute, lungfish-cli rnaseq cell-map select"
shots:
  - id: import-embedding-dialog
    caption: "The Import Embedding pane of the Workflow Operations dialog with the pbmc_1k_v3 result and the 10x projection and clusters files chosen."
  - id: cell-map-view
    caption: "The pbmc_1k_v3 cell map open on the 10x t-SNE embedding, with the cells colored by the 10x graph clusters and the legend beside the plot."
  - id: cell-map-gene-coloring
    caption: "The same cell map colored by the normalized UMIs of one gene picked with the Gene… search."
  - id: cell-map-selection
    caption: "A lasso selection on the cell map, with the number of selected cells shown and the Save Selection as Labels Table… and Pseudobulk Selected Cells… actions offered."
illustrations: []
glossary_refs: [umi, plugin-pack, conda, managed-environment, pinned, determinism, thread, tsv, inspector, modifier-key, key-equivalent]
features_refs: [rnaseq.cell-map-import, rnaseq.cell-map-compute, rnaseq.cell-map-select, viewport.rnaseq-result]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Importing or computing a cell embedding, and reading, coloring, and selecting cells on the cell map. -->

<!-- WAIT ux-text TV-CELLMAP -->

## What it is

### Embeddings, UMAP, t-SNE, and PCA

### Clusters and Leiden

## Why you would do this

## Choosing a tool

## Before you start

## Procedure

### Import an embedding with Import Embedding

<!-- WAIT ux-text TV-PSEUDOBULK -->

<!-- SHOT: import-embedding-dialog -->

### Compute clusters and a UMAP with rnaseq cell-map compute

### Color cells by label or gene on the cell map

<!-- WAIT ux-text TV-CELLMAP -->

<!-- SHOT: cell-map-gene-coloring -->

### Select cells on the cell map

<!-- WAIT ux-text TV-CELLMAP -->

<!-- SHOT: cell-map-selection -->

### Save a selection as a labels table or pseudobulk the selected cells

<!-- WAIT ux-text TV-PSEUDOBULK -->

## Settings

### Import Embedding settings

<!-- WAIT ux-text TV-PSEUDOBULK -->

### Save Selection as Labels Table settings

### rnaseq cell-map compute options

## Reading the results

### The cell map view

<!-- WAIT ux-text TV-CELLMAP -->

<!-- SHOT: cell-map-view -->

### The captions under the cell map

<!-- WAIT ux-text TV-HELP -->

### The cell map legend

### PHATE coordinates on the cell map

### The Inspector on a cell map result

<!-- WAIT ux-text TV-INSPECT -->

## What good looks like

## On the command line

## Next
