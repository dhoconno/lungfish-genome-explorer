# FASTQ Operations UX — Unified Design Specification

**Version:** 1.0
**Date:** 2026-03-08
**Synthesized from:** Team A/B (Operations Panel Redesign) + Team C (Inspector & Workflow IA)

---

## Design Decisions (Synthesis)

Where the two design specs diverged, the following choices were made:

| Decision | Team A/B | Team C | **Chosen** | Rationale |
|----------|----------|--------|-----------|-----------|
| Operation discovery | Sidebar within middle pane | Inspector Selection tab | **Sidebar in middle pane** | Keeps operations visible alongside preview canvas; Inspector width (260pt) too narrow for a usable list |
| Parameter entry | Inline parameter bar above preview | Modal sheet (NSPanel) | **Inline parameter bar** | Direct manipulation — slider changes update preview instantly; modal blocks preview |
| Charts | Sparkline strip (3 inline, 52pt) + popover | Sparklines in Inspector + click to full chart | **Sparkline strip + popover** | Keeps content area self-contained; popover is simpler than tab switching |
| Console | Eliminated entirely | Reduced to pure log | **Eliminated** | Status goes to activity bar + Inspector provenance; console is dev-facing |
| Results display | Results table (reads + derived files) | Toast + sidebar nesting | **Both** | Results table in bottom pane; derived files also nest in sidebar |
| Comparison | Side-by-side split | Side-by-side with overlay charts | **Overlay charts** (Phase 2) | Single chart with overlaid data is more space-efficient |

---

## Architecture Summary

```
FASTQDatasetViewController (NSViewController)
  +-- NSSplitView (vertical, 3 panes)
  |   +-- topPane: FASTQSummaryPane (NSView)
  |   |   +-- FASTQSummaryBar (existing, retained)
  |   |   +-- FASTQSparklineStrip (new) — 3 inline sparklines
  |   +-- middlePane: OperationPreviewPane (NSView)
  |   |   +-- operationSidebar (NSTableView, source list, 180pt fixed)
  |   |   +-- previewArea (NSView)
  |   |       +-- parameterBar (NSStackView, 36pt)
  |   |       +-- previewCanvas (OperationPreviewView)
  |   |       +-- runBar (NSView, 36pt)
  |   +-- bottomPane: ResultsPane (NSView)
  |       +-- NSSegmentedControl (Reads / Derived Files)
  |       +-- ReadTableView or DerivedFilesView
```

### Inspector Additions (Document Tab)

When viewing derived FASTQ files:

1. **Provenance section** (DisclosureGroup) — vertical timeline of lineage
2. **Command block** — scrollable monospace, copy button
3. **Input file link** — clickable, navigates to parent in sidebar

### Inspector Additions (Selection Tab)

- **Estimated Impact** section — transient, shows when operation is configured

---

## Implementation Phases

### Phase 1: Layout Foundation
- Rewrite FASTQDatasetViewController to 3-pane NSSplitView
- Create FASTQSparklineStrip (3 mini CoreGraphics charts)
- Create operation sidebar (NSTableView, source list style, 6 categories)
- Create parameter bar + run bar skeleton
- Remove old operation controls from bottom pane
- Wire up operation selection → parameter bar population

### Phase 2: Preview Canvas (3 Operations)
- Create OperationPreviewView base class (CoreGraphics canvas)
- Implement Quality Trim preview (single read, base cells, sliding window)
- Implement Subsample preview (8 reads, kept/discarded)
- Implement Length Filter preview (8 reads, threshold lines)
- Wire parameter changes → preview updates with 150ms animation

### Phase 3: Remaining Previews
- Adapter Trim, Fixed Trim, Contaminant Filter
- Error Correction, Deduplicate
- Deinterleave/Interleave, Paired-End Merge/Repair
- Search by ID, Search by Motif

### Phase 4: Inspector & Polish
- Provenance timeline in Document tab
- Command display with copy button
- Estimated Impact section in Selection tab
- Results table (reads browser + derived files)
- Derived file nesting in sidebar outline
- Animation polish + reduced motion support

### Phase 5: Comparison Mode (Future)
- FASTQComparisonViewController
- Overlay histograms
- Delta statistics in Inspector

---

## Key Specs Reference

- **Sparkline strip**: 52pt tall, 3 equal-width charts, CoreGraphics filled area
- **Operation sidebar**: 180pt fixed width, source list style, SF Symbols
- **Parameter bar**: 36pt tall, controls vary by operation
- **Preview canvas**: CoreGraphics, `isFlipped = true`, 60fps during animation
- **Run bar**: 36pt tall, output estimate + Run button (Cmd+Return)
- **Read schematic**: 20pt tall rounded rect, 3pt corner radius
- **Quality colors**: Q≥30 green, 20-29 yellow, 10-19 orange, <10 red
- **All colors**: NSColor semantic tokens only, no hardcoded RGB
- **Animations**: 150ms parameter updates, 200ms fade, 250ms operation switch
- **Reduced motion**: instant transitions, no pulsing
- **Popover for full charts**: 360x280pt, `.semitransient`

See `fastq-operations-panel-redesign.md` for full per-operation preview specs.
See `fastq-inspector-ia.md` for full Inspector layout specs.
