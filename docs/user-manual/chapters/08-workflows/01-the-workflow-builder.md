---
title: The Workflow Builder
chapter_id: 08-workflows/01-the-workflow-builder
audience: analyst
prereqs: [01-foundations/06-the-lungfish-project, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 12
task: Compose a multi-step workflow visually and run it against a sample.
tags: [workflows, builder, pipeline, node-graph]
tools: []
entry_points:
  - "Tools > Workflow Builder"
shots: []
planned_shots:
  - id: workflow-builder-canvas
    caption: "The Workflow Builder canvas with a multi-step pipeline composed as connected nodes."
  - id: workflow-builder-palette
    caption: "The operation palette open on the left edge of the canvas, grouped by category."
  - id: workflow-builder-node-inspector
    caption: "A selected node showing its parameter form in the right inspector pane."
illustrations: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

The Workflow Builder is a visual node-graph composer for chaining Lungfish
operations into reusable pipelines. Each operation that you would normally
launch from a menu (download a reference, map reads, trim primers, call
variants) appears as a draggable node on a canvas. You wire the output of one
node into the input of the next, configure parameters per node, and run the
whole graph against a sample. The result is a workflow asset that lives in
your project, carries provenance for every step, and can be run again next
month against a different sample without re-clicking through dialogs.

Workflows are the bridge between a one-off analysis and a documented
procedure. You learned in [Provenance and reproducibility](../01-foundations/08-provenance-and-reproducibility.md)
that every Lungfish operation already records its inputs, parameters, tool
versions, and outputs. A workflow takes that record and makes it executable.
Instead of "here is what I did", the workflow file says "here is how to do
it again". For a lab that runs the same reads-to-variants procedure on every
new isolate, this is the difference between writing a SOP in a Google Doc and
writing one that actually runs.

A note on scope. Two kinds of operations are deliberately not in the
Workflow Builder. Result-import paths (NAO-MGS, NVD, CZ-ID) load existing
classification output produced outside Lungfish; they do not produce new
data, so they belong in the Import Center rather than the Builder. Result-
viewport tools (tree re-rooting, taxonomy read extraction, BLAST
verification) act on already-loaded data inside a viewport; they are not
workflow steps. The Workflow Builder is for operations that produce new
data from inputs. If a step you want to compose is missing from the
palette today, it is one of the gaps tracked under Lungfish's
documentation-driven backlog and will land in a future release.

So what should you do with this? If you find yourself running the same
sequence of operations on more than two samples, stop running them by hand
and build the workflow once.

## What you will learn

By the end of this chapter you will know how to open the Workflow Builder,
drag operation nodes from the palette, connect them with edges, configure
per-node parameters, save the resulting workflow as a project asset, and run
it against a sample. The worked example composes a SARS-CoV-2 reads-to-variants
workflow and runs it against a fixture sample.

## Procedure

### Open the Workflow Builder

Choose **Tools > Workflow Builder** from the menu bar. A new window opens
showing three panes: an operation palette on the left, a canvas in the
middle, and an inspector on the right. The canvas starts empty except for a
faint grid and two pinned nodes labelled **Sample input** and **Project
output**. These two nodes are not draggable. They represent the entry and
exit of any workflow you build, and you connect your first and last
operation to them.

<!-- planned: workflow-builder-palette -->

The palette groups operations by category. Categories follow the same
structure as the **Tools** menu: Acquire, Align and map, Trim, Call, Profile,
Assemble, Tree. Click a category header to expand or collapse its contents.
Hovering a node in the palette shows a one-line description and the plugin
that provides it, which matters when two plugins offer similar operations
(for example, both iVar and LoFreq can call variants).

### Drag a node onto the canvas

Click and hold any palette entry, drag it onto the canvas, and release. The
node appears where you dropped it, with a coloured header that matches the
operation's plugin (orange for core, blue for Kraken2, green for EsViritu,
and so on) and a row of input and output ports along its left and right
edges. You can move a placed node at any time by dragging its header. To
delete a node, select it and press `Delete` or `Backspace`.

