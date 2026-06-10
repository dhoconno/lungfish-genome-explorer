# Responsiveness Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the app feel snappy on common interactions, starting with sidebar deletion, by instrumenting hot paths with `os_signpost` and fixing only the bottlenecks that captured Instruments traces confirm.

**Architecture:** Add one shared `PerfSignpost` helper to the kernel (`LungfishKit`), wire signpost intervals around the sidebar-delete path, then apply trace-gated fixes (surgical outline removal, cached sidebar width, single-pass tree lookup, off-main filesystem trash). Profiling is the arbiter: the user captures traces, the implementer applies the fix whose hypothesis the trace confirms.

**Tech Stack:** Swift 6.2, macOS 26, `@MainActor` + strict concurrency, SwiftPM, `os` (`OSSignposter`/`Logger`), `NSOutlineView`, XCTest.

---

## Profile-first contract (read before executing)

This plan is **profile-gated**. Phase 0 (instrumentation) executes unconditionally.
Every task in Phase 1 begins with a **TRACE GATE**: do not apply the fix until the
user has provided an Instruments trace whose named `Sidebar.Delete` region confirms
the specific hypothesis. If a trace refutes a hypothesis, **skip that task** and note
it in the plan. Do not optimize on speculation.

## Build/test conventions (binding — from project memory)

- Build/test this worktree WITHOUT `cd`-only tricks: use
  `swift test --package-path <worktree> --skip-update` /
  `swift build --package-path <worktree> --skip-update`. `swift` has no `-C` flag.
- `--skip-update` always (offline; avoids the `testSRASearch` NCBI flake).
- **Serialize all swift invocations** — one `.build/.lock` per checkout. Before any
  build/test, confirm no foreign `swift-build`/`swift-test`/`xcodebuild` is running
  (`ps aux | grep -E "swift-(build|test)|xcodebuild" | grep -v grep`). A waiter can be
  killed (exit 144, empty output) — that is lock contention, not a test failure.
- **Green-bar baseline:** GREEN iff XCTest failures ⊆ the known 9 environmental
  failures (6 `GenotypeRealBundleSmokeTests`, 2 `ZhangArtifactCanaryTests`,
  1 `VCFRobustnessTests.testAllRealVCFsFromDownloads`) AND swift-testing failures = 0.
- **Background→MainActor:** any work moved off-main keeps model mutation + UI updates
  on `@MainActor`. Never `Task { @MainActor in }` from GCD, never bare
  `DispatchQueue.main.async` touching `@MainActor` state. Use
  `DispatchQueue.global().async { ...; DispatchQueue.main.async { [weak self] in
  MainActor.assumeIsolated { ... } } }`.

## File structure

| File | Responsibility | Action |
| --- | --- | --- |
| `Package.swift` | Add a new `LungfishKitTests` test target (the kernel currently has none). | Modify |
| `Sources/LungfishKit/PerfSignpost.swift` | Shared signpost helper: named `OSSignposter` handles + interval begin/end. The sweep's one piece of shared infra. | Create |
| `Tests/LungfishKitTests/PerfSignpostTests.swift` | Unit tests for the helper's API (state lifecycle, naming). | Create |
| `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift` | `performDelete` / `removeItemFromSidebar` / `findParent`. Add signposts; later, surgical removal + single-pass lookup. | Modify |
| `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` | `reloadOutlineView` / `recommendedSidebarWidth` / `maxLabelWidth`. Add signpost; later, width cache. | Modify |
| `Tests/LungfishAppTests/SidebarDeletePerformanceTests.swift` | Regression tests for the delete-refresh contract (surgical removal, width-cache invalidation). | Create |

Verified target layout (2026-06-09): `LungfishKit` has **no** test target (all leaf
test targets depend on it, but there is no `LungfishKitTests`). App tests live in
`Tests/LungfishAppTests` (NOT `LungfishAppUITests`). Task 1 adds the
`LungfishKitTests` target to `Package.swift`.

---

## Phase 0 — Instrumentation (executes unconditionally)

### Task 0: Verify clean baseline build

**Files:** none (baseline only).

- [ ] **Step 1: Confirm no foreign swift process holds the lock**

Run: `ps aux | grep -E "swift-(build|test)|xcodebuild" | grep -v grep || echo FREE`
Expected: `FREE`

- [ ] **Step 2: Build the worktree offline**

