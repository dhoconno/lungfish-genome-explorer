# Assembly Document Inspector and FASTA Action Surface Design

Date: 2026-04-21
Status: Approved in conversation

## Summary

Assembly results should use the standard right-sidebar `Document` inspector, populated with assembly-specific document content, instead of embedding provenance and artifact metadata inside the viewport detail pane.

The assembly viewport itself should remain focused on contig browsing and reuse: summary strip, list, reads-style detail content, and action bar. The detail content should resemble the FASTQ `Reads` surface, but adapted for contigs and without quality-score columns or FASTQ-only affordances.

Sequence-oriented actions should not stop at assembly results. BLAST verification, copy/export FASTA, bundle creation, and operation dispatch should be available consistently across assembler-produced contigs, NVD contigs, and standalone FASTA sequences through a shared FASTA action model.

## Goals

- Put assembly-specific document metadata in the same right-sidebar `Document` inspector used by other document types.
- Make assembly results expose only the `Document` inspector surface while active.
- Keep the assembly viewport focused on contig browsing, sequence preview, and downstream reuse.
- Provide layout controls for `Detail | List`, `List | Detail`, and `List Over Detail` through the `Document` inspector.
- Distinguish original source data from generated source artifacts.
- Support linkbacks from assembly provenance inputs to project-resolved source data when possible.
- Align assembly contig actions with the sequence-oriented control-click actions already used elsewhere for FASTA-backed content.
- Ensure all managed assemblers use the same general assembly result viewport.
- Build explicit capability gating so FASTA-backed selections only offer valid operations.

## Non-Goals

- Do not introduce a second inspector panel inside the assembly viewport.
- Do not add an operations sidebar to the assembly viewport in this pass.
- Do not expose FASTQ-specific affordances such as quality scores, read pair repair, or FASTQ metadata editing on assembly contigs.
- Do not redesign the existing right sidebar layout beyond adding assembly-specific `Document` content.
- Do not treat selected-contig materialization as a new assembly analysis type.

## Product Decisions

### 1. Inspector Placement

Assembly document metadata lives in the app’s normal right-sidebar inspector, exactly where other `Document` inspectors live. There is no assembly-specific inspector embedded inside the main viewport.

### 2. Inspector Tabs for Assembly

When an assembly result is active, the inspector should expose only the `Document` tab. `Selection` and `AI` should not be shown for assembly results in this pass.

### 3. Viewport Detail Content

The viewport detail area should not present long provenance text blocks. Instead, it should show a reads-style contig surface that combines contig metadata with a compact preview of the beginning of the sequence.

There should be no `Reads` or `Operations` tabs inside the assembly detail pane for this pass. The detail pane itself is the single contig content surface.

### 4. FASTA Action Consistency

Actions that apply to nucleotide sequences should be available to assembler-produced contigs just as they are for other FASTA-backed content. These include BLAST verification, copy/export FASTA, bundle creation, and operation dispatch.

## Current State

The repo already contains the foundation for this feature, but the assembly result experience is split incorrectly:

- `Sources/LungfishApp/Views/Results/Assembly/AssemblyResultViewController.swift`
  - already uses the shared split-pane layout machinery and an assembly action bar
  - still treats provenance and source artifacts as viewport detail text instead of document-inspector content
- `Sources/LungfishApp/Views/Results/Assembly/AssemblyContigDetailPane.swift`
  - currently renders `Assembly Context` and `Source Artifacts` directly in the viewport detail area
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
  - already adapts tabs based on `ViewportContentMode`
  - currently has no assembly-specific content mode
- `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
  - already acts as the umbrella document inspector model
  - does not yet model assembly-specific content
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+Assembly.swift`
  - currently routes assembly views through `.genomics`
- `Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift`
  - already provides the reads-style content pattern to borrow for contig detail preview
- `Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift`
  - already exposes BLAST and contig-sequence actions through a context menu for FASTA-backed NVD hits
- `Sources/LungfishIO/Formats/FASTQ/FASTQDerivatives.swift`
  - already encodes which derivative operations can work on FASTA through `supportsFASTA`

The main missing work is to make assembly a first-class inspector mode, simplify the viewport detail content, and unify FASTA-backed actions across assembly, NVD, and standalone FASTA browsing.

## Recommended Architecture

### 1. Add an Assembly Viewport Content Mode

Add `ViewportContentMode.assembly` and use it when `AssemblyResultViewController` is active.

Reasons:

- assembly results are not generic genomics documents
- assembly results should not inherit genomics inspector tabs such as `Selection`
- assembly-specific `Document` content should be routed cleanly rather than hidden behind generic branching

`MainWindowController`, `InspectorViewController`, and the viewer routing layer should treat `.assembly` as a first-class mode rather than piggybacking on `.genomics`.

### 2. Keep the Existing Document Inspector Shell

Do not create a separate assembly inspector controller. Keep the existing inspector shell and tab framework, but render assembly-specific content under the existing `Document` tab when the content mode is `.assembly`.

The cleanest implementation is:

- keep `DocumentSectionViewModel` as the umbrella document inspector model
- add an assembly-specific payload/state to it
- render a dedicated `AssemblyDocumentSection` from the inspector when content mode is `.assembly`