Each port is typed. A `BAM` output port can only connect to a `BAM` input
port, a `FASTA` to a `FASTA`, and so on. The builder draws a thin red flash
across an attempted edge if the types do not match, then drops the
connection. This is the same set of viewport interface classes that organises
the rest of the app: Sequence, Taxonomy, Alignment, Assembly, and Variant.

### Connect nodes with edges

To draw an edge, click an output port on one node and drag to an input port
on another. Release over the target port to commit. The edge follows a
curved path that updates as you move either node. To remove an edge, click
it once to select and press `Delete`.

Most nodes have one primary input and one primary output, plus a handful of
optional secondary inputs (a BED file of primer coordinates, a GFF
annotation for codon-aware variant calls, a sample-sheet CSV for
multi-sample fan-out). Secondary inputs collapse into a single **More
inputs** drawer on the node header; click the drawer chevron to reveal them.

For multi-sample read workflows, start with a **Sample Sheet** input node
when your run is described by a CSV with `sample`, `r1`, and `r2` columns.
The node fans out one FASTQ bundle stream per row, preserving row metadata
so downstream QC, trimming, mapping, and classification steps run once per
sample while keeping the batch definition reproducible.

### Configure per-node parameters

Click a node to select it. The right-hand inspector swaps to show the node's
parameter form, which mirrors the dialog you would see if you ran the
operation interactively. iVar's **Minimum allele frequency**, minimap2's
preset, SPAdes's `--meta` flag: every parameter that appears in the run
dialog appears here too.

<!-- planned: workflow-builder-node-inspector -->

Two parameter conventions are worth understanding before you build anything
non-trivial.

The first is that values flow with the workflow. When you save a workflow,
every parameter you set on every node travels with it. Loading the same
workflow next month restores the same parameter values, so a colleague who
opens the file gets the same analysis you ran.

The second is that file paths do not flow with the workflow. The **Sample
input** node and any path-typed parameter (a custom reference FASTA, an
external primer scheme outside the project) are bound at run time, not at
save time. A saved workflow that says "trim primers using ARTIC v3" is
portable; a saved workflow that says "trim primers using
`/Users/alice/schemes/artic-v3.bed`" would not be, so the builder rejects
absolute paths outside the project at save time.

### Common node types

Most workflows draw from a small set of node categories. The table below
lists the ones you will use most often, with their primary input and output
types and the plugin that provides them.

| Node | Category | Input | Output | Plugin |
|---|---|---|---|---|
| Download reference | Acquire | accession (text) | reference bundle | core |
| Import FASTQ | Acquire | filesystem path | FASTQ bundle | core |
| Map reads | Align and map | FASTQ + reference | BAM | minimap2 |
| Trim primers | Trim | BAM + primer scheme | BAM | core |
| Call variants | Call | BAM + reference | VCF | iVar |
| Annotate variants | Call | VCF + GFF | annotated VCF | core |
| Profile taxa | Profile | FASTQ | taxonomy report | Kraken2 |
| Assemble | Assemble | FASTQ | assembly bundle | SPAdes |
| Build tree | Tree | MSA | phylogram | IQ-TREE |
| QC report | Report | BAM or FASTQ | HTML report | core |

Two categories shipped with palette gaps as of this writing. The Profile
category is missing a NAO-MGS node (the operation exists, but you have to
add the step at the CLI after exporting). The Tree category is missing a
re-rooting node, so a workflow that ends in IQ-TREE produces an unrooted
tree and you handle rooting interactively in the Phylogeny viewer.

### Save the workflow

Choose **File > Save Workflow** or press `Cmd-S`. The first save prompts
for a name and writes the workflow to the active project at
`Workflows/<name>.lungfishflow`. Subsequent saves overwrite that file. The
saved bundle includes the node graph, every parameter value, the plugin
versions in use at save time, and a provenance entry recording who saved
the workflow and when.

