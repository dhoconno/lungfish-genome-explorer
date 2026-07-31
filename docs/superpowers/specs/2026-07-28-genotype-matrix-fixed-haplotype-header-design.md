# Genotype Matrix Fixed Manual-Haplotype Header Design

## Problem

The manual-haplotype assignment band is currently drawn as two sibling overlay views above the pinned and sample table scroll views. The implementation attempts to reserve room for those overlays with `NSScrollView.contentInsets.top`. AppKit does not use that inset as an additional fixed `NSTableHeaderView` section, so table rows can draw beneath the overlays and the ordinary sample header can be clipped. In the observed debug build, genotype rows scroll over the haplotype rows while sample names and per-sample read totals disappear.

## Scope

This repair affects only genotype-only analyses that are eligible for manual haplotype assignment. It does not change workflows, recipes, scientific data, provenance, workbook projection, or haplotyped-analysis viewport behavior.

## Chosen Design

Render the manual-haplotype rows as a lower section of each matrix table's native `NSTableHeaderView`.

- The existing header section remains at the top and continues to draw selectors, sample names, read totals, column comments, and pinned metadata-column labels.
- When manual assignment is eligible, the header height becomes the ordinary header height plus the manual-haplotype section height.
- The pinned header draws the disclosure control and seven locus labels.
- The sample header draws H1/H2 assignment text for each locus in each sample column.
- The native table header remains fixed while the table document scrolls vertically and follows column resizing/reordering and horizontal scrolling using AppKit's existing table geometry.
- Missing assignments use an em dash (`—`) centered on the sample column midpoint. Assigned labels use the same centered layout so the band reads as a per-column summary.
- Collapsing the section leaves one fixed disclosure row; expanding it exposes seven fixed locus rows.
- Ineligible haplotyped analyses retain the ordinary header height and rendering exactly.

The existing manual-haplotype snapshot and selective invalidation model remains the source of display values and accessibility summaries. The sibling overlay views and top-content-inset reservation are removed from the active layout path.

## Alternatives Considered

1. Keep the overlay and adjust scroll-view insets or clip-view tiling. This is a small patch but remains dependent on undocumented AppKit interactions that already failed in the real viewport.
2. Add separate fixed stack containers above both scroll views. This would work, but it duplicates horizontal column geometry and scroll synchronization already supplied by `NSTableHeaderView`.
3. Integrate the section into the native table headers. This is the selected approach because it has one vertical containment model, preserves the existing column model, and minimizes ongoing synchronization work.

## Accessibility and Interaction

- Existing column-selector controls remain in the ordinary header region.
- The disclosure control remains keyboard and accessibility operable in the pinned header.
- Column accessibility labels continue to include the manual-assignment summary.
- Tooltips remain available for truncated assignment text.
- Text size preferences expand both the ordinary header and haplotype rows without overlap.

## Verification

Automated coverage will verify:

- sample names and read totals occupy the ordinary fixed-header section;
- the first genotype row never intersects the fixed header;
- vertical scrolling changes table content position without moving the header;
- expanded and collapsed heights are correct;
- assignment and em-dash text rectangles are centered on sample-column midpoints;
- horizontal scrolling, column resizing, and column reordering retain alignment;
- ineligible haplotyped analyses retain their prior header geometry;
- existing manual-haplotype editing, accessibility, and performance tests continue to pass.

The debug app will then be rebuilt and visually exercised against a representative genotype-only bundle.
