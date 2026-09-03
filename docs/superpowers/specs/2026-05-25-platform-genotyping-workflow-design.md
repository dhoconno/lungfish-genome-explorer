# Platform-Neutral Amplicon Genotyping Workflow

Date: 2026-05-25

## Goal

Replace the ONT-only genotyping entry point with one optional, CLI-backed amplicon genotyping workflow that handles:

- ONT barcode-demux runs: one FASTQ bundle/folder containing a whole barcoded run, with sample assignment from barcode definitions.
- Illumina sample-bundle runs: many prepared per-sample `.lungfishfastq` bundles. R1/R2 overlap merging and clumpification happen first through the CLI-backed FASTQ import recipe `illumina-amplicon-merge`; genotyping consumes the resulting single-read sample bundles.

Both modes write one `.lungfishgenotype` analysis bundle and can optionally apply assay/species-scoped haplotype definitions.

## Expert Review Synthesis

MHC analyst review:

- Illumina sample identity must come from the input bundle/sample name, not from sequence barcode rediscovery.
- Paired-end merge is a scientific step and belongs in FASTQ import provenance. Genotyping provenance must point at the prepared sample bundles and record that no internal R1/R2 merge was performed.
- The post-merge biological filter should stay the same as ONT: full-reference-span alignments, zero substitutions, indels allowed, minimum support threshold.
- ONT-specific softclip assumptions should not be applied to Illumina merged reads.

Swift/AppKit review:

- Add a stable CLI seam, `lungfish fastq genotype`, with explicit mode/read-type options.
- Keep legacy `fastq ont-barcode-genotype` as a wrapper for compatibility.
- In the GUI, expose one enabled workflow as “Amplicon Genotyping” with mode/read-type controls.
- Hide barcode-definition controls for Illumina sample-bundle mode and allow multiple prepared read bundles.

QA review:

- Tests must use synthetic references and synthetic paired bundles, not large committed data.
- Provenance tests are required, including final bundle paths, R1/R2 checksums, read type, mode, merge stats, haplotype snapshot, stderr, exit status, and wall time.

## CLI Contract

New command:

```bash
lungfish fastq genotype INPUT... \
  --mode auto|ont-barcode-demux|illumina-paired \
  --read-type auto|ont|illumina \
  --reference REF \
  --output-dir OUT \
  --output-name NAME
```

ONT mode additionally requires:

```bash
--barcodes BARCODE_CSV [--demux-manifest demux-manifest.json]
```

Illumina sample-bundle mode:

- accepts multiple prepared input `.lungfishfastq` bundles or single FASTQ files,
- requires R1/R2 reads to have already been merged with `lungfish import fastq --recipe illumina-amplicon-merge`,
- prefixes staged read names with the sample identifier for downstream sample assignment,
- records the source sample bundle, resolved FASTQ payload, staged mapping FASTQ, and read count.

Compatibility:

- `lungfish fastq ont-barcode-genotype` remains available and delegates to ONT barcode-demux mode.
- Existing `.lungfishgenotype` result bundles remain readable.

## GUI Contract

Workflow Operations should show one workflow named “Amplicon Genotyping”.

Controls:

- Read type: Auto, ONT, Illumina.
- Mode: Auto, ONT barcode-demux, Illumina sample bundles.
- Barcode definition picker only appears for ONT barcode-demux mode.
- Multiple FASTQ bundles are valid in Illumina sample-bundle mode.
- Haplotype definition controls remain assay/species/source/definition scoped and are passed through CLI options.

## Provenance Requirements

The workflow must write canonical provenance into the final `.lungfishgenotype` bundle. Required fields include:

- workflow/tool name and version,
- exact argv and durable replay argv,
- explicit options and resolved defaults,
- resolved mode and read type,
- all input bundle paths,
- prepared Illumina sample bundle paths, source FASTQ payload paths, staged mapping FASTQs, and checksums,
- reference path/checksum,
- barcode definition and demux manifest checksums for ONT,
- `illuminaInputPreparation` with `internalMergePerformed` reporting whether the run merged pairs itself; when merging happened at import it stays false and the R1/R2 merge parameters and counts live in each prepared FASTQ bundle's import provenance, and when the pipeline merged unmerged input during the run the accompanying `pairMergeSummary` records the counts,
- minimap2/samtools/python/runtime identity,
- output files in the final bundle,
- exit status, wall time, useful stderr.

Missing provenance is a blocking defect.

## Initial Implementation Scope

This iteration implements the new CLI seam, mode-aware request model, GUI controls, and an Illumina sample-bundle branch that consumes prepared merged/clumpified bundles from FASTQ import. It keeps the existing workbook/result-bundle format to avoid breaking the current viewer while removing ONT-only assumptions from Illumina filtering.
