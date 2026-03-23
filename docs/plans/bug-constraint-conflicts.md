# Bug: Auto Layout Constraint Conflicts in TaxonomyTableView

## Status: Fixed

## Root Cause
TaxonomyTableView uses Auto Layout internally (NSSearchField, NSScrollView with
constraints) but is placed inside an NSSplitView container that uses
autoresizingMask (frame-based layout). When the NSSplitView first lays out,
the container starts at width=0 and height=0, which conflicts with the
internal constraints (8pt padding + search field + 8pt padding > 0).

## Fix Applied
1. **TaxonomyTableView.swift**: Lowered priority of padding/spacing constraints
   (searchTop, searchLeading, searchHeight, labelTrailing, scrollBottom) to
   `.defaultHigh` (750) so they yield to the required-priority autoresizing mask
   constraints at zero size. Once the container has real bounds, .defaultHigh
   is always satisfiable.

2. **ViewerViewController+AnnotationDrawer.swift**: Added early return in
   `openAnnotationDrawerIfBundleHasData()` when `taxonomyViewController != nil`,
   preventing the annotation drawer from being created while the taxonomy view
   is active.

## Also Fixed: BLAST Showing in Downloads Popover

BLAST operations were appearing in the Downloads toolbar popover because
`DownloadsPopoverView` displayed ALL `OperationCenter` items without filtering.

### Fix
1. **OperationType.isDownloadCategory**: New computed property classifying
   download/import types vs pipeline types (BLAST, classification, extraction).
2. **OperationCenter.downloadItems / activeDownloadCount**: Filtered accessors
   for the Downloads popover and toolbar badge.
3. **DownloadsPopoverView**: Now uses `center.downloadItems` instead of
   `center.items`. Pipeline operations only appear in the Operations Panel.
4. **Toolbar badge**: Uses `activeDownloadCount` so BLAST jobs don't
   trigger the filled-icon state.

## Also Fixed: BLAST "No sequences provided" Diagnostics

`BlastService.buildVerificationRequest` had no logging — failures were
invisible. Added comprehensive logging:
- File existence checks for classification output and source FASTQ
- Read ID scan counts (total classified, matching target taxIds)
- Sequence extraction counts (how many FASTQ reads matched)
- Explicit guard after sequence extraction (catches case where read IDs
  match but FASTQ file is missing/unreadable)