This keeps assembly-specific layout and provenance logic from leaking into the already overloaded generic document branch while still preserving the user-facing `Document` tab.

### 3. Keep the Shared Assembly Viewport Shell

All managed assemblers should continue to route through the same `AssemblyResultViewController`.

The shared viewport should still contain:

- summary strip
- contig list
- detail pane
- bottom action bar

The viewport should continue using the existing shared split-layout preference and divider behavior for `Detail | List`, `List | Detail`, and `List Over Detail`.

## Inspector Design

### Assembly Document Section Order

The assembly `Document` inspector should follow the same general organization as other document inspectors. The approved order is:

1. document identity/header
2. layout controls
3. `Source Data`
4. `Assembly Context`
5. `Source Artifacts`

### Document Identity/Header

This section should show the basic identity of the analysis/result, such as:

- analysis name / output directory name
- assembler display name
- read type
- top-level summary cues already familiar from other document inspectors

### Layout Controls

The existing shared layout preference surface should be presented here, above provenance and artifact information.

Supported options:

- `Detail | List`
- `List | Detail`
- `List Over Detail`

Behavior requirements:

- persists using the shared existing layout preference mechanism in the first pass
- changes apply immediately to the active assembly viewport
- does not clear selection, filters, or scroll state

### Source Data

`Source Data` represents the original input data used to create the assembly, not files generated by the assembly process.

Primary source:

- `AssemblyProvenance.inputs`

Each row should attempt to resolve into one of two forms:

- project linkback:
  - if the provenance input path maps to a known project/sidebar item, show it as a link-style action that navigates the sidebar to the source item
- filesystem fallback:
  - if the item cannot be resolved into project navigation but the path exists, provide reveal/open filesystem actions

This section is intentionally separate from `Source Artifacts` so original inputs are not mixed with generated outputs.

### Assembly Context

`Assembly Context` is the provenance-facing section. It should include:

- assembler
- read type
- assembler version when available
- execution backend when available
- runtime / wall time
- command line
- relevant run parameters
- core summary metrics already present on `AssemblyResult`

Where a full provenance record exists, it should be the preferred truth source for execution and input context.

### Source Artifacts

`Source Artifacts` represents generated files from the assembly output and sidecars. It should include link/reveal actions for:

- contigs FASTA
- scaffolds FASTA when present
- graph output when present
- log output when present
- params file when present
- provenance sidecar when present

These should be rendered as filesystem-backed rows, using the same general reveal/open vocabulary already used for attachments and related file rows elsewhere in the app.

## Viewport Design

### Shell

The assembly viewport remains:

- summary strip at top
- contig list and detail arranged by the shared split layout
- action bar at bottom

### Contig List

The existing list-first model stays intact. The current table styling is already directionally correct.

It should continue to provide:

- search/filter
- sortable contig rows
- multi-selection
- stable context menu entry point for sequence actions

### Detail Pane

The detail pane should adopt the FASTQ `Reads` view idea, but specialized for contigs.

It becomes a single surface rather than a tabbed area.

Expected content:

- concise selected-contig metadata
- a preview row or rows showing the beginning of the sequence
- multi-selection summary when more than one contig is selected

It should not show:

- provenance blocks
- source artifact blocks
- tabs for `Reads` or `Operations`
- FASTQ-only columns such as quality score summaries

Recommended first-pass columns/fields:

- row index or rank
- contig name
- length
- sequence preview

For single selection, the pane can emphasize one contig and its preview. For multi-selection, it should switch to a compact summary plus selected-row preview content rather than concatenating full FASTA text.

## Shared FASTA Action Surface

### Purpose

Users should be able to perform the same class of sequence-oriented actions on:

- assembly contigs
- NVD contigs
- standalone FASTA sequences

These actions should not be redefined independently in each controller.

### Common Action Set

The shared FASTA action surface should include:

- `Verify with BLAST…`
- `Copy FASTA`
- `Export FASTA…`
- `Create Bundle…`
- `Run Operation…`

For assembly results:

- these actions should remain available from the action bar
- they should also be reachable from control-click / context menu

For NVD contigs:

- the existing BLAST/copy-sequence model should migrate onto the shared FASTA action vocabulary where feasible

For standalone FASTA browsing:

- `FASTACollectionViewController` should gain the same style of control-click sequence actions

### Extraction / Materialization Model

The user-approved behavior is that if deeper work is needed on an individual sequence, the user should either:

- copy it to the clipboard
- export it to a file
- materialize it into an app file bundle
- run an operation on it

Assembly should therefore reuse the same general materialization shape as classifier extraction and FASTA sequence export flows rather than inventing a new assembly-only export concept.

The wording should stay honest to the content:

- FASTA-backed surfaces should talk about sequences/contigs rather than `reads`
- classifier-specific `Extract Reads…` wording should not be copied literally onto assembly/FASTA surfaces

## Operation Registry and Capability Gating

### Problem

The current operation surface is still conceptually FASTQ-first, with FASTA support mostly represented by a `supportsFASTA` flag on derivative operations.

