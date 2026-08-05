# Compact miSeq Haplotype Band and Shared Assignment Editor

**Date:** 2026-08-04
**Status:** Approved for implementation

## Objective

Make the haplotyped miSeq genotype matrix compact and editable in the same
place as full-length genotype-only results. The matrix band should communicate
the two effective haplotypes at a glance, while a selected sample column should
open the familiar two-slot-per-locus assignment editor.

The change is presentation and review-state editing only. It does not change
the miSeq recipe, genotype calls, haplotype definitions, or scientific calling
thresholds.

## Compact Matrix Band

Each sample/locus row displays one centered compact value:

- two calls: `M2A • M4A`;
- one call: `M2A • —` or `— • M4A`;
- no assigned call, no haplotype, or not assayed: `—`;
- unresolved excess genotypes: `Too many genotypes`;
- unresolved excess haplotypes: `Too many haplotypes`.

The visible row must not contain `H1`, `H2`, `called`, `pipeline`, or `analyst
override`. Those details remain available in the existing per-slot hover help,
keyboard targets, and VoiceOver labels. The row retains two invisible semantic
hit regions so an analyst can still activate H1 or H2 independently.

Auto-sizing measures the compact combined value instead of the verbose
per-slot descriptions. Long valid haplotype labels still widen the sample
column enough to remain visible, subject to the matrix's existing viewport
limits.

## Selected-Sample Editor

Selecting exactly one sample column in a haplotyped miSeq Genotype Matrix opens
the same visual assignment pattern used for full-length genotype-only review:

- `Haplotype Assignments` heading and completeness summary;
- one row for each included miSeq haplotype locus;
- side-by-side H1 and H2 combo fields when space permits, stacking at the same
  accessibility breakpoint as the existing editor;
- existing haplotype names offered as completion choices;
- one Save action for all changed slots;
- read-only presentation when the bundle is not writable.

Only loci in the active miSeq haplotype projection are shown. Aggregate miSeq
loci such as `MHC-DR`, `MHC-DQ`, and `MHC-DP` are preserved as their actual
analysis loci rather than being converted to full-length `DRB/DQA/DQB/DPA/DPB`
rows.

The editor shares the existing editor layout and combo-box controls but uses an
effective-call adapter rather than `ManualHaplotypeAssignment`. This is
necessary because haplotyped miSeq results already have pipeline calls and an
audited override model. The UI must not create a second source of truth.

## Save, Clear, and Synchronization Semantics

The editor is seeded from the controller-owned effective haplotype projection:
pipeline call plus any authoritative analyst override. Placeholder/error values
such as `-`, `ERR: TMG`, and `ERR: TMH` appear as empty editable fields.

One Save computes the changed sample/locus/slot values and submits them through
the existing atomic call-override mutation path:

- a changed nonempty value writes an analyst override;
- clearing an authoritative override restores its pipeline call;
- clearing an untouched pipeline value is a no-op and the pipeline value
  returns when the editor reloads;
- unchanged fields create no audit entry or workbook update;
- all changed fields save together or none save.

The existing author provider supplies the author. Each changed slot receives an
audit entry under the existing shared mutation operation, and the annotations
sidecar remains the durable source for analyst corrections. A successful Save
rebuilds the effective projection, refreshes Haplotype Calls and the matrix
band, refreshes the selected-column editor, marks `current.xlsx` dirty, and
notifies the Inspector. No scientific artifact is created without its existing
provenance/audit path.

## Error and Accessibility Behavior

If persistence fails, the editor retains the draft and shows the existing
retry/reload recovery controls. Switching selections with unsaved edits uses
the existing draft-transition guard rather than silently discarding work.

VoiceOver continues to announce sample, locus, slot, effective value, status,
source, and editability. Hover help continues to show the same information.
The compact visible string is not used as a replacement for those richer
descriptions.

## Performance

Compact rendering is derived from the already-built effective projection and
must not rebuild genotype rows. A successful edit invalidates only affected
sample columns and effective-call keys. Column selection builds one editor
snapshot in O(samples × included loci) using indexed projection lookups; typing
in a combo field does not rebuild the genotype matrix.

## Tests

Tests must cover:

- compact paired, partial, empty, too-many-genotype, and too-many-haplotype
  rendering;
- retained per-slot tooltip, hit target, keyboard, and accessibility behavior;
- compact auto-fit measurement;
- selected miSeq column mounting the assignment editor with dynamic loci;
- a multi-slot Save writing only call overrides, auditing the change, marking
  the workbook dirty, and synchronizing both views;
- clearing an override restoring the pipeline value;
- no-op Save behavior and read-only behavior;
- unchanged genotype-only full-length manual-assignment behavior.
