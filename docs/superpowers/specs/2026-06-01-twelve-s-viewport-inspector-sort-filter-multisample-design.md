# 12S Viewport: Inspector Migration, Column Sort/Filter, Context-Menu Copy, and Multi-Sample Comparison

Date: 2026-06-01
Status: Approved design (brainstorming complete)
Module owner: `LungfishTwelveSUI` (leaf) + `LungfishApp` (Inspector glue), reusing `LungfishKit` + `LungfishCore` kernel infrastructure.

## Problem

The 12S amplicon results viewport (`TwelveSAmpliconResultViewController`) is a hand-rolled vertical `NSSplitView`: a bespoke `NSTableView` on the left and an `NSStackView` "detail pane" on the right showing the selected row's scientific name, exact reads, reference-target count, per-sample evidence, and alternate matches.

Four gaps:

1. The detail pane holds limited information that belongs in the Inspector, not in a split pane competing with the table for width.
2. The list cannot be sorted or filtered per-column the way every other list view in the app can.
3. There is no right/command-click context menu for copy actions (Copy Name, Copy Sequence, Copy Sequences, Copy Rows).
4. The viewport is not prepared for multi-sample comparison, even though the underlying bundle is already multi-sample at the data level.

## Goals

- Migrate the detail-pane content into a new Inspector tab.
- Give the 12S list per-column sort and filter, identical in behavior to the rest of the app.
- Add a selection-aware context menu with Copy Name / Copy Sequence / Copy Sequences / Copy Rows.
- Prepare the viewport for multi-sample comparison reusing the NAO-MGS / NVD idiom.
- Maximize reuse of kernel infrastructure; preserve the kernel/leaf module separation.

## Non-Goals (YAGNI)

- No change to the 12S bundle format (`TwelveSAmpliconResultBundle`) or any IO type.
- No change to the CLI.
- No column-per-sample matrix view (NAO-MGS / NVD do not do this; it would be net-new code).
- No new export formats.

## Key Finding: the data is already multi-sample

`TwelveSAmpliconResultBundleData` already carries `samples: [TwelveSAmpliconSampleResult]`, and every row type
(`TwelveSScientificNameCountRow`, `TwelveSTargetCountRow`, `TwelveSUnresolvedSequence`) stores per-sample maps
(`sampleCounts: [String: Int]`, `sampleExactReadTotals: [String: Int]`) plus `count(forSample:)`,
`totalExactReads`, and `maxSamplePercent` computed properties. The screenshot shows "1 samples" only because
that run had one sample. Therefore **all multi-sample work in this design is UI-layer only.** No format or CLI change.

## Decisions (locked during brainstorming)

1. **Table approach:** full migration of the 12S tables onto the kernel's generic `BatchTableView<Row>` (the same base class NAO-MGS, NVD, Kraken2, EsViritu, TaxTriage subclass). This delivers column sort, per-column filter menus, multi-row selection callbacks, a context-menu hook, and multi-sample metadata columns from shared code.
2. **Comparison layout:** the sample-picker + aggregated-rows idiom (NAO-MGS / NVD), not a column-per-sample matrix.
3. **Per-sample breakdown surfacing:** reuse `MetadataColumnController` dynamic per-sample columns (already embedded in `BatchTableView`, `isMultiSampleMode = true`); per-sample detail also appears in the new Inspector tab.
4. **Process:** spec → phased TDD (keep the green bar) → GUI smoke via Computer Use (binding rule).

## Architecture and Module Boundaries

No new modules. No `LungfishIO`/CLI changes. The kernel rule is preserved: leaves subclass kernel types (kernel → leaf
is the existing direction for every classifier); the Inspector detail tab lives in `LungfishApp` and is fed by the
leaf VC through a new `on...` callback, never the reverse. `LungfishTwelveSUI` never references a `LungfishApp` type.

