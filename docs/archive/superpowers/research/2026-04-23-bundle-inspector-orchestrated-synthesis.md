# Bundle Inspector Orchestrated Redesign Brief

Date: 2026-04-23

## Purpose

This brief synthesizes the three focus-group reports and the technical audit into a single redesign direction for the right-side Inspector, with mapping bundles as the first target and cross-inspector consistency as the long-term goal.

The core conclusion is stable across all four inputs: the current `Selection` surface is overloaded, the current `Document` tab is named too generically, the icon-only tab shell is too opaque, and filtered-alignment creation is both buried and insufficiently explicit about outcome, location, and relationship to the source alignment.

## Non-Negotiable Redesign Principles

1. Use task-language, not implementation-language, at the top level.
   The right-side shell should communicate user intent directly. Avoid icon-only tab meaning and avoid software-centric nouns like `Document` and `Selection` for mapping workflows.

2. Keep tab semantics stable across bundle types.
   Do not rename the same conceptual tab differently by mode. If a capability is unavailable for a bundle type, omit the tab rather than changing its meaning.

3. Separate object inspection, reversible view state, and durable output creation.
   These are three different mental models and three different risk levels. They must not continue to share one long scroll surface.

4. Treat derived alignments as first-class bundle assets.
   A filtered alignment is not a hidden side effect of a read-style panel. It is a new derived output that should be visible, selectable, and clearly related to its source.

5. Prefer biological or workflow outcomes over BAM jargon in user-facing copy.
   Terms like `track`, `MAPQ`, `primary`, and `artifacts` should either be replaced or demoted into helper text.

6. Make post-action state explicit.
   After creating a filtered alignment, the app must answer four questions immediately: what was created, whether the source changed, where the new result lives in the bundle, and how to compare it with the source.

7. Hide filesystem complexity until it is specifically useful.
   The primary model should be "new derived alignment in this bundle" rather than `alignments/filtered/` or mapping-viewer-copy internals.

## Recommended Right-Side Tab Model

### Mapping-first recommendation

For mapping bundles, the Inspector should move to four text-labeled tabs:

1. `Overview`
2. `Selected Item`
3. `View`
4. `Derived Alignments`

This is the clearest mapping-first vocabulary for biology-facing users. It preserves the technical audit's structural separation while using more approachable labels than `Bundle`, `Inspect`, `View`, and `Derive`.

### Cross-inspector consistency target

Across other inspectors, keep the same four semantic buckets even if labels are slightly tuned for audience fit:

- `Overview`: bundle/result facts, provenance, inputs, outputs, status
- `Selected Item`: currently selected annotation, read, variant, sample, or chromosome
- `View`: reversible display and shell preferences
- `Derived Alignments` for mapping, and eventually a more general `Derived Outputs` label where bundle types support durable generated artifacts beyond alignments

### Tab rules

- Use visible text labels in the segmented control. Icons can remain decorative, but not as the only affordance.
- Do not keep `Selection` as a catch-all tab under a new name.
- If a bundle type has no derivation workflows, hide the derivation tab entirely.
- If nothing is selected, `Selected Item` should show a short empty state, not unrelated controls.

## Recommended User-Facing Vocabulary

### Top-level tabs

- Replace `Document` with `Overview`
- Replace `Selection` with `Selected Item`
- Add `View`
- Add `Derived Alignments`

### Mapping overview sections

- Replace `Source Data` with `Run Inputs`
- Replace `Mapping Context` with `Run Settings`
- Replace `Source Artifacts` with `Output Files`
- Move `Panel Layout` out of the overview surface and into `View`

### Filtered-alignment workflow language

- Replace `Create Filtered Track` with `Create New Filtered Alignment`
- Replace `Source Track` with `Starting Alignment`
- Replace `Output Track Name` with `Name for New Alignment`
- Replace `Mapped Only` with `Keep mapped reads only`
- Replace `Primary Only` with `Keep one primary alignment per read`
- Replace `Minimum MAPQ` with `Minimum alignment confidence`
- Show `MAPQ` only as helper text if needed
- Replace `Duplicates` with `Duplicate handling`
- Replace `Exact Matches Only` with `Keep reads with zero mismatches to reference`
- Replace `Minimum % identity` with `Minimum identity to reference (%)`

### Required helper text

The derived-alignment panel should state this before launch:

`Creates a new alignment in this bundle. The original alignment stays unchanged.`

When technical terms remain visible, they should be secondary clarifiers, not primary labels.

## Filtered-Alignment Post-Create Behavior and Discoverability Rules

### Required behavior after successful creation

1. Reload the active mapping viewer or bundle view.
2. Reveal the new alignment immediately in the visible alignment list.
3. Keep the source alignment present and unchanged.
4. Auto-select the new filtered alignment.
5. Preserve obvious naming continuity with the source, for example `<source> - filtered`.
6. Show confirmation that names the relationship explicitly:
   `Created a new filtered alignment from <source>. The original alignment was not changed.`

### Discoverability rules

- The new alignment must appear as a separate sibling item, or a clearly nested derived child, next to the source alignment.
- The UI should visually distinguish derived outputs with a badge or secondary label such as `Filtered` or `Derived from <source>`.
- The confirmation should include a direct next action such as `Show New Alignment`, `Return to Source Alignment`, or equivalent inline affordance.
- Silent reload is not acceptable as the main success model.
- Internal storage details should remain secondary. The primary explanation is bundle-relative ownership.

## Concrete Implementation Guidance

### `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`

- Replace the current tab model in `InspectorTab`, `InspectorViewModel.availableTabs`, and `InspectorView.tabPicker` with text-labeled mapping tabs for `Overview`, `Selected Item`, `View`, and `Derived Alignments`.
- Stop routing all non-document content through `.selection`.
- Remove auto-switch behavior that sends users into a catch-all `Selection` tab on read or annotation click. Selection events should target `Selected Item`.
- Update the filtered-alignment completion path in `runCreateFilteredAlignmentWorkflow(_:)` so success is not just alert-plus-reload.
- Add explicit post-reload reveal and reselection hooks for the created alignment, using the completion payload from `BundleAlignmentFilterService` and mapping viewer reload coordination.

### `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`

- Split this file's responsibilities.
- Keep reversible read display controls in a view-scoped section that belongs under the future `View` tab.
- Move duplicate workflows, consensus extraction, variant calling, and filtered-alignment creation into a derivation-oriented section that belongs under `Derived Alignments`.
- Reword all filtered-alignment labels into plain-language copy and add in-panel helper text explaining that the original alignment remains unchanged.
- Treat validation and output-name suggestion logic in `ReadStyleSectionViewModel` as reusable workflow state, but stop presenting that state under a section named like a rendering panel.

### `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`

- Evolve this file toward the stable `Overview` contract rather than mode-specific `Document` semantics.
- Keep it responsible for bundle/result facts, not shell preferences.
- Remove mapping layout ownership from the overview path.

### `Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift`

- Keep this as the mapping-specific overview renderer.
- Rename section headers to `Run Inputs`, `Run Settings`, and `Output Files`.
- Remove `layoutSection` from this file and relocate layout controls into the future `View` tab.
- Add room for a concise derived-alignment summary in the overview path later, but do not overload this tab with workflow launch controls.

## What To Do Now Versus Later

### Do now

- Replace icon-only mapping Inspector tabs with visible text labels.
- Introduce the four-tab mapping structure: `Overview`, `Selected Item`, `View`, `Derived Alignments`.
- Move mapping layout controls out of `MappingDocumentSection`.
- Separate filtered-alignment creation from `ReadStyleSection` display controls.
- Rewrite filtered-alignment copy in plain language.
- Change filtered-alignment completion from generic success alert to reveal-plus-reselect behavior with explicit source-preservation messaging.

### Do later

- Harmonize non-mapping inspectors onto the same semantic tab model where capabilities exist.
- Generalize `Derived Alignments` into `Derived Outputs` for bundle types with non-alignment derivation workflows.
- Add richer derived-output summaries in `Overview`, including source relationships and compatibility/status notes.
- Revisit whether `Selected Item` should split further for expert modes, but only after the baseline separation is in place and validated.

## Bottom Line

The redesign should not be a cosmetic rename of `Document` and `Selection`. The required change is structural: `Overview` for bundle facts, `Selected Item` for current object context, `View` for reversible presentation controls, and `Derived Alignments` for durable workflow outputs. Mapping bundles should be the first implementation because they expose the current failure modes most clearly, but the semantics chosen there should become the template for the broader Inspector system.
