# Mapping Bundle Viewer, Inspector, and Annotation Actions Design

Date: 2026-04-21
Status: Revised after expert review

## Summary

Managed read-mapping results should become a first-class mapping analysis surface rather than a thin split view bolted onto the generic genomics viewer. The mapping result experience should combine:

- a classifier-style contig list with search, sort, per-column filters, and familiar typography
- an embedded BAM/reference viewer that keeps the existing annotation drawer and reference-bundle rendering stack
- a mapping-specific `Document` inspector with layout controls, provenance, source-data linkbacks, and artifact links
- CLI-backed interval extraction from selected annotations using `samtools view`

The design should reuse the full viewer bundle already copied into each mapping analysis directory. That bundle already contains the reference sequence and its annotations. The missing work is shell integration, mapping-specific inspector state, provenance persistence, and parity affordances around table behavior, zoom shortcuts, and annotation-to-read extraction.

## Goals

- Make managed mapping results a first-class viewport mode with mapping-specific inspector behavior.
- Add `Detail | List`, `List | Detail`, and `List Over Detail` layout controls to the mapping `Document` inspector.
- Make the mapping list match classifier list typography and interaction patterns.
- Add classifier-style per-column filtering and sorting to the mapping contig list.
- Preserve the full embedded BAM/reference viewer instead of downgrading to a custom mini-view.
- Add miniBAM-style keyboard zoom shortcuts and context-menu zoom actions to the embedded mapping BAM viewer.
- Show annotations from the source reference bundle inside the mapping detail surface and let users:
  - filter annotations
  - zoom to an annotation interval
  - extract reads overlapping that interval via `samtools view`
- Populate the mapping `Document` inspector with mapping provenance, source FASTQ/reference linkbacks, and output artifact links.
- Keep all data-producing operations CLI-backed and testable.
- Add deterministic XCTest and XCUI coverage for layout, filtering, annotation actions, and extraction routing.

## Non-Goals

- Do not replace the embedded full `ViewerViewController` with a second BAM renderer.
- Do not build a mapping-specific annotation database or search stack separate from the copied reference bundle.
- Do not introduce variant calling or variant summaries in this pass.
- Do not redesign the global inspector shell or main window chrome beyond mapping-specific content.
- Do not implement multi-BAM comparison, coverage overlays from multiple analyses, or cohort/sample matrices in this pass.

## Product Decisions

### 1. Mapping Gets Its Own Content Mode

Mapping results should no longer masquerade as generic `.genomics` content. Add a dedicated `.mapping` `ViewportContentMode`.

Reasons:

- the `Document` inspector needs mapping-specific provenance and layout controls
- mapping should not inherit unrelated generic bundle metadata behavior
- mapping selection behavior should be explicit instead of accidental side effects from genomics mode

Approved inspector-tab behavior for `.mapping`:

- `Document` is always available
- `Selection` remains available when the embedded viewer emits annotation/read selections
- `AI` is not required in this pass

This keeps the mapping analysis metadata in the right place without removing useful selection inspection from the embedded viewer.

#### Mapping Mode Consumer Matrix

The new `.mapping` mode must be treated as an explicit first-class mode, not as a partial alias of `.genomics`.

Approved first-pass behavior:

- inspector tabs:
  - `Document`
  - `Selection`
- inspector content:
  - mapping-specific `Document`
  - standard genomics `Selection` fed by the embedded viewer
- toolbar:
  - mapping should keep only controls that make sense for the embedded BAM/reference viewer
  - generic whole-document controls that assume the top-level viewer owns the window chrome must be reviewed explicitly before enabling
- drawers:
  - the embedded viewer’s annotation drawer remains available inside the mapping detail pane
  - the top-level viewer should not expose a second competing drawer surface for the mapping shell

Implementation work must enumerate every existing `ViewportContentMode` consumer touched by toolbar visibility, inspector tabs, and drawer availability so `.mapping` is intentional everywhere it appears.

### 2. The Mapping Shell Stays Two-Pane, but Uses Shared Layout Infrastructure

The mapping viewport should use the same tracked split-view machinery already used by assembly and metagenomics result shells:

- `TrackedDividerSplitView`
- `TwoPaneTrackedSplitCoordinator`
- a dedicated persisted mapping layout enum

Supported layouts:

- `Detail | List`
- `List | Detail`
- `List Over Detail`

Behavior requirements:

