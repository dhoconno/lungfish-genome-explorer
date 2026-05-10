# Bundle Inspector Technical Audit

Date: 2026-04-23

## Scope

This audit reviews the current Inspector implementation for mapping bundles with emphasis on tab shell behavior, section ownership, BAM filtering entry points, and the information architecture needed to grow from mapping-first work into a consistent cross-inspector system.

Primary files reviewed:

- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- `Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift`
- `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- `docs/superpowers/specs/2026-04-21-mapping-bundle-viewer-design.md`
- `docs/superpowers/specs/2026-04-22-bam-filtering-design.md`

## Current Technical Audit

### 1. The shell is mode-aware, but not information-architecture-aware

The current shell correctly adapts `availableTabs` by `ViewportContentMode`, but tab meaning changes too much by mode. `Document` can mean bundle metadata, mapping-analysis provenance, FASTQ dashboard metadata, or metagenomics summary. `Selection` can mean current object details, editor controls, appearance controls, sample toggles, read display controls, consensus export, duplicate workflows, variant calling, and BAM filtering.

This is technically simple, but it produces a weak contract: tabs are named by implementation history rather than by user intent. As more special cases arrive, the shell will keep accumulating mode-specific exceptions inside one `InspectorView`.

### 2. `Selection` is overloaded beyond a stable user mental model

In the current `InspectorView`, the `Selection` tab is a long vertical stack of:

- selected-item detail
- variant detail
- sequence appearance
- annotation style
- sample display controls
- read display controls
- alignment-derived workflows

That is too many responsibility classes for one tab. The main design flaw is not density alone. It is that object-scoped inspection, temporary view state, and artifact-producing workflows are intermixed in one scroll surface.

### 3. `ReadStyleSection` currently spans three different domains

`ReadStyleSection` is doing all of the following:

- transient read display controls
- alignment statistics and metadata
- workflow launching for duplicate handling, consensus extraction, variant calling, and BAM filtering

That makes the section difficult to name accurately and hard to scale. It also blurs an important boundary:

- changing how reads are rendered should feel reversible and local
- creating filtered BAMs or deduplicated outputs should feel durable and bundle-scoped

Those two classes of action should not share the same visual section or state ownership model.

### 4. Mapping document state is cleaner than the shell around it

The mapping-specific `Document` path is the strongest part of the current architecture. `MappingDocumentStateBuilder` is already a good seam: it builds a presentation model from `MappingResult`, optional provenance, and project context, while `MappingDocumentSection` renders that model without owning assembly logic.

The main issue is not the mapping document content itself. The issue is that layout controls are still placed inside the same document surface as provenance and source links. Layout is view state, not bundle metadata.

### 5. BAM filtering launch is technically centralized, but interaction feedback is weak

The current BAM filtering flow has good service-level structure:

- validation is localized in `ReadStyleSectionViewModel`
- launch is centralized in `InspectorViewController`
- execution is delegated to `BundleAlignmentFilterService`
- completion reloads either the mapping viewer bundle or the generic bundle view

The interaction problem is after launch. The user mostly gets:

- a running spinner
- a generic success alert
- an implicit reload

That does not clearly answer the user-facing questions that matter most:

- Was a new track created or did the old one change?
- Which bundle owns it?
- Is it in the mapping analysis, the source bundle, or somewhere else?
- Which track is selected now?
- How do I compare the derived track to the source track?

## Right-side Tabs

Use words, not icons, for the top-level right-side tabs. The starting target should be:

- `Bundle`
- `Inspect`
- `View`
- `Derive`
- `Assistant` when enabled

These names are stable across bundle types because they describe intent, not implementation.

### `Bundle`

Purpose: bundle- or result-scoped facts and provenance.

Contains:

- title, subtype, summary
- source inputs and linkbacks
- provenance and run context
- artifacts and file-level outputs
- bundle-level status such as derived tracks, missing assets, or compatibility notes

Does not contain:

- transient display settings
- object editing controls
- workflow launchers

For mapping, this tab should absorb the current mapping document content, but move `Panel Layout` out.

### `Inspect`

Purpose: currently selected object details.

Contains:

- selected annotation details and edit affordances
- selected read details
- selected variant details
- selected sample details where applicable

This tab should be explicitly object-scoped. If nothing is selected, it should show a short empty state rather than a long list of unrelated controls.

### `View`

Purpose: reversible display and shell preferences.

Contains:

- sequence appearance
- annotation display/style
- sample visibility toggles
- read display settings
- mapping shell layout controls

This is where `Panel Layout` belongs for mapping, because it changes the presentation shell, not the underlying bundle.

### `Derive`

Purpose: artifact-producing workflows that generate new outputs or mutate bundle structure.

Contains:

- BAM filtering
- duplicate workflows
- consensus export
- variant calling
- future export or derivation workflows

The key rule is that `Derive` actions must explain output ownership and post-run destination in-place, before launch and after completion.

## Mapping-first Target

For mapping bundles, the first implementation should expose:

- `Bundle`
- `Inspect`
- `View`
- `Derive`

This separates the current overloaded `Selection` tab into three durable categories:

- object inspection
- reversible view state
- durable data creation

## Cross-bundle Harmonization Principles

1. Keep tab meaning stable across content modes.
   `Bundle` should always mean bundle/result facts. `Inspect` should always mean currently selected thing. `View` should always mean reversible display state. `Derive` should always mean new outputs or structural bundle changes.

2. Prefer capability-based omission over semantic renaming.
   If a bundle type does not support a tab, hide it. Do not rename `Bundle` to `Result Summary` in one mode and `Document` in another.

3. Keep state ownership outside the Inspector.
   Builders and coordinators should assemble bundle-specific presentation state; the Inspector should render and dispatch.

4. Separate scope explicitly.
   Object scope, bundle scope, and shell scope should not share one section just because they all happen to live on the right side.

5. Treat derived outputs as first-class bundle assets.
   A filtered BAM should appear in the same IA as other bundle artifacts and derived tracks, not as a temporary side effect of display controls.

6. Prefer conceptual location over filesystem location.
   Users need to know "new derived alignment track in this bundle" before they need to know `alignments/filtered/`.

## Implementation Seams Likely to Change

- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
  The current tab composition and mode switching logic will need to separate `Inspect`, `View`, and `Derive` content instead of putting them all under `Selection`.

- `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
  This is the main decomposition target. Read display controls should stay view-scoped; BAM filtering and other workflows should move to a derivation-oriented section.

