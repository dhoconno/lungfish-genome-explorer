# FASTQ Operations Dialog And CLI Refactor Design

Date: 2026-04-17
Status: Proposed

## Summary

Replace the current FASTQ operations UI with one consistent category-driven modal dialog system. The FASTQ dataset sidebar should show category-only launchers, each category should open the same sidebar-plus-detail dialog pattern, and every FASTQ operation should execute through a `lungfish-cli`-backed path with TDD and artifact-backed integration coverage.

This refactor should also establish a reusable shell for future dataset operation dialogs, such as BAM variant calling, without trying to solve every dataset type in the first pass.

## Goals

- Replace the mixed FASTQ operation UX of inline controls, bottom drawers, and separate sheets with one consistent modal interaction model.
- Keep the FASTQ operations list visible as category launchers, even for planned categories, while disabling categories whose required tool packs are not ready.
- Standardize tool panes so input selection, settings, validation, and run behavior feel the same across trimming, mapping, assembly, classification, and related tools.
- Support one or more FASTQ dataset inputs for most operations.
- Support two non-classification output strategies:
  - `Per Input`
  - `Grouped Result`
- Keep classification tools as a fixed batch-style exception with their existing bespoke result handling.
- Route every FASTQ operation launch through `lungfish-cli`.
- Treat virtual FASTQ materialization as a standard part of operation execution.
- Build the dialog shell so other dataset types can adopt it later.
- Add TDD coverage for UI state, command construction, virtual FASTQ handling, and artifact-backed operation results.

## Non-Goals

- Do not build a universal cross-dataset operation registry in this pass.
- Do not merge BAM, VCF, FASTA, and FASTQ operations into one global taxonomy.
- Do not support chaining multiple tools in one dialog session yet.
- Do not preserve the old FASTQ parameter bar or bottom-drawer configuration workflows.
- Do not require all existing tool-specific config structs and views to survive unchanged.
- Do not change classification result viewing or batch output semantics.

## Current State

The current FASTQ operation experience is inconsistent:

- `FASTQDatasetViewController` shows a sidebar of per-tool rows grouped by category headers.
- Some tools expose parameters in the middle pane's parameter bar.
- Some tools rely on bottom drawers, such as demultiplexing and primer trim metadata.
- Some tools route into separate tool-specific sheets, such as the classifier runner, minimap2 mapping, and SPAdes assembly.
- Some tool rows are actionable while others act mostly as descriptions.

Execution paths are also split:

- Many FASTQ transforms build a `FASTQDerivativeRequest`.
- Some tools route to separate app delegate handlers.
- Multi-input FASTQ execution already exists in `MainSplitViewController.runFASTQOperation`.
- `lungfish-cli` already exposes a substantial FASTQ operation surface.
- Virtual FASTQ materialization already exists, but it is not a first-class requirement of the current UI contract.

This means the app already has many of the pieces needed for a unified system, but the UI contract and availability model are fragmented.

## Design Principles

### One Interaction Model

Every FASTQ operation category uses the same launch and configuration pattern:

- click category
- modal opens
- user picks a tool from the left sidebar
- user configures the tool in the right pane
- user runs the selected tool

### Shell Reuse, Domain-Specific Semantics

The dialog shell should be reusable across dataset types, but FASTQ should own its own category map, tool descriptors, and execution logic.

### Pack Gating At The Category Level

Categories stay visible even when unavailable. Availability is determined from plugin pack readiness and core-tool readiness, not from one-off checks in individual views.

### Inputs And Outputs Are First-Class UI Concepts

Input FASTQ selection, reference selection, database selection, barcode selection, and output strategy should all be standard shells within the dialog, not tool-specific inventions.

### CLI Is The Execution Contract

The modal is a configuration surface only. Running a FASTQ tool means building a CLI invocation from validated dialog state and executing it through the standard app-side operation pipeline.

### Virtual FASTQs Must Behave Like Normal Inputs

