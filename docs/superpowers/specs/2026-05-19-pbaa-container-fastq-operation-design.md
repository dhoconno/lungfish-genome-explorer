# pbAA Container FASTQ Operation Design

**Date:** 2026-05-19
**Status:** Approved for spec review
**Scope:** FASTQ Operations pbAA clustering workflow, container pinning, and reference-bundle output

## Goal

Add a pbAA amplicon clustering operation to the FASTQ Operations surface without using a conda plug-in pack. The operation runs pbAA in pinned public BioContainers through a focused Nextflow workflow, accepts a FASTQ dataset plus a guide FASTA source, and imports pbAA's passed consensus sequences as a `.lungfishref` reference bundle with complete provenance.

This replaces the current Amplicon Genotyping conda pack path, which installs a Linux ELF binary into a macOS conda environment and fails smoke verification on macOS.

## Non-Goals

- Do not keep pbAA as a conda plug-in pack.
- Do not make this a generic arbitrary Nextflow workflow runner.
- Do not convert FASTQ reads to FASTA for pbAA clustering. pbAA `cluster` consumes indexed FASTQ reads and indexed guide FASTA.
- Do not expose every pbAA advanced option in the first implementation.
- Do not discard pbAA raw outputs after wrapping the passed consensus FASTA.

## User Model

The user opens FASTQ Operations, chooses the `CLUSTERING` subgroup, selects `pbAA Amplicon Clustering`, picks one or more demultiplexed HiFi FASTQ datasets, and chooses a guide sequence from either:

- a filesystem FASTA-like file, or
- any `.lungfishref` bundle in the active project.

The operation runs in the Operations Panel. When complete, the primary result is a new `.lungfishref` bundle built from `<prefix>_passed_cluster_sequences.fasta`. The user can inspect the raw pbAA output directory, logs, Nextflow work information, and provenance from the Operations Panel.

## External Tooling

The workflow uses public pinned BioContainers:

- pbAA: `quay.io/biocontainers/pbaa:1.2.0--h9ee0642_0`
- pbAA digest observed during prototype: `sha256:fa48bd65b2e429af09eaf06541030e812e5bb0de440059b9b34a6e49c87edd04`
- samtools: `quay.io/biocontainers/samtools:1.23.1--ha83d96e_0`
- samtools digest observed during spec review: `sha256:23cda33a3a42125872766df9aaf1d2db67cdb8c85314b793465188435af31ba6`

Container pins are versioned with Lungfish Genome Explorer. Each Lungfish release records the pbAA workflow container image tags, expected digests, and workflow schema version in source. Changing a tag, digest, default parameter, output contract, or Nextflow process graph is treated as a versioned workflow change and is reflected in provenance.

At runtime, Lungfish records both the configured pins and the resolved image identities reported by the container runtime/Nextflow where available. If a digest cannot be resolved, provenance must still record the exact configured image reference and the runtime limitation.

## Architecture

### FASTQ Operation Catalog

Add a `clustering` FASTQ operation category/subgroup. Its first tool is `pbAA Amplicon Clustering`.

The tool requires:

- FASTQ dataset input.
- Guide sequence input.

It does not require a conda plug-in pack. Readiness depends on required input selection and the configured container/Nextflow runtime, not on Plugin Manager status.

### Guide Sequence Resolution

The guide picker supports both filesystem FASTA and project `.lungfishref` bundles.

For filesystem inputs, the selected file is staged into the workflow run directory and indexed with `samtools faidx`.

For `.lungfishref` inputs, Lungfish resolves the bundle's stored FASTA payload, stages it into the workflow run directory, and indexes the staged FASTA. Provenance records both the source bundle path and the staged FASTA used by pbAA.

### FASTQ Input Resolution

FASTQ bundles are resolved to their primary FASTQ payloads through the existing FASTQ bundle resolution path. Plain FASTQ files remain valid where the surrounding FASTQ Operations infrastructure already supports them.

The staged read input is indexed with `samtools fqidx` before `pbaa cluster` runs.

### Nextflow Workflow

The pbAA operation owns a focused local Nextflow workflow generated or staged by Lungfish. The workflow has three process responsibilities:

1. Stage and index the guide FASTA with samtools.
2. Stage and index the FASTQ reads with samtools.
3. Run `pbaa cluster <guide fasta> <reads fastq> <prefix>`.

