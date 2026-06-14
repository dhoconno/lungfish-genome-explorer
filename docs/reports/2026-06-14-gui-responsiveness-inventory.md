# GUI Responsiveness Inventory and Review

Date: 2026-06-14
Scope: user interactions in the macOS GUI. Scientific tool runtime is out of
scope except where the GUI blocks before, after, or around a run.

## Review Method

Ten independent Swift performance review passes were completed. Each reviewer
worked from a different Swift/AppKit performance specialty and did not edit
files.

Completed specialties:

- AppKit shell, main menu, toolbar, split view, and command validation.
- Swift concurrency, task cancellation, and main actor load.
- Sidebar, `NSOutlineView`, filesystem watcher, and file operations.
- Large `NSTableView` and reusable table/list surfaces.
- SwiftUI/AppKit forms and text entry.
- Workflow builder, workflow operations, and operation center.

Second-wave specialties:

- Custom drawing, viewport refresh, zoom, scroll, and export rendering.
- Search/filter/menu-validation command paths.
- Filesystem, disk IO, caching, and network-volume GUI behavior.
- State architecture, invalidation, notifications, and view-model rebuilds.

## User Action Inventory

### Shell and Window Actions

- App menu, File/Edit/View/Sequence/Tools/Operations/Window/Help command routing
  and validation through `MainMenu`, `AppDelegate+MenuActions`, and
  `AppDelegate.validateMenuItem`.
- Project open, recent-project restore, multi-window session restore, close
  project, and project lock/write warnings.
- Toolbar actions for sidebar, inspector, drawers, operations, translation, and
  zoom.
- Operations panel open/close, cancel operation, clear completed operations, and
  expanded log viewing.

### Sidebar and Project Tree Actions

- Open project and initial sidebar scan.
- Watcher refresh, sidecar-only refresh, incremental subtree update, and
  `MustScanSubDirs` full reload.
- Select one item, multi-select items, open selected content, restore selection,
  and refresh selected content.
- Search/filter project tree and universal indexed search.
- Context menu construction, rename, new folder, move, copy, duplicate, delete,
  reveal in Finder, export, import, drag/drop, and batch folder workflow launch.

### Viewer and Result Actions

- Sequence/FASTA/FASTQ/BAM/reference-bundle viewport selection, scroll, zoom,
  track toggles, find/navigation, annotation drawer open, and graphics export.
- FASTQ preview, quality charts, metadata drawer, derivative operation dialog,
  and operation progress/cancel.
- Assembly contig selection/detail/copy/export.
- Classification result row selection, table filter/sort, column filters,
  sample filters, BLAST/NCBI links, extraction dialogs, and CSV/TSV exports.
- 12S, genotype, EsViritu, NVD, NAO-MGS, TaxTriage, phylogenetic tree, and
  alignment result display modes.

### Table, Filter, and Search Actions

- `BatchTableView` search text, sort descriptors, row selection, metadata column
  visibility, header filter menus, copy, and context menus.
- Annotation/variant/sample drawer filters, query-builder sheets, sample
  visibility toggles, and metadata import/export.
- Global/sidebar universal search, database browser search, quick filters, and
  provenance search.

### Form and Text-Entry Actions

- Workflow operations dialog fields: output name, advanced arguments, threads,
  length thresholds, reference/barcode/sample metadata pickers, and folder
  batch toggles.
- FASTQ/FASTA operation dialog fields and advanced arguments.
- Workflow builder node label/parameters/bundle input and operation configure
  bridge.
- Inspector annotation name/notes/color and sample/metadata editing.
- Settings tabs, AI provider fields, storage settings, rendering settings, and
  import/search forms.
- Genotype haplotype definition editor, threshold sections, manual override
  forms, and sample detail sheets.

## Consensus Risks

1. Full sidebar reloads are too coarse and run expensive filesystem/tree/width
   work on the main actor. Watcher `MustScanSubDirs` storms can queue repeated
   full reloads before the user sees a delete confirmation.
2. Typed filtering is too eager. Shared batch tables, sidebar search, and
   several custom result tables perform recursive filtering, sorting, expansion,
   and `reloadData()` per keystroke.
3. Large table and matrix surfaces rely on full reloads or non-virtualized
   stacks. This affects `BatchTableView`, genotype outline/matrix views,
   EsViritu outlines, TaxTriage tables, and metadata columns.
4. Many GUI actions perform synchronous disk IO on the main actor: project open,
   sidebar tree rebuilds, delete/copy/move/duplicate, project discovery, package
   validation, provenance/log export, and some result loading.
5. Coarse invalidation makes small changes expensive. `OperationCenter` publishes
   a whole array, operations panel reloads whole tables, workflow builder
   parameter edits rebuild broad graph presentation, and notification fanout can
   trigger repeated refreshes.
6. Several async GUI jobs start from `@MainActor` with `Task {}` and may run
   synchronous setup on the main actor before their first suspension. Expensive
   compute/IO should use immutable snapshots and detached/background workers,
   with generation-checked commits on `MainActor`.
