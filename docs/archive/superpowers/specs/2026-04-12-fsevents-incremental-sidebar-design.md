# FSEvents-Based FileSystemWatcher with Incremental Sidebar Updates

**Date**: 2026-04-12  
**Status**: Design  
**Problem**: Excessive sidecar metadata reloading — the 1-second polling `FileSystemWatcher` creates a feedback loop where app-internal sidecar writes trigger full sidebar rebuilds, which re-read all sidecar files, logging each one.

## Problem Analysis

The current `FileSystemWatcher` polls the entire project directory tree every 1.0 second by recursively enumerating all files and comparing modification dates. When *any* file changes — including `.lungfish-meta.json` sidecar files that the app itself writes — it triggers:

1. Full `reloadFromFilesystem()` → rebuilds entire `SidebarItem` tree
2. Loads `derived.manifest.json`, `read-manifest.json`, `batch-operations.json` for every FASTQ bundle
3. `scheduleUniversalSearchRebuild()` → full SQLite index rebuild of all project artifacts
4. Search rebuild reads all `.lungfish-meta.json` files, logging each one
5. Any metadata writes from the above trigger the next poll cycle → feedback loop

Result: hundreds of "Loaded FASTQ metadata from SRR*.fastq.gz.lungfish-meta.json" log entries per minute during normal use.

## Design

### 1. Replace Polling with FSEvents

Replace the `Timer` + `DirectorySnapshot` polling approach with macOS `FSEventStreamCreate`.

**Configuration:**
- `kFSEventStreamCreateFlagFileEvents` — per-file event granularity (not just directory-level)
- `kFSEventStreamCreateFlagUseCFTypes` — CF-compatible path delivery
- `kFSEventStreamCreateFlagNoDefer` — not set; we want coalescing
- **Latency: 3.0 seconds** — FSEvents coalesces all events within this window before delivering a single batch. This provides natural debouncing and matches the user's acceptable latency of 3–5 seconds.
- **Schedule on `CFRunLoopGetMain()`** with `kCFRunLoopDefaultMode`

**Callback signature change:**
```swift
// Old
private let onChange: @MainActor () -> Void

// New
private let onChange: @MainActor (_ changedPaths: [URL]) -> Void
```

The watcher passes through the list of changed file/directory URLs so the sidebar can scope its updates.

**Main-thread dispatch** (same pattern as current code):
```swift
DispatchQueue.main.async {
    MainActor.assumeIsolated {
        self.onChange(filteredPaths)
    }
}
```

**Fallback:** If `FSEventStreamCreate` returns `nil` (should not happen on macOS but defensive), log an error and fall back to the current polling approach at a 5-second interval.

### 2. Sidecar Exclusion Filter

Before invoking the `onChange` callback, the watcher filters out events caused by internal sidecar files. If *all* changed paths in an FSEvents batch are sidecar files, the callback is suppressed entirely.

**Sidecar patterns (excluded from triggering sidebar refresh):**
- `*.lungfish-meta.json` — FASTQ metadata sidecars
- `*.json` files inside `.lungfishfastq` or `.lungfishref` bundle directories (manifests, configs)
- `.universal-search.db`, `.universal-search.db-wal`, `.universal-search.db-shm` — search index
- Files matching `FASTQBundleCSVMetadata.filename`

**Implementation:** A static method `FileSystemWatcher.isSidecarPath(_:)` that checks the filename and parent path. This is called per-path in the FSEvents callback before assembling the filtered list.

**Important nuance:** Sidecar changes are filtered from *sidebar refresh triggers* but are NOT filtered from *search index updates* (Section 4). A `.lungfish-meta.json` change means read counts may have updated, which the search index should reflect — but that's a targeted upsert, not a full sidebar rebuild.

### 3. Incremental Sidebar Updates

**New method: `updateSidebar(changedPaths: [URL])`**

This replaces the current pattern where FSEvents → `reloadFromFilesystem()`.

**Algorithm:**

1. **Map paths to project subtrees:** Group changed paths by their top-level directory relative to the project root (e.g., `Downloads/`, `Reference Sequences/`, a specific `.lungfishfastq` bundle)

2. **Per affected subtree:**
   - Re-scan that directory using `FileManager.contentsOfDirectory`
   - Rebuild `SidebarItem` nodes for items in that directory using `buildSidebarTree(from:isRoot:false)`
   - This scopes manifest/metadata reads: only bundles in the affected subtree have their `derived.manifest.json`, `read-manifest.json`, etc. re-read

