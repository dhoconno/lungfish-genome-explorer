# Genotype Matrix Native Annotations Design

Date: 2026-06-30
Branch: `codex/genotype-matrix-annotations`

## Goal

Add a lightweight Lungfish-native annotation workflow for genotype-only `.lungfishgenotype`
bundles whose references do not define haplotypes. Users should be able to inspect and
decorate the genotype matrix in-app instead of moving immediately to Excel.

This feature must not replace or duplicate the full haplotyping review interface. It is a
raw genotype matrix annotation mode that reuses existing matrix, sidecar, workbook, and
provenance infrastructure where practical.

## Approved Direction

Use a genotype-only matrix mode with shared primitives.

- Genotype-only bundles open the native raw genotype matrix by default, not Quick Look.
- Bundles with haplotype analysis keep the existing haplotyping-oriented experience.
- Persistent comments and styles are saved as Lungfish bundle annotations in
  `annotations.json`.
- `current.xlsx` is kept in sync so users can move between Lungfish and Excel
  interchangeably.
- Excel/workbook syncing is debounced in the background after sidecar saves.

## Non-Goals

- Do not build a general-purpose Excel editor.
- Do not add editable per-reference locus-mapping rules in v1.
- Do not add rich formatting to comment text.
- Do not implement saved sample-set or cohort filter presets in v1.
- Do not mutate genotype calls when display filters are applied.

## Data Model

Matrix annotation targets are first-class and independent of haplotype slots:

```text
row:    locus + genotype
column: sample id
cell:   locus + genotype + sample id
```

Row targets use the resolved matrix locus plus the raw genotype label. The resolved locus
must come from Lungfish's built-in locus-resolution rules, including macaque/MCM-specific
cases where allele prefixes such as `Mamu-I*` are assigned to an appropriate MHC locus.

Column comments and styles attach to the sample identity so they can appear wherever that
sample is inspected in the app, not only in this matrix.

Empty or unsupported cells are annotatable. This is required for expected genotypes that are
missing from the data but should still be marked by the analyst.

Styles supported in v1:

- Fill/background color
- Text color
- Bold
- Italic

Comment bodies remain plain text.

Style precedence:

1. Cell-specific style wins for explicitly set properties.
2. Otherwise row and sample-column styles are inherited.
3. Row and column inherited styles can combine, such as row fill plus column text color.

## UI And Interaction

Add a dedicated right-inspector `Annotations` tab for persistent matrix annotations.

The existing `View` tab remains for reversible display state such as matrix mode, thresholds,
denominator choices, free-text filters, and display color modes. Persistent comments and
styles do not live in `View`.

Selection must support:

- Single row, column, or cell
- Multiple rows, columns, cells, or mixed targets
- Empty cells
- Header click for column selection
- Row click for row selection
- Cell click and modifier-based multi-selection for cells

When a row is selected, the `Annotations` tab shows row comments and row style controls.
When a column is selected, it shows sample comments and sample style controls. When a cell is
selected, it shows row comments, sample comments, then cell comments, with cell controls as
the primary editing surface.

Multi-selection shows shared or mixed style state and applies edits to all selected targets.

Add a selection helper:

- From a selected row, select only cells that have genotype support and `passedUniqueReads`
  greater than or equal to a user-provided threshold `N`.
- The helper must never select empty or unsupported cells.
- The helper is a one-time selection action. It does not create a saved dynamic rule.

Annotated rows, column headers, and cells should show a compact marker. Hover tooltips show
the newest relevant comment or a short summary. Full comment threads live in the
`Annotations` tab.

## Display Filters

V1 display filters:

- Free-text row filter for genotype/locus text, such as `Mamu-B`
- Free-text sample/column filter for sample IDs and sample metadata
- Per-cell minimum read count
- Per-cell minimum read percentage
- Percentage denominator picker:
  - Sample retained reads across the genotype result
  - Sample reads within the row's locus

Filtering is display-only. A cell is hidden when it fails the active read or percent
thresholds. A row stays visible if at least one visible cell remains in the current
sample/column set. Column filtering prunes sample columns visually but does not delete calls
or annotations.

Saved annotations must persist and sync even when their targets are hidden by current
filters.

## Excel Sync And Provenance

Annotation edits save immediately to `annotations.json`. The app then schedules a debounced
background update to `artifacts/workbooks/current.xlsx`.

`current.xlsx` must reflect:

- Cell, row, and sample-column fill colors
- Text colors
- Bold and italic text styling
- Cell, row, and sample comments
- Annotations on empty or unsupported cells
- All saved annotations, including annotations currently hidden by filters

If the workbook sync fails, the LGE annotations remain saved and the `Annotations` tab shows
a failed or pending sync state with a retry action. If the bundle is read-only, annotation
editing and Excel sync are disabled with a clear message.

All scientific-data-producing workflows must write reproducibility provenance. Sidecar
annotation writes, annotation-bearing workbook updates, and annotation-bearing exports are
in scope for provenance. Export and workbook-update provenance should reference stable
bundle inputs such as `annotations.json`; they must not depend only on deleted temporary
projection files.

## Implementation Slices

1. Native genotype-only routing: genotype-only bundles open the raw matrix, not Quick Look.
2. Matrix selection model: row, column, cell, multi-selection, and empty-cell targeting.
3. Annotation schema/store: matrix target comments/styles, audit records, provenance, and
   read-only behavior.
4. Rendering: inherited styles, markers, hover tooltips, bold/italic/text color/fill.
5. Inspector `Annotations` tab: selection-aware comment/style editing and sync status.
6. Display filters: row text, sample text, per-cell read threshold, per-cell percent
   threshold, and denominator selection.
7. Selection helper: selected row to supported cells with reads >= `N`, never empty cells.
8. Debounced Excel sync: `annotations.json` first, then `current.xlsx`, with retry/failure
   state.
9. Export/provenance: stable sidecar input and all saved annotations written regardless of
   active filters.

## Test Plan

Add focused regression tests for:

- Genotype-only `.lungfishgenotype` routing to native matrix.
- Genotype-only default state showing the raw matrix.
- Row, column, cell, empty-cell, and multi-selection identities.
- Matrix annotation schema round-tripping, audit entries, and provenance sidecars.
- Read-only bundle behavior.
- Style precedence: cell override, row inheritance, column inheritance, and row/column
  combination.
- Comment markers and tooltip summary source.
- Inspector selection rendering for row, column, cell, and multi-selection.
- Per-cell count and percentage filters.
- Denominator selection for percent filters.
- Row visibility when no visible cells remain.
- Sample-column free-text pruning.
- Selection helper behavior, including the requirement not to select empty cells.
- Debounced workbook update success, failure, retry, and pending state.
- `current.xlsx` containing saved annotations on visible and hidden targets.
- Annotation-bearing export provenance referencing stable sidecar inputs.

## Risks

- Coordinate drift between matrix rows, workbook sheets, and future locus-resolution changes.
- XLSX comments are more complex than fills/styles because they require additional package
  parts and relationships.
- Existing matrix highlight controls are display-oriented, so persistent annotation controls
  must be visually and architecturally distinct.
- Debounced workbook sync must avoid excessive rewrites during color picker drags while still
  feeling immediate.

## Rollout

Implement in iterative passes. After each pass, run targeted tests and have review agents
inspect code quality, UX consistency, data/provenance coverage, and failure modes. Apply
review improvements and repeat for no more than five review cycles. End by producing a debug
build that can be tested locally.
