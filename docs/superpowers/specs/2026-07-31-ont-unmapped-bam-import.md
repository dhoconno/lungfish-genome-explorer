# ONT Unmapped BAM Import

**Date:** 2026-07-31
**Status:** Approved

## Goal

Allow an unmapped BAM file to be selected anywhere Lungfish accepts ONT read files. Lungfish converts the BAM to a temporary compressed FASTQ and then uses the existing FASTQ recipe and import pipeline unchanged.

## User experience

- File pickers, drag and drop, Import Center, and `lungfish import fastq` accept `.bam` files as ONT read inputs.
- Each BAM is treated as one single-end ONT sample. Its filename stem becomes the default sample name.
- BAM selection preselects Oxford Nanopore in the import sheet. A BAM import is rejected if another platform is selected.
- Directory imports discover BAM files alongside FASTQ files.
- The existing recipe, quality, compression, and bundle options remain available.

## Processing

Immediately after creating the per-sample import workspace, the importer materializes a BAM input as a temporary `fastq.gz`:

1. The managed `samtools fastq` runtime writes all primary reads to one temporary FASTQ. Lungfish does not perform a separate scan for mapped records.
2. The managed `pigz` runtime compresses that FASTQ to `fastq.gz`.
3. The resulting temporary file replaces the BAM only for the existing recipe and ingestion stages.
4. The workspace and both temporary files are removed by the importer’s existing cleanup.

FASTQ behavior is unchanged. Paired BAM inputs and mixed BAM/FASTQ pairs are not introduced.

## Provenance

The original BAM—not the temporary FASTQ—is the durable scientific input. The output bundle records:

- the BAM path, checksum, and size;
- the exact `samtools fastq` and `pigz` arguments, tool versions, runtime identity, timing, exit status, and useful stderr;
- the temporary FASTQ materialization steps before the existing recipe and ingestion steps;
- all existing import options and resolved defaults.

Temporary paths may appear in step-level execution records, while the top-level replay command remains the original `lungfish import fastq <input.bam> --platform ont ...` command.

## Errors and safeguards

- BAM with a non-ONT platform produces a clear input error before conversion.
- A BAM used as R2 or paired with another file is rejected.
- Missing managed `samtools` or `pigz`, conversion failure, compression failure, or an empty output stops the import without publishing a bundle.
- No validation pass is added to determine whether records are mapped; “unmapped BAM” is the expected use case.

## Verification

Tests cover BAM discovery and naming, ONT-only validation, GUI routing/platform selection, conversion command construction, cleanup, and provenance. An integration fixture verifies that a small BAM produces the expected imported reads and that its final bundle identifies the BAM as the original input.
