# 12S Viewport: Per-Sample Comparison Matrix + Detail-Tab Reference Sequences

Date: 2026-06-01
Status: Approved design (follow-on to the 12S Inspector/sort-filter/copy/multi-sample work)
Module owner: `LungfishTwelveSUI` (leaf) + `LungfishApp` (Inspector + metadata-import glue), reusing `LungfishCore`/`LungfishKit` + `LungfishIO`.

## Problem

Two gaps surfaced during GUI testing of the 12S viewport:

1. **No sample metadata as columns.** NVD/NAO-MGS let the user import a CSV/TSV of sample metadata and attach it as sortable/filterable columns. 12S cannot. The user wants metadata from *all* samples attached to the list.
2. **Matched (target/species) reference sequences are not viewable.** The Detail tab shows per-sample read evidence and alternate matches, but not the actual reference sequence(s) that define each matched species, so an analyst cannot select/copy them to check in other programs.

## Decisions (locked during brainstorming)

1. **Comparison shape: samples as columns, species as rows.** The 12S list stays one row per species. For each sample, a per-sample column block is appended: the sample's **read count** for that species, plus that sample's **imported metadata** values. Species typically outnumber samples, so columns-per-sample scales better than rows-per-sample. This makes the species list a true cross-sample comparison matrix. Every per-sample column is sortable and filterable like any other column.
2. **Detail-tab sequences: collapsed by default, expand to view + copy.** The Detail tab gains a `Reference Sequences (N)` disclosure (collapsed by default, since a species like *Homo sapiens* may have 100+ targets). Expanding shows each matching reference target (target ID + bases, monospaced, text-selectable) with **Copy Sequence** per row and **Copy All as FASTA** for the species. The reference FASTA is read lazily on selection.

## Non-Goals (YAGNI)