- layout changes apply immediately
- current contig selection remains intact
- list filter/sort state remains intact
- divider position persists sensibly across window resizes

### 3. The Mapping List Reuses Classifier Table Patterns

The left list should stop being a one-off `NSTableView` and adopt the classifier table interaction model:

- search field above the table
- sortable columns
- per-column filter menus in headers
- alternating row backgrounds
- 22 pt row height equivalent
- text cells using the same classifier list text font
- numeric cells using the same classifier list monospaced digit font

The cleanest path is a dedicated `MappingContigTableView` built on the same table/filter infrastructure already used by classifier tables, not a bespoke implementation.

Reuse requirements:

- reuse the shared sort/filter/header-menu infrastructure
- do not inherit classifier-only sample metadata columns
- do not inherit classifier sample pickers or batch-only row affordances

Approved typography target:

- text: `.systemFont(ofSize: 12)`
- numeric values: `.monospacedDigitSystemFont(ofSize: 12, weight: .regular)`

This matches the existing classifier table family closely enough to satisfy the parity requirement without inventing a mapping-only look.

### 4. The BAM Detail Surface Reuses the Full Viewer Bundle

Each mapping result already has a copied viewer bundle containing:

- the reference sequence
- annotation tracks from the source bundle
- the imported BAM and index
- the existing annotation search/drawer infrastructure

The design should continue embedding `ViewerViewController` inside the mapping result shell. The work is to expose the right behavior through the mapping shell rather than fork a new BAM viewport stack.

Fallback rule:

- if a copied viewer bundle is present, mapping opens with the full BAM/reference/annotation detail surface
- if no copied viewer bundle is present, mapping still opens in degraded mode with the contig list, summary, and document inspector intact, but the detail pane shows a mapping-specific placeholder and annotation actions are disabled with explicit messaging
- absence of a copied viewer bundle is not an open-time fatal error for legacy or FASTA-only analyses

### 5. Annotation Workflows Ride on the Existing Annotation Drawer

The mapping detail surface should keep the embedded viewer’s annotation drawer visible and functional. That drawer already supports filtering, sorting, and selection against the copied annotation database.

For mapping results, annotation selection must additionally support:

- `Zoom to Annotation`
- `Extract Overlapping Reads…`

`Zoom to Annotation` should navigate the BAM viewer to the selected annotation interval.

`Extract Overlapping Reads…` should create a BAM-region extraction request using the selected annotation’s chromosome/start/end and the mapping analysis BAM, then route it through the app’s existing extraction service so the operation is still `samtools`-backed.

Coordinate and feature contract:

- `SequenceAnnotation` intervals are 0-based, end-exclusive
- zoom should use the annotation bounding region expanded by a small context window
  - approved first-pass padding: `max(50 bp, 2% of bounding span)` on each side, clamped to the chromosome bounds
- extraction must convert each interval block to `samtools` region notation (`1`-based, end-inclusive)
- discontinuous annotations must extract from the union of blocks, not from the coarse bounding span
- a discontinuous annotation may still zoom using the padded bounding span for user orientation
- if an annotation has no resolvable chromosome or the copied annotation bundle is unavailable, both actions are disabled and the UI must say why

### 6. Mapping Provenance Must Be Persisted Explicitly

`MappingResult` alone is too thin for the requested inspector. A mapping-specific provenance sidecar should be introduced, analogous in purpose to assembly provenance but smaller in scope.

The sidecar should persist:

- mapper ID and display name
- preset / mode ID and display label
- sample name
- read-class hints inferred at launch time
- thread count
- `minimumMappingQuality`
- `includeSecondary`
- `includeSupplementary`
- advanced arguments
- resolved FASTQ source paths
- resolved reference FASTA path
- source reference bundle path when present
- viewer bundle path when present
- exact argv for the mapper invocation
- exact argv for normalization/index/stat steps that materially affect the final BAM
- mapper version
- `samtools` version used for normalization/extraction steps
- wall-clock runtime
- timestamp

Version capture is required for real managed runs. Deterministic UI-test backends may record a synthetic sentinel such as `ui-test-deterministic`.

Compatibility contract:

- `mapping-result.json` remains the primary lightweight result contract
- `mapping-provenance.json` is optional but preferred
- old analyses with only `mapping-result.json` must still open
- missing provenance yields a partial inspector with explicit “provenance unavailable” rows rather than an open failure
- provenance loading must have deterministic merge/fallback rules so a stale or absent sidecar does not make the UI ambiguous

