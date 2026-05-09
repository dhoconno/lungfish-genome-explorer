---
title: Exporting as Nextflow or Snakemake
chapter_id: 08-workflows/02-exporting-as-nextflow-or-snakemake
audience: analyst
prereqs: [01-foundations/08-provenance-and-reproducibility, 08-workflows/01-the-workflow-builder]
estimated_reading_min: 8
task: Export a Lungfish workflow as Nextflow or Snakemake for sharing and external execution.
tags: [workflows, export, nextflow, snakemake, methods]
tools: [nextflow, snakemake]
entry_points:
  - "File > Export > Provenance > Nextflow"
  - "File > Export > Provenance > Snakemake"
shots: []
planned_shots:
  - id: export-provenance-submenu
    caption: "The File > Export > Provenance submenu showing the four export targets."
  - id: nextflow-export-main-nf
    caption: "The generated main.nf opened in a text editor, with the four-process reads-to-variants pipeline visible."
illustrations: []
glossary_refs: [methods-export, provenance, provenance-sidecar, reproducibility]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A Lungfish workflow does not have to stay inside Lungfish. Once you have run a
pipeline and you are happy with it, the **File > Export > Provenance** submenu
emits the same workflow as a runnable artifact you can hand to a collaborator,
commit to a git repository, or feed to a cluster scheduler. Four targets are
available, and they are derived from the same provenance records the app
already keeps for every operation. That means the exported pipeline describes
the exact tool versions and command lines that ran, not a reconstruction.

The four targets sit on a spectrum from "executable on a cluster" to "ready to
paste into a paper". Pick the target that matches what your collaborator (or
your future self) needs to do with it.

| Target | Files emitted | Best for |
|---|---|---|
| Nextflow | `main.nf`, `nextflow.config`, `provenance/` | Re-running on an HPC or cloud cluster with a Nextflow-aware scheduler |
| Snakemake | `Snakefile`, `config.yaml`, `provenance/` | Re-running under an existing Snakemake-based group convention |
| Shell | `run.sh`, `provenance/` | Local re-run, debugging, or stepping through one command at a time |
| Methods Section | `methods.md`, `provenance/` | Pasting a tool-and-version paragraph into a paper |

Every export is a single folder. Every export contains a `provenance/`
subdirectory holding the original provenance sidecars copied verbatim from the
project, so the export is self-describing even after it leaves your machine.
So what should you do with this? When a collaborator asks "how did you run
this", export the workflow as Nextflow or Snakemake instead of writing them an
email.

## What you will learn

By the end of this chapter you will be able to choose between Nextflow,
Snakemake, shell, and methods-section export depending on your destination,
generate the export from a project's provenance, run the exported pipeline on
a fresh machine, and edit the exported pipeline for collaborators who want to
swap inputs.

## Procedure: export the reads-to-variants workflow as Nextflow

This walkthrough assumes you have completed the SARS-CoV-2 reads-to-variants
workflow from [The Workflow Builder](01-the-workflow-builder.md). That
workflow downloads paired-end reads, maps them with minimap2, primer-trims
with `ivar trim`, and calls variants with iVar. We will export it as a
Nextflow pipeline, look at the generated `main.nf`, and run it from the
command line.

<!-- planned: export-provenance-submenu -->

1. With the project open, choose **File > Export > Provenance > Nextflow**.
2. In the save dialog, name the export folder `reads-to-variants-nf` and
   pick a location outside the project (for example, `~/exports/`). Click
   **Export**.
3. Lungfish writes the export folder and reveals it in Finder.
4. Open `main.nf` in a text editor.
5. Open Terminal in the export folder and run `nextflow run main.nf
   -profile standard`.

<!-- planned: nextflow-export-main-nf -->

The generated `main.nf` declares one Nextflow process per Lungfish operation.
Each process carries the exact command line Lungfish ran, the conda channel
spec for the tool, and a `publishDir` directive that mirrors the project's
output layout. The `nextflow.config` file declares a `standard` profile that
runs locally and a `slurm` profile that submits each process as a SLURM job.
The `provenance/` subdirectory is copied next to the pipeline so anyone
inspecting the export can see, for any output, which input checksums and
which tool version produced it.

## Interpretation: what the export captures, and what it does not

The export is honest about what it is. It captures everything Lungfish itself
controls. It does not capture everything your operating system controls.

What the export captures, by reading the provenance sidecars:

- The ordered list of operations, with each step's inputs, outputs, and
  resolved command line.
- The tool name and version string for each step (for example,
  `minimap2 2.28-r1209` rather than just `minimap2`).
- The conda channel and package name for each tool, so a fresh
  `nextflow run` resolves the same package family.
- Input file checksums (SHA-256), so a downstream re-run can verify that the
  inputs match.
- The Lungfish app version and the plugin pack versions in effect when the
  workflow ran.

What the export does not capture, and where the honest limits sit:

