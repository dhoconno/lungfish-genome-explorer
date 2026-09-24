---
title: Running External Workflows
chapter_id: 08-workflows/03-running-external-workflows
audience: analyst
prereqs: [08-workflows/02-exporting-as-nextflow-or-snakemake]
estimated_reading_min: 12
task: Link a workflow package into the Workflow Library, enable it, run it against project data, and read the run bundle and provenance it leaves behind.
tags: [workflows, nextflow, snakemake, runner, workflow-package]
tools: [nextflow, snakemake]
parameters_refs: [workflow.library-run]
entry_points:
  - "Tools > Workflows > Workflow Library..."
  - "Tools > Workflows > <package name>..."
  - "Tools > <category> > <workflow name>..."
  - "CLI: lungfish-cli workflow run"
shots:
  - id: workflow-library-linked-package
    caption: "The Workflow Library window's User Workflows heading with its Link Workflow... button, showing a linked Hello World Nextflow card whose Execution row reads Runnable."
  - id: workflow-operations-runner
    caption: "The Workflow Operations window opened from Tools > Workflows, with the enabled workflows listed down the left, the linked Hello World Nextflow package selected, and the Overview, Inputs, and Primary Settings sections on the right."
illustrations: []
glossary_refs: [checksum, nextflow, plugin-pack, provenance, provenance-sidecar, required-setup-pack, run-bundle, snakemake, workflow-engine, workflow-library, workflow-package]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter runs a pipeline somebody else wrote against data in your project. [Exporting as Nextflow or Snakemake](02-exporting-as-nextflow-or-snakemake.md) went the other way, writing a run from Lungfish Genome Explorer (LGE) out as a pipeline. Pipeline and workflow mean the same thing here, a recorded series of analysis steps.

