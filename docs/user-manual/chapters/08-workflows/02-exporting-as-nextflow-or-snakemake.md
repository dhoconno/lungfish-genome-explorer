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
  - "File > Export > Provenance > Nextflow Pipeline…"
  - "File > Export > Provenance > Snakemake Workflow…"
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
    caption: "The exported provenance folder open in a Finder list view, with the containers folder, main.nf, nextflow.config, and the provenance folder of copied run records."
  - id: nextflow-export-main-nf
    caption: "The top of the generated main.nf of the minimap2 mapping result open in TextEdit, showing the header comment with its notes that in-app steps, such as the build of the mapping viewer, are not replayed, then the params lines and the first process block, for the reference import, with its comment that bgzip and samtools ran inside it."
illustrations: []
glossary_refs: [bam, bundle, checksum, container, environment-variable, json, methods-export, nextflow, provenance, provenance-sidecar, reproducibility, required-setup-pack, samtools, shell, snakemake, terminal, variant-track, workflow-engine, working-directory, yaml, demo-project, operations-panel]
features_refs: [provenance.export]
fixtures_refs: [hg002-chr20]
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish Genome Explorer (LGE) writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a [checksum](../../GLOSSARY.md#checksum) of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. This chapter turns that record into something a person outside LGE can read or run.

The **File > Export > Provenance** submenu offers six targets. The first four write files a computer can run, and the last two write files for people or programs to read. Each writes a folder rather than a single file.

| Target | Main file written | Best for |
|---|---|---|
| Shell Script… | `run.sh` | Reading or replaying what LGE ran, one command at a time |
| Python Script… | `reproduce.py` | A group that prefers Python to shell |
| Nextflow Pipeline… | `main.nf`, `nextflow.config`, `containers/manifest.json` | A collaborator who already uses Nextflow |
| Snakemake Workflow… | `Snakefile`, `config.yaml` | A group that already uses Snakemake |
| Methods Section… | `methods.md` | Drafting the methods paragraph of a paper |
| Full Provenance (JSON)… | `provenance.json` | Handing the whole record, as [JSON](../../GLOSSARY.md#json) text, to a program |

A [shell](../../GLOSSARY.md#shell) script is a plain text file of commands you run in [Terminal](../../GLOSSARY.md#terminal), the macOS app for typed commands, from top to bottom, and a Python script does the same in Python, a programming language. [Nextflow](../../GLOSSARY.md#nextflow) and [Snakemake](../../GLOSSARY.md#snakemake) are [workflow engines](../../GLOSSARY.md#workflow-engine), programs that run a pipeline of tools in order on one computer or on a cluster, a shared set of computers a lab or university submits large jobs to.

The export covers one artifact, meaning one file or [bundle](../../GLOSSARY.md#bundle) a tool made, not the whole project. LGE collects every earlier step that fed into the artifact you select. It follows each input to the record that produced it, by path and by checksum, so a variant track's export starts at the reads that were imported, then the mapping, then the calling.

Every target is a faithful record of what ran, and the four that write something to run are built so the run can happen again elsewhere. Files inside the project are named relative to the project, so the record writes `@/` followed by the file's path from the project folder, as in `@/Analyses/minimap2-2026-09-25T00-00-00`. A recipient points the export at a copy of the project. In the Nextflow and Snakemake exports, scratch files the run made, written into a temporary work folder, land under `results/`, and in the shell and Python scripts they land under `OUTDIR`. Each managed tool carries the exact package it ran from, which a Nextflow or Snakemake run installs and a shell or Python script lists in its header as a `micromamba create` line to run once for each tool. The Nextflow and Snakemake exports are valid pipelines, so each engine can check its own before anything runs, as [What good looks like](#what-good-looks-like) shows.

A file that was outside the project when the run was recorded, such as a FASTQ file an import read, is the exception. The record names it as `<external>/` followed by its file name, which keeps your account name and folders out of the record, as `<workspace>/` followed by its path when it sat in a scratch folder, or by the recording machine's full path. The header lists a file named by a full path. For a file named `<external>/…` or in a scratch folder, it carries one note telling the recipient to replace each such path, and the file's name shows on its `params` line, `config.yaml` key, or `INPUT_n` line.

## Why you would do this

A collaborator asks how you produced a result. You could describe it in an email, which is slow to write and impossible to check, or hand over a folder that names every tool, version, and command in order, with the checksums of the files that went in and came out. The second answer takes one menu choice.

The same holds when a journal asks for the analysis behind a figure, when a manuscript needs a methods paragraph drafted from the versions that actually ran, and when you need to know six months from now which copy of minimap2 made a particular [BAM](../../GLOSSARY.md#bam) file.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Human Mapping and Variants (with results) [demo project](../../GLOSSARY.md#demo-project) with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It holds a finished mapping result, `minimap2-2026-09-25T00-00-00` under `Analyses`. That run placed the HG002 reads from a half-megabase slice of human chromosome 20 on the matching slice of the human reference with minimap2, a read-mapping tool, then sorted and indexed the alignment with [samtools](../../GLOSSARY.md#samtools). HG002 is a human genome from the Genome in a Bottle project, which publishes a benchmark set of its high-confidence variants. A mapping you ran yourself in [Mapping Reads to a Reference](../04-alignments/01-mapping-reads-to-a-reference.md) works the same way, under its own `minimap2-<timestamp>` name.

The artifact must have a recorded history. LGE records provenance for files a tool operation made, so a mapping result, an assembly, or a reference you imported by dropping in its FASTA qualifies, and a file LGE did not make, such as one you copied into the project folder in Finder, does not. An artifact with no history produces a **No Provenance Available** alert instead of a save panel, so select a different artifact.

Nothing needs installing to export. Reading an export needs only a text editor. Running a Nextflow or Snakemake export needs that engine on the recipient's machine. LGE's [Required Setup pack](../../GLOSSARY.md#required-setup-pack) holds both engines in its storage folder, which a fresh Terminal window does not search, so for the checks below install your own copies.

## Procedure

The walkthrough exports the HG002 mapping result as a Nextflow pipeline. Only the menu item changes for the other five targets.

### Select the artifact whose history you want

Click `minimap2-2026-09-25T00-00-00` under `Analyses` in the sidebar, so it shows in the viewport, the main display area. LGE exports the record of the item selected in the sidebar, or of the bundle open in the viewport when that bundle contains the item. With nothing selected it uses what the viewport shows, and with nothing shown it falls back to the most recently finished run of this session, so select deliberately.

### Choose the target from the menu

Choose **File > Export > Provenance > Nextflow Pipeline…**. The six targets appear in the order of the table above, with a separator after the fourth.

<!-- SHOT: export-provenance-submenu -->

The Inspector offers the same export. Its Provenance section has an **Export** button in its header, which is the route to use when a reference bundle carries [variant tracks](../../GLOSSARY.md#variant-track), lists of where a sample differs from the reference, and you want the record of one track rather than of the whole bundle. Choose the track in the **Source** picker at the top of the section, as [Reading a lineage](../01-foundations/08-provenance-and-reproducibility.md#reading-a-lineage) shows.

### Answer the sheet about unpinned tools

Before the save panel opens, LGE checks each step a script or pipeline would run against the managed tool lock, the list of exact tool versions LGE installs. A step is unpinned when the version that ran has no entry in the lock, when no version was recorded, or when LGE builds the tool itself from its source code. An unpinned step might run a different version on the recipient's computer, which can change which variants are called. No step of the HG002 mapping result is unpinned, so its export goes straight to the save panel.

When a step is unpinned, a sheet titled **Export a Nextflow pipeline with unpinned tools?** lists each such tool with its step and the reason. **Cancel** is the default and exports nothing. **Export Anyway…** opens the save panel, and the export then names each of those steps in its header, in a comment above the step that starts `Not pinned.`, and in the export's own record. A record that an earlier LGE wrote, which the Provenance tab marks **Older record format**, leaves out facts that LGE fills in when it reads it, so a script made from it might not match what ran. LGE never writes a script or pipeline from one, says so, and offers only **OK**. In this demo project the records of the two tracks LGE called, HG002 bcftools and HG002 LoFreq, are in that format, so the own record of either exports only as a Methods Section or as Full Provenance (JSON), which never show the sheet.

### Name the folder and save it

A save panel titled **Export Provenance** appears, reading "Choose a folder name for the exported reproducibility package." It opens in the project folder that holds the artifact, rather than in the last folder you used, which could belong to another project. Its Save As name arrives as `<artifact>-provenance-<format>`, here `minimap2-2026-09-25T00-00-00-provenance-nextflow`, and the format in the name keeps two exports of one artifact from colliding. Choose a location outside the project in the panel's Where menu, such as the Desktop, so the export stays apart from your data, and click **Save**.

<!-- SHOT: export-provenance-save-panel -->

If a folder of the same name already exists where you save, LGE writes into it and replaces every file of the same name, including `main.nf`, while files the export does not write stay, so choose a new name to keep an earlier export intact. If a file of that name exists, LGE refuses the export and names the path.

The export then runs as an **Export Provenance** row in the [Operations Panel](../../GLOSSARY.md#operations-panel), the list of running and finished jobs, and the row runs the same command that [On the command line](#on-the-command-line) shows, `lungfish-cli provenance export`, where `lungfish-cli` is the program inside LGE that takes typed commands. LGE builds the folder out of sight and puts it in place only when it is complete, so **Cancel** on the row leaves the folder you chose as it was.

### Open the folder

A **Provenance Export Complete** alert names the target and the file it wrote, with **OK** and **Show in Finder** buttons. Click **Show in Finder** to open the folder.

If you saved the folder inside your project, you can also read the files without leaving LGE. Select `main.nf` or `Snakefile` in the sidebar and the viewer shows it as plain text. It shows the first 2 MB of a longer file and says so.

<!-- SHOT: export-provenance-complete-alert -->

<!-- SHOT: provenance-export-folder -->

Send the whole folder, compressed into a zip archive, which Finder makes when you right-click the folder and choose **Compress**. A script pulled out on its own loses the records beside it that back every claim it makes. If your collaborator also runs LGE, you can skip the export and hand over the `.lungfish` project itself.

## Settings

**Provenance.** Chooses what the export writes from the selected artifact's history, offering Shell Script…, Python Script…, Nextflow Pipeline…, Snakemake Workflow…, Methods Section…, and Full Provenance (JSON)…. There is no default, because you pick a target from the submenu. Pick what the reader needs, a runnable copy for a collaborator, a methods draft for a manuscript, or the full record as JSON for a reviewer. On the command line this is `--format`, with the values `shell`, `python`, `nextflow`, `snakemake`, `methods`, and `json`.

**Save As.** Names the export folder in the save panel. The default is the artifact name, `-provenance-`, and the format, so successive exports of one artifact do not collide. Change it to tell apart two exports of one artifact and format, such as before and after a reanalysis. On the command line this is the last part of the `--output` path.

**Unpinned tools.** Decides whether a script or pipeline is written when LGE cannot pin a step's tool version. The default is to refuse, and **Export Anyway…** on the sheet writes it with each such step named. Override only when the recipient can accept other versions of those tools. On the command line this is `--allow-unpinned`, which the `methods` and `json` formats ignore.

**Where.** Chooses the folder the export is saved into. The default is the project folder that holds the artifact, so the panel never starts inside another project. Move out of the project to keep the export apart from the data it describes, and choose a shared folder when the export goes to a collaborator. On the command line this is the folder part of the `--output` path.

## Reading the results

### What the export folder holds

Every export folder carries a `provenance/` subfolder beside the main file, and it is worth opening first, because every target writes it. It holds a fresh [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), the record LGE writes beside a result, for the export itself. Under `provenance/source/` it holds the sidecars of every earlier step that fed into the artifact and of every file inside the result's own folder, such as the reference bundle inside the mapping result and its variant tracks. Records that the history names by a path outside the result's own folder, such as the imports, land under `provenance/source/external/` with their original path rebuilt as folders. The Nextflow export of the mapping result lays out like this.

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

Finder hides names that start with a dot, so press Cmd-Shift-Period to see them. The fields inside each sidecar are listed in [Provenance sidecars](../appendices/file-formats.md#provenance-sidecars).

### What each target file holds

The table uses a few terms. A conda environment is the private folder a tool is installed into, an image is a packaged copy of a tool that a [container](../../GLOSSARY.md#container) runs, and an image digest is a fingerprint of one exact build of that image. In a Nextflow file, a `process` is one step, and in a Snakefile a `rule` is one step.

| File | What it holds on the HG002 mapping result |
|---|---|
| `main.nf` | A header naming the run, the LGE version, start time, and host, then the notes that the rule below describes. One `params` line for each file the run started from, named from the file name and declared once. One process for each step that ran a tool or a `lungfish-cli` command, named for its tool in capitals and ending in the step's number along the whole exported history. Each carries a comment naming the tool, its version, and the step's duration, then the exact command, then a `stub:` block that only creates empty copies of the step's output files. A closing `workflow` block feeds each process the files it reads, from the earlier process that wrote a file of that name or from a `params` input. |
| `nextflow.config` | An `errorStrategy = 'terminate'` line and `conda.enabled = true`, so each process builds its tool from the recorded package, with no cluster settings. A comment says that the `=<build>` part of a package spec names the osx-arm64 build in the lock, the Apple-silicon Mac build, which another platform can drop and keep the version. `docker.enabled = true` appears only when a step ran in a container, so the demo's export needs no Docker. |
| `containers/manifest.json` | The tool, version, image, and image digest for each step that ran in a container. An empty list here, because every tool came from a conda environment. |
| `Snakefile` | The same header, a usage comment `snakemake --cores 8 --software-deployment-method conda`, a `rule all` naming every final output, and one rule per step with its log under `logs/` and a `conda:` line naming its environment file. Inputs inside the project are read through a `project()` helper, and the files the run started from are read through `config`, so one `--config` override redirects an input. A step that gets no process in `main.nf` gets no rule, and a sub-step is named in a comment above its import's rule. |
| `config.yaml` | A [YAML](../../GLOSSARY.md#yaml) file of `key: value` lines. A `project` key, `.` by default for Snakemake's [working directory](../../GLOSSARY.md#working-directory), names the `.lungfish` project the inputs live in. It also holds `outdir: results` and the same file-name keys as the Nextflow parameters, each once, mapped to project-relative paths or to the recorded path of a file that was outside the project. A comment carries the same note on `=<build>` as `nextflow.config`. |
| `envs/` | One conda environment file per managed tool, holding the exact package the tool ran from, such as `bioconda::samtools=1.24=h36b3a25_1`, which reads as channel, tool, version, and build. |
| `run.sh` | `set -euo pipefail`, a `PROJECT` variable read from the `LUNGFISH_PROJECT` [environment variable](../../GLOSSARY.md#environment-variable), and an `OUTDIR` variable you must set to a folder that does not exist yet, as [On the command line](#on-the-command-line) shows. The script makes that folder and stops if it already exists. Before any tool runs, it checks each input against the SHA-256 checksum the record holds and stops if one is missing or differs. The header comment lists the `micromamba create` line for each tool, with the same note on `=<build>`. After the check come one `INPUT_n` variable per input with its checksum, then each command in order with its tool version and the `lge-` environment to activate for it. Every output a command names by path goes under `OUTDIR`, so a replay never writes into the result folder it came from. A command that names its output only through `--project`, as `lungfish-cli import fastq` does, writes into the project that `LUNGFISH_PROJECT` names. Two commands the run joined by a pipe stay on one line. |
| `reproduce.py` | The same in Python, with the same `OUTDIR` rule and input check, and inputs in an `INPUTS` dictionary, Python's lookup table, keyed by file name. |
| `methods.md` | A draft marked "This is an automatically-generated draft. Read it before submitting.", a Computational Analysis paragraph with one sentence per tool naming what it did, its version and package, the subcommands that ran, and the parameters worth reporting, a Tool Versions table with one row per tool, an Input Files list of the files no step produced, with checksums, and a Reproducibility paragraph. |
| `provenance.json` | The record with every earlier record merged in, as one JSON file. |

Three kinds of recorded step get no process, rule, or script line and are named in a comment instead. An in-app step, one LGE did itself with no command a person could type, and a tool step whose output LGE read in the app and kept no file of, are named in the header as not replayed. A sub-step, a tool that a `lungfish-cli` command ran inside itself, gets a "ran inside" comment beside that command, because replaying the command runs the tool again. Every other step that ran an outside tool or a `lungfish-cli` command gets one. In the HG002 export the BAM header rewrite and the mapping viewer build are in-app steps, and the tools of the two imports are sub-steps.

<!-- SHOT: nextflow-export-main-nf -->

Nextflow reads files through `params`, named inputs a user can override, and Snakemake builds everything the `rule all` names. Parameter names come from file names rather than roles, so nothing in `params.grch38_chr20_10_0_10_5mb_fasta` announces that it is the reference. Read the file before you override a parameter. A step comment reads like `minimap2 v2.31`, and a Snakefile rule adds the package in parentheses. A collaborator redirects one input by naming it, as in `nextflow run main.nf --grch38_chr20_10_0_10_5mb_fasta /data/GRCh38.chr20.fasta` for Nextflow and `snakemake --cores 8 --config grch38_chr20_10_0_10_5mb_fasta=/data/GRCh38.chr20.fasta` for Snakemake, where `--cores 8` allows up to 8 processor cores, and points a Snakemake export at a project with `--directory` or `--config project=`.

The methods draft needs editing. It describes each tool once, so the five samtools steps of the HG002 result become one sentence naming samtools view (filters the reads), sort, index, flagstat (counts them), and faidx (indexes the reference), but it cannot know the accessions, access dates, or citations a paper needs. LGE's own steps, such as the build of the mapping viewer, are left out of the paragraph and named in the Reproducibility paragraph instead.

## What good looks like

Check three things before you send an export.

The `provenance/` folder is populated. It is what backs any claim you make about the run.

The tool versions and input file names look right, and none reads `unknown`, which is what LGE writes when it never recorded a version. The HG002 result has none.

If the recipient will run a Nextflow or Snakemake export, have it checked by its own engine first. Three checks run no analysis tool, and each should finish without an error. Type them in [Terminal](../../GLOSSARY.md#terminal), as [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block) explains, where `cd` moves into the export folder.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants (with results).lungfish"
cd "$HOME/Desktop/minimap2-2026-09-25T00-00-00-provenance-nextflow"
nextflow lint main.nf
nextflow run main.nf -stub-run --project "$PROJECT"
```

`nextflow lint` reads the pipeline and reports mistakes in how it is written, and needs Nextflow 25.04 or later. `-stub-run` runs every process's `stub:` block in place of its command, so it walks the whole chain in order and creates empty output files, which proves the steps are linked correctly without running a tool. The stub run leaves `work/` and `results/` folders where you typed the command, so run it in a copy of the folder or delete them before you send it. For a Snakemake export, `snakemake -n --directory "$PROJECT"` from its folder is the dry run, and it lists the jobs Snakemake would run and in what order.

Passing these checks means the pipeline is well formed and its tools are named. A real run also needs the project the inputs live in, which `config.yaml` names for Snakemake, `params.project` for Nextflow, and `LUNGFISH_PROJECT` for the scripts, and copies of the files that were outside the project when the run was recorded, which the `params` lines or `config.yaml` name and the header tells the recipient to replace. The Methods Section and Full Provenance targets need none of this.

## On the command line

The block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and [Projects, provenance, and run history](../appendices/cli-reference.md#projects-provenance-and-run-history) in the CLI Reference lists every flag of `provenance export`. A fresh Terminal window does not find `lungfish-cli` until you run the `export PATH=` line that [Finding the program](../appendices/cli-reference.md#finding-the-program) shows.

```bash
PROJECT="$HOME/Documents/LGE Demo Projects/Human Mapping and Variants (with results).lungfish"

lungfish-cli provenance export "$PROJECT/Analyses/minimap2-2026-09-25T00-00-00" \
  --format nextflow \
  --output "$HOME/Desktop/minimap2-2026-09-25T00-00-00-provenance-nextflow"
```

The input can be a sidecar file, a bundle, or a result folder. The command prints each record it copied, which shows the chain of earlier steps the export captured. To try a replay, export again with `--format shell` into a new folder and move into it. `run.sh` and `reproduce.py` arrive already marked as programs, so `LUNGFISH_PROJECT="$PROJECT" OUTDIR="$HOME/Desktop/replay-1" ./run.sh`, typed in that folder, starts a replay without a `chmod` first. The two names before `./run.sh` set variables for that command alone. The replay's read import writes into the project `LUNGFISH_PROJECT` names, so point it at a copy of the demo project.

## Next

Continue to [Running External Workflows](03-running-external-workflows.md), which goes the other way and runs a pipeline written outside LGE on data in your project.
