# Phase 4 Virtualization Audit

Date: 2026-07-02
Context: Fable-only GUI performance refactor, Phase 4 (large-dataset scaling).

> **Archive note (2026-07-05):** This is the historical audit that retargeted
> the performance phase. Do not treat the findings table below as a current
> backlog without re-checking source. In particular, `GenotypeOutlineView` is
> now backed by a virtualized `NSTableView`; see
> `GenotypeOutlineVirtualizationTests`.

## Why this audit

The implementation plan's original Phase 4 assumed non-virtualized result
*tables* needing a top-N *row* cap (5000-row threshold, 1000-row window). Before
implementing a UX-altering cap, we verified the premise against AppKit reality.

## Key principle

`NSTableView` and `NSOutlineView` VIRTUALIZE ROWS — they instantiate cell views
only for visible rows. A large row count therefore does NOT cause a rendering
blowup for them, and a top-N row cap gains no rendering benefit (it only hides
data). They do NOT virtualize COLUMNS (every column view is created), and
`NSStackView` layouts (`addArrangedSubview` per item) are not virtualized at all.
So the genuine scaling risks are: (a) `NSStackView`/manual view-per-item growing
with the data, and (b) column-per-sample/per-item fan-out on a table/matrix.

## Findings

### Genuine non-virtualized scaling problems (Phase 4 targets)

| Surface | File:line | Problem | Reach |
|---|---|---|---|
| GenotypeOutlineView | `LungfishGenotypeUI/GenotypeOutlineView.swift:~225` | **NSStackView, one full row view-tree per sample** (block glyph + label + tape). Unbounded. **Worst case.** | 100+ samples = 100+ view trees upfront |
| GenotypeComparisonMatrixView | `LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:~523` | One column per visible sample | 50–200+ |
| TaxTriageBatchOverviewView | `LungfishTaxTriageUI/TaxTriageBatchOverviewView.swift:~218` | Organism×sample heatmap, one column per sample | 50–100+ |
| StrainComparisonView | `LungfishTaxTriageUI/StrainComparisonView.swift:~121` | One column per sample | 10–100+ |
| GenotypeHaplotypeDefinitionMatrixView | `LungfishGenotypeUI/GenotypeHaplotypeDefinitionMatrixView.swift:~259` | One column per diagnostic allele | 10–50 (lower reach; assess) |

### Safe surfaces (row-virtualized or already bounded — NO change)

- GenotypeResultTableView — NSTableView, 7 fixed columns.
- ViralDetectionTableView (EsViritu) — NSOutlineView, 9 fixed columns.
- BatchTaxTriageTableView — NSTableView, 9 fixed columns.
- EsVirituDetailPane — NSStackView but bounded (5 fixed metrics).
- GenotypeResultViewController detail loops — already `prefix`-capped (24, 8, 80, 40) or bounded by locus count.

## Effect on the plan

The original 5000-row / 1000-row-window / 200-column pinned thresholds are
DROPPED. Phase 4 is retargeted to virtualize `GenotypeOutlineView` and to
column-window the per-sample matrices/heatmaps. Row caps on the already-virtualized
result tables are NOT implemented (no benefit, would hide data).

The genotype v2 work (`codex/lungfishgenotype-viewport-inspector`) has landed on
main, so these genotype UI files are safe to edit directly.
