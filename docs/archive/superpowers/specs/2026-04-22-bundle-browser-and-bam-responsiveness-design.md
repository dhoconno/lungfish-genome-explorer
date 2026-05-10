# Bundle Browser and BAM Responsiveness Design

Date: 2026-04-22
Status: Proposed

## Summary

The current `.lungfishref` viewing experience still carries an older chromosome-drawer model that is weaker than the newer list/detail browsers used elsewhere in the app. It also becomes unresponsive when BAM-backed bundles are opened on very large references because the viewer waits too long to switch from per-read rendering to coverage-only rendering.

This design replaces the chromosome drawer with a manifest-backed bundle browser that becomes the default entry surface for all `.lungfishref` bundles, including single-sequence bundles. The bundle browser should open instantly from static cached row summaries, drill into the existing genome viewer when the user chooses a sequence or contig, and preserve browser state so users can move back and forth without rebuilding the list.

For BAM-backed detail views, the viewer should stay fluid by treating coverage as the default zoomed-out representation. Individual read fetching, packing, layout, and hit-testing should not happen until the user zooms in far enough for read-level detail to be visually meaningful.

## Goals

- Make a list/detail bundle browser the default top-level opening surface for every `.lungfishref` bundle.
- Remove the chromosome drawer from bundle viewing rather than maintaining two competing navigation models.
- Reuse the existing detailed genome viewer for sequence/contig drill-in instead of building a second detail renderer.
- Keep the bundle browser fast by sourcing row data from static cached summaries instead of loading full sequences or scanning BAMs on open.
- Preserve responsiveness for BAM-backed bundles by showing coverage when zoomed out and deferring read-level work until the viewport is sufficiently zoomed in.
- Keep mapping result shells coherent with the new bundle browser without nesting one list/detail surface inside another.
- Maintain backward compatibility for existing bundles that do not yet carry the new browser summary data.
- Add deterministic tests for bundle routing, cache loading, legacy fallback, and read-render gating.

## Non-Goals

- Do not redesign the existing sequence detail renderer once the user drills into a bundle sequence.
- Do not replace the current BAM rendering stack with a new coverage or read renderer.
- Do not add cross-project reference copying in this pass.
- Do not add a second generic database for mutable project analytics; this design is only about static bundle-browser summaries and responsive rendering.
- Do not compute expensive BAM-derived list metrics synchronously during bundle open.

## Current State

The repo already contains most of the pieces needed for the new flow, but they are not composed correctly yet:

- `ViewerViewController.displayBundle(at:)` in `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift` still treats bundle open as a direct jump into the genome viewer and conditionally installs `ChromosomeNavigatorView` when `chromosomes.count > 1`.
- `ChromosomeNavigatorView` is the older bundle-navigation surface and duplicates information that is better expressed in the richer list/detail browser.
- `FASTACollectionViewController` in `Sources/LungfishApp/Views/Viewer/FASTACollectionViewController.swift` already provides a much stronger list/detail interaction model, but it is sequence-object-driven and currently expects loaded `Sequence` values rather than lightweight bundle summaries.
- `BundleManifest.GenomeInfo.chromosomes` already carries enough identity metadata to seed a static browser row model: name, length, aliases, primary flag, mitochondrial flag, and FASTA description.
- `SequenceViewerView` already has a coverage-only tier driven by sparse depth points and already skips `fetchReadsAsync` in that tier, but the current threshold in `ReadTrackRenderer.coverageThresholdBpPerPx` is too permissive for very large references.
- `MappingResultViewController` already owns its own left-hand mapped-contig list. If all bundle opens were blindly rerouted into a browser, the mapping shell would risk showing a list inside another list.

## Product Decisions

### 1. Every Top-Level `.lungfishref` Bundle Opens into a Bundle Browser First

Top-level bundle openings should no longer jump directly into a chromosome or contig detail view. They should open into a bundle browser first, regardless of whether the bundle contains one sequence or many.

Approved behavior:

- multi-sequence bundles open to the bundle browser with the first natural-sort sequence selected and its summary shown in the detail pane
- single-sequence bundles also open to the bundle browser, with the sole row selected by default
- double-clicking a row or pressing the existing “Open in Browser” action drills into the current genome viewer for that sequence
- drill-in should preserve the browser’s search, sort, selection, and scroll state so the user can return without rebuilding context

This keeps the entry model consistent for every bundle and removes the hidden rule that “single sequence means direct genome view, multiple sequences means drawer.”

### 2. The Chromosome Drawer Is Deprecated for Bundle Viewing

`ChromosomeNavigatorView` should no longer be part of the `.lungfishref` viewing experience.

Approved first-pass behavior:

- top-level bundle viewing never installs the chromosome drawer
- bundle sequence navigation happens through the bundle browser list
- once drilled into the detail viewer, the viewer shows only the selected sequence/contig and does not resurrect the old drawer
- variant-only bundle behavior stays unchanged except that it should not attempt to construct the drawer surface either

This is an explicit deprecation, not a coexistence plan. The old drawer is redundant with the richer list/detail browser and should stop owning the product interaction.