The workflow emits:

- `<prefix>_passed_cluster_sequences.fasta`
- `<prefix>_failed_cluster_sequences.fasta`
- `<prefix>_read_info.txt`
- pbAA intermediate FASTA files such as `<prefix>_reads_<guide>_ecr.fasta`
- logs and Nextflow execution metadata.

The first implementation can run one pbAA clustering job per selected FASTQ dataset. Grouped multi-input batching can be added later if users need FOFN mode.

### Output Import

The primary output is the passed consensus FASTA:

`<prefix>_passed_cluster_sequences.fasta`

Lungfish imports that FASTA as a standalone `.lungfishref` bundle via the existing reference-bundle builder/import path. If the passed FASTA is empty or missing, the operation fails with a user-visible message and leaves the raw pbAA output directory attached to the failed operation for inspection.

The `.lungfishref` bundle provenance must point at the final stored bundle payload, not only the temporary pbAA output FASTA. It must also preserve the upstream pbAA/Nextflow/container provenance so rerunning the bundle is reproducible.

The raw pbAA output directory remains an auxiliary operation artifact for debugging and scientific review. It is not the primary project object.

## Provenance Requirements

The final `.lungfishref` bundle must include provenance that records:

- Lungfish workflow name and workflow schema version.
- Lungfish app/CLI version.
- Exact CLI argv or reproducible command.
- User-visible options and resolved defaults.
- Input FASTQ paths, guide source paths, staged paths, file sizes, and checksums.
- Output `.lungfishref` path and final bundle payload checksums.
- pbAA version and command line.
- samtools version and indexing commands.
- Nextflow version and launch command when available.
- Container image tags and resolved digests for pbAA and samtools.
- Runtime identity, including Docker/Apple Containerization/other executor details.
- Exit status, wall time, and stderr/log excerpts when useful.

Missing provenance is a blocking defect for this operation.

## Plugin Pack Removal

Remove the Amplicon Genotyping/pbAA conda plug-in pack from user-visible pack catalogs and release plugin-pack surfaces. Existing status/history data may continue to display in historical operation logs, but users should no longer be offered pbAA installation/reinstall through Plugin Manager.

Tests must assert that release-visible plugin-pack lists no longer include the pbAA pack and that pbAA appears only as the container-backed FASTQ operation.

## Operations Panel

The Operations Panel entry for pbAA clustering shows:

- selected FASTQ dataset(s),
- selected guide sequence source,
- configured pbAA and samtools container references,
- runtime status,
- indexing progress,
- pbAA command and status,
- output `.lungfishref` bundle path,
- links to raw pbAA outputs and logs.

Failures surface the failing phase: runtime unavailable, container pull failure, guide resolution failure, FASTQ resolution failure, indexing failure, pbAA non-zero exit, empty passed consensus FASTA, or reference-bundle import failure.

## Testing

Unit and integration coverage should include:

- FASTQ catalog exposes `CLUSTERING` and `pbAA Amplicon Clustering`.
- pbAA tool has required FASTQ and guide inputs.
- guide picker accepts FASTA-like files and `.lungfishref` bundles.
- pbaa launch request records selected guide source.
- CLI/runner builds expected Nextflow parameters and container references.
- provenance includes configured image pins and resolved digests where available.
- successful run imports passed consensus FASTA as `.lungfishref`.
- empty/missing passed FASTA produces a clear failure and preserves raw outputs.
- pbAA conda pack is absent from release-visible plugin-pack lists.

Runtime smoke tests should be skipped when Docker/Nextflow is unavailable, but the command construction and provenance contracts must be tested without requiring network or container pulls.

## Prototype Evidence

A local Docker prototype pulled `quay.io/biocontainers/pbaa:1.2.0--h9ee0642_0`, built a temporary pbAA-plus-samtools wrapper image, and successfully ran:

```sh
samtools faidx guide.fasta
samtools fqidx reads.fastq
pbaa cluster -j 1 guide.fasta reads.fastq smoke
```

The run exited successfully and produced pbAA's expected passed FASTA, failed FASTA, read-info table, and intermediate ECR FASTA. This validates that the macOS conda failure is an installation/runtime packaging issue, not a pbAA workflow limitation.
