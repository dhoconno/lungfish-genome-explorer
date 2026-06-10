# Watcher Reload Storm Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the main-thread sidebar stall (30s+ before the delete confirmation dialog) by coalescing FSEvents-driven full reloads, moving the directory scan off the main thread, and signposting the reload path so the win is measurable.

**Architecture:** The stall is a storm of full `reloadFromFilesystem()` calls triggered by `kFSEventStreamEventFlagMustScanSubDirs` on a network volume (diagnosis: `docs/reports/2026-06-09-sidebar-delete-diagnosis.md`). Fix in three layers: (1) debounce/coalesce repeated full-reload deliveries in `ProjectFilesystemRefreshCoordinator.fanOut` — the single choke point every delivery flows through; (2) signpost `reloadFromFilesystem` + the FSEvents delivery so before/after is measurable; (3) move the recursive `buildRootItems` scan off the main actor, returning only the model swap + outline update to `@MainActor`. Reuse existing machinery (`applySubtreeDiff`, `testingEmitChange`).

**Tech Stack:** Swift 6.2, macOS 26, `@MainActor` + strict concurrency, FSEvents (`CoreServices`), SwiftPM, `os` (`OSSignposter`/`Logger`), `NSOutlineView`, XCTest.

---

## Diagnosis recap (why these tasks, in this order)

- The hang occurs **before** `performDelete` runs — proven by a live signpost capture: 43 `Sidebar.OutlineRefresh` intervals at 1–2/sec for ~66s, zero `Sidebar.Delete`.
- Driver: `FileSystemWatcher` callback (`FileSystemWatcher.swift:114`, dispatched on `DispatchQueue.main`) delivers `MustScanSubDirs` as an empty `ChangedPaths`; the consumer (`SidebarViewController.swift:707-709`) turns that into a full `reloadFromFilesystem()`. On `/Volumes/iWES_WNPRC` (network volume) `MustScanSubDirs` fires constantly.
- `reloadFromFilesystem()` (`SidebarViewController.swift:791`) is heavyweight and entirely main-thread: recursive `buildRootItems(from:)` (slow on a network mount) + full `reloadData()` + full-tree width measure + expansion/selection save-restore + `scheduleUniversalSearchRebuild()`.
- The existing incremental path (`updateSidebar` → `applySubtreeDiff`) **already falls back to full reload** for root/Analyses/new-top-level changes (`SidebarViewController.swift:899-915`). The ONT job writes into `Analyses/`, so incremental-diff alone would NOT help that trigger — which is why **debounce (Task 2) is the load-bearing fix** and off-main (Task 4) makes each unavoidable reload non-blocking.

## Build/test conventions (binding — from project memory)

