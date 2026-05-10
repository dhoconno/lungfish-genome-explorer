# Harmonized Reference Mapping View Design

## Context

`.lungfishref` bundles and read-mapping viewer bundles now represent the same practical object: reference sequences plus zero or more track families, including mapped reads, variants, and annotations. Mapping analyses already use a richer list/detail mapping viewport with read display controls, BAM filtering, variant calling, primer trimming, consensus export, and mapping provenance. Direct `.lungfishref` sidebar selections still open the older bundle browser first, which creates a second interaction model and lets Inspector behavior drift.

The goal is to make every `.lungfishref` open through one harmonized reference-bundle viewport. Mapping analysis results should keep their run provenance, but the underlying reference sequence and track interaction model should be the same as direct bundle viewing.

## Goals

- Route reference-only, alignment-bearing, variant-bearing, and annotation-bearing `.lungfishref` bundles through one list/detail viewport.
- Preserve the mapping analysis viewport behavior while making it a specialization of the same reference-bundle view.
- Keep Inspector controls synchronized for direct bundles and mapping-result viewer bundles.
- Show unavailable major capabilities as visible but disabled with clear reasons.
- Make future track families easier to add without creating new top-level viewer modes for each one.
- Remove the older default `.lungfishref` browse-first views and tests so stale routing cannot reappear accidentally.
- Retain the useful old-viewer capability to promote the selected detail sequence into a full-viewport focused browser/detail view.

## Non-Goals

- Replacing the entire Inspector tab model in this change.
- Implementing new track families.
- Changing bundle file format semantics beyond any small metadata helpers needed for display.
- Removing mapping result provenance, output artifact, or source input sections.

## User Experience

Opening any `.lungfishref` shows a reference track-container viewport:

- Left/list pane: reference sequences, chromosomes, or contigs.
- Detail pane: the selected sequence rendered with available tracks.
- Focus control: a command in the detail pane can promote the selected sequence to a full-viewport focused detail view.
- Back control: focused detail mode includes a visible Back button that returns to the normal list/detail navigation view.
- Inspector Document tab: bundle summary, track inventory, and, when applicable, mapping-run provenance/artifacts.
- Inspector View tab: visible track-family display sections.
- Inspector Analysis tab: track-family actions.

Reference-only bundles still use this layout. Mapped-read controls and variant actions remain visible only where they are meaningful, but major actions that explain bundle potential are visible-disabled. For example, "Call Variants" is disabled with a reason when no analysis-ready BAM track exists.

The existing old browse-first bundle browser should be removed as a default `.lungfishref` experience. Reusable browser/list code may survive only if it becomes the sequence list pane for the harmonized viewport. Tests that assert browse-first routing or legacy bundle-browser behavior should be deleted or rewritten to assert the harmonized route, so the codebase does not retain two competing `.lungfishref` interaction models.

The full-viewport focus mode is not the old default browser route. It is an explicit action from the harmonized viewport that temporarily gives the selected sequence all available viewport space for detailed inspection. It must include a visible Back button to return to the normal list/detail navigation view, and should preserve the selected sequence, region, track display settings, Inspector wiring, and mutation/reload behavior.

## Architecture

Introduce a shared reference-bundle viewport model rather than treating mapping results as the only path into the list/detail view.

Core concepts:

- `ReferenceBundleViewportInput`: either a direct `.lungfishref` bundle or a mapping analysis result with a viewer bundle.
- `ReferenceBundleTrackCapabilities`: describes available track families and action readiness.
- `ReferenceSequenceListRow`: display row for a chromosome/contig/sequence, populated from manifest/browser summary and optional alignment/variant statistics.
- `ReferenceBundleDocumentContext`: bundle URL, manifest, source bundle links, optional mapping result/provenance, and artifact rows.
- `ReferenceViewportPresentationMode`: list/detail or focused detail, with shared loaded bundle state.

The existing `MappingResultViewController` can either be renamed/extracted into a generalized controller or wrapped by a new controller. The important boundary is that both direct `.lungfishref` and mapping analyses feed the same viewport input model.

## Routing

`MainSplitViewController` should route every sidebar `.referenceBundle` item to the harmonized viewport. Mapping analysis directories continue to load `MappingResult` and provenance, then route to the same viewport with mapping context attached.

Direct bundle routing should:

- Load the bundle manifest.
- Build sequence list rows from manifest chromosomes or browser summary.
- Build document context from bundle metadata.
- Wire Inspector alignment, variant, annotation, and view-state sections from the loaded `ReferenceBundle`.

