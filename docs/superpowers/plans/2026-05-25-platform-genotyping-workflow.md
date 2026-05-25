# Platform-Neutral Amplicon Genotyping Implementation Plan

## Phase 1 - Request and CLI Seam

- Add workflow mode/read-type enums in LungfishWorkflow.
- Extend the current genotyping request to carry multiple input FASTQ bundles, optional barcode definitions, mode, and read-type override while preserving the legacy initializer.
- Add `fastq genotype` CLI command.
- Make `fastq ont-barcode-genotype` delegate through ONT barcode-demux mode.

## Phase 2 - Illumina Input Preparation

- Add an `illumina-amplicon-merge` FASTQ import recipe that merges paired-end amplicon reads and emits a clumpified single-read sample bundle before genotyping.
- Resolve Illumina genotyping samples from prepared single-FASTQ bundles or single FASTQ files.
- Prefix staged read names with a sanitized sample identifier for downstream sample assignment.
- Write a sample manifest and barcode-placeholder file into the support directory for workbook compatibility.

## Phase 3 - Mode-Aware Execution

- Use `map-ont`/`PL:ONT` and barcode demux filter for ONT.
- Use `sr`/`PL:ILLUMINA` and query-prefix sample assignment for prepared Illumina sample bundles.
- Do not require both-end softclips for Illumina merged reads.
- Preserve haplotype analysis and workbook output in the existing result bundle.

## Phase 4 - Provenance

- Record mode, requested/resolved read type, input count, prepared Illumina sample bundle payload descriptors, sample manifest, and all final outputs.
- Keep R1/R2 merge stats in the FASTQ import provenance for the prepared sample bundles.
- Keep BAMs as transient alignment outputs and remove them after provenance has checksummed them.

## Phase 5 - GUI

- Rename the enabled workflow to Amplicon Genotyping.
- Add mode/read-type segmented pickers in Workflow Operations.
- Make barcode definition required only for ONT barcode-demux mode.
- Allow multiple prepared FASTQ inputs for Illumina sample-bundle mode.
- Build GUI CLI invocations through `fastq genotype`.

## Phase 6 - Tests and Build

- Add CLI parse tests for the new seam.
- Add request/provenance tests for prepared Illumina sample-bundle mode with synthetic data.
- Add GUI state tests for mode-specific readiness.
- Run focused Swift tests and produce a debug app build.
