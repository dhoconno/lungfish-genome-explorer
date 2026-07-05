---
title: Running External Workflows
chapter_id: 08-workflows/03-running-external-workflows
audience: analyst
prereqs: [08-workflows/02-exporting-as-nextflow-or-snakemake]
estimated_reading_min: 9
task: Run an nf-core pipeline or a local Nextflow or Snakemake file through the generic workflow runner and read the .lungfishrun bundle it leaves behind.
tags: [workflows, nextflow, snakemake, nf-core, runner]
tools: [nextflow, snakemake]
entry_points:
  - "Tools > Operations > Workflows"
  - "CLI: lungfish workflow run"
shots: []
planned_shots:
  - id: workflow-operations-runner
    caption: "The Tools > Operations > Workflows panel with the nf-core catalogue on the left and a schema-driven parameter form on the right."
illustrations: []
glossary_refs: [provenance, provenance-sidecar, reproducibility]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

The previous chapter re-emitted a finished Lungfish run as a Nextflow or
Snakemake artifact. This chapter is the reverse direction: taking a pipeline
that already exists, an nf-core workflow or a Nextflow or Snakemake file someone
handed you, and running it from inside Lungfish so its outputs land in your
project with provenance attached. The generic runner lives at **Tools >
Operations > Workflows**, and its command-line twin is `lungfish workflow run`.

The runner does two distinct jobs. It launches a curated nf-core pipeline from a
built-in catalogue, building the parameter form for you. And it executes a local
`*.nf` or `Snakefile` you point it at, detecting the engine from the filename.
Either way the run is wrapped in a `.lungfishrun` bundle: a self-describing
folder that records the command, the logs, and a signed provenance envelope.

## What you will learn

Working through this chapter, you will run a catalogued nf-core pipeline through
the Operations runner, drive a local Nextflow or Snakemake file from the command
line, read the `.lungfishrun` bundle the runner produces, and understand which
flags apply to nf-core runs and which apply to local files.

## Procedure: run an nf-core pipeline from the runner

1. Open **Tools > Operations > Workflows**.
2. Choose a pipeline from the nf-core catalogue. The catalogue currently exposes
   a single supported pipeline, nf-core/viralrecon (Viral Recon).
3. Fill in the parameter form. Lungfish builds this form from the pipeline's
   `nextflow_schema.json`, grouping parameters into the collapsible sections the
   schema defines (for example Input/Output or Reference genome).
4. Pick an executor: `docker`, `conda`, or `local`. The runner defaults to
   `docker`.
5. Run the pipeline. Lungfish creates a `.lungfishrun` bundle, invokes Nextflow,
   and imports the recognized outputs back into the project.

Viral Recon takes exactly one input samplesheet. When you set CPU and memory
ceilings for an nf-core run, the runner passes them through as the pipeline's
own `max_cpus` and `max_memory` parameters rather than as per-process limits.

## Procedure: run a local Nextflow or Snakemake file

The same command runs a workflow file straight off disk. The engine is inferred
from the path: a `.nf` extension is treated as Nextflow, and a filename
containing `snakefile` (case-insensitive) is treated as Snakemake.

```bash
lungfish workflow run pipeline.nf --input reads.fastq.gz --cpus 8 --memory 16.GB
lungfish workflow run Snakefile --results-dir ./out --resume
```

Lungfish shells out to the `nextflow` or `snakemake` binary through the system
environment, so the matching engine must already be installed and on your
`PATH`. The runner does not vendor either one. The full flag set for
`workflow run`:

| Flag | Purpose |
|---|---|
| `--input <path>` | Input file for the run; repeat for multiple inputs. |
| `--params-file <path>` | Load parameters from a JSON file. |
| `--expected-output <path>` | A scientific output that should receive a provenance sidecar; repeat per output. |
| `--cpus <n>` | Maximum CPUs per process. |
| `--memory <size>` | Maximum memory per process, for example `8.GB`. |
| `--workdir, -w <dir>` | Working directory for execution. |
| `--resume` | Resume from the last checkpoint. |
| `--timeout <minutes>` | Maximum execution time. Not accepted for nf-core runs. |
| `--dry-run` | Print the resolved plan without executing anything. |
| `--prepare-only` | Create the run bundle and command preview without launching the engine. |
| `--results-dir <dir>` | Output directory for results. Defaults to `./results`. |

Two flags are nf-core-only. `--executor` (the `docker`, `conda`, or `local`
profile) and `--version` (the pipeline release or tag) shape an nf-core run and
are ignored when the argument is a local `*.nf` or `Snakefile`, since a local
file already carries its own engine configuration.

## Interpretation: the run bundle, and the list and validate commands

Every run produces a `.lungfishrun` bundle, printed as the final line on
completion. By default it is created in the current directory under the
workflow's name; `--bundle-root` chooses a parent directory and `--bundle-path`
sets an exact path. Inside the bundle you will find a `manifest.json` that
tracks the run's status history, a `logs/` folder holding `stdout.log` and
`stderr.log`, and a provenance record that Lungfish signs when a signer is
configured. When you name `--expected-output` targets, the same provenance
envelope is also written as a sidecar next to each of those outputs once the run
succeeds.

Two neighbouring subcommands are narrower than they might read. `lungfish
workflow list --nf-core` prints only the supported Viral Recon pipeline; without
the flag it prints a usage hint rather than a project inventory. `lungfish
workflow validate <file>` checks syntax for a `.nf` file or a Snakefile (a
filename containing `snakefile`) and rejects anything else, so it does not accept
a `.yaml` workflow definition. For the exact command grammar, see the
[CLI reference](../appendices/cli-reference.md#workflows).

## Next

This is the last chapter in [Workflows](.). See
[the appendices](../appendices/) for CLI reference, keyboard shortcuts, and the
troubleshooting guide.