| Concern | Module | Approach |
|---|---|---|
| Generic sortable/filterable table + context-menu hook + multi-sample columns | `LungfishKit` (kernel) | Reuse `BatchTableView<Row>` as-is (no kernel edits expected). |
| 12S target/unresolved tables | `LungfishTwelveSUI` (leaf) | New `TwelveSTargetTableView` + `TwelveSUnresolvedTableView` subclasses; replace the hand-rolled `NSTableView`. |
| Context-menu copy actions | `LungfishTwelveSUI` (leaf) | `TwelveSCopyMenuProvider` builds an `NSMenu` per selection; assigned via `BatchTableView.tableContextMenu`; writes `NSPasteboard`. |
| Per-row detail (was the detail pane) | `LungfishApp` (Inspector) | New `InspectorTab.twelveSDetail`, `TwelveSDetailSectionViewModel`, `TwelveSDetailSection` view. |
| Multi-sample picker state/UI | `LungfishCore` + `LungfishKit` | Reuse `ClassifierSamplePickerState`, `ClassifierSampleEntry` (new `TwelveSSampleEntry`), `ClassifierSamplePickerView`. |

### Data flow (NAO-MGS-identical shape)

```
TwelveSAmpliconResultBundleData (already per-sample)
  → ViewerViewController+TwelveS glue builds [TwelveSSampleEntry] + ClassifierSamplePickerState
  → TwelveSAmpliconResultViewController observes picker.selectedSamples (withObservationTracking)
  → aggregates rows across the selected sample subset
  → configure(rows:) on the visible BatchTableView subclass
  → row selection fires onRowSelected / onMultipleRowsSelected / onSelectionCleared
      → single  → glue feeds TwelveSDetailSectionViewModel → Inspector .twelveSDetail tab
      → multi/0 → Inspector detail shows a "select a single match" placeholder
```

## Components

### A. `BatchTableView` subclasses (leaf)

Two thin subclasses replace the hand-rolled table. Each overrides only documented hooks.

`TwelveSTargetTableView: BatchTableView<TwelveSScientificNameCountRow>`
- `columnSpecs`: Scientific Name, Common Names, Group, Tax ID, Exact Reads, Refs, Max %, Alternates — each with a `sortDescriptorPrototype` (numeric columns default descending).
- `cellContent(for:row:)`: per-column text/alignment, lifted from the current `viewFor` switch.
- `columnValue(for:row:)` + `columnTypeHints`: Exact Reads / Refs / Max % / Alternates are numeric (filter menus offer ≥/≤/between); the rest are text.
- `compareRows(_:_:by:ascending:)`: numeric compare for numeric columns, `localizedStandardCompare` for text.
- `rowMatchesFilter(_:filterText:)`: the existing free-text predicate (name / common names / potential matches / taxon groups / taxids).
- `sampleId(for:)`: for metadata-column lookup. Aggregated rows are fed through `MetadataColumnController` per sample in multi-sample mode exactly as NAO-MGS does.
- `rowIdentity(for:)`: `resultIdentity + scientificName + taxids.joined` — stable across sort/filter/reload.

`TwelveSUnresolvedTableView: BatchTableView<TwelveSUnresolvedSequence>`
- `columnSpecs`: Sequence, Reads, Samples, Chimera, Bases (existing five).
- Same hook overrides; `Bases` / `sequence` is the copy-sequence source.
- `rowIdentity(for:)`: `resultIdentity + sequenceID`.

The existing `TwelveSResultDisplayState` filters (minimum reads, taxon-group pills, exclude-human, require-alternates,
chimera) are applied **in the VC before** `configure(rows:)`. They coexist with the kernel's free-text and per-column
filters, which narrow within the already-display-state-filtered set. No double application.

### B. Context menu (leaf)

`TwelveSCopyMenuProvider` builds an `NSMenu` from the current selection, assigned to `tableContextMenu`.
Items gated by selection count and mode:

- **Copy Name** — always. Single → that scientific name (or sequence ID in unresolved mode); multi → newline-joined names.
- **Copy Sequence** — unresolved mode, single row with a non-empty `sequence` → raw bases. Omitted (not disabled) when empty.
- **Copy Sequences** — unresolved mode, multi-row → FASTA (`>sequenceID\nsequence`), reusing the FASTA-formatting idiom from `FASTASequenceActionMenuBuilder`.
- **Copy Rows** — multi-row → TSV (header + selected rows) in the visible-column order, matching export column order.

