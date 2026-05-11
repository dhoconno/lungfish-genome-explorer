# Workflow Builder and Runner Design

**Date:** 2026-05-11
**Status:** Approved for implementation planning
**Scope:** Native Swift/AppKit Workflow Builder and Swift/CLI-backed runner

## Goal

Build the Workflow Builder into a real in-app workflow authoring and execution system, using an expanded VSP2-style FASTQ bundle workflow as the first executable exemplar.

The exemplar starts from explicit `.lungfishfastq` input nodes selected inside the Workflow Builder, runs connected FASTQ transformation nodes, and writes derived `.lungfishfastq` outputs with complete provenance. The existing VSP2 FASTQ import recipe remains the reference implementation used to test scientific correctness, but the builder runner must execute the expanded graph directly rather than wrapping `lungfish import fastq --recipe vsp2`.

## Non-Goals

- Do not build a general plugin operation registry before the exemplar works.
- Do not replicate raw FASTQ import workflows in the builder for this first slice.
- Do not use the generic Nextflow exporter as the execution path for VSP2 bundle transformations.
- Do not replace the existing `RecipeEngine`; use it as the parity oracle and continue to support it for import.
- Do not make the first version a reusable template-only runner that hides the graph behind one recipe node.

## User Model

The user opens the Workflow Builder, adds one or more explicit FASTQ bundle input nodes, chooses existing app-managed `.lungfishfastq` bundles from the active project, connects concrete operation nodes, configures parameters, saves the workflow, and runs it.

The saved workflow is concrete. Its input nodes reference selected project bundles. Parameterized reusable inputs are out of scope for this first system, which optimizes for a specific workflow that can be inspected, run, and compared against the existing VSP2 recipe path.

## Architecture

The implementation remains native Swift:

- `LungfishWorkflow` owns graph model additions, new node types, validation, and operation-run records.
- `LungfishApp` owns AppKit builder UI, workflow library UI, node inspector UI, and operation dispatch integration.
- Existing native tool runners and CLI provenance structures remain the execution and reproducibility foundation.

The system has five main pieces:

1. Explicit FASTQ input nodes
2. Concrete FASTQ operation nodes
3. Node inspector and parameter editing
4. Workflow library management
5. Builder-native graph runner

## Graph Model

### Explicit Input Nodes

Add or repurpose a concrete `FASTQ Bundle Input` node type for existing `.lungfishfastq` bundles. The node stores:

- Project-relative bundle path
- Display name
- Stable bundle identity when available
- Input role
- File size and checksum metadata captured at run time

The graph can contain multiple input nodes. Each input node produces a `fastqBundle` output port.

The pinned `Sample input` anchor can remain for backward compatibility, but the VSP2 exemplar should use explicit FASTQ bundle input nodes. The pinned anchor is not the primary user path for this slice.

### Operation Nodes

Add concrete node types for the VSP2-expanded workflow:

- `fastpDedup`
- `fastpTrim`
- `deaconHumanScrub`
- `fastpMerge`
- `seqkitLengthFilter`

Each node has one primary `fastqBundle` input and one primary `fastqBundle` output. If an operation produces auxiliary reports or logs, the runner records them in provenance and output metadata; the initial canvas does not need secondary report ports unless they are useful for workflow composition.

Default node labels:

- Remove PCR duplicates
- Adapter + quality trim
- Remove human reads
- Merge overlapping pairs
- Remove short reads

### Parameters

Node parameter definitions mirror the existing VSP2 recipe defaults:

- Dedup: no user-visible parameters initially.
- Trim: `detectAdapter = true`, `quality = 15`, `window = 5`, `cutMode = right`.
- Human scrub: `database = deacon-panhuman`.
- Merge: `minOverlap = 15`.
- Length filter: `minLength = 50`, optional `maxLength`.

Parameters are stored on `WorkflowNode.parameters` as today, validated through typed `ParameterDefinition` metadata, and resolved to `ParameterValue` for execution and provenance.

## UI Design

### Palette

The palette should expose the concrete VSP2 operation nodes under FASTQ-focused categories:

- Input: FASTQ Bundle Input
- Trimming and filtering: Deduplicate, Adapter + quality trim, Length filter
- Decontamination: Human scrub
- Read processing: Merge paired reads
- Output: Project output

The palette remains searchable and draggable. Pinned anchors stay hidden from normal palette search.

### Node Inspector

Selecting a node opens an inspector panel. The inspector supports:

- Node label editing
- FASTQ input bundle chooser for input nodes
- Typed parameter controls for operation nodes
- Read-only port summary
- Validation errors for the selected node

Use the existing parameter-control infrastructure where practical, but adapt it to edit `WorkflowNode.parameters` rather than external workflow schemas.

The input bundle chooser must prefer project-relative paths and reject bundles outside the active project for this first slice. That keeps saved workflows portable within the project and makes provenance path resolution unambiguous.

### Canvas Editing

The canvas already supports adding, moving, selecting, connecting, and deleting graph objects. This work should make deletion behavior complete and test-covered:

- Delete selected removable nodes.
- Delete selected connections.
- Do not delete pinned anchors.
- Update validation and dirty state after deletion.
- Make the menu Delete item enabled only when a deletable selection exists.

### Workflow Library

Add a project-local workflow management surface for many workflows under `<project>/Workflows`.

Initial operations:

- New workflow
- Open workflow
- Duplicate workflow
- Rename workflow
- Delete workflow
- Save workflow
- Run selected workflow

The library reads `.lungfishflow` bundles, displays workflow name, version, modified date, and last run status when available. File dialogs can remain as fallback paths, but the primary project workflow management should not require browsing the filesystem manually.

## Runner Design

### Execution Strategy