Users should not have to care whether a selected FASTQ dataset is virtual or materialized. The execution pipeline must handle resolution and materialization consistently for every tool.

## User-Facing Information Architecture

### FASTQ Categories

Use this FASTQ category model in the first pass:

- `QC & REPORTING`
- `DEMULTIPLEXING`
- `TRIMMING & FILTERING`
- `DECONTAMINATION`
- `READ PROCESSING`
- `SEARCH & SUBSETTING`
- `MAPPING`
- `ASSEMBLY`
- `CLASSIFICATION`

This replaces the current `ALIGNMENT` label with `MAPPING` and keeps reporting/QC distinct from preprocessing.

### Category Visibility Rules

- All planned FASTQ categories remain visible in the FASTQ operations list.
- Categories with no currently available tools remain disabled.
- Disabled categories do not open the modal.
- Disabled categories show a clear reason, such as:
  - `Requires Alignment Pack`
  - `Requires Assembly Pack`
  - `Requires Metagenomics Pack`
  - `No tools available`

### Category Launchers

The FASTQ operations list becomes category-only launchers, not per-tool rows.

Each category row should show:

- category name
- optional short summary or status
- enabled or disabled state

There should be no expandable category headers with child rows in the FASTQ dataset view after this refactor.

### Quality Report Reframing

Keep a reporting/QC category, but stop framing the current cached/sample-based summary as a guaranteed full report.

The initial tool in `QC & REPORTING` should be labeled:

- `Refresh QC Summary`

The category remains future-facing for additional FASTQ report/export tools.

## Shared Dataset Operation Dialog Shell

### Shell Responsibility

Introduce a reusable shell, referred to here as `DatasetOperationsDialog`.

This shell owns only shared mechanics:

- modal framing
- title and dataset label
- category context
- left tool sidebar
- right detail pane
- shared validation/status footer
- run and cancel actions
- disabled/planned tool states

It should not own FASTQ-specific enum cases, derivative request types, or tool pack semantics.

### Shell Layout

The dialog uses a two-pane layout:

- left sidebar: tools within the selected category
- right pane: configuration for the selected tool

The right pane should use the same section order everywhere:

1. `Overview`
2. `Inputs`
3. `Primary Settings`
4. `Advanced Settings`
5. `Output`
6. `Readiness`

Not every tool needs every section, but the order and labels should remain stable.

### Shared Footer

The footer should always show:

- readiness or validation text on the left
- `Cancel` and `Run` buttons on the right

`Run` always means "run the currently selected tool", never "run the category".

## FASTQ Operation Registry

### FASTQ-Specific Catalog

Introduce a FASTQ-specific registry, referred to here as `FASTQOperationCatalog`.

This registry owns:

- category IDs
- category display order
- tool IDs
- tool labels and descriptions
- default tool per category
- availability state
- required pack IDs
- configuration view factory
- validation and execution bridge

### Category Descriptor Model

Each FASTQ category descriptor should expose:

- stable `categoryID`
- title
- summary
- required pack IDs
- visibility state
- enabled state
- disabled reason
- default tool ID

### Tool Descriptor Model

Each FASTQ tool descriptor should expose:

- stable `toolID`
- `categoryID`
- title
- subtitle
- plain-language description
- availability state:
  - `available`
  - `comingSoon`
  - `unavailable(reason)`
- configuration state object
- validation summary
- execution builder

The registry should use stable IDs so later workflow-building features can refer to tools and categories without depending on fragile display strings.

## FASTQ Tool Map

### QC & REPORTING

- `Refresh QC Summary`: available
- future report/export tools: visible but disabled until implemented

### DEMULTIPLEXING

- `Demultiplex by Barcodes`: available

### TRIMMING & FILTERING

- `Quality Trim`
- `Adapter Removal`
- `PCR Primer Trimming`
- `Trim Fixed Bases`
- `Filter by Read Length`

These are available if the core bundled tools required by the app setup are ready.

### DECONTAMINATION

