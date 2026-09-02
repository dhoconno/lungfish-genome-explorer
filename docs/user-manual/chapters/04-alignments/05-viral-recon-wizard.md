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
    caption: "The Viral Recon wizard showing its four controls: inputs, primer scheme, minimum mapped reads, and readiness."
illustrations: []
glossary_refs: [primer-scheme, provenance, workflow]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

The Viral Recon wizard wraps the supported `nf-core/viralrecon` workflow so a SARS-CoV-2 amplicon run delivers the standard pipeline outputs in one shot: mapping, primer trimming, variant calls, consensus sequences, and workflow reports. Lungfish builds the input samplesheet for you from FASTQ bundles, obtains the reference, stages the primer files, writes a `.lungfishrun` bundle, and launches the run through Nextflow.

Viral Recon requires **Docker Desktop**. It is the only execution profile that reaches a working run, so the wizard offers no executor choice and the launch path refuses any other.

The wizard is **SARS-CoV-2-specific**, not a general viral pipeline. The reference is always `MN908947.3`, the protocol is always **amplicon**, and a SARS-CoV-2 primer scheme is **required** to run. For a non-SARS amplicon virus, or a shotgun protocol, this GUI wizard is the wrong tool. Build a samplesheet and use the CLI, or assemble the individual mapping, primer-trim, and variant-calling steps yourself.

The GUI lives next to the mappers. There is no "Workflows" menu in Lungfish. You reach Viral Recon at `Tools > FASTQ/FASTA Operations > Mapping…`, then by clicking the **Viral Recon** tool row in the Mapping category, the same dialog where you pick minimap2 or BWA-MEM2. The separate top-level "Workflow Operations…" item is the generic Nextflow/Snakemake runner, not this wizard.

This is a workflow-level path, not a stand-in for the mapping and primer-trimming chapters. Reach for the wizard when you already know the protocol is SARS-CoV-2 amplicon and want a reproducible end-to-end run. Reach for the individual Lungfish mapping, primer-trim, and variant-calling dialogs when you want to inspect or tune each step as you go.

In practice, if your run is SARS-CoV-2 amplicon and you want consensus plus variants in a single pass, open the wizard, pick a primer scheme, and run.

For release-level tool versions and the current supported workflow pin, see [Tool Versions](../appendices/tool-versions.md#appendix-tool-versions). For citations, see [Tool Bibliography](../appendices/bibliography.md#appendix-bibliography).

## Inputs

The GUI wizard and the CLI take different input shapes, and confusing the two is a common mistake. In the **GUI** you select one or more Lungfish FASTQ bundles or files, and the wizard *generates* the viralrecon samplesheet internally; you never write one. On the **CLI** you supply a samplesheet you wrote yourself.

The wizard reads the platform off the reads themselves and shows it as static text under the input summary. A **Platform** control offering Illumina or Nanopore appears only when that detection fails, so most runs never see it.

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

There is no reference control. Viral Recon always runs against `MN908947.3`, because every bundled primer scheme is written against that accession and would not apply to another genome.

Lungfish obtains the reference for you. It uses `Downloads/MN908947.3.lungfishref` when the project already holds it, and downloads it from NCBI GenBank when it does not. A first run therefore has a short download step, and the readiness line says so rather than appearing stalled. `NC_045512.2` is the same genome under a different accession, but it is never substituted: its FASTA header would not match the primer BED, so trimming would find nothing.

A SARS-CoV-2 primer scheme is required, because the protocol is always amplicon. Choose one from the built-in and project-local `.lungfishprimers` bundles. If none are installed, the wizard shows "No SARS-CoV-2 primer schemes are available." and cannot run. It stages `primers.bed` into the prepared input directory and cuts `primers.fasta` out of the reference, since no bundled scheme ships one.

The wizard checks that the chosen scheme was written against `MN908947.3` and refuses one that was not. Primer scheme structure and import status are documented in [Primer Scheme Bundles](../appendices/primer-schemes.md#appendix-primer-schemes).

## The four controls

The sheet shows four controls, in this order:

1. **Inputs.** A read-only summary of the FASTQ bundles you selected, with the detected platform below it.
2. **Primer Scheme.** The scheme menu, with its accession, primer count and amplicon count.
3. **Minimum mapped reads.** A stepper, default 1000. A sample with fewer mapped reads is dropped from the run.
4. **Readiness.** What is still missing, or confirmation that the run can start.

A collapsed **Advanced** group sits above Readiness. It carries a **Choose GFF...** button for a replacement annotation, and an extra-parameters field.

Type extra parameters the way you would on a command line, for example `--variant_caller bcftools --skip_fastqc true`. Names are checked against the pipeline schema before the run starts, so a misspelling is refused at the sheet instead of failing minutes into a run. Parameters the wizard owns, such as `input`, `primer_bed` and `genome`, are refused with the control that owns them named.

## Procedure

Prepare the run:

1. Open the project that contains the FASTQ bundles and select them in the sidebar.
2. Choose `Tools > FASTQ/FASTA Operations > Mapping…`, then click the **Viral Recon** tool row. The wizard opens.
   <!-- planned: viral-recon-tool-row -->
3. Confirm the FASTQ inputs. The detected platform appears below the summary; a Platform control appears only if detection failed.
4. Choose the SARS-CoV-2 primer scheme. This is required, and the wizard will not run without it.

Finish the run:

1. Set the minimum mapped reads if 1000 does not suit your data.
2. Open **Advanced** only if you need a replacement GFF or an extra pipeline parameter.
3. Read the Readiness line. It names whatever is still missing, including a reference that has to be downloaded first.
4. Click **Run**. Lungfish writes the `.lungfishrun` bundle and launches Nextflow from it.

<!-- planned: viral-recon-wizard-overview -->

Everything else is a default you never see. The wizard applies these:

| Setting | Default |
|---|---|
| Executor | Docker |
| Workflow version | 3.0.0 |
| Reference | `MN908947.3` |
| Variant caller | iVar |
| Consensus caller | BCFtools |
| Memory | 8.GB |

To change any of them, type the matching parameter into the Advanced field, for example `--consensus_caller ivar` or `--max_memory 16.GB`.

Stages map to viralrecon `skip_*` parameters. Assembly and Kraken2 are skipped by default; run them with `--skip_assembly false` or `--skip_kraken2 false`.

| Stage | Parameter | Default |
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

Freyja lineage abundance and its bootstrap are always skipped and cannot be re-enabled. The pipeline pins Freyja to an amd64-only container whose bootstrap workers are killed on Apple Silicon, which fails the whole run after every other output has been written. Lungfish runs Freyja natively from the wastewater-surveillance pack instead.

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
| `--executor <profile>` | Select the Nextflow execution profile. Only `docker` works; `conda` and `local` are parsed and then refused. |
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
  --executor docker \
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
