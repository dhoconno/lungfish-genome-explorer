# FASTA Selection Detail Design

**Date:** 2026-08-05  
**Scope:** Shared multi-sequence FASTA viewport used by standalone Savont clustering results and ordinary FASTA files

## Goal

Present standalone Savont cluster output as an ordinary, useful FASTA collection. The sequence table remains the primary overview, while a resizable bottom pane shows the complete FASTA record or records selected by the user. The small per-row Mini Map column is removed because it does not help users inspect consensus clusters.

This is a presentation change only. It does not change Savont execution, cluster sequences, support counts, output files, or provenance.

## Shared FASTA viewport

The existing `FASTACollectionViewController` remains the single multi-sequence FASTA browser. Lungfish will not add a Savont-specific result controller or a separate routing path. Consequently, standalone Savont output and other multi-record FASTA files receive the same interaction model.

The collection table retains these columns:

- Name
- Source, when multiple input documents are displayed
- Length
- Description
- Annotations
- GC%

The Mini Map column is removed. Search, sorting, multiple selection, contextual actions, double-click navigation, and the existing Open in Browser behavior remain available.

## Selection detail pane

The table and FASTA text area form a vertical split view with a user-adjustable divider.

- With no selected rows, the detail pane is collapsed so the table receives all available space.
- With one selected row, the detail pane expands and displays that complete FASTA record.
- With multiple selected rows, the pane displays every selected record in current table order, separated by one blank line.
- Selection changes update the text immediately without reparsing or rereading the source file.
- Filtering or sorting changes the visible table order; the detail pane follows that visible order for selected records.

The pane is read-only, monospaced, vertically and horizontally scrollable, selectable, and compatible with the normal Copy command. The FASTA text includes the sequence name and description in the header and wraps nucleotide lines at 80 characters. An empty description does not add trailing header whitespace.

The divider position is retained for the lifetime of the controller. Clearing the selection collapses the pane; selecting another row restores the previous nonzero pane height. The initial expanded height should expose several wrapped sequence lines without taking more than roughly one third of the viewport.

## Data and performance

The controller already owns the parsed `Sequence` values. Detail rendering uses those in-memory values and does not load files, compute alignments, or invoke command-line tools. FASTA text is generated only when selection changes. For multiple selections, records are emitted in one pass and assigned to the text view once.

The output sequence and support count remain unchanged. Savont's `_ReadCount-<N>` header field therefore remains visible in the Name column and FASTA header.

## Accessibility and interaction

The detail text uses the app's established content text-size preference and a monospaced system font. The split view and text view expose descriptive accessibility labels, and selected sequence text remains available to assistive technologies.

The existing table context menu continues to operate on the selected rows. Copy from the detail text copies the user's text selection; the existing Copy as FASTA table action continues to copy complete selected records.

## Error and empty states

An empty FASTA continues to display the existing empty-state message. A nonempty FASTA with no selection shows only the table. If a sequence has an empty body, its header is still displayed in the detail pane. The viewer does not invent sequence content or support values.

## Verification

Automated coverage will verify:

- the shared FASTA table no longer contains the Mini Map column;
- no selection keeps the detail pane collapsed;
- one selected row shows the exact FASTA header and wrapped sequence;
- multiple selected rows appear in visible table order with one blank line between records;
- descriptions are preserved without adding whitespace to description-free headers;
- filtering and sorting update selection detail consistently;
- clearing and restoring selection preserves the last expanded pane height;
- existing FASTA actions and Open in Browser callbacks continue to work.

Manual verification will open a standalone Savont cluster FASTA, select one and several clusters, resize the divider, copy sequence text, and confirm that double-click navigation still works.

## Acceptance criteria

1. Standalone Savont cluster output opens in the shared multi-FASTA browser.
2. The Mini Map column is absent.
3. Selected rows reveal complete, correctly formatted FASTA records in a resizable bottom pane.
4. Multiple selections are displayed in current table order.
5. No selection gives the table all available vertical space.
6. Existing FASTA search, sort, contextual actions, and browser navigation continue to work.
7. Savont output data and canonical provenance remain unchanged.