- `Remove Human Reads`
- `Remove Spike-in / Contaminants`
- `Remove Duplicate Reads`

These are available if their required built-in tools or managed databases are ready. Tool-level prerequisites may still block execution inside the dialog.

### READ PROCESSING

- `Merge Overlapping Pairs`
- `Repair Paired-End Files`
- `Orient Reads`
- `Correct Sequencing Errors`

### SEARCH & SUBSETTING

- `Subsample by Proportion`
- `Subsample by Count`
- `Extract Reads by ID`
- `Extract Reads by Motif`
- `Select Reads by Sequence`

### MAPPING

- `minimap2`: available first
- future mapping tools: visible in the modal but disabled until implemented and supported

The `MAPPING` category depends on the alignment tool pack. The UI category name should be `MAPPING` even if the current pack ID remains `alignment`.

### ASSEMBLY

- `SPAdes`: available first
- future assembly tools: visible in the modal but disabled until implemented and supported

This category replaces the old separate SPAdes launch surface with a tool inside the shared assembly dialog.

### CLASSIFICATION

- `Kraken2`
- `EsViritu`
- `TaxTriage`

This category depends on the metagenomics pack and should be disabled until that pack is ready. Classification outputs remain batch-style and bespoke.

## Availability And Plugin Pack Gating

### Pack Dependency Mapping

In the first pass, category enablement should follow this dependency model:

- `QC & REPORTING`: core bundled tools / required setup pack
- `DEMULTIPLEXING`: core bundled tools / required setup pack
- `TRIMMING & FILTERING`: core bundled tools / required setup pack
- `DECONTAMINATION`: core bundled tools plus per-tool prerequisite checks
- `READ PROCESSING`: core bundled tools / required setup pack
- `SEARCH & SUBSETTING`: core bundled tools / required setup pack
- `MAPPING`: alignment pack
- `ASSEMBLY`: assembly pack
- `CLASSIFICATION`: metagenomics pack

### Status Source Of Truth

Use `PluginPackStatusService` as the pack readiness source of truth, but extend the service or wrap it so the dialog system can query specific pack IDs needed for category gating.

This is necessary because the current `visibleForCLI` behavior only exposes active optional packs, while the FASTQ operations UI needs status for inactive but relevant packs such as alignment and assembly.

The final gating API should be able to answer:

- does pack `alignment` exist and is it ready?
- does pack `assembly` exist and is it ready?
- does pack `metagenomics` exist and is it ready?

without depending on those packs being included in the current visible list.

### Category Vs Tool Readiness

Category readiness determines whether the category can open at all.

Tool readiness still matters inside enabled categories. Examples:

- the category opens because the pack is installed
- `Kraken2` then shows database selection as required
- `Orient Reads` then shows reference sequence selection as required
- `Remove Human Reads` then shows human scrubber database installation as required

Pack gating should never replace tool-level prerequisite checks.

## Standardized Inputs

### Locked Primary Input

Every FASTQ tool dialog should show the current FASTQ dataset selection as a standard input row. This is the default selected source when launching from a FASTQ dataset view.

### Multi-Input FASTQ Selection

Most FASTQ tools should allow one or more FASTQ dataset inputs.

The `Inputs` section should support:

- the currently selected FASTQ dataset
- adding additional FASTQ datasets
- removing optional inputs
- showing which inputs are virtual vs already materialized only if useful for status

Classification is the exception in output semantics, but it still participates in the multi-input dataset selection pattern.

### Additional Input Types

The shell should treat these as standard input picker patterns:

- reference sequence
- database
- barcode kit or barcode definition table
- adapter or primer source
- contaminant reference

Every picker row should use the same behavior:

- project-first selection when a project-native asset type exists
- `Browse…` fallback for external files
- selected-item card with name and source
- `Replace` or `Clear` actions
- consistent required/optional labeling
- inline validation when incompatible or missing

This means `MAPPING > minimap2` and `READ PROCESSING > Orient Reads` should use the same `Reference Sequence` picker contract instead of each defining its own style.