- The full transitive conda dependency hash. The export pins the top-level
  tool version. It does not pin every shared library that conda resolved
  underneath. A re-run six months later may pull a newer `htslib`
  underneath `samtools` and produce output that is logically equivalent but
  not bit-identical.
- The exact host CPU microarchitecture. Tools that compile SIMD paths at
  install time (BWA-MEM2, for instance) may take a different code path on
  the collaborator's machine.
- Reads that originated from an SRA download. The export references the
  accession; it does not bundle the FASTQ. A collaborator running the
  export needs network access to NCBI or ENA, or needs a local cache.

If your collaborator needs the strongest possible reproducibility, export as
Nextflow and pair the export with the OCI image Lungfish builds when you run
**File > Export > Provenance > Container Image**. The OCI image pins every
transitive dependency by content hash. The Nextflow export then resolves
tools against the image rather than against conda, and re-runs are
bit-identical across machines.

## Procedure: hand off to a collaborator on a different OS

The export is a plain folder. It travels through any channel you would use
for a small code repository.

1. Initialise a git repository inside the export folder with `git init &&
   git add . && git commit -m "Initial export"`.
2. Push to a shared host (GitHub, GitLab, an institutional GitLab, or a
   bare repository on a shared filesystem).
3. The collaborator clones the repository, installs Nextflow (`curl -s
   https://get.nextflow.io | bash`), and runs `nextflow run main.nf
   -profile standard`.

If the collaborator is on Linux and you exported from macOS, the export
itself is portable: `main.nf`, `nextflow.config`, and `provenance/` are all
plain text. The portability question is the underlying tools, not the
pipeline. Nextflow's conda integration handles the platform difference for
the tools Lungfish ships, because every tool in the default plugin packs
exists in bioconda for both `osx-arm64` and `linux-64`. If the collaborator
is on a Linux cluster without internet access on compute nodes, ship the OCI
image alongside the export and switch the Nextflow profile to use it.

## Procedure: edit the export so a collaborator can swap inputs

The most common edit is "run this exact pipeline against my reads, not
yours". The exported `main.nf` exposes inputs at the top of the file as
parameters, with defaults set to the inputs you ran in Lungfish:

```groovy
params.reads_r1 = "${projectDir}/inputs/SRRxxxxxxx_1.fastq.gz"
params.reads_r2 = "${projectDir}/inputs/SRRxxxxxxx_2.fastq.gz"
params.reference = "${projectDir}/inputs/MN908947.3.fasta"
params.primer_bed = "${projectDir}/inputs/qiaseq.bed"
params.outdir    = "results"
```

A collaborator who wants to run the pipeline against their own reads
overrides those parameters at the command line:

```sh
nextflow run main.nf \
  --reads_r1 my_sample_1.fastq.gz \
  --reads_r2 my_sample_2.fastq.gz \
  -profile standard
```

The Snakemake export uses the same convention, with parameters in
`config.yaml` that the collaborator overrides via `--config`. The shell
export uses positional environment variables documented at the top of
`run.sh`. The methods-section export does not parameterise anything; it is
prose.

## Interpretation: which target to pick

The four targets answer four different questions.

Pick **Nextflow** when the collaborator already runs Nextflow pipelines, when
the destination is a cluster with a Nextflow-aware scheduler (SLURM, PBS,
SGE, AWS Batch, Google Batch), or when you want the workflow to live in a
git repository that other tooling will discover. Nextflow's resume semantics
also matter when the workflow is long and steps are expensive: a failed run
restarts from the failed process, not from the beginning.

Pick **Snakemake** when the collaborator's group already has Snakemake
conventions and the export needs to drop into an existing
`workflow/Snakefile` layout. Lungfish's Snakemake export uses the modern
`workflow/` directory convention and writes a `config/config.yaml` rather
than inlining configuration. Per-rule conda environments are written into
`workflow/envs/`.

Pick **Shell** when you want to debug the pipeline one command at a time, or
when the destination is a single workstation with no scheduler. The shell
export is also the easiest to read if you are trying to understand what
Lungfish actually did under the hood: every command line is on one line,
in order, with comments naming the originating Lungfish operation.

Pick **Methods Section** when you are writing a paper. The methods export
emits one Markdown paragraph that names each tool, its resolved version, and
the parameters that differed from defaults, in the order the workflow ran
them. The paragraph is suitable for pasting under a "Bioinformatics
analysis" subhead with no rewriting. The accompanying `provenance/` folder
serves as the supplementary material that backs every claim in the
paragraph.

You can run more than one export from the same project. The exports are
independent folders and do not overwrite each other. A common pattern is to
run **Nextflow** for the cluster, **Methods Section** for the paper draft,
and **Shell** for your own debugging, all from the same provenance.

## Next

This is the last chapter in [Workflows](.). See [the appendices](../appendices/)
for CLI reference, keyboard shortcuts, and the troubleshooting guide.
