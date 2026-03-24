# BLAST UI Fixes and Enhancements

## Status: In Progress

## Issues to Fix

### 1. Export button not working
The Export button in BLAST results drawer tab doesn't respond to clicks.

### 2. Multi-selection for right-click operations
Need contiguous (shift-click) and discontiguous (cmd-click) selection in the
BLAST results outline view. Copy operations should work on all selected items.

### 3. BLAST confidence heuristic is wrong
Current: 100% identity = "High" confidence. But this example shows all reads
hitting DIFFERENT organisms (fungi, not the classified taxon). The confidence
should reflect whether BLAST results SUPPORT the Kraken2 classification, not
just whether reads have high-identity hits.

Fix: Compare BLAST top hits to the queried taxon. If top hits are from
different organisms than what Kraken2 classified, confidence should be LOW.
Use green/yellow/red header bar. Show the searched taxon name prominently.

### 4. Grey out filtered taxa in sunburst
When the taxonomy table is filtered (search field), excluded taxa should be
visually dimmed/greyed in the sunburst chart.

### 5. 'Open in NCBI BLAST' button not working
The button exists but doesn't open the browser.

### 6. Copy classification commands from sidebar
Right-click classification result in sidebar → "Copy Command" should copy
the exact Kraken2/Bracken commands used to generate the results.
