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
it against project data. The worked example uses an explicit `.lungfishfastq`
input bundle and the VSP2 FASTQ processing chain, which is the first
Workflow Builder graph backed by the native Swift runner.

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

The second is that scientific inputs must stay project-scoped. Legacy
workflows can still bind the pinned **Sample input** node at run time.
Native FASTQ workflows use explicit **FASTQ Bundle Input** nodes instead:
choose an existing `.lungfishfastq` bundle in the active project and the node
stores a project-relative path such as `@/Imports/Sample.lungfishfastq`. The
builder rejects bundle paths that point outside the project root.

### Common node types

Most workflows draw from a small set of node categories. The table below
lists the ones you will use most often, with their primary input and output
types and the plugin that provides them.

| Node | Category | Input | Output | Plugin |
|---|---|---|---|---|
| FASTQ bundle input | Input | project `.lungfishfastq` | FASTQ reads | core |
| FASTP deduplicate | FASTQ processing | FASTQ reads | deduplicated FASTQ reads | core |
| FASTP trim | FASTQ processing | FASTQ reads | trimmed FASTQ reads | core |
| Deacon human scrub | FASTQ processing | FASTQ reads | scrubbed FASTQ reads | core |
| FASTP merge | FASTQ processing | paired FASTQ reads | merged FASTQ reads | core |
| SeqKit length filter | FASTQ processing | FASTQ reads | filtered FASTQ reads | core |
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

### Version and diff saved workflows

Every saved `.lungfishflow` carries a semver-style workflow version such as
`1.0.0` or `1.1.0`. The version is visible in the Workflow Builder window
subtitle and is written into the saved `workflow.json` inside the bundle.
When you save a `.lungfishflow`, Lungfish also appends a small
`versions/history.json` entry with the version, workflow name, and save time.
That history is intentionally minimal: it gives an audit reader a durable
version surface without making the Builder a source-control system.

Use the CLI when you need a reviewable diff between two saved versions:

```bash
lungfish workflow diff Workflows/reads-to-variants-v1.lungfishflow \
  Workflows/reads-to-variants-v1.1.lungfishflow
```

The text output names version changes, added or removed nodes, changed node
parameters, and connection changes. For automated audit checks, add
`--format json` to emit the same comparison as machine-readable JSON. A
typical regression gate checks that a workflow moved from `1.0.0` to
`1.1.0`, then reviews the diff before running the new version against a
known sample.

### Run the workflow

Click the **Run** button in the toolbar. If the graph uses explicit
**FASTQ Bundle Input** nodes, the saved bundle paths on those nodes are the
workflow inputs and the run starts immediately after validation. If the graph
uses the legacy pinned **Sample input** anchor, a small sheet appears asking
you to bind that input to a real sample in the current project. In both
cases, **Project output** binds to the active project.

Each run is written under `runs/<run-id>/` inside the `.lungfishflow` bundle.
The run record includes timestamps, graph checksum, sample/project bindings,
per-node status, error state, and run-level reproducibility provenance. The
Operation Center receives a parent workflow row and one child row per node,
all carrying the same durable run id, so you can watch progress while working
elsewhere in the app. The first failing node marks the run failed and leaves
downstream nodes skipped in the run record for inspection.

Native FASTQ bundle graphs are backed by the same CLI surface used by the app:

```bash
lungfish-cli workflow builder-run \
  --workflow Workflows/vsp2-fastq.lungfishflow \
  --project Project.lungfish \
  --run-directory Workflows/vsp2-fastq.lungfishflow/runs/<run-id>
```

The runner writes `builder-plan.json`, native tool provenance, the final
derived `.lungfishfastq` bundle, and `.lungfish-provenance.json` inside that
output bundle. The output bundle is only published after provenance has been
written, so an interrupted run cannot leave a final-looking FASTQ bundle
without reproducibility metadata.

## Worked example: VSP2 FASTQ bundle workflow

Open a project that already contains a paired-end `.lungfishfastq` bundle.
Choose **Tools > Workflow Builder** and create a new workflow in the project
library.

Add a **FASTQ Bundle Input** node and choose the imported bundle in the
inspector. The stored value should look like
`@/Imports/<sample>.lungfishfastq`.

Drag the following operation nodes onto the canvas, left to right:

1. **FASTP deduplicate**
2. **FASTP trim**
3. **Deacon human scrub**
4. **FASTP merge**
5. **SeqKit length filter**

Connect the chain from **FASTQ Bundle Input** through those five operation
nodes into **Project output**. The default parameters mirror the VSP2 FASTQ
recipe: adapter detection enabled, quality threshold `15`, trim window `5`,
Deacon database `deacon-panhuman`, merge minimum overlap `15`, and minimum
length `50`.

Save the workflow as `vsp2-fastq`. Click **Run**. Because the workflow has an
explicit FASTQ bundle input, Lungfish does not ask for separate FASTQ files
or an import-time recipe. It compiles the connected graph into a native
FASTQ plan, runs the operations, and writes a derived `.lungfishfastq` bundle
under the workflow run's `outputs/` folder. The derived bundle records the
input bundle as its parent and carries lineage entries for deduplication,
trimming, human-read removal, merging, and length filtering.

## Worked example: SARS-CoV-2 reads to variants

This walkthrough composes the same reads-to-variants pipeline you ran step
by step in [Calling Variants from Amplicons](../05-variants/01-calling-variants-from-amplicons.md), but
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
**Run** in the sheet. The Operation Center fills with a parent workflow row
and one child row per node, then runs them in order. When the last row
completes, the project sidebar shows a new annotated VCF under **Variants**.

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
Operation Center marks that row red and stops the downstream nodes. Inspect
the generated `runs/<run-id>/run.json` and `runs/<run-id>/provenance.json`
files in the saved workflow bundle when you need the exact binding, graph
revision, status history, or failure details. Treat the run record as the
source of truth when comparing graph revisions or diagnosing a failed
workflow node.

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
