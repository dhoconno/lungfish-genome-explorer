# Metadata Column Joins for Classifier Viewports

**Date:** 2026-04-03
**Status:** Approved

## Problem

When sample metadata is attached to classifier results via CSV/TSV import, the metadata columns appear in the taxonomy table but all values show as em-dash (`—`). The `MetadataColumnController` infrastructure works correctly — the issue is that the table delegates never pass the row's sample ID to the cell rendering method, so the lookup always fails.

## Root Cause

All five classifier table delegates call `metadataColumns.cellForColumn(column)` (the one-argument overload), which resolves to `cellForColumn(column, sampleId: currentSampleId)`. The `currentSampleId` is either nil or not set at the right time. The two-argument overload `cellForColumn(_:sampleId:)` exists but is never called directly by any table delegate.

## Approach

Fix each table delegate to pass the correct sample ID for each row. No new abstractions — just wire the existing `cellForColumn(_:sampleId:)` API to the sample ID that each row's data model already carries (or needs to carry).

## Per-Classifier Changes

### Kraken2 (TaxonomyTableView.swift)

Single-sample classifier. All rows share the same sample ID.

- The `viewFor` delegate already calls `cellForColumn(column)` which uses `currentSampleId`
- Fix: ensure `currentSampleId` is reliably set when `sampleMetadataStore` is assigned
- The wiring in `TaxonomyViewController.sampleMetadataStore.didSet` calls `update(store:sampleId:)` with `sampleEntries.first?.id` — this should work if `sampleEntries` is populated before `sampleMetadataStore` is set
- Verify ordering: `sampleEntries` must be populated before `sampleMetadataStore` is assigned

### EsViritu (ViralDetectionTableView.swift)

Single-sample classifier. Same pattern as Kraken2.

- The `viewFor` delegate calls `cellForColumn(column)` using `currentSampleId`
- Fix: same ordering verification as Kraken2 — `sampleEntries` before `sampleMetadataStore`

### TaxTriage (TaxTriageResultViewController.swift)

Multi-sample classifier, but rows are aggregated by organism in "All Samples" mode.

**No data model change needed.** When a single sample is selected, all rows belong to that sample — `currentSampleId` works. In "All Samples" mode, rows are aggregated across samples with no single sample ID — metadata columns correctly show em-dash.

**Fix:** Ensure `currentSampleId` is set on the `MetadataColumnController` when the sample filter changes. The existing `updateMetadataColumnState()` method calls `metadataColumns.update(store:sampleId:)` — verify it passes the correct sample ID from the picker state (the selected sample, or nil for "All Samples").

### NVD (NvdResultViewController.swift)

Multi-sample classifier with hierarchical outline view.

**No data model change needed** — `NvdOutlineItem` already carries `sampleId`:
- `.contig(sampleId: String, qseqid: String)`
- `.childHit(sampleId: String, qseqid: String, hitRank: Int)`
- `.taxonGroup(name: String)` — no sample ID (aggregated across samples)

**Delegate change:**
- Extract sample ID from the `NvdOutlineItem`:
  - `.contig(sampleId, _)` → use `sampleId`
  - `.childHit(sampleId, _, _)` → use `sampleId`
  - `.taxonGroup(_)` → use `nil` (shows em-dash, which is correct for aggregated rows)
- Call `metadataColumnController.cellForColumn(tableColumn, sampleId: extractedSampleId)`

### NAO-MGS (NaoMgsResultViewController.swift)

Multi-sample classifier with flat table.

**No data model change needed** — `NaoMgsTaxonSummaryRow` already has `.sample: String`.

**Delegate change:**
- Get `displayedRows[row].sample` for the current row index
- Call `metadataColumns.cellForColumn(column, sampleId: row.sample)`

## Export Integration

The existing `MetadataColumnController.exportValues(for:)` method already supports per-sample export. Each classifier's export path needs to:

1. Include `metadataColumns.exportHeaders` in the header row
2. For each data row, call `metadataColumns.exportValues(for: rowSampleId)` and append the values

This is the same pattern as the cell rendering fix — pass the row's sample ID instead of relying on `currentSampleId`.

## Testing Strategy

### Unit Tests (SampleMetadataStore)

- Parse CSV with multiple samples, verify `records` dictionary has correct per-sample values
- Case-insensitive sample ID matching (e.g., "Sample_A" matches "sample_a")
- Missing samples return nil (no crash, results in em-dash at render time)
- Column ordering preserved from header

### Unit Tests (MetadataColumnController)

- `cellForColumn(_:sampleId:)` returns correct value for known sample+column
- `cellForColumn(_:sampleId:)` returns em-dash for unknown sample
- `cellForColumn(_:sampleId: nil)` returns em-dash
- `exportValues(for:)` returns correct values per sample
- Column visibility toggling works (add/remove columns, verify cell rendering)

### Integration Tests Per Classifier

For each of the 5 classifiers, test that:
1. Loading metadata and toggling a column visible shows the correct value
2. Multi-sample classifiers show per-row values (not the same value for every row)
3. Export includes metadata columns with correct per-row values

### Test Data

Use synthetic metadata TSV:
```
sample_id	Type	Location
SAMPLE_A	clinical	Boston
SAMPLE_B	environmental	Seattle
```

Paired with synthetic classifier results that reference SAMPLE_A and SAMPLE_B.

## Files Modified

| File | Change |
|---|---|
| `NvdResultViewController.swift` | Extract sample ID from `NvdOutlineItem`, pass in delegate |
| `NaoMgsResultViewController.swift` | Pass `row.sample` in delegate |
| `TaxTriageResultViewController.swift` | Verify `currentSampleId` wiring in sample filter change |
| `TaxonomyTableView.swift` | Verify `currentSampleId` wiring (may need no code change) |
| `ViralDetectionTableView.swift` | Verify `currentSampleId` wiring (may need no code change) |
| `MetadataColumnController.swift` | No changes needed (API already exists) |
| `SampleMetadataStore.swift` | No changes needed |

## Out of Scope

- Metadata editing UI (already exists)
- Metadata import UI (already exists via Inspector)
- New metadata column types (beyond string values)
- Sorting by metadata columns (existing sort infrastructure handles this)