### 7. “CLI-Backed” Means Artifact-Producing Operations, Not Pure View State

The user asked that these activities be CLI-backed. For this feature, that means:

- mapping execution remains driven by the managed CLI/native tool pipeline
- extraction of reads from annotation intervals must be backed by `samtools view`
- command strings should be surfaced to `OperationCenter` for extraction jobs where practical
- persisted provenance must describe what was actually executed

Pure view-state interactions such as column sorting, list filtering, pane layout, and zoom are UI actions over CLI-produced artifacts. They do not need their own CLI invocation.

### 8. Mapping State Ownership Must Stay Out of the Inspector

The inspector should render mapping document state, not assemble it.

Approved ownership split:

- `MappingProvenanceLoader`
  - pure loader/decoder with compatibility handling for missing or old provenance sidecars
- `MappingDocumentStateBuilder`
  - pure builder that merges `MappingResult`, optional provenance, and project-resolution context into inspector-facing state
- `MainSplitViewController`
  - orchestration only
- `InspectorViewController`
  - presentation only

This keeps the document model testable and avoids turning `InspectorViewController` into the source of truth.

## Current State

The repo already has useful pieces in place:

- `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
  - currently embeds a full `ViewerViewController`
  - currently uses a fixed left/right split and a hand-built `NSTableView`
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`
  - already routes mapping results into a dedicated result controller
  - currently still marks the viewer content mode as `.genomics`
- `Sources/LungfishApp/App/AppDelegate.swift`
  - already copies the source reference bundle into a viewer bundle for mapping analyses
- `Sources/LungfishWorkflow/Mapping/MappingResult.swift`
  - already persists mapper, BAM/BAI, copied viewer bundle, and contig summaries
  - does not persist command lines or enough source/provenance detail for inspector use
- `Sources/LungfishApp/Views/Metagenomics/BatchTableView.swift`
  - already provides the sort/filter/header-menu foundation needed for the mapping list
- `Sources/LungfishApp/Views/Layout/TwoPaneTrackedSplitCoordinator.swift`
  - already provides the layout-swap behavior needed for left/right and stacked mapping layouts
- `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift`
  - already contains the exact zoom shortcut semantics the user wants mirrored
- `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift`
  - already provides searchable/sortable annotation tables
- `Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift`
  - already provides BAM-region extraction backed by `samtools`

The gap is integration, not raw capability.

## Recommended Architecture

### 1. Add Mapping Content-Mode Plumbing

Add `.mapping` to `ViewportContentMode` and route managed mapping results through it.

Responsibilities:

- `ViewerViewController+Mapping` sets `.mapping`
- `InspectorViewController` exposes mapping-appropriate tabs
- main-window toolbar/inspector logic treats `.mapping` intentionally rather than as generic genomics
- all other `ViewportContentMode` consumers are audited and either assigned explicit `.mapping` behavior or intentionally left unsupported

### 2. Add Dedicated Mapping Layout Preference State

Create `MappingPanelLayout` mirroring the existing assembly/metagenomics pattern.

Requirements:

- stored under its own defaults key
- bridged into `DocumentSectionViewModel`
- immediately applies to `MappingResultViewController`
- used by a shared inspector control rendered inside the mapping document section

### 3. Replace the Hand-Built Mapping Table with a Reusable Table Class

Create `MappingContigTableView` rather than continuing to grow the one-off `NSTableView`.

Recommended structure:

- subclass the shared batch-table infrastructure or extract the reusable portions needed for a non-batch result table
- fixed columns for:
  - `Contig`
  - `Length`
  - `Mapped Reads`
  - `% Mapped`
  - `Mean Depth`
  - `Coverage Breadth`
  - `Median MAPQ`
  - `Mean Identity`
- per-column filter state keyed by column identifier
- sort descriptors persisted for the life of the controller instance
- command-click quick copy of scalar cell values where already supported by the shared table stack

Metric contract:

- all table metrics are computed from the final normalized BAM written by the mapping pipeline
- the inspector must surface the normalization filters that define that BAM:
  - `minimumMappingQuality`
  - `includeSecondary`
  - `includeSupplementary`
