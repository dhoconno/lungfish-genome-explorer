# Shared miSeq Haplotype Curation Workbench

**Date:** 2026-08-04
**Status:** Approved for implementation

## Problem

The haplotyped miSeq Genotype Matrix can build an editable effective-haplotype
model, but its lower pane still displays the legacy cohort summary. The earlier
integration test called the controller's detail builder directly, so it did not
exercise the real sample-header selection and pane-visibility path. The result
is a hidden editor even after a sample column is selected.

The miSeq editor also duplicates the visual structure of the full-length
manual haplotype editor. That makes the two interfaces vulnerable to drifting
apart even though they represent the same analyst task.

## Selected Design

The Genotype Matrix lower pane is selection-driven for both full-length
genotype-only and haplotyped miSeq results:

- no selected sample column: the lower pane is empty;
- exactly one selected sample column: show the sample curation workbench;
- multiple selected sample columns: retain the compact multi-sample summary;
- row and cell selections: retain their existing allele/cell detail behavior.

The sample curation workbench uses one shared assignment-card implementation.
It owns the heading, completeness and unsaved state, Save action, responsive
two-slot locus rows, completion fields, clear controls, read-only state, and
retry/reload presentation. Thin workflow adapters supply values and actions:

- full-length genotype-only reads and writes manual haplotype assignments;
- haplotyped miSeq reads workflow calls plus analyst overrides and writes only
  audited call overrides.

The shared card accepts dynamic locus labels, so miSeq loci such as `MHC-DR`,
`MHC-DQ`, and `MHC-DP` are not translated into full-length locus names.
Workflow-specific actions remain conditional; this change does not invent a
new miSeq copy/import format.

## Persistence and Synchronization

For miSeq, workflow-assigned calls are the immutable baseline. A non-empty
analyst edit is saved through the existing atomic call-override operation.
Clearing an analyst override restores the workflow value. One Save covering
multiple slots produces one operation identity, updates the annotation audit,
marks `current.xlsx` dirty once, and refreshes both Haplotype Calls and the
Genotype Matrix. Manual-assignment records are never written for a haplotyped
miSeq result.

The full-length adapter retains its existing manual-assignment persistence and
Compare & Copy behavior. Both adapters retain the existing unsaved-change
navigation guard.

## Visibility and State Rules

The controller treats a raw genotype matrix that supports sample curation as a
detail-pane mode regardless of whether the result is genotype-only. It hides
the cohort summary and shows the detail scroll view for both supported
workflows. Entering this mode with no matrix selection clears stale content.

Selecting a column through the actual matrix header callback must mount the
workbench. Tests may not bypass that callback when asserting visible behavior.

## Accessibility and Performance

The shared card preserves the existing accessible labels, combo-box help,
keyboard Save action, focus restoration, text scaling, and responsive row
layout. It uses the already-built effective projection; typing changes only
the editor draft, and Save invalidates only affected effective-call keys and
sample columns.

## Regression Tests

Tests must prove:

- a haplotyped miSeq matrix starts with the cohort summary hidden and no lower
  pane content when no sample column is selected;
- selecting a column through the matrix's native target callback visibly
  mounts the workbench and effective editor;
- both workflow adapters render the shared assignment-card implementation;
- miSeq locus names and workflow baselines remain intact;
- Save and clear retain audited override semantics and synchronized views;
- full-length genotype-only selection, Compare & Copy, accessibility, and
  navigation guards remain unchanged.