Selection resolves through `BatchTableView.selectedRowsByIdentity()`. A right-click on an unselected row first selects
it via `selectDisplayedRowForContextMenuIfNeeded`, matching NVD. Pasteboard writes go through a `PasteboardWriting`
abstraction so the copy payloads are unit-testable without touching the real `NSPasteboard`.

### C. Inspector detail tab (`LungfishApp`)

- New `InspectorTab.twelveSDetail` case; added to `availableTabs` for `.metagenomics` so the metagenomics Inspector
  becomes `[.resultSummary, .twelveSDetail, .provenance]`.
- New `TwelveSDetailSectionViewModel` (`@Observable @MainActor`) holding the selected row's payload:
  - Target variant: scientific name, total exact reads, reference-target count, `[TwelveSDetailSampleEvidenceRow]`, alternate-match texts.
  - Unresolved variant: sequence ID, read count, per-sample counts, chimera status, the sequence string.
  - Empty / multi state → placeholder.
- New `TwelveSDetailSection: View` rendering the payload with disclosure groups (the visual idiom the detail pane used),
  now in the Inspector.
- The leaf VC exposes `onSelectedRowDetailChanged: ((TwelveSDetailPayload?) -> Void)?`. `ViewerViewController+TwelveS`
  wires it to a new `inspector.updateTwelveSDetail(...)` public API and auto-selects `.twelveSDetail` on the first
  single-selection only (never steals the tab while the user is on another tab thereafter).
- The old detail `NSStackView` and its `updateTargetDetail` / `updateUnresolvedDetail` methods are deleted. The
  `NSSplitView` collapses to a single full-width table host.

`TwelveSDetailPayload` is a small `Sendable` value type defined in the leaf (`LungfishTwelveSUI`) so both the leaf VC
and the App glue can pass it without the leaf importing App. The Inspector view-model maps the payload to display fields.

### D. Multi-sample (leaf + glue)

- New `TwelveSSampleEntry: ClassifierSampleEntry` (id, displayName, metric = exact reads). Built by the glue from `bundleData.samples`.
- The VC gains `samplePickerState: ClassifierSamplePickerState?` and an "All Samples / N of M Samples" header button
  (mirroring NAO-MGS `updateSampleFilterButtonTitle` + `NSPopover` hosting `ClassifierSamplePickerView`).
- It observes `selectedSamples` via `withObservationTracking`; on change it re-aggregates rows over the selected subset
  and calls `configure(rows:)`. Re-registration and main-actor hops follow the binding runtime pattern
  (`DispatchQueue.main.async { MainActor.assumeIsolated { … } }`), never `Task { @MainActor }` from a background context.
- **Aggregation:** for the selected sample set, each target row's `totalExactReads` / `maxSamplePercent` recompute from
  the per-sample maps restricted to the selected samples (`count(forSample:)` already supports this). A single-sample
  bundle aggregated over its one sample equals today's totals — zero behavior change for existing bundles.
- `MetadataColumnController` (embedded in `BatchTableView`, `isMultiSampleMode = true`) is inherited and remains
  available for genuine imported sample metadata (its actual purpose), keyed by `sampleId(for:)`.

**Per-sample breakdown surfacing — design refinement (implementation finding).** During implementation it became clear
that 12S target rows are *aggregates across samples* (one row per species, holding a `sampleCounts` map), unlike
NAO-MGS/NVD where there is one row *per sample*. `MetadataColumnController` keys metadata off a single
`sampleId(for: row)`, which is well-defined for per-sample rows but not for an aggregated species row. Forcing a
"dominant sample" mapping would attach misleading metadata. Therefore the per-sample breakdown surfaces through the two
mechanisms that map correctly onto aggregated rows: (1) the **Inspector Detail tab's sample-evidence list** (per-sample
reads + percentages for the selected species), and (2) the **sample-picker filter** (restrict the visible/aggregated row
set to a chosen sample subset). The shared `MetadataColumnController` is retained, dormant unless real imported metadata
is present, so there is no regression and no net-new misuse of the shared component. This honors the "reuse + surface
per-sample data" intent without inventing a column-per-sample matrix (an explicit non-goal).