That is enough to bootstrap this feature, but not enough to guarantee correct action menus across all FASTA-backed surfaces.

### Required Direction

Each operation/tool that can be launched from FASTA-backed content should have explicit capability gating:

- FASTQ-only
- FASTA-only
- both FASTA and FASTQ

First pass:

- reuse the existing `supportsFASTA` coverage where it exists
- hide FASTQ-only operations from assembly contigs and standalone FASTA sequences
- allow sequence operations that are valid without quality scores

Examples already encoded as FASTA-compatible in `FASTQDerivativeOperationKind`:

- subsampling
- length filtering
- text/motif search
- deduplication
- fixed trim
- orient
- contaminant filter
- sequence presence filter

Examples that must remain hidden for FASTA-backed selections:

- quality trim
- adapter trim when quality-score-dependent flow is assumed
- paired-end merge
- paired-end repair
- demultiplex
- human read scrub
- any operation requiring quality scores or paired-end synchronization

Longer term, the registry should move from a loose flag to a shared input-capability matrix that can drive:

- control-click menus
- future sidebar operation surfaces
- validation for assembly-, FASTA-, and classifier-backed sequence selections

## Assembler Routing

All managed assemblers should use the same assembly result viewport and inspector model:

- SPAdes
- MEGAHIT
- SKESA
- Flye
- Hifiasm

The routing should remain keyed off `AssemblyResult`, not assembler-specific UI controllers. Differences between assemblers should stay in the result payload and compatibility rules, not in separate viewport implementations.

## Data Flow

### Inspector Data Flow

1. user opens an assembly analysis
2. viewer routes to `AssemblyResultViewController`
3. viewer sets `ViewportContentMode.assembly`
4. inspector switches to `Document`-only availability
5. inspector loads assembly document payload from:
   - `AssemblyResult`
   - `AssemblyProvenance` if available
   - resolved project/sidebar references for provenance inputs
6. `AssemblyDocumentSection` renders the ordered sections in the right sidebar

### Viewport Data Flow

1. assembly result controller loads contig records from the shared catalog
2. list selection updates the reads-style detail surface
3. context menu and action bar both dispatch through the shared FASTA action layer
4. BLAST, FASTA export, bundle creation, and operation launch consume real FASTA content from the selected contigs

## Error Handling

- if provenance sidecar is missing:
  - still show `Assembly Context` from `AssemblyResult`
  - show `Source Data` as unavailable instead of suppressing the entire inspector
- if a provenance input path no longer exists:
  - keep the row visible but mark it unresolved
- if a project linkback cannot be resolved:
  - fall back to filesystem reveal/open when the file exists
- if a source artifact file is absent:
  - show it as missing rather than hiding the row silently
- if no FASTA-compatible operations are available for the selected contig(s):
  - `Run Operation…` should be disabled or omitted cleanly
- if BLAST materialization fails:
  - context menu and action bar should surface the failure the same way existing result viewports do

## Testing Strategy

### Inspector Routing

Add tests that verify:

- `ViewportContentMode.assembly` is emitted when assembly results are shown
- inspector tabs for assembly collapse to `Document` only
- assembly-specific document content appears in the right-sidebar document flow

### Assembly Document Section

Add tests for:

- approved section order
- source-data linkback resolution
- filesystem fallback for unresolved but existing provenance inputs
- source-artifact rows for contigs/scaffolds/graph/log/params/provenance

### Viewport

Add tests that verify:

- assembly detail pane no longer includes provenance/artifact text blocks
- reads-style detail content appears for single selection
- multi-selection shows selection summary plus preview-friendly content
- layout changes preserve selection and use the shared layout preference

### Shared FASTA Actions

Add tests that verify:

- assembly context menu includes BLAST/copy/export/bundle and uses real FASTA payloads
- action bar and context menu route through the same underlying FASTA action handling
- standalone FASTA collection rows get the shared FASTA action set
- NVD sequence actions stay aligned with the shared FASTA action behavior

### Capability Gating

Add tests that verify:

- FASTA-backed selections only offer FASTA-valid operations
- FASTQ-only operations are hidden for assembly contigs and standalone FASTA sequences
- BLAST verification remains available when valid sequence data exists

## Risks

- overloading the generic `DocumentSectionViewModel` without a distinct assembly payload will make the inspector harder to maintain
- keeping assembly on `.genomics` mode will leak incorrect inspector tabs and toolbar assumptions
- leaving NVD, assembly, and standalone FASTA actions separate will produce user-visible drift in sequence workflows
- relying on implicit FASTA support flags without a clearer capability model will cause invalid operations to surface in some menus

## Recommendation

Implement this as:

1. a first-class `.assembly` viewport content mode
2. a right-sidebar `AssemblyDocumentSection` rendered through the existing `Document` tab
3. a simplified reads-style assembly detail pane with no provenance blocks or tabs
4. a shared FASTA action surface reused by assembly, NVD, and standalone FASTA sequence browsers
5. explicit FASTA capability gating for operation exposure

This is the smallest coherent design that fixes the current assembly document-inspector problem while also aligning FASTA-backed workflows across the app.
