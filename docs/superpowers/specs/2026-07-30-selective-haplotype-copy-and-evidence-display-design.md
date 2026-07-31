# Selective Haplotype Copy and Evidence Display Design

**Status:** Approved for autonomous implementation and expert review  
**Date:** 2026-07-30

## Objective

Refine the genotype-only sample workbench so analysts can:

- see every supported allele without opening a second view;
- stage only the useful manual haplotype assignments from a comparison sample;
- recognize read support consistently for named, extension, and novel calls; and
- see long saved haplotype labels immediately without manually resizing a
  sample column.

This work applies to eligible full-length ONT and miSeq amplicon genotype-only
results. Results with authoritative haplotyping remain on their existing
viewport and Inspector paths.

## Scope reduction

This work does not add diagnostic-genotype selection or a reusable haplotype
definition format. The current **Export All Haplotype Assignments…** button is
removed from the genotype-only manual assignment editor.

Existing `diagnosticAlleles` data remains readable and round-trippable so older
bundles and audit records are not damaged. It is not exposed by this interface,
reinterpreted, combined across samples, or exported by a new command.

## User-visible design

### Supported alleles

The Evidence pane always contains the complete supported-allele snapshot for
the selected sample. The twelve-row preview, **Show All …** button, and popover
are removed.

The list remains an inline, bounded, independently scrollable, virtualized
table. “Always show all” means every row is available in this pane without a
second action; it does not mean creating an unbounded workbench or rendering
every row at once.

The table keeps the existing two fields:

| Allele | Read support |
|---|---:|

Rows retain the exact order and scope supplied by the current matrix evidence
snapshot, including current matrix search, filters, thresholds, and row
visibility. Known, extension, novel, provisional exon-2, false-positive,
false-negative, and comment text semantics remain unchanged.

The table has a fixed header and uses the available trailing-pane height. It
continues to reflow to the existing compact row presentation at narrow widths
and at larger content text sizes.

The workbench supplies a finite available height to the virtualized list. The
list is at least 280 points high when that space is available, prefers 360
points, and never exceeds 480 points before using its own vertical scroller.
When the compact workbench is shorter than 280 points, the list uses the
remaining finite height with a 160-point minimum. Larger content text increases
row height and therefore shows fewer simultaneous rows without clipping.

### Selective Compare & Copy

Selecting a comparison sample continues to show its genotype evidence beside
the target sample. Below the comparison summary, the pane adds a compact
assignment chooser grouped in the existing workbook locus order.

Each locus shows source H1 and H2 as independent rows containing:

- a checkbox;
- the source slot and label;
- the current target value, if any; and
- a plain-language outcome: **Fills empty slot**, **Replaces [label]**, or
  **Same assignment**.

Only populated source assignments are selectable. Nothing is selected when a
source is first chosen. Empty source slots are shown as unassigned but cannot
clear target values. Changing the comparison source clears the selection.

A legacy target slot that contains hidden diagnostic metadata or notes cannot
be replaced with a different label through Compare & Copy. It is shown as
**Unavailable—clear the existing assignment first**, with an explanation that
clearing is required to avoid attaching older hidden information to a different
haplotype. Copying the same label remains available and preserves the target
metadata. The disabled reason is included in the checkbox's accessibility
description.

A per-locus **Select assigned** control is available when that locus has at
least one populated source slot. A pane-level **Select all assigned** control is
available as a convenience, but is never the default.

The action button reads:

> Stage N Selected Assignments

It remains disabled when `N` is zero. Staging copies only the selected source
labels and their established color tokens into the corresponding target slots.
Every unselected target slot remains byte-for-byte unchanged. Existing hidden
source metadata is never copied. An empty target receives no hidden metadata.
An eligible populated target retains its existing metadata only when the source
label represents the same normalized haplotype label. This feature does not
create, merge, infer, or silently delete diagnostic allele definitions.

Staging is still reversible and does not write the sidecar, update
`current.xlsx`, or run the CLI. **Save Assignments** remains the only persistence
action. If the target draft already contains unsaved edits in a selected slot,
the existing confirmation is narrowed to the selected replacements and names
the affected locus/slot values. Cancelling leaves the draft unchanged.

After staging, the editor reports how many assignments were staged and from
which sample. The normal saved before/after assignment audit, author, timestamp,
and source-sample context remain intact. The draft reports one operation-wide
copy source only when every staged copied slot came from the same source and no
manual edit is mixed into that save. Staging from a second source or manually
editing any assignment after staging clears the operation-wide copy source.
The saved before/after values remain the authoritative audit record, and the
audit never attributes manually edited or mixed-source slots to one sample.

### Removed export control

