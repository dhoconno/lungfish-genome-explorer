---
title: Viral Recon Wizard (SARS-CoV-2)
chapter_id: 04-alignments/05-viral-recon-wizard
audience: bench-scientist
prereqs: [01-foundations/03-amplicon-vs-shotgun, 03-reads/01-importing-fastq, 04-alignments/03-primer-trimming]
estimated_reading_min: 9
task: Run nf-core/viralrecon from Lungfish for a SARS-CoV-2 amplicon consensus and variant workflow.
tags: [alignments, workflows, viralrecon, nf-core, nextflow, amplicon, consensus, sars-cov-2]
tools: [nextflow, nf-core/viralrecon]
entry_points:
  - "Tools > FASTQ/FASTA Operations > Mapping…, then the Viral Recon tool row"
  - "CLI: lungfish workflow run nf-core/viralrecon"
shots: []
planned_shots:
  - id: viral-recon-tool-row
    caption: "The FASTQ/FASTA Operations dialog, Mapping category, with the Viral Recon tool row selected."
  - id: viral-recon-wizard-overview
    caption: "The Viral Recon wizard with FASTQ inputs, reference, primer scheme, callers, and executor selected."
illustrations: []
glossary_refs: [primer-scheme, provenance, workflow]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

The Viral Recon wizard wraps the supported `nf-core/viralrecon` workflow so a SARS-CoV-2 amplicon run delivers the standard pipeline outputs in one shot: mapping, primer trimming, variant calls, consensus sequences, and workflow reports. Lungfish builds the input samplesheet for you from FASTQ bundles, stages the reference and primer files, writes a `.lungfishrun` bundle, and launches the run through Nextflow with the executor you choose.

The wizard is **SARS-CoV-2-specific**, not a general viral pipeline. Its own subtitle reads "SARS-CoV-2 consensus and variant analysis from FASTQ bundles." The reference is either the built-in SARS-CoV-2 genome (`MN908947.3`) or a Local FASTA, the protocol is always **amplicon**, and a SARS-CoV-2 primer scheme is **required** to run: a readiness gate, not an optional extra. For a non-SARS amplicon virus, or a shotgun protocol, this GUI wizard is the wrong tool. Build a samplesheet and use the CLI, or assemble the individual mapping, primer-trim, and variant-calling steps yourself.

The GUI lives next to the mappers. There is no "Workflows" menu in Lungfish. You reach Viral Recon at `Tools > FASTQ/FASTA Operations > Mapping…`, then by clicking the **Viral Recon** tool row in the Mapping category, the same dialog where you pick minimap2 or BWA-MEM2. The separate top-level "Workflow Operations…" item is the generic Nextflow/Snakemake runner, not this wizard.

This is a workflow-level path, not a stand-in for the mapping and primer-trimming chapters. Reach for the wizard when you already know the protocol is SARS-CoV-2 amplicon and want a reproducible end-to-end run. Reach for the individual Lungfish mapping, primer-trim, and variant-calling dialogs when you want to inspect or tune each step as you go.

In practice, if your run is SARS-CoV-2 amplicon and you want consensus plus variants in a single pass, open the wizard, set the reference and a primer scheme, pick an executor, and run.