What the saved workflow does not include is the sample. The **Sample input**
node is bound when you press **Run**, not when you press **Save**, which is
what makes the workflow reusable across samples.

### Run the workflow

Click the **Run** button in the toolbar. A small sheet appears asking you to
bind the **Sample input** node to a real sample in the current project.
Choose a FASTQ bundle (or a paired-end pair) from the dropdown and click
**Run**. The Workflow Builder closes its sheet and the project's Operation
Center takes over: each node becomes a row in the operation log, executes in
dependency order, and writes its outputs into the project as if you had
launched it from the Tools menu. You can watch progress in the Operation
Center panel, and you can keep working in the rest of the app while the
workflow runs.

## Worked example: SARS-CoV-2 reads to variants

This walkthrough composes the same reads-to-variants pipeline you ran step
by step in [Reads to variants](../04-variants/01-reads-to-variants.md), but
as a single saved workflow.

Open a project that already contains a paired-end FASTQ bundle for a
SARS-CoV-2 sample. Choose **Tools > Workflow Builder**.

Drag the following nodes onto the canvas, left to right:

1. **Download reference**, with the accession `MN908947.3`
2. **Map reads** (minimap2)
3. **Trim primers**, with the primer scheme set to **ARTIC v3**
4. **Call variants** (iVar), with **Minimum allele frequency** set to `0.5`
5. **Annotate variants**, with the GFF source set to **NCBI for accession**

Connect the edges. The **Sample input** node's FASTQ output goes into **Map
reads**'s FASTQ input. **Download reference**'s reference output goes into
**Map reads**'s reference input, into **Call variants**'s reference input,
and into **Annotate variants**'s reference input (one output port can fan
out to many input ports). **Map reads**'s BAM output flows into **Trim
primers**, then into **Call variants**, and **Call variants**'s VCF output
flows into **Annotate variants**, whose annotated VCF output connects to the
**Project output** node.

Press `Cmd-S` and save the workflow as `sarscov2-reads-to-variants`. The
file lands at `Workflows/sarscov2-reads-to-variants.lungfishflow` inside the
project.

Click **Run**, bind the sample input to your paired FASTQ bundle, and click
**Run** in the sheet. The Operation Center fills with five rows, one per
node, and runs them in order. When the last row completes, the project
sidebar shows a new annotated VCF under **Variants**.

To prove the workflow is reusable, import a second paired-end FASTQ bundle
into the same project, double-click the saved workflow in the sidebar to
reopen it, click **Run**, and bind the sample input to the new bundle. Same
graph, same parameters, different sample, no re-clicking.

## Interpretation

A successful workflow run leaves three things in your project: the output
artefacts (in this example, a BAM, a trimmed BAM, an unannotated VCF, and an
annotated VCF), one Operation Center row per node with its full provenance,
and a `runs/` folder inside the workflow bundle that records which sample
the workflow was bound to on each run. If you ran the workflow three times
against three samples, you have three entries under `runs/` and three sets
of output artefacts; the workflow file itself is unchanged.

If a node fails (a download times out, iVar errors on an empty BAM), the
Operation Center marks that row red and stops the downstream nodes. Fix the
failing step, click **Resume** on the workflow, and only the failed node and
its descendants re-run. Upstream nodes that already succeeded are not
recomputed.

A common surprise the first time you save a workflow: the node graph
captures parameters but not paths. If your workflow needs a primer scheme
that lives outside the project, import the scheme into the project first
(it lands under `Primer Schemes/`). The builder will refuse to save a node
whose path-typed parameter points outside the project root, with an error
that names the offending parameter. This is intentional. A workflow that
embeds a path on your laptop is a workflow that does not run on anyone
else's.

## Next

Continue to [Exporting as Nextflow or Snakemake](02-exporting-as-nextflow-or-snakemake.md)
to share your workflow with collaborators who use those pipeline tools.