Run: `swift build --package-path . --skip-update`
Expected: `Build complete!` (cold build is slow; this is the baseline we reuse).

If the build fails for reasons unrelated to our (zero) changes, STOP and report —
do not proceed onto instrumentation on a red baseline.

---

### Task 1: Create the `PerfSignpost` kernel helper

**Files:**
- Modify: `Package.swift` (add `LungfishKitTests` test target)
- Create: `Sources/LungfishKit/PerfSignpost.swift`
- Test: `Tests/LungfishKitTests/PerfSignpostTests.swift`

- [ ] **Step 0: Add a `LungfishKitTests` target to `Package.swift`**

The kernel has no test target. Immediately after the `LungfishKit` `.target(...)`
block (the one with `path: "Sources/LungfishKit"`, around line 198) and before the
`// MARK: - LungfishTwelveSUI` comment, insert:

```swift
        .testTarget(
            name: "LungfishKitTests",
            dependencies: ["LungfishKit"],
            path: "Tests/LungfishKitTests"
        ),
```

Create the directory: `mkdir -p Tests/LungfishKitTests`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishKit

final class PerfSignpostTests: XCTestCase {
    func testIntervalBeginReturnsActiveStateThatCanEnd() {
        // The helper must hand back a state we can later end, exercising the
        // begin/end pairing without needing Instruments attached.
        let signpost = PerfSignpost(category: "Test")
        let state = signpost.begin("UnitInterval")
        // Ending must not trap and must accept the state we were given.
        signpost.end("UnitInterval", state)
    }

