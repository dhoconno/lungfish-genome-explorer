# Batch Aggregated Classifier Views

**Date:** 2026-04-06
**Status:** Draft

## Overview

When a user clicks a batch group icon in the sidebar (not an individual sample child), the app displays an aggregated view combining data from all samples in the batch. This applies to Kraken2, EsViritu, and TaxTriage batch runs. The aggregated view follows the pattern established by NAO-MGS and NVD: a flat table with a Sample column, sample filtering via the Inspector, dynamic metadata columns joined on sample name, and a detail pane that works only with single-row selection.

Individual sample viewing is unchanged.

## Data Model

### Flat Row Types

Each classifier gets a flat row struct for the aggregated table. Rows are built by parsing each sample's result files and tagging with the sample ID.

**Kraken2** — `BatchClassificationRow`:
- `sample: String`
- `taxonName: String`
- `rank: String`
- `readsDirectly: Int`
- `readsClade: Int`
- `percentage: Double`
- All existing columns from the single-sample kreport table are preserved.

**EsViritu** — `BatchEsVirituRow`:
- `sample: String`
- `virusName: String`
- `assembly: String`
- `uniqueReads: Int`
- `coverageBreadth: Double`
- `coverageDepth: Double`
- All existing columns from the single-sample detection table are preserved.

**TaxTriage** — extends existing `TaxTriageTableRow`:
- Already has multi-sample infrastructure. The existing `allTableRows` array gains a Sample column in the table display. The segmented control approach (All Samples vs per-sample tabs) is replaced with the flat-table-with-Sample-column pattern plus Inspector sample picker.

### Aggregation Strategy

Parse on load, cache in memory. The `configureBatch` method reads each sample's result files from the batch manifest, builds flat row arrays, and holds them for the view's lifetime. No SQLite database or on-disk cache.

If profiling shows large batches (50+ samples) are slow to open, a lightweight JSON cache in the batch directory can be added as a future optimization.

## Sidebar Routing

### Current Behavior

`.batchGroup` items are excluded from `displayContent(for:)` in `MainSplitViewController`. Clicking the batch group icon is effectively a no-op for the viewport.

### New Behavior

In `MainSplitViewController.displayContent(for:)`, the `.batchGroup` case:

1. Detects the tool type from the batch directory name prefix (`kraken2-batch-...`, `esviritu-batch-...`, `taxtriage-batch-...`)
2. Routes to the same view controller as individual results: `TaxonomyViewController`, `EsVirituResultViewController`, or `TaxTriageResultViewController`
3. Calls a new `configureBatch(batchURL:manifest:projectURL:)` method that puts the VC into batch mode

## View Controller Changes

### Batch Mode Flag

Each of the three VCs gains an `isBatchMode: Bool` property. The `configureBatch` method sets this to `true` and populates the aggregated row arrays.

### Kraken2 — TaxonomyViewController

- **Sunburst**: Hidden in batch mode.
- **Table**: The existing `NSOutlineView` hierarchy is hidden. A new flat `NSTableView` is shown with columns: Sample, Taxon Name, Rank, Reads (direct), Reads (clade), Percentage, plus dynamic metadata columns.
- **Sample picker**: Populated from batch manifest sample IDs.
- **Metadata columns**: `MetadataColumnController` set to `isMultiSampleMode = true`, using per-row `sampleId` lookups.

### EsViritu — EsVirituResultViewController

- **Table**: The existing `ViralDetectionTableView` outline is hidden. A new flat `NSTableView` is shown with columns: Sample, Virus Name, Assembly, Unique Reads, Coverage Breadth, Coverage Depth, plus dynamic metadata columns.
- **Sample picker**: Populated from batch manifest sample IDs.
- **Metadata columns**: Same `MetadataColumnController` pattern.

### TaxTriage — TaxTriageResultViewController

- **Table**: The segmented control (All Samples vs per-sample tabs) is replaced. A flat `NSTableView` with columns: Sample, Organism, TASS Score, Reads, Confidence, plus dynamic metadata columns.
- **Sample picker**: Populated from batch manifest sample IDs (replaces segmented control filtering).
- **Metadata columns**: Same pattern.