## Standardized Output Strategy

### Output Strategies For Non-Classification Tools

For most FASTQ tools, the `Output` section should present:

- `Per Input`
- `Grouped Result`

`Per Input` means one result per selected FASTQ dataset.

`Grouped Result` means one grouped result container in the project that holds per-input outputs under one top-level result item. It does not imply automatic concatenation of all reads into one FASTQ unless a future dedicated merge-style tool explicitly does that.

### Fixed Output Strategy

Some tools may use `Tool Fixed` output handling when the result structure is inherently defined by the tool.

### Classification Exception

Classification tools do not show the generic output-strategy control. Their outputs remain batch-style and bespoke.

## Tools Menu Entry Points

### Menu Structure

Add category entry points under the Tools menu using the same dialog shell used by the FASTQ dataset view.

Recommended structure:

- `Tools > FASTQ Operations > QC & Reporting…`
- `Tools > FASTQ Operations > Demultiplexing…`
- `Tools > FASTQ Operations > Trimming & Filtering…`
- `Tools > FASTQ Operations > Decontamination…`
- `Tools > FASTQ Operations > Read Processing…`
- `Tools > FASTQ Operations > Search & Subsetting…`
- `Tools > FASTQ Operations > Mapping…`
- `Tools > FASTQ Operations > Assembly…`
- `Tools > FASTQ Operations > Classification…`

Each menu item should open the category-scoped dialog with the same selected category and default tool that the FASTQ dataset view would use.

### Menu Enablement

Tools menu items should use the same category readiness model as the FASTQ dataset view:

- visible categories remain in the menu
- unavailable categories are disabled
- enabled/disabled state is driven by the registry and pack status, not duplicate logic

### Legacy Entry Point Cleanup

Existing one-off launch entries such as separate direct classifier and SPAdes actions should no longer define the user-facing interaction model. They can become internal routing helpers or be retired once the category launchers are in place.

## Reusable Cross-Dataset Seam

### Scope Of Generalization

This refactor should create a reusable shell seam now, because future BAM operations such as variant calling will need a similar category-driven modal.

However, FASTQ remains the first concrete adopter.

### What Becomes Generic Now

- dialog shell
- category and tool descriptor protocols
- left-sidebar tool selector
- right-pane section rhythm
- shared input picker row patterns
- shared footer/readiness behavior
- category launch routing from dataset views and menu items

### What Stays FASTQ-Specific For Now

- FASTQ category taxonomy
- FASTQ tool catalog
- FASTQ execution request mapping
- FASTQ-specific validation
- FASTQ-specific output import structure

This avoids turning the FASTQ refactor into a full generalized operations platform project while still creating the correct extension point for BAM and other dataset types.

## Execution Contract

### CLI As The Only FASTQ Run Path

The dialog layer should not execute FASTQ tools directly through ad hoc app-side tool launchers.

Instead, every FASTQ operation should resolve to a `lungfish-cli` invocation contract, even if the app wraps the process, tracks it in `OperationCenter`, or imports results after completion.

That means:

- derivative-style operations keep using a CLI-backed path
- mapping and assembly should be normalized to the same overall execution strategy
- QC/reporting should follow the same rule if it remains a runnable operation

### Multi-Input Execution

The execution layer should accept one or more FASTQ dataset inputs and the selected output strategy, then route through the existing batch-capable FASTQ operation pipeline where possible.

This should build on the current multi-input behavior already present in `MainSplitViewController.runFASTQOperation` rather than inventing a second batch mechanism.

### Virtual FASTQ Materialization

Every FASTQ execution path must assume that any input dataset may be virtual.

Standard execution sequence:

1. resolve selected FASTQ dataset inputs
2. detect which inputs are virtual
3. materialize virtual FASTQs as needed
4. build the final `lungfish-cli` invocation from resolved inputs
5. execute the tool
6. import and register outputs back into the project using the selected output strategy