The first production runner recognizes supported FASTQ bundle transformation graphs and executes them directly as a graph of Swift operations. It must not collapse the graph to a single VSP2 recipe invocation.

Execution proceeds in topological order:

1. Resolve explicit input node bundle references.
2. Validate each operation can consume the upstream bundle.
3. Materialize or locate FASTQ payloads from the input `.lungfishfastq`.
4. Run each operation using the existing native tool infrastructure.
5. Create derived output bundles for each terminal output.
6. Write run records, operation rows, logs, and provenance.

For the VSP2 chain, the operation implementations may reuse existing low-level executors from `RecipeEngine` and `RecipeStepExecutor` where that avoids duplicating tool-specific command construction. The important boundary is that the builder runner executes node-by-node and records node-level status, not that every tool wrapper is copied.

### Outputs

The terminal output is a derived `.lungfishfastq` bundle stored in the active project. For multiple explicit input nodes, the runner writes one output bundle per input. Aggregating multiple inputs into one output requires an explicit aggregation node, which is out of scope for this first slice.

Output bundle naming should be deterministic and collision-safe:

- Base name: `<input-name>-<workflow-name>`
- Existing output: allocate `-2`, `-3`, and so on unless the run is explicitly configured to overwrite.

### Provenance

Missing provenance is a blocking defect.

Every run must write provenance at two levels:

- Workflow run provenance in the `.lungfishflow/runs/<run-id>/` directory.
- Scientific output provenance inside each derived `.lungfishfastq` output bundle.

Provenance must include:

- Workflow Builder tool name and version
- Workflow graph id, graph checksum, workflow version
- Exact command or reproducible GUI workflow command equivalent
- User-visible options and resolved defaults
- Runtime identity
- Input and output paths
- Checksums and file sizes
- Per-node tool names, versions, argv, exit status, wall time, and useful stderr
- Dependency ordering between steps

For GUI-created derived outputs, provenance must point at the final stored output payload inside the derived `.lungfishfastq` bundle, not temporary workspace files.

### Errors

Validation fails before execution when:

- An input node has no selected `.lungfishfastq` bundle.
- A referenced bundle is missing or outside the project.
- Required operation parameters are missing or invalid.
- Required ports are unconnected.
- The graph contains unsupported node types for the selected runner.
- The graph is cyclic.

Runtime failure behavior:

- Mark the failing node failed.
- Mark downstream nodes skipped.
- Preserve completed upstream outputs when they are valid derived bundles.
- Write run-level provenance with nonzero exit status and stderr.
- Surface the failure through Operation Center and the Workflow Builder UI.

## VSP2 Exemplar

The builder should provide an "Add VSP2 FASTQ Workflow" action that creates this graph:

```text
FASTQ Bundle Input
  -> Remove PCR duplicates
  -> Adapter + quality trim
  -> Remove human reads
  -> Merge overlapping pairs
  -> Remove short reads
  -> Project output
```

The action lays out nodes left to right, connects ports, and fills parameters from `vsp2.recipe.json`. The user still chooses the explicit input bundle in the input node inspector.

This gives users a tangible end-to-end path while keeping every step visible and editable.

## Accuracy Testing

The VSP2 import recipe is the oracle for this slice.

Tests should create a FASTQ fixture and compare:

1. Existing VSP2 recipe execution path.
2. Workflow Builder expanded graph execution over an already imported `.lungfishfastq` input.

Required comparisons:

- Final retained read sequences and qualities after normalizing ordering when needed.
- Read counts.
- Pairing or merged/single layout metadata.
- Applied parameter values.
- Step labels and step ordering.
- Output bundle metadata.
- Output provenance completeness.
- Final provenance output paths point at stored bundle payloads.

Where byte-for-byte checksums are deterministic, assert exact checksums. Where gzip timestamps or tool output ordering make byte identity unstable, compare normalized FASTQ records and metadata instead.

## Migration and Compatibility

Existing saved workflows must still decode. Legacy abstract nodes remain available for existing exporter tests and manual workflows.

New concrete VSP2 nodes should be additive. If old `.lungfishflow` bundles lack the new fields, default decoding behavior should preserve the existing graph.

## Test Plan

Unit tests:

- New node types expose expected ports, labels, categories, and defaults.
- Parameter validation rejects bad VSP2 values.
- Explicit input node stores and round-trips project-relative bundle references.
- Graph validation reports missing input bundle references.
- Delete selection removes nodes and connections while preserving pinned anchors.
- VSP2 exemplar graph builder creates the expected node sequence and connections.

App tests:

- Palette includes VSP2 operation nodes.
- Inspector edits node labels and parameters.
- Inspector selects a project-local `.lungfishfastq` bundle.
- Workflow library lists, opens, duplicates, renames, and deletes `.lungfishflow` bundles.

Runner tests:

- Supported VSP2 graph dispatches node-by-node.
- Failure marks downstream nodes skipped.
- Run record includes graph checksum, node statuses, bindings, outputs, and provenance.
- Derived output bundle contains complete provenance.
- Builder VSP2 output matches the existing recipe oracle on normalized FASTQ content and metadata.

CLI or integration tests:

- Existing `lungfish import fastq --recipe vsp2` behavior remains unchanged.
- Workflow Builder run records remain readable and diffable through existing workflow tooling.

## Acceptance Criteria

- A user can create or insert the VSP2 exemplar graph in the Workflow Builder.
- A user can select explicit `.lungfishfastq` input bundle nodes from the active project.
- A user can connect, edit, and delete graph objects without corrupting the graph.
- A user can manage multiple saved workflows in the active project.
- Running the exemplar creates derived `.lungfishfastq` outputs.
- The run and each derived output include complete provenance.
- Automated parity tests show the builder VSP2 graph matches the existing VSP2 recipe path for scientific output.
