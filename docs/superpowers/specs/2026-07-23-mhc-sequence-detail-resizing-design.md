# MHC Sequence Detail Resizing Design

## Goal

Make the full-length MHC sequence reader use the complete resized detail pane in both dimensions while preserving its existing GenBank, FASTA, and EMBL modes.

## Root cause

`GenotypeAlleleSequenceDetailView` configures its `NSTextView` with an unbounded text container and disables `widthTracksTextView`. It then calls `sizeToFit()` after every render. The text document therefore keeps a content-derived width instead of following the `NSScrollView` viewport when the containing split view is resized.

## Design

The sequence text view will track its enclosing scroll viewport width, wrap text at that width, and remain vertically resizable for its content. The scroll view remains constrained to all four available detail-view edges below the mode picker, so its viewport grows and shrinks with the detail pane height. Vertical scrolling remains enabled; horizontal scrolling remains available for any AppKit-required overflow but is not required to read ordinary formatted sequence records.

No sequence records, formatting, selected-row behavior, memory-management behavior, or controls change.

## Verification

An AppKit unit test will resize the detail view from a compact frame to a large frame, then assert that the text document width follows the scroll viewport and that the scroll viewport height follows the enlarged detail view. Existing format, selection, and hierarchy-reuse tests remain unchanged except for replacing the old fixed-width/horizontal-reachability expectation.