A [workflow engine](../../GLOSSARY.md#workflow-engine) is a program that reads a description of an analysis, works out which step must come before which, and runs them in that order. LGE speaks to two. [Nextflow](../../GLOSSARY.md#nextflow) describes an analysis as processes joined by the files that flow between them. [Snakemake](../../GLOSSARY.md#snakemake) describes it as rules, each naming the files it reads, the files it writes, and the command between. LGE installs both engines itself and keeps each at one fixed version, so an upgrade elsewhere on your Mac never changes a run.

A [workflow package](../../GLOSSARY.md#workflow-package) is a folder ending in `.lungfishflowpkg` that holds a pipeline file and a `manifest.json` describing it. The manifest names the pipeline, gives its version, and declares which engine runs it, what it needs as input, and what it produces. LGE builds the run window from those declarations, so a package that declares a reference bundle and a read bundle gets a reference picker and a reads picker without anyone writing a dialog. A reference bundle, `.lungfishref`, holds a genome sequence, and a read bundle, `.lungfishfastq`, holds one sample's sequencing reads.

Two windows matter, and both sit under **Tools > Workflows**. **Tools > Workflows > Workflow Library...** is where a package is linked and switched on, and it runs nothing. The **Workflow Operations** window is where a run is set up and started. Every linked package gets its own item in **Tools > Workflows**, named after the package. An enabled package's item opens the Workflow Operations window with that package selected. A package that is not yet enabled is listed as "<name> (not enabled)", and choosing it opens the Workflow Library at that package's card. With nothing linked, the submenu holds only the Workflow Library item. The command line reaches the same engines with `lungfish-cli workflow run`, which takes a bare pipeline file instead of a package.

## Why you would do this

A colleague has a Snakemake workflow that does something LGE does not, such as a summary statistic your field uses or a tool LGE does not ship. Run in a terminal, it would work, and you would hold a result with nothing attached to say what produced it.

Run through LGE, it leaves a record. Every run writes a [run bundle](../../GLOSSARY.md#run-bundle), a `.lungfishrun` folder holding the exact command, the engine, the exit status, the timing, and a [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a small JSON file beside each result. An exit status is the number a program reports when it finishes, where zero means success. Six months on, that folder says which files and which command made the result.

A linked package also becomes an entry with a form in the Workflow Operations window, so a colleague who has never seen Snakemake can run it correctly.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. The Workflow Operations window draws its pickers from the open project.

This chapter uses the two example packages in the LGE source, `hello-world-nextflow.lungfishflowpkg` and `hello-world-snakemake.lungfishflowpkg`, in the [WorkflowPackages folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/Examples/WorkflowPackages). GitHub offers no download for a single folder, so click **Code** on the repository's front page, choose **Download ZIP**, unpack it, and find `Examples/WorkflowPackages/` inside. Move the two packages somewhere you will keep them, such as Documents. A linked package stays where it is rather than being copied into the project, so moving or deleting it later breaks the link.

Each package runs one step and does not use its inputs to compute anything, to prove the whole path works before you trust it with an hour-long pipeline. It still declares a reference and a read bundle, because a package must declare both to run. The Nextflow package writes a four-base FASTA and wraps it as a `.lungfishref` reference bundle with an index. The Snakemake package writes the same FASTA and a near-empty manifest. Neither needs a container runtime, the software that runs packaged tools in isolation, or a Python install.

Select one reference bundle from `Reference Sequences/` and one read bundle from `Imports/` in the sidebar, Cmd-clicking the second, before you open the run window, because the window fills its pickers from the selection. Any of each will do. A new project has neither, so import a reference as [Importing and Viewing a Sequence](../02-sequences/01-importing-and-viewing.md) describes and reads as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) describes.

## Procedure

### 1. Link the package into the Workflow Library

Choose **Tools > Workflows > Workflow Library...**. Find the **User Workflows** heading and click **Link Workflow...** beside it. A chooser titled Link Workflow Package opens, noting that the package stays at its location and that linking a package whose identity is already in the library replaces its earlier source and version. The identity is the `id` in its `manifest.json`, and relinking keeps whatever enablement you had set.

Select `hello-world-nextflow.lungfishflowpkg` and click **Link Workflow**. A card appears under User Workflows in the category its manifest declares, **Templates** for both examples. The card lists the declared inputs and output, the runtime, the [plugin packs](../../GLOSSARY.md#plugin-pack) the package needs, and an **Execution** row.

The Execution row reads **Runnable** or **Catalog only**. A package is Runnable only when its runner is Nextflow or Snakemake, it declares a required `.lungfishref` input and a required `.lungfishfastq` input, and it declares at least one output. Anything else, including a package that names a plain shell command, is catalogued and readable but cannot run. Both examples read Runnable.

<!-- SHOT: workflow-library-linked-package -->

### 2. Enable the workflow

Turn the card's **Enabled** switch on. Until you do, the package appears in **Tools > Workflows** greyed out as "Hello World Nextflow (not enabled)", and choosing that item brings you back to this card rather than opening a run window. The Workflow Operations window likewise lists it marked "Enable in Library" and will not let you choose it.

Nextflow and Snakemake arrive with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install. If a card's dependency row names a missing pack, install it from **Tools > Plugin Manager...** before enabling that workflow.

### 3. Open the workflow and set its inputs

With the two bundles selected, choose **Tools > Workflows > Hello World Nextflow...**. The **Workflow Operations** window opens with **Hello World Nextflow** already selected in its list of workflows. Any enabled specialized workflow in **Tools > Genotyping** opens the same window, and you can switch packages in its list at any time. The window shows six sections, Overview, Inputs, Primary Settings, Advanced Settings, Output, and Readiness. The dialog follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

Inputs holds the pickers the manifest asked for, here a **Reference** picker and a **FASTQ Bundles** list. A linked package accepts exactly one read bundle, and with more selected the Readiness line reads "Imported workflow packages currently accept one FASTQ bundle. Select one bundle, or choose a built-in workflow for folder batches."

Primary Settings holds **Output Name** and **Cores**, with a caption naming the runner and the package version. Advanced Settings is read-only text restating the declared inputs, outputs, and runtime.

<!-- SHOT: workflow-operations-runner -->

### 4. Check the Readiness line and run

The Readiness line reads "Ready to run." when everything is set, and **Run** stays disabled until it does. Otherwise it names what is missing, such as "Select a reference bundle or FASTA file."

Click **Run** and watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). A successful run of either example leaves a row reading **Completed**. The reference runs behind this chapter took two seconds for Nextflow and nine for Snakemake. Right-click a finished row and choose **Run Again...** to reopen the window with the original package, inputs, and core count locked, so the repeat matches the recorded run.

## Settings

The window builds its form from the package's manifest, so another package may show other pickers. These are the settings the two examples produce.

**Enabled.** Turns a linked package into a runnable item in **Tools > Workflows**. The default is off, so a new link is listed there greyed out until you choose otherwise. Turn it on once for each package you intend to run, and off to hide one without unlinking it. A package whose card reads Catalog only cannot be enabled. This setting has no command-line flag.

**Reference.** Supplies the reference bundle the manifest declares as a required input, from a menu of reference bundles in the project or with **Choose…** for any other location. There is no default, so the picker starts empty. Change it when the run should use a different genome. On the command line this is `--input`, repeated once per input.

**FASTQ Bundles.** Supplies the sequencing reads the manifest declares, one `.lungfishfastq` bundle for a linked package. The default is what you selected in the sidebar. Run several libraries one at a time. On the command line this is also `--input`.

**Include subfolders.** Adds every eligible bundle in folders beneath the one you selected, and appears only when the selected folder has such subfolders. A linked package runs one read bundle at a time, so it matters only for the built-in workflows in this window. The default is off. Turn it on when a run folder keeps each sample in its own subfolder. This setting has no command-line flag.

**Output Name.** Names the result the run writes. The default is the package name in lower case with hyphens, such as `hello-world-nextflow`. Change it when a second run on the same inputs would otherwise collide with the first. The field is locked during Run Again. This setting has no command-line flag.

**Cores.** Sets how many processor cores the engine may use. The default is LGE's thread count for your Mac, and most people should leave it. Lower it to keep the Mac responsive during a long pipeline. Snakemake honours it as its `--cores` value. Nextflow only records it, so it has no effect on a Nextflow run. The field is locked during Run Again. On the command line this is `--cpus`.

**Directory.** Chooses where the run writes its results, in the **Output** section. The default is the project's `Analyses/` folder. Change it when results belong on a volume with more space. Run Again always uses a fresh folder so the original stays untouched. On the command line this is `--results-dir`.

## Reading the results

Every run writes a `.lungfishrun` bundle. A window run puts it under the Directory the Output section named. A command-line run puts it in the current folder under the pipeline file's name, so a first run of `main.nf` makes `main.lungfishrun` and a second makes `main-2.lungfishrun`.

LGE does not display the bundle's contents, so open the `.lungfishrun` folder in the Finder, choosing **Show Package Contents** from its right-click menu if it shows as one item, and open its files in TextEdit. Four parts matter.

`manifest.json` records the run. It carries `engine`, `executionStatus`, `exitCode`, the full `commandPreview` LGE assembled, the `params` it passed, and a `statusHistory` with a timestamped entry for each state. A completed Snakemake run records `prepared`, `running`, and `completed`. The final state is what matters.

The `logs/` folder holds `stdout.log` and `stderr.log`, the first place to look when a run fails. The Nextflow example's `stdout.log` ends `[SUCCESS] completed=1 failed=0 cached=0`, where cached counts steps skipped because their result already existed. Its `stderr.log` is empty.

`replayIdentity` inside the manifest makes Run Again possible. It records a SHA-256 [checksum](../../GLOSSARY.md#checksum) and size for every file in the package, so a repeat can confirm it runs the same pipeline rather than an edited copy.

The `provenance/` folder holds the bundle's own [provenance](../../GLOSSARY.md#provenance) record. Each declared output also gets a `.lungfish-provenance.json` sidecar once the run succeeds, beside a plain file or at the root of a bundle output. The fields inside the sidecar are listed in [Provenance sidecars](../appendices/file-formats.md#provenance-sidecars).

## What good looks like

A run can finish without making the files you wanted, so four checks separate a run that worked from one that stopped.

1. The status says success. The Operations Panel row reads **Completed**, and `manifest.json` carries `"executionStatus": "completed"` and `"exitCode": 0`. A nonzero exit with output files present is worse than no output, because partial files can look usable.
2. Each declared output exists and carries a `.lungfish-provenance.json` sidecar. An output without a sidecar means the run did not reach the provenance step.
3. The logs end the way a successful engine ends them, with `failed=0` for Nextflow.
4. The output has the shape you expected. The Nextflow example writes `hello-world-nextflow.lungfishref` holding `genome/sequence.fa`, a `.fai` index, and a manifest for one four-base contig named `hello`.

The Snakemake example writes `hello-world-snakemake.lungfishref` with a `sequence.fasta` and a manifest that is an empty JSON object, `{}`. LGE does not check an output against the bundle type its manifest declared, so that sparse output is the example's own design, and a reminder that a package's output is only as complete as its author made it.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
lungfish-cli workflow validate hello-world-nextflow.lungfishflowpkg/main.nf

lungfish-cli workflow run hello-world-nextflow.lungfishflowpkg/main.nf \
  --results-dir ./nf-results \
  --expected-output ./nf-results/hello-world-nextflow.lungfishref \
  --bundle-root ./bundles

lungfish-cli workflow run hello-world-snakemake.lungfishflowpkg/Snakefile \
  --results-dir ./smk-results \
  --expected-output ./smk-results/results/hello-world-snakemake.lungfishref \
  --bundle-root ./bundles \
  --cpus 2
```

The command line takes a bare pipeline file rather than a package, and picks the engine from its name. A lower-case `.nf` extension means Nextflow, and a name containing `snakefile` in any case means Snakemake, so keep pipeline file names in lower case. An executed run needs at least one `--expected-output` naming exactly where the pipeline writes, because that is the file LGE records a checksum of, and the Snakemake example writes one folder deeper, into `results/`.

## Next

This is the last chapter in Workflows. The [CLI Reference](../appendices/cli-reference.md) lists every `workflow run` option, and [Troubleshooting](../appendices/troubleshooting.md) helps when a run fails.