- No new bundle format or CLI change. (Reference sequences already exist in the bundle's reference FASTA; metadata import is a UI/IO concern.)
- No separate "samples as rows" comparison view (explicitly not chosen).
- No change to the existing aggregated **Exact Reads** column (it remains the cross-sample total; per-sample reads are additive columns).

## Key Findings (from code exploration)

- **Metadata import is a shared facility.** `InspectorViewController+MetadataImport.swift` presents a panel via
  `FeatureFilePanelFactory.inspectorTextMetadataImportPanel()`, parses CSV/TSV into a `SampleMetadataStore`
  (`Sources/LungfishCore/Models/SampleMetadataStore.swift`: `scanForSampleColumn(csvData:knownSampleIds:)` →
  `SampleMetadataStore(scanResult:sampleColumnIndex:knownSampleIds:)`), and applies it to the active result's VC.
  NVD exposes a `sampleMetadataStore` property and wires it through `MainSplitViewController+ClassifierDisplay.swift`
  with an `applyStore:` closure. `SampleMetadataStore` exposes `records: [String: [String: String]]`
  (sampleID → columnName → value), `columnNames`, and `matchedSampleIds`.
- **`MetadataColumnController` does not fit a matrix.** It keys metadata off a single `sampleId(for: row)` (one
  metadata column per field, value from one sample). 12S needs *one column per (sample, field)* on an aggregated
  species row, so the per-sample columns are built directly in the 12S `BatchTableView` subclass rather than via
  `MetadataColumnController`. The controller stays available for nothing here (it is not used for the matrix).
- **Target sequences live in the reference FASTA.** `TwelveSAmpliconTarget` has **no** `sequence` field. The bundle's
  `artifacts.referenceURL` (a FASTA) holds per-target sequences keyed by header. `FASTAReader` (`readAllSync()`) reads
  them. `TwelveSScientificNameCountRow.targetIDs` lists the target IDs for a species, so `targetID → sequence` is built
  by reading the reference FASTA and matching headers.

## Architecture and Module Boundaries

No new modules. Kernel/leaf boundary preserved: the leaf owns the matrix-column construction and the
reference-sequence loading; the App owns the metadata-import panel glue and feeds the store + sequences to the leaf via
public API / callbacks. The leaf never imports `LungfishApp`.

### A. Per-sample comparison matrix (leaf `LungfishTwelveSUI`)

`TwelveSTargetTableView` gains dynamic per-sample columns built from two inputs the VC supplies:
- the ordered list of currently-selected sample IDs (display order = picker order / sample table order), and
- an optional `SampleMetadataStore` (imported metadata).

Column model (appended after the fixed columns, rebuilt when samples or store change):
- For each selected sample `S`, one **reads** column `sample_<S>_reads` titled `"<displayName> reads"` whose value is
  `row.count(forSample: S)`.
- For each imported metadata field `F` and each selected sample `S`, one column `sample_<S>_meta_<F>` titled
  `"<displayName> · <F>"` whose value is `store.records[S]?[F] ?? ""`.

`columnValue(for:row:)`, `compareRows(...)`, and `columnTypeHints` are extended to recognize these dynamic column IDs
(reads columns numeric; metadata columns numeric iff the value parses as a number, else text). This routes the dynamic
columns through the kernel's existing per-column sort/filter machinery for free.

To keep column blow-up bounded (10 samples × many fields), the matrix columns are **opt-in per sample-metadata field
and per reads** via a header "Sample Columns" menu (show/hide), defaulting to: reads columns shown for ≤ 8 selected
samples, metadata columns hidden until toggled. A `log`/empty-state note is shown when columns are suppressed for large
cohorts (no silent truncation).

The VC drives this with:
- `configureSamples(_:state:)` already exists; the matrix rebuilds on sample-selection change.
- new `applyMetadataStore(_ store: SampleMetadataStore?)` on the VC → forwards to the target table.
- new public `var onMetadataImportRequested: (() -> Void)?` (fired by an action-bar / header "Import Metadata…" control)
  so the App can present the shared import panel and hand back a store.

### B. Detail-tab reference sequences (leaf payload + App view)

- `TwelveSDetailPayload.TargetDetail` gains `referenceSequences: [TwelveSReferenceSequence]` where
  `TwelveSReferenceSequence { targetID: String; sequence: String }` (Sendable). Empty when sequences aren't loaded.
- A new leaf type `TwelveSReferenceSequenceProvider` reads the bundle's reference FASTA once (lazily, cached by bundle
  URL) and exposes `sequences(forTargetIDs:) -> [TwelveSReferenceSequence]`. The VC owns one provider per loaded bundle
  and, when building a target payload, populates `referenceSequences` from the selected row's `targetIDs`. Reading the
  FASTA is done off the main actor (it is file IO) and the payload is emitted once ready; selection shows the rest of
  the detail immediately and the sequences fill in when loaded.
- `TwelveSDetailSection` (App) renders a `Reference Sequences (N)` `DisclosureGroup`, **collapsed by default**. Expanded:
  each sequence as `targetID` + monospaced, `.textSelection(.enabled)` bases, with a per-row **Copy Sequence** button and
  a **Copy All as FASTA** button for the species (FASTA = `>targetID\nsequence` joined). Copy uses the same
  `PasteboardWriting` seam.

### C. Metadata import glue (App)

- `MainSplitViewController+ContentDisplay.swift` (12S display path) wires `controller.onMetadataImportRequested` to the
  existing inspector metadata-import flow, scanning against the bundle's sample IDs, and calls
  `controller.applyMetadataStore(store)` with the resulting `SampleMetadataStore`. Reuse
  `FeatureFilePanelFactory.inspectorTextMetadataImportPanel()` and `SampleMetadataStore.scanForSampleColumn` /
  the column-selection flow exactly as NVD does.

## Data Flow

```
Import Metadata… (12S header/action bar)
  → onMetadataImportRequested → App presents shared panel → SampleMetadataStore (keyed by sampleID)
  → controller.applyMetadataStore(store) → TwelveSTargetTableView rebuilds per-sample columns
Sample picker selection change → rebuild per-sample column set (which samples' columns are shown)
Row selection (single target) → VC builds TwelveSDetailPayload, asynchronously populates referenceSequences
  from TwelveSReferenceSequenceProvider → Inspector Detail tab shows the collapsed Reference Sequences disclosure
```