### Flat Table Implementation

Each VC embeds a second `NSTableView` alongside the existing outline view. Only one is visible at a time based on `isBatchMode`. This avoids regressions in the existing single-sample tree/outline views.

All flat tables support:
- Multi-row selection (Shift+click, Cmd+click)
- All columns sortable (Sample alphabetically, numeric columns numerically)
- Right-click column header to toggle metadata column visibility

## Inspector Integration

When a batch group is selected, the Inspector's result summary tab shows four collapsible sections (using `DisclosureGroup`, all expanded by default):

### 1. Operation Details

Tool name and version, database name/version (Kraken2), all pipeline parameters used (confidence threshold, thread count, etc.). Sourced from the batch manifest's stored configuration. Formatted as a labeled key-value list.

### 2. Sample Picker

`ClassifierSamplePickerView` listing all samples with toggle checkboxes. Toggling samples filters the aggregated table in real time. Uses `ClassifierSamplePickerState` shared between Inspector and VC.

### 3. Metadata Import

"Sample Metadata" section with an "Import..." button. Opens `NSOpenPanel` for CSV/TSV. File must have a column matching sample IDs. On import, creates `SampleMetadataStore` and passes to `MetadataColumnController` for dynamic table columns. Follows the existing NVD pattern.

### 4. Source Samples

List of original FASTQ bundles included in the batch, each rendered as a clickable link. Clicking navigates the sidebar to that FASTQ bundle and opens it. Sample IDs from the manifest map back to bundle URLs in the project.

### Individual Sample Children

When an individual sample child is selected (not the batch group), the Inspector shows single-sample result metadata as today. No sample picker, no metadata import. Still shows operation details and a link back to its source FASTQ bundle.

### Wiring

`InspectorViewModel` detects when the active viewport is in batch mode and exposes `samplePickerState`, `sampleEntries`, and `sampleMetadataStore` for SwiftUI Inspector sections to bind to. Mirrors how `NaoMgsResultViewController` feeds state to the Inspector.

## Detail Pane Behavior

### Single Row Selected (Batch Mode)

- **Kraken2**: Taxon detail — classification counts, taxonomy info, scoped to the selected sample. Header shows both taxon name and sample name.
- **EsViritu**: Coverage plot + assembly metadata + mini-BAM viewer for the selected virus+sample pair.
- **TaxTriage**: BAM viewer for the selected organism+sample pair.

Same content as single-sample detail pane, scoped to the specific row's sample.

### Multiple Rows Selected

Standard "Select a single row to view details" placeholder. Matches NAO-MGS behavior.

### No Rows Selected

Overview/empty state appropriate for the tool.

## Scope

### In Scope

- Clicking batch group icon opens aggregated flat table with Sample column
- Sample picker in Inspector for filtering
- Metadata column import (CSV/TSV joined on sample name)
- Operation details (methods, versions, parameters) in Inspector
- Clickable links to source FASTQ bundles in Inspector
- Collapsible disclosure sections in Inspector
- Multi-select placeholder in detail pane
- Kraken2 sunburst hidden in batch mode
- All existing single-sample columns preserved

### Out of Scope

- Changes to individual sample viewing (unchanged)
- New export formats
- Cross-tool aggregation (each batch is one tool)
- SQLite database for aggregated data (deferred unless profiling shows need)
- Sunburst aggregation or replacement visualization in batch mode

## Existing Patterns Referenced

- **NAO-MGS** (`NaoMgsResultViewController`): Multi-sample flat table, `ClassifierSamplePickerState`, `MetadataColumnController`, detail pane single/multi selection
- **NVD** (`NvdResultViewController`): Metadata import via Inspector, `SampleMetadataStore`, dynamic columns
- **TaxTriage** (`TaxTriageResultViewController`): Existing batch infrastructure (`TaxTriageBatchOverviewView`, `allTableRows`)
- **Batch manifests** (`MetagenomicsBatchResultStore`): Sample enumeration, result directory mapping
- **Inspector** (`AnalysesSection`): Parameter display, disclosure groups
