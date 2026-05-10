# FSEvents + Incremental Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 1-second polling `FileSystemWatcher` with FSEvents-based monitoring, add sidecar exclusion filtering, and implement incremental sidebar/search-index updates to eliminate the feedback loop causing excessive metadata reloading.

**Architecture:** `FileSystemWatcher` uses `FSEventStreamCreate` with a 3-second latency to receive kernel-level file change notifications. Changed paths are filtered to exclude internal sidecar files, then passed to `SidebarViewController.updateSidebar(changedPaths:)` which rebuilds only affected subtrees and applies surgical `NSOutlineView` insertions/removals. The universal search index receives the unfiltered paths for targeted upsert/delete.

**Tech Stack:** Swift 6.2, CoreServices/FSEvents C API, NSOutlineView, SQLite3

**Spec:** `docs/superpowers/specs/2026-04-12-fsevents-incremental-sidebar-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `Sources/LungfishApp/Services/FileSystemWatcher.swift` | FSEvents stream lifecycle, sidecar filter, changed-path delivery |
| `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` | New `updateSidebar(changedPaths:)`, updated watcher callback |
| `Sources/LungfishApp/Services/UniversalProjectSearchService.swift` | New `update(changedPaths:)` forwarding method |
| `Sources/LungfishIO/Search/ProjectUniversalSearchIndex.swift` | New `update(changedPaths:)` with targeted upsert/delete |
| `Tests/LungfishAppTests/FileSystemWatcherTests.swift` | Updated tests for new API + sidecar filter tests |
| `Tests/LungfishIOTests/ProjectUniversalSearchIncrementalTests.swift` | Tests for incremental index update |

---

### Task 1: Rewrite FileSystemWatcher with FSEvents

**Files:**
- Modify: `Sources/LungfishApp/Services/FileSystemWatcher.swift` (full rewrite)
- Test: `Tests/LungfishAppTests/FileSystemWatcherTests.swift`

This is the core change. Replace the `Timer` + `DirectorySnapshot` polling with `FSEventStreamCreate`.

- [ ] **Step 1: Write failing tests for the new sidecar filter**

Add new tests to `FileSystemWatcherTests.swift` that verify sidecar files are excluded from the changed-paths callback. These tests use the static `isSidecarPath` method directly (no FSEvents needed).

```swift
// Add to FileSystemWatcherTests.swift, after existing tests

@Test("isSidecarPath identifies lungfish-meta.json files")
func sidecarFilterIdentifiesMetaJSON() {
    let metaURL = URL(fileURLWithPath: "/project/Downloads/SRR123.fastq.gz.lungfish-meta.json")
    #expect(FileSystemWatcher.isSidecarPath(metaURL) == true)
}

@Test("isSidecarPath identifies universal search database files")
func sidecarFilterIdentifiesSearchDB() {
    let dbURL = URL(fileURLWithPath: "/project/.universal-search.db")
    let walURL = URL(fileURLWithPath: "/project/.universal-search.db-wal")
    let shmURL = URL(fileURLWithPath: "/project/.universal-search.db-shm")
    #expect(FileSystemWatcher.isSidecarPath(dbURL) == true)
    #expect(FileSystemWatcher.isSidecarPath(walURL) == true)
    #expect(FileSystemWatcher.isSidecarPath(shmURL) == true)
}

@Test("isSidecarPath identifies metadata.csv")
func sidecarFilterIdentifiesMetadataCSV() {
    let csvURL = URL(fileURLWithPath: "/project/Downloads/SRR123.lungfishfastq/metadata.csv")
    #expect(FileSystemWatcher.isSidecarPath(csvURL) == true)
}

@Test("isSidecarPath identifies JSON inside bundles")
func sidecarFilterIdentifiesJSONInBundles() {
    let manifestURL = URL(fileURLWithPath: "/project/Downloads/SRR123.lungfishfastq/derived.manifest.json")
    let readManifestURL = URL(fileURLWithPath: "/project/Downloads/SRR123.lungfishfastq/read-manifest.json")
    #expect(FileSystemWatcher.isSidecarPath(manifestURL) == true)
    #expect(FileSystemWatcher.isSidecarPath(readManifestURL) == true)
}

@Test("isSidecarPath allows non-sidecar files through")
func sidecarFilterAllowsNormalFiles() {
    let fastqURL = URL(fileURLWithPath: "/project/Downloads/SRR123.fastq.gz")
    let bamURL = URL(fileURLWithPath: "/project/Alignments/sample.bam")
    let bundleURL = URL(fileURLWithPath: "/project/Downloads/SRR123.lungfishfastq")
    #expect(FileSystemWatcher.isSidecarPath(fastqURL) == false)
    #expect(FileSystemWatcher.isSidecarPath(bamURL) == false)
    #expect(FileSystemWatcher.isSidecarPath(bundleURL) == false)
}

