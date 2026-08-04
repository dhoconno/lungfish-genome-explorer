# miSeq Synchronized Haplotype and Genotype Views

**Date:** 2026-08-03  
**Status:** Approved for implementation and expert review

## Objective

For a completed **miSeq amplicon MHC genotyping** analysis that includes
haplotyping, make the haplotype-call presentation the default viewport and let
analysts switch to the same genotype matrix used for full-length MHC genotyping.
Both presentations must show the same effective haplotype calls and must remain
synchronized when an analyst edits or clears a haplotype override.

The miSeq viewport will expose only two primary presentations:

1. **Haplotype Calls**
2. **Genotype Matrix**

The existing **Review** and **Audit** viewport tabs will be removed for these
results. Review controls remain available in the selected-item detail pane and
Inspector. Audit records and scientific provenance remain durable and
inspectable through the bundle and Inspector; only the redundant viewport tab
is removed.

## Current State

Haplotyped miSeq bundles currently have two different matrix concepts:

- the normal haplotype-call outline/tape presentation;
- `GenotypeHaplotypeDefinitionMatrixView`, which presents diagnostic alleles
  from the selected haplotype definition set.

The full-length-style matrix is `GenotypeComparisonMatrixView`. It already
supports genotype rows by sample, matrix filtering, annotations, comments,
false-positive and false-negative review, row and column visibility, and a
disclosable haplotype band for genotype-only manual assignments. Haplotyped
miSeq results currently route Matrix mode to the diagnostic-definition matrix
instead of this comparison matrix.

Automated miSeq haplotype calls are stored in the result's
`GenotypeHaplotypeAnalysis`. Analyst corrections are stored as audited
overrides in `GenotypeAnnotationSidecar` through `GenotypeAnnotationStore`.
Genotype-only manual assignments use a separate
`ManualHaplotypeAssignment` record. Haplotyped miSeq results must not copy their
automated calls or overrides into the genotype-only manual-assignment format.

## Scope

### Included

- Haplotyped miSeq results default to **Haplotype Calls** when the bundle has no
  saved view preference.
- A two-choice viewport selector switches between **Haplotype Calls** and
  **Genotype Matrix**.
- **Genotype Matrix** uses `GenotypeComparisonMatrixView`, with the same rows,
  columns, filters, annotations, comments, accessibility behavior, and
  performance characteristics as the full-length MHC genotype matrix.
- The matrix haplotype band shows effective automated miSeq haplotype calls,
  including analyst overrides.
- Haplotype edits initiated from either presentation use the same audited
  override mutation path and refresh both presentations immediately.
- Clearing an override restores the pipeline-produced call in both
  presentations.
- The selected view is remembered per analysis bundle.
- Review and Audit are removed from the haplotyped miSeq viewport selector.
- Existing provenance and annotation audit records remain intact.

### Excluded

- Changing the miSeq workflow recipe, thresholds, reference selection,
  genotype calling, or haplotype calling.
- Changing how haplotype definition sets are imported, evaluated, or stored.
- Creating a new diagnostic-allele import/export format.
- Converting automated haplotype calls into manual haplotype assignments.
- Removing audit entries, provenance artifacts, or Inspector access to them.
- Changing non-miSeq haplotyping presentations as part of this feature.
- Changing genotype-only matrix behavior except where shared code must remain
  compatible.

## View Selection and Layout

### Applicability

The two-view presentation applies when all of the following are true:

- the result workflow kind is `miSeqAmpliconMHCGenotype`;
- the completed bundle contains a `GenotypeHaplotypeAnalysis`;
- the result is not being treated as genotype-only.

Genotype-only miSeq results continue to open directly in the genotype matrix.
Other workflow kinds retain their existing view rules.

### Selector

The miSeq haplotyped viewport replaces the current Summary/Review/Audit lens
control with one segmented selector:

- **Haplotype Calls**
- **Genotype Matrix**

There is no Review or Audit segment. The View Inspector reflects the same
selection and may provide the same two choices, but it must not create a second
independent state.

If no saved preference exists, **Haplotype Calls** is selected. An explicit
choice is saved in `GenotypeAnnotationSidecar.Settings` and restored when the
same bundle is reopened. Existing `outline` preferences map to Haplotype Calls;
existing `matrix` preferences map to the new full-length-style Genotype Matrix.

### Haplotype Calls

Haplotype Calls retains the existing miSeq haplotype outline/tape presentation,
sorting, cohort filtering, selection, effective call status, and detail
presentation. It no longer routes analysts through a separate Review lens.
Selecting a sample or locus exposes the existing call evidence and override
controls in the detail pane and Inspector.

### Genotype Matrix

Genotype Matrix renders `GenotypeComparisonMatrixView` from the bundle's raw
genotype calls and reviewable candidate rows. It must include the same useful
matrix capabilities as full-length MHC genotyping, including:

- read-support cells by sample;
- known, extension, novel, partial-extension, and other reviewable rows when
  present in the bundle;
- search and read-support filters;
- row and column selection and visibility commands;
- comments and false-positive/false-negative annotations;
- accessible text sizing and matrix keyboard/context-menu behavior;
- the disclosable haplotype band aligned to sample columns.

The diagnostic-definition matrix is no longer a viewport destination. Its
underlying definition data remains available to the haplotype evaluator and
call evidence UI.

