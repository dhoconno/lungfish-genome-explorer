# Sidebar Delete Sluggishness — Trace Diagnosis (2026-06-09)

## Summary

The reported sluggishness ("select a folder, press delete, wait 30+ seconds for the
confirmation dialog") is **not** in the delete code path. It is caused by a storm of
full sidebar rebuilds driven by the FSEvents `FileSystemWatcher`, all running
synchronously on the main thread. `performDelete` never even executes during the
stall — the main thread is saturated before the confirmation dialog can be shown.

## Evidence (live os_signpost capture)

Captured via `log stream --signpost --predicate 'subsystem == "com.lungfish.app"'`
against the instrumented debug build (PID 97337), while the user selected a folder and
pressed delete:

- **43 `Sidebar.OutlineRefresh` intervals** fired continuously at **1–2 per second for
  ~66 seconds** (20:48:53 → 20:49:59), each ~7 ms.
- **Zero `Sidebar.Delete` / `Delete.FilesystemTrash` / `Delete.ModelMutation`
  intervals** — `performDelete` did not run. The hang is entirely *before* the
  confirmation dialog.

A standalone probe confirmed the signpost machinery itself works (`OSSignposter` with
subsystem `com.lungfish.app` emits correctly), ruling out an instrumentation artifact.

## Root cause

1. `FileSystemWatcher` ([Services/FileSystemWatcher.swift](../../Sources/LungfishApp/Services/FileSystemWatcher.swift))
   monitors the open project directory via FSEvents, dispatching its callback on
   `DispatchQueue.main` (line 114).
2. On a **network/external volume** (`/Volumes/iWES_WNPRC`), FSEvents frequently sets
   `kFSEventStreamEventFlagMustScanSubDirs` rather than delivering granular paths.
3. The watcher delivers `MustScanSubDirs` as an empty `ChangedPaths`
   (FileSystemWatcher.swift:213-216), which the sidebar consumer
   ([SidebarViewController.swift:707-709](../../Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift#L707))
   turns into a **full `reloadFromFilesystem()`**.
4. `reloadFromFilesystem()` ([SidebarViewController.swift:791](../../Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift#L791))
   is heavyweight and entirely main-thread: full recursive `buildRootItems(from:)`
   filesystem scan (slow over a network mount) + full `outlineView.reloadData()` +
   full-tree label-width measurement (`recommendedSidebarWidth`/`maxLabelWidth`) +
   save/restore expansion + save/restore selection + `scheduleUniversalSearchRebuild()`.
5. Because each rescan is slow on the network volume and `MustScanSubDirs` keeps
   arriving, full reloads pile up faster than they drain. The FSEvents 3-second
   coalescing latency and the sidecar filter are both **bypassed** on the
   `MustScanSubDirs` path, so neither throttles the storm.

### Contributing trigger

A separate `lungfish-cli` ONT genotyping job (running in another worktree, 14 threads)
is writing ~100 output files into a sibling project under the same parent
(`/Volumes/iWES_WNPRC/32328/`). The open project is `32328_v2.lungfish`; the job writes
to `32328_v3.lungfish`. The watcher watches only the `v2` folder path, but on a network
volume FSEvents reports changes coarsely (volume/parent granularity, `MustScanSubDirs`),
so the sibling writes plausibly bleed through as forced full rescans.

## Why this supersedes the original Phase 1 plan

The original plan (Tasks 3–6: surgical outline removal, width memoization, single-pass
deletion lookup, off-main trash) all targeted `performDelete`. The trace proves the
stall is upstream of `performDelete` entirely. Those tasks remain reasonable
*incremental* improvements but would **not** fix the reported sluggishness. The fix must
target the FSEvents → full-reload path.

## Candidate fixes (ranked)

1. **Debounce/coalesce full reloads + drop redundant `MustScanSubDirs` storms.**
   Collapse bursts of `MustScanSubDirs` into a single trailing-edge reload (e.g. a
   250–500 ms debounce timer), so N events in a window cause 1 rebuild, not N. Highest
   impact, lowest risk, fixes the storm regardless of trigger.
2. **Move the filesystem scan off the main thread.** `buildRootItems(from:)` (the
   network-volume directory walk) should run off-main; only the model swap + outline
   update return to `@MainActor`. Removes the main-thread block even when a reload does
   run. Pairs with the existing width-memoization idea (recompute width off the hot path).
3. **Make `MustScanSubDirs` do an incremental diff instead of a full rebuild.** Reuse
   the existing `applySubtreeDiff` machinery so even a forced rescan applies surgical row
   updates rather than `reloadData()` + full re-measure.
4. **Throttle/relax watching on network volumes.** Detect non-local volumes and either
   increase FSEvents latency substantially or fall back to a slower poll, since granular
   FSEvents are unreliable there anyway.

## Open question for the user

Whether to scope the fix to (a) the network-volume storm specifically, or (b) make the
watcher→reload path robust in general (debounce + off-main + incremental) so any rapid
filesystem churn — local or network, self-inflicted or external — stays smooth. The
broad-sweep goal argues for (b).