- `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
  The document shell should evolve toward a stable `Bundle` tab contract rather than mode-specific document semantics.

- `Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift`
  Keep this as the mapping-specific bundle/provenance renderer, but remove layout controls and add clearer derived-track surfacing.

- `Sources/LungfishApp/Views/Inspector/MappingDocumentStateBuilder.swift`
  Good existing seam for bundle-scoped mapping state. Likely expansion point for derived-track summaries and stronger mapping-analysis ownership messaging.

- `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
  Likely source for track-selection and post-create reselection hooks once the app needs to reveal and focus newly created filtered tracks.

- `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
  Likely orchestration point for passing bundle/result context into a more structured multi-tab inspector model.

- `Sources/LungfishWorkflow/Alignment/BundleAlignmentFilterService.swift`
  Service flow is fine conceptually; likely only needs better completion payload usage by the UI rather than architectural redesign.

## Risks and Migration Notes

- The biggest migration risk is superficial tab renaming without responsibility separation. Renaming `Selection` to `Inspect` while leaving all current controls in place would preserve the core problem.
- The second risk is over-fitting to mapping. The mapping-first pass should establish reusable tab semantics, not a mapping-only special shell.
- Moving layout controls out of `Document` may feel like churn, but leaving them there will keep metadata and view state entangled.
- Workflow completion must not depend on silent reload as the primary feedback mechanism. Reload is an implementation detail, not the interaction model.
- Mapping analyses are structurally unusual because the visible alignment lives in a copied viewer bundle inside the result directory. The IA should hide that complexity unless the user explicitly asks for artifact locations.

## Strong Recommendation: How Filtered BAM Results Should Surface

Filtered BAM creation should end with explicit reselection of the new derived alignment track, not just a bundle reload plus success alert.

Recommended post-create behavior:

1. Reload the active bundle or mapping viewer bundle.
2. Reveal the new alignment track in the visible track list immediately.
3. Auto-select the new filtered track as the active read track.
4. Keep the source track visible and clearly labeled as the parent/source.
5. Show an inline completion message in `Derive` and/or `Bundle` stating:
   "Created a new derived alignment track in this bundle. The source track was not changed."
6. Offer direct next actions such as:
   `View New Track`, `Return to Source Track`, and `Reveal in Bundle`.

For mapping results specifically, the message should say that the new track was added to the mapping analysis's viewer bundle as a new alignment track. That is the right conceptual explanation. The filesystem path under `alignments/filtered/` can be secondary detail inside `Bundle`, not the primary completion message.

## Bottom Line

The current inspector has solid lower-level seams, especially for mapping document-state assembly and filtering execution, but the shell semantics are unstable. The path forward is to stop using `Selection` as a catch-all, establish a stable word-based tab model (`Bundle`, `Inspect`, `View`, `Derive`), and make filtered BAM outputs reselectable first-class bundle assets instead of outcomes that users must infer from a reload.
