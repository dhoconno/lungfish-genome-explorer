# Genotype Curation Layout Polish Design

## Goal

Correct three visual defects in genotype-only result views:

1. the manual-haplotype disclosure strip appears to stop at the frozen allele
   pane and uses an oversized grey button;
2. the Supported Alleles pane can collapse into a narrow column at the far
   right of a wide detail view; and
3. the assignment and evidence/comparison cards do not consistently share a
   top edge.

Scientific projections, annotations, workbook updates, audit behavior, and
authoritative haplotyped result views must not change.

## Full-width haplotype strip

The existing frozen and sample header bands remain separate native views so
their scrolling behavior and column geometry do not change. They will render
as one continuous strip:

- both halves use the same window background;
- a one-pixel separator defines the strip without a filled grey bar;
- the disclosure silhouette and `Haplotypes` label form a compact,
  borderless, leading-aligned button instead of filling the frozen pane; and
- the sample-side band continues through the full visible sample viewport.

Expanded locus rows and per-sample values retain their existing layout,
tooltips, typography, and accessibility semantics.

## Sample curation workbench

At wide widths, the workbench uses an explicit 62/38 assignment/evidence
split after accounting for the 16-point inter-column gap. Both columns consume
the complete available width. The assignment column has a 520-point minimum
and the evidence column has a 360-point minimum.

If those minimums cannot be met, or if larger content typography raises the
required breakpoint, the workbench stacks both cards at full width. Existing
hysteresis remains so resizing near the threshold does not flicker between
layouts.

The allocation is a layout constraint only. It must not remount either hosted
view, reset comparison state, replace the virtualized allele table, or change
scroll position.

## Card alignment and appearance

Haplotype Assignments, Compare & Copy, and Supported Alleles use matching
rounded card chrome:

- 8-point corner radius;
- `controlBackgroundColor` fill;
- one-pixel separator stroke;
- 10-point internal padding; and
- 4-point vertical outer inset.

In side-by-side mode, the assignment and evidence/comparison cards share the
same top edge. Supported Alleles fills its allocated evidence column and its
virtualized table scrolls internally at the existing bounded height.

## Accessibility and responsive behavior

- The haplotype disclosure remains keyboard- and VoiceOver-operable.
- At 200% content text size, the workbench stacks before either card becomes
  too narrow.
- Supported Alleles retains its compact table rows and existing accessibility
  labels.
- The full-width strip and card styling work in light and dark appearances by
  using semantic AppKit colors.

## Verification

Mounted tests will cover:

- continuous haplotype strip coverage across frozen and sample panes;
- a compact disclosure button without the old full-width bezel;
- a 2,240-point workbench with no dead center gap and an evidence column near
  38% of the available width;
- equal top coordinates for assignment and evidence/comparison cards;
- full-width stacking at narrower widths and 200% typography;
- stable child, table, and comparison identities across layout changes; and
- the existing dynamic-height, keyboard, accessibility, and performance
  regressions.

