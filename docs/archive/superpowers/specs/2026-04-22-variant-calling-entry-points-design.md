# Variant Calling Entry Points And Shared Picker Design

Date: 2026-04-22
Status: Approved for planning

## Summary

The BAM variant-calling implementation already exists in the app as an inspector-launched, CLI-backed workflow. This pass adjusts how people discover and launch that workflow without changing the underlying caller execution, VCF normalization, SQLite import, or bundle-attachment pipeline.

The approved interaction model is:

- keep `Call Variants…` in the alignment inspector as the fast contextual shortcut
- add `Tools > Call Variants…` as the menu-bar command
- route both entry points through the same variant-calling sheet and the same CLI-backed execution path
- scope the workflow to the currently loaded bundle
- show only analysis-ready alignment tracks in the sheet picker

This keeps the feature discoverable from the menu bar while preserving the contextual inspector affordance that makes sense for BAM-backed bundle analysis.

## Goals

- Add a discoverable menu-bar entry point for BAM variant calling.
- Preserve the existing inspector action as a contextual shortcut.
- Use one shared sheet for both launch paths.
- Limit sheet track selection to analysis-ready alignment tracks only.
- Preselect the active alignment track when it is eligible.
- Keep menu validation bundle-scoped instead of viewport-scoped.
- Preserve the existing caller pipeline after launch:
  - caller execution
  - VCF normalization
  - `VCF.gz` and `.tbi` staging
  - SQLite import
  - bundle variant-track attachment
- Add focused test coverage for menu validation, picker filtering, preselection, and shared launch routing.

## Non-Goals

- Do not redesign the caller-specific settings UI in the existing variant-calling sheet.
- Do not add new callers beyond the current viral-first set.
- Do not make the Tools-menu command operate on arbitrary BAM files outside the loaded bundle.
- Do not expose non-analysis-ready alignment tracks in the picker with disabled rows or explanatory text.
- Do not replace the inspector shortcut with a Tools-only launch model.
- Do not change the current CLI-backed provenance, import, or bundle-mutation semantics.

## Current State

### Existing Variant-Calling Workflow

The repository already contains the main BAM variant-calling implementation:

- `BAMVariantCallingDialog`, `BAMVariantCallingDialogState`, and `BAMVariantCallingDialogPresenter`
- inspector launch wiring in `InspectorViewController`
- bundle/caller preflight in `BAMVariantCallingPreflight`
- caller execution in `ViralVariantCallingPipeline`
- normalized VCF to SQLite import in `VariantSQLiteImportCoordinator`
- bundle track attachment in `BundleVariantTrackAttachmentService`
- CLI orchestration in `VariantsCommand`

That means this pass is not inventing a second workflow. It is a surface-area refinement over an existing workflow.

### Existing Entry Point Bias

Today the feature is effectively inspector-scoped:

- the alignment inspector exposes `Call Variants…`
- the read-style section disables that button only based on whether the bundle has alignment tracks
- there is no app-wide `Tools` menu entry for variant calling

This creates two problems:

- variant calling is harder to discover than other important tool-driven operations
- the enablement rule is looser than the real workflow requirement, which is analysis-ready alignment tracks rather than just any alignment track

### Existing Menu Patterns

The app’s `Tools` menu already contains top-level, discoverable command surfaces for major workflows. Variant calling belongs in that family more than it belongs in a hidden or viewport-conditional action model.

At the same time, the feature remains inherently contextual because it acts on a loaded reference bundle and one of its eligible alignment tracks. That means a contextual inspector shortcut still has value even after the menu item is added.

## Product Decisions

### 1. Use Dual Entry Points With One Shared Workflow

Approved behavior:

- keep the alignment inspector `Call Variants…` button
- add `Tools > Call Variants…`
- both entry points present the same `BAMVariantCallingDialog`
- both entry points reuse the same `BAMVariantCallingDialogState`, presenter, CLI runner, and success/failure handling

Rationale:

- the menu bar makes the command discoverable
- the inspector keeps the action close to the relevant BAM/alignment context
- sharing the sheet avoids divergence between two launch paths

### 2. Make The Tools Command Bundle-Scoped, Not Viewport-Scoped

The new menu command should not depend on whether a BAM is currently visible in the viewport.

Approved enablement rule:

- enable `Tools > Call Variants…` when the currently loaded bundle contains at least one analysis-ready alignment track
- disable it when there is no loaded bundle
- disable it when the loaded bundle has no analysis-ready alignment tracks

