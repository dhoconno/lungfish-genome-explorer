# Genotype-Only Selection Detail Design

## Goal

Make genotype-only result bundles a focused matrix-review experience. These results should expose only the Summary matrix in a list-over-detail layout, and the detail pane should describe the current matrix selection instead of presenting cohort or low-coverage statistics.

This change applies to genotype result bundles that contain genotype calls and have no haplotype analysis. Haplotyped result bundles retain their existing Summary, Review, and Audit lenses and their configurable panel layouts.

## Presentation Rules

For a genotype-only result, the effective display state is always:

- viewport lens: Summary
- summary view: Matrix
- panel layout: List Over Detail

The viewport hides the Summary/Review/Audit segmented control and removes the vertical space reserved for it. The View inspector omits both the Viewport and Panel Layout radio groups. Any previously retained Review, Audit, Outline, or side-by-side display value is normalized before it reaches the viewport, so stale UI state cannot reveal an unsupported presentation.

The existing controls remain unchanged for a result with a haplotype analysis. The common display-state types keep their current cases because haplotyped results still use them.

## Detail Pane Behavior

The genotype-only Summary displays the ordinary scrollable detail pane instead of `GenotypeCohortSummaryPanelView`. Low-coverage outliers, below-threshold samples, and QC cohort summaries are not shown in this mode.

The detail pane follows the matrix selection:

### No selection

Show a concise empty state: “Select a sample column or allele row to view details.” Clearing a matrix selection returns to this state rather than retaining the last selection.

### One sample column

Show the full sample identifier, retained-read and QC values available in the result, and every visible supported allele for that sample. Allele entries include their full display label, locus, unique-read count, alignment count, and support percentage. Entries are ordered by locus and then descending unique-read support.

### One allele row

Reuse the existing shared-call detail where possible. Show the complete allele label, locus, aggregate sample/read/alignment support, and supporting-sample table. When embedded GenBank reference metadata is available, append all non-empty source fields for the selected record using the field definitions and sequence-name mapping already loaded in `ONTGenotypeReferenceMetadata`.

### Multiple allele rows

Show a selection summary followed by one compact entry per selected allele. Each entry contains the full allele label, locus, supporting-sample count, total unique reads, and total alignments. Do not truncate allele names in the model; views may wrap them. GenBank values shared by all selected records may be shown once, while differing values remain associated with their allele entries.

### One or more cells

For a single cell, show the selected sample and allele together with unique reads, alignments, and support percentage. For multiple cells, show a compact evidence table grouped by allele and sample. Mixed row, column, and cell selections use a generic selection summary and preserve annotation-target information rather than making an ambiguous biological interpretation.

Matrix annotations and comments remain visible for the selected targets and continue to use the existing `GenotypeResultSelectionState` publication path.

## Data Flow and Component Boundaries

`GenotypeResultViewController` owns the genotype-only predicate and normalizes incoming display state. It also chooses between the selection-driven detail pane and the existing haplotype/cohort presentation.

`GenotypeResultDisplaySectionViewModel` receives an explicit genotype-only capability from the inspector update path. The SwiftUI section uses that capability to omit unsupported Viewport and Panel Layout controls. The view model also normalizes attempts to set an unsupported lens or layout so programmatic and restored state behave consistently with the UI.

`GenotypeComparisonMatrixView` remains responsible for selection mechanics. Its existing row, column, and cell `MatrixTarget` callbacks are sufficient; selection interpretation and detail construction stay in the view controller. Shared-call lookup uses the loaded result, and GenBank detail lookup uses `ONTGenotypeResultBundleData.referenceMetadata` rather than reopening the embedded database.

No new scientific output is created or transformed. Existing bundle contents, annotations, filters, styles, exports, and provenance are unchanged.

## Error and Fallback Behavior

- A genotype-only bundle with no calls uses the ordinary empty-result behavior rather than being classified as a populated genotype-only matrix.
- If a selected sample is absent from the sample summary table, call-level evidence still appears and unavailable sample metrics are omitted.
- If GenBank metadata is absent or the selected genotype cannot be mapped to a sequence record, allele support remains visible without a metadata section.
- Empty GenBank fields are omitted from detail; values are never synthesized.
- If a target disappears after filtering, clearing or pruning the selection restores the no-selection prompt.

## Testing

Add focused tests covering:

- genotype-only results force Summary, Matrix, and List Over Detail even when another state is applied;
- the viewport lens control is hidden and its reserved top space is removed for genotype-only results;
- the inspector omits Viewport and Panel Layout controls only for genotype-only results;
- haplotyped results continue to expose all lenses and layouts;
- no selection shows the new prompt and not cohort/low-coverage content;
- column selection shows sample metrics and supported alleles;
- single-row selection shows the complete allele and GenBank metadata;
- multi-row selection shows every selected full allele label and aggregate support;
- cell and multi-cell selections show the corresponding support evidence;
- filtering away a selection restores the empty state;
- annotation targets and comments remain published for row, column, and cell selections.

Run the focused `LungfishGenotypeUITests` and `GenotypeResultDisplaySectionTests`, followed by a debug application build. This display-only feature does not require new provenance assertions because it neither creates nor modifies scientific data.