### 3. Introduce a Lightweight Bundle Browser Model Instead of Reusing Loaded `Sequence` Objects

The bundle browser should not depend on eagerly loading complete `Sequence` records from the FASTA payload. It should render from a new summary model that represents what the browser needs for first paint.

Approved row model requirements:

- sequence or contig name
- optional display description
- length
- aliases
- `isPrimary`
- `isMitochondrial`
- annotation-track count or precomputed annotation summary when available
- variant-track count or precomputed variant summary when available
- alignment-track summaries when available
- enough information to route “Open in Browser” directly to the selected sequence

Recommended implementation shape:

- add a dedicated `BundleBrowserSequenceSummary` model
- either extract a shared table/detail foundation from `FASTACollectionViewController` or evolve it so it can render summary rows without requiring loaded `Sequence` values
- keep the existing genome viewer as the drill-in destination rather than teaching the bundle browser to render tracks itself

The browser can still visually resemble `FASTACollectionViewController`, but it must stop assuming sequence-content ownership.

### 4. Cache Static Browser Rows with a Manifest-First Contract and a Local Mirror for Legacy Bundles

The bundle browser must populate from static cached summaries rather than recomputing expensive metrics at open time.

Approved cache policy:

- the authoritative portable cache format is a new optional browser-summary section in `manifest.json`
- Lungfish-created or Lungfish-rewritten bundles should write this browser-summary section when the bundle is created or refreshed
- opening a bundle must not synchronously rewrite a foreign or shared bundle manifest just to backfill the cache
- the app may maintain a project-local SQLite mirror for legacy bundles that do not yet carry manifest browser summaries
- the browser loader order is:
  - manifest browser summary when present
  - local SQLite mirror keyed by bundle fingerprint when present
  - lightweight synthesis from `manifest.genome.chromosomes` as a compatibility fallback

This keeps bundle-owned metadata portable while still allowing instant reopen of legacy bundles without mutating external references on first inspection.

#### Browser Summary Payload

The new manifest section should be explicit and typed rather than buried inside the generic metadata groups.

Approved content for the first version:

- summary schema version
- per-sequence rows
- optional aggregate counts for annotations, variants, and alignments
- optional per-alignment sequence metrics when already known from managed workflows
  - mapped reads
  - mapped percent
  - mean depth
  - coverage breadth
  - median MAPQ
  - mean identity

Important boundary:

- these metrics are static summaries
- if a metric is not already cached, the bundle browser must leave it blank or show a lightweight unavailable state
- the browser must not scan BAMs on the main thread or during initial open just to fill these cells

This preserves instant load as the primary requirement.

### 5. Bundle Opening Needs Explicit Modes so Embedded Mapping Viewers Do Not Nest Another Browser

The viewer layer needs a distinction between:

- opening a bundle as a top-level document
- opening a specific sequence from a bundle inside an already structured shell such as mapping results

Approved routing model:

- add an explicit bundle opening mode:
  - `.browse`
  - `.sequence(name: String, restoreViewState: Bool)`
- top-level `.lungfishref` document opens use `.browse`
- bundle-browser drill-in uses `.sequence(...)`
- mapping result shells continue to own the master contig list and should open their embedded viewer directly into `.sequence(...)`
- the embedded mapping viewer must not show a second bundle browser above or beside the mapping list

This preserves the improved top-level bundle experience without regressing the dedicated mapping-analysis shell.

### 6. Bundle Browser Navigation Should Be a Reversible Drill-In, Not a Second Document Open

Drilling from the bundle browser into a sequence viewer should be treated as an in-document navigation state change.

Approved first-pass behavior:

- the browser remains the owning document mode for top-level bundles
- selecting “Open in Browser” swaps the content area to the existing genome viewer for the selected sequence
- a back affordance returns to the browser without reconstructing its rows, filters, or selection
- returning from detail should also preserve the last viewed sequence row

This avoids document churn and keeps the browser/detail pairing feeling like one coherent workflow.

### 7. BAM-Backed Detail Rendering Must Stay Coverage-Only Until Read Detail Is Salient

The existing coverage tier is the right interaction model for zoomed-out BAM viewing, but it needs to engage earlier.

Approved zoom-tier policy:

- coverage-only when scale is greater than `2.0 bp/px`
- packed-read rendering when scale is less than or equal to `2.0 bp/px` and greater than `0.6 bp/px`
- base-level rendering when scale is less than or equal to `0.6 bp/px`

Coverage-only behavior must mean more than “don’t draw reads.” In coverage tier, the viewer should:

- fetch sparse depth data only
- skip BAM read fetches entirely
- skip read packing and row layout entirely
- skip read hit-testing entirely
- skip any overlay computations that depend on individual reads
- keep hover/selection behavior limited to coverage/depth interactions

When the user zooms into packed or base tiers, read fetching and layout may resume. When the user zooms back out to coverage tier, any packed-read state should be discarded or made dormant so the viewport stops paying memory and layout costs for invisible detail.

### 8. Static Mapping Summaries Should Stay Outside the BAM Rendering Path

