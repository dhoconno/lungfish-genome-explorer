# Manual Haplotype Save Refresh and Sample Curation Workbench

**Date:** 2026-07-28  
**Status:** Approved  
**Scope:** Eligible genotype-only full-length ONT and miSeq amplicon MHC result viewports

## Summary

Manual haplotype assignments currently persist to the annotation sidecar and
mark `current.xlsx` dirty, but the fixed matrix header continues to show the
pre-save values until a broader reload republishes the sidecar to the matrix.
The selected-sample detail pane also presents the editor, sample statistics,
and supported alleles as a narrow trailing column even when the bottom pane has
substantial horizontal space.

This repair makes saved assignments appear immediately in the fixed header and
replaces the narrow card with a responsive **Sample Curation Workbench**. The
workbench keeps the assignment controls and supporting evidence visible
together, uses a compact seven-row H1/H2 editor, and adapts without losing a
draft or keyboard focus.

The repair does not change scientific workflows, genotype calls, assignment
semantics, workbook layout, audit schema, provenance, or haplotyped-analysis
viewport behavior.

## Expert Review

Three independent reviews covered:

- macOS UI/UX and information architecture;
- AppKit/SwiftUI sizing, responsiveness, focus, and accessibility; and
- annotation-save data flow, redraw scope, workbook scheduling, and
  performance.

All three reviews agreed on the data-flow defect. The UI reviewers independently
recommended a full-width, responsive curation workspace with a compact
`Locus | H1 | H2` editor and adjacent evidence. Alternatives were rejected:

- a fixed evidence rail would hide evidence behind a mode switch at narrow
  widths; and
- a grid of independent locus cards would make cross-locus scanning, keyboard
  order, and large-text behavior worse.

## Goals

1. A successful save or clear immediately updates the selected sample's values
   in the fixed manual-haplotype header band.
2. The refresh invalidates only changed visible sample header regions and does
   not rebuild the genotype projection, rebuild columns, reload matrix rows, or
   synchronize the workbook immediately.
3. The selected-sample detail pane uses its available width and presents sample
   identity, assignments, evidence, and comments in a coherent curation
   workspace.
4. The editor remains usable in top, leading, and trailing panel layouts and at
   the app's supported content text sizes.
5. Responsive reflow preserves the editor model, dirty draft, control identity,
   keyboard focus, and scroll reachability.
6. Existing annotation audit and workbook-dirty behavior remains exactly once
   per successful changed save.

## Non-goals

- No bulk editing across multiple selected samples.
- No change to haplotype label validation, autocomplete semantics, color-token
  assignment, copy semantics, or canonical loci.
- No automatic haplotype inference.
- No change to Excel projection or the timing policy that eventually refreshes
  `current.xlsx`.
- No change to the viewport or Inspector for analyses where haplotyping was
  performed.
- No nested independently scrolling evidence table in this iteration.

## Assay Parity

The save bridge and Sample Curation Workbench are owned by the shared eligible
genotype-only result path. They must be available for both:

- `full-length-ont-mhc-genotype` results whose workflow mode is
  `genotypeOnly`; and
- `miseq-amplicon-mhc-genotype` results whose workflow mode is
  `genotypeOnly`.

The UI must not infer eligibility from read length, candidate naming, or the
presence of `_nov` provisional exon 2 sequences. Existing `_nov` rows and
provisional exon 2 detail remain available in the miSeq viewport while manual
sample assignments are edited.

Any authoritative indication that haplotyping was performed continues to fail
closed through `GenotypeManualHaplotypeEligibility`. Haplotyped ONT and
haplotyped miSeq results retain their existing viewport and Inspector and do
not mount the manual workbench.

## Confirmed Save-Refresh Defect

The editor's save closure calls
`replaceManualHaplotypeAssignments`, marks the current workbook dirty, and
invokes `onAnnotationSidecarChanged`. The app-level callback updates the
Inspector only. It does not apply the new sidecar or assignments to
`GenotypeComparisonMatrixView`.

The editor reload path does apply the sidecar to the matrix, which is why a
later broad refresh repairs the display. The fixed header therefore is not
reading incorrect persisted data; its in-memory
`manualHaplotypeBandSnapshot` is stale.

## Save and Refresh Design