The modal should surface this only through readiness or progress messaging when necessary. Users should not have to choose different workflows for virtual vs materialized FASTQs.

## Migration Strategy

### FASTQ Dataset View

Refactor `FASTQDatasetViewController` so that:

- the operation list becomes category-only
- the current parameter bar is removed as the primary configuration surface
- bottom-drawer dependencies for FASTQ operations are removed
- category launch triggers the new modal dialog

### Existing Tool-Specific Views

Existing sheets and tool-specific config views can be refactored to fit the new strategy. They do not need to preserve their current outer framing.

Preferred direction:

- extract reusable tool configuration panes from current standalone shells
- host those panes inside the new dataset-operations shell
- normalize section order, input selection, validation presentation, and footer behavior

This applies to:

- the classifier runner
- minimap2 mapping
- SPAdes assembly
- demultiplexing
- orient reads
- other FASTQ tools that currently depend on bespoke controls

### Drawer Replacement

Current demultiplexing, primer-trimming, and related bottom-drawer workflows should be fully replaced by modal-based tool panes.

### Menu Routing

Create new menu entry points for FASTQ category dialogs and route them through the same registry/shell used by the FASTQ dataset view.

## Testing

### TDD Requirement

This refactor must be developed with TDD. No production-code behavior change should land without a failing test first.

### UI And Registry Tests

Add failing tests first for:

- FASTQ category ordering
- category visibility
- category enablement and disabled reasons
- default tool selection per category
- Tools menu entry creation and enablement
- category launch routing from FASTQ dataset view and Tools menu
- standardized right-pane section order
- standardized input and output sections

### Command Construction Tests

Add failing tests first for:

- single-input FASTQ tool launches
- multi-input FASTQ tool launches
- `Per Input` output strategy mapping
- `Grouped Result` output strategy mapping
- classification tools preserving fixed batch output behavior
- required additional input assets such as references and databases

### Virtual FASTQ Tests

Virtual FASTQ handling must be an explicit regression target, not a side effect.

Add failing tests first for:

- concrete FASTQ input launch
- virtual FASTQ input launch
- mixed concrete and virtual multi-input launch where allowed
- correct CLI argument construction after materialization
- correct output import behavior after materialization

### Artifact-Backed Integration Tests

Every FASTQ operation exposed through the new dialog system must have artifact-backed integration coverage before the refactor is considered complete.

This should verify:

- the operation routes through `lungfish-cli`
- the expected output artifacts are created
- outputs are imported into the correct project structure
- multi-input result structure matches the selected output strategy
- virtual FASTQ materialization behaves correctly for tools that operate on FASTQ payloads

The integration suite must cover every runnable FASTQ tool surfaced by the dialog, including:

- `Refresh QC Summary`
- all trimming and filtering tools
- all decontamination tools
- all read-processing tools
- all search and subsetting tools
- demultiplexing
- mapping
- assembly
- classification

### Existing Test Suites To Extend

This work should build on and extend existing FASTQ operation test coverage, including current app and integration tests around FASTQ derivatives, batch operations, and virtual FASTQ round-trips.

## Risks

- `FASTQDatasetViewController` currently owns too much operation-specific UI logic, so the refactor may require more decomposition than the UI suggests.
- Some existing sheets likely mix outer-shell concerns with tool-state logic, making extraction non-trivial.
- The current pack-status API is not yet shaped for category gating by arbitrary pack ID.
- Multi-input and grouped-result support can become confusing if output semantics are not worded precisely.
- Virtual FASTQ handling could regress silently if command-construction tests cover only materialized datasets.

## Recommendation

Proceed with a category-driven FASTQ operations dialog system built on a reusable dataset-operations shell, backed by a FASTQ-specific registry and a CLI-first execution contract.

Use category-level pack gating, standardized input and output sections, and explicit virtual FASTQ materialization rules. Normalize existing classifier, mapping, assembly, and drawer-based flows into this common strategy, and require TDD plus artifact-backed integration coverage before considering the refactor complete.