    func testEmitEventDoesNotTrap() {
        let signpost = PerfSignpost(category: "Test")
        signpost.event("PointEvent")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter PerfSignpostTests`
Expected: FAIL — `cannot find 'PerfSignpost' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import os
import LungfishCore

/// Lightweight wrapper around `OSSignposter` for marking responsiveness-critical
/// regions so Instruments traces self-label. Effectively free when no trace is
/// recording. Shared kernel infra for the responsiveness sweep.
///
/// Usage:
/// ```swift
/// let state = PerfSignpost.sidebar.begin("Sidebar.Delete")
/// defer { PerfSignpost.sidebar.end("Sidebar.Delete", state) }
/// ```
public struct PerfSignpost: Sendable {
    private let signposter: OSSignposter

    /// - Parameter category: Instruments category, e.g. "Sidebar".
    public init(category: String) {
        self.signposter = OSSignposter(
            subsystem: LogSubsystem.app,
            category: category
        )
    }

    /// Begin an interval. Returns the state that must be passed to `end`.
    /// The name must be a static string (OSSignposter requirement).
    public func begin(_ name: StaticString) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        return signposter.beginInterval(name, id: id)
    }

    /// End a previously-begun interval.
    public func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// Emit a single point-of-interest event.
    public func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}

public extension PerfSignpost {
    /// Shared instance for sidebar interactions.
    static let sidebar = PerfSignpost(category: "Sidebar")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path . --skip-update --filter PerfSignpostTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishKit/PerfSignpost.swift Tests/LungfishKitTests/PerfSignpostTests.swift
git commit -m "feat(kit): add PerfSignpost helper for responsiveness profiling"
```

---

### Task 2: Wire signpost regions around the sidebar-delete path

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift` (`performDelete`, ~line 507)
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` (`reloadOutlineView`, ~line 506)

This task adds **only** signpost begin/end calls — no behavior change. There is no
unit test for signpost emission (it requires Instruments); correctness is verified by
the build succeeding and by the region appearing in a trace (Step 6, manual).

- [ ] **Step 1: Confirm `import os` availability in the data-source file**

Run: `grep -n "^import" Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift`
If `import LungfishKit` is absent, it will be added in Step 2. `PerfSignpost` is
public in `LungfishKit`, which `LungfishApp` already imports elsewhere.

- [ ] **Step 2: Wrap the whole `performDelete` body in `Sidebar.Delete`**

In `performDelete(items:includingDependentURLs:)`, immediately after the
`canWriteSidebarProjectOutputs` guard returns true (just before
`let planner = ProjectDeletionPlanner()`), insert:

```swift
        let deleteSignpost = PerfSignpost.sidebar.begin("Sidebar.Delete")
        defer { PerfSignpost.sidebar.end("Sidebar.Delete", deleteSignpost) }
```

Ensure `import LungfishKit` is present at the top of the file (add it next to the
existing imports if missing).

- [ ] **Step 3: Wrap the filesystem-trash loop in `Delete.FilesystemTrash`**

Immediately before the `for url in deletionURLs {` loop, insert:

```swift
        let trashSignpost = PerfSignpost.sidebar.begin("Delete.FilesystemTrash")
```

Immediately after that loop's closing brace (before the
`for item in items where item.url == nil {` block), insert:

```swift
        PerfSignpost.sidebar.end("Delete.FilesystemTrash", trashSignpost)
```

- [ ] **Step 3b: Wrap the model-mutation phase in `Delete.ModelMutation`**

In Phase 0 the model mutation is still interleaved with the trash loop (the
`removeItemFromSidebar(item)` call at the end of each iteration). Wrap the
*aggregate* model-mutation work by beginning `Delete.ModelMutation` immediately
after the `Delete.FilesystemTrash` end (Step 3) — i.e. just before the
`for item in items where item.url == nil {` block — and ending it immediately before
`reloadOutlineView()`:

```swift
        let modelSignpost = PerfSignpost.sidebar.begin("Delete.ModelMutation")
```

then before `reloadOutlineView()`:

```swift
        PerfSignpost.sidebar.end("Delete.ModelMutation", modelSignpost)
```

(After Task 6 moves trashing off-main, model mutation becomes cleanly separated and
this region tightens automatically. The region exists now so the first trace already
distinguishes model-walk cost from outline-refresh cost.)

- [ ] **Step 4: Wrap the notification fan-out in `Delete.Notify`**

Immediately before `NotificationCenter.default.post(name: .sidebarItemsDeleted, ...)`
near the end of `performDelete`, insert:

```swift
        let notifySignpost = PerfSignpost.sidebar.begin("Delete.Notify")
        defer { PerfSignpost.sidebar.end("Delete.Notify", notifySignpost) }
```

(The `defer` fires at function scope end, immediately after the post — acceptable
since the post is the last statement.)

- [ ] **Step 5: Wrap `reloadOutlineView` body in `Delete.OutlineRefresh`**

In `SidebarViewController.swift`, change `reloadOutlineView()` from:

```swift
    func reloadOutlineView() {
        outlineView.reloadData()
        postPreferredSidebarWidthIfNeeded()
    }
```

to:

```swift
    func reloadOutlineView() {
        let state = PerfSignpost.sidebar.begin("Delete.OutlineRefresh")
        defer { PerfSignpost.sidebar.end("Delete.OutlineRefresh", state) }
        outlineView.reloadData()
        postPreferredSidebarWidthIfNeeded()
    }
```

Ensure `import LungfishKit` is present at the top of `SidebarViewController.swift`
(add if missing).

- [ ] **Step 6: Build (no foreign lock holder first)**

Run: `ps aux | grep -E "swift-(build|test)|xcodebuild" | grep -v grep || echo FREE`
Expected: `FREE`
Run: `swift build --package-path . --skip-update`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift
git commit -m "perf(sidebar): add os_signpost regions around the delete path"
```

- [ ] **Step 8: HANDOFF — user captures the first trace**

Provide the user this capture recipe and PAUSE for the trace before Phase 1:

> 1. Build & launch the debug app from this worktree.
> 2. Open a representative project (small is fine — that is where the lag shows).
> 3. In Instruments, choose the **Time Profiler** template and add the
>    **os_signpost** instrument (File ▸ Recording Options, or the `+` in the
>    instrument list). Optionally add **Hangs**.
> 4. Record, then in the app select one or more sidebar items and delete them
>    (Move to Trash). Do it a few times. Stop recording.
> 5. In the os_signpost track, find the `Sidebar.Delete` interval and note the
>    duration of it and its children (`Delete.OutlineRefresh`,
>    `Delete.FilesystemTrash`, `Delete.Notify`). Save the `.trace` and share it,
>    or screenshot the signpost summary + the Time Profiler heaviest-stack for the
>    `Sidebar.Delete` window.

---

## Phase 1 — Trace-gated sidebar-delete fixes

Apply each task ONLY if its TRACE GATE is satisfied by the captured trace. Order is
by suspected impact; re-order to match what the trace actually shows.

**Hypothesis 5 (notification fan-out) is measure-only here.** The `Delete.Notify`
region added in Task 2 quantifies it. If a trace shows `.sidebarItemsDeleted`
observers doing expensive synchronous refresh work, author a dedicated fix task at
that point (most likely: make the heaviest observer's response incremental, mirroring
Task 3). It is intentionally not pre-written, since the cost and the culprit observer
are unknown until measured.

**Shared test hook used by Tasks 5 and 6 — `deleteItemsForTesting`.** Both tasks
drive deletion from a test without the trash-confirmation `NSAlert`. Introduce it
once, in Task 5 Step 3, by extracting the model-mutation + dispatch core of
`performDelete` (everything after the confirmation alert resolves) into an
`internal func applyDeletion(of items: [SidebarItem], includingDependentURLs:
[URL] = [])`, and have `performDelete`'s alert handlers call it. Then:

```swift
    func deleteItemsForTesting(_ items: [SidebarItem]) {
        applyDeletion(of: items)
    }
```

Task 6's async test depends on this same hook plus `onDeleteCompletedForTesting`
(Task 6 Step 4). Until Task 6, `applyDeletion` is synchronous; Task 6 makes its
trash phase async, at which point `onDeleteCompletedForTesting` fires on completion.

### Task 3: Surgical outline removal instead of full `reloadData()`

**TRACE GATE:** Apply only if `Delete.OutlineRefresh` is a material fraction of
`Sidebar.Delete` (e.g. tens of ms or a visible main-thread hang) AND the Time
Profiler attributes it to `NSOutlineView.reloadData` / cell re-creation.

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift`
  (`performDelete` ~line 578-587, `removeItemFromSidebar` ~line 638, `findParent` ~line 668)
- Test: `Tests/LungfishAppTests/SidebarDeletePerformanceTests.swift`

Background: the surgical primitive already exists and is proven in
`SidebarViewController.applySubtreeDiff` (line 987 uses
`outlineView.removeItems(at:inParent:withAnimation:)`). This task makes the delete
path use the same primitive instead of `reloadOutlineView()`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import LungfishApp

@MainActor
final class SidebarDeletePerformanceTests: XCTestCase {
    /// After removing an item from the model, a surgical removal must update the
    /// outline's row count by exactly the number removed — without a full reload.
    func testSurgicalRemovalUpdatesRowCountByDelta() throws {
        let controller = try makeControllerWithRootItems(count: 5)
        controller.loadViewIfNeeded()
        controller.reloadOutlineView() // initial population
        let before = controller.outlineViewRowCountForTesting

        let victim = try XCTUnwrap(controller.rootItemsForTesting.first)
        controller.removeItemFromSidebarSurgically(victim)

        let after = controller.outlineViewRowCountForTesting
        XCTAssertEqual(before - after, 1, "exactly one row should be removed")
        XCTAssertFalse(
            controller.rootItemsForTesting.contains { $0 === victim },
            "model must no longer contain the removed item"
        )
    }
}
```

Note: `makeControllerWithRootItems`, `outlineViewRowCountForTesting`,
`rootItemsForTesting`, and `removeItemFromSidebarSurgically` are test-support
surface added in Steps 3-4. If a sidebar test helper already exists in the target,
reuse it instead of adding `makeControllerWithRootItems` (check
`Tests/LungfishAppTests/` for existing `SidebarViewController` test fixtures
first; repeat the helper here only if none exists).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter SidebarDeletePerformanceTests`
Expected: FAIL — `value of type 'SidebarViewController' has no member 'removeItemFromSidebarSurgically'`.

- [ ] **Step 3: Add the surgical removal method**

In `SidebarViewController+OutlineDataSource.swift`, add:

```swift
    /// Removes `item` from the model AND the outline using a surgical
    /// `removeItems(at:inParent:)` call — no full `reloadData()`. Mirrors the
    /// diffing primitive in `applySubtreeDiff`. Must run on the main actor.
    func removeItemFromSidebarSurgically(_ item: SidebarItem) {
        let parent = findParent(of: item)
        let siblings = parent?.children ?? rootItems
        guard let index = siblings.firstIndex(where: { $0 === item }) else {
            // Model/outline already out of sync — fall back to model-only removal.
            removeItemFromSidebar(item)
            return
        }
        if parent != nil {
            parent?.children.remove(at: index)
        } else {
            rootItems.remove(at: index)
        }
        outlineView.removeItems(
            at: IndexSet(integer: index),
            inParent: parent,
            withAnimation: []
        )
    }
```

- [ ] **Step 4: Add minimal test-support surface**

In `SidebarViewController+OutlineDataSource.swift` (or a `#if DEBUG` test-support
extension consistent with the file's existing conventions — check whether the
target already exposes `…ForTesting` accessors and match that style):

```swift
    var outlineViewRowCountForTesting: Int { outlineView.numberOfRows }
    var rootItemsForTesting: [SidebarItem] { rootItems }
```

If `makeControllerWithRootItems` has no existing equivalent, add a minimal builder
in the test file that constructs a `SidebarViewController`, assigns `count` plain
`.file`-type `SidebarItem`s to `rootItems`, and returns it. Match how existing
sidebar tests instantiate the controller.

- [ ] **Step 5: Switch `performDelete` to surgical removal**

In `performDelete`, replace the two model-removal call sites plus the trailing full
reload. Change:

```swift
            if let item {
                removeItemFromSidebar(item)
            }
        }

        for item in items where item.url == nil {
            removeItemFromSidebar(item)
        }

        reloadOutlineView()
```

to:

```swift
            if let item {
                removeItemFromSidebarSurgically(item)
            }
        }

        for item in items where item.url == nil {
            removeItemFromSidebarSurgically(item)
        }

        // Width may have changed now that rows are gone; update without a full reload.
        postPreferredSidebarWidthIfNeeded()
```

Note: `postPreferredSidebarWidthIfNeeded` is `private` in `SidebarViewController`.
Since `performDelete` lives in the same type's extension in a sibling file, change
`postPreferredSidebarWidthIfNeeded` from `private` to `internal` (drop the
`private`) so the extension can call it. (Task 4 changes its body; this only
changes its access level.)

- [ ] **Step 6: Run tests**

Run: `swift test --package-path . --skip-update --filter SidebarDeletePerformanceTests`
Expected: PASS.

- [ ] **Step 7: Run the broader sidebar suite for regressions**

Run: `swift test --package-path . --skip-update --filter Sidebar`
Expected: all pass except any of the known-9 environmental failures (none are in
Sidebar, so expect fully green here).

- [ ] **Step 8: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift Tests/LungfishAppTests/SidebarDeletePerformanceTests.swift
git commit -m "perf(sidebar): delete via surgical outline removal, no full reload"
```

- [ ] **Step 9: HANDOFF — user re-traces**

Ask the user to repeat the Task 2 Step 8 capture and confirm `Delete.OutlineRefresh`
(now the post-delete `postPreferredSidebarWidthIfNeeded` path) has shrunk and no
main-thread hang remains on delete.

---

### Task 4: Cache recommended sidebar width (stop full-tree remeasure)

**TRACE GATE:** Apply only if, in a trace, `recommendedSidebarWidth` /
`maxLabelWidth` appears as a non-trivial cost during delete (or any mutation) — i.e.
the full-tree font-metric walk shows up in the Time Profiler heaviest stack.

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
  (`postPreferredSidebarWidthIfNeeded` ~line 511, `recommendedSidebarWidth` ~line 526,
  `maxLabelWidth` ~line 532)
- Test: `Tests/LungfishAppTests/SidebarDeletePerformanceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
    /// Width recomputation must be memoized: calling the recommended-width path
    /// twice without an invalidating mutation must not re-walk the tree.
    func testRecommendedWidthIsMemoizedUntilInvalidated() throws {
        let controller = try makeControllerWithRootItems(count: 5)
        controller.loadViewIfNeeded()

        let first = controller.recommendedSidebarWidthForTesting(countingWalk: true)
        let walksAfterFirst = controller.widthWalkCountForTesting

        _ = controller.recommendedSidebarWidthForTesting(countingWalk: true)
        XCTAssertEqual(
            controller.widthWalkCountForTesting, walksAfterFirst,
            "second call must use the cached width, not re-walk"
        )

        controller.invalidateRecommendedWidthCacheForTesting()
        _ = controller.recommendedSidebarWidthForTesting(countingWalk: true)
        XCTAssertEqual(
            controller.widthWalkCountForTesting, walksAfterFirst + 1,
            "after invalidation the walk runs exactly once more"
        )
        XCTAssertGreaterThan(first, 0)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter testRecommendedWidthIsMemoized`
Expected: FAIL — missing `recommendedSidebarWidthForTesting` / `widthWalkCountForTesting`.

- [ ] **Step 3: Add the cache + invalidation**

In `SidebarViewController.swift`, add stored properties near the existing
`lastRecommendedSidebarWidth`:

```swift
    /// Memoized result of `recommendedSidebarWidth()`. Nil means "needs recompute".
    private var cachedRecommendedWidth: CGFloat?
    /// Test-only counter of how many times the full-tree label walk executed.
    private var widthWalkCount = 0
```

Change `recommendedSidebarWidth()` from:

```swift
    private func recommendedSidebarWidth() -> CGFloat {
        let contentWidth = maxLabelWidth(in: rootItems, depth: 0)
        let estimated = contentWidth + 40
        return min(max(estimated, 220), 720)
    }
```

to:

```swift
    private func recommendedSidebarWidth() -> CGFloat {
        if let cached = cachedRecommendedWidth { return cached }
        widthWalkCount += 1
        let contentWidth = maxLabelWidth(in: rootItems, depth: 0)
        let estimated = contentWidth + 40
        let clamped = min(max(estimated, 220), 720)
        cachedRecommendedWidth = clamped
        return clamped
    }

    /// Invalidate the memoized width. Call after any mutation that changes which
    /// labels are present (insert, delete, rename).
    func invalidateRecommendedWidthCache() {
        cachedRecommendedWidth = nil
    }
```

- [ ] **Step 4: Invalidate on delete**

In `SidebarViewController+OutlineDataSource.swift` `performDelete`, immediately
before the `postPreferredSidebarWidthIfNeeded()` call added in Task 3 Step 5, insert:

```swift
        invalidateRecommendedWidthCache()
```

Also call `invalidateRecommendedWidthCache()` at the top of `reloadOutlineView()`
(a full reload implies the tree changed), right after the signpost `begin`.

- [ ] **Step 5: Add test-support surface**

```swift
    var widthWalkCountForTesting: Int { widthWalkCount }
    func invalidateRecommendedWidthCacheForTesting() { invalidateRecommendedWidthCache() }
    func recommendedSidebarWidthForTesting(countingWalk: Bool) -> CGFloat {
        recommendedSidebarWidth()
    }
```

- [ ] **Step 6: Run tests**

Run: `swift test --package-path . --skip-update --filter SidebarDeletePerformanceTests`
Expected: PASS (both tests).

- [ ] **Step 7: Run the sidebar suite**

Run: `swift test --package-path . --skip-update --filter Sidebar`
Expected: fully green.

- [ ] **Step 8: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift Tests/LungfishAppTests/SidebarDeletePerformanceTests.swift
git commit -m "perf(sidebar): memoize recommended width, invalidate on mutation"
```

- [ ] **Step 9: HANDOFF — user re-traces** to confirm the `maxLabelWidth` walk no
longer appears on the delete path.

---

### Task 5: Single-pass tree lookup in `performDelete`

**TRACE GATE:** Apply only if `findItem` / `findParent` / `search(in:)` recursion
shows as a non-trivial cost in a delete trace (most likely only with larger trees or
large multi-selection).

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift`
  (`performDelete` ~line 526-532)

- [ ] **Step 1: Write the failing test**

```swift
    /// Deleting N items must resolve each item to its model node without repeated
    /// full-tree scans. We assert behavior (all deleted) under a larger tree as a
    /// guard; the optimization is internal.
    func testDeleteResolvesAllItemsInLargerTree() throws {
        let controller = try makeControllerWithRootItems(count: 200)
        controller.loadViewIfNeeded()
        controller.reloadOutlineView()
        let victims = Array(controller.rootItemsForTesting.prefix(50))

        controller.deleteItemsForTesting(victims)

        XCTAssertEqual(controller.rootItemsForTesting.count, 150)
        for victim in victims {
            XCTAssertFalse(controller.rootItemsForTesting.contains { $0 === victim })
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter testDeleteResolvesAllItemsInLargerTree`
Expected: FAIL — missing `deleteItemsForTesting` (add a thin test hook that calls the
model-mutation portion of `performDelete` without the trash/alert UI; if such a hook
is awkward, gate this test behind a refactor that extracts the model-mutation core of
`performDelete` into a separately-callable `applyDeletion(of:)` method and test that).

- [ ] **Step 3: Build a one-time path→item index for the deletion set**

In `performDelete`, the loop currently calls
`selectedItemsByPath[…] ?? findItem(byPath: …)` twice per URL. Build a single index
covering both selected items and any dependent URLs up front, then look up from it:

```swift
        // One-time index of every model node reachable by standardized path, so the
        // deletion loop is O(tree) once instead of O(tree) per URL.
        var itemsByStandardizedPath: [String: SidebarItem] = selectedItemsByPath
        func indexTree(_ items: [SidebarItem]) {
            for item in items {
                if let path = item.url?.standardizedFileURL.path,
                   itemsByStandardizedPath[path] == nil {
                    itemsByStandardizedPath[path] = item
                }
                indexTree(item.children)
            }
        }
        indexTree(rootItems)
```

Then replace each `selectedItemsByPath[url.standardizedFileURL.path] ?? findItem(byPath: url.standardizedFileURL.path)`
with `itemsByStandardizedPath[url.standardizedFileURL.path]`.

- [ ] **Step 4: Run tests**

Run: `swift test --package-path . --skip-update --filter SidebarDeletePerformanceTests`
Expected: PASS.

- [ ] **Step 5: Run the sidebar suite**

Run: `swift test --package-path . --skip-update --filter Sidebar`
Expected: fully green.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift Tests/LungfishAppTests/SidebarDeletePerformanceTests.swift
git commit -m "perf(sidebar): index tree once for deletion lookup"
```

---

### Task 6: Move filesystem trash off the main thread

**TRACE GATE:** Apply only if `Delete.FilesystemTrash` is a material fraction of
`Sidebar.Delete` in the trace (main-thread time spent in `trashItem`). If trash is
fast in practice, SKIP — moving it off-main adds concurrency complexity for no win.

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift`
  (`performDelete` filesystem loop, ~line 531-581)

Design note: keep model mutation (`removeItemFromSidebarSurgically`) and the
`.sidebarItemsDeleted` post on `@MainActor`. Only the `FileManager.trashItem` calls
move off-main. Per binding rules, hop back with
`DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { … } }`.

- [ ] **Step 1: Write the failing test**

```swift
    /// Trashing happens off-main but the model/outline update still lands, and an
    /// already-deleted error is tolerated. Uses a temp directory with real files.
    func testDeleteRemovesRealFilesAndUpdatesModel() throws {
        let tmp = try makeTempProjectWithFiles(count: 3) // returns (controller, urls)
        let controller = tmp.controller
        controller.loadViewIfNeeded()
        controller.reloadOutlineView()

        let expectation = expectation(description: "model updated after async trash")
        controller.onDeleteCompletedForTesting = { expectation.fulfill() }
        controller.deleteItemsForTesting(controller.rootItemsForTesting)

        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(controller.rootItemsForTesting.isEmpty)
        for url in tmp.urls {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path . --skip-update --filter testDeleteRemovesRealFilesAndUpdatesModel`
Expected: FAIL — missing `onDeleteCompletedForTesting` / `makeTempProjectWithFiles`.

- [ ] **Step 3: Restructure the trash loop**

Extract the per-URL trash work (the `trashItem` call + sidecar handling + failure
collection, lines ~534-576) into a pure function that takes the URLs and returns
`(succeededURLs, failedItems)`, with NO access to `self` model state:

```swift
    private struct TrashOutcome {
        var succeededURLs: [URL] = []
        var failedItems: [(String, Error)] = []
    }

    /// Pure filesystem work — safe to run off the main actor. Does not touch model.
    private static func trashURLs(
        _ urls: [URL],
        labels: [String: String],
        planner: ProjectDeletionPlanner
    ) -> TrashOutcome {
        var outcome = TrashOutcome()
        for url in urls {
            let label = labels[url.standardizedFileURL.path] ?? url.lastPathComponent
            let sidecars = planner.existingCompanionSidecarURLs(for: url)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                outcome.succeededURLs.append(url)
            } catch {
                if isAlreadyDeletedError(error) {
                    outcome.succeededURLs.append(url)
                } else {
                    outcome.failedItems.append((label, error))
                    continue
                }
            }
            for sidecarURL in sidecars where FileManager.default.fileExists(atPath: sidecarURL.path) {
                do { try FileManager.default.trashItem(at: sidecarURL, resultingItemURL: nil) }
                catch {
                    if !isAlreadyDeletedError(error) {
                        outcome.failedItems.append((sidecarURL.lastPathComponent, error))
                    }
                }
            }
        }
        return outcome
    }
```

Then in `performDelete`, dispatch it off-main and reconcile on main:

```swift
        let labels = Dictionary(uniqueKeysWithValues: deletionURLs.map {
            ($0.standardizedFileURL.path,
             itemsByStandardizedPath[$0.standardizedFileURL.path]?.title ?? $0.lastPathComponent)
        })
        let plannerForTrash = planner
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Self.trashURLs(deletionURLs, labels: labels, planner: plannerForTrash)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    for url in outcome.succeededURLs {
                        if let item = itemsByStandardizedPath[url.standardizedFileURL.path] {
                            self.removeItemFromSidebarSurgically(item)
                        }
                    }
                    for item in items where item.url == nil {
                        self.removeItemFromSidebarSurgically(item)
                    }
                    self.invalidateRecommendedWidthCache()
                    self.postPreferredSidebarWidthIfNeeded()
                    self.presentDeletionFailuresIfNeeded(outcome.failedItems)
                    NotificationCenter.default.post(
                        name: .sidebarItemsDeleted,
                        object: self,
                        userInfo: self.windowScopedUserInfo(["items": deletedItems.isEmpty ? items : deletedItems])
                    )
                    self.onDeleteCompletedForTesting?()
                }
            }
        }
```

Move the existing failure-alert block into a helper
`presentDeletionFailuresIfNeeded(_:)`, and end the `Sidebar.Delete` signpost inside
the main-thread reconciliation (move the `defer` to an explicit
`PerfSignpost.sidebar.end` at the end of the `MainActor.assumeIsolated` block, since
the work is now asynchronous and the function returns before it completes).

- [ ] **Step 4: Add the completion test hook**

```swift
    /// Test-only: fired after the async delete reconciliation completes on main.
    var onDeleteCompletedForTesting: (() -> Void)? {
        get { _onDeleteCompletedForTesting }
        set { _onDeleteCompletedForTesting = newValue }
    }
```

(Back it with a stored `private var _onDeleteCompletedForTesting: (() -> Void)?` on
the controller; in production it stays nil and is a no-op.)

- [ ] **Step 5: Run tests**

Run: `swift test --package-path . --skip-update --filter SidebarDeletePerformanceTests`
Expected: PASS.

- [ ] **Step 6: Run the sidebar suite**

Run: `swift test --package-path . --skip-update --filter Sidebar`
Expected: fully green.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishApp/Views/Sidebar/SidebarViewController+OutlineDataSource.swift Tests/LungfishAppTests/SidebarDeletePerformanceTests.swift
git commit -m "perf(sidebar): trash files off the main thread, reconcile on main"
```

- [ ] **Step 8: HANDOFF — user re-traces** to confirm `Delete.FilesystemTrash` no
longer occupies the main thread and the overall `Sidebar.Delete` main-thread span has
dropped.

---

## Phase 2 — Close out the sidebar-delete target

### Task 7: Full-suite regression gate + results note

- [ ] **Step 1: Confirm lock is free**

Run: `ps aux | grep -E "swift-(build|test)|xcodebuild" | grep -v grep || echo FREE`
Expected: `FREE`

- [ ] **Step 2: Run the full test suite**

Run: `swift test --package-path . --skip-update`
Expected: GREEN per the baseline rule — XCTest failures ⊆ the known 9 environmental
failures, swift-testing failures = 0. Investigate ANY other failure before closing.

- [ ] **Step 3: Write a short results note**

Create `docs/reports/2026-06-09-responsiveness-sweep-sidebar-delete.md` summarizing,
per applied task: the trace-measured before/after for `Sidebar.Delete` and its
children, which hypotheses were confirmed vs. skipped, and the net user-visible win.

- [ ] **Step 4: Commit**

```bash
git add docs/reports/2026-06-09-responsiveness-sweep-sidebar-delete.md
git commit -m "docs: results note for sidebar-delete responsiveness work"
```

- [ ] **Step 5: Decide integration** via the finishing-a-development-branch skill
(merge to main / PR / keep). Then return to the sweep backlog and pick the next
target (sidebar add, sidebar selection, menu validation, or Viewport refresh),
repeating the per-target loop from the spec.

---

## Notes for the next target (not yet planned)

The remaining anchor paths (sidebar add, sidebar selection-change, menu-item
selection/validation, Viewport refresh/switch) each get their own signpost regions
and trace-gated tasks, authored as a fresh plan iteration once this target closes.
`PerfSignpost` is already in place for them; add per-area static instances
(e.g. `PerfSignpost.viewport`, `PerfSignpost.menu`) following the `.sidebar` pattern.