This avoids a brittle “current viewport must be BAM” requirement while still keeping the command honest about when it can succeed.

### 3. Restrict The Sheet Picker To Analysis-Ready Tracks Only

The alignment picker in the shared sheet will show only analysis-ready alignment tracks.

Approved behavior:

- do not list ineligible tracks in a disabled state
- do not expose raw/non-ready tracks with explanatory rows
- if no analysis-ready tracks exist, the sheet should not present from either entry point

Rationale:

- the workflow only makes sense for tracks that already satisfy the app’s analysis-ready requirements
- hiding non-ready tracks keeps the picker compact and reduces ambiguity
- the menu and inspector entry points should both fail before sheet presentation rather than present a picker that contains unusable options

### 4. Preselect The Most Relevant Eligible Track

Both entry points open the same sheet, but they differ in how much context they have.

Approved preselection order:

1. if the current context exposes an active alignment track and that track is analysis-ready, preselect it
2. otherwise preselect the first analysis-ready alignment track in bundle order

This rule applies to both launch paths. The inspector path will often have an obvious active track; the Tools-menu path may not.

### 5. Tighten Inspector Enablement To Match Real Eligibility

The existing inspector shortcut currently disables only when the bundle has no alignment tracks. That is too weak.

Approved behavior:

- disable the inspector `Call Variants…` button unless the loaded bundle has at least one analysis-ready alignment track
- keep the label and placement unchanged
- do not add a second inspector-specific picker or panel

This aligns the inspector shortcut with the same eligibility rule used by the menu command.

### 6. Preserve The Existing Execution Boundary And Post-Run Import Path

This pass does not change the backend workflow after the user clicks `Run`.

Required invariant:

- caller output still goes through the existing CLI-backed variant-calling command path
- the produced VCF still gets normalized
- the normalized VCF still gets compressed and tabix-indexed
- the normalized VCF still gets imported into SQLite through `VariantSQLiteImportCoordinator`
- the resulting database, `VCF.gz`, and `.tbi` still get attached to the bundle as a normal variant track

The menu/invocation refactor must not bypass the SQLite import path or create a second “VCF-only” attach flow.

### 7. Fail Closed If Context Changes Between Validation And Presentation

Menu validation and inspector enablement happen before presentation, but bundle state can still change.

Approved failure behavior:

- if the menu command or inspector shortcut is invoked and the bundle is gone, present the existing “no bundle loaded” alert path
- if the bundle no longer has eligible analysis-ready tracks, present the existing “no alignment tracks” style alert with updated eligibility wording
- if an operation lock appears after validation but before launch, reuse the existing `OperationCenter` lock-holder alert path

This keeps the workflow robust without introducing a separate state-reconciliation layer.

## Implementation Boundary

This design is intentionally narrow.

### In Scope

- new `Tools` menu action and validation
- shared presenter routing from menu and inspector
- analysis-ready track filtering in dialog state or a closely related shared layer
- better enablement rules for the inspector shortcut
- preselection behavior for the shared picker
- tests for the new entry-point and picker behavior

### Out Of Scope

- new caller configuration controls
- reworking the sidebar/catalog inside the variant sheet
- changing the CLI JSON event protocol
- changing import semantics or SQLite schema behavior
- changing bundle manifest attachment semantics

## Testing Strategy

### Unit / Controller Tests

- menu validation tests proving `Tools > Call Variants…` is enabled only when the loaded bundle has at least one analysis-ready alignment track
- dialog-state tests proving the picker options include only analysis-ready tracks
- preselection tests proving the active eligible track wins and the first eligible track is the fallback
- inspector routing tests proving both launch paths call the same presenter or workflow entry method

### Integration Tests

- a focused app-level test covering the Tools-menu launch path through the shared dialog state
- regression coverage proving the existing CLI-backed variant-calling flow still emits SQLite-backed variant tracks after launch

### Safety Checks

- verify the inspector shortcut remains available for eligible bundles after the menu command is added
- verify the Tools-menu command does not become enabled for bundles that have BAM files but no analysis-ready tracks
- verify successful runs still produce:
  - a bundle-attached `.vcf.gz`
  - a `.vcf.gz.tbi`
  - a SQLite database
  - a standard `VariantTrackInfo`

## Open Follow-Up Explicitly Deferred

The following ideas are intentionally deferred from this pass:

- exposing variant calling from context menus
- exposing variant calling from a toolbar item
- showing ineligible tracks in the picker with disabled rows and reason strings
- broadening the Tools-menu command to operate on arbitrary external BAM files
