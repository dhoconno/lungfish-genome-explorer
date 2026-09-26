---
title: Exporting as Nextflow or Snakemake
chapter_id: 08-workflows/02-exporting-as-nextflow-or-snakemake
audience: analyst
prereqs: [01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 10
task: Export one artifact's recorded history as a Nextflow pipeline, a Snakemake workflow, a script, a methods draft, or raw JSON.
tags: [workflows, export, nextflow, snakemake, methods, provenance]
tools: [nextflow, snakemake]
parameters_refs: [provenance.export]
entry_points:
  - "File > Export > Provenance > Nextflow Pipeline..."
  - "File > Export > Provenance > Snakemake Workflow..."
  - "Inspector > Provenance section > Export"
  - "CLI: lungfish-cli provenance export <input> --format <format> --output <dir>"
shots:
  - id: export-provenance-submenu
    caption: "The File > Export > Provenance submenu, with the six export targets and the separator after the fourth."
  - id: export-provenance-save-panel
    caption: "The Export Provenance save panel, showing its message and a shortened folder name ending in -provenance-nextflow."
  - id: export-provenance-complete-alert
    caption: "The Provenance Export Complete alert, with its OK and Show in Finder buttons."
  - id: provenance-export-folder
    caption: "The exported provenance folder open in Finder, with the primary artifact beside the provenance subdirectory of copied run records."
  - id: nextflow-export-main-nf
    caption: "The generated main.nf open in TextEdit, showing the process blocks for the selected chr20 reference bundle's import, bgzip, and samtools steps."
illustrations: []
glossary_refs: [bam, checksum, container, methods-export, nextflow, provenance, provenance-sidecar, reproducibility, samtools, snakemake, workflow-engine]
features_refs: []
fixtures_refs: [demo-project]
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. This chapter turns that record into something a person outside LGE can read or run.

The **File > Export > Provenance** submenu offers six targets. The first four can be run, and the last two are for reading. Each writes a folder rather than a single file. The Nextflow and Snakemake files need editing before they run, as [What good looks like](#what-good-looks-like) notes.

| Target | Main file written | Best for |
|---|---|---|
| Shell Script... | `run.sh` | Reading what LGE ran, one command at a time |
| Python Script... | `reproduce.py` | A group that prefers Python to shell |
| Nextflow Pipeline... | `main.nf`, `nextflow.config`, `containers/manifest.json` | A collaborator who already uses Nextflow |
| Snakemake Workflow... | `Snakefile`, `config.yaml` | A group that already uses Snakemake |
| Methods Section... | `methods.md` | Drafting the methods paragraph of a paper |
| Full Provenance (JSON)... | `provenance.json` | Feeding the record to your own tools |

A shell script is a plain text file of terminal commands run top to bottom. [Nextflow](../../GLOSSARY.md#nextflow) and [Snakemake](../../GLOSSARY.md#snakemake) are [workflow engines](../../GLOSSARY.md#workflow-engine), programs that run a pipeline of tools in order on one computer or on a cluster, a shared set of computers a lab or university submits large jobs to.

The export covers one artifact, meaning one file or bundle a tool made, not the whole project. LGE collects every earlier step that fed into the artifact you select, stopping at a file nothing in the project produced, such as an imported FASTQ.

The Nextflow and Snakemake files are faithful records of what ran rather than portable pipelines. They carry the absolute file paths of the machine that ran them, and they need editing by somebody who knows the engine before they run on a second machine.

## Why you would do this

A collaborator asks how you produced a result. You could describe it in an email, which is slow to write and impossible to check, or hand over a folder that names every tool, version, and command in order, with the checksums of the files that went in and came out. The second answer takes one menu choice.

The same holds when a journal asks for the analysis behind a figure, when a manuscript needs a methods paragraph drafted from the versions that actually ran, and when you need to know six months from now which copy of minimap2 made a particular [BAM](../../GLOSSARY.md#bam) file.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

This chapter uses the demo-project fixture. Build it from the instructions in the [demo-project folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/demo-project), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. The example is the project's `Analyses/mapping-HG002` run, which mapped human reads, placing each one at its position on the genome, from a short stretch of HG002 chromosome 20 to the same stretch of the human reference genome with minimap2, a read-mapping tool, and then processed the alignment with [samtools](../../GLOSSARY.md#samtools). HG002 is a well-characterised human genome used for reference datasets. Any finished run in your own project works the same way.

The artifact must have a recorded history. LGE records provenance for files a tool operation made, so a mapping result or an assembly qualifies, and a FASTA you dragged in does not. An artifact with no history produces a **No Provenance Available** alert instead of a save panel, so select a different artifact.

Nothing needs installing to export. Reading an export needs only a text editor. Running a Nextflow or Snakemake export needs that engine on the recipient's machine.

## Procedure

The walkthrough exports the HG002 mapping run as a Nextflow pipeline. Only the menu item changes for the other five targets.

### 1. Select the artifact whose history you want

Expand the `Analyses` folder in the sidebar and select `mapping-HG002`, or click it so it shows in the viewport, the main display area. LGE looks at the visible viewport first and the sidebar selection second. When nothing is selected, LGE falls back to the most recently finished run, so select deliberately.

### 2. Choose the target from the menu

Choose **File > Export > Provenance > Nextflow Pipeline...**. The six targets appear in the order of the table above, with a separator after the fourth.

<!-- SHOT: export-provenance-submenu -->

The Inspector offers the same export. Its Provenance section has an **Export** button in its header, which is the route to use when a reference bundle carries variant tracks, lists of where samples differ from the reference, and you want the record of one track rather than of the whole bundle.

### 3. Name the folder and save it

A save panel titled **Export Provenance** appears, reading "Choose a folder name for the exported reproducibility package." Its name arrives as `<artifact>-provenance-<format>`, here `mapping-HG002-provenance-nextflow`. Choose a location outside the project, such as the Desktop, and click **Save**.

<!-- SHOT: export-provenance-save-panel -->

The format in the name keeps two exports of one artifact from colliding. If a folder of the same name already exists where you save, LGE writes into it and replaces the records it copies, so choose a new name to keep an earlier export intact. If a file of that name exists, LGE refuses the export and names the path.

### 4. Open the folder

A **Provenance Export Complete** alert names the target and the file it wrote, with **OK** and **Show in Finder** buttons. Click **Show in Finder** to open the folder.

<!-- SHOT: export-provenance-complete-alert -->

<!-- SHOT: provenance-export-folder -->

Send the whole folder, compressed into a zip archive. A script pulled out on its own is unlikely to run, because it reads the records beside it. If your collaborator also runs LGE, you can skip the export and hand over the `.lungfish` project itself.

## Settings

**Provenance.** Chooses what the export renders from the selected artifact's history, offering Shell Script..., Python Script..., Nextflow Pipeline..., Snakemake Workflow..., Methods Section..., and Full Provenance (JSON).... There is no default, because you pick a target from the submenu. Pick what the reader needs, a runnable transcription for a collaborator, a methods draft for a manuscript, or the raw JSON for a reviewer. On the command line this is `--format`, with the values `shell`, `python`, `nextflow`, `snakemake`, `methods`, and `json`.

**Save As.** Names the folder that receives the export. The default is the artifact name, `-provenance-`, and the format, so successive exports of one artifact do not collide. Change it when several exports of one artifact and format need telling apart, such as before and after a reanalysis. On the command line `--output` takes this name and the location below as one path.

**Where.** Chooses where the export folder is created, opening at the save panel's last location. Keep the export outside the project, apart from the data it describes. Choose a place you can share, such as a repository checkout, when the export goes to a collaborator. On the command line this is the folder part of the `--output` path.

## Reading the results

### What the export folder holds

Every export folder carries a `provenance/` subfolder beside the main file, and it is worth opening first, because it is correct whichever target you chose. It holds a fresh sidecar for the export itself and, under `provenance/source/`, the sidecars of every earlier step that fed into the artifact. Records from outside the export's own folder land under `provenance/source/external/` with their original path rebuilt as folders. The Nextflow export of the mapping run lays out like this.

```text
mapping-HG002-provenance-nextflow/
  main.nf
  nextflow.config
  containers/manifest.json
  provenance/
    source/
      mapping-provenance.json
      external/Users/.../mapping-HG002/
```

The fields inside each sidecar are listed in [Provenance sidecars](../appendices/file-formats.md#provenance-sidecars).

### What each target file holds

| File | What it holds on the HG002 mapping run |
|---|---|
| `main.nf` | A header naming the run, LGE version, start time, host, and user. One `params` line per file read or written, named from the file name. One process per recorded step, here `MINIMAP2_1` and `SAMTOOLS_2` to `SAMTOOLS_5`, each with a comment naming the tool, its version, and the step's duration, then the exact command. |
| `nextflow.config` | An `errorStrategy = 'terminate'` line and `docker.enabled = true`, with no cluster settings. |
| `containers/manifest.json` | The tool, version, image, and image digest for each step that ran in a [container](../../GLOSSARY.md#container). An empty list here, because every tool came from a conda environment. |
| `Snakefile` | The same header, a usage comment `snakemake --cores 8 --use-singularity`, a `rule all` naming the final outputs, and one rule per step with its log under `logs/`. |
| `config.yaml` | The same file-name keys as the Nextflow parameters, mapped to the recorded paths, plus `outdir: results`. |
| `run.sh` | `set -euo pipefail`, one `INPUT_n` variable per input with its SHA-256 checksum, `OUTDIR`, and each command in order with its tool version. |
| `reproduce.py` | The same in Python, with inputs in an `INPUTS` dictionary keyed by file name. |
| `methods.md` | A draft marked "This is an automatically-generated draft. Read it before submitting.", a Computational Analysis section naming each successful step's tool and version, a Tool Versions table, an Input Files list with checksums, and a Reproducibility paragraph. |
| `provenance.json` | The expanded record as JSON. |

<!-- SHOT: nextflow-export-main-nf -->

Nextflow reads files through `params`, named inputs a user can override, and Snakemake builds everything the `rule all` names. A conda environment is the private folder a tool is installed into, an image is a packaged copy of a tool, and its digest is a fingerprint of one exact build. Parameter names come from file names rather than roles, so nothing in `params.grch38_chr20_10_0_10_5mb_fasta` announces that it is the reference. Read the file before you override a parameter. A version comment reads like `minimap2 2.31 (managed conda environment minimap2; executable minimap2; root /Users/.../.lungfish/conda)`, where the dots stand for the account name of whoever ran the analysis.

A collaborator redirects one input in a Snakemake export by overriding its key, as in `snakemake --cores 8 --config grch38_chr20_10_0_10_5mb_fasta=/data/GRCh38.chr20.fasta`.

The methods draft needs editing. On the HG002 run it names samtools in four nearly identical sentences because four samtools steps ran.

A run made only of steps that copy a saved subset of reads out again emits a single `REPLAY_RETAINED_SELECTION` process instead of one per step, with a comment saying it does not rerun the upstream analysis.

## What good looks like

Check three things before you send an export.

1. The `provenance/` folder is populated. It is what backs any claim you make about the run.
2. The tool versions and input file names look right, and none reads `unknown`, which is what LGE writes when it never recorded a version. The HG002 run has none.
3. If the recipient will run a Nextflow or Snakemake export, have it checked by its own engine first. The Nextflow export fails Nextflow's check and the Snakemake export fails Snakemake's. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

The Methods Section, Full Provenance, and Shell Script targets are ready to use as written.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
lungfish-cli provenance export ./Analyses/mapping-HG002 \
  --format nextflow \
  --output ./mapping-HG002-provenance-nextflow
```

The input can be a sidecar file, a bundle, or a result folder. The command prints each record it copied, which shows the chain of earlier steps the export captured. `run.sh` and `reproduce.py` arrive already marked as programs, so `./run.sh` starts one without a `chmod` first.

## Next

Continue to [Running External Workflows](03-running-external-workflows.md), which runs a pipeline written outside LGE.