The user is correct that list-view values such as mapped-read counts are static for a given artifact set and should not be recomputed by interrogating the BAM every time the UI opens.

Approved boundary:

- top-level bundle browser rows use the browser summary cache described above
- managed mapping result shells continue to source their mapped-contig list from persisted mapping summary artifacts such as `mapping-result.json`, not from on-demand BAM scans
- BAM reading in the detail viewer is only for viewport detail, not for populating static list rows

This separation keeps the list instant and prevents the detail viewport from blocking document open.

### 9. Backward Compatibility Must Favor Fast Fallbacks Over Open-Time Mutation

Existing bundles on shared or external volumes may not contain the new browser-summary manifest section. They still need to open correctly.

Approved compatibility behavior:

- if the browser summary is absent, the browser synthesizes rows from `manifest.genome.chromosomes`
- fallback rows must still be enough to render the list immediately with at least name, description, and length
- richer cached metrics may appear when a matching local SQLite mirror exists
- absence of either cache is not a fatal error and must not block opening the bundle
- first-pass implementation does not silently rewrite external manifests during viewing

This is important for shared references, external volumes, and concurrent sessions.

## Architecture

### Bundle Browser Surface

Recommended responsibilities:

- `BundleBrowserState`
  - owns loaded row summaries, sort/filter state, selected row, and cached detail summary
- `BundleBrowserViewController`
  - renders the list/detail browser for bundle summaries
- `BundleBrowserLoader`
  - resolves manifest summary, SQLite mirror, or synthesized fallback rows
- `ViewerViewController`
  - remains responsible for actual sequence/annotation/alignment detail rendering after drill-in

This keeps the browser’s job limited to document navigation and summary presentation.

### Bundle Summary Storage

Recommended storage split:

- `manifest.json`
  - portable bundle-owned summary when the bundle was created or refreshed by Lungfish
- project-local SQLite cache
  - optional mirror keyed by bundle identity plus manifest fingerprint for legacy bundles and faster reopen

The two stores should share the same logical row schema so they can be loaded interchangeably.

### Mapping Shell Integration

`MappingResultViewController` should keep its existing role as the owner of the mapping list/detail shell.

Approved integration:

- mapping list selection picks a contig
- the embedded `ViewerViewController` opens that contig directly in sequence detail mode
- the embedded viewer uses the same BAM responsiveness policy as top-level bundle drill-in
- the mapping shell does not embed a second browser surface

## Data Flow

### Top-Level Bundle Open

1. User opens a `.lungfishref` bundle.
2. The document loader resolves the bundle manifest.
3. The bundle browser loader fetches cached rows from:
   - manifest browser summary
   - or local SQLite mirror
   - or synthesized fallback from `GenomeInfo.chromosomes`
4. The bundle browser renders immediately from those rows.
5. The user selects a sequence and drills into detail.
6. The viewer opens the selected sequence directly without installing `ChromosomeNavigatorView`.

### BAM-Backed Detail Zoom

1. The detail viewer computes zoom tier from `bp/px`.
2. If the tier is coverage:
   - request sparse depth only
   - do not fetch or pack reads
3. If the tier is packed or base:
   - fetch reads for the visible region
   - pack rows only for those tiers
4. If the user zooms back out to coverage:
   - stop using per-read state for rendering and interaction

## Error Handling

- Invalid or unreadable manifest summary data should fall back to synthesized chromosome rows rather than failing the document open.
- Missing SQLite cache entries are a normal condition, not an error.
- Bundles with no genome section but valid variant-only content should open without the browser drawer and should present the best available summary rows for their content.
- BAM-backed detail panes that cannot resolve depth or read data should surface the existing viewer placeholder/error messaging without collapsing the surrounding browser or mapping shell.

## Testing

Required XCTest coverage:

- top-level `.lungfishref` open routes to bundle-browser mode for single-sequence bundles
- top-level `.lungfishref` open routes to bundle-browser mode for multi-sequence bundles
- mapping embedded viewer routes directly to sequence detail mode and does not present the bundle browser
- browser loader prefers manifest summary over SQLite mirror and SQLite mirror over synthesized fallback
- synthesized fallback rows use `GenomeInfo.chromosomes` without loading full sequences
- bundle viewing does not install `ChromosomeNavigatorView`
- coverage tier threshold changes from the current permissive value to the new `2.0 bp/px` policy
- coverage tier suppresses read fetch, row packing, and read hit-testing
- packed/base tiers still fetch reads and render detail correctly

Required XCUI coverage:

- opening a `.lungfishref` document lands in the bundle browser
- drilling into a sequence and navigating back preserves list selection
- zoomed-out BAM viewing remains responsive and does not expose read-level hover or selection affordances until zoomed in

## Rollout Notes

- The old chromosome drawer should be treated as deprecated immediately for `.lungfishref` bundle viewing.
- The browser-summary manifest section should be backward compatible and optional.
- SQLite mirroring is a compatibility and performance aid for legacy bundles, not a second source of truth for newly written bundle manifests.
- Implementation should prefer introducing explicit bundle-browser seams rather than hiding the new behavior inside `displayBundle(at:)` conditionals.
