---
title: Running External Workflows
chapter_id: 08-workflows/03-running-external-workflows
audience: analyst
prereqs: [08-workflows/02-exporting-as-nextflow-or-snakemake]
estimated_reading_min: 9
task: Prepare a local workflow command, understand its output declarations, and inspect or reopen supported .lungfishrun history.
tags: [workflows, nextflow, snakemake, nf-core, runner]
tools: [nextflow, snakemake]
entry_points:
  - "Tools > Workflow Library…"
  - "CLI: lungfish workflow run"
shots: []
planned_shots:
  - id: workflow-operations-runner
    caption: "Workflow Operations showing an enabled imported local package and its configuration controls."
illustrations: []
glossary_refs: [provenance, provenance-sidecar, reproducibility]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

The previous chapter re-emitted a finished Lungfish run as a Nextflow or
Snakemake artifact. This chapter covers the other direction: running an existing
local workflow through `lungfish workflow run` and inspecting its `.lungfishrun`
history and provenance.

In the app, **Tools > Workflow Library…** manages workflow availability.
**Workflow Operations** configures enabled specialized workflows and supported
imported local packages. The supported Viral Recon adapter has a separate
[Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md); use that chapter
for its GUI entry point and supported configuration. The CLI accepts
`nf-core/viralrecon` or `viralrecon` for that adapter.

## What you will learn

You will prepare a local Nextflow or Snakemake command, identify the output
declarations required for execution, read the resulting run bundle, and reopen
a supported previous local configuration for review.

## Procedure: run a local Nextflow or Snakemake file

The same command runs a workflow file straight off disk. The engine is inferred
from the path: a `.nf` extension is treated as Nextflow, and a filename
containing `snakefile` (case-insensitive) is treated as Snakemake.

For existing local workflow files, these planning-only examples create a run
bundle and command preview without launching an engine:

```bash
lungfish workflow run pipeline.nf --results-dir ./example-results --prepare-only
lungfish workflow run Snakefile --results-dir ./example-results --prepare-only
```

For execution, remove `--prepare-only` and supply the inputs and parameters your
workflow requires. You must also declare its actual final outputs with
`--expected-output <path>`, repeated as needed, so Lungfish can attach provenance.
An output declaration does not make the workflow create that file.

For local workflows, Lungfish first uses an available managed engine, then
falls back to its effective `PATH`. Launching a workflow does not install a
missing engine. Relevant flags for `workflow run`:

| Flag | Purpose |
|---|---|
| `--input <path>` | Input file for the run; repeat for multiple inputs. |
| `--params-file <path>` | Load parameters from a JSON file. |
| `--param key=value` | Supply a workflow parameter; repeat per parameter. |
| `--expected-output <path>` | A scientific output that should receive a provenance sidecar; repeat per output. |
| `--cpus <n>` | Retained CPU request; passed as `--cores` for local Snakemake. The local Nextflow adapter does not enforce a per-process CPU limit from this field. |
| `--memory <size>` | Retained memory request. The local adapters do not enforce a memory ceiling from this field. |
| `--workdir, -w <dir>` | Passed as Nextflow `-work-dir`; retained in local Snakemake history without a separate launch option. Engine execution uses the results directory. |
| `--resume` | Adds Nextflow `-resume`; retained in local Snakemake history without a separate launch option. |
| `--timeout <minutes>` | Accepted but not enforced by the local runner; rejected for nf-core runs. |
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

## Run Again: inspect a previous local configuration

In **Workflow Operations**, choose **Open Previous Run…** and select a
`.lungfishrun` folder. This also works after restarting Lungfish. A terminal
local workflow row in Operations offers **Run Again…** in its context menu.
Both entry points load the saved configuration and its bound provenance.

Run Again currently supports imported local packages that fit the existing
reference-plus-one-FASTQ configuration controls without dropping saved options.
Completed, failed and cancelled histories can be inspected. Older histories
without a bound configuration, unfinished attempts and unsupported settings
explain why they cannot be repeated. Use a new configuration when you need to
change settings that the restored form keeps fixed.

The form shows the source run, package name and version, retained inputs, core
count and a fresh output location. The previous run and its results stay intact.
For missing sources, use **Open Workflow Library…**, the reference chooser or
**Locate Original Reads…**. Relocated copies must retain the original bytes.
**Open Tool Setup…** opens the existing runtime management surface.

Choose **Check Configuration** after repairing a source or choosing a new output
parent. It checks the current package registration, retained package and input
identity, runtime, settings and destination. Missing or changed inputs and
occupied or overlapping output locations remain blocked. Checking does not
launch a workflow. The output name and core count remain fixed in this mode.

Choose **Run** only after the check succeeds. Lungfish validates the captured
configuration and originating window again before starting a new operation with
its own run bundle, output directory and provenance. Read-only projects permit
configuration inspection but cannot start a scoped write. Closing or replacing
the configuration during validation prevents launch. Cancellation remains in
progress until the worker drains, and does not become a successful result or a
failure dialog merely because a late process result arrives.

## Next

This is the last chapter in [Workflows](.). See
[the appendices](../appendices/) for CLI reference, keyboard shortcuts, and the
troubleshooting guide.
