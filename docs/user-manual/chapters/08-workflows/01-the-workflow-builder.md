---
title: The Workflow Builder
chapter_id: 08-workflows/01-the-workflow-builder
audience: analyst
prereqs: [01-foundations/06-the-lungfish-project, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 12
task: Compose a FASTQ-preprocessing workflow visually and run it against a project bundle.
tags: [workflows, builder, pipeline, node-graph]
tools: []
entry_points:
  - "Tools > Workflow Builder (Experimental)…"
shots: []
planned_shots:
  - id: workflow-builder-canvas
    caption: "The Workflow Builder canvas with the VSP2 FASTQ chain composed as connected nodes."
  - id: workflow-builder-palette
    caption: "The operation palette open on the left edge of the canvas, showing the seven real category headers: Input, Preprocessing, Trimming & Filtering, Decontamination, Read Processing, Analysis, Output."
  - id: workflow-builder-node-inspector
    caption: "A selected Adapter + quality trim node showing its parameter form in the right inspector pane."
illustrations: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

The Workflow Builder turns a chain of Lungfish FASTQ-preprocessing steps into
a picture you wire together by hand. Every operation you would otherwise launch
from a recipe or a dialog becomes a draggable node on a canvas: remove
duplicates, trim adapters, scrub human reads, merge pairs, filter by length.
You connect the output of one node to the input of the next, set each node's
parameters, and run the whole graph against a FASTQ bundle in your project.
What comes back is a workflow asset. It lives in your project, carries
provenance for every step, and runs again next month against a different bundle
without a single dialog to re-click.

A workflow is the bridge between a one-off analysis and a documented procedure.
You saw in [Provenance and reproducibility](../01-foundations/08-provenance-and-reproducibility.md)
that every Lungfish operation records its inputs, parameters, tool versions,
and outputs. A workflow takes that record and makes it run. "Here is what I
did" becomes "here is how to do it again". For a lab that cleans up reads the
same way on every run, this is the difference between an SOP written in a
Google Doc and one that actually executes.

A word on scope, because this is where the Builder is easy to over-read. The
menu item reads **Workflow Builder (Experimental)** for a reason. The graph
editor is general, but the only operations the native runner executes today are
the five FASTQ-preprocessing steps listed below. The palette also holds generic
Analysis placeholder nodes (Alignment, Variant Calling, Quantification,
Assembly) and a handful of file-input nodes. Those generic nodes do not run
inside the app. They exist so a graph can be exported as Nextflow text for an
external engine, and they are covered in
[Exporting as Nextflow or Snakemake](02-exporting-as-nextflow-or-snakemake.md).
Two other families of operation are missing on purpose. Result-import paths
(NAO-MGS, NVD, CZ-ID) load classification output produced outside Lungfish and
belong in the Import Center, not the Builder. Result-viewport tools (tree
re-rooting, taxonomy read extraction, BLAST verification) act on data already
loaded in a viewport, and they are not workflow steps.

If you run the same FASTQ-cleanup steps on more than two bundles, stop running
them by hand and build the workflow once.

## What you will learn

This chapter shows how to open the Workflow Builder,
read the palette by its real categories, drag the five FASTQ-preprocessing
nodes onto the canvas, connect them into a linear chain, configure per-node
parameters, save the workflow as a project asset, version and diff it, and run
it against a project FASTQ bundle. The worked example builds the VSP2 FASTQ
processing chain, which is the one Workflow Builder graph the native Swift
runner executes end to end.

## Procedure

### Open the Workflow Builder

Choose **Tools > Workflow Builder (Experimental)…** from the menu bar. A new
window opens showing three panes: an operation palette on the left, a canvas
in the middle, and an inspector on the right. The canvas starts empty except
for a faint grid and two pinned nodes labelled **Sample input** and **Project
output**. These two nodes are not draggable.

One point about input settles the rest of the chapter. A native FASTQ graph
uses an explicit **FASTQ Bundle Input** node that you drag on yourself. The
pinned **Sample input** anchor is a legacy path that prompts for a sample at run
time. The worked example uses the explicit node, so that is the path to follow.

<!-- planned: workflow-builder-palette -->

The palette groups operations into seven categories: **Input**,
**Preprocessing**, **Trimming & Filtering**, **Decontamination**, **Read
Processing**, **Analysis**, and **Output**. Click a category header to expand
or collapse its contents. Hovering a node shows a one-line description. The
five runnable FASTQ operations live in Trimming & Filtering, Decontamination,
and Read Processing; the Analysis category holds the export-only placeholder
nodes.

### Drag a node onto the canvas

Click and hold any palette entry, drag it onto the canvas, and release. The
node appears where you dropped it, with a header and a row of input and output
ports along its left and right edges. You can move a placed node at any time by
dragging its header. To delete a node, select it and press `Delete` or
`Backspace`.

Each port carries a data type, and the check is a plain match on that type. A
port connects only to another port of the same data type: a reads port (FASTQ
Bundle) connects to a reads port, an alignments port (BAM Track) to an
alignments port, and so on. There is one exception, a reference output may feed
an assembly input and an assembly output may feed a reference input, because
the two are interchangeable downstream. A port typed `Any` (such as the
**Project output** input) accepts anything. If you attempt any other
incompatible edge, Lungfish plays the system alert sound and the connection is
dropped.

Ports are fixed per node type and always visible. There is no collapsing
drawer of optional inputs. A node that needs two inputs shows both ports
directly on its body. The generic Alignment node, for example, shows a reads
port and a reference port side by side, and the generic Variant Calling node
shows an alignments port and a reference port.

### Connect nodes with edges

To draw an edge, click an output port on one node and drag to an input port on
another. Release over the target port to commit. The edge follows a curved
path that updates as you move either node. To remove an edge, click it once to
select and press `Delete`. The builder refuses any connection that would
create a cycle, so a node can never feed itself, directly or through a loop.

The native FASTQ runner adds one more rule: the chain must be linear, each node
feeding exactly one node downstream. A branching graph, where one output fans
out to several inputs, is valid in the editor for export but rejected when you
run it natively. So build FASTQ-preprocessing workflows as a single straight
line from the input node to **Project output**.

### Configure per-node parameters

Click a node to select it. The right-hand inspector swaps to show the node's
parameter form, which mirrors the controls you would see if you ran the
operation from a recipe. The parameters that exist depend on the node:

| Node | Parameters (with defaults) |
|---|---|
| Remove PCR duplicates | none |
| Adapter + quality trim | Detect adapters (on), Quality threshold (15), Window size (5), Cut mode (right) |
| Remove human reads | Database (deacon-panhuman) |
| Merge overlapping pairs | Minimum overlap (15) |
| Remove short reads | Minimum length (50), Maximum length (unset) |

The generic Analysis placeholder nodes (Alignment, Variant Calling,
Quantification, Assembly) do not expose scientific parameters such as a
minimum allele frequency or a minimap2 preset. They carry only two hidden
metadata fields used when the graph is exported as Nextflow text. If you need
to tune mapping or variant-calling parameters, run those operations through
their own dialogs and export from provenance instead.

<!-- planned: workflow-builder-node-inspector -->

Two parameter conventions are worth understanding before you build anything
non-trivial.

The first is that values flow with the workflow. When you save a workflow,
every parameter you set on every node travels with it. Loading the same
workflow next month restores the same parameter values, so a colleague who
opens the file gets the same analysis you ran.

The second is that scientific inputs must stay project-scoped. Native FASTQ
workflows use an explicit **FASTQ Bundle Input** node: choose an existing
`.lungfishfastq` bundle in the active project and the node stores a
project-relative path such as `@/Imports/Sample.lungfishfastq`. The builder
rejects bundle paths that point outside the project root, because a workflow
that embeds an absolute path on your laptop is a workflow that does not run on
anyone else's.

### The real node types

Most FASTQ workflows draw from a small set of nodes. The table below lists the
node types that exist in the palette, grouped by their real category, with
their primary input and output. The five operation nodes marked runnable are
the ones the native runner executes; the Analysis nodes are export-only.

| Node | Category | Input | Output | Runnable natively |
|---|---|---|---|---|
| FASTQ Bundle Input | Input | project `.lungfishfastq` | FASTQ reads | input |
| FASTQ Input | Input | FASTQ file | FASTQ reads | input |
| FASTA Input | Input | FASTA file | reference bundle | input |
| BAM Input | Input | BAM/CRAM file | alignments | input |
| Sample Sheet | Input | CSV/TSV | per-row metadata | input |
| Remove PCR duplicates | Trimming & Filtering | FASTQ reads | FASTQ reads | yes |
| Adapter + quality trim | Trimming & Filtering | FASTQ reads | FASTQ reads | yes |
| Remove short reads | Trimming & Filtering | FASTQ reads | FASTQ reads | yes |
| Remove human reads | Decontamination | FASTQ reads | FASTQ reads | yes |
| Merge overlapping pairs | Read Processing | paired FASTQ reads | merged FASTQ reads | yes |
| Quality Control | Preprocessing | FASTQ reads | report | export-only |
| Trimming | Preprocessing | FASTQ reads | FASTQ reads | export-only |
| Alignment | Analysis | reads + reference | alignments | export-only |
| Variant Calling | Analysis | alignments + reference | variants | export-only |
| Quantification | Analysis | alignments + annotation | counts | export-only |
| Assembly | Analysis | FASTQ reads | assembly | export-only |
| Report | Output | report inputs | report file | export-only |

There is no download node, no primer-trim node, no annotation node, and no
phylogenetics node in the palette. Those operations live in their own dialogs
and viewports elsewhere in the app, and a finished run can still be exported as
a pipeline (see the next chapter). The Builder today is scoped to FASTQ
preprocessing.

### Save the workflow

Choose **File > Save Workflow** or press `Cmd-S`. The first save prompts for a
name and writes the workflow to the active project at
`Workflows/<name>.lungfishflow`. Subsequent saves overwrite that file. The
saved bundle includes the node graph, every parameter value, the tool versions
in use at save time, and a provenance entry recording who saved the workflow
and when.

What the saved workflow does not embed is an absolute path to your data. A
**FASTQ Bundle Input** node stores only the project-relative `@/...` path, so
the same workflow run against a different bundle is a matter of pointing that
node at a different file.

### Version and diff saved workflows

Every saved `.lungfishflow` carries a semver-style workflow version such as
`1.0.0` or `1.1.0`. The version is written into the saved `workflow.json`
inside the bundle and is shown in the Workflow Builder window subtitle after a
graph load or a version change. When you save a `.lungfishflow`, Lungfish also
appends a small `versions/history.json` entry with the version, workflow name,
and save time. That history is intentionally minimal: it gives an audit reader
a durable version surface without making the Builder a source-control system.

Use the CLI when you need a reviewable diff between two saved versions:

```bash
lungfish workflow diff Workflows/vsp2-fastq-v1.lungfishflow \
  Workflows/vsp2-fastq-v1.1.lungfishflow
```

The text output names version changes, added or removed nodes, changed node
parameters, and connection changes. For automated audit checks, add
`--format json` to emit the same comparison as machine-readable JSON. A typical
regression gate checks that a workflow moved from `1.0.0` to `1.1.0`, then
reviews the diff before running the new version against a known bundle.

### Run the workflow

Click the **Run** button in the toolbar. If the graph uses an explicit **FASTQ
Bundle Input** node, the saved bundle path on that node is the workflow input
and the run starts immediately after validation. If the graph instead uses the
legacy pinned **Sample input** anchor, a small sheet appears asking you to bind
that input to a real sample in the current project. In both cases, **Project
output** binds to the active project.

Each run is written under `runs/<run-id>/` inside the `.lungfishflow` bundle.
The run record includes timestamps, a graph checksum, the sample and project
bindings, per-node status, error state, and run-level reproducibility
provenance. Per-node status is one of running, succeeded, failed, or skipped,
written as text in the record (the Operations Panel shows the same words, not a
colour cue alone). The Operations Panel receives a parent workflow row and one
child row per node, all carrying the same durable run id, so you can watch
progress while working elsewhere in the app. The first failing node marks the
run failed and leaves every downstream node in the `skipped` state for
inspection.

Native FASTQ bundle graphs are backed by the same CLI surface the app uses:

```bash
lungfish-cli workflow builder-run \
  --workflow Workflows/vsp2-fastq.lungfishflow \
  --project Project.lungfish \
  --run-directory Workflows/vsp2-fastq.lungfishflow/runs/<run-id>
```

The real flags are `--workflow`, `--project`, `--run-directory`, `--threads`,
and `--dry-run`. Note that command lines recorded inside a provenance file
(for example, argv beginning `workflow builder-run --graph-id …` or
`workflow builder-step run …`) are audit records, not user-invocable commands.
The runnable command is the one above. The runner writes `builder-plan.json`,
native tool provenance, the derived `.lungfishfastq` bundle, and
`.lungfish-provenance.json` inside that output bundle.

## Worked example: VSP2 FASTQ bundle workflow

This is the one graph the native runner executes end to end. Open a project
that already contains a paired-end `.lungfishfastq` bundle. Choose **Tools >
Workflow Builder (Experimental)…** and create a new workflow in the project
library.

Add a **FASTQ Bundle Input** node and choose the imported bundle in the
inspector. The stored value should look like
`@/Imports/<sample>.lungfishfastq`.

Drag the following operation nodes onto the canvas, left to right:

1. **Remove PCR duplicates**
2. **Adapter + quality trim**
3. **Remove human reads**
4. **Merge overlapping pairs**
5. **Remove short reads**

Connect the chain as a single straight line from **FASTQ Bundle Input**
through those five nodes into **Project output**. Keep it linear: the native
runner rejects any node whose output fans out to more than one downstream node.
The default parameters mirror the VSP2 FASTQ recipe: adapter detection on,
quality threshold `15`, window size `5`, Deacon database `deacon-panhuman`,
merge minimum overlap `15`, and minimum length `50`.

You do not have to drag these five nodes by hand every time. Lungfish ships a
built-in VSP2 template that generates the same chain programmatically (input
through length-filter to **Project output**) with stable node identifiers, so
two people who start from the template get byte-for-byte the same graph.

Save the workflow as `vsp2-fastq` and click **Run**. Because the workflow has
an explicit FASTQ bundle input, Lungfish does not ask for separate FASTQ files
or an import-time recipe. It compiles the connected graph into a native FASTQ
plan, runs the operations, and writes a derived `.lungfishfastq` bundle under
the run's `outputs/` folder. The derived bundle records the input bundle as its
parent and carries lineage entries for duplicate removal, trimming, human-read
removal, merging, and length filtering.

One detail will surprise you the first time you read the run record. Adjacent
fastp-backed steps (for example, **Remove PCR duplicates** immediately followed
by **Adapter + quality trim**) are fused into a single fastp invocation for
provenance accounting. The run record will therefore show fewer fastp
invocations than nodes. This is expected; the lineage of each logical step is
still recorded.

## Interpretation

A successful workflow run leaves three things in your project: the output
artefact (here, a derived `.lungfishfastq` bundle), one Operations Panel row
per node with its full provenance, and a `runs/` folder inside the workflow
bundle that records which bundle the workflow was bound to on each run. If you
ran the workflow three times against three bundles, you have three entries
under `runs/` and three output bundles; the workflow file itself is unchanged.

The output bundle is published atomically. The runner writes the derived bundle
and its `.lungfish-provenance.json` into a hidden staging bundle first, then
renames the staging bundle into place only after provenance has been written.
On any error it deletes both the staging bundle and the target. An interrupted
run therefore cannot leave a final-looking `.lungfishfastq` bundle without
reproducibility metadata, which is exactly the durability property an audit
reader wants.

If a node fails (a tool errors on an empty bundle, a database is missing), the
Operations Panel marks that row's status `failed` and leaves the downstream
nodes `skipped`. Inspect the generated `runs/<run-id>/run.json` and
`runs/<run-id>/provenance.json` files in the saved workflow bundle when you
need the exact binding, graph checksum, status history, or failure details.
Treat the run record as the source of truth when comparing graph revisions or
diagnosing a failed workflow node.

A common surprise the first time you save a workflow: the node graph captures
parameters but not absolute paths. The builder refuses to save a **FASTQ
Bundle Input** node whose path points outside the project root, with an error
that names the offending value. This is intentional. A workflow that embeds a
path on your laptop is a workflow that does not run on anyone else's.

## Next

Continue to [Exporting as Nextflow or Snakemake](02-exporting-as-nextflow-or-snakemake.md)
to share a completed run with collaborators who use those pipeline tools.