The genotype-only editor no longer displays **Export All Haplotype
Assignments…**. The genotype-only artifact-lens manual-haplotype section also
removes its **Export Manual Definitions…** control and callback. Removing these
two GUI entry points does not delete stored assignments, legacy diagnostic
metadata, audit events, provenance, or existing files that an analyst exported
previously.

The older haplotyped-analysis UI is outside this scope and is not changed.

### Consistent read-support color

In **Cell Color: Support** mode, every projected sample cell with positive read
support uses the same blue support color. The rule no longer depends on whether
the row is a named allele, extension, novel candidate, or provisional exon-2
sequence.

The derived matrix projection remains the scientific eligibility boundary. Its
existing read and percentage filters continue to decide which rows and
sample-support entries survive; this change does not reinterpret candidate
population percentages as per-sample read percentages. Once a support entry
survives that projection and has `passedUniqueReads > 0`, it receives a fixed
blue support fill at the existing maximum support opacity. Fill intensity does
not encode a percentage or denominator. A missing or zero-read support entry
receives no automatic fill.

Allele type remains visible in the allele-name column through its existing text,
qualifier, and tint treatment. The support fill does not replace these cues.

Presentation precedence remains:

1. an analyst-applied cell fill;
2. selection and annotation overlays;
3. automatic support fill; and
4. ordinary row background.

False-positive cells retain faded italic bracketed read counts, even when their
projected positive read support qualifies for the support fill. False negatives
retain their no-read display and border. Comments, selection borders, and
accessibility descriptions remain unchanged.

### Immediate sample-column auto-fit after save

After a successful manual assignment save, the matrix remeasures only samples
whose displayed assignment pairs changed.

For each changed, visible sample while the haplotype band is expanded, the
current column width is the widest of:

- the sample name and retained-read header;
- the analyst’s stored preferred width; and
- all seven displayed `H1 · H2` assignment pairs.

The enforced minimum width is the wider of the header and displayed assignment
pairs; it does not include the stored preferred width. A genuine user drag may
therefore narrow a previously wide preference down to that visible-content
minimum and records the new preference.

The table and scroll document complete their native layout before the pinned
haplotype band reads the updated column geometry. The affected column therefore
widens immediately; no manual resize is needed to trigger the change.

Automatic widening never overwrites the analyst’s stored preferred width.
Users may widen a column further, but cannot narrow it below the widest visible
assignment while the band is expanded. Collapsing the band restores the larger
of the ordinary header width and user preference. The matrix preserves its
semantic horizontal anchor so columns do not appear to jump during the update.

## State and component boundaries

### Supported-allele presentation

`GenotypeSupportedAllelesSnapshot` remains the ordered value snapshot.
`GenotypeSupportedAllelesVirtualizedList` becomes the sole row renderer used by
the inline panel. It gains a native fixed header and width-aware compact cell
layout because those behaviors currently exist only in the preview. The
popover-only state and button wrapper are deleted.

The inline list receives stable rows, fonts, and a bounded height. Snapshot
changes update the existing table/coordinator rather than remounting the
workbench or creating one SwiftUI view per allele.

### Selective-copy state

`GenotypeSampleComparisonModel` owns:

- the selected source sample;
- selected source slot addresses;
- the selected-slot outcome summaries;
- the pending selective-copy confirmation; and
- the staged status message.

It does not own the editor draft or persistence. `GenotypeManualHaplotypeEditor`
adds a value-semantic operation that copies a provided set of locus/slot
addresses from one source snapshot. The controller continues to provide source
assignments and connects the staged operation to the existing draft.

The comparison model receives the current target slot snapshot and draft
revision whenever the editor changes. Fill/replace/same/unavailable outcomes
therefore update while Compare & Copy remains open.

Selection state is presentation-only. It is discarded when the source changes,
the workbench changes target samples, the bundle changes, or staging completes.
A source refresh API replaces candidate snapshots and clears a selected source
that no longer exists.

Requesting confirmation captures the source sample, selected slot addresses,
source assignment values, and target draft revision as one immutable pending
request. Source and checkbox controls are disabled while it is pending. Confirm
revalidates the request against the live source snapshot and target draft.
Staging returns applied and skipped slot addresses so disappeared or newly
ineligible values are reported without clearing targets.

### Support-color rule

The automatic support background remains centralized in
`GenotypeComparisonMatrixView`. One eligibility function decides whether the
projected sample cell has positive read support, independent of row population.
Manual style, review, and selection layers continue to use their existing
rendering paths.

### Column sizing

The existing per-sample measurement cache remains authoritative. A successful
save invalidates and remeasures only changed samples. Width changes are applied
as one guarded batch, then the AppKit table/scroll layout is completed before
manual-band frames and headers are refreshed.

