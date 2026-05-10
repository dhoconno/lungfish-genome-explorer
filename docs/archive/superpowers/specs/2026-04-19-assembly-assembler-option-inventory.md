# Assembly Assembler Option Inventory

Date: 2026-04-19
Status: Working inventory

## Summary

This document grounds the v1 assembly UI in the real parameter surfaces of the five approved assemblers:

- `SPAdes`
- `MEGAHIT`
- `SKESA`
- `Flye`
- `Hifiasm`

The v1 UI remains read-type-driven. It exposes exactly three visible read classes:

- `Illumina short reads`
- `ONT reads`
- `PacBio HiFi`

The shared control vocabulary is intentionally smaller than the union of all upstream flags. Tool-native details remain available behind advanced disclosures only when they fit the approved v1 scope.

## Shared Control Vocabulary

The stable controls that should look and feel the same across the shared assembly pane are:

- `Assembler`
- `Read Type`
- `Project Name`
- `Threads`
- `Output Location`

Capability-scoped primary controls appear only when the selected tool supports the concept:

- `Memory Limit`
- `Minimum Contig Length`
- `Assembly Mode / Profile`
- `K-mer Strategy`
- `Error Correction / Polishing`

## Deliberate V1 Simplifications

- `Flye --pacbio-hifi` is deferred even though upstream Flye supports it.
- `Hifiasm --ont` is deferred even though upstream Hifiasm supports ONT workflows.
- SPAdes hybrid and supplementary long-read flags remain out of v1.
- Hybrid assembly remains out of scope.
- Trio assembly remains out of scope.
- Hi-C-assisted assembly remains out of scope.
- Ultra-long ONT augmentation remains out of scope.
- Standalone polishing workflows remain out of scope.

## Tool Inventory

### `SPAdes`

- Supported v1 read class: `Illumina short reads`
- Allowed input topology in v1:
  - paired-end short reads
  - single-end short reads
- Shared controls:
  - `Assembler`
  - `Read Type`
  - `Project Name`
  - `Threads`
  - `Output Location`
- Capability-scoped controls:
  - `Memory Limit` via `--memory`
  - `Minimum Contig Length` as a Lungfish post-filter
  - `Assembly Mode / Profile` via `--isolate`, `--meta`, `--plasmid`
  - `K-mer Strategy` via `-k`
  - `Error Correction / Polishing` as the inverse `--only-assembler` toggle
- Advanced disclosure controls:
  - `Careful Mode` via `--careful`
  - `Coverage Cutoff` via `--cov-cutoff`
  - `PHRED Offset` via `--phred-offset`
- Explicit v1 deferrals:
  - supplementary long-read input flags such as `--nanopore` and `--pacbio`
  - hybrid assembly modes
  - RNA, biosynthetic, coronaviral, and other specialized pipelines outside the approved v1 read classes

### `MEGAHIT`

- Supported v1 read class: `Illumina short reads`
- Allowed input topology in v1:
  - paired-end short reads
  - interleaved paired-end short reads
  - single-end short reads
- Shared controls:
  - `Assembler`
  - `Read Type`
  - `Project Name`
  - `Threads`
  - `Output Location`
- Capability-scoped controls:
  - `Memory Limit` via `--memory`
  - `Minimum Contig Length` via `--min-contig-len`
  - `Assembly Mode / Profile` via `--presets`
  - `K-mer Strategy` via `--k-list` or `--k-min` / `--k-max` / `--k-step`
- Advanced disclosure controls:
  - preset tuning such as `meta-sensitive` and `meta-large`
  - graph simplification via `--cleaning-rounds`
  - pruning knobs such as `--disconnect-ratio`, `--prune-level`, and `--prune-depth`
  - memory-mode tuning via `--mem-flag`
- Explicit v1 deferrals:
  - metagenome-specific expert tuning beyond the curated preset and pruning surface
  - resume and temp-file maintenance controls

### `SKESA`

- Supported v1 read class: `Illumina short reads`
- Allowed input topology in v1:
  - paired-end short reads
  - interleaved paired-end short reads
  - single-end short reads
- Shared controls:
  - `Assembler`
  - `Read Type`
  - `Project Name`
  - `Threads`
  - `Output Location`
- Capability-scoped controls:
  - `Memory Limit` via `--memory`
  - `Minimum Contig Length` via `--min_contig`
  - `K-mer Strategy` via `--kmer`
- Advanced disclosure controls:
  - paired-read interpretation via `--use_paired_ends`
  - insert-size override via `--insert_size`
  - assembly iteration tuning via `--steps`
  - conservative SNP joining via `--allow_snps`
- Explicit v1 deferrals:
  - SRA-driven input handling
  - debugging or histogram output options
  - non-Illumina-oriented use cases

### `Flye`

- Supported v1 read class: `ONT reads`
- Allowed input topology in v1:
  - one or more ONT long-read FASTQ files of the same class
- Shared controls:
  - `Assembler`
  - `Read Type`
  - `Project Name`
  - `Threads`
  - `Output Location`
- Capability-scoped controls:
  - `Assembly Mode / Profile` as default ONT assembly versus `--meta`
  - `Error Correction / Polishing` via polishing `--iterations`
- Advanced disclosure controls:
  - ONT read-mode selection via `--nano-raw`, `--nano-hq`, or `--nano-corr`
  - estimated genome size via `--genome-size`
  - overlap tuning via `--min-overlap`
  - disjointig coverage control via `--asm-coverage`
  - haplotype or alternate-contig handling via `--keep-haplotypes` and `--no-alt-contigs`
  - optional scaffolding via `--scaffold`
- Explicit v1 deferrals:
  - `--pacbio-hifi`
  - PacBio CLR and corrected PacBio modes
  - mixed read types
  - standalone polishing mode via `--polish-target`

### `Hifiasm`

- Supported v1 read class: `PacBio HiFi`
- Allowed input topology in v1:
  - one or more PacBio HiFi FASTQ files of the same class
- Shared controls:
  - `Assembler`
  - `Read Type`
  - `Project Name`
  - `Threads`
  - `Output Location`
- Capability-scoped controls:
  - `Assembly Mode / Profile` as the default HiFi primary-assembly path only
- Advanced disclosure controls:
  - bloom-filter memory tuning via `-f`
  - purge-duplication control via `-l`
  - primary/alternate output via `--primary`
  - ploidy assumption via `--n-hap`
- Explicit v1 deferrals:
  - `--ont`
  - Hi-C integration via `--h1` and `--h2`
  - trio binning via `-1` and `-2`
  - ultra-long augmentation via `--ul`
  - telomere-specific tuning

## Compatibility Matrix

- `Illumina short reads`
  - enable `SPAdes`
  - enable `MEGAHIT`
  - enable `SKESA`
  - disable `Flye`
  - disable `Hifiasm`
- `ONT reads`
  - enable `Flye`
  - disable `SPAdes`
  - disable `MEGAHIT`
  - disable `SKESA`
  - disable `Hifiasm`
- `PacBio HiFi`
  - enable `Hifiasm`
  - disable `SPAdes`
  - disable `MEGAHIT`
  - disable `SKESA`
  - disable `Flye`

Mixed detected read classes must be blocked with:

`Hybrid assembly is not supported in v1. Select one read class per run.`