- Build/test this worktree with `swift test --package-path . --skip-update` / `swift build --package-path . --skip-update`. `swift` has no `-C` flag. Always `--skip-update` (offline; avoids the `testSRASearch` flake).
- **Serialize all swift invocations** — single `.build/.lock` per checkout. Before any build/test: `ps aux | grep -E "swift-(build|test)|xcodebuild" | grep -v grep`; if a swift process runs, WAIT (a killed waiter exits 144 with empty output — that's lock contention, not a failure).
- **Green-bar baseline:** GREEN iff XCTest failures ⊆ the known 9 environmental failures (6 `GenotypeRealBundleSmokeTests`, 2 `ZhangArtifactCanaryTests`, 1 `VCFRobustnessTests.testAllRealVCFsFromDownloads`) AND swift-testing failures = 0.
- **Background→MainActor:** work moved off-main keeps model mutation + UI on `@MainActor`. Never `Task { @MainActor in }` from GCD; never bare `DispatchQueue.main.async` touching `@MainActor` state. Use `DispatchQueue.global(qos:).async { …; DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { … } } }`.

## File structure

| File | Responsibility | Action |
| --- | --- | --- |
| `Sources/LungfishApp/Services/ProjectFilesystemRefreshCoordinator.swift` | Owns the FSEvents watcher + fan-out. Add coalescing/debounce of full-reload (empty/empty) deliveries here, at the single `fanOut` choke point. | Modify |
| `Tests/LungfishAppTests/ProjectFilesystemRefreshCoordinatorDebounceTests.swift` | Tests that repeated full-reload deliveries coalesce to one trailing-edge delivery; granular deliveries pass through unbatched. | Create |
| `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` | `reloadFromFilesystem` (signpost + off-main scan), the FSEvents consumer closure. | Modify |
| `Sources/LungfishKit/PerfSignpost.swift` | Add a `.filesystem` static instance for the reload-path signposts (mirrors `.sidebar`). | Modify |

Note: `Tests/LungfishAppTests` is the correct app test target (verified 2026-06-09). `ProjectFilesystemRefreshCoordinator` is `@MainActor` and exposes `testingEmitChange(projectURL:changedPaths:)` and `testingSubscriberCount(for:)` for driving deliveries without real FSEvents.

---

## Task 1: Add `PerfSignpost.filesystem` + signpost `reloadFromFilesystem`

**Files:**
- Modify: `Sources/LungfishKit/PerfSignpost.swift` (add `.filesystem` static, ~after the `.sidebar` extension)
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` (`reloadFromFilesystem(notifyUnchangedSelectionRefresh:)`, ~line 791)

No unit test (signpost emission needs Instruments/log stream); build success + a later live capture is the proof. This task makes the storm and the eventual fix measurable.

- [ ] **Step 1: Add the `.filesystem` static instance**

In `Sources/LungfishKit/PerfSignpost.swift`, the existing extension is:

```swift
public extension PerfSignpost {
    /// Shared instance for sidebar interactions.
    static let sidebar = PerfSignpost(category: "Sidebar")
}
```

Change it to add a second instance:

```swift
public extension PerfSignpost {
    /// Shared instance for sidebar interactions.
    static let sidebar = PerfSignpost(category: "Sidebar")

    /// Shared instance for filesystem-watcher / reload interactions.
    static let filesystem = PerfSignpost(category: "Filesystem")
}
```

- [ ] **Step 2: Signpost the full reload**

In `SidebarViewController.swift`, `reloadFromFilesystem(notifyUnchangedSelectionRefresh:)` currently begins:

```swift
    private func reloadFromFilesystem(notifyUnchangedSelectionRefresh: Bool) {
        sidebarLogger.info("reloadFromFilesystem: CALLED - starting filesystem scan")
        guard let projectURL = projectURL else {
```

Insert a signpost interval spanning the whole method body. Change to:

```swift
    private func reloadFromFilesystem(notifyUnchangedSelectionRefresh: Bool) {
        let reloadSignpost = PerfSignpost.filesystem.begin("Filesystem.FullReload")
        defer { PerfSignpost.filesystem.end("Filesystem.FullReload", reloadSignpost) }
        sidebarLogger.info("reloadFromFilesystem: CALLED - starting filesystem scan")
        guard let projectURL = projectURL else {
```

`SidebarViewController.swift` already imports `LungfishKit` (verified). No import change needed.

- [ ] **Step 3: Build (lock check first)**

Run: `ps aux | grep -E "swift-(build|test)|xcodebuild" | grep -v grep || echo FREE`
Expected: `FREE`
Run: `swift build --package-path . --skip-update`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishKit/PerfSignpost.swift Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift
git commit -m "perf(sidebar): signpost full reloadFromFilesystem via PerfSignpost.filesystem"
```

---

## Task 2: Coalesce full-reload deliveries in the coordinator (the load-bearing fix)

**Files:**
- Modify: `Sources/LungfishApp/Services/ProjectFilesystemRefreshCoordinator.swift`
- Test: `Tests/LungfishAppTests/ProjectFilesystemRefreshCoordinatorDebounceTests.swift`

Design: the FSEvents callback delivers a *full-reload request* as `ChangedPaths(nonSidecar: [], all: [])` (the `MustScanSubDirs` case). Storms of these must collapse to ONE trailing-edge delivery. Granular deliveries (non-empty `all`) must pass through immediately and unbatched, so normal incremental updates are unaffected. The debounce lives in `fanOut`, the single point all deliveries pass through.

Because the coalescing uses a real timer, the test injects a controllable scheduler. Add a tiny injectable delay hook rather than sleeping in tests.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class ProjectFilesystemRefreshCoordinatorDebounceTests: XCTestCase {
    private func emptyReload() -> FileSystemWatcher.ChangedPaths {
        FileSystemWatcher.ChangedPaths(nonSidecar: [], all: [])
    }
    private func granular(_ p: String) -> FileSystemWatcher.ChangedPaths {
        let u = URL(fileURLWithPath: p)
        return FileSystemWatcher.ChangedPaths(nonSidecar: [u], all: [u])
    }

    func testFullReloadBurstCoalescesToOneDelivery() {
        let coordinator = ProjectFilesystemRefreshCoordinator()
        // Deterministic scheduler: capture the pending work instead of using wall-clock.
        var pending: (() -> Void)?
        coordinator.testingSetCoalesceScheduler { work in pending = work }

        let projectURL = URL(fileURLWithPath: "/tmp/proj-\(UUID().uuidString)")
        var deliveries = 0
        _ = coordinator.register(projectURL: projectURL) { _ in deliveries += 1 }

        // Simulate a storm of MustScanSubDirs full-reload requests.
        for _ in 0..<10 {
            coordinator.testingEmitChange(projectURL: projectURL, changedPaths: emptyReload())
        }
        XCTAssertEqual(deliveries, 0, "full-reload requests must be deferred, not delivered per-event")

        // Fire the single coalesced timer.
        pending?()
        XCTAssertEqual(deliveries, 1, "a burst of full-reload requests collapses to exactly one delivery")
    }

    func testGranularChangesPassThroughImmediately() {
        let coordinator = ProjectFilesystemRefreshCoordinator()
        coordinator.testingSetCoalesceScheduler { _ in /* never fire; proves granular path doesn't use it */ }

        let projectURL = URL(fileURLWithPath: "/tmp/proj-\(UUID().uuidString)")
        var granularDeliveries = 0
        _ = coordinator.register(projectURL: projectURL) { changed in
            if !changed.all.isEmpty { granularDeliveries += 1 }
        }

        coordinator.testingEmitChange(projectURL: projectURL, changedPaths: granular("/tmp/a"))
        coordinator.testingEmitChange(projectURL: projectURL, changedPaths: granular("/tmp/b"))
        XCTAssertEqual(granularDeliveries, 2, "granular deliveries pass through immediately, unbatched")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter ProjectFilesystemRefreshCoordinatorDebounceTests`
Expected: FAIL — `value of type 'ProjectFilesystemRefreshCoordinator' has no member 'testingSetCoalesceScheduler'`.

- [ ] **Step 3: Implement coalescing in the coordinator**

In `ProjectFilesystemRefreshCoordinator.swift`, add stored state near the other private vars (after `subscriptionsByID`):

```swift
    /// Scheduler used to defer a coalesced full-reload delivery. Default uses a real
    /// timer; tests inject a synchronous capture. The closure must eventually invoke
    /// its argument on the main actor.
    private var coalesceScheduler: (@escaping @MainActor () -> Void) -> Void = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated { work() }
        }
    }
    /// Project keys with a full-reload delivery already scheduled (dedup the storm).
    private var pendingFullReloadKeys: Set<String> = []
```

Add the test hook (place with the other `testing…` methods):

```swift
    func testingSetCoalesceScheduler(_ scheduler: @escaping (@escaping @MainActor () -> Void) -> Void) {
        coalesceScheduler = scheduler
    }
```

Change `fanOut` to route full-reload requests (empty `nonSidecar` AND empty `all`) through the coalescer, while passing everything else straight through:

```swift
    private func fanOut(projectKey: String, changedPaths: FileSystemWatcher.ChangedPaths) {
        guard watchersByProjectKey[projectKey] != nil else { return }

        let isFullReloadRequest = changedPaths.nonSidecar.isEmpty && changedPaths.all.isEmpty
        if isFullReloadRequest {
            // Collapse a storm of MustScanSubDirs full-reload requests into one
            // trailing-edge delivery per project.
            guard !pendingFullReloadKeys.contains(projectKey) else { return }
            pendingFullReloadKeys.insert(projectKey)
            coalesceScheduler { [weak self] in
                guard let self else { return }
                self.pendingFullReloadKeys.remove(projectKey)
                self.deliver(projectKey: projectKey, changedPaths: FileSystemWatcher.ChangedPaths(nonSidecar: [], all: []))
            }
            return
        }
        deliver(projectKey: projectKey, changedPaths: changedPaths)
    }

    private func deliver(projectKey: String, changedPaths: FileSystemWatcher.ChangedPaths) {
        guard let projectWatcher = watchersByProjectKey[projectKey] else { return }
        for handler in projectWatcher.handlers.values {
            handler(changedPaths)
        }
    }
```

(The old `fanOut` body that looped over handlers is now `deliver`; `testingEmitChange` still calls `fanOut`, so tests exercise the coalescing path.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path . --skip-update --filter ProjectFilesystemRefreshCoordinatorDebounceTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run any existing coordinator tests for regressions**

Run: `swift test --package-path . --skip-update --filter ProjectFilesystemRefreshCoordinator`
Expected: all pass (existing tests use `testingEmitChange` with granular paths, which still pass through immediately).

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Services/ProjectFilesystemRefreshCoordinator.swift Tests/LungfishAppTests/ProjectFilesystemRefreshCoordinatorDebounceTests.swift
git commit -m "perf(sidebar): coalesce MustScanSubDirs full-reload storm to one delivery"
```

- [ ] **Step 7: HANDOFF — user re-captures the live signpost stream**

Provide the user this recipe and PAUSE for confirmation:

> Rebuild and relaunch the debug app, open the same `/Volumes/iWES_WNPRC` project with the ONT job running, then run:
> `log stream --signpost --predicate 'subsystem == "com.lungfish.app"' --style compact | grep -E "Filesystem.FullReload|Sidebar.Delete"`
> Expect: `Filesystem.FullReload` now fires at most ~3×/sec → coalesced to roughly once per debounce window (not 1–2/sec sustained). Then press delete on a folder; the `Sidebar.Delete` interval should now appear promptly (dialog not blocked).

---

## Task 3: Verify the delete dialog is no longer blocked (regression test)

**Files:**
- Test: `Tests/LungfishAppTests/ProjectFilesystemRefreshCoordinatorDebounceTests.swift` (add one test)

This locks in the user-visible contract: a burst of full-reload requests must not produce one handler call per event (which is what blocked the main thread).

- [ ] **Step 1: Write the failing test**

```swift
    func testStormDoesNotCallHandlerPerEvent() {
        let coordinator = ProjectFilesystemRefreshCoordinator()
        var pending: (() -> Void)?
        coordinator.testingSetCoalesceScheduler { work in pending = work }

        let projectURL = URL(fileURLWithPath: "/tmp/proj-\(UUID().uuidString)")
        var handlerCalls = 0
        _ = coordinator.register(projectURL: projectURL) { _ in handlerCalls += 1 }

        // 100 MustScanSubDirs events (the storm) before the timer fires.
        for _ in 0..<100 {
            coordinator.testingEmitChange(projectURL: projectURL, changedPaths: FileSystemWatcher.ChangedPaths(nonSidecar: [], all: []))
        }
        XCTAssertEqual(handlerCalls, 0, "no synchronous per-event handler calls during the storm")
        pending?()
        XCTAssertEqual(handlerCalls, 1, "the entire storm yields a single reload")
    }
```

- [ ] **Step 2: Run test to verify it passes** (the Task 2 implementation already satisfies it)

Run: `swift test --package-path . --skip-update --filter testStormDoesNotCallHandlerPerEvent`
Expected: PASS. (If it FAILS, the coalescing in Task 2 is wrong — fix Task 2 before continuing.)

- [ ] **Step 3: Commit**

```bash
git add Tests/LungfishAppTests/ProjectFilesystemRefreshCoordinatorDebounceTests.swift
git commit -m "test(sidebar): lock in that a full-reload storm yields a single reload"
```

---

## Task 4: Move the directory scan off the main thread

**TRACE GATE:** Apply after Task 2's re-capture (Step 7). If coalescing alone makes delete feel responsive AND `Filesystem.FullReload` durations are small, this is optional polish — still worth doing for network volumes, but confirm with the user whether to proceed. If a single `Filesystem.FullReload` is itself long (hundreds of ms on the network mount), this is required.

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` (`reloadFromFilesystem`, `buildRootItems`)
- Test: `Tests/LungfishAppTests/SidebarReloadOffMainTests.swift`

Design: `buildRootItems(from:)` (the recursive, network-slow scan) must run off the main actor; the model swap (`rootItems = …`), `reloadOutlineView()`, expansion/selection restore, and `scheduleUniversalSearchRebuild()` stay on `@MainActor`. Per binding rules, hop back with `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { … } }`. `buildRootItems` must be made callable off the actor (it reads the filesystem, not view state — confirm it touches no `@MainActor` UI; if it does, extract the pure scan into a `nonisolated static` helper that returns `[SidebarItem]`).

- [ ] **Step 1: Inspect `buildRootItems` for main-actor dependencies**

Run: `grep -n -A40 "private func buildRootItems" Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
Confirm whether its body references `outlineView`, `self`-mutable view state, or only filesystem + pure `SidebarItem` construction. If it is pure (filesystem → `[SidebarItem]`), extract it to:

```swift
    nonisolated private static func scanRootItems(from projectURL: URL) -> [SidebarItem]
```

moving the existing logic verbatim, and have the instance `buildRootItems(from:)` call `Self.scanRootItems(from:)`. If it references view state, STOP and report — the off-main move needs a design decision (escalate).

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class SidebarReloadOffMainTests: XCTestCase {
    func testReloadCompletesAndPopulatesFromTempProject() throws {
        // Build a tiny on-disk project: two top-level folders.
        let root = try makeTempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Imports"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assemblies"), withIntermediateDirectories: true)

        let controller = SidebarViewController()
        controller.loadViewIfNeeded()

        let done = expectation(description: "reload finished")
        controller.reloadFromFilesystemForTesting(projectURL: root) { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertGreaterThanOrEqual(controller.rootItemsForTesting.count, 2)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sbtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
```

Note: `reloadFromFilesystemForTesting(projectURL:completion:)` and `rootItemsForTesting` are test surface added in Step 4. Check `Tests/LungfishAppTests/` for an existing `SidebarViewController` fixture/helper first and reuse it if present.

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter SidebarReloadOffMainTests`
Expected: FAIL — missing `reloadFromFilesystemForTesting`.

- [ ] **Step 4: Make the scan off-main and add the completion-capable path**

Refactor `reloadFromFilesystem(notifyUnchangedSelectionRefresh:)` so the scan runs off-main and reconciliation returns to the main actor. The structure:

```swift
    private func reloadFromFilesystem(notifyUnchangedSelectionRefresh: Bool, completion: (() -> Void)? = nil) {
        let reloadSignpost = PerfSignpost.filesystem.begin("Filesystem.FullReload")
        guard let projectURL = projectURL else {
            rootItems = []
            reloadOutlineView()
            PerfSignpost.filesystem.end("Filesystem.FullReload", reloadSignpost)
            completion?()
            return
        }

        // Capture UI state on the main actor BEFORE going off-main.
        let selectedURLs = selectedItems().compactMap { $0.url?.standardizedFileURL }
        let expandedURLs = saveExpandedItemURLs()
        let shouldApplyInitialExpansionDefaults = rootItems.isEmpty

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = Self.scanRootItems(from: projectURL)   // off-main, network-slow part
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.applyReloadedRootItems(
                        scanned,
                        selectedURLs: selectedURLs,
                        expandedURLs: expandedURLs,
                        shouldApplyInitialExpansionDefaults: shouldApplyInitialExpansionDefaults,
                        notifyUnchangedSelectionRefresh: notifyUnchangedSelectionRefresh
                    )
                    PerfSignpost.filesystem.end("Filesystem.FullReload", reloadSignpost)
                    completion?()
                }
            }
        }
    }
```

Extract the post-scan main-actor work (everything currently after `rootItems = buildRootItems(...)`: `reloadOutlineView()`, expansion defaults, `restoreExpandedItemURLs`, `restoreSelection`, the selection-change propagation block, `scheduleUniversalSearchRebuild()`) into:

```swift
    private func applyReloadedRootItems(
        _ scanned: [SidebarItem],
        selectedURLs: [URL],
        expandedURLs: Set<URL>,
        shouldApplyInitialExpansionDefaults: Bool,
        notifyUnchangedSelectionRefresh: Bool
    ) {
        let selectedURLSet = Set(selectedURLs)
        suppressSelectionCallbacks = true
        rootItems = scanned
        reloadOutlineView()
        if shouldApplyInitialExpansionDefaults {
            for item in rootItems where item.type == .folder { outlineView.expandItem(item) }
        }
        restoreExpandedItemURLs(expandedURLs)
        restoreSelection(urls: selectedURLs)
        suppressSelectionCallbacks = false
        let restoredItems = selectedItems()
        let restoredURLSet = Set(restoredItems.compactMap { $0.url?.standardizedFileURL })
        if restoredURLSet != selectedURLSet {
            if !selectedURLSet.isEmpty && restoredItems.isEmpty {
                sidebarLogger.debug("reloadFromFilesystem: Selection temporarily unavailable after refresh, preserving active content")
            } else {
                handleSelectionChange(restoredItems, source: "reloadFromFilesystem")
            }
        } else if notifyUnchangedSelectionRefresh, !restoredItems.isEmpty {
            selectionDelegate?.sidebarDidRefreshSelectedItems(restoredItems)
        }
        let itemCount = rootItems.reduce(0) { $0 + countItems(in: $1) }
        sidebarLogger.info("reloadFromFilesystem: Sidebar updated with \(itemCount) items")
        scheduleUniversalSearchRebuild()
    }
```

Add the test hooks:

```swift
    func reloadFromFilesystemForTesting(projectURL: URL, completion: @escaping () -> Void) {
        self.projectURL = projectURL
        reloadFromFilesystem(notifyUnchangedSelectionRefresh: false, completion: completion)
    }
    var rootItemsForTesting: [SidebarItem] { rootItems }
```

(Keep the existing public `reloadFromFilesystem()` → `reloadFromFilesystem(notifyUnchangedSelectionRefresh: true)` overload working by adding the `completion: nil` default.)

- [ ] **Step 5: Run tests**

Run: `swift test --package-path . --skip-update --filter SidebarReloadOffMainTests`
Expected: PASS.

- [ ] **Step 6: Run the sidebar suite**

Run: `swift test --package-path . --skip-update --filter Sidebar`
Expected: fully green (no Sidebar tests are in the known-9).

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift Tests/LungfishAppTests/SidebarReloadOffMainTests.swift
git commit -m "perf(sidebar): run filesystem scan off-main, reconcile on MainActor"
```

- [ ] **Step 8: HANDOFF — user re-captures** to confirm the main thread is no longer blocked during reloads (no `Filesystem.FullReload` main-thread hang; delete dialog instant even mid-churn).

---

## Task 5: Full-suite regression gate + results note

- [ ] **Step 1: Lock free?**

Run: `ps aux | grep -E "swift-(build|test)|xcodebuild" | grep -v grep || echo FREE`
Expected: `FREE`

- [ ] **Step 2: Full test suite**

Run: `swift test --package-path . --skip-update`
Expected: GREEN per the baseline rule (XCTest failures ⊆ the known 9; swift-testing = 0). Investigate ANY other failure before closing.

- [ ] **Step 3: Update the diagnosis report with results**

Append a "Results" section to `docs/reports/2026-06-09-sidebar-delete-diagnosis.md`: the before (1–2 reloads/sec, 30s+ to dialog) vs after (coalesced reloads, dialog prompt) measured from the live signpost captures, and which tasks were applied vs gated-out.

- [ ] **Step 4: Commit**

```bash
git add docs/reports/2026-06-09-sidebar-delete-diagnosis.md
git commit -m "docs: results for watcher reload-storm fix"
```

- [ ] **Step 5: Integration** via the finishing-a-development-branch skill (merge / PR / keep). Then return to the broad sweep: the next anchor targets (menu validation, viewport refresh) get their own signpost regions + trace-gated tasks.

---

## Scope decisions (re: "robust watcher" choice)

The user chose the broad "robust watcher" option (debounce + off-main + incremental).
Two of the four diagnosis candidates are intentionally handled or deferred:

- **Incremental `applySubtreeDiff` instead of full rebuild on `MustScanSubDirs`:**
  NOT given its own task. Reason: the existing `updateSidebar` already uses
  `applySubtreeDiff` for granular changes, but **falls back to full reload for
  root-level / `Analyses/` / new-top-level changes** (`SidebarViewController.swift:899-915`).
  The reported trigger (ONT job) writes into `Analyses/`, so an incremental path would
  hit that fallback anyway. Debounce (Task 2) + off-main scan (Task 4) address the
  actual main-thread block. If, after Task 4, a future trace shows `MustScanSubDirs`
  reloads are still individually too costly on non-Analyses changes, add an
  incremental-diff task then — it would be additive, not a rewrite.
- **Network-volume-specific throttling:** intentionally omitted. The Task 2 debounce is
  volume-agnostic and fixes the storm whether it originates from a network mount or
  local churn, so a volume-type special case would add branching for no additional
  user-visible benefit.

This keeps the fix focused on what the trace proved while leaving clean extension
points. If the user wants the incremental-diff task included up front, add it between
Tasks 4 and 5.

## Notes

- The original Phase-1 sidebar-delete tasks (surgical removal, width memoization, single-pass lookup, off-main trash) in `2026-06-09-responsiveness-sweep.md` are **deprioritized** — the trace showed `performDelete` is not the bottleneck. They remain valid minor improvements; revisit only if a future trace implicates the delete path itself.
- `PerfSignpost.sidebar` (delete signposts) stays in place; this plan adds `PerfSignpost.filesystem` for the reload path.