## Edge Cases

- **Empty / multi selection** → Inspector detail placeholder ("Select a single match to view details").
- **Single-sample bundles** → picker renders but selection is a no-op; aggregation over one sample == legacy totals.
- **Empty sequence** in unresolved rows → "Copy Sequence" omitted.
- **Mode switch (Targets ↔ Unresolved)** → swaps the visible `BatchTableView` subclass; each retains its own
  sort/filter/selection; the context menu re-binds to the active table.
- **Sort/filter vs. display-state** → display-state filters run first in the VC; kernel filters narrow within. No double count.
- **Concurrency** → all `@MainActor`; sample-selection observation uses the NAO-MGS re-registration idiom.

## Testing

Phased TDD; the suite must stay GREEN (XCTest failures ⊆ the 9 known-environmental; swift-testing = 0).

- **Leaf unit tests** (`Tests/LungfishTwelveSUITests/`):
  - `columnSpecs` / `cellContent` correctness for both subclasses.
  - Sort ascending/descending per column (numeric and text).
  - Free-text and per-column filter predicates.
  - Multi-sample aggregation: reads sum correctly over a sample subset; single-sample == legacy totals.
  - Copy payloads: Copy Name (single/multi), Copy Sequence, Copy Sequences (FASTA), Copy Rows (TSV) verified via a
    `PasteboardWriting` test double.
- **Inspector tests** (`LungfishApp` tests):
  - `TwelveSDetailSectionViewModel` maps a target row and an unresolved row to the correct fields.
  - Placeholder for empty / multi selection.
  - `availableTabs` includes `.twelveSDetail` in `.metagenomics`.
- **Regression:** existing 12S `FunctionalFixtureTests`-style coverage, `TwelveSAmpliconResultViewControllerTests`, and
  `TwelveSAmpliconResultExportTests` stay green.
- **GUI smoke (Computer Use, binding):** launch `.build/debug/Lungfish`, open the 12S fixture bundle, verify:
  1. detail content appears in the Inspector `.twelveSDetail` tab (no split detail pane);
  2. clicking a column header sorts; the header menu filters;
  3. right-click a row shows Copy Name / Copy Sequence / Copy Sequences / Copy Rows and they write the clipboard;
  4. the sample-picker button opens the shared `ClassifierSamplePickerView`.

## Files Expected to Change

New (leaf, `Sources/LungfishTwelveSUI/`):
- `TwelveSTargetTableView.swift`
- `TwelveSUnresolvedTableView.swift`
- `TwelveSCopyMenuProvider.swift`
- `TwelveSDetailPayload.swift`

New (App, `Sources/LungfishApp/Views/Inspector/Sections/`):
- `TwelveSDetailSection.swift` (view + `TwelveSDetailSectionViewModel`)

Modified:
- `Sources/LungfishTwelveSUI/TwelveSAmpliconResultViewController.swift` — replace table + detail pane; add sample picker; expose `onSelectedRowDetailChanged`.
- `Sources/LungfishApp/Views/Inspector/InspectorSupportingTypes.swift` — add `.twelveSDetail`.
- `Sources/LungfishApp/Views/Inspector/InspectorViewModel.swift` — `availableTabs` + section view-model wiring.
- `Sources/LungfishApp/Views/Inspector/InspectorView.swift` — render `.twelveSDetail`.
- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift` (+ `+PublicAPI`) — `updateTwelveSDetail(...)`.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+TwelveS.swift` — build sample entries; wire detail callback + tab switch.

New tests:
- `Tests/LungfishTwelveSUITests/TwelveSTableViewTests.swift`
- `Tests/LungfishTwelveSUITests/TwelveSCopyMenuTests.swift`
- `Tests/LungfishTwelveSUITests/TwelveSMultiSampleAggregationTests.swift`
- Inspector detail tests under the App test target.

## Rollout

Phased, each phase green before the next:
1. Leaf table subclasses + migrate VC to them (sort/filter live).
2. Context-menu copy actions.
3. Inspector detail tab + delete old detail pane.
4. Multi-sample picker + aggregation + metadata columns.
5. GUI smoke + regression sweep.