- `Mapped Reads` is an alignment count, not a deduplicated fragment count
- `% Mapped` is persisted and displayed as a percentage in the range `0...100`; the UI must not scale it a second time
- `Coverage Breadth` is displayed as a percentage in the range `0...100`
- default initial sort is `Mapped Reads` descending, then contig name ascending

Filter contract:

- text columns use the existing classifier text operators
- numeric columns use the existing classifier numeric operators (`≥`, `≤`, `=`, `between`)

### 4. Introduce Mapping Document Inspector State

Add a `MappingDocumentState` and a dedicated `MappingDocumentSection`, parallel to the assembly document section.

Approved section order:

1. header
2. layout controls
3. source data
4. mapping context
5. source artifacts

#### Header

Should show:

- analysis/output name
- mapper display name
- preset / read mode summary
- high-level mapping summary such as mapped reads percentage

#### Source Data

Should resolve and show:

- FASTQ bundle(s) or FASTQ file(s) used as inputs
- source reference bundle when available, clearly labeled as the original source bundle
- resolved reference FASTA

If a copied viewer bundle exists, it should appear separately under artifacts as a derived snapshot, not be confused with the original source reference.

Each row should prefer project navigation when the path maps to a sidebar item and fall back to filesystem reveal when it does not.

#### Mapping Context

Should show the actual run configuration, including:

- mapper
- preset / mode
- sample name
- paired-end vs single-end
- thread count
- quality / secondary / supplementary filters
- advanced arguments
- runtime
- exact executed command line(s)
- mapper version
- `samtools` version

#### Source Artifacts

Should expose link/reveal actions for:

- sorted BAM
- BAM index
- copied viewer bundle
- mapping result sidecar
- mapping provenance sidecar
- reference index directory when persisted under the analysis output

### 5. Add Mapping Provenance Persistence

Add a mapping provenance model and sidecar in `LungfishWorkflow/Mapping`.

Preferred filenames:

- `mapping-result.json` remains the lightweight result sidecar
- add `mapping-provenance.json` for richer inspector-facing context

Creation points:

- normal managed mapping flow
- deterministic UI-test mapping backend

Loading points:

- `MainSplitViewController.displayMappingAnalysisFromSidebar(at:)`
- `MappingDocumentStateBuilder`

`MappingResult.load(from:)` should remain the single required open path for analyses. Provenance loading is layered on top and may fail independently without blocking the viewport.

### 6. Add a Mapping-Specific Annotation Extraction Action

Introduce a mapping action layer that translates annotation selections into BAM-region extraction requests.

Expected behavior:

- the user selects an annotation in the embedded annotation drawer or annotation context menu
- `Zoom to Annotation` recenters and frames the selected interval
- `Extract Overlapping Reads…` presents the standard extraction destination/configuration UI for BAM-region extraction
- extraction runs through `ReadExtractionService.extractByBAMRegion`
- `OperationCenter` shows a CLI-oriented description derived from `samtools view`

Selection-to-region behavior should use the annotation interval as stored in the copied viewer bundle. Reference name reconciliation should continue using the existing BAM-region matching helpers rather than string-splicing region names directly.

Filter behavior for extraction:

- first pass uses the same alignment population visible in the final normalized BAM
- no hidden widening to include filtered-out secondary/supplementary reads
- if a future UI wants alternate extraction populations, that is a separate feature

### 7. Add MiniBAM Shortcut Parity to the Embedded Mapping Viewer

The embedded full viewer already supports zoom and context menus, but mapping needs reliable parity with the miniBAM experience when nested inside the mapping shell.

Required additions:

- local handling for `Command` + `=`, `+`, `-`, `_`, `0`
- context menu entries for:
  - `Zoom In`
  - `Zoom Out`
  - `Zoom to Fit`
  - `Center View Here`
- responder/focus handling robust enough for an embedded viewer living inside `MappingResultViewController`

The cleanest implementation is to extract the common zoom-shortcut logic into a shared helper that both `MiniBAMViewController` and the embedded full viewer can use, rather than copying the switch statements again.

## UI Design

### Mapping Viewport

The mapping viewport remains:

- summary strip at top
- classifier-style contig list
- embedded BAM/reference viewer

The list/detail split swaps or stacks via the mapping layout preference. The mapping result shell should not add a second provenance pane inside the main viewport.

### Annotation Surface

The existing bottom annotation drawer inside the embedded viewer remains the primary annotation table for mapping results.

Its responsibilities:

