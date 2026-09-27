---
title: Exporting as Nextflow or Snakemake
chapter_id: 08-workflows/02-exporting-as-nextflow-or-snakemake
audience: analyst
prereqs: [01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 11
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
    caption: "The exported provenance folder open in Finder, with main.nf, nextflow.config, and the containers folder beside the provenance subdirectory of copied run records."
  - id: nextflow-export-main-nf
    caption: "The generated main.nf of the minimap2 mapping result open in TextEdit, showing the params lines and the process blocks from the reference and read imports through MINIMAP2_6 and the samtools steps."
illustrations: []
glossary_refs: [bam, checksum, container, methods-export, nextflow, provenance, provenance-sidecar, reproducibility, samtools, snakemake, workflow-engine, demo-project]
features_refs: []
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. This chapter turns that record into something a person outside LGE can read or run.

The **File > Export > Provenance** submenu offers six targets, four that transcribe the run as something to run and two for reading. Each writes a folder rather than a single file.

| Target | Main file written | Best for |
|---|---|---|
| Shell Script... | `run.sh` | Reading what LGE ran, one command at a time |
| Python Script... | `reproduce.py` | A group that prefers Python to shell |
| Nextflow Pipeline... | `main.nf`, `nextflow.config`, `containers/manifest.json` | A collaborator who already uses Nextflow |
| Snakemake Workflow... | `Snakefile`, `config.yaml` | A group that already uses Snakemake |
| Methods Section... | `methods.md` | Drafting the methods paragraph of a paper |
| Full Provenance (JSON)... | `provenance.json` | Feeding the record to your own tools |

A shell script is a plain text file of terminal commands run top to bottom. [Nextflow](../../GLOSSARY.md#nextflow) and [Snakemake](../../GLOSSARY.md#snakemake) are [workflow engines](../../GLOSSARY.md#workflow-engine), programs that run a pipeline of tools in order on one computer or on a cluster, a shared set of computers a lab or university submits large jobs to.

The export covers one artifact, meaning one file or bundle a tool made, not the whole project. LGE collects every earlier step that fed into the artifact you select, back through the imports that brought the first files into the project.

Every target is a faithful record of what ran rather than a portable pipeline. The commands carry the absolute file paths of the machine that ran them, so they need their paths edited before they run anywhere else. The Nextflow and Snakemake exports are valid pipelines for their engines, so each engine can check one and walk through its steps before anything runs, as [What good looks like](#what-good-looks-like) shows.

## Why you would do this

A collaborator asks how you produced a result. You could describe it in an email, which is slow to write and impossible to check, or hand over a folder that names every tool, version, and command in order, with the checksums of the files that went in and came out. The second answer takes one menu choice.

The same holds when a journal asks for the analysis behind a figure, when a manuscript needs a methods paragraph drafted from the versions that actually ran, and when you need to know six months from now which copy of minimap2 made a particular [BAM](../../GLOSSARY.md#bam) file.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Mapping and Variants (with results) [demo project](../../GLOSSARY.md#demo-project) with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds a finished mapping result, `minimap2-2026-09-25T00-00-00` under `Analyses`. That run placed the HG002 reads from a half-megabase slice of human chromosome 20 on the matching slice of the human reference with minimap2, a read-mapping tool, then sorted and indexed the alignment with [samtools](../../GLOSSARY.md#samtools). HG002 is a human genome from the Genome in a Bottle project whose true sequence is already known. A mapping you ran yourself in [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) works the same way, under its own `minimap2-<timestamp>` name.

The artifact must have a recorded history. LGE records provenance for files a tool operation made, so a mapping result or an assembly qualifies, and a FASTA you dragged in does not. An artifact with no history produces a **No Provenance Available** alert instead of a save panel, so select a different artifact.

Nothing needs installing to export. Reading an export needs only a text editor. Running a Nextflow or Snakemake export needs that engine on the recipient's machine.

## Procedure

The walkthrough exports the HG002 mapping result as a Nextflow pipeline. Only the menu item changes for the other five targets.

### Select the artifact whose history you want

Click `minimap2-2026-09-25T00-00-00` under `Analyses` in the sidebar, so it shows in the viewport, the main display area. LGE looks at the visible viewport first and the sidebar selection second. When nothing is selected, LGE falls back to the most recently finished run, so select deliberately.

### Choose the target from the menu

Choose **File > Export > Provenance > Nextflow Pipeline...**. The six targets appear in the order of the table above, with a separator after the fourth.

<!-- SHOT: export-provenance-submenu -->

The Inspector offers the same export. Its Provenance section has an **Export** button in its header, which is the route to use when a reference bundle carries variant tracks and you want the record of one track rather than of the whole bundle. A variant track is a list of where a sample differs from the reference, attached to the bundle.

### Name the folder and save it

A save panel titled **Export Provenance** appears, reading "Choose a folder name for the exported reproducibility package." Its Save As name arrives as `<artifact>-provenance-<format>`, here `minimap2-2026-09-25T00-00-00-provenance-nextflow`, and the format in the name keeps two exports of one artifact from colliding. Choose a location outside the project in the panel's Where menu, such as the Desktop, and click **Save**.

<!-- SHOT: export-provenance-save-panel -->

If a folder of the same name already exists where you save, LGE writes into it and replaces the records it copies, so choose a new name to keep an earlier export intact. If a file of that name exists, LGE refuses the export and names the path.

### Open the folder

A **Provenance Export Complete** alert names the target and the file it wrote, with **OK** and **Show in Finder** buttons. Click **Show in Finder** to open the folder.

<!-- SHOT: export-provenance-complete-alert -->

<!-- SHOT: provenance-export-folder -->

Send the whole folder, compressed into a zip archive. A script pulled out on its own loses the records beside it that back every claim it makes. If your collaborator also runs LGE, you can skip the export and hand over the `.lungfish` project itself.

## Settings

**Provenance.** Chooses what the export renders from the selected artifact's history, offering Shell Script..., Python Script..., Nextflow Pipeline..., Snakemake Workflow..., Methods Section..., and Full Provenance (JSON).... There is no default, because you pick a target from the submenu. Pick what the reader needs, a transcription to run for a collaborator, a methods draft for a manuscript, or the raw JSON for a reviewer. On the command line this is `--format`, with the values `shell`, `python`, `nextflow`, `snakemake`, `methods`, and `json`.

**Save As.** Names the export folder in the save panel. The default is the artifact name, `-provenance-`, and the format, so successive exports of one artifact do not collide. Change it to tell apart two exports of one artifact and format, such as before and after a reanalysis. On the command line this is the last part of the `--output` path.

**Where.** Chooses the folder the export is saved into, opening at the save panel's last location. Keep the export outside the project, apart from the data it describes. Choose a shared place, such as a repository checkout, when the export goes to a collaborator. On the command line this is the folder part of the `--output` path.

## Reading the results

### What the export folder holds

Every export folder carries a `provenance/` subfolder beside the main file, and it is worth opening first, because it is correct whichever target you chose. It holds a fresh sidecar for the export itself and, under `provenance/source/`, the sidecars of every earlier step that fed into the artifact, including those of the reference bundle inside the mapping result and its variant tracks. Records that the history names by a path outside the result's own folder, such as the imports, land under `provenance/source/external/` with their original path rebuilt as folders. The Nextflow export of the mapping result lays out like this.

```text
minimap2-2026-09-25T00-00-00-provenance-nextflow/
  main.nf
  nextflow.config
  containers/manifest.json
  provenance/
    .lungfish-provenance.json
    source/
      .lungfish-provenance.json
      mapping-provenance.json
      GRCh38.chr20.10.0-10.5Mb.lungfishref/
      external/
```

The fields inside each sidecar are listed in [Provenance sidecars](../appendices/file-formats.md#provenance-sidecars).

### What each target file holds

Three terms appear in the table. A conda environment is the private folder a tool is installed into, an image is a packaged copy of a tool that a [container](../../GLOSSARY.md#container) runs, and an image digest is a fingerprint of one exact build of that image.

| File | What it holds on the HG002 mapping result |
|---|---|
| `main.nf` | A header naming the run, the LGE version, start time, and host. One `params` line for each file the run started from, named from the file name and declared once. One process per recorded step, here ten, from `LUNGFISH_IMPORT_FASTA_1`, `BGZIP_2`, and `SAMTOOLS_3` for the reference import, through `CLUMPIFYSH_4` and `LUNGFISH_IMPORT_FASTQ_5` for the read import, to `MINIMAP2_6` and `SAMTOOLS_7` to `SAMTOOLS_10` for the mapping. Each carries a comment naming the tool, its version, and the step's duration, then the exact command, then a `stub:` block that only creates empty copies of the step's output files. A closing `workflow` block feeds each process the files it reads, from the earlier process that wrote a file of that name or from a `params` input. |
| `nextflow.config` | An `errorStrategy = 'terminate'` line and `docker.enabled = true`, with no cluster settings. |
| `containers/manifest.json` | The tool, version, image, and image digest for each step that ran in a container. An empty list here, because every tool came from a conda environment. |
| `Snakefile` | The same header, a usage comment `snakemake --cores 8 --use-singularity`, a `rule all` naming every final output, and one rule per step with its log under `logs/`. A file two steps both recorded, such as a bundle an import wrapper and the tool it ran both wrote, belongs to the earlier rule only, so no two rules claim one output. |
| `config.yaml` | The same file-name keys as the Nextflow parameters, each once, mapped to the recorded paths, plus `outdir: results`. |
| `run.sh` | `set -euo pipefail`, one `INPUT_n` variable per input with its SHA-256 checksum, `OUTDIR`, and each command in order with its tool version. |
| `reproduce.py` | The same in Python, with inputs in an `INPUTS` dictionary keyed by file name. |
| `methods.md` | A draft marked "This is an automatically-generated draft. Read it before submitting.", a Computational Analysis section naming each successful step's tool and version, a Tool Versions table, an Input Files list with checksums, and a Reproducibility paragraph. |
| `provenance.json` | The expanded record as JSON. |

<!-- SHOT: nextflow-export-main-nf -->

The `docker.enabled = true` line and the `--use-singularity` usage comment are the engines' standard boilerplate. They do nothing when the container manifest is empty, as it is here, so they are not a sign the export is wrong.

Nextflow reads files through `params`, named inputs a user can override, and Snakemake builds everything the `rule all` names. Parameter names come from file names rather than roles, so nothing in `params.grch38_chr20_10_0_10_5mb_fasta` announces that it is the reference. Read the file before you override a parameter. A version comment reads like `minimap2 2.31 (managed conda environment minimap2; executable minimap2; root /Users/.../.lungfish/conda)`, where the dots stand for the account name of whoever ran the analysis. A collaborator redirects one input in a Snakemake export by overriding its key, as in `snakemake --cores 8 --config grch38_chr20_10_0_10_5mb_fasta=/data/GRCh38.chr20.fasta`.

The methods draft needs editing. On the HG002 result it names samtools in five nearly identical sentences, one for the reference import and four for the mapping, because five samtools steps ran.

A run made only of steps that copy a saved subset of reads out again emits a single `REPLAY_RETAINED_SELECTION` process instead of one per step, with a comment saying it does not rerun the upstream analysis.

## What good looks like

Check three things before you send an export.

The `provenance/` folder is populated. It is what backs any claim you make about the run.

The tool versions and input file names look right, and none reads `unknown`, which is what LGE writes when it never recorded a version. The HG002 result has none.

If the recipient will run a Nextflow or Snakemake export, have it checked by its own engine first. Three checks need no data and no tools, only the engine, and each should finish without an error.

```bash
cd "$HOME/Desktop/minimap2-2026-09-25T00-00-00-provenance-nextflow"
nextflow lint main.nf
nextflow run main.nf -stub-run
```

`nextflow lint` reads the pipeline and reports mistakes in how it is written. `-stub-run` runs every process's `stub:` block in place of its command, so it walks the whole chain in order and creates empty output files, which proves the steps are linked correctly without running a tool. For a Snakemake export, `snakemake -n` from its folder is the dry run, and it lists the jobs Snakemake would run and in what order. On a mapping run of the same shape as the demo's, the release candidate's export passed `nextflow lint` with no errors, `-stub-run` completed all ten processes, and `snakemake -n` planned the run.

Passing these checks means the pipeline is well formed, not that it will run as it stands. Each command still names the files and tool locations of the Mac that made it, so a real run needs those paths pointed at the recipient's own copies first, as the Shell Script and Python Script targets do. The Methods Section and Full Provenance targets are ready to use as written.

## On the command line

The block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and [Projects, provenance, and run history](../appendices/cli-reference.md#projects-provenance-and-run-history) in the CLI Reference lists every flag of `provenance export`.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants (with results).lungfish"

lungfish-cli provenance export "$PROJECT/Analyses/minimap2-2026-09-25T00-00-00" \
  --format nextflow \
  --output "$HOME/Desktop/minimap2-2026-09-25T00-00-00-provenance-nextflow"
```

The input can be a sidecar file, a bundle, or a result folder. The command prints each record it copied, which shows the chain of earlier steps the export captured. `run.sh` and `reproduce.py` arrive already marked as programs, so `./run.sh` starts one without a `chmod` first.

## Next

Continue to [Running External Workflows](03-running-external-workflows.md), which goes the other way and runs a pipeline written outside LGE on data in your project.
