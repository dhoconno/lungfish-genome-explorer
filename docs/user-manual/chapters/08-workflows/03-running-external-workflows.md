---
title: Running External Workflows
chapter_id: 08-workflows/03-running-external-workflows
audience: analyst
prereqs: [08-workflows/02-exporting-as-nextflow-or-snakemake]
estimated_reading_min: 13
task: Link a workflow package into the Workflow Library, enable it, run it against project data, and read the run bundle and provenance it leaves behind.
tags: [workflows, nextflow, snakemake, runner, workflow-package]
tools: [nextflow, snakemake]
parameters_refs: [workflow.library-run]
entry_points:
  - "Tools > Workflows > Workflow Library…"
  - "Tools > Workflows > <package name>…"
  - "Tools > <category> > <workflow name>…"
  - "CLI: lungfish-cli workflow run"
  - "CLI: lungfish-cli workflow validate"
  - "CLI: lungfish-cli workflow list"
  - "CLI: lungfish-cli run-headless"
shots:
  - id: workflow-library-linked-package
    caption: "The Workflow Library window's User Workflows heading with its Link Workflow button, showing a linked Hello World Nextflow card whose Execution row reads Runnable."
  - id: workflow-operations-runner
    caption: "The Workflow Operations window opened from Tools > Workflows, with the enabled workflows listed down the left, the linked Hello World Nextflow package selected, and its Inputs and Primary settings sections on the right."
illustrations: []
glossary_refs: [checksum, nextflow, plugin-pack, provenance, provenance-sidecar, required-setup-pack, run-bundle, snakemake, workflow-engine, workflow-library, workflow-package]
features_refs: [workflow.library, workflow.nextflow, workflow.snakemake]
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter runs a pipeline somebody else wrote against data in your project. [Exporting as Nextflow or Snakemake](02-exporting-as-nextflow-or-snakemake.md) went the other way, writing a run from Lungfish Genome Explorer (LGE) out as a pipeline. Pipeline and workflow mean the same thing here, a recorded series of analysis steps.