- annotation filtering
- annotation sorting
- row selection
- row-to-viewer navigation

The mapping-specific additions are action affordances, not a new annotation table.

Integration constraint:

- extend the shared `AnnotationTableDrawerView` and `ViewerViewController` action path with a mapping-host hook or coordinator
- do not create a second mapping-only annotation action implementation that forks menu logic from the shared drawer

### Document Inspector

The right inspector should read like an analysis document, not a generic bundle:

- what run is this
- what data was used
- how was it run
- what files came out of it
- how should the panes be laid out

This mirrors the assembly inspector direction and keeps mapping provenance out of the central viewer pane.

## Data and Command Flow

### Mapping Result Load

1. User selects a mapping analysis in the sidebar.
2. `MainSplitViewController` loads `MappingResult`.
3. The same path optionally loads `MappingProvenance`.
4. `MappingDocumentStateBuilder` builds a `MappingDocumentState`.
5. `ViewerViewController` displays the mapping shell in `.mapping` mode.
6. `InspectorViewController` receives the prebuilt `MappingDocumentState`.
7. `MappingResultViewController` loads the copied viewer bundle into the embedded viewer when available and otherwise enters degraded mode with explicit placeholder copy.

### Annotation Interval Extraction

1. User selects an annotation in the embedded viewer.
2. Mapping action layer resolves the interval and BAM URL from the active `MappingResult`.
3. The action layer converts annotation intervals from 0-based half-open blocks to `samtools` regions.
4. The app presents extraction options.
5. The request is executed through `ReadExtractionService.extractByBAMRegion`.
6. The extraction operation logs or displays the effective `samtools view` command through `OperationCenter`.
7. Resulting outputs are routed through the normal extraction destination path.

## Testing Requirements

### Unit / App Tests

- mapping layout preference persistence and application
- mapping document-state construction from result + provenance
- mapping source-data link resolution
- mapping artifact row generation
- mapping contig table sort and per-column filter behavior
- mapping metric-unit rendering and no double-scaling of percentages
- mapping annotation extraction request formation
- mapping multi-interval annotation extraction request formation
- mapping degraded-mode state when provenance or viewer bundle is missing
- mapping extraction CLI description generation
- mapping viewer shortcut handling in embedded context

### XCUI

Add deterministic UI tests that cover:

- running a mapping tool and opening the result viewport
- switching between `Detail | List`, `List | Detail`, and `List Over Detail`
- filtering the contig table by at least one numeric and one text column
- sorting by a numeric column
- invoking `Command` zoom shortcuts in the mapping detail viewer
- opening/filtering the annotation drawer in a mapping result
- selecting an annotation and zooming to it
- invoking overlap-read extraction from an annotation and verifying the operation is launched
- opening a legacy or degraded mapping result and verifying the empty/disabled messaging
- validating that the mapping `Document` inspector shows source data, mapping context, and artifact links

## Acceptance Criteria

- Mapping analyses open in a dedicated mapping viewport mode.
- The `Document` inspector for mapping analyses shows layout controls and mapping-specific provenance/artifact content.
- The mapping contig list matches classifier typography and exposes classifier-style per-column filtering and sorting.
- Layout changes work in both left/right orientations and stacked mode without dropping selection state.
- The embedded mapping viewer supports miniBAM-style keyboard zoom shortcuts and zoom context-menu actions.
- Annotations from the source reference bundle are visible and filterable in mapping results.
- Selecting an annotation supports zooming to the annotation and extracting overlapping reads.
- Read extraction is backed by `samtools view` through the shared extraction pipeline.
- Deterministic XCTest and XCUI coverage exercise the new behaviors.

## Open Questions Resolved in This Spec

- **Should mapping use a second BAM viewer implementation?**
  - No. Reuse the existing copied full viewer bundle and embedded `ViewerViewController`.
- **Should mapping metadata live inside the viewport detail pane?**
  - No. Put it in the right-sidebar `Document` inspector.
- **Should mapping keep a selection-capable inspector path?**
  - Yes. Keep `Selection` available in mapping mode while making `Document` mapping-specific.
- **Should annotation filtering be reimplemented for mapping?**
  - No. Reuse the existing annotation drawer/search infrastructure in the copied viewer bundle.
- **What does CLI-backed mean here?**
  - Extraction and analysis-producing operations must be backed by the managed CLI/native tool pipeline; list filtering, layout, and zoom remain UI state.