7. Text-entry forms use broad observable state and computed readiness/validation,
   so typing can trigger whole-view recomputation and repeated parsing.
8. Viewport drawing is too entangled with data-fetch scheduling and broad
   invalidation. Sequence/BAM/annotation/genotype drawing can schedule async
   fetches from draw paths, and many navigation gestures invalidate full bounds.
9. Universal/sidebar search can trigger first-use full indexing from a
   keystroke. Annotation search is especially risky because annotation-tab
   filtering performs synchronous count/query work per text change, while the
   variant tab already uses a better debounced/off-main pattern.
10. Project open, bundle selection, MSA preview, recent-project filtering,
    context menus, provenance inspection, and delete planning contain
    synchronous filesystem probes that are most visible on network/cloud volumes.

## Fixes Implemented In This Pass

### Coalesce Watcher Full Reload Storms

`ProjectFilesystemRefreshCoordinator` now treats empty `ChangedPaths`
(`MustScanSubDirs`) as a debounced full-reload request. Consecutive empty
full-reload requests collapse into one trailing reload, and pending reloads are
cancelled when the watcher/subscription is removed. Mixed bursts that also
include concrete changed paths are still delivered conservatively so a
`MustScanSubDirs` signal is not dropped.

Regression test:
`ProjectFilesystemRefreshCoordinatorTests.testMustScanSubDirsChangesAreCoalescedIntoOneFullReload`

Expected UX win: network-volume or sibling-write FSEvents storms should no
longer queue repeated full sidebar rebuilds that block delete confirmation and
other interactions.

### Debounce Shared Batch Table Typing

`BatchTableView` now debounces user-typed free-text filtering by 180 ms, while
programmatic `setFilterText` remains immediate for state restoration and tests.

Regression tests:
`BatchTableViewTests.testUserSearchInputIsDebouncedBeforeFilteringRows`
`BatchTableViewTests.testProgrammaticFilterTextStillAppliesImmediately`

Expected UX win: table-heavy result views share less per-keystroke filtering,
sorting, full reload, and selection-restore work.

## Recommended Backlog

### Highest Impact

- Move sidebar tree building to an off-main snapshot builder, then apply
  generation-checked `NSOutlineView` diffs on the main actor.
- Add a sidebar refresh scheduler/transaction layer that coalesces manual reloads
  and watcher events for the same mutation.
- Make delete confirmation progressive: present quickly, calculate dependency
  impact in the background, then enable destructive buttons.
- Add debounced sidebar search with a small-query threshold for universal indexed
  search and avoid expanding every result for large matches.
- Change `OperationCenter`/operations panel updates from whole-array reloads to
  row-level updates, and cap/virtualize expanded log rendering.
- Move viewport data-fetch scheduling out of `draw(_:)` into a render
  coordinator keyed by viewport signature; fetch completion should invalidate
  only affected track/lane rects.
- Add an off-main project/sidebar filesystem index with stale cached sidebar
  display for slow or network volumes.

### Medium Impact

- Reuse metadata table cells in `MetadataColumnController`.
- Move annotation-tab filtering to the existing variant-tab pattern:
  debounce, generation guard, background DB count/query, main-thread commit.
- Convert genotype outline stacks to virtualized table/outline views before
  scaling cohort size.
- Split genotype display-state changes by cost class and cache support maps by
  denominator/filter keys.
- Add generation-token helpers for selection-triggered result loading,
  mini-BAM materialization, unique-read recompute, and other async view jobs.
- Move workflow operation project discovery, package validation, reference
  discovery, and barcode/haplotype scans to cancellable background caches.
- Commit annotation text/name changes on focus loss or debounce instead of every
  keystroke.
- Normalize active column-filter snapshots once, including lowercased text and
  parsed numeric thresholds, before scanning table rows.
- Batch or scope notification fanout so window-local updates require
  `windowStateScope` and hot-path filter changes do not redraw unrelated views.

### UX Alternatives For Expensive Actions

- Run delete, duplicate, move, copy, clear temp, and large exports as background
  operations with progress and one final sidebar diff.
- For large result tables, default to top-N or selected-sample subsets with an
  explicit “Show all” or “Apply filter”.
- For genotype matrices, render a sample window/subset by default instead of one
  column per sample for very large cohorts.
- For logs, show a tail view in the panel and offer “Open full log” rather than
  constructing one attributed string for every entry.
- For universal search, use a warm index and search the last completed index
  while an asynchronous rebuild runs; consider SQLite FTS5 or token tables
  instead of leading-wildcard `LIKE`.
- For MSA and large bundle previews, show manifest/row-count summaries first
  and lazy-load visible alignment windows.
- For slow/network volumes, show cached project state with a non-modal
  “refreshing” status instead of blocking the window on a full scan.

## Provenance Note

This pass did not add new scientific data creation/export behavior. One reviewer
flagged existing GUI CSV/TSV scientific exports that appear to bypass provenance;
that remains a blocking issue for future scientific-export work under the
project provenance requirements, but it was not changed in this responsiveness
pass.