## Edge Cases

- **No metadata imported** → only per-sample **reads** columns (and only when shown); no metadata columns. Existing
  single-sample bundles: one reads column at most (and the matrix adds little, which is fine).
- **Large cohorts** → reads columns auto-suppressed above a threshold (default 8 selected samples) with a visible note;
  user can still toggle them on via the Sample Columns menu. No silent truncation.
- **Metadata sample IDs that don't match the bundle** → unmatched rows are dropped by `SampleMetadataStore` (existing
  behavior); a count is surfaced the same way NVD surfaces it.
- **Species with many targets (e.g. 162)** → Detail sequences are collapsed by default; loading is lazy and cached.
- **Reference FASTA missing/unreadable** → `referenceSequences` stays empty; the disclosure shows "No reference
  sequences available" rather than erroring.
- **Concurrency** → FASTA read is off-main; the payload's sequence fill-in hops back via the project's
  `DispatchQueue.main.async { MainActor.assumeIsolated { … } }` pattern, never `Task { @MainActor }` from background.

## Testing (phased TDD; keep the green bar)

- **Leaf unit tests:**
  - Per-sample column construction: given selected samples + a store, the expected reads/metadata column IDs, titles,
    `columnValue`, numeric hints, and `compareRows` ordering.
  - Matrix updates when the selected-sample set changes and when a store is applied/cleared.
  - `TwelveSReferenceSequenceProvider`: maps targetIDs → sequences from a fixture FASTA; missing targets → omitted;
    missing FASTA → empty.
  - `TwelveSDetailPayload` carries `referenceSequences`; Copy-All-as-FASTA formatting.
- **App tests:** `TwelveSDetailSectionViewModel` exposes reference sequences; disclosure default-collapsed; import glue
  applies a store to the VC (verified via a VC seam).
- **Regression:** the existing 12S leaf + Inspector tests and the full suite stay green (XCTest failures ⊆ the known
  environmental set; swift-testing = 0).
- **GUI smoke (binding):** import a sample-metadata CSV, confirm per-sample columns appear and sort/filter; select a
  species, expand Reference Sequences, select + Copy a sequence and Copy All as FASTA.

## Files Expected to Change

New (leaf):
- `Sources/LungfishTwelveSUI/TwelveSReferenceSequenceProvider.swift`
- `Sources/LungfishTwelveSUI/TwelveSSampleMatrixColumns.swift` (pure column-spec/value/compare helpers for the matrix)

Modified (leaf):
- `TwelveSTargetTableView.swift` — dynamic per-sample columns + value/compare/type-hint routing.
- `TwelveSAmpliconResultViewController.swift` — `applyMetadataStore(_:)`, `onMetadataImportRequested`, provider
  ownership, payload sequence population, "Sample Columns" + "Import Metadata…" affordances.
- `TwelveSDetailPayload.swift` — `referenceSequences` + `TwelveSReferenceSequence`.
- `TwelveSCopyMenuProvider.swift` / detail copy — Copy All as FASTA for reference sequences (reuse FASTA formatting).

Modified (App):
- `Sources/LungfishApp/Views/Inspector/Sections/TwelveSDetailSection.swift` — Reference Sequences disclosure + copy.
- `MainSplitViewController+ContentDisplay.swift` — wire `onMetadataImportRequested` + `applyMetadataStore`.

New tests:
- `Tests/LungfishTwelveSUITests/TwelveSSampleMatrixColumnsTests.swift`
- `Tests/LungfishTwelveSUITests/TwelveSReferenceSequenceProviderTests.swift`
- additions to `TwelveSDetailPayloadTests.swift`, `TwelveSCopyMenuTests.swift`, `InspectorTwelveSModeTests.swift`

## Rollout

1. Reference sequences in Detail tab (payload + provider + disclosure + copy). Self-contained, immediately useful.
2. Per-sample matrix columns (reads), with the Sample Columns toggle + large-cohort guard.
3. Metadata import glue → metadata columns join the matrix.
4. GUI smoke + full regression sweep.