A [workflow engine](../../GLOSSARY.md#workflow-engine) is a program that reads a description of an analysis, works out which step must come before which, and runs them in that order. LGE speaks to two. [Nextflow](../../GLOSSARY.md#nextflow) describes an analysis as processes joined by the files that flow between them. [Snakemake](../../GLOSSARY.md#snakemake) describes it as rules, each naming the files it reads, the files it writes, and the command between. LGE installs both itself and keeps each at one fixed version, which [Tool Versions](../appendices/tool-versions.md) lists as Nextflow 26.04.6 and Snakemake 9.25.2.

A [workflow package](../../GLOSSARY.md#workflow-package) is a folder ending in `.lungfishflowpkg` that holds a pipeline file and a `manifest.json`, a plain text file of labeled values in the [JSON](../../GLOSSARY.md#json) format. The manifest names the pipeline and declares its engine, inputs, and outputs, and LGE shows the package's name, version, inputs, outputs, and runtime from it. A reference bundle, `.lungfishref`, holds a genome sequence, and a read bundle, `.lungfishfastq`, holds one sample's sequencing reads.

Two windows matter, and both sit under **Tools > Workflows**. The [Workflow Library](../../GLOSSARY.md#workflow-library), at **Tools > Workflows > Workflow Library…**, lists each package as a boxed entry called a card, and it is where a package is linked and switched on, but it runs nothing. The **Workflow Operations** window is where a run is set up and started. Every linked package gets its own item in **Tools > Workflows**, named after the package, and an enabled package's item opens that window with the package selected. The command line, where you type commands into [Terminal](../../GLOSSARY.md#terminal), reaches the same engines with `lungfish-cli workflow run`, which takes the pipeline file itself instead of a package.

In practice, link a package once, switch it on, and run it from its own item in **Tools > Workflows**, so every run leaves a record of what ran.

## Three kinds of workflow

LGE uses the word workflow for three things, and this chapter is about the third.

| Kind | What it is | Where you meet it | Where the manual covers it |
|---|---|---|---|
| Processing recipe | A fixed series of read-cleaning steps that runs while reads are imported | The recipe checkbox on the Import FASTQ sheet | [Processing recipes](../03-reads/01-importing-fastq.md#processing-recipes) |
| Specialized workflow | A multi-step analysis built into LGE for one kind of study, such as MHC genotyping or 12S amplicon matching | A card under Specialized Workflows in the Workflow Library, and an item in its own **Tools** submenu | [Turning on a specialized workflow](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow), then the chapter for each study |
| Workflow package | A Nextflow or Snakemake pipeline somebody else wrote, linked into LGE from a folder on your Mac | A card under User Workflows in the Workflow Library, and an item in **Tools > Workflows** | This chapter |

A workflow package has to be linked first, and the Procedure below starts there.

## What a workflow package holds

The two examples name their pipeline file `main.nf` for Nextflow and `Snakefile` for Snakemake. [The workflow bundles](../appendices/file-formats.md#the-workflow-bundles) describes the folder, and the table lists every manifest field except `schemaVersion`, which must be `1`, and the descriptive `maturity` and `template`.

| Field | What it says |
|---|---|
| `id`, `name`, `version`, `author`, `description` | Who wrote the package and what it is called. The `id` is its identity, so linking a package with the same `id` replaces the earlier link and keeps its enablement |
| `category` | The heading the package's card sits under, `Examples` for the two example packages |
| `runner` | The engine as `kind`, `nextflow` or `snakemake`, and the pipeline file as `entrypoint`, which must exist in the folder |
| `runtime` | What the pipeline needs for its tools, a `kind` of `none`, `conda`, or `docker`, with an `environmentFile` that must exist in the package or a `containerImage` fixed to one exact build, and linking fails otherwise |
| `inputs`, `outputs` | Each input has an `id`, `name`, accepted `bundleTypes`, and `required`. Each output has an `id`, `name`, `bundleType`, and a `pathTemplate`, the path inside the **Directory** folder where the pipeline writes it, which may contain `{{outputName}}`. Bundle types are `lungfishref`, `lungfishfastq`, `lungfishbam`, `lungfishvcf`, `lungfishmsa`, `lungfishtree`, and `lungfishproject` |
| `requiredPluginPackIDs` | The [plugin packs](../../GLOSSARY.md#plugin-pack) whose tools the pipeline needs, by pack id, such as `lungfish-tools` for the Required Setup pack, with the rest in [the pack table](../01-foundations/07-plugin-packs.md#the-packs-and-what-is-in-them) |

A package is Runnable, rather than cataloged only, when its runner is Nextflow or Snakemake, it declares a required `.lungfishref` input and a required `.lungfishfastq` input, and it declares at least one output. The run window always shows the same Reference picker and FASTQ Bundles line, which is why a package needs both inputs to run. A package that cannot meet that rule, such as one that reads only FASTQ files or whose runner is `command`, a plain shell command, is cataloged and readable but cannot run in the window. A Nextflow or Snakemake pipeline file can still run through `lungfish-cli workflow run`, which takes any number of `--input` files and keeps the same kind of record.

LGE sets up no conda environment or container for a linked package, so the pipeline must supply any tools it calls. The card's **Dependency** row shows each plugin pack the manifest lists as Ready or Needs install, and its **Runtime** row shows the manifest's `kind`, where `docker` means the pipeline expects Docker Desktop, which LGE does not install or start ([Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) explains).

### Make a package from a pipeline you were given

1. Copy an example package and rename the copy, keeping the `.lungfishflowpkg` ending.
2. Replace its pipeline files with your collaborator's, all of them, because LGE records a checksum of every file in the package.
3. Edit `manifest.json` to give the package a new `id` and to set `entrypoint`, `pathTemplate`, `name`, `version`, and `description`.
4. Make the pipeline read the parameters described next, then link the package as the Procedure shows.

The window starts the pipeline with `lungfish-cli workflow run` and hands it only these parameters, values it reads by name. Each input that takes a `.lungfishref` or `.lungfishfastq` bundle arrives under its manifest `id` and as `reference_bundle` or `reads_bundle`, `outdir` is the Directory, and `input` holds both bundle paths, reference first, comma-joined. A Nextflow pipeline reads them as `params.reads_bundle` and a Snakemake pipeline as `config["reads_bundle"]`, and each path is the bundle's folder. Output Name only fills `{{outputName}}`, and Cores becomes Snakemake's `--cores`, so neither is a parameter. Give every other option a default inside the pipeline, or run the pipeline file from Terminal and pass it with `--param name=value` or `--params-file`.

## Why you would do this

A colleague has a Snakemake workflow that does something LGE does not, such as a summary statistic your field uses. Run in Terminal, it would work, and you would hold a result with nothing attached to say what produced it.

Run through LGE, it leaves a record. Every run writes a [run bundle](../../GLOSSARY.md#run-bundle), a `.lungfishrun` folder holding the exact command, the engine, the exit status, and the timing. Each result also gets a [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a small JSON file kept beside or inside it that says how it was made. An exit status is the number a program reports when it finishes, where zero means success. Six months on, those two records say which files and which command made the result.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. The Workflow Operations window draws its pickers from the open project. To use your lab's own data, import the reads as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) shows and the genome as [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) shows.

Nextflow and Snakemake come with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), Third-Party Tools in the Plugin Manager, about 2.7 GB, which the Welcome window offers to install the first time you open LGE.

This chapter uses the two example packages in the LGE source, `hello-world-nextflow.lungfishflowpkg` and `hello-world-snakemake.lungfishflowpkg`, in the [WorkflowPackages folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/Examples/WorkflowPackages). GitHub offers no download for a single folder, so open the repository's front page, [github.com/dhoconno/lungfish-genome-explorer](https://github.com/dhoconno/lungfish-genome-explorer), click **Code**, choose **Download ZIP**, unpack it, and find `Examples/WorkflowPackages/` inside. Move the two packages somewhere you will keep them, such as Documents, because a linked package stays where it is and moving it later breaks the link until you point LGE at its new place.

Each package runs one step and does not use its inputs to compute anything, so the Nextflow one is a safe first test. The Nextflow package writes a four-base [FASTA](../../GLOSSARY.md#fasta) file and wraps it as a `.lungfishref` reference bundle with an index, a companion file that lets a program jump to a position. The Snakemake package writes the same FASTA and a near-empty manifest, and the command-line block at the end of the chapter runs it. Neither needs a container runtime, the software that runs packaged tools in isolation, or a Python install.

Select one reference bundle from `Reference Sequences/` and one read bundle from `Imports/` in the sidebar, Cmd-clicking the second, before you open the run window, because the window fills its pickers from the selection. The Human Mapping and Variants demo project, opened from **Help > Demo Projects…** as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds a pair you already know from earlier chapters, the `GRCh38.chr20.10.0-10.5Mb` reference and the `HG002.chr20.10.0-10.5Mb` reads.

## Procedure

### Link the package into the Workflow Library

Choose **Tools > Workflows > Workflow Library…**. Find the **User Workflows** heading and click **Link Workflow...** beside it. A chooser titled Link Workflow Package opens.

Select `hello-world-nextflow.lungfishflowpkg` and click **Link Workflow**. A card appears under User Workflows in the category its manifest declares, **Examples** for both example packages. A badge beside the name gives the engine, Nextflow or Snakemake, and the line below it is the manifest's description. The **Enabled** switch sits at the card's top right.

The **Execution** row reads **Runnable** or **Catalog only** by the rule in [What a workflow package holds](#what-a-workflow-package-holds), and hovering over Catalog Only at the card's top right shows why. Both examples read Runnable.

<!-- SHOT: workflow-library-linked-package -->

Below the card sit the package's folder path and three buttons. **Locate...** points the link at the package after you move it, and the package must keep its `id`. **Revalidate** reads the package again after you edit it, and **Remove** unlinks it without touching its folder.

### Enable the workflow

Turn on the card's **Enabled** switch. Until you do, the package's item in **Tools > Workflows** reads **Enable Hello World Nextflow…** and brings you back to this card instead of opening a run window.

If a card's **Dependency** row reads Needs install, click **Install Dependencies** on the card, which installs the pack and then enables the workflow.

### Open the workflow and set its inputs

With the two bundles still selected in the sidebar, or selected again if you clicked elsewhere, choose **Tools > Workflows > Hello World Nextflow…**. The **Workflow Operations** window opens with **Hello World Nextflow** already selected in its list of workflows, its default **Output Name**, and the reference you selected in the sidebar.

The right side shows **Overview**, **Inputs**, **Primary settings**, and **Output**, and a specialized workflow with extra controls adds **Advanced settings**. A linked package has none, so this window cannot give its pipeline options of its own. The Readiness line sits at the foot of the window, beside **Cancel** and **Run**.

**Overview** holds **Open Previous Run…**, which opens a chooser for a `.lungfishrun` folder and loads its recorded settings for review, as Run Again does below, so a run can be repeated from its folder even after LGE has been quit.

**Inputs** holds a **Reference** picker and a **FASTQ Bundles** line that names the bundle you selected in the sidebar, the same two for every linked package. A linked package accepts exactly one read bundle, and with more selected the Readiness line reads "Imported workflow packages currently accept one FASTQ bundle. Select one bundle, or choose a built-in workflow for folder batches." The app's imported workflow packages are linked packages, and its built-in workflows are the specialized ones.

**Primary settings** holds **Output Name** and **Cores**. Four lines of read-only text follow them, giving the engine and the package version, the declared inputs, the declared outputs, and the runtime.

<!-- SHOT: workflow-operations-runner -->

### Check the Readiness line and run

The Readiness line reads "Ready to run." when everything is set, and **Run** stays disabled until it does. Otherwise it names what is missing, such as "Select a reference bundle or FASTA file."

Click **Run** and watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P), where the run is the row titled **Local Workflow**. A successful run of the Nextflow example leaves that row reading **Completed**. While a run is going, its row offers **Cancel**, on a first run as on a repeat. LGE stops the engine, the row reads Cancelled, and the run bundle's `manifest.json` records the state `cancelled`.

Right-click a finished row and choose **Run Again…** to reopen the window with the original package, inputs, and core count restored and the Output Name and Cores fields locked, so the repeat matches the recorded run. **Overview** then names the package and its version and offers **Check Configuration**, which compares the package and inputs with the checksums the run recorded and checks the runtime and the new destination. The Readiness line reads "Ready to run." only after that check passes, and a changed package file makes it read "The workflow package changed. Locate the original package before running again."

## Settings

Every linked package shows these same settings, so another package differs only in its default Output Name, the four read-only lines under Primary settings, and the path of its result. A [command-line flag](../../GLOSSARY.md#command-line-flag) is an option typed in Terminal, such as `--cpus`.

**Enabled.** Turns a linked package into a runnable item in **Tools > Workflows**. The default is off, so a new link is listed there as "Enable `<name>`…" until you switch it on. Turn it on once for each package you intend to run, and off to set one aside without unlinking it, though a package whose card reads Catalog only cannot be enabled and its item reads "Show `<name>` in Workflow Library" instead. This setting has no command-line flag.

**Reference.** Supplies the reference bundle the manifest declares as a required input, from the **Project Reference** menu of reference bundles in the project or with **Choose…** for any other location, which accepts a bundle or a plain FASTA file. The default is the reference selected in the sidebar, or else the first reference bundle in the project, preferring one outside the Analyses folder, and the picker starts empty only when the project holds none. Change it when the run should use a different genome, with **Replace…** or **Clear** once one is set. On the command line this is `--input`, repeated once per input.

**FASTQ Bundles.** Supplies the sequencing reads the manifest declares, one `.lungfishfastq` bundle for a linked package. The default is what you selected in the sidebar. Run several libraries one at a time. On the command line this is also `--input`.

**Include subfolders.** Adds every read bundle in the subfolders beneath the folder you selected, and appears only when that folder has such subfolders. The default is off, because a linked package runs one read bundle at a time and only a specialized workflow, which [Plugin Packs](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow) introduces, takes a folder batch, one run over every read bundle in a folder. Turn it on for a specialized workflow when a run folder keeps each sample in its own subfolder. This setting has no command-line flag.

**Output Name.** Supplies the name for a result path that the package's manifest builds from it, and Run stays off while the field is blank. The default is the package name in lower case with hyphens, such as `hello-world-nextflow`, and choosing another workflow in the list replaces it with that workflow's own default. Change it only for a package whose manifest builds its result path from the output name, because the two examples write a fixed name and ignore the field, and note that the field is locked during Run Again. This setting has no command-line flag.

**Cores.** Sets how many processor cores the engine may use. The default is the number of active processor cores in your Mac, and most people should leave it. Lower it to keep the Mac responsive during a long Snakemake pipeline, since Snakemake receives it as its `--cores` value while Nextflow only records the number. On the command line this is `--cpus`.

**Directory.** Chooses where the run writes its results, in the **Output** section. The default is the project's `Analyses/` folder. Change it when results belong on a volume with more space, and expect Run Again to use a fresh folder so the original stays untouched. On the command line this is `--results-dir`.

## Reading the results

Every run writes a `.lungfishrun` bundle named after the pipeline file, such as `main.lungfishrun`, and a taken name becomes `main-2.lungfishrun`, then `main-3.lungfishrun`, so a repeat never overwrites an earlier run bundle. A window run puts it in a `Workflow Runs` folder inside the Directory, `Analyses/Workflow Runs/` by default, and the sidebar hides it, so right-click the finished row in the Operations Panel and choose **Reveal Output Files** to select it in Finder. A command-line run puts it in the folder `--bundle-root` names, or else in the [working directory](../../GLOSSARY.md#working-directory), the folder Terminal is sitting in.

LGE does not display the bundle's contents, so open the `.lungfishrun` folder in Finder, choosing **Show Package Contents** from its right-click menu if it shows as one item, and open its files in TextEdit. It holds `manifest.json`, `logs/`, `provenance/`, empty `reports/` and `outputs/` folders, and `.lungfish-provenance.json`, which Finder hides because its name starts with a dot, so press Cmd-Shift-Period in that window to see it.

`manifest.json` records the run. `engine` names Nextflow or Snakemake but not its version, which the run bundle's provenance record identifies by the engine program's SHA-256 [checksum](../../GLOSSARY.md#checksum) under `runtimeExecutableSHA256`. `executionStatus` is `prepared`, `running`, `completed`, `failed`, or `cancelled`, and `exitCode` is the engine's exit status, 0 for success. `commandPreview` is the exact engine command LGE launched, and `params` lists the named values handed to the pipeline plus the core count. `statusHistory` lists each state with its time, and the last one is the outcome.

The `logs/` folder holds `stdout.log`, the engine's ordinary messages, and `stderr.log`, its [standard error](../../GLOSSARY.md#standard-error), the channel for warnings, errors, and progress notes, so a non-empty `stderr.log` is not always a failure, and the folder is the first place to look when a run fails. The Nextflow example's `stdout.log` ends `[SUCCESS] completed=1 failed=0 cached=0`, where cached counts steps skipped because their result already existed.

`replayIdentity` inside the manifest makes Run Again possible. It records a SHA-256 checksum and size for every file in the package and in each input bundle, so a repeat can confirm the same pipeline and inputs, but it stores no copies, so keep the package folder beside the project.

Each declared output also gets a [provenance](../../GLOSSARY.md#provenance) sidecar once the run succeeds. For a plain file such as `summary.tsv` it is `summary.tsv.lungfish-provenance.json` beside it. For a folder or a bundle such as `hello-world-nextflow.lungfishref` it is a hidden `.lungfish-provenance.json` inside it, and a bundle also gets a `provenance/` folder. Right-click the bundle, choose **Show Package Contents**, and press Cmd-Shift-Period to see it. Read `reproducibleCommand`, `files`, `outputs`, and `status` first, and [Provenance sidecars](../appendices/file-formats.md#provenance-sidecars) lists the rest.

## What good looks like

A run can finish without making the files you wanted, so four checks separate a run that worked from one that stopped.

The status says success. The Operations Panel row reads **Completed**, and `manifest.json` carries `"executionStatus": "completed"` and `"exitCode": 0`. A nonzero exit with output files present is worse than no output, because partial files can look usable.

Each declared output exists and carries a provenance sidecar. An output without a sidecar means the run did not reach the provenance step.

The logs end the way a successful engine ends them, with `failed=0` for Nextflow.

The output has the shape you expected. For your own pipeline, check that the manifest's `pathTemplate` matches where the pipeline writes, or the run ends Failed. The Nextflow example writes `hello-world-nextflow.lungfishref` holding `genome/sequence.fa`, a `.fai` index, and a manifest for one four-base sequence named `hello`.

The Snakemake example writes `results/hello-world-snakemake.lungfishref` with a `sequence.fasta` and a manifest that is an empty JSON object, `{}`. LGE does not check an output against its declared bundle type, so that sparse output is the example's own design.

## On the command line

The block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and [Workflows](../appendices/cli-reference.md#workflows) in the CLI Reference lists every flag of the `workflow` commands. [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to make Terminal find `lungfish-cli`. The paths assume the two example packages sit in your Documents folder.

```bash
PACKAGES="$HOME/Documents"

lungfish-cli workflow validate "$PACKAGES/hello-world-nextflow.lungfishflowpkg/main.nf"

lungfish-cli workflow run "$PACKAGES/hello-world-nextflow.lungfishflowpkg/main.nf" \
  --results-dir "$HOME/Desktop/nf-results" \
  --expected-output "$HOME/Desktop/nf-results/hello-world-nextflow.lungfishref" \
  --bundle-root "$HOME/Desktop/bundles"

lungfish-cli workflow run "$PACKAGES/hello-world-snakemake.lungfishflowpkg/Snakefile" \
  --results-dir "$HOME/Desktop/smk-results" \
  --expected-output "$HOME/Desktop/smk-results/results/hello-world-snakemake.lungfishref" \
  --bundle-root "$HOME/Desktop/bundles" \
  --cpus 2
```

`workflow validate` scans a pipeline file without running it, prints `Workflow syntax appears valid` when the file passes, and otherwise lists the problems and ends with a nonzero exit status. `workflow list --nf-core` lists the one published [nf-core](../../GLOSSARY.md#nf-core) pipeline LGE supports, Viral Recon, which [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md) runs. `run-headless` is a short form of `workflow run --quiet`, for unattended runs in scripts.

Give each input to `workflow run` with `--input`, the reference first, and LGE passes the paths on as one comma-joined `input` parameter. Each `--param name=value` adds one named parameter, and `--params-file` reads names and values from a JSON file. `--bundle-root` names the folder for the run bundle.

The engine comes from the file name, a lower-case `.nf` extension for Nextflow and a name containing `snakefile` in any case for Snakemake, so keep the `.nf` extension in lower case. A run that executes needs at least one `--expected-output` naming exactly where the pipeline writes, because that is the file LGE records a checksum of, and the Snakemake example writes one folder deeper, into `results/`. Find that path in the pipeline's own code, such as a Nextflow `publishDir` line or a Snakemake `output` line. `--dry-run` and `--prepare-only`, which write nothing or only the run bundle, need none. The command-line `--executor` flag, which [`workflow run`](../appendices/cli-reference.md#workflow-run) documents, applies only to Viral Recon.

## Next

This is the last chapter of Workflows. Continue to [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md), the first chapter of MHC Allele Genotyping, which runs one of the specialized workflows from [the table above](#three-kinds-of-workflow) on macaque amplicon reads. To send a step to a Linux machine or an HTCondor pool, a group of computers that a scheduler shares among its users, instead of your Mac, see [Running on a Linux Machine](04-running-on-a-linux-machine.md). When a run fails, [Start here, at the failed row](../appendices/troubleshooting.md#start-here-at-the-failed-row) says what to copy.