## Shared Effective Haplotype Projection

Both views consume one controller-owned effective haplotype projection. For
each sample, locus, and H1/H2 slot, the projection resolves:

1. the pipeline-produced call from the active `GenotypeHaplotypeAnalysis`;
2. the latest valid analyst override from `GenotypeAnnotationSidecar`;
3. the resulting display status, including unresolved/error states;
4. whether the displayed value is automated or overridden.

The projection is the only source used to build both the haplotype outline and
the genotype matrix haplotype band. It is derived data and is not written as a
second scientific artifact.

`ManualHaplotypeAssignment` remains authoritative only for eligible
genotype-only analyses. Haplotyped miSeq calls and corrections continue to use
the established override records. This prevents two independently editable
representations of the same call.

## Editing and Synchronization

### From Haplotype Calls

Existing sample/locus override controls continue to call
`GenotypeAnnotationStore.applyOverride` and `clearOverride`. After a successful
mutation, the controller rebuilds the effective projection and refreshes both
the visible Haplotype Calls presentation and the matrix haplotype band.

### From Genotype Matrix

Selecting a sample column or a haplotype-band value exposes the same effective
haplotype editor in the detail pane. Saving or clearing from this presentation
uses the same override store methods, author identity, reason/rationale
requirements, and validation as Haplotype Calls. It does not call the
genotype-only manual-assignment APIs.

### Mutation result

A successful edit must:

- update the annotation sidecar atomically;
- append the existing audit entry with author, before/after values, locus,
  sample, slot, rationale, and timestamp;
- invalidate the effective haplotype projection;
- refresh both views without reopening the bundle;
- mark `current.xlsx` stale and schedule the existing workbook update behavior;
- notify the Inspector of the new annotation state.

A failed edit must leave both views on their prior shared projection and show a
plain-language error. Read-only bundles display calls but disable mutation.

## State and Compatibility

The controller retains one view-selection value. The viewport selector and
Inspector are two controls for that same value. Switching views does not alter
calls, filters, annotations, or workbook contents.

Existing bundles need no migration of scientific data. Existing view
preferences retain their raw values and receive the new presentation meaning.
Existing override and audit schemas remain authoritative. The implementation
may add neutral presentation models for the shared haplotype band, but it must
not rewrite prior annotations merely because a bundle is opened.

The implementation must preserve behavior for:

- miSeq genotype-only analyses;
- full-length ONT genotype-only analyses;
- full-length or other workflows whose viewport rules are outside this scope;
- read-only and older bundles with no saved view preference.

## Provenance and Traceability

Removing viewport tabs does not remove traceability. Every scientific workflow
continues to write its existing provenance. Every analyst haplotype mutation
continues to write annotation audit records and marks the workbook projection
stale. The selector itself is a view preference and is not a scientific call
mutation.

No new scientific-data creation or transformation is introduced by switching
views. If implementation changes any export or workbook projection, its output
must continue to include the exact workflow/tool version, resolved options,
inputs and outputs, checksums, sizes, exit status, wall time, and useful stderr
as required by Lungfish provenance policy.

## Performance and User Experience

- Opening the default Haplotype Calls view must not eagerly construct the full
  genotype matrix.
- The genotype matrix is configured lazily on first selection and then reused.
- Switching views must not rerun haplotype analysis or reload the workbook.
- Override refreshes update the shared projection and affected sample band
  content without rebuilding unrelated genotype rows.
- Matrix virtualization, column sizing, text-size preferences, and scroll
  position preservation remain active.
- The selector uses plain labels and exposes an accessibility role, value, and
  help text describing the two presentations.
- Empty or malformed haplotype analyses fall back safely to the genotype matrix
  while retaining an explanatory detail message; they do not expose blank
  Review or Audit tabs.

## Verification Requirements

Automated tests must prove:

1. haplotyped miSeq defaults to Haplotype Calls without a saved preference;
2. the viewport exposes exactly Haplotype Calls and Genotype Matrix;
3. Review and Audit are absent and cannot be selected through notifications or
   restored stale state;
4. switching to Genotype Matrix shows `GenotypeComparisonMatrixView` and not
   `GenotypeHaplotypeDefinitionMatrixView`;
5. raw genotype and candidate rows appear with expected read support;
6. the matrix haplotype band contains automated effective calls;
7. an override initiated from Haplotype Calls updates the matrix band;
8. an override initiated from Genotype Matrix updates Haplotype Calls;
9. clearing either override restores the pipeline call in both views;
10. edits write one audited override path, mark the workbook stale, and do not
    create manual-assignment duplicates;
11. saved view preference restores for the same bundle;
12. read-only bundles show synchronized values with disabled editing;
13. genotype-only and non-miSeq viewport behavior remains unchanged;
14. view switching and targeted override refresh meet existing matrix
    performance budgets;
15. the debug and release app bundles build and pass signature validation.

## Release Requirements

The release notes will describe the new default miSeq haplotype presentation,
the full-length-style genotype matrix option, synchronized editing, and removal
of Review/Audit viewport tabs in narrative form. The release must include all
verified pending fixes on the release branch, publish a signed and notarized DMG
and Sparkle appcast entry, and leave `main` clean with no stale feature
worktrees or branches.
