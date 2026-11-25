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

A [workflow engine](../../GLOSSARY.md#workflow-engine) is a program that reads a description of an analysis, works out which step must come before which, and runs them in that order. LGE speaks to two. [Nextflow](../../GLOSSARY.md#nextflow) describes an analysis as processes joined by the files that flow between them. [Snakemake](../../GLOSSARY.md#snakemake) describes it as rules, each naming the files it reads, the files it writes, and the command between. LGE installs both engines itself and keeps each at one fixed version, so an upgrade elsewhere on your Mac never changes a run.

A [workflow package](../../GLOSSARY.md#workflow-package) is a folder ending in `.lungfishflowpkg` that holds a pipeline file and a `manifest.json` describing it. The manifest names the pipeline, gives its version, and declares which engine runs it, what it needs as input, and what it produces. The run window always shows one Reference picker and one FASTQ Bundles line, so LGE can run a package only when it declares a required reference bundle and a required read bundle, and it fills in the package's name, version, inputs, outputs, and runtime from the manifest without anyone writing a dialog. A reference bundle, `.lungfishref`, holds a genome sequence, and a read bundle, `.lungfishfastq`, holds one sample's sequencing reads.

Two windows matter, and both sit under **Tools > Workflows**. **Tools > Workflows > Workflow Library…** is where a package is linked and switched on, and it runs nothing. The **Workflow Operations** window is where a run is set up and started. Every linked package gets its own item in **Tools > Workflows**, named after the package. An enabled package's item opens the Workflow Operations window with that package selected. A package that is not yet enabled is listed as "Enable <name>…", and choosing it opens the Workflow Library at that package's card. A package this build cannot run, one whose card reads Catalog only, is listed as "Show <name> in Workflow Library" and opens the same card. With nothing linked, the submenu holds only the Workflow Library item. The command line reaches the same engines with `lungfish-cli workflow run`, which takes a bare pipeline file instead of a package.

In practice, link a package once, switch it on, and run it from its own item in **Tools > Workflows**, so every run leaves a record beside its result.

## Three kinds of workflow

LGE uses the word workflow for three things, and this chapter is about the third.

| Kind | What it is | Where you meet it | Where the manual covers it |
|---|---|---|---|
| Processing recipe | A fixed series of read-cleaning steps that runs while reads are imported | The recipe checkbox on the Import FASTQ sheet | [Processing recipes](../03-reads/01-importing-fastq.md#processing-recipes) |
| Specialized workflow | A multi-step analysis built into LGE for one kind of study, such as MHC genotyping or 12S amplicon matching | A card under Specialized Workflows in the Workflow Library, and an item in its own **Tools** submenu | [Turning on a specialized workflow](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow), then the chapter for each study |
| Workflow package | A Nextflow or Snakemake pipeline somebody else wrote, linked into LGE from a folder on your Mac | A card under User Workflows in the Workflow Library, and an item in **Tools > Workflows** | This chapter |

A specialized workflow needs no linking. It ships with LGE, and turning it on is a switch in the Workflow Library, as [Turning on a specialized workflow](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow) shows. A workflow package has to be linked first, and the Procedure below starts there.

## What a workflow package holds

A package folder holds the pipeline file, `main.nf` for Nextflow or `Snakefile` for Snakemake, beside a `manifest.json`. The manifest is a short text file with these fields, and [The workflow bundles](../appendices/file-formats.md#the-workflow-bundles) gives the full layout.

| Field | What it says |
|---|---|
| `id`, `name`, `version`, `author`, `description` | Who wrote the package and what it is called. The `id` is its identity, so linking a package with the same `id` replaces the earlier link |
| `category` | The heading the package's card sits under, `Examples` for the two example packages |
| `runner` | The engine, `nextflow` or `snakemake`, and the pipeline file it starts from |
| `inputs`, `outputs` | The bundle types the pipeline reads, each marked required or optional, and the bundle type and path of each result it writes |
| `requiredPluginPackIDs` | The [plugin packs](../../GLOSSARY.md#plugin-pack) whose tools the pipeline calls |

A package is Runnable, rather than cataloged only, when its runner is Nextflow or Snakemake, it declares a required `.lungfishref` input and a required `.lungfishfastq` input, and it declares at least one output. The run window always shows the same Reference picker and FASTQ Bundles line, which is why a package needs both inputs to run.

## Why you would do this

A colleague has a Snakemake workflow that does something LGE does not, such as a summary statistic your field uses or a tool LGE does not ship. Run in a terminal, it would work, and you would hold a result with nothing attached to say what produced it.

Run through LGE, it leaves a record. Every run writes a [run bundle](../../GLOSSARY.md#run-bundle), a `.lungfishrun` folder holding the exact command, the engine, the exit status, the timing, and a [provenance sidecar](../../GLOSSARY.md#provenance-sidecar), a small JSON file beside each result. An exit status is the number a program reports when it finishes, where zero means success. Six months on, that folder says which files and which command made the result.

A linked package also becomes an entry with a form in the Workflow Operations window, so a colleague who has never seen Snakemake can run it correctly.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. The Workflow Operations window draws its pickers from the open project.

This chapter uses the two example packages in the LGE source, `hello-world-nextflow.lungfishflowpkg` and `hello-world-snakemake.lungfishflowpkg`, in the [WorkflowPackages folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.53/Examples/WorkflowPackages). GitHub offers no download for a single folder, so click **Code** on the repository's front page, choose **Download ZIP**, unpack it, and find `Examples/WorkflowPackages/` inside. Move the two packages somewhere you will keep them, such as Documents. A linked package stays where it is rather than being copied into the project, so moving or deleting it later breaks the link until you point LGE at its new place.

Each package runs one step and does not use its inputs to compute anything, so it proves the whole path works before you trust it with an hour-long pipeline. It still declares a reference and a read bundle, because a package must declare both to run. The Nextflow package writes a four-base FASTA and wraps it as a `.lungfishref` reference bundle with an index. The Snakemake package writes the same FASTA and a near-empty manifest. Neither needs a container runtime, the software that runs packaged tools in isolation, or a Python install.

Select one reference bundle from `Reference Sequences/` and one read bundle from `Imports/` in the sidebar, Cmd-clicking the second, before you open the run window, because the window fills its pickers from the selection. The Human Mapping and Variants demo project, which **Help > Demo Projects…** opens as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains, holds a pair you already know from earlier chapters, the `GRCh38.chr20.10.0-10.5Mb` reference and the `HG002.chr20.10.0-10.5Mb` reads. Run the example on those, and a real workflow of your own would take the same two bundles.

## Procedure

### Link the package into the Workflow Library

Choose **Tools > Workflows > Workflow Library…**. Find the **User Workflows** heading and click **Link Workflow...** beside it. A chooser titled Link Workflow Package opens, noting that the package stays at its location and that linking a package whose identity is already in the library replaces its earlier source and version. The identity is the `id` in its `manifest.json`, and relinking keeps whatever enablement you had set.

Select `hello-world-nextflow.lungfishflowpkg` and click **Link Workflow**. A card appears under User Workflows in the category its manifest declares, **Examples** for both example packages. A badge beside the name gives the engine, Nextflow or Snakemake, and the line below it is the manifest's description. The card lists the declared inputs and outputs, the runtime, the [plugin packs](../../GLOSSARY.md#plugin-pack) the package needs, and an **Execution** row.

The Execution row reads **Runnable** or **Catalog only**. A package is Runnable only when its runner is Nextflow or Snakemake, it declares a required `.lungfishref` input and a required `.lungfishfastq` input, and it declares at least one output. Anything else, including a package that names a plain shell command, is cataloged and readable but cannot run. Both examples read Runnable.

<!-- SHOT: workflow-library-linked-package -->

Below the card sit the package's folder path and three buttons. **Locate...** points the link at the package after you move it, and the package must keep the same identity. **Revalidate** reads the package again after you edit it, and **Remove** unlinks it without touching its folder. A link whose folder has gone missing stays listed with the reason, so you can locate or remove it.

### Enable the workflow

Turn the card's **Enabled** switch on. Until you do, the package appears in **Tools > Workflows** as **Enable Hello World Nextflow…**, and choosing that item brings you back to this card rather than opening a run window. The Workflow Operations window likewise lists it marked "Enable in Library" and will not let you choose it.

Nextflow and Snakemake arrive with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), which the Welcome window offers to install the first time you open LGE. If a card's dependency row names a missing pack, click **Install Dependencies** on the card, which installs the pack and then enables the workflow.

### Open the workflow and set its inputs

With the two bundles selected, choose **Tools > Workflows > Hello World Nextflow…**. The **Workflow Operations** window opens with **Hello World Nextflow** already selected in its list of workflows, its default **Output Name**, and the reference you selected in the sidebar. The specialized workflows that ship with LGE open the same window from their own **Tools** submenus, and you can switch between entries in its list at any time. The window follows the layout [Operation dialogs](../01-foundations/06-the-lungfish-project.md#operation-dialogs) describes.

The list down the left gives each enabled workflow's name and a one-line subtitle, which for a linked package is its manifest's description. The right side shows **Overview**, **Inputs**, **Primary settings**, and **Output**. A built-in workflow with extra controls adds **Advanced settings**, and a linked package has none. The Readiness line sits at the foot of the window, beside **Cancel** and **Run**.

**Overview** holds **Open Previous Run…**, which opens a chooser for a `.lungfishrun` folder and loads its recorded settings for review, as Run Again does below.

**Inputs** holds a **Reference** picker and a **FASTQ Bundles** line that names the bundle you selected in the sidebar, the same two for every linked package. A linked package accepts exactly one read bundle, and with more selected the Readiness line reads "Imported workflow packages currently accept one FASTQ bundle. Select one bundle, or choose a built-in workflow for folder batches."

**Primary settings** holds **Output Name** and **Cores**. Four lines of read-only text follow them, giving the engine and the package version, the declared inputs, the declared outputs, and the runtime.

<!-- SHOT: workflow-operations-runner -->

### Check the Readiness line and run

The Readiness line reads "Ready to run." when everything is set, and **Run** stays disabled until it does. Otherwise it names what is missing, such as "Select a reference bundle or FASTA file."

Click **Run** and watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). A successful run of either example leaves a row reading **Completed**. The reference runs behind this chapter took two seconds for Nextflow and nine for Snakemake. While a run is going, its row offers **Cancel**, on a first run as on a repeat. LGE stops the engine, the row reads Cancelled, and the run bundle's `manifest.json` records the state `cancelled`.

Right-click a finished row and choose **Run Again…** to reopen the window with the original package, inputs, and core count restored and the Output Name and Cores fields locked, so the repeat matches the recorded run. **Overview** then names the package and its version and offers **Check Configuration**, which checks the retained package, inputs, runtime, and new destination. The Readiness line reads "Ready to run." only after that check passes.

## Settings

Every linked package shows these same settings, so another package differs only in its default Output Name, the four read-only lines under Primary settings, and the path of its result.

**Enabled.** Turns a linked package into a runnable item in **Tools > Workflows**. The default is off, so a new link is listed there with Enable before its name until you choose otherwise. Turn it on once for each package you intend to run, and off to set one aside without unlinking it, though a package whose card reads Catalog only cannot be enabled and its item reads **Show <name> in Workflow Library** instead. This setting has no command-line flag.

**Reference.** Supplies the reference bundle the manifest declares as a required input, from the **Project Reference** menu of reference bundles in the project or with **Choose…** for any other location. The default is the reference selected in the sidebar, or else the first reference bundle in the project, preferring one outside the Analyses folder, and the picker starts empty only when the project holds none. Change it when the run should use a different genome, with **Replace…** or **Clear** once one is set. On the command line this is `--input`, repeated once per input.

**FASTQ Bundles.** Supplies the sequencing reads the manifest declares, one `.lungfishfastq` bundle for a linked package. The default is what you selected in the sidebar. Run several libraries one at a time. On the command line this is also `--input`.

**Include subfolders.** Adds every eligible bundle in folders beneath the one you selected, and appears only when the selected folder has such subfolders. The default is off, since a linked package runs one read bundle at a time and only the specialized workflows in this window, which [Plugin Packs](../01-foundations/07-plugin-packs.md#turning-on-a-specialized-workflow) introduces, take folder batches. Turn it on when a run folder keeps each sample in its own subfolder. This setting has no command-line flag.

**Output Name.** Supplies the name for a result path that the package's manifest builds from it, and Run stays off while the field is blank. The default is the package name in lower case with hyphens, such as `hello-world-nextflow`, and choosing another workflow in the list replaces it with that workflow's own default. Change it only for a package whose manifest builds its result path from the output name, because the two examples write a fixed name and ignore the field, and note that the field is locked during Run Again. This setting has no command-line flag.

**Cores.** Sets how many processor cores the engine may use. The default is LGE's thread count for your Mac, and most people should leave it. Lower it to keep the Mac responsive during a long pipeline, knowing that Snakemake honors it as its `--cores` value while Nextflow only records it. On the command line this is `--cpus`.

**Directory.** Chooses where the run writes its results, in the **Output** section. The default is the project's `Analyses/` folder. Change it when results belong on a volume with more space, and expect Run Again to use a fresh folder so the original stays untouched. On the command line this is `--results-dir`.

## Reading the results

Every run writes a `.lungfishrun` bundle. A window run puts it under the Directory the Output section named. A command-line run puts it in the current folder under the pipeline file's name, so a first run of `main.nf` makes `main.lungfishrun` and a second makes `main-2.lungfishrun`.

LGE does not display the bundle's contents, so open the `.lungfishrun` folder in the Finder, choosing **Show Package Contents** from its right-click menu if it shows as one item, and open its files in TextEdit. Four parts matter.

`manifest.json` records the run. It carries `engine`, `executionStatus`, `exitCode`, the full `commandPreview` LGE assembled, the `params` it passed, and a `statusHistory` with a timestamped entry for each state. A completed Snakemake run records `prepared`, `running`, and `completed`. The final state is what matters.

The `logs/` folder holds `stdout.log` and `stderr.log`, the first place to look when a run fails. The Nextflow example's `stdout.log` ends `[SUCCESS] completed=1 failed=0 cached=0`, where cached counts steps skipped because their result already existed. Its `stderr.log` is empty.

`replayIdentity` inside the manifest makes Run Again possible. It records a SHA-256 [checksum](../../GLOSSARY.md#checksum) and size for every file in the package, so a repeat can confirm it runs the same pipeline rather than an edited copy.

The `provenance/` folder holds the bundle's own [provenance](../../GLOSSARY.md#provenance) record. Each declared output also gets a `.lungfish-provenance.json` sidecar once the run succeeds, beside a plain file or at the root of a bundle output. The fields inside the sidecar are listed in [Provenance sidecars](../appendices/file-formats.md#provenance-sidecars).

## What good looks like

A run can finish without making the files you wanted, so four checks separate a run that worked from one that stopped.

The status says success. The Operations Panel row reads **Completed**, and `manifest.json` carries `"executionStatus": "completed"` and `"exitCode": 0`. A nonzero exit with output files present is worse than no output, because partial files can look usable.

Each declared output exists and carries a `.lungfish-provenance.json` sidecar. An output without a sidecar means the run did not reach the provenance step.

The logs end the way a successful engine ends them, with `failed=0` for Nextflow.

The output has the shape you expected. The Nextflow example writes `hello-world-nextflow.lungfishref` holding `genome/sequence.fa`, a `.fai` index, and a manifest for one four-base contig named `hello`.

The Snakemake example writes `hello-world-snakemake.lungfishref` with a `sequence.fasta` and a manifest that is an empty JSON object, `{}`. LGE does not check an output against the bundle type its manifest declared, so that sparse output is the example's own design, and a reminder that a package's output is only as complete as its author made it.

## On the command line

The block follows the convention in [Reading an On the command line block](../01-foundations/06-the-lungfish-project.md#reading-a-command-line-block), and [Workflows](../appendices/cli-reference.md#workflows) in the CLI Reference lists every flag of the `workflow` commands. The paths assume the two example packages sit in your Documents folder.

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

`workflow validate` checks a pipeline file without running it. `workflow list --nf-core` lists the one published nf-core pipeline LGE supports, Viral Recon, which [The Viral Recon Wizard](../04-alignments/05-viral-recon-wizard.md) runs. `workflow run` takes a bare pipeline file rather than a package, and picks the engine from its name. A lower-case `.nf` extension means Nextflow, and a name containing `snakefile` in any case means Snakemake, so keep pipeline file names in lower case. An executed run needs at least one `--expected-output` naming exactly where the pipeline writes, because that is the file LGE records a checksum of, and the Snakemake example writes one folder deeper, into `results/`. `lungfish-cli run-headless` followed by the pipeline file and the same options is a short form of `workflow run --quiet`, for scripts. Nothing in this chapter's window offers a choice between containers and conda for a pipeline, and the command-line `--executor` flag, which [`workflow run`](../appendices/cli-reference.md#workflow-run) documents, applies only to Viral Recon.

## Next

This is the last chapter of Workflows. Continue to [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md), the first chapter of MHC Allele Genotyping, which runs one of the specialized workflows from the table in [Three kinds of workflow](#three-kinds-of-workflow) on macaque amplicon reads. To send a step to a Linux machine or an HTCondor pool instead of your Mac, see [Running on a Linux Machine](04-running-on-a-linux-machine.md). When a workflow run fails, [Troubleshooting](../appendices/troubleshooting.md) helps.
