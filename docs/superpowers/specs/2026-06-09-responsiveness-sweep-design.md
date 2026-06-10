# Responsiveness Sweep — Design

Date: 2026-06-09
Branch: `perf/responsiveness-sweep`
Worktree: `.worktrees/perf-responsiveness-sweep` (based on local `main` @ `f93ec180`)

## Problem

The app is sometimes sluggish on common interactions: selecting a menu item,
selecting or deleting files in the left sidebar, and refreshing the Viewport.
The sluggishness is noticeable **even on small projects**, which points at fixed
per-action overhead (work done on every menu open / selection / refresh
regardless of data size) rather than data-volume scaling. Users notice this and
get frustrated, so the goal is to make the app feel snappy across the board.

## Goal & scope

Broad responsiveness sweep: make the app feel snappy. The three named hot paths
are the anchor cases, but the sweep is open to any other interaction that
profiling reveals as janky.

- **Anchor paths:** (1) menu-item selection/validation, (2) sidebar
  add/delete/select, (3) Viewport refresh/switch.
- **First target:** deleting items from the left sidebar.
- **In scope:** the anchor paths plus the shared kernel machinery they route
  through, plus anything profiling exposes as janky during the sweep.
- **Out of scope:** unrelated refactoring not tied to a measured bottleneck.

## Approach (chosen: profile-driven ranked backlog)

Measure → diagnose → fix → re-measure, run highest-impact-first, with natural
stop points.

1. **Instrument (one-time setup).** Add `os_signpost` intervals around the named
   actions so Instruments traces are self-labeling. Introduces exactly one piece
   of shared kernel infra: a small `PerfSignpost` helper in `LungfishKit`.
   Behavior-neutral and reversible.
2. **User captures.** The user runs the debug build, reproduces the actions that
   feel worst (and anything else janky), and provides Instruments `.trace`
   bundles and/or screen recordings. (Division of labor: user reproduces,
   assistant analyzes — chosen explicitly.)
3. **Assistant analyzes.** Per trace, produce a backlog entry:
   *symptom → measured cost (ms, main-thread %) → root cause (file:line) →
   proposed fix → expected win → regression risk*, ranked by user-perceived
   impact.
4. **Fix one at a time.** Each fix is its own small, separately-verified change.
   Tests run before moving on; SwiftPM invocations serialized (single
   `.build/.lock`); `--skip-update` to stay offline.
5. **User re-measures.** A fresh trace of the same signpost region confirms the
   stall is gone before the fix is considered done.

### Why this approach

Directly honors the "profile first" and "user reproduces, assistant analyzes"
decisions, matches the "fixed per-action overhead" signal (typically a handful
of specific culprits, not whole-subsystem rewrites), and provides natural
stopping points. Rejected alternatives: subsystem-by-subsystem rewrite (higher
regression risk, may rewrite code not on the critical path) and a full in-app
perf-HUD build-out (valuable long-term but delays the actual fixes; the cheap
part — `os_signpost` markers — is folded into step 1 instead).

## Binding project rules honored

- **Profile-first**, plan-first (this spec), expert/phased implementation.
- **OperationCenter** remains the path for any operation.
- **CLI parity** considered for anything not purely UI.
- **GUI testing via the real app** (user drives reproduction; assistant analyzes
  real traces — not a code audit).
- **Green-bar baseline:** a run is GREEN iff XCTest failures ⊆ the known 9
  environmental failures AND swift-testing failures = 0.
- **Background→MainActor** dispatch rules: any work moved off-main keeps model
  mutation and UI updates on `@MainActor` (no `Task { @MainActor in }` from GCD,
  no bare `DispatchQueue.main.async` touching `@MainActor` state).

## Shared instrumentation: `PerfSignpost`

A tiny helper added to `LungfishKit` (the kernel) so every target in the sweep
reuses it. Wraps `os.OSSignposter` / `os_signpost` interval begin/end with a
named log handle (subsystem `com.pathogenuity.lungfish`, category
`Responsiveness`). Provides `PointsOfInterest`-style intervals that appear as
named regions in Instruments. No behavior change; compiled in all builds but
effectively free when not being recorded.

## First target — sidebar deletion

### Action under study

Selecting one or more sidebar items and deleting them (context-menu
"Move to Trash" or the delete key):

`deleteSelectedItems()` → `presentDeleteConfirmation()` → `performDelete()` →
`removeItemFromSidebar()` + `reloadOutlineView()`
(`Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift`,
`SidebarViewController.swift`).

### Instrumentation for this target

Wrap the delete path in an `os_signpost` interval `Sidebar.Delete` with child
regions:

- `Delete.FilesystemTrash` — the `trashItem` loop (+ companion sidecars).
- `Delete.ModelMutation` — `findItem` / `findParent` / `removeItemFromSidebar`.
- `Delete.OutlineRefresh` — `reloadOutlineView()` incl. recommended-width
  recompute.
- A region around the `.sidebarItemsDeleted` notification fan-out.

### Hypotheses (to confirm/refute with the trace; ranked by suspected impact)

1. **Full `reloadData()` on delete.** `performDelete` ends with
   `reloadOutlineView()` → `outlineView.reloadData()`, a full teardown/rebuild,
   despite the file's own note that surgical `NSOutlineView` ops are preferred
   (`SidebarViewController.swift:986`). Likely the biggest visible stall.
2. **Full-tree label-width measurement.** `reloadOutlineView()` also calls
   `postPreferredSidebarWidthIfNeeded()` → `recommendedSidebarWidth()` →
   `maxLabelWidth(in: rootItems, …)`, which walks the **entire** tree computing
   per-item font metrics on every delete. Fixed overhead matching
   "small projects feel slow."
3. **Synchronous main-thread `trashItem`.** Per-file (+ sidecar) filesystem I/O
   on the main thread inside the loop (`…OutlineDataSource.swift:537`).
4. **Repeated recursive tree walks.** `findItem(byPath:)` / `findParent(of:)`
   are linear tree walks called multiple times per URL.
5. **Notification fan-out.** `.sidebarItemsDeleted` observers may each trigger
   their own refresh.

### Fix shape (only what the trace justifies)

Likely candidates, each landing as a separate verified change:

- Replace post-delete `reloadData()` with surgical row removal
  (`removeItems(at:inParent:)`).
- Cache or incrementally update the recommended sidebar width instead of
  remeasuring the whole tree on every mutation.
- Compute parent/index once before removal rather than re-walking the tree.
- If `trashItem` latency shows on the main thread, move the filesystem work
  off-main while keeping model mutation and outline updates on `@MainActor`.

### Verification

- Re-trace `Sidebar.Delete` after each fix; the region should shrink measurably
  and no main-thread hang should remain.
- Run the sidebar/outline test targets each time; preserve the green-bar
  baseline. Add a regression test if a fix changes the refresh contract.

### Out of scope for this first target

The add and selection paths, menu validation, and Viewport refresh are later
entries in the same backlog, worked through the same loop.

## Per-target loop (applies to every subsequent target)

For each new target after sidebar deletion:

1. Add/confirm `os_signpost` regions for the action.
2. User captures a trace; assistant adds a ranked backlog entry.
3. Fix highest-impact item; verify with tests + a fresh trace.
4. Repeat until the action feels snappy, then move to the next target.
