---
title: Viral Recon Wizard
chapter_id: 04-alignments/05-viral-recon-wizard
audience: bench-scientist
prereqs: [01-foundations/03-amplicon-vs-shotgun, 03-reads/01-importing-fastq, 04-alignments/03-primer-trimming]
estimated_reading_min: 9
task: Run nf-core/viralrecon from Lungfish for viral amplicon consensus and variant workflows.
tags: [alignments, workflows, viralrecon, nf-core, nextflow, amplicon, consensus]
tools: [nextflow, nf-core/viralrecon]
entry_points:
  - "Tools > Workflows > Viral Recon"
  - "CLI: lungfish workflow run nf-core/viralrecon"
shots: []
planned_shots:
  - id: viral-recon-wizard-overview
    caption: "The Viral Recon wizard with inputs, reference, primer scheme, callers, and executor selected."
  - id: viral-recon-prepare-only-result
    caption: "A prepared `.lungfishrun` bundle before launch."
illustrations: []
glossary_refs: [primer-scheme, provenance, workflow]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

The Viral Recon wizard wraps the supported `nf-core/viralrecon` workflow for viral sequencing runs where you want the standard pipeline outputs: mapping, primer trimming, variant calls, consensus sequences, and workflow reports. Lungfish prepares the input samplesheet, stages reference and primer files, writes a `.lungfishrun` bundle, and launches the run through Nextflow with the executor you choose.

This is a workflow-level path, not a replacement for the mapping and primer-trimming chapters. Use the wizard when you already know the protocol and want a reproducible end-to-end viral run. Use the individual Lungfish mapping, primer trim, and variant calling dialogs when you want to inspect or tune each step before proceeding.

For release-level tool versions and the current supported workflow pin, see [Tool Versions](../appendices/tool-versions.md#appendix-tool-versions). For citations, see [Tool Bibliography](../appendices/bibliography.md#appendix-bibliography).

## Inputs

The wizard expects FASTQ inputs and prepares the viralrecon samplesheet for you. In the GUI, you select one or more Lungfish FASTQ bundles or files, then choose platform handling:

| Setting | What Lungfish passes through |
|---|---|
| Platform auto | Let the wizard infer the platform when possible. |
| Illumina | Pass `platform=illumina`. |
| Nanopore | Pass `platform=nanopore`. |

The CLI path requires exactly one samplesheet input for viralrecon:

```bash
lungfish workflow run nf-core/viralrecon \
  --input samplesheet.csv \
  --bundle-root ./Analyses
```

`viralrecon` is accepted as shorthand for `nf-core/viralrecon`.

## Reference and Primers

The wizard has two reference modes:

| Mode | Behavior |
|---|---|
| SARS-CoV-2 Genome | Uses the catalog default SARS-CoV-2 reference accession and names it as the viralrecon genome parameter. |
| Local FASTA | Stages the FASTA into the run inputs and optionally stages a matching GFF. |

For amplicon protocols, choose a primer scheme from the built-in and project-local `.lungfishprimers` bundles. The wizard stages `primers.bed` and, when present or derivable, `primers.fasta` into the prepared input directory. Primer scheme structure and import status are documented in [Primer Scheme Bundles](../appendices/primer-schemes.md#appendix-primer-schemes).

## Procedure

Prepare the run:

1. Open the project that contains the FASTQ bundles.
2. Choose `Tools > Workflows > Viral Recon`.
3. Add the FASTQ inputs and confirm the platform.
4. Choose the reference mode. For a local reference, select the FASTA and optional GFF.

Finish the run:

1. Choose the primer scheme if the protocol is amplicon.
2. Pick the executor: Docker, Conda, or Local. Docker and Conda are the normal reproducible choices; Local is for machines where the required tools are already installed and managed outside Lungfish.
3. Review CPUs, memory, minimum mapped reads, variant caller, consensus caller, and skip toggles. The wizard exposes iVar and BCFtools caller choices and defaults to skipping workflow branches Lungfish does not currently surface directly.
4. Click `Prepare` or `Run`. Prepare-only writes the `.lungfishrun` bundle and prints the path. Run launches Nextflow from that bundle.

<!-- planned: viral-recon-wizard-overview -->

## CLI Procedure

The CLI mirrors the run-bundle adapter used by the GUI. The smallest valid viralrecon invocation is:

```bash
lungfish workflow run nf-core/viralrecon \
  --input samplesheet.csv \
  --bundle-path Analyses/my-viralrecon-run.lungfishrun
```

Common options:

| Option | Meaning |
|---|---|
| `--executor <docker|conda|local>` | Select the Nextflow execution profile. |
| `--results-dir <dir>` | Override the workflow output directory. |
| `--bundle-root <dir>` | Let Lungfish create a named `.lungfishrun` bundle under this directory. |
| `--bundle-path <path>` | Write the run bundle at an exact path. |
| `--version <tag>` | Override the supported workflow release. |
| `--workdir <dir>` | Override Nextflow work directory. |
| `--param key=value` | Pass a viralrecon parameter. Repeat for multiple params. |
| `--cpus <n>` | Set `max_cpus`. |
| `--memory <value>` | Set `max_memory`, for example `8.GB`. |
| `--resume` | Resume a previous Nextflow work directory. |
| `--dry-run` | Print the launch plan without starting Nextflow. |
| `--prepare-only` | Build the `.lungfishrun` bundle but do not launch. |

Example:

```bash
lungfish workflow run nf-core/viralrecon \
  --input samplesheet.csv \
  --executor conda \
  --bundle-root Analyses \
  --results-dir Analyses/viralrecon-results \
  --param platform=illumina \
  --param protocol=amplicon \
  --param primer_bed=PrimerSchemes/primers.bed \
  --cpus 8 \
  --memory 16.GB
```

The CLI validates that viralrecon receives exactly one `--input` samplesheet. `--timeout` is not supported for this workflow adapter.

## Outputs and Provenance

The prepared `.lungfishrun` bundle records the workflow name, requested workflow release, executor, bundle paths, inputs, parameters, and output surfaces. The launched workflow writes Nextflow outputs into the chosen results directory. Lungfish provenance for the run points at the bundle-owned payload paths, not temporary staging files, so the run can be reviewed after staging directories are cleaned up.

For methods text, cite both the viralrecon workflow and the tools that appear in the final provenance. `lungfish provenance bibliography <bundle>` can generate a first-pass citation list from any bundle that carries Lungfish provenance.

## Next

Open the resulting variant and consensus outputs in the variant chapters, or continue to [Alignment Quality](04-alignment-quality.md) when you want to inspect a Lungfish-native alignment before variant calling.