3. **Diff old vs new children (by URL):**
   - **Insertions**: New URLs not in the old children → `outlineView.insertItems(at:inParent:)`
   - **Deletions**: Old URLs not in the new children → `outlineView.removeItems(at:inParent:)`
   - **Updates**: URLs present in both but with different subtitles or children → `outlineView.reloadItem(_:reloadChildren:)`
   - Order changes are handled by removing and re-inserting at the correct index

4. **Selection/expansion preservation:** Because unchanged items retain their object identity, `NSOutlineView` preserves selection and expansion state naturally. No explicit save/restore needed.

5. **Short-circuit:** If all changed paths were filtered by the sidecar exclusion (Section 2), `updateSidebar` returns immediately without touching the outline view.

**`reloadFromFilesystem()` remains** for:
- Initial project open
- Direct calls after explicit file operations (move, copy, rename, delete, create folder) — these 7+ call sites provide instant feedback and don't go through FSEvents
- `kFSEventStreamEventFlagMustScanSubDirs` fallback (see Section 5)
- Manual refresh if ever added

### 4. Incremental Universal Search Index

**New method: `ProjectUniversalSearchIndex.update(changedPaths: [URL])`**

Replaces the full `rebuild()` call on every sidebar refresh.

**Algorithm:**

1. **Classify each changed path:**
   - Deleted path → delete its rows from the SQLite index (`DELETE WHERE path = ?`)
   - New or modified `.lungfishfastq` bundle → re-parse that bundle's metadata and upsert index entries
   - New or modified `.lungfishref` bundle → re-parse and upsert
   - New or modified classification/analysis result directory → re-parse and upsert
   - Modified `.lungfish-meta.json` → find the parent FASTQ bundle and upsert its read count / base count entries
   - Other file types → upsert if they match indexed formats (BAM, VCF, BED, etc.)

2. **Batch upserts** within a single SQLite transaction for efficiency.

3. **Full rebuild** remains at project open only (`scheduleUniversalSearchRebuild(immediate: true)`).

**Sidebar integration:** The sidebar's `updateSidebar(changedPaths:)` also calls `universalSearchService.update(changedPaths:)` with the *unfiltered* path list (including sidecar files), because the search index needs to reflect metadata changes even though the sidebar tree doesn't need to rebuild for them.

### 5. Error Handling & Edge Cases

**FSEvents flags:**
- `kFSEventStreamEventFlagRootChanged`: Watched directory renamed/deleted → stop watching, clear sidebar
- `kFSEventStreamEventFlagMustScanSubDirs`: Kernel coalesced too many events → fall back to full `reloadFromFilesystem()` for this one occurrence. Log a warning. This is rare and only happens under extreme I/O pressure.
- `kFSEventStreamEventFlagUnmount`: Volume unmounted → stop watching cleanly

**Race with app's own writes:** When the app writes a sidecar (e.g., `FASTQMetadataStore.save()`), FSEvents fires ~3 seconds later. The sidecar filter suppresses the sidebar refresh callback. The search index receives the update via the unfiltered path for targeted re-indexing. No feedback loop.

**Direct `reloadFromFilesystem()` calls:** The 7+ call sites that invoke `reloadFromFilesystem()` directly after file operations (move, copy, rename, delete, create folder, import, export) continue unchanged. They provide instant feedback for user-initiated operations. FSEvents handles external changes and long-running pipeline outputs.

**Testing:** `FileSystemWatcher` gains an internal test-mode initializer that accepts a mock event delivery closure, so sidecar filtering, path mapping, and incremental update logic can be unit-tested without real FSEvents.

## Files Changed

| File | Change |
|------|--------|
| `Sources/LungfishApp/Services/FileSystemWatcher.swift` | Replace Timer/snapshot with FSEventStream, add sidecar filter, pass changed paths |
| `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` | Add `updateSidebar(changedPaths:)`, update FSEvents callback, keep `reloadFromFilesystem()` |
| `Sources/LungfishApp/Services/UniversalProjectSearchService.swift` | Add `update(changedPaths:)` method |
| `Sources/LungfishCore/Search/ProjectUniversalSearchIndex.swift` | Add `update(changedPaths:)` with targeted upsert/delete |
| `Tests/LungfishAppTests/FileSystemWatcherTests.swift` | New: sidecar filter tests, path mapping tests |
| `Tests/LungfishAppTests/SidebarIncrementalUpdateTests.swift` | New: incremental diff tests |

## Non-Goals

- Replacing FSEvents with `DispatchSource.makeFileSystemObjectSource` (per-file descriptor, doesn't scale to recursive directories)
- Implementing file-level change diffing for content (we only care about existence and modification date, same as current)
- Real-time (<1 second) detection of external changes
- Changing the direct `reloadFromFilesystem()` calls after explicit user operations
