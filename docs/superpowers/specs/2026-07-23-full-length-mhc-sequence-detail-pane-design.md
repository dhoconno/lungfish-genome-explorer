# Full-Length MHC Sequence Detail Pane Design

**Date:** 2026-07-23

## Scope

This change applies only to the full-length ONT MHC genotyping result viewport. It replaces the current graphical and facts-heavy allele detail content with a lightweight, read-only sequence record viewer. It does not change genotyping, candidate classification, artifacts, workbooks, other result surfaces, or the broader Lungfish application.

## Selection Behavior

- With no selected allele rows, the detail pane is completely empty. It does not show an instructional caption or placeholder.
- Column-only and cell-only selections do not select allele rows and therefore leave the detail pane empty.
- With one or more selected allele rows, the pane shows the corresponding allele records.
- Multiple records are ordered exactly as their selected rows appear from top to bottom in the viewport, regardless of the order in which the user selected them.
- Changing the row selection replaces the displayed records. Missing data must never leave stale content from a previous selection.

## Formats

The pane contains a segmented format control with these options:

1. GenBank
2. FASTA
3. EMBL

GenBank is the default when a result bundle is opened. A user-selected format remains active while the user changes row selections within that open result.

The content is displayed in a monospaced, selectable, read-only text view:

- GenBank records retain their annotations and use the normal `//` record terminator.
- FASTA displays one record per selected allele.
- EMBL contains the same sequence and annotations as the corresponding GenBank records and uses the normal `//` record terminator.

## Record Sources

- A known allele row resolves to the exact validated reference-library record represented by that genotype row.
- A novel or extension row resolves to its exact validated generated candidate record.
- Candidate FASTA and EMBL output use the same canonical, UTR-trimmed candidate sequence published in the outward-facing candidate artifacts.
- Distinct rows remain distinct records even when they have the same display name.

The viewer consumes the validated record data already loaded for the result bundle. Selecting rows must not parse BAM files, rescan result directories, rebuild graphical tracks, or perform unbounded work.

## Unavailable Records

If a selected row cannot resolve to a validated record, the viewer displays a compact unavailable entry for that row in the selected format. Other resolvable selected records remain visible. The unavailable entry identifies the row without inventing sequence or annotation data.

## UI Structure

The detail pane has only:

- the `GenBank | FASTA | EMBL` format control; and
- the record text view.

It does not show the former overview graphics, facts rail, evidence summaries, or navigation buttons on this workflow surface.

## Performance and Lifecycle

- Formatting is deterministic and bounded by the selected record set.
- Repeated selection and format changes reuse the same view hierarchy.
- Selection changes replace text rather than accumulating child views, constraints, caches, observers, or asynchronous tasks.
- No row selection clears both the current record set and rendered text.

## Testing

Automated tests will verify:

- an empty detail pane when no allele row is selected;
- column-only and cell-only selection remaining empty;
- GenBank as the initial format;
- exact GenBank, FASTA, and EMBL rendering;
- known, novel, and extension record resolution;
- mixed known/candidate multi-selection in viewport order;
- distinct records for rows with identical display names;
- format persistence across row selection changes;
- replacement rather than retention of stale unavailable content;
- bounded view hierarchy and formatting behavior across repeated selections.

The focused viewport and result-bundle test suites must pass before a new `Lungfish Debug` build is launched.
