# Bundle Inspector Redesign Design

Date: 2026-04-23
Status: Approved by user direction for implementation

## Summary

The current Inspector is overloaded for mapping and BAM-backed bundle work. The right sidecar uses icon-only tabs, mixes bundle facts with selected-item inspection, and places durable BAM-creation workflows inside a read-style panel that otherwise looks like reversible view state. The redesign should treat the right sidecar as a Bundle Inspector with stable text-labeled tabs, starting with mapping bundles and aligning the semantics used by other inspectors over time.

This design incorporates:

- three independent focus-group reports from biologists with strong domain knowledge but limited deep-sequencing UI fluency
- a Swift/AppKit/UI/UX technical audit
- the existing mapping-viewer and BAM-filtering designs already present in the repo

## Goals

- Replace icon-only mapping Inspector tabs with text labels.
- Reframe the current `Document` tab as bundle-scoped information rather than a generic document bucket.
- Split the overloaded `Selection` surface into separate tabs for selected-item inspection, reversible view state, and durable derived-output workflows.
- Make filtered BAM outputs clearly discoverable as separate derived alignments that do not replace the source BAM.
- Let users access a derived filtered alignment separately from the source alignment inside the current viewer session.
- Start with mapping bundles, but choose semantics that can be reused across other inspectors.

## Non-Goals

- Do not redesign the whole main window chrome.
- Do not rename every existing internal type to match the new user-facing language.
- Do not rework BAM filtering service architecture; the problem is primarily shell structure and completion behavior.
- Do not solve every cross-inspector variation in one pass. Mapping is the first implementation target.

## Research Synthesis

The external and internal review tracks converged on the same issues:

- icon-only tabs are opaque for biology-first users
- `Document` and `Selection` are implementation-history labels, not task labels
- the current `Selection` tab mixes three scopes:
  - bundle/result facts
  - selected-item details
  - reversible view controls
  - durable data-creating workflows
- filtered BAM creation is understandable only if the UI explicitly states:
  - a new alignment was created
  - the source alignment was not modified
  - where the new alignment can now be found
  - how to view the new alignment separately from the original

## Product Decisions

### 1. Mapping Uses Four Text Tabs

For mapping and BAM-backed reference bundles, the right sidecar should use:

- `Bundle`
- `Selected Item`
- `View`
- `Derived`

When the assistant is available in genomics mode, it remains a separate text-labeled `Assistant` tab.

Rationale:

- `Bundle` aligns with the user’s requested “Bundle Inspector” mental model
- `Selected Item` is explicit about scope
- `View` clearly implies reversible display state
- `Derived` clearly implies durable outputs and workflows

### 2. Tab Meaning Must Stay Stable

The semantic contract is:

- `Bundle`
  - bundle/result facts, provenance, inputs, outputs, derived asset inventory
- `Selected Item`
  - selected annotation, read, variant, chromosome, or sample details
- `View`
  - reversible appearance, layout, visibility, and read-display state
- `Derived`
  - workflow launchers that create new outputs or materially alter bundle structure

Bundle types that do not support a given tab should hide it rather than reusing the name for a different concept.

### 3. The Mapping Bundle Tab Absorbs Mapping Document Content

The current mapping `Document` surface becomes the `Bundle` tab, with these adjustments:

- keep the header and summary
- rename sections:
  - `Source Data` -> `Run Inputs`
  - `Mapping Context` -> `Run Settings`
  - `Source Artifacts` -> `Output Files`
- remove `Panel Layout` from the bundle tab
- add an `Alignment Tracks` section showing:
  - all alignment tracks in the current bundle
  - which one is currently isolated for viewing
  - which one was most recently derived
  - whether a track is original vs. derived

### 4. The Selected Item Tab Becomes Truly Selection-Scoped

`Selected Item` should contain only object-scoped detail:

- annotation detail/editing
- selected variant detail
- selected read detail

If nothing is selected, the tab should show a short explanatory empty state rather than unrelated controls.

### 5. The View Tab Owns Reversible Read and Layout Controls

The `View` tab should contain:

- appearance controls
- annotation style controls
- sample display controls
- read display controls
- visible alignment selector
- mapping layout controls

The visible alignment selector is new. It must allow:

- `All Alignments`
- one specific alignment track at a time

This is the minimum needed to let users work with a filtered alignment separately from the source BAM without forcing them to infer hidden bundle structure.

Behavior:

- default remains the current aggregated behavior (`All Alignments`)
- choosing a specific alignment limits read/depth/consensus rendering to that alignment
- the selection persists across reloads when the chosen alignment still exists

### 6. The Derived Tab Owns Durable BAM and Mapping Workflows

The `Derived` tab should contain:

- BAM filtering
- duplicate workflows
- consensus export
- BAM-backed variant calling

The tab must explain scope before launch:

`Creates a new alignment in this bundle. The original alignment stays unchanged.`

Filtering controls should use plainer language:

- `Starting Alignment`
- `Name for New Alignment`
- `Keep mapped reads only`
- `Keep one primary alignment per read`
- `Minimum alignment confidence`
- `Duplicate handling`
- `Keep reads with zero mismatches to reference`
- `Minimum identity to reference (%)`

Technical terms such as `MAPQ` can survive in helper text, not as the primary label.

### 7. Filtered Alignment Completion Must Reveal the New Result

Successful BAM filtering must no longer stop at “reload plus generic alert”.

Required completion behavior:

1. Keep the source alignment unchanged.
2. Reload the active bundle or embedded mapping viewer bundle.
3. Mark the new derived alignment in the `Bundle` tab track inventory.
4. Switch the visible-alignment selector to the newly created track.
5. Preserve a one-click path back to `All Alignments` or the source alignment.
6. Show explicit language:
   `Created a new filtered alignment from <source>. The source alignment was not changed.`

This gives users both discoverability and a real way to work with the derived result separately.

## Implementation Shape

### Inspector Shell

Primary file:

- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`

Changes:

- add `View` and `Derived` tabs
- switch segmented tab content from SF Symbols to text labels
- default to `Bundle` as the initial bundle-facing tab
- keep selection-driven tab switching targeted only at `Selected Item`

### Read/Workflow Decomposition

Primary file:

- `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`

Changes:

- keep `ReadStyleSectionViewModel` as the shared alignment-state source
- split the view layer into smaller sections:
  - selected-read detail
  - read display / visible-alignment controls
  - derived-workflow controls
- move summary/provenance visibility away from the catch-all read-style surface and into the bundle tab where appropriate

### Bundle Alignment Inventory

Primary files:

- `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- `Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift`

Changes:

- add a shared alignment-inventory presentation model
- render alignment rows with source/derived/current/recently-created cues
- allow direct “show this alignment” switching through the inventory

### Viewer Track Isolation

Primary files:

- `Sources/LungfishCore/Models/Notifications.swift`
- `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`

Changes:

- add a read-display notification key for the visible alignment track ID
- let the viewer isolate one alignment provider while preserving `All Alignments`
- apply the same selected-track filter to reads, depth, and consensus generation

### BAM Filtering Completion

Primary files:

- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`

Changes:

- carry the created track identity through the completion path
- update inspector state before/after reload so the new track is highlighted and isolated
- replace generic completion language with explicit derived-output language

## Testing

Required coverage:

- Inspector tab availability and text labels for mapping mode
- source-level guard that the segmented control uses text rather than icon-only tabs
- mapping document section no longer owns layout controls
- view-model preservation of visible-alignment selection across reloads
- viewer application of visible-alignment read settings
- filtered-alignment workflow tests updated for explicit post-create reveal state

Primary test files:

- `Tests/LungfishAppTests/InspectorMappingModeTests.swift`
- `Tests/LungfishAppTests/InspectorAssemblyModeTests.swift`
- `Tests/LungfishAppTests/WindowAppearanceTests.swift`
- `Tests/LungfishAppTests/AlignmentFilterInspectorStateTests.swift`
- `Tests/LungfishAppTests/ReadStyleSectionViewModelTests.swift`
- `Tests/LungfishAppTests/MappingDocumentSectionTests.swift`
- `Tests/LungfishAppTests/ViewerViewportNotificationTests.swift`

## Rollout

Do now:

- ship the mapping-first shell split
- make filtered-alignment results separately accessible
- improve wording and completion behavior

Do later:

- harmonize additional bundle types onto the same tab semantics where capabilities exist
- decide whether `Derived` should broaden into `Derived Outputs` for non-alignment workflows in other bundle types

## Bottom Line

The fix is structural, not cosmetic. Mapping needs a Bundle Inspector with stable text tabs, a true selected-item surface, a reversible view surface, and a dedicated durable-workflow surface. Filtered BAM creation must end with a separately accessible derived alignment, not a reload that forces the user to guess what happened.