`GenotypeComparisonMatrixView` will expose a narrow assignment-only update
entry point:

```swift
func applyManualHaplotypeAssignments(
    _ assignments: [ManualHaplotypeAssignment]
)
```

The method delegates to the existing immutable assignment index and
`updateManualHaplotypeBand(assignments:)` implementation. That implementation:

1. builds the next header snapshot;
2. compares it to the prior snapshot;
3. determines the changed samples;
4. invalidates only intersecting visible sample rectangles; and
5. refreshes affected header accessibility descriptions.

The successful changed-save sequence becomes:

1. atomically replace the sample's assignments in the annotation store;
2. apply only `currentStore.sidecar.manualHaplotypeAssignments` to the matrix;
3. mark `current.xlsx` dirty once, retaining the existing full-update flag;
4. publish the sidecar callback once for the Inspector; and
5. return the canonical clean draft to the editor.

The sequence must not call `configure`, `applyAnnotationSidecar`,
`applyDisplayState`, `reloadData`, base or derived projection methods, column
rebuilding, or workbook synchronization. An unchanged save performs none of
these actions.

Persistence and audit remain owned by
`replaceManualHaplotypeAssignments`. The new matrix update is presentation-only
and creates no audit entry.

## Sample Curation Workbench

### Wide presentation

At approximately 840 points or wider, the selected-sample detail uses:

```text
Selected Sample: CR1178     Retained 14,734  Alignments 14,734  QC OK
2 of 14 assigned                                      Save Assignments

Haplotype Assignments (about 60–65%)     Supported Alleles (about 35–40%)
Locus       H1             H2            Allele       Locus   Reads   Support
MHC-A       [combo]        [combo]       Mafa…        MHC-A   712     33.3%
MHC-B       [combo]        [combo]       Mafa…        MHC-B   547     33.3%
MHC-DRB     [combo]        [combo]       …
MHC-DQA     [combo]        [combo]
MHC-DQB     [combo]        [combo]
MHC-DPA     [combo]        [combo]
MHC-DPB     [combo]        [combo]
```

The sample identity and statistics are full-width and precede editing.
Assignments occupy the leading column and evidence/comments occupy the
trailing column. Normal pane margins are 16 points and the column gap is 16
points.

The assignment editor is a compact seven-row data-entry grid:

- locus names appear once per row;
- H1 and H2 fields appear side by side;
- clear and validation controls remain adjacent to their field;
- row-major keyboard and VoiceOver order is locus H1, then locus H2; and
- completeness and dirty state remain visible near Save.

Supported alleles become semantic per-allele rows instead of one
undifferentiated wrapping text block. Each row exposes allele, locus, unique
reads, alignments, and support while preserving the existing stable sort order
and selection-state publication. The inline pane previews at most twelve rows.
When more are available, **Show All … Alleles…** opens a separate virtualized
popover. This bounds the detail document height and avoids nesting a second
scroller inside it.

### Responsive presentation

The workbench uses hysteresis to avoid oscillation during live resizing:

- enter two-column mode at 840 points or wider;
- return to one-column mode below 780 points.

In one-column mode, assignments appear first and evidence/comments follow. At
the narrowest supported side-pane widths, each locus retains a readable label
and the H1/H2 editors may stack within the row. The responsive mechanism must
rearrange stable views rather than replace the editor model or remount controls.

The content-width decision includes the current content typography scale.
Larger text causes the single-column and stacked-field layouts to activate
earlier.

### Actions

- **Save Assignments** remains the prominent sample-scoped action and retains
  its existing validation and unchanged-draft disabling.
- **Copy from Sample…** remains searchable and stages changes in the current
  draft. Its picker uses a compact popover so expanding it does not increase the
  detail document height. It must not persist immediately.
- The export action is labeled **Export All Manual Definitions…** so its
  analysis-wide scope is explicit. It remains wired to the existing
  provenance-producing export path and is visually separated from the
  sample-scoped Save action.
- Retry and Reload remain visible when persistence fails.

## AppKit and SwiftUI Layout Contract

The detail pane retains one outer vertical `NSScrollView`. Horizontal scrolling
remains disabled.

The document view remains width-equal to the clip view and at least
viewport-height. A full-width sample-workbench wrapper is constrained to the
detail stack's leading and trailing edges. Every generic top-level detail
section must similarly own an explicit fill-width constraint rather than rely
on `NSStackView.Alignment.width`.