Mapping analysis routing should:

- Load `MappingResult` and `MappingProvenance`.
- Use `result.viewerBundleURL` as the rendered bundle.
- Add mapping-run source data, settings, and artifacts to the Document tab.
- Continue to use the mapping result directory as the service target for filtered BAM outputs where current behavior requires it.

Legacy routing cleanup should:

- Remove public or private entry points whose only purpose is opening `.lungfishref` bundles in browse mode.
- Replace tests that look for `displayBundle(at:mode:.browse)` routing with tests for the harmonized viewport.
- Remove dead UI tests, accessibility identifiers, and view-controller test hooks that exist only for the old browse-first bundle browser.
- Keep lower-level manifest, bundle loading, annotation search, and sequence table utilities when they are still used by the harmonized viewport.
- Keep or replace the old full-viewport detail capability as an explicit focus action from the harmonized viewport.
- Ensure focused detail mode has a stable Back button accessibility identifier for UI tests.

## Inspector Model

Keep the top-level Inspector tabs by purpose for now:

- Document
- Selection
- View
- Analysis
- AI, where applicable

Inside those tabs, group controls by track family:

- Reference Sequences
- Mapped Reads
- Variants
- Annotations
- Future track families

Track-family sections read from `ReferenceBundleTrackCapabilities`. Major actions should be visible-disabled when unavailable; specialized controls can remain hidden when the related track family does not exist and showing them would add noise.

Examples:

- Mapped Reads section: read visibility, alignment track selection, MAPQ/display options, consensus controls, BAM filtering, primer trimming, duplicate workflows.
- Variants section: variant visibility, type filters, variant table/search shortcuts, call variants from BAM when an eligible alignment exists.
- Annotations section: annotation visibility, type filters, mapped-reads-to-annotations when mapped reads exist.

## Data Flow

1. Sidebar selection creates `ReferenceBundleViewportInput`.
2. Viewport loads `ReferenceBundle` and sequence rows.
3. Viewport embeds or owns the existing `ViewerViewController` detail renderer in direct sequence mode.
4. Viewport publishes loaded bundle context to Inspector through one shared update path.
5. Inspector derives track capabilities and action readiness from the bundle and optional mapping context.
6. Actions that mutate the bundle reload the same viewport input instead of choosing separate mapping-vs-bundle reload paths where possible.
7. Focus mode reuses the same loaded detail renderer state when possible; returning to list/detail restores the selected row and region.

## Compatibility

Existing `.lungfishref` bundles remain valid. Bundles without alignments or variants simply show disabled or absent track-family controls according to capability rules. Variant-only bundles that synthesize chromosomes from variant databases should still be supported, but they need explicit tests because sequence rendering and sequence extraction may be limited without actual FASTA content.

Mapping result directories keep their current result sidecars and provenance. The visual viewport changes only by sharing the reference-bundle container model with direct `.lungfishref` bundles.

## Testing

Add tests before implementation:

- Direct reference-only `.lungfishref` routes to the harmonized viewport, not browse mode.
- Direct `.lungfishref` with BAM and VCF exposes the same Inspector read/variant action wiring as a mapping viewer bundle.
- Reference-only bundle shows major unavailable actions as disabled with explanatory text.
- Mapping analysis results still show mapping provenance/artifacts and use the mapping result directory as the filtered alignment target.
- Bundle mutation actions reload the harmonized viewport for direct bundles and mapping analysis viewer bundles.
- Existing mapping viewport tests continue to pass or are renamed to the generalized reference viewport.
- Legacy browse-first `.lungfishref` routing tests are removed or rewritten so no test preserves the old default behavior.
- Focus mode opens the selected detail sequence into a full-viewport view and a visible Back button returns to list/detail without losing selection, region, or Inspector wiring.

## Edge Cases

- Bundles with multiple chromosomes should select from the list pane rather than the old chromosome drawer.
- Bundles with no genome but variant databases should continue using synthesized chromosomes.
- Bundles with missing BAM indexes should show mapped-read actions disabled with the specific missing-index reason.
- Direct bundles imported from old workflows may lack per-track mapped-read counts; list rows should tolerate unavailable metrics.
- Mapping viewer bundles may be symlink-heavy; reload logic must preserve current link/copy behavior.

## Open Questions

No blocking product questions remain. The chosen behavior is that all `.lungfishref` bundles use the harmonized list/detail viewport, and major unavailable capabilities remain visible but disabled.