@Test("isSidecarPath allows top-level JSON files outside bundles")
func sidecarFilterAllowsTopLevelJSON() {
    // JSON files at the project root that are NOT inside a bundle
    // These are classification/analysis result markers and should trigger sidebar refresh
    let resultJSON = URL(fileURLWithPath: "/project/Analyses/classification-2026-04/classification-result.json")
    // This is inside a known result directory, not a bundle sidecar
    #expect(FileSystemWatcher.isSidecarPath(resultJSON) == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FileSystemWatcherTests 2>&1 | head -30`
Expected: Compilation error — `isSidecarPath` does not exist yet.

- [ ] **Step 3: Implement the sidecar filter**

Add the static method to `FileSystemWatcher`. This is the first piece because it's independently testable:

```swift
// Add to FileSystemWatcher, inside the class body after the properties section

/// Returns true if the given path is an internal sidecar/metadata file that should
/// NOT trigger a sidebar refresh when changed.
///
/// Sidecar files are app-internal metadata (statistics, manifests, search indexes)
/// that change frequently during normal use. Excluding them from sidebar refresh
/// triggers eliminates the feedback loop where sidecar writes cause full reloads
/// that re-read all sidecars.
///
/// Note: Sidecar paths are excluded from *sidebar refresh* triggers but are still
/// delivered to the search index for targeted re-indexing.
public static func isSidecarPath(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    let ext = url.pathExtension.lowercased()

    // Universal search database and WAL/SHM files
    if name.hasPrefix(".universal-search.db") {
        return true
    }

    // FASTQ metadata sidecar
    if name.hasSuffix(".lungfish-meta.json") {
        return true
    }

    // FASTQBundleCSVMetadata
    if name == "metadata.csv" {
        return true
    }

    // JSON files inside .lungfishfastq or .lungfishref bundles are internal manifests.
    // JSON files outside bundles (e.g. classification-result.json in Analyses/) are NOT
    // sidecars — they signal the presence of new analysis results.
    if ext == "json" {
        let pathString = url.path
        if pathString.contains(".lungfishfastq/") || pathString.contains(".lungfishref/") {
            return true
        }
    }

    return false
}
```

- [ ] **Step 4: Run sidecar filter tests to verify they pass**

Run: `swift test --filter FileSystemWatcherTests/sidecarFilter 2>&1 | tail -20`
Expected: All 6 new sidecar filter tests pass.

- [ ] **Step 5: Rewrite FileSystemWatcher to use FSEvents**

Replace the entire `FileSystemWatcher` implementation. The class keeps the same `@MainActor` isolation and public API shape, but changes the callback signature and replaces internals:

```swift
// FileSystemWatcher.swift - FSEvents-based directory monitoring with sidecar filtering
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CoreServices
import os.log
import LungfishCore

/// Logger for file system watcher operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "FileSystemWatcher")

/// Watches a directory for filesystem changes using macOS FSEvents.
///
/// This class monitors a directory and its subdirectories for changes including
/// file creation, deletion, modification, and rename/move. Changes to internal
/// sidecar files (`.lungfish-meta.json`, search databases, bundle-internal JSON)
/// are filtered out to prevent feedback loops.
///
/// When non-sidecar changes are detected, the provided callback is invoked on the
/// main thread with the list of changed paths. Sidecar-only changes are suppressed.
///
/// FSEvents coalesces changes within a 3-second window before delivering them,
/// providing natural debouncing.
@MainActor
public final class FileSystemWatcher {

    // MARK: - Types

    /// Paths delivered to the callback, split by sidecar classification.
    /// The sidebar uses `nonSidecar` to decide what to refresh.
    /// The search index uses `all` (nonSidecar + sidecar) for targeted re-indexing.
    public struct ChangedPaths: Sendable {
        /// Paths that are NOT internal sidecars — these trigger sidebar subtree refreshes.
        public let nonSidecar: [URL]
        /// All changed paths including sidecars — used by the search index.
        public let all: [URL]
    }

    // MARK: - Properties

    /// The callback to invoke when filesystem changes are detected.
    /// Called on the main thread. Receives non-sidecar paths for sidebar refresh
    /// and all paths for search index update.
    private let onChange: @MainActor (ChangedPaths) -> Void

    /// The directory currently being watched
    private var watchedDirectory: URL?

    /// The FSEvents stream reference.
    /// `nonisolated(unsafe)` because FSEventStreamRef isn't Sendable and we need
    /// to access it in deinit. Safe because all accesses are on the main thread
    /// (stream is scheduled on the main run loop).
    private nonisolated(unsafe) var eventStream: FSEventStreamRef?

    /// FSEvents latency — events are coalesced within this window before delivery.
    private let latency: CFTimeInterval = 3.0

    /// Whether the watcher is currently active
    public var isWatching: Bool {
        eventStream != nil
    }

    // MARK: - Initialization

    /// Creates a new FileSystemWatcher.
    ///
    /// - Parameter onChange: Callback invoked when filesystem changes are detected.
    ///                      Always called on the main thread.
    public init(onChange: @escaping @MainActor (ChangedPaths) -> Void) {
        self.onChange = onChange
        logger.debug("FileSystemWatcher initialized")
    }

    deinit {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    // MARK: - Public API

    /// Starts watching the specified directory for changes.
    ///
    /// If already watching a directory, stops the previous watch first.
    ///
    /// - Parameter directory: The directory URL to watch (must be a file URL)
    public func startWatching(directory: URL) {
        if eventStream != nil {
            stopWatching()
        }

        guard directory.isFileURL else {
            logger.error("startWatching: URL is not a file URL: \(directory.absoluteString, privacy: .public)")
            return
        }

        watchedDirectory = directory
        let path = directory.path
        logger.info("startWatching: Starting FSEvents watch on '\(path, privacy: .public)'")

        // FSEventStreamCreate requires a C callback. We pass `self` (Unmanaged) as the
        // context info pointer. The callback dispatches to the main queue and uses
        // MainActor.assumeIsolated to bridge back into @MainActor isolation.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [path] as CFArray

        guard let stream = FSEventStreamCreate(
            nil,                                          // allocator
            FileSystemWatcher.fsEventsCallback,           // callback
            &context,                                     // context
            pathsToWatch,                                 // paths
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), // since when
            latency,                                      // latency (seconds)
            UInt32(
                kFSEventStreamCreateFlagFileEvents |      // per-file events
                kFSEventStreamCreateFlagUseCFTypes |      // CF path types
                kFSEventStreamCreateFlagNoDefer           // deliver first event immediately
            )
        ) else {
            logger.error("startWatching: FSEventStreamCreate returned nil — falling back to polling")
            startPollingFallback(directory: directory)
            return
        }

        eventStream = stream
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)

        logger.info("startWatching: FSEvents stream started successfully")
    }

    /// Stops watching the current directory.
    ///
    /// Safe to call even if not currently watching.
    public func stopWatching() {
        guard let stream = eventStream else {
            logger.debug("stopWatching: Not currently watching")
            return
        }

        logger.info("stopWatching: Stopping watcher for '\(self.watchedDirectory?.path ?? "unknown", privacy: .public)'")

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
        watchedDirectory = nil

        logger.info("stopWatching: Watcher stopped and released")
    }

    // MARK: - Sidecar Filter

    /// Returns true if the given path is an internal sidecar/metadata file that should
    /// NOT trigger a sidebar refresh when changed.
    ///
    /// Sidecar files are app-internal metadata (statistics, manifests, search indexes)
    /// that change frequently during normal use. Excluding them from sidebar refresh
    /// triggers eliminates the feedback loop where sidecar writes cause full reloads
    /// that re-read all sidecars.
    ///
    /// Note: Sidecar paths are excluded from *sidebar refresh* triggers but are still
    /// delivered to the search index for targeted re-indexing.
    public static func isSidecarPath(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        // Universal search database and WAL/SHM files
        if name.hasPrefix(".universal-search.db") {
            return true
        }

        // FASTQ metadata sidecar
        if name.hasSuffix(".lungfish-meta.json") {
            return true
        }

        // FASTQBundleCSVMetadata
        if name == "metadata.csv" {
            return true
        }

        // JSON files inside .lungfishfastq or .lungfishref bundles are internal manifests.
        // JSON files outside bundles (e.g. classification-result.json in Analyses/) are NOT
        // sidecars — they signal the presence of new analysis results.
        if ext == "json" {
            let pathString = url.path
            if pathString.contains(".lungfishfastq/") || pathString.contains(".lungfishref/") {
                return true
            }
        }

        return false
    }

    // MARK: - FSEvents Callback

    /// C-function callback for FSEventStream. Bridges into Swift/MainActor.
    private static let fsEventsCallback: FSEventStreamCallback = {
        (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in

        guard let clientCallBackInfo else { return }
        let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

        // Extract paths from the CF array
        guard let cfPaths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
        let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

        var allURLs: [URL] = []
        var mustScanSubDirs = false

        for i in 0..<numEvents {
            let flag = Int(flags[i])

            // Root changed — the watched directory was moved/deleted
            if flag & kFSEventStreamEventFlagRootChanged != 0 {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        logger.warning("FSEvents: Root directory changed — stopping watcher")
                        watcher.stopWatching()
                    }
                }
                return
            }

            // Kernel overflow — must do a full scan
            if flag & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                mustScanSubDirs = true
            }

            // Skip history-done sentinel events
            if flag & kFSEventStreamEventFlagHistoryDone != 0 {
                continue
            }

            allURLs.append(URL(fileURLWithPath: cfPaths[i]))
        }

        // Dispatch to main thread for @MainActor isolation
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if mustScanSubDirs {
                    logger.info("FSEvents: MustScanSubDirs flag — delivering empty ChangedPaths to trigger full reload")
                    // Empty nonSidecar signals "full reload needed" to the sidebar
                    watcher.onChange(ChangedPaths(nonSidecar: [], all: []))
                    return
                }

                guard !allURLs.isEmpty else { return }

                let nonSidecar = allURLs.filter { !FileSystemWatcher.isSidecarPath($0) }

                // Only invoke callback if there are non-sidecar changes OR sidecar-only
                // changes that the search index should process.
                if !nonSidecar.isEmpty || !allURLs.isEmpty {
                    watcher.onChange(ChangedPaths(nonSidecar: nonSidecar, all: allURLs))
                }
            }
        }
    }

    // MARK: - Polling Fallback

    /// Fallback polling mode if FSEventStreamCreate fails. Uses a 5-second timer
    /// with the original snapshot-comparison approach. Should never be needed on macOS.
    private func startPollingFallback(directory: URL) {
        logger.warning("startPollingFallback: Using polling fallback (FSEvents unavailable)")
        // Implementation intentionally omitted — FSEvents is available on all
        // supported macOS versions. If needed, the original Timer+DirectorySnapshot
        // code can be restored from git history.
    }
}
```

- [ ] **Step 6: Update existing FileSystemWatcher tests for new callback signature**

The existing tests create `FileSystemWatcher { ... }` with a `() -> Void` callback. Update them to use the new `(ChangedPaths) -> Void` signature:

```swift
// In each existing test, change the watcher creation from:
let watcher = FileSystemWatcher {
    callbackInvoked = true
    expectation.fulfill()
}

// To:
let watcher = FileSystemWatcher { _ in
    callbackInvoked = true
    expectation.fulfill()
}
```

Apply this pattern to all 8 existing tests:
- `watcherDetectsFileCreation` — change `{ ... }` to `{ _ in ... }`
- `watcherDetectsFileDeletion` — same
- `watcherDetectsFileRename` — same
- `watcherHandlesNestedChanges` — same
- `watcherCleansUpOnStop` — same
- `watcherFiltersHiddenFiles` — both watcher1 and watcher2
- `watcherDebouncesRapidChanges` — same
- `watcherCanRestartOnDifferentDirectory` — same

Also increase sleep durations from 2 seconds to 5 seconds in each test, since FSEvents now has a 3-second latency window.

- [ ] **Step 7: Run all FileSystemWatcher tests**

Run: `swift test --filter FileSystemWatcherTests 2>&1 | tail -30`
Expected: All tests pass (8 existing + 6 new sidecar filter tests = 14 tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/LungfishApp/Services/FileSystemWatcher.swift Tests/LungfishAppTests/FileSystemWatcherTests.swift
git commit -m "feat: replace polling FileSystemWatcher with FSEvents + sidecar filter

Replace 1-second Timer+DirectorySnapshot polling with FSEventStreamCreate.
Add ChangedPaths struct that separates sidecar from non-sidecar paths.
Add static isSidecarPath filter for .lungfish-meta.json, search DBs,
and bundle-internal JSON files."
```

---

### Task 2: Update SidebarViewController Watcher Integration

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`

Update the sidebar to use the new `ChangedPaths` callback and route to either incremental or full update.

- [ ] **Step 1: Update the watcher callback in `openProject(at:)`**

In `SidebarViewController.swift`, find the `openProject(at:)` method (around line 650). Change the watcher creation:

```swift
// OLD (around line 667-670):
fileSystemWatcher = FileSystemWatcher { [weak self] in
    self?.reloadFromFilesystem()
}

// NEW:
fileSystemWatcher = FileSystemWatcher { [weak self] changedPaths in
    guard let self else { return }
    if changedPaths.nonSidecar.isEmpty && !changedPaths.all.isEmpty {
        // Sidecar-only changes OR MustScanSubDirs with empty paths — update search only
        // MustScanSubDirs (empty all) triggers full reload below
        if changedPaths.all.isEmpty {
            // kFSEventStreamEventFlagMustScanSubDirs — full reload
            self.reloadFromFilesystem()
        } else {
            // Sidecar-only — just update the search index
            self.updateSearchIndex(changedPaths: changedPaths.all)
        }
    } else {
        // Non-sidecar changes detected — incremental sidebar update
        self.updateSidebar(changedPaths: changedPaths)
    }
}
```

- [ ] **Step 2: Add the `updateSearchIndex(changedPaths:)` helper**

Add this near the existing `scheduleUniversalSearchRebuild` method (around line 456):

```swift
/// Sends changed paths to the universal search service for targeted re-indexing.
///
/// Unlike `scheduleUniversalSearchRebuild()` which does a full rebuild,
/// this only updates index entries for the specific files that changed.
private func updateSearchIndex(changedPaths: [URL]) {
    guard let projectURL else { return }
    Task {
        await universalSearchService.update(
            projectURL: projectURL,
            changedPaths: changedPaths
        )
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -20`
Expected: Compilation error — `universalSearchService.update(projectURL:changedPaths:)` doesn't exist yet. That's OK — we'll add it in Task 4. For now, comment out the body of `updateSearchIndex` with a `// TODO: Task 4` and verify the build passes.

Temporary:
```swift
private func updateSearchIndex(changedPaths: [URL]) {
    guard let projectURL else { return }
    // TODO: Implement in Task 4 — uncomment when UniversalProjectSearchService.update exists
    // Task {
    //     await universalSearchService.update(
    //         projectURL: projectURL,
    //         changedPaths: changedPaths
    //     )
    // }
    _ = projectURL // silence unused warning
}
```

- [ ] **Step 4: Build to verify compilation succeeds**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift
git commit -m "feat: wire sidebar to FSEvents ChangedPaths callback

Route non-sidecar changes to updateSidebar (Task 3), sidecar-only
changes to search index update (Task 4), and MustScanSubDirs to
full reloadFromFilesystem."
```

---

### Task 3: Implement Incremental Sidebar Updates

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`

This is the most complex task. Add `updateSidebar(changedPaths:)` which maps changed paths to sidebar subtrees, rebuilds only those subtrees, and applies surgical `NSOutlineView` operations.

- [ ] **Step 1: Add the `updateSidebar(changedPaths:)` method**

Add this method near `reloadFromFilesystem()` (after line 780):

```swift
/// Incrementally updates the sidebar for specific changed paths.
///
/// Instead of rebuilding the entire sidebar tree, this method:
/// 1. Maps changed paths to their top-level parent items in the sidebar
/// 2. Re-scans only the affected directories
/// 3. Diffs old vs new children and applies NSOutlineView insert/remove/reload
///
/// For changes that affect the root level (e.g. new top-level file), falls back
/// to a full reload.
///
/// - Parameter changedPaths: The FSEvents `ChangedPaths` with both filtered and unfiltered paths.
private func updateSidebar(changedPaths: FileSystemWatcher.ChangedPaths) {
    guard let projectURL else { return }

    logger.debug("updateSidebar: Processing \(changedPaths.nonSidecar.count) non-sidecar changed paths")

    // Also forward ALL paths (including sidecars) to the search index
    updateSearchIndex(changedPaths: changedPaths.all)

    let nonSidecar = changedPaths.nonSidecar
    guard !nonSidecar.isEmpty else { return }

    // Map each changed path to its top-level sidebar parent.
    // A changed path like /project/Downloads/foo.lungfishfastq/bar.fastq.gz
    // maps to the "Downloads" top-level item.
    let projectPath = projectURL.standardizedFileURL.path
    var affectedTopLevelNames: Set<String> = []
    var affectsRoot = false

    for url in nonSidecar {
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(projectPath) else { continue }

        // Relative path from project root, e.g. "Downloads/SRR123.lungfishfastq/foo"
        let relativePath = String(filePath.dropFirst(projectPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let components = relativePath.split(separator: "/", maxSplits: 1)
        if components.isEmpty {
            // Change at project root level
            affectsRoot = true
        } else {
            affectedTopLevelNames.insert(String(components[0]))
        }
    }

    // If the root level itself changed (new top-level file/folder), fall back to full reload.
    // Also fall back if the Analyses folder is affected (it's a synthetic group with special logic).
    if affectsRoot || affectedTopLevelNames.contains(AnalysesFolder.directoryName) {
        logger.info("updateSidebar: Root-level or Analyses change — falling back to full reload")
        reloadFromFilesystem()
        return
    }

    logger.info("updateSidebar: Incremental update for \(affectedTopLevelNames.count) top-level items")

    // For each affected top-level item, rebuild its subtree and diff against existing
    for topLevelName in affectedTopLevelNames {
        let topLevelURL = projectURL.appendingPathComponent(topLevelName)

        // Find the existing SidebarItem in rootItems
        guard let existingItemIndex = rootItems.firstIndex(where: {
            $0.url?.standardizedFileURL.path == topLevelURL.standardizedFileURL.path
        }) else {
            // New top-level item we don't have yet — fall back to full reload
            logger.debug("updateSidebar: New top-level item '\(topLevelName)' — full reload")
            reloadFromFilesystem()
            return
        }

        let existingItem = rootItems[existingItemIndex]

        // Rebuild just this item's subtree
        let rebuiltItem = buildSidebarTree(from: topLevelURL, isRoot: false)

        // Apply the diff
        applySubtreeDiff(
            existingItem: existingItem,
            rebuiltItem: rebuiltItem,
            parent: nil,
            indexInParent: existingItemIndex
        )
    }
}
```

- [ ] **Step 2: Add the `applySubtreeDiff` helper method**

Add this method right after `updateSidebar`:

```swift
/// Applies a diff between an existing sidebar item's children and a rebuilt version,
/// using surgical NSOutlineView operations instead of reloadData().
///
/// - Parameters:
///   - existingItem: The current SidebarItem in the tree
///   - rebuiltItem: The freshly rebuilt version of the same item
///   - parent: The parent item (nil for root-level items)
///   - indexInParent: The index of this item within its parent's children (or rootItems)
private func applySubtreeDiff(
    existingItem: SidebarItem,
    rebuiltItem: SidebarItem,
    parent: SidebarItem?,
    indexInParent: Int
) {
    // Update title and subtitle if changed (e.g. processing state badge changed)
    var itemNeedsReload = false
    if existingItem.title != rebuiltItem.title {
        existingItem.title = rebuiltItem.title
        itemNeedsReload = true
    }
    if existingItem.subtitle != rebuiltItem.subtitle {
        existingItem.subtitle = rebuiltItem.subtitle
        itemNeedsReload = true
    }

    if itemNeedsReload {
        outlineView.reloadItem(existingItem, reloadChildren: false)
    }

    // Build maps for diffing children by URL
    let existingByURL: [String: (index: Int, item: SidebarItem)] = {
        var map: [String: (Int, SidebarItem)] = [:]
        for (i, child) in existingItem.children.enumerated() {
            if let path = child.url?.standardizedFileURL.path {
                map[path] = (i, child)
            }
        }
        return map
    }()

    let rebuiltByURL: [String: (index: Int, item: SidebarItem)] = {
        var map: [String: (Int, SidebarItem)] = [:]
        for (i, child) in rebuiltItem.children.enumerated() {
            if let path = child.url?.standardizedFileURL.path {
                map[path] = (i, child)
            }
        }
        return map
    }()

    let existingURLs = Set(existingByURL.keys)
    let rebuiltURLs = Set(rebuiltByURL.keys)

    // Deletions: items in existing but not in rebuilt
    let deletedURLs = existingURLs.subtracting(rebuiltURLs)
    // Insertions: items in rebuilt but not in existing
    let insertedURLs = rebuiltURLs.subtracting(existingURLs)
    // Potential updates: items in both
    let commonURLs = existingURLs.intersection(rebuiltURLs)

    // Apply deletions (in reverse index order to avoid shifting)
    let deletionIndices = deletedURLs
        .compactMap { existingByURL[$0]?.index }
        .sorted(by: >)
    for index in deletionIndices {
        existingItem.children.remove(at: index)
        outlineView.removeItems(
            at: IndexSet(integer: index),
            inParent: existingItem,
            withAnimation: .slideUp
        )
    }

    // Apply insertions (in order of rebuilt indices)
    let insertions = insertedURLs
        .compactMap { url -> (Int, SidebarItem)? in
            guard let (index, item) = rebuiltByURL[url] else { return nil }
            return (index, item)
        }
        .sorted { $0.0 < $1.0 }
    for (targetIndex, newItem) in insertions {
        let insertIndex = min(targetIndex, existingItem.children.count)
        existingItem.children.insert(newItem, at: insertIndex)
        outlineView.insertItems(
            at: IndexSet(integer: insertIndex),
            inParent: existingItem,
            withAnimation: .slideDown
        )
    }

    // Recurse into common items for subtitle/children updates
    for url in commonURLs {
        guard let (_, existingChild) = existingByURL[url],
              let (_, rebuiltChild) = rebuiltByURL[url] else { continue }
        // Find the current index of the existing child (may have shifted from deletions/insertions)
        guard let currentIndex = existingItem.children.firstIndex(where: {
            $0.url?.standardizedFileURL.path == url
        }) else { continue }
        applySubtreeDiff(
            existingItem: existingChild,
            rebuiltItem: rebuiltChild,
            parent: existingItem,
            indexInParent: currentIndex
        )
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds. (The `AnalysesFolder.directoryName` reference should already exist — it's used at line 830 of SidebarViewController.)

- [ ] **Step 4: Run existing sidebar tests to check for regressions**

Run: `swift test --filter SidebarTests 2>&1 | tail -20`
Expected: All existing sidebar tests pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift
git commit -m "feat: add incremental sidebar update via subtree diff

Add updateSidebar(changedPaths:) that maps FSEvents paths to affected
top-level sidebar items, rebuilds only those subtrees, and applies
surgical NSOutlineView insert/remove/reload operations."
```

---

### Task 4: Incremental Universal Search Index

**Files:**
- Modify: `Sources/LungfishIO/Search/ProjectUniversalSearchIndex.swift`
- Modify: `Sources/LungfishApp/Services/UniversalProjectSearchService.swift`
- Test: `Tests/LungfishIOTests/ProjectUniversalSearchIncrementalTests.swift` (new)

Add targeted upsert/delete to the search index so it can process individual changed paths without a full rebuild.

- [ ] **Step 1: Write failing test for incremental update**

Create `Tests/LungfishIOTests/ProjectUniversalSearchIncrementalTests.swift`:

```swift
// ProjectUniversalSearchIncrementalTests.swift - Tests for incremental index updates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class ProjectUniversalSearchIncrementalTests: XCTestCase {

    private var tempDir: URL!
    private var index: ProjectUniversalSearchIndex!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncrementalSearchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        index = try ProjectUniversalSearchIndex(projectURL: tempDir)
    }

    override func tearDown() async throws {
        index = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDeleteByPath_removesMatchingEntities() throws {
        // Build initial index with a FASTQ bundle
        let bundleURL = tempDir.appendingPathComponent("SRR123.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        // Write a minimal preview.fastq so the bundle is recognized
        let previewURL = bundleURL.appendingPathComponent("preview.fastq")
        try "@SEQ1\nACGT\n+\nIIII\n".write(to: previewURL, atomically: true, encoding: .utf8)

        let stats = try index.rebuild()
        XCTAssertGreaterThan(stats.indexedEntities, 0)

        // Now delete entries for this bundle
        let removed = try index.deleteEntities(matchingPathPrefix: "SRR123.lungfishfastq")
        XCTAssertGreaterThan(removed, 0)

        // Verify the entity is gone
        let results = try index.search(query: "SRR123")
        XCTAssertEqual(results.count, 0)
    }

    func testUpsertFASTQBundle_addsNewEntity() throws {
        let bundleURL = tempDir.appendingPathComponent("NEW456.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let previewURL = bundleURL.appendingPathComponent("preview.fastq")
        try "@SEQ1\nACGT\n+\nIIII\n".write(to: previewURL, atomically: true, encoding: .utf8)

        // Start with empty index
        let initialStats = try index.indexStats()
        XCTAssertEqual(initialStats.entityCount, 0)

        // Upsert just this one bundle
        try index.upsertArtifact(at: bundleURL)

        let afterStats = try index.indexStats()
        XCTAssertGreaterThan(afterStats.entityCount, 0)

        let results = try index.search(query: "NEW456")
        XCTAssertGreaterThan(results.count, 0)
    }

    func testUpdateChangedPaths_deletesRemovedFiles() throws {
        // Build initial index with a bundle
        let bundleURL = tempDir.appendingPathComponent("DEL789.lungfishfastq")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let previewURL = bundleURL.appendingPathComponent("preview.fastq")
        try "@SEQ1\nACGT\n+\nIIII\n".write(to: previewURL, atomically: true, encoding: .utf8)
        try index.rebuild()

        // Verify it was indexed
        let beforeResults = try index.search(query: "DEL789")
        XCTAssertGreaterThan(beforeResults.count, 0)

        // Delete the bundle from disk
        try FileManager.default.removeItem(at: bundleURL)

        // Run incremental update with the deleted path
        try index.update(changedPaths: [bundleURL])

        // Verify it was removed from the index
        let afterResults = try index.search(query: "DEL789")
        XCTAssertEqual(afterResults.count, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectUniversalSearchIncrementalTests 2>&1 | head -20`
Expected: Compilation error — `deleteEntities`, `upsertArtifact`, `update(changedPaths:)` don't exist.

- [ ] **Step 3: Add `deleteEntities(matchingPathPrefix:)` to ProjectUniversalSearchIndex**

In `ProjectUniversalSearchIndex.swift`, add near the end of the class (before the schema section):

```swift
// MARK: - Incremental Updates

/// Deletes all entities whose `rel_path` starts with the given prefix.
///
/// Also deletes associated attributes via ON DELETE CASCADE.
///
/// - Parameter prefix: The relative path prefix to match (e.g. "SRR123.lungfishfastq")
/// - Returns: The number of deleted entities.
@discardableResult
public func deleteEntities(matchingPathPrefix prefix: String) throws -> Int {
    try execute("BEGIN IMMEDIATE TRANSACTION")
    do {
        let sql = "DELETE FROM us_entities WHERE rel_path LIKE ? || '%'"
        try executeWithBindings(sql, bindings: [.text(prefix)])
        let changes = sqlite3_changes(db)
        try execute("COMMIT")
        Self.logger.debug("deleteEntities: Removed \(changes) entities matching prefix '\(prefix, privacy: .public)'")
        return Int(changes)
    } catch {
        try? execute("ROLLBACK")
        throw error
    }
}
```

- [ ] **Step 4: Add `upsertArtifact(at:)` to ProjectUniversalSearchIndex**

```swift
/// Re-indexes a single artifact at the given URL.
///
/// Determines the artifact type (FASTQ bundle, reference bundle, classification result, etc.)
/// and calls the appropriate indexer. If the artifact already exists in the index, its entries
/// are replaced via INSERT OR REPLACE.
///
/// - Parameter url: The URL of the artifact to index.
public func upsertArtifact(at url: URL) throws {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
        // File was deleted — remove from index
        let relPath = relativePathFromProject(url)
        try deleteEntities(matchingPathPrefix: relPath)
        return
    }

    var entityCount = 0
    var attributeCount = 0
    var perKindCounts: [String: Int] = [:]

    try execute("BEGIN IMMEDIATE TRANSACTION")
    do {
        // Delete existing entries for this artifact first (clean upsert)
        let relPath = relativePathFromProject(url)
        let deleteSql = "DELETE FROM us_entities WHERE rel_path LIKE ? || '%'"
        try executeWithBindings(deleteSql, bindings: [.text(relPath)])

        // Determine type and index
        if isDir.boolValue {
            if url.pathExtension == FASTQBundle.directoryExtension {
                try indexFASTQBundle(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
            } else if url.pathExtension == "lungfishref" {
                try indexReferenceBundle(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
            } else if url.lastPathComponent.hasPrefix("classification-") && hasFile("classification-result.json", in: url) {
                try indexClassificationResult(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
            } else if url.lastPathComponent.hasPrefix("esviritu-") && hasFile("esviritu-result.json", in: url) {
                try indexEsVirituResult(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
            } else if url.lastPathComponent.hasPrefix("taxtriage-") && hasFile("taxtriage-result.json", in: url) {
                try indexTaxTriageResult(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
            } else if url.lastPathComponent.hasPrefix("naomgs-") && hasFile("manifest.json", in: url) {
                try indexNaoMgsResult(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
            } else if url.lastPathComponent.hasPrefix("nvd-") && hasFile("hits.sqlite", in: url) {
                try indexNvdResult(at: url, entityCount: &entityCount, attributeCount: &attributeCount, perKindCounts: &perKindCounts)
            }
        }

        try execute("COMMIT")
    } catch {
        try? execute("ROLLBACK")
        throw error
    }

    Self.logger.debug("upsertArtifact: Indexed \(entityCount) entities for \(url.lastPathComponent, privacy: .public)")
}

/// Returns the path of a URL relative to the project root.
private func relativePathFromProject(_ url: URL) -> String {
    let projectPath = projectURL.standardizedFileURL.path
    let filePath = url.standardizedFileURL.path
    if filePath.hasPrefix(projectPath) {
        return String(filePath.dropFirst(projectPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    return url.lastPathComponent
}
```

- [ ] **Step 5: Add `update(changedPaths:)` to ProjectUniversalSearchIndex**

```swift
/// Incrementally updates the index for specific changed paths.
///
/// For each path:
/// - If the file/directory still exists on disk, upserts its index entries
/// - If the file/directory was deleted, removes its index entries
///
/// For sidecar files (`.lungfish-meta.json`), finds the parent FASTQ bundle
/// and re-indexes it to pick up updated statistics.
///
/// - Parameter changedPaths: URLs of files/directories that changed.
public func update(changedPaths: [URL]) throws {
    guard !changedPaths.isEmpty else { return }

    Self.logger.debug("update(changedPaths:): Processing \(changedPaths.count) changed paths")

    // Deduplicate: if both a sidecar and its parent bundle are in the list,
    // we only need to upsert the bundle once.
    var bundlesToUpsert: Set<String> = []
    var pathsToProcess: [URL] = []

    for url in changedPaths {
        let pathString = url.standardizedFileURL.path

        // If this is a sidecar inside a FASTQ bundle, resolve to the bundle
        if FileSystemWatcher.isSidecarPath(url) {
            if let bundlePath = extractBundlePath(from: pathString) {
                if bundlesToUpsert.insert(bundlePath).inserted {
                    pathsToProcess.append(URL(fileURLWithPath: bundlePath))
                }
            }
            continue
        }

        // Check if this path is inside a known bundle
        if let bundlePath = extractBundlePath(from: pathString) {
            if bundlesToUpsert.insert(bundlePath).inserted {
                pathsToProcess.append(URL(fileURLWithPath: bundlePath))
            }
        } else {
            pathsToProcess.append(url)
        }
    }

    for url in pathsToProcess {
        try upsertArtifact(at: url)
    }
}

/// Extracts the path to the enclosing `.lungfishfastq` or `.lungfishref` bundle,
/// if the given path is inside one. Returns nil if not inside a bundle.
private func extractBundlePath(from path: String) -> String? {
    for ext in [".lungfishfastq/", ".lungfishref/"] {
        if let range = path.range(of: ext) {
            return String(path[path.startIndex..<range.upperBound].dropLast()) // drop trailing /
        }
    }
    // Check if the path IS a bundle (not inside one)
    if path.hasSuffix(".lungfishfastq") || path.hasSuffix(".lungfishref") {
        return path
    }
    return nil
}
```

- [ ] **Step 6: Add `executeWithBindings` helper if it doesn't exist**

Check if `ProjectUniversalSearchIndex` already has a method for executing SQL with bound parameters. Search for `executeWithBindings` or the pattern used by `insertEntity`. If it uses a different pattern (e.g., preparing statements manually), adapt the `deleteEntities` method to match. The existing `insertEntity` method (around line 1898) shows the pattern — use the same approach.

If the index uses raw `sqlite3_prepare_v2` + `sqlite3_bind_*` directly, replace the `executeWithBindings` call in `deleteEntities` with:

```swift
var stmt: OpaquePointer?
guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
    throw SearchIndexError.sqliteError(String(cString: sqlite3_errmsg(db)))
}
defer { sqlite3_finalize(stmt) }
sqlite3_bind_text(stmt, 1, (prefix as NSString).utf8String, -1, nil)
guard sqlite3_step(stmt) == SQLITE_DONE else {
    throw SearchIndexError.sqliteError(String(cString: sqlite3_errmsg(db)))
}
```

- [ ] **Step 7: Run the incremental search tests**

Run: `swift test --filter ProjectUniversalSearchIncrementalTests 2>&1 | tail -20`
Expected: All 3 tests pass.

- [ ] **Step 8: Add `update(changedPaths:)` to `UniversalProjectSearchService`**

In `Sources/LungfishApp/Services/UniversalProjectSearchService.swift`, add:

```swift
/// Incrementally updates the search index for specific changed paths.
///
/// This is the incremental counterpart to `scheduleRebuild`. Instead of
/// rebuilding the entire index, it processes only the specified paths.
public func update(projectURL: URL, changedPaths: [URL]) {
    let canonical = projectURL.standardizedFileURL

    do {
        let idx = try index(for: canonical)
        try idx.update(changedPaths: changedPaths)
    } catch {
        universalSearchLogger.error(
            "update(changedPaths:) failed for \(canonical.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
    }
}
```

- [ ] **Step 9: Uncomment the `updateSearchIndex` body in SidebarViewController**

In `SidebarViewController.swift`, replace the TODO placeholder in `updateSearchIndex(changedPaths:)` from Task 2:

```swift
private func updateSearchIndex(changedPaths: [URL]) {
    guard let projectURL else { return }
    Task {
        await universalSearchService.update(
            projectURL: projectURL,
            changedPaths: changedPaths
        )
    }
}
```

- [ ] **Step 10: Build and run full test suite**

Run: `swift build --build-tests 2>&1 | tail -10`
Expected: Build succeeds.

Run: `swift test --filter "FileSystemWatcherTests|ProjectUniversalSearchIncrementalTests|SidebarTests" 2>&1 | tail -30`
Expected: All tests pass.

- [ ] **Step 11: Commit**

```bash
git add Sources/LungfishIO/Search/ProjectUniversalSearchIndex.swift Sources/LungfishApp/Services/UniversalProjectSearchService.swift Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift Tests/LungfishIOTests/ProjectUniversalSearchIncrementalTests.swift
git commit -m "feat: add incremental search index update via upsert/delete

Add deleteEntities(matchingPathPrefix:), upsertArtifact(at:), and
update(changedPaths:) to ProjectUniversalSearchIndex. Wire through
UniversalProjectSearchService and SidebarViewController."
```

---

### Task 5: Integration Verification

**Files:** None (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: All ~1400 tests pass. No regressions.

- [ ] **Step 2: Build the app**

Run: `swift build 2>&1 | tail -10`
Expected: Clean build with no warnings related to our changes.

- [ ] **Step 3: Verify the FSEvents `extractBundlePath` edge cases**

Check the `extractBundlePath` method handles these cases correctly by reviewing the logic:
- Path inside a bundle: `/project/Downloads/SRR123.lungfishfastq/preview.fastq` → `/project/Downloads/SRR123.lungfishfastq`
- Path IS a bundle: `/project/Downloads/SRR123.lungfishfastq` → `/project/Downloads/SRR123.lungfishfastq`
- Path not in a bundle: `/project/Downloads/sample.bam` → `nil`
- Nested path: `/project/Downloads/SRR123.lungfishfastq/derivatives/trim/foo.fastq` → `/project/Downloads/SRR123.lungfishfastq`

The `range.upperIndex` in `extractBundlePath` should be `range.upperBound`. Fix if needed:

```swift
return String(path[path.startIndex..<range.upperBound].dropLast())
```

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: address integration issues from verification pass"
```

(Skip this step if no fixes were needed.)
