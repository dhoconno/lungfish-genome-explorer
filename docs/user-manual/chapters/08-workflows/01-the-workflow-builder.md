---
title: The Workflow Builder
chapter_id: 08-workflows/01-the-workflow-builder
audience: analyst
prereqs: [01-foundations/06-the-lungfish-project, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 18
task: Compose a read-cleanup chain in the Workflow Builder window, save it into the project, and run it against a FASTQ bundle from the window or the command line.
tags: [workflows, builder, node-graph, fastq, experimental]
tools: [fastp, deacon, seqkit]
parameters_refs: [workflow.builder]
entry_points:
  - "Settings > Advanced (Show Experimental Features)"
  - "Tools > Workflow Builder (Experimental)..."
  - "CLI: lungfish-cli workflow builder-run"
  - "CLI: lungfish-cli workflow diff"
shots:
  - id: workflow-builder-experimental-toggle
    caption: "The Experimental Features section of Settings > Advanced, with the Show Experimental Features toggle that makes the Tools menu item appear."
  - id: workflow-builder-sidebar-library
    caption: "The Workflow Builder's left sidebar, showing the Workflows list above the node palette with its plus, duplicate, and trash buttons."
  - id: workflow-builder-palette
    caption: "The node palette with its Filter nodes search field and the four category headers it draws: Input, Trimming & Filtering, Decontamination, and Read Processing."
  - id: workflow-builder-canvas
    caption: "The canvas with the five-step read-cleanup chain composed by hand, running from FASTQ Bundle Input through to the pinned Project output anchor."
  - id: workflow-builder-node-inspector
    caption: "An Adapter + quality trim node selected, showing its Label field, the tool it runs, and the Configure... button in the right-hand inspector."
illustrations: []
glossary_refs: [adapter, bundle, deacon, directed-acyclic-graph, fastp, fastq, host-depletion, node-port, operations-panel, paired-end, pcr-duplicate, provenance, read, read-merging, reproducibility, seqkit, sliding-window-trimming, workflow-bundle, workflow-lineage]
features_refs: []
fixtures_refs: [human-mito]
brand_reviewed: false
lead_approved: false
---

## What it is

If you run the same read-cleaning steps on more than two samples, draw the chain once and run the saved file from then on. The Workflow Builder is the window in Lungfish Genome Explorer (LGE) where that drawing happens.

In the Workflow Builder you draw a read-cleaning procedure as a chain of boxes and then run it. Each box is one operation, such as trimming [adapters](../../GLOSSARY.md#adapter), the short synthetic sequences library preparation attaches to each fragment, or dropping short [reads](../../GLOSSARY.md#read). You drag boxes onto a canvas, connect them, set each one's numbers, and click Run. LGE saves the procedure itself, so next month you can run the same chain on a different sample without opening five dialogs one after another.

Composing a chain happens only in the window. There are no starter templates and no command that builds a chain. Once a chain exists as a file, `lungfish-cli workflow builder-run` runs it and `lungfish-cli workflow diff` compares two versions of it.

The drawing is a [directed acyclic graph](../../GLOSSARY.md#directed-acyclic-graph), a set of boxes joined by one-way arrows in which no path leads back to where it started. This chapter calls the boxes nodes and the lines connections, and chain, workflow, and graph all mean the same drawing. LGE refuses a connection that would feed a node's output back into anything upstream of it, because a procedure that fed itself would never finish.

The palette, the list of node types you drag from, offers six node types, all of them for cleaning [FASTQ](../../GLOSSARY.md#fastq) files. There is no mapping, variant-calling, assembly, or download node. Those operations have their own dialogs, and a finished run made with them can still become a shareable pipeline, as [Exporting as Nextflow or Snakemake](02-exporting-as-nextflow-or-snakemake.md) shows.

## Why you would do this

Five separate dialogs do not remember each other. Each records what it did as [provenance](../../GLOSSARY.md#provenance), but nothing says the five steps belonged together or in what order to repeat them. A saved chain says exactly that, in a file a colleague can open.

The numbers travel with the chain. If you decided reads shorter than 50 bases are not worth keeping, because a read that short matches too many places in a genome, that decision lives in the file rather than in your memory.

A chain also records where its input sits inside the project folder rather than on your particular Mac, so moving the project to another machine does not break it. LGE refuses to run a chain whose input points outside the project.

This chapter builds its chain over HG002 mitochondrial reads, from a widely used human reference sample. That choice makes one of the five steps behave in a way worth watching, which [Reading the results](#reading-the-results) returns to.

## Before you start

You need a project open, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows.

Open the Long Reads and Assembly demo project with **Help > Demo Projects…**, as [Demo projects](../01-foundations/06-the-lungfish-project.md#demo-projects) explains. It already holds the `HG002.chrM` bundle this section imports. To import the pair yourself instead, follow the rest of this section.

This chapter uses the human-mito fixture. Download `HG002.chrM_R1.fastq.gz` and `HG002.chrM_R2.fastq.gz` from the [human-mito folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/v2026.9.40/docs/user-manual/fixtures/human-mito), as [Practice data for this manual](../01-foundations/06-the-lungfish-project.md#practice-data-for-this-manual) explains. Import them as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) describes. LGE recognises them as the two halves of a [paired-end](../../GLOSSARY.md#paired-end) library, read from both ends of each fragment, and groups them into one [bundle](../../GLOSSARY.md#bundle) named `HG002.chrM.lungfishfastq` under `Imports`. It holds 19,916 reads, 9,958 pairs, with a mean read length of 248.4 bases, figures to check your import against.

The Workflow Builder is experimental, so turn experimental features on first, as [Experimental packs and features](../01-foundations/07-plugin-packs.md#experimental-packs-and-features) shows. The **Tools > Workflow Builder (Experimental)...** item appears only when **Show Experimental Features** in **Settings > Advanced** is on.

<!-- SHOT: workflow-builder-experimental-toggle -->

The settings pane warns that experimental features may be incomplete, may change without compatibility guarantees, and are not intended for production scientific work. Use this window to learn the mechanics and keep a repeatable record, and put a result you intend to publish through the individual dialogs.

The chain calls three tools. [fastp](../../GLOSSARY.md#fastp) trims adapters and low-quality bases, [Deacon](../../GLOSSARY.md#deacon) removes reads from the host, and [seqkit](../../GLOSSARY.md#seqkit) filters reads by length. They arrive with the [Required Setup pack](../../GLOSSARY.md#required-setup-pack), the one pack LGE installs by itself, so there is nothing to install. Deacon's human index, the Human Read Removal Data, is part of that pack too.

## Procedure

The numbers in this chapter came from runs with fastp 1.3.6, Deacon 0.16.0, and seqkit 2.13.0. Other versions shift the counts a little without changing what they mean.

### 1. Open the window and create a workflow

Choose **Tools > Workflow Builder (Experimental)...**. The window has three panes. The left sidebar holds the project's workflow library above the node palette, the canvas is in the middle, and the node inspector, which shows the selected node's settings, is on the right. The sidebar and the inspector can each be hidden.

The top of the sidebar is a list headed **Workflows**, with three buttons whose tooltips read New workflow, Duplicate workflow, and Delete workflow. Right-clicking a row offers **Rename**, **Duplicate**, and **Delete**. Reopening a saved workflow from this list can show an empty canvas. This is a known defect, listed with its workaround in [Known defects in this release](../appendices/troubleshooting.md#known-defects-in-this-release).

<!-- SHOT: workflow-builder-sidebar-library -->

Saving works differently here than in most Mac applications. There is no **File > Save Workflow** item and no Cmd-S. Clicking **Run** saves the drawing into the library before it starts. If you close the window with unsaved changes, LGE offers Save, Don't Save, and Cancel, and Don't Save discards the drawing for good. Run a chain as soon as it is complete.

Click the plus button. A **New Workflow** prompt reads "Name this workflow before adding it to the project library." Name it `Mito read cleanup` and click **Create**. LGE writes it into the project at `Workflows/Mito read cleanup.lungfishflow`, a [workflow bundle](../../GLOSSARY.md#workflow-bundle).

The canvas starts with two pinned nodes, **Sample input** on the left and **Project output** on the right. Pinned means they cannot be moved or deleted. Sample input is an older way of choosing the input that asks for a sample each time the chain runs, kept so older chains still work. This chapter leaves it alone and names the input inside the drawing instead.

### 2. Read the palette

The palette sits below the workflow list, with a **Filter nodes** search field above it. It shows four category headers, **Input**, **Trimming & Filtering**, **Decontamination**, and **Read Processing**, all expanded. Rest the pointer on a node to see its name and the data type of each [port](../../GLOSSARY.md#node-port), a labelled connection point on the node's edge. In this palette every port carries one kind of thing, a FASTQ bundle of reads.

<!-- SHOT: workflow-builder-palette -->

| Node | Category | Input port | Output port |
|---|---|---|---|
| FASTQ Bundle Input | Input | none | Reads (FASTQ Bundle) |
| Remove PCR duplicates | Trimming & Filtering | Reads (FASTQ Bundle) | Deduplicated (FASTQ Bundle) |
| Adapter + quality trim | Trimming & Filtering | Reads (FASTQ Bundle) | Trimmed (FASTQ Bundle) |
| Remove short reads | Trimming & Filtering | Reads (FASTQ Bundle) | Filtered (FASTQ Bundle) |
| Remove human reads | Decontamination | Reads (FASTQ Bundle) | Scrubbed (FASTQ Bundle) |
| Merge overlapping pairs | Read Processing | Reads (FASTQ Bundle) | Merged (FASTQ Bundle) |

A [PCR duplicate](../../GLOSSARY.md#pcr-duplicate) is one original fragment copied many times during library preparation, which looks like independent evidence and is not. The output names describe what each node did, and every output connects to every input. Merge overlapping pairs does not check that its reads are paired, so single-end reads, read from one end only, pass through it with nothing merged.

### 3. Place the nodes

Drag a palette entry onto the canvas and release. Drag a placed node to move it. To delete a node, select it and press Delete. The pinned anchors ignore both.

Place six nodes in a left-to-right row, **FASTQ Bundle Input**, **Remove PCR duplicates**, **Adapter + quality trim**, **Remove human reads**, **Merge overlapping pairs**, and **Remove short reads**. The fast steps come first so the slow human-read comparison has fewer reads to work through.

The toolbar carries **Zoom In** (Cmd-plus), **Zoom Out** (Cmd-minus), **Reset Zoom**, and the **Grid** and **Snap** toggles. With the grid in view, the arrow keys nudge a selection one square at a time. Drag on empty canvas to box-select several nodes. Undo and redo work as everywhere else.

<!-- SHOT: workflow-builder-canvas -->

### 4. Connect them into one straight line

Drag from an output port to an input port on another node and release. To remove a connection, click it and press Delete.

Wire the chain as one straight line, from **FASTQ Bundle Input** through the five operation nodes in order and into **Project output**. Leave the pinned Sample input unconnected. The runner, the part of LGE that carries out a saved chain, requires a straight line. The canvas lets one node feed two downstream nodes, and nothing flags that while you draw, so Run is where you find out, with a **Workflow Run Failed** alert reading like this.

```
Workflow Builder runner requires a single linear FASTQ chain: Node 'FASTQ Bundle Input' must have exactly one outgoing connection.
```

The quoted name is the node's Label. If you meet that message, delete the extra connection and run again.

A port accepts only a port of the same data type, except the pinned Project output, which accepts any type. A refused connection, a duplicate, or one that would form a loop plays the system alert sound and drops the line, with no message, so on a muted Mac watch for the line failing to appear.

### 5. Set the parameters

Click a node and the inspector shows it. Every node starts with a **Label** field holding the name drawn on the box, which you may change without changing what the node does.

Start with the input node. Its inspector shows a **FASTQ bundle** menu listing the project's bundles. Choose `HG002.chrM`. LGE shows the file's full location below the menu, but the node stores `@/Imports/HG002.chrM.lungfishfastq`, where `@/` stands for the project folder, so the chain moves between Macs.

<!-- SHOT: workflow-builder-node-inspector -->

Every operation node arrives at the values this chapter uses, so there is nothing to change for this run. An operation node shows its Label, the tool it runs, and a **Configure...** button with the caption "Uses the same FASTQ/FASTA Operations dialog as the Tools menu." Its settings live behind that button. Click **Configure...** to open the FASTQ/FASTA Operations dialog, set the values, and click Apply to hand them back to the node. [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md) explains the fastp and length settings in full.

### 6. Run it

Click **Run** in the toolbar. LGE checks the drawing first and stops with a **Workflow Not Ready** alert when it finds an empty drawing, a loop, an input node with nothing wired out, a required port with nothing wired in, or an output node with nothing wired in.

Three other refusals are worth knowing. **No Project Open** appears when no project is open, since the `@/` paths have nothing to resolve against. **Input Bundle Not Ready** appears when the input node has no bundle or names one that cannot be found. A project opened read only refuses the run, as [Shared Projects and Bundle Migration](../appendices/shared-projects.md#reading-the-windows-read-only-state) explains.

Because the chain names its input in the drawing, the run starts as soon as the check passes. Watch the run in the [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel), which opens with **Operations > Show Operations Panel** (Cmd-Shift-P). It shows two rows, one named after the workflow and one for the runner, both carrying the same run identifier, a long string such as `9008AAD2-0223-4F26-9CD8-00E36F21940C`.

## Settings

Nine settings belong to nodes and three are window controls. None has a command-line flag, because the command line runs a saved file rather than composing one. Every node setting except FASTQ bundle is reached through **Configure...**.

**FASTQ bundle.** Names the reads the chain runs on, on the FASTQ Bundle Input node, chosen from the project's bundles and stored in the `@/` form. It arrives unset. Set it once per chain, and change it to run the same steps on a different library.

**Detect adapters.** Lets fastp work out the adapter sequence from the reads rather than being told it, on the Adapter + quality trim node. It is on by default, because adapter left in makes reads look like they carry bases the sample never had. Turn it off only when you supply the adapter another way.

**Quality threshold.** Sets the lowest base quality, the instrument's per-base confidence score, that survives trimming, on the Adapter + quality trim node, from 0 to 93. Every rise of 10 divides the chance of a wrong base by ten, so 20 means about 1 in 100 wrong. The default is 15. Raise it toward 20 when downstream calls must be conservative, and lower it when a thin run needs every base.

**Window size.** Sets how many neighbouring bases fastp averages when deciding where quality has fallen off, on the Adapter + quality trim node, 1 or more. The default is 5, the ordinary setting for [sliding-window trimming](../../GLOSSARY.md#sliding-window-trimming) of Illumina data. A larger window smooths over one bad base, and a smaller one can cut a read short for no good reason, so change it rarely.

**Cut mode.** Chooses which end the sliding trim works from, on the Adapter + quality trim node, `right`, `front`, `tail`, or `both`. The default is `right`, the 3-prime end the instrument reads last, where quality falls off, and `tail` also trims from the 3-prime end and behaves alike on this data. Choose `front` or `both` when quality plots show the first bases are also poor.

**Database.** Names the human reference index Deacon uses to spot human reads, on the Remove human reads node. Its default and only value is `deacon-panhuman`. There is nothing else to choose.

**Minimum overlap.** Sets how many bases the two reads of a pair, its mates, must share before fastp joins them, on the Merge overlapping pairs node, 1 or more. The default is 15, long enough that two mates that never overlapped rarely match by chance. Raise it when fragments are long and real overlaps are large.

**Minimum length.** Drops any read shorter than this, on the Remove short reads node, 0 or more. The default is 50 bases, long enough that a read usually matches one place on a genome. Raise it for a reference full of repeats, and lower it when the target is itself short.

**Maximum length.** Drops any read longer than this, on the Remove short reads node, 1 or more. It arrives unset, meaning no upper limit. Set it when a fixed-length protocol has produced much longer reads, usually two fragments stuck end to end, so on a 250-base protocol a limit near 400 catches them.

**Filter nodes.** Narrows the palette to node types whose name contains what you type. It starts empty. Use it to reach a node without scrolling.

**Grid.** Shows or hides the alignment grid behind the canvas, a toolbar toggle. It is on by default. Turn it off for a cleaner picture of a finished chain.

**Snap.** Makes a dragged node settle onto the nearest grid position, a toolbar toggle. It is on by default, because aligned nodes are easier to read. Turn it off to place a node exactly.

Remove PCR duplicates has no settings at all.

## Reading the results

A run of the saved `.lungfishflow` bundle gets its own folder at `runs/<run-id>/` inside the bundle. The Finder draws the bundle as one file, so right-click it and choose **Show Package Contents** to look inside. A run of a bare graph file, the chain's `workflow.json` passed to the command line on its own, writes to `Workflow Runs/<run-id>/` in the project instead.

The run folder holds `builder-plan.json`, the list of commands LGE worked out from your drawing, a `workspace` folder of intermediate files each step handed to the next, safe to delete once you have read the counts, and an `outputs` folder holding the finished bundle. A window run also writes `run.json`, with the per-node statuses (pending, running, succeeded, failed, or skipped) and any error, and `provenance.json`. The failure alert names the workflow and the error, and `run.json` is where a failed run names the node that stopped.

The finished bundle is a new `.lungfishfastq` named for the input and the workflow, here `HG002.chrM-mito-read-cleanup.lungfishfastq`. It records its parent as `@/Imports/HG002.chrM.lungfishfastq` and carries a [lineage](../../GLOSSARY.md#workflow-lineage) of five entries, one per step, each with its exact command. The lineage uses internal names.

| Node you placed | Lineage key |
|---|---|
| Remove PCR duplicates | `deduplicate` |
| Adapter + quality trim | `fastpTrim` |
| Remove human reads | `humanReadScrub` |
| Merge overlapping pairs | `pairedEndMerge` |
| Remove short reads | `lengthFilter` |

The bundle is published all at once, so an interrupted run leaves no half-finished bundle. Either the bundle and its [reproducibility](../../GLOSSARY.md#reproducibility) record both arrive, or neither does.

### What the reference run did to the reads

Every figure here is a count of reads, never of pairs. What each step removes and why is explained in [Trimming and Filtering Reads](../03-reads/04-trimming-and-filtering.md) and [Decontamination](../03-reads/05-decontamination.md).

| Step | Reads in | Reads out |
|---|---|---|
| Remove PCR duplicates and Adapter + quality trim, one fastp command | 19,916 | 19,752 |
| Remove human reads (Deacon) | 19,752 | 318 |
| Merge overlapping pairs (fastp) | 318 | 225 |
| Remove short reads (seqkit) | 225 | 106 |

Four rows for five nodes is not an error. Adjacent duplicate removal and trimming run as one fastp command carrying both `--dedup` and `--cut_right`, and the lineage still lists both steps.

The human-read step is why this chapter uses a human sample. Deacon removed 19,434 of 19,752 reads, 98.4 percent. Remove human reads does [host depletion](../../GLOSSARY.md#host-depletion), dropping reads from the organism the sample came from, and these reads are human. A step that is right for one experiment can be wrong for another, so keep this node when you are looking for something other than the host, and take it out when the host is your subject.

[Read merging](../../GLOSSARY.md#read-merging) joins two mates into one longer read, so the count falls, though not by half, because unmerged mates are kept too. The gain shows in length. The final 106 reads hold 30,498 bases, a mean of 287.7 against the input's 248.4.

Ending with 106 reads from 19,916 is the expected result of pointing a host-removal chain at a sample that is all host. Treat this run as a lesson in mechanics, not as a finding.

### Comparing two versions of a chain

Every saved chain carries a version in its `workflow.json`. A new chain starts at `1.0.0` and no control in the window changes it, so a different version means someone edited the file by hand, and a later save keeps that edited version. Each save adds a line to `versions/history.json`, and because Run saves first, that history logs saves rather than edits. A command-line run adds no line.

This part is for command-line users. `lungfish-cli workflow diff` compares two saved chains and names version changes, added or removed nodes, changed settings, and changed connections. Two hand-edited copies, one with the minimum length at 50 and version `1.0.0` and one at 100 and `1.1.0`, gave this.

```
Workflow diff: Mito read cleanup (1.0.0) -> Mito read cleanup (1.1.0)
- Version: 1.0.0 -> 1.1.0
- Node Remove short reads parameter minLength: 50 -> 100
```

## What good looks like

The two Operations Panel rows both finish without an error. A failure raises an alert naming the workflow.

The counts match what you meant. The lineage records each command but not read counts, so read them from the tool reports in the run's `workspace` folder, `<name>_fused_fastp_report_<id>.json` for fastp and `<name>_deacon_summary.json` for Deacon, and compare them with the finished bundle's read count. Ask of every large drop whether you meant it.

The commands carry your numbers. Click the run's row in the Operations Panel and click **More** to see the command that ran. The reference run's fastp call read `-q 15 -W 5 --cut_right` and its seqkit call read `-m 50`, the defaults this chapter used.

The finished bundle names its parent. Select it in the sidebar and its Inspector lineage should read `@/Imports/HG002.chrM.lungfishfastq`. A bundle with no recorded parent cannot say where its data came from, so rerun the chain.

The chain is portable. The input node's path should name a file inside the project. LGE checks this when the chain runs, not when it saves, and a path outside the project gives this refusal.

```
Error: FASTQ bundle input is outside the active project: /tmp/.../Outside.lungfishfastq
```

Treat a first run as a rehearsal on one sample before pointing the chain at thirty.

## On the command line

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to run it.

```bash
lungfish-cli workflow builder-run \
  --workflow "Mito Workflow.lungfish/Workflows/Mito read cleanup.lungfishflow" \
  --project "Mito Workflow.lungfish" \
  --threads 4

lungfish-cli workflow diff \
  "Mito Workflow.lungfish/Workflows/mito-v1.lungfishflow" \
  "Mito Workflow.lungfish/Workflows/mito-v1.1.lungfishflow"
```

Add `--dry-run` to `builder-run` to print the compiled plan as JSON without running a tool. A command-line run writes the plan, the workspace, and the output bundle, but not `run.json` or the run's `provenance.json`, so use the window when you want per-node statuses. `lungfish-cli workflow validate` checks Nextflow and Snakemake files only and refuses a builder graph.

## Next

Continue to [Exporting as Nextflow or Snakemake](02-exporting-as-nextflow-or-snakemake.md) to turn a finished run into a pipeline a collaborator can run without LGE, or to [Running External Workflows](03-running-external-workflows.md) for pipelines LGE runs rather than composes.