The manual editor's `NSHostingView` is pinned on all four edges inside a
permanent wrapper. The wrapper owns horizontal geometry; SwiftUI intrinsic
width does not. The SwiftUI root uses a flexible leading-aligned width and a
width-constrained intrinsic height.

The fixed `height >= 590` constraint is removed. The host's intrinsic height,
after applying its required external width, determines document height. Text
size changes invalidate the host's intrinsic content size and relayout the
document.

The responsive workbench keeps both assignment and evidence sections mounted
and changes stack orientation and constraint sets in place. The bounded inline
evidence preview creates no nested vertical scroller; the optional complete
evidence list scrolls in a separate popover.

## Accessibility and Keyboard Behavior

- Preserve all existing locus/slot accessibility identifiers.
- Expose `Locus`, `H1`, and `H2` as semantic headers for the assignment grid.
- Preserve row-major traversal through all fourteen combo boxes.
- Keep color supplemental; labels, validation, QC, dirty state, and
  completeness remain textual.
- Validation is exposed as an accessibility description, not only an icon
  tooltip.
- Supported alleles expose semantic rows rather than one combined text element.
- Responsive reflow preserves the first responder and current text selection.
- Focusing the editor lays out first, scrolls the actual H1 control into view,
  and then makes it first responder.
- Large text wraps and grows vertically; it never clips or causes horizontal
  document overflow.

## Performance

Saving one sample must be bounded by:

- assignment-store persistence and its existing audit write;
- one assignment-snapshot comparison;
- redraw of only changed visible sample header regions;
- one workbook-dirty mark; and
- one sidecar callback.

Saving must not trigger:

- base or derived genotype projection passes;
- sample-column reconstruction;
- full or partial matrix row reloads;
- repeated supported-allele computation while typing;
- workbook CLI execution; or
- immediate `current.xlsx` synchronization.

Supported-allele presentation consumes the already sorted snapshot built when
the sample selection changes. Editing a combo box does not rebuild that
snapshot.

## Failure and Edge Cases

- If persistence fails, the header remains unchanged and the dirty draft stays
  available with Retry/Reload.
- Clearing the final assignment for a locus immediately restores the centered
  em dash in that sample's fixed header.
- An unchanged save does not dirty the workbook or redraw the header.
- Read-only analyses retain visible assignments and disable mutation with the
  existing explanation.
- Missing sample summary statistics omit unavailable rows as they do today.
- Large supported-allele collections remain bounded in view construction and
  retain the existing stable sort and published selection details.
- Multi-sample column selection keeps the existing bounded, read-only summary
  and does not mount the workbench editor.

## Verification

Focused tests will prove:

1. Saving Animal A immediately changes only Animal A's header value while
   Animal B remains an em dash.
2. Clearing an existing assignment immediately returns only that sample to an
   em dash.
3. A changed save produces one annotation callback and one workbook
   `.markDirty`, with no `.synchronize`.
4. Base projection, derived projection, column rebuild, full reload, and
   partial reload counters remain unchanged.
5. Persistence contains the saved canonical value and the existing atomic
   replacement audit operation.
6. The editor/workbench fills the pane at representative widths of 280, 420,
   779, 841, 1,200, and 2,300 points without horizontal overflow.
7. Responsive breakpoint crossings preserve host/model identity, dirty draft,
   focused field, and scroll reachability.
8. At 100% and 200% content text size, every control remains visible and the
   document height includes all content.
9. All fourteen combo boxes and clear controls remain discoverable in stable
   locus/H1/H2 accessibility order.
10. Supported allele rows preserve sorting, metrics, and bounded construction.
11. Top, leading, and trailing panel layouts remain usable.
12. The same manual-assignment save propagation, workbench,
    copy-from-sample, and autocomplete paths work for explicit genotype-only
    ONT and miSeq result kinds. Existing shared comment and review-annotation
    behavior remains unchanged.
13. Explicitly haplotyped miSeq results do not expose the manual workbench or
    its sample-header editing command.

The focused genotype viewport and manual-haplotype accessibility suites must
pass. The broader test suite and `git diff --check` are run before completion;
any environment-only failures are reported separately with their exact
evidence.
