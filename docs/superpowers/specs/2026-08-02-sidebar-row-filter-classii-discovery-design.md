# Stable Sidebar, Row-Supported Columns, and Partial Class II Discovery

Date: 2026-08-02

Status: Approved by the user's instruction to proceed without further review

## Summary

This change addresses three independent defects without changing the underlying
full-length ONT genotyping recipe:

1. Filesystem refreshes preserve the user's location in the project sidebar.
2. A selected allele row can restrict the matrix to samples with more than zero
   reads for that exact row.
3. High-support class II clusters that are scientifically interpretable as
   novel or extension observations remain visible in the genotype matrix even
   when a partial amplicon prevents publication as a reference-ready allele.

## Sidebar Refresh Behavior

`NSOutlineView.reloadData()` currently rebuilds rows and resets the scroll view
to the top. The controller restores expansion and selection but not the visible
location. Before a full reload, Lungfish will capture:

- the URL of the top visible row;
- that row's offset from the top of the clip view; and
- the raw scroll origin as a fallback.

After rebuilding and restoring expansion and selection, Lungfish will resolve
the saved URL in the new tree and restore the same row and offset. If that item
was deleted, it will restore the nearest valid raw position. Explicit navigation
commands continue to scroll their selected item into view; background filesystem
refreshes do not.

## Show Columns With Calls in a Selected Row

The row contextual menu will include **Show Only Columns with Calls in This
Row** when exactly one allele row is selected. A call is present when the row's
raw `passedUniqueReads` value is greater than zero; this command does not use the
current Min Reads or Min Percent display threshold.

The command replaces only the manual sample-column visibility include set. It
preserves row visibility, search, sort, annotations, and selected scientific
data. It uses the existing matrix visibility machinery, so **Show All Rows and
Columns** restores the full matrix and accessibility announcements describe the
change. Right-click and Control-click use the contextual menu. Command-click
retains the standard macOS multi-selection behavior rather than being
overloaded with a destructive filtering action.

If a selected row has no supporting samples, the menu item is disabled with a
plain-language explanation. Multiple selected rows do not imply union or
intersection semantics; the command is offered only for one row.

## Partial Class II Candidate Discovery

### Evidence and Root Cause

In the reproduced DRB analysis, CN29 has one exact known call with 234 reads and
two unmatched clusters with 267 and 194 reads. Both unmatched clusters pass the
reciprocal alignment identity and coverage thresholds and are initially
classified as novel. They are subsequently demoted to
`incomplete-reference-span` because the ~4 kb amplicon begins around exon 2 and
does not cover the full reference CDS.

That demotion is correct for allele publication: a partial amplicon must not be
written to the public candidate FASTA or presented as a complete,
reference-ready allele. The defect is that the useful provisional biological
interpretation is discarded with the publication decision, causing the matrix
to omit substantial class II genotype evidence.

### Data Model

An un-nameable record may carry an optional **provisional candidate
interpretation** when all of the following are true:

- the classifier produced a novel or extension candidate;
- canonicalization demoted it only because the observed amplicon has an
  incomplete reference span; and
- the existing identity, aligned-bases, and shorter-sequence coverage checks
  passed.

The interpretation records the provisional name, locus, novel/extension class,
closest reference, difference counts, alignment metrics, and explicit
`incomplete-reference-span` readiness. It does not acquire an external FASTA
identity or become importable as a reference allele. Older result bundles
decode without this optional field.

### Matrix and Workbook Projection

The viewport and Unified Genotype Pivot include these records as reviewable
partial candidates. They retain the same per-sample read counts and stable raw
cluster identity as the evidence bundle. Their note/detail text explicitly says
that the sequence is a provisional partial-amplicon interpretation and is not
reference-ready. Candidate color follows novel/extension and singleton/shared
status so the evidence is visible alongside complete candidate calls.

The public candidate FASTA, candidate GenBank, and reference-promotion boundary
remain reference-ready-only. The raw consensus stays in the internal evidence
FASTA, the un-nameable JSON, and the BAM/BAI evidence links.

## Provenance

The existing scientific workflow provenance will be extended to record:

- the count of incomplete candidates retained for review;
- the exact eligibility rule;
- the fact that they are excluded from reference-ready sequence exports; and
- the candidate/un-nameable schema and projection behavior.

All existing argv, resolved defaults, runtime identity, inputs/outputs,
checksums, file sizes, exit status, wall time, and useful stderr remain present
as required by `AGENTS.md`.

## Tests and Validation

- A hosted AppKit test scrolls into a long sidebar, triggers a full filesystem
  reload, and verifies that the same URL remains at the same visible offset.
- Matrix menu tests verify label, availability, exact >0-read sample selection,
  preservation of other visibility state, and restoration through Show All.
- Artifact/model tests verify backward-compatible decoding and that only
  incomplete-reference-span demotions retain provisional interpretation.
- Projection tests verify that partial candidates appear in Unified with their
  read counts but remain absent from reference-ready candidate FASTA/GenBank.
- A real CN29 run verifies that the known call remains and both high-support
  partial novel clusters are reviewable, with complete provenance and no
  relaxation of zero-SNP known-call rules.

