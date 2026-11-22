---
title: Demultiplexing by Barcode
chapter_id: 03-reads/09-demultiplexing-barcodes
audience: bench-scientist
prereqs: [01-foundations/02-sequencing-reads, 03-reads/01-importing-fastq]
estimated_reading_min: 26
task: Split a pooled read bundle into one bundle per sample with Demultiplex Barcodes, on any sequencing platform.
tags: [reads, demultiplex, barcodes, dual-index, illumina, nanopore, cutadapt, chance-floor, barcode-scout]
tools: [cutadapt]
parameters_refs: []
entry_points:
  - "Tools > Demultiplexing > Demultiplex Barcodes…"
  - "CLI: lungfish-cli fastq demultiplex"
  - "CLI: lungfish-cli fastq scout"
shots:
  - id: demux-tab-detect-barcodes
    caption: "The Demux tab of the FASTQ drawer for the Illumina dual-index pool after Detect Barcodes read the indexes in the read names, with the plan table and the Demultiplex… button."
  - id: demultiplex-barcodes-pane
    caption: "The Demultiplex Barcodes pane of the FASTQ/FASTA Operations dialog with ONT Native Barcoding V14 (SQK-NBD114-96, 96) chosen for the pooled NRG1 bundle."
  - id: demultiplex-chance-summary
    caption: "The Operations Panel row of a finished Demultiplex Barcodes run on the Illumina pool, with the summary lines about the barcodes found and the chance floor."
illustrations: []
glossary_refs: [barcode, barcode-kit, barcode-scout, demultiplex, cutadapt, adapter, library-prep, read-identifier, paired-end, mate, read-pair, fragment, single-end, interleaved-fastq, ont, minknow, unclassified-reads, virtual-bundle, output-strategy, operations-panel]
features_refs: [fastq.demultiplex]
fixtures_refs: [nrg1-ont-barcoded]
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Splitting a pooled read bundle into one bundle per sample with Demultiplex Barcodes, on every platform. -->

<!-- The demultiplex text moves here from 03-reads/07-ont-runs.md as a text cut (ARCHITECTURE.md rule 5). Each CUT comment names the lines at eaef01d8f that land under its heading. The stub does not carry the cut, which the N-DEMUX W step makes. -->

## What it is

### Barcodes, kits, and dual indexes

## Why you would do this

## Choosing a tool

<!-- CUT from 03-reads/07-ont-runs.md:60-62 and the two Demultiplex Barcodes rows at :69-70, at eaef01d8f -->

## Before you start

## Procedure

<!-- WAIT ux-text TV-SHELL -->

### Check an Illumina pool with Detect Barcodes on the Demux tab

<!-- SHOT: demux-tab-detect-barcodes -->

### Demultiplex an Illumina dual-index pool with the Read Names engine

### Demultiplex a pooled nanopore bundle with Cutadapt

<!-- CUT from 03-reads/07-ont-runs.md:114-128 and :132, at eaef01d8f -->

<!-- WAIT ux-text TV-DEMUX -->

<!-- SHOT: demultiplex-barcodes-pane -->

### Demultiplex with a custom definition and the Exact Bare Barcode engine

<!-- CUT from 03-reads/07-ont-runs.md:130, at eaef01d8f -->

### Demultiplex paired short reads

<!-- CUT from 03-reads/07-ont-runs.md:134-138, at eaef01d8f -->

### Check barcodes with barcode scout before you commit

<!-- CUT from 03-reads/07-ont-runs.md:144-146, at eaef01d8f -->

## Settings

<!-- CUT from 03-reads/07-ont-runs.md:160-176, at eaef01d8f -->

<!-- WAIT ux-text TV-DEMUX -->

<!-- WAIT ux-text TV-HELP -->

## Reading the results

### The chance floor and the run summary

<!-- SHOT: demultiplex-chance-summary -->

### The demultiplex of the pooled nanopore bundle

<!-- CUT from 03-reads/07-ont-runs.md:200-220, at eaef01d8f -->

### Unassigned reads and Keep Unchecked Samples

## What good looks like

<!-- CUT from 03-reads/07-ont-runs.md:240, at eaef01d8f -->

## On the command line

<!-- CUT from 03-reads/07-ont-runs.md:256-266 and the fastq demultiplex sentences of :270, at eaef01d8f -->

## Next