## Accessibility

- The inline allele table remains one keyboard region with virtualized rows and
  retains complete allele/read-support VoiceOver labels.
- Compare assignments are grouped by locus. Each checkbox announces source
  sample, locus, H1/H2 slot, source label, current target label, and whether it
  fills, replaces, or matches.
- Tab enters and leaves the assignment chooser; arrows move within it; Space
  toggles the focused assignment.
- **Stage N Selected Assignments** exposes the same count in its accessibility
  label and confirmation.
- Checkboxes, words, and bracket/border treatments carry meaning without
  relying on color.
- At 200% content text, labels wrap or reflow; controls do not clip and the
  workbench does not remount or lose its draft.
- Read-only bundles may open and navigate Compare & Copy. Source selection and
  evidence remain available, while every Stage and Save action is disabled and
  announced as read-only.

## Performance requirements

- A supported-allele snapshot with at least 1,000 rows remains virtualized.
  Opening the Evidence pane must not create one native view per row.
- Filtering or refreshing evidence updates the existing list and does not
  rebuild the assignment editor.
- Searching comparison samples does not precompute genotype or assignment
  details for every source.
- Selecting source slots is local presentation work and runs no CLI or
  projection rebuild.
- Staging or saving selected assignments remeasures at most the affected sample
  columns.
- Extending support fill to candidate rows does not rebuild the base projection
  and stays within the existing matrix drawing path.

## Error handling and compatibility

- A comparison source that disappears after a refresh clears the source and
  slot selection without changing the draft.
- A selected source assignment that disappears before staging is skipped and
  reported; no target slot is cleared.
- A legacy target containing hidden diagnostic metadata or notes is unavailable
  for a different-label replacement until the analyst explicitly clears and
  saves that assignment.
- Read-only bundles show the evidence and comparison but keep staging and save
  actions disabled.
- Legacy assignments and unrecognized loci continue to round-trip under the
  existing preservation rules.
- No workflow recipes, genotype calling rules, reference resolution, workbook
  projection schema, or haplotyped-analysis presentation changes are included.

## Audit and provenance

Selective staging itself is not persisted. Saving uses the existing atomic
annotation-sidecar transaction and audit event containing author, timestamp,
and before/after assignment values. The existing single source field is written
only for a clean, single-source copied draft; it is omitted for manual or
mixed-source edits so the audit never makes a false attribution. Workbook dirty
tracking and the subsequent audited `current.xlsx` update remain unchanged.

Removing the two genotype-only export controls eliminates those GUI export
entry points; it does not weaken provenance for any remaining scientific
command or workflow.

## Verification

Automated coverage must include:

1. an inline virtualized table exposing all 1,001 rows with no Show All button
   or popover;
2. preserved matrix order, qualifiers, false-positive/negative presentation,
   and 200% text behavior;
3. independent H1/H2 and per-locus selection;
4. default-zero selection and disabled stage action;
5. selected-slot staging that leaves all unselected and blank-source target
   slots unchanged;
6. a different-label replacement blocked when the target contains legacy
   diagnostic-only metadata, notes-only metadata, or both, with same-label
   preservation, empty-target eligibility, and no copied source metadata;
7. live chooser outcomes after manual draft changes, plus an immutable pending
   confirmation and revalidation when source assignments change;
8. accurate single-source audit context and omitted source attribution for
   mixed-source or manually mixed drafts;
9. narrowed dirty-draft confirmation and cancellation with no draft mutation;
10. no writes, CLI calls, or workbook dirtying before Save;
11. audited persistence after Save for ONT and miSeq genotype-only fixtures;
12. unchanged ineligibility and presentation for haplotyped fixtures;
13. equal fixed support fill for projected positive-read named, extension,
    novel, and provisional exon-2 cells;
14. no automatic fill for missing/zero support, no candidate population
    percentage used as cell intensity, plus unchanged manual-fill,
    false-positive, false-negative, comment, and selection precedence;
15. removal of both genotype-only export controls while the legacy haplotyped
    presentation remains unchanged;
16. read-only comparison browsing with disabled Stage and Save actions;
17. immediate expanded-band widening after saving a maximum-length label,
    without a resize callback;
18. unchanged user-preferred width during automatic sizing, user-driven
    preference reduction down to the visible-content minimum, only one sample
    remeasured, correct collapse restoration, and preserved horizontal anchor;
19. a fixed-header, compact-reflow virtualized list within the specified
    160/280/360/480-point height rules; and
20. focused responsiveness/performance checks for large allele lists,
    comparison selection, support-color drawing, and post-save auto-fit.