For release-level tool versions and the current supported workflow pin, see [Tool Versions](../appendices/tool-versions.md#appendix-tool-versions). For citations, see [Tool Bibliography](../appendices/bibliography.md#appendix-bibliography).

## Inputs

The GUI wizard and the CLI take different input shapes, and confusing the two is a common mistake. In the **GUI** you select one or more Lungfish FASTQ bundles or files, and the wizard *generates* the viralrecon samplesheet internally; you never write one. On the **CLI** you supply a samplesheet you wrote yourself.

In the GUI, choose how the wizard treats the platform:

| Setting | What the wizard does |
|---|---|
| Platform auto | Detects the platform from the reads (passes no explicit platform). |
| Illumina | Forces `platform=illumina`. |
| Nanopore | Forces `platform=nanopore`. |

The wizard refuses a mixed-platform selection outright. Feed it bundles that mix Illumina and Nanopore reads and it raises a mixed-platforms error rather than guess, so keep one platform per run.

The CLI path is the one that requires exactly one samplesheet you supply:

```bash
lungfish workflow run nf-core/viralrecon \
  --input samplesheet.csv \
  --results-dir ./Analyses/viralrecon-results \
  --expected-output ./Analyses/viralrecon-results \
  --bundle-root ./Analyses
```

`viralrecon` is accepted as shorthand for `nf-core/viralrecon`.

## Reference and Primers

The wizard has two reference modes:

| Mode | Behavior |
|---|---|
| SARS-CoV-2 Genome | Uses the catalog default SARS-CoV-2 accession (`MN908947.3`) as the viralrecon genome parameter. |
| Local FASTA | Stages a FASTA you choose into the run inputs, with an optional **Choose GFF…** picker to stage a matching annotation. |

A SARS-CoV-2 primer scheme is required, because the protocol is always amplicon. Choose one from the built-in and project-local `.lungfishprimers` bundles. If none are installed, the wizard shows "No SARS-CoV-2 primer schemes are available." and cannot run. It stages `primers.bed`, and `primers.fasta` when the scheme carries it, into the prepared input directory.

Two scheme-related gates can catch you out. First, the wizard checks that your reference accession is compatible with the chosen scheme and rejects an unknown or mismatched one. Second, if the selected scheme carries no bundled `primers.fasta`, the wizard cannot derive primer sequences from the accession alone and needs a local FASTA to derive them. You do not have to leave SARS-CoV-2 Genome mode to satisfy this. When the scheme lacks bundled primers, a local FASTA picker with a **Choose FASTA...** button appears below the accession field; pick a SARS-CoV-2 FASTA there and the gate clears while the mode stays on SARS-CoV-2 Genome. Primer scheme structure and import status are documented in [Primer Scheme Bundles](../appendices/primer-schemes.md#appendix-primer-schemes).

## Procedure

Prepare the run:

1. Open the project that contains the FASTQ bundles and select them in the sidebar.
2. Choose `Tools > FASTQ/FASTA Operations > Mapping…`, then click the **Viral Recon** tool row. The wizard opens.
   <!-- planned: viral-recon-tool-row -->
3. Confirm the FASTQ inputs and set the platform (Platform auto, Illumina, or Nanopore). Keep one platform per run.
4. Choose the reference mode. For a local reference, select the FASTA and, if you have one, click **Choose GFF…** to stage the annotation.

Finish the run:

1. Choose the SARS-CoV-2 primer scheme. This is required; the wizard will not run without it.
2. Pick the executor: Docker (the default), Conda, or Local. Docker and Conda are the usual reproducible choices; Local is for machines where the required tools are already installed and managed outside Lungfish.
3. Review CPUs, memory, minimum mapped reads, variant caller, consensus caller, and skip toggles. The defaults sit in the table below; the skip toggles default to skipping Assembly and Kraken2. The CPU and memory steppers are capped by your host's core count.
4. Click **Prepare** or **Run**. Prepare-only writes the `.lungfishrun` bundle and prints its path. Run launches Nextflow from that bundle.

<!-- planned: viral-recon-wizard-overview -->

The wizard opens with these defaults:

| Setting | Default |
|---|---|
| Executor | Docker |
| Workflow version | 3.0.0 |
| Minimum mapped reads | 1000 |
| Memory | 8.GB |
| Variant caller | iVar |
| Consensus caller | BCFtools |

The **Variant caller** picker offers iVar (the default) or BCFtools, and the **Consensus caller** picker offers BCFtools (the default) or iVar. The two selections pass through as the viralrecon `variant_caller` and `consensus_caller` parameters.

Each **Skip Options** checkbox maps to a viralrecon `skip_*` parameter, and checking a box skips that stage. Assembly and Kraken2 are checked by default, so both are skipped unless you clear them. Checking the Variants or Consensus box skips that stage and drops the headline variant or consensus outputs from the run, so leave both clear for a standard consensus-plus-variants pass.

| Toggle | Parameter | Default |
|---|---|---|
| Assembly | `skip_assembly` | Skipped |
| Variants | `skip_variants` | Runs |
| Consensus | `skip_consensus` | Runs |
| FastQC | `skip_fastqc` | Runs |
| Kraken2 | `skip_kraken2` | Skipped |
| fastp | `skip_fastp` | Runs |
| Cutadapt | `skip_cutadapt` | Runs |
| iVar trim | `skip_ivar_trim` | Runs |
| MultiQC | `skip_multiqc` | Runs |

## CLI Procedure

The CLI mirrors the run-bundle adapter used by the GUI. The smallest valid viralrecon invocation is:

```bash
lungfish workflow run nf-core/viralrecon \
  --input samplesheet.csv \
  --results-dir Analyses/viralrecon-results \
  --expected-output Analyses/viralrecon-results \
  --bundle-path Analyses/my-viralrecon-run.lungfishrun
```

Common options:

| Option | Meaning |
|---|---|
| `--executor <profile>` | Select the Nextflow execution profile: `docker`, `conda`, or `local`. |
| `--results-dir <dir>` | Override the workflow output directory. |
| `--expected-output <path>` | Mark a final scientific output that must receive focused provenance. Executed runs require at least one; repeat it for multiple outputs. |
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
  --expected-output Analyses/viralrecon-results \
  --param platform=illumina \
  --param protocol=amplicon \
  --param primer_bed=PrimerSchemes/primers.bed \
  --cpus 8 \
  --memory 16.GB
```

The CLI checks that viralrecon receives exactly one `--input` samplesheet. `--timeout` is not supported for this workflow adapter.

## Outputs and Provenance

The prepared `.lungfishrun` bundle records the workflow name, the requested workflow release, the executor, the bundle paths, the inputs, the parameters, and the output surfaces. The launched workflow writes its Nextflow outputs into the chosen results directory. Lungfish provenance for the run points at the bundle-owned payload paths, not the temporary staging files, so the run stays reviewable after the staging directories are cleaned up.

For methods text, cite both the viralrecon workflow and the tools that show up in the final provenance. `lungfish provenance bibliography <bundle>` can generate a first-pass citation list from any bundle that carries Lungfish provenance.

## Next

Open the resulting variant and consensus outputs in the variant chapters, or continue to [Alignment Quality](04-alignment-quality.md) when you want to inspect a Lungfish-native alignment before variant calling.
