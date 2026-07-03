# Fable-only GUI Performance Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove perceptible lag from every LGE GUI interaction and keep the app elegant on very large datasets, implemented exclusively with Fable.

**Architecture:** Five sequential, expert-gated phases from low to high risk. Each task follows TDD (failing test → minimal fix → green → commit), preserves the green-bar baseline, and honors the project's background→MainActor dispatch rules. Work happens in the existing worktree `.claude/worktrees/fable-gui-perf-refactor` (branch `worktree-fable-gui-perf-refactor`).

**Tech Stack:** Swift 6.2, AppKit-via-Swift, `@Observable`/`@MainActor`/strict concurrency, SwiftPM, XCTest + swift-testing.

## Global Constraints

- Swift 6.2, macOS 26 Tahoe, Apple Silicon. Strict concurrency; `@MainActor` for all UI.
- **Green-bar baseline (binding):** a run is GREEN iff XCTest failures are a subset of the known 9 environmental failures (6 `GenotypeRealBundleSmokeTests`, 2 `ZhangArtifactCanaryTests`, 1 `VCFRobustnessTests.testAllRealVCFsFromDownloads`) AND swift-testing failures = 0.
- **SwiftPM discipline:** SERIALIZE every `swift build`/`swift test` (single `.build/.lock`; never run two concurrently). Always pass `--skip-update` to stay offline. Build/test the worktree with `--package-path .claude/worktrees/fable-gui-perf-refactor` from the repo root, or run from inside the worktree directory (do NOT `cd` into the original repo root).
- **Background→MainActor dispatch (binding):** NEVER `Task { @MainActor in }` from a GCD background block; NEVER bare `DispatchQueue.main.async` to touch `@MainActor` state; NEVER `await` `@MainActor` from `Task.detached`. For UI callbacks from GCD use `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { ... } }`, or use `async`/`await` with the work isolated to a `nonisolated`/actor context and the commit back on `@MainActor`.
- **Stale-result safety:** any async fetch that can be superseded by a newer user action must be guarded by a generation counter checked before committing results on `@MainActor` (existing pattern: `SequenceViewerView.*FetchGeneration`).
- **Scope:** GUI only (left sidebar, viewports, inspector, menus, dialogs). Do NOT change third-party tool invocations or scientific data-creation/export/provenance behavior.
- **Do NOT re-touch already-landed fixes:** `BatchTableView` 180 ms debounce, `ProjectFilesystemRefreshCoordinator` watcher coalescing, genotype matrix rendering (commit b951cd2f), TaxTriage selection (commit 4d70b6f1).
- **Line numbers in this plan are anchors as of HEAD `5b417cfb`.** Every task's Step 1 is to re-read the current code around the cited symbol and confirm the anti-pattern is still present before editing. If already fixed, mark the task N/A and note it.
- **Commit message trailer (binding):** end every commit body with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Per-Phase Expert Review Gate (binding)

After the last task of each phase, before starting the next phase:

1. Run the full relevant test targets; confirm the green-bar baseline holds.
2. Dispatch three reviewer agents in parallel over the phase's diff (`git diff <phase-start-sha>..HEAD`):
   - `swift-expert` — idiom + concurrency correctness (esp. background→MainActor rules, generation guards).
   - `performance-engineer` — did the change actually remove the cost; any new hot path or regression introduced.
   - `code-reviewer` — correctness, regressions, missing/weak test coverage.
3. Triage findings via superpowers:receiving-code-review (verify before implementing). Fix all blocking findings; iterate the review until all three reviewers report no blocking findings AND the green bar still holds.
4. Only then proceed to the next phase.

A finding is "blocking" if it identifies a correctness bug, a concurrency-rule violation, a functional regression, a missing test for changed behavior, or a change that fails to remove (or worsens) the targeted cost.

---

## Phase 0: Baseline

### Task 0: Establish green baseline in the worktree

**Files:** none (verification only).

- [ ] **Step 1: Confirm worktree + branch**

Run: `git -C .claude/worktrees/fable-gui-perf-refactor branch --show-current`
Expected: `worktree-fable-gui-perf-refactor`

- [ ] **Step 2: Build the worktree offline**

Run: `swift build --package-path .claude/worktrees/fable-gui-perf-refactor --skip-update`
Expected: build succeeds (no errors). Serialize: ensure no other swift process holds `.build/.lock` first (`ps aux | grep swift-`).

- [ ] **Step 3: Run the fast UI-adjacent test targets to capture the baseline**

Run: `swift test --package-path .claude/worktrees/fable-gui-perf-refactor --skip-update --filter LungfishKitTests`
Expected: PASS (0 failures). This is the touch-point suite for Phase 1/3 kernel changes. Record the pass count.

- [ ] **Step 4: Record baseline note (no commit needed)**

Note the LungfishKitTests pass count and confirm the known 9 environmental failures are the only XCTest failures if a broader run is done. This is the reference the phase gates compare against.

---

## Phase 1: Behavior-preserving quick wins

Phase-start SHA: record `git rev-parse HEAD` before Task 1.

### Task 1: Debounce VCF variant browser filter

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/VCFDatasetViewController.swift` (`controlTextDidChange` ~line 357, `applyFilter` ~line 259).
- Test: `Tests/LungfishAppTests/VCFDatasetViewControllerTests.swift` (create).

**Interfaces:**
- Produces: a debounced user-typed filter path on `VCFDatasetViewController`; a `setFilterText(_:)`-style immediate path for tests/state restoration.

Current code: `controlTextDidChange` sets `filterText` then calls `applyFilter()` synchronously on every keystroke; `applyFilter()` filters `allVariants`, calls `classifyVariantType` per element, `applySortOrder()`, then `tableView.reloadData()`.

- [ ] **Step 1: Re-read and confirm the anti-pattern**

Run: read `VCFDatasetViewController.swift` around `controlTextDidChange` and `applyFilter`. Confirm no debounce exists yet. If already debounced, mark N/A.

- [ ] **Step 2: Write the failing test**

Create `Tests/LungfishAppTests/VCFDatasetViewControllerTests.swift`. First, in this same step, read the real `VCFVariant` and `VCFSummary` initializers in `LungfishIO` and the `waitUntil` helper used by `BatchTableViewTests` (`Tests/LungfishKitTests`), then write the test below with the confirmed real initializers substituted for the two `<...>` markers — do not leave the markers in the committed test. The controller exposes displayed state; if `displayedVariants` is not test-visible, add a minimal `@testable`-internal read accessor as part of this task (that accessor is the seam).

```swift
import AppKit
import XCTest
@testable import LungfishApp
import LungfishIO

@MainActor
final class VCFDatasetViewControllerTests: XCTestCase {
    // Replace <make three variants ...> with real VCFVariant inits:
    // chr1:100 A>G, chr2:200 C>T, chr1:150 A>G. Replace <make summary> with a
    // real VCFSummary. Both signatures come from LungfishIO (read them first).

    func testUserFilterInputIsDebounced() async throws {
        let vc = VCFDatasetViewController()
        _ = vc.view // force loadView
        let variants = /* <make three variants> */ [VCFVariant]()
        vc.configure(summary: /* <make summary> */ , variants: variants)

        let field = try XCTUnwrap(vc.view.firstDescendant(of: NSSearchField.self))
        field.stringValue = "chr1"
        field.sendAction(field.action, to: field.target)

        // Synchronous: still all 3 (debounce not yet fired).
        XCTAssertEqual(vc.displayedVariantCountForTesting, 3)

        try await waitUntil { vc.displayedVariantCountForTesting == 2 }
        XCTAssertEqual(vc.displayedVariantCountForTesting, 2)
    }
}
```

Add `var displayedVariantCountForTesting: Int { displayedVariants.count }` (internal, `@testable`) to the controller in this task. Add a `firstDescendant(of:)` / `waitUntil` helper to `LungfishAppTests` if absent by copying the `LungfishKitTests` support file's implementation.

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --package-path .claude/worktrees/fable-gui-perf-refactor --skip-update --filter VCFDatasetViewControllerTests`
Expected: FAIL (the synchronous filter changes the displayed set immediately, so the "still 3 immediately" assertion fails).

- [ ] **Step 4: Implement the debounce**

In `VCFDatasetViewController`, add `private var pendingFilterTask: Task<Void, Never>?`. Change `controlTextDidChange` to store `filterText` and schedule the debounce; keep an immediate internal `applyFilter()` for programmatic use. Match the `BatchTableView` approach (180 ms). Example:

```swift
private var pendingFilterTask: Task<Void, Never>?
private static let filterDebounce: Duration = .milliseconds(180)

public func controlTextDidChange(_ obj: Notification) {
    guard let field = obj.object as? NSSearchField, field === searchField else { return }
    filterText = field.stringValue
    scheduleDebouncedFilter()
}

private func scheduleDebouncedFilter() {
    pendingFilterTask?.cancel()
    pendingFilterTask = Task { [weak self] in
        try? await Task.sleep(for: Self.filterDebounce)
        guard !Task.isCancelled else { return }
        self?.applyFilter()
    }
}
```

`applyFilter()` stays unchanged internally. Empty/cleared filter should still apply immediately if that matches the BatchTableView contract (check `testClearingUserSearchInputAppliesImmediately`) — if so, special-case empty `filterText` to call `applyFilter()` directly without the sleep.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path .claude/worktrees/fable-gui-perf-refactor --skip-update --filter VCFDatasetViewControllerTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Viewer/VCFDatasetViewController.swift Tests/LungfishAppTests/VCFDatasetViewControllerTests.swift
git commit -m "perf: debounce VCF variant browser filter

Filter no longer re-filters, re-sorts, and reloads the whole variant table on
every keystroke; user-typed input is debounced 180ms while programmatic/cleared
input stays immediate.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

### Task 2: Debounce Taxa Collections drawer filter

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxaCollectionsDrawerView.swift` (`controlTextDidChange` ~line 870, `applyFilters` ~line 536, `reloadData` ~line 556).
- Test: `Tests/LungfishAppTests/TaxaCollectionsDrawerTests.swift` (extend existing).

**Interfaces:**
- Produces: debounced user-typed filter on the taxa collections drawer; immediate path preserved for programmatic use.

- [ ] **Step 1: Re-read and confirm.** Read `applyFilters` + its search delegate. Confirm no debounce. Read the existing `TaxaCollectionsDrawerTests.swift` to reuse its setup helpers.
- [ ] **Step 2: Write failing test** in the existing test file: drive the search field, assert `filteredItems` (or whatever the displayed collection is named — confirm from source) does not change synchronously, then `waitUntil` it converges.
- [ ] **Step 3: Run to verify fail.** `swift test --package-path ... --skip-update --filter TaxaCollectionsDrawerTests` → FAIL.
- [ ] **Step 4: Implement debounce** with the same `pendingFilterTask` + 180 ms pattern as Task 1. Empty query applies immediately.
- [ ] **Step 5: Run to verify pass** → PASS.
- [ ] **Step 6: Commit** `perf: debounce taxa collections drawer filter` with the Fable trailer.

### Task 3: Debounce sidebar local search

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` (`searchFieldChanged` ~line 349, `applyLocalSidebarSearch` ~line 355, `filterItems` ~line 518).
- Test: `Tests/LungfishAppTests/` — find the existing sidebar test target/file (`grep -rl "SidebarViewController" Tests/`); extend it, or create `SidebarSearchDebounceTests.swift`.

**Interfaces:**
- Produces: debounced local sidebar text filter. Note: short queries (≤2 chars) route to universal search — preserve that branch; only debounce the local recursive-filter path.

- [ ] **Step 1: Re-read.** Confirm `applyLocalSidebarSearch` does recursive `filterItems` + full `reloadData()` per keystroke and there is no debounce. Note the ≤2-char universal-search branch so it is not broken.
- [ ] **Step 2: Write failing test:** driving the sidebar search field with a ≥3-char query does not synchronously rebuild the filtered tree; it converges after the debounce.
- [ ] **Step 3: Run to verify fail** → FAIL.
- [ ] **Step 4: Implement debounce** (`pendingSearchTask` + 180 ms) around the local-filter path only. Keep the universal-search routing and any existing `SidebarSearchScheduler` intact — if a scheduler already debounces, this task may be N/A; verify in Step 1.
- [ ] **Step 5: Run to verify pass** → PASS.
- [ ] **Step 6: Commit** `perf: debounce sidebar local search filter` with the Fable trailer.

### Task 4: Cache per-render chromosome set in sequence viewer

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Rendering.swift:732`, `SequenceViewerView.swift:1838`, `SequenceViewerView+Alignment.swift:124,759`.
- Test: `Tests/LungfishAppTests/` — add a focused test if a seam exists; otherwise rely on existing sequence-viewer tests + the perf reviewer.

**Interfaces:**
- Consumes: `variantDB.allChromosomes()` / `db.allChromosomes()`.
- Produces: a cached `Set<String>` of chromosomes per DB, invalidated when the DB reference changes.

- [ ] **Step 1: Re-read** all four sites. Confirm `Set(db.allChromosomes())` is rebuilt inside render/draw-adjacent paths per frame. Identify the owning object and where the DB is set/swapped.
- [ ] **Step 2: Write failing/characterization test** if a testable seam exists (e.g., a helper that returns the chromosome set, asserting the underlying `allChromosomes()` is called once across repeated reads with an unchanged DB via a spy). If no seam, document why and lean on the perf reviewer; do not fabricate a test.
- [ ] **Step 3: Implement cache:** store `cachedChromosomeSet: Set<String>?` keyed to the current DB identity; compute lazily; invalidate on DB assignment. Keep it `@MainActor`-isolated (these are render-path reads).
- [ ] **Step 4: Run** the sequence-viewer test target: `swift test --package-path ... --skip-update --filter SequenceViewer` (adjust filter to the real test class names) → PASS / green baseline preserved.
- [ ] **Step 5: Commit** `perf: cache chromosome set in sequence viewer render path` with the Fable trailer.

### Task 5: Move synchronous DB query out of VariantSection render

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/VariantSection.swift:126`.
- Test: existing inspector tests; add one if a seam exists.

**Interfaces:**
- Consumes: `db.query(chromosome:start:end:limit:)`.
- Produces: the sample-count value delivered to the section without a synchronous DB query in the SwiftUI render/body path.

- [ ] **Step 1: Re-read** line ~126. Confirm a synchronous `db.query(...)` runs in a view render/body context. Determine whether this is a SwiftUI `body` or a view-model computed property.
- [ ] **Step 2: Write failing test** if the sample-count derivation has a testable seam (view model): assert the count is fetched off the render path and cached. If purely inline in `body`, restructure to a view-model property first.
- [ ] **Step 3: Implement:** hoist the query into the section's view model, computed once when the variant/selection changes (async, generation-guarded if it can be superseded), and render from the cached value.
- [ ] **Step 4: Run** inspector tests → green.
- [ ] **Step 5: Commit** `perf: hoist VariantSection sample-count query out of render` with the Fable trailer.

### Task 6: Remove redundant paired layout flushes

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ShellLayout.swift:102-103,243-244`, `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift:102,104`.
- Test: existing layout/shell tests; visual verification via run/verify skill.

- [ ] **Step 1: Re-read** each cited pair. Confirm two `layoutSubtreeIfNeeded()` calls run back-to-back on the same view with no state mutation between them (making the second redundant). If there IS a mutation between them, do NOT remove — mark that site N/A and explain.
- [ ] **Step 2: Remove** only the provably-redundant second call at each confirmed site.
- [ ] **Step 3: Build + run shell/layout tests** → green baseline preserved.
- [ ] **Step 4: Commit** `perf: drop redundant layout flushes in split view and mapping` with the Fable trailer.

### Phase 1 Gate

- [ ] Run `swift test --package-path ... --skip-update --filter LungfishAppTests` and `--filter LungfishKitTests`; confirm green baseline.
- [ ] Dispatch `swift-expert`, `performance-engineer`, `code-reviewer` over `git diff <phase1-start>..HEAD`. Fix all blocking findings; iterate until all three are satisfied and green holds.

---

## Phase 2: Off-main file I/O

Phase-start SHA: record before Task 7. Each conversion follows one shared recipe.

### Task 7: Add a shared async file-read helper

**Files:**
- Create: `Sources/LungfishKit/AsyncFileReader.swift`.
- Test: `Tests/LungfishKitTests/AsyncFileReaderTests.swift`.

**Interfaces:**
- Produces:
  ```swift
  enum AsyncFileReader {
      static func readString(_ url: URL, encoding: String.Encoding = .utf8) async throws -> String
      static func readData(_ url: URL) async throws -> Data
      static func write(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic) async throws
      static func writeString(_ string: String, to url: URL, atomically: Bool = true, encoding: String.Encoding = .utf8) async throws
  }
  ```
  Reads/writes execute off the main actor (the functions are `nonisolated`; the file work runs on a background executor via a detached task or a dedicated actor). Callers `await` and then commit results on `@MainActor`.

- [ ] **Step 1: Write failing tests** in `AsyncFileReaderTests`: round-trip write-then-read a temp file; assert the returned content matches; assert reading a missing file throws.

```swift
import XCTest
@testable import LungfishKit

final class AsyncFileReaderTests: XCTestCase {
    func testWriteThenReadRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-asyncfilereader-\(ProcessInfo.processInfo.globallyUniqueString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try await AsyncFileReader.writeString("hello", to: url)
        let read = try await AsyncFileReader.readString(url)
        XCTAssertEqual(read, "hello")
    }

    func testReadMissingFileThrows() async {
        let url = URL(fileURLWithPath: "/nonexistent/lungfish/\(UUID().uuidString)")
        do { _ = try await AsyncFileReader.readString(url); XCTFail("expected throw") }
        catch { /* expected */ }
    }
}
```

- [ ] **Step 2: Run to verify fail** (`--filter AsyncFileReaderTests`) → FAIL (type not defined).
- [ ] **Step 3: Implement** `AsyncFileReader` as `nonisolated` static functions that perform the blocking I/O off the main actor. Do NOT capture `@MainActor` state. Keep it dependency-free (Foundation only).
- [ ] **Step 4: Run to verify pass** → PASS.
- [ ] **Step 5: Commit** `perf: add AsyncFileReader for off-main file I/O` with the Fable trailer.

### Tasks 8–17: Convert each synchronous main-actor read/write to AsyncFileReader

Apply the SAME recipe to each site below. Each is its own task, test cycle, and commit (fold trivially-adjacent sites in the same file into one task where a reviewer would not reject them separately).

**Sites (re-verify each is still synchronous-on-main before editing):**
- Task 8: `Views/Viewer/FASTQDatasetViewController.swift:1524` (read) + `:1513` (write) — sampled FASTA/FASTQ.
- Task 9: `Views/Viewer/MultipleSequenceAlignmentViewController.swift:397` — alignment text.
- Task 10: `Views/Viewer/ViewerViewController+TwelveS.swift:189` — FASTA.
- Task 11: `Views/Results/MHCReference/MHCReferenceBundleViewport.swift:25` — FASTA.
- Task 12: `Views/Sidebar/FolderMetadataEditorSheet.swift:209` — CSV.
- Task 13: `Views/Sidebar/ProjectMetadataExportImport.swift:520` — CSV.
- Task 14: `Views/MainWindow/MainSplitViewController+ContentDisplay.swift:731` + `+ClassifierDisplay.swift:618,830,920` — manifest Data reads.
- Task 15: `Views/Inspector/InspectorViewController+MetadataImport.swift:81,286` — metadata reads.
- Task 16: `Services/WorkflowBuilderRunService.swift:463` — provenance JSON decode.
- Task 17: `Views/Sidebar/SidebarViewController.swift:1874,1886,1897,2015,2027,2038,2099,2164` + `SidebarViewController+MenuDelegate.swift:385,626` — sidecar/manifest reads + one write. (Group the sidebar sidecar reads carefully: many are `try?` best-effort; convert only those on a user-blocking path and keep semantics identical.)

**Recipe per task:**

- [ ] **Step 1: Re-read** the site. Confirm the call is synchronous on `@MainActor` and on a user-perceptible path. If it is tiny/fast (a few KB config read) and moving it off-main adds a suspension that complicates state without a perceptible win, mark N/A and note it — do not add async churn for its own sake.
- [ ] **Step 2: Write/extend a test** where a seam exists (e.g., the load method returns a value that a test can assert after `await`). If the method is deeply embedded in view lifecycle with no seam, note that unit coverage is not feasible and rely on the perf/code reviewers + real-app verification; do not fabricate a test.
- [ ] **Step 3: Convert** the call to `await AsyncFileReader.read...`, hoisting the enclosing method to `async` or wrapping in a `Task { }` that awaits then commits on `@MainActor`. Add a generation guard if a newer selection/navigation can supersede this load. Preserve identical downstream behavior (same parsing, same error handling, same UI update).
- [ ] **Step 4: Build + run** the owning module's test target → green baseline.
- [ ] **Step 5: Commit** `perf: move <site> file read off the main actor` with the Fable trailer.

### Phase 2 Gate

- [ ] Green baseline across touched modules.
- [ ] Reviewer panel over the phase diff, with `swift-expert` explicitly checking every conversion for background→MainActor-rule compliance and generation-guard correctness. Iterate to satisfaction.

---

## Phase 3: Incremental / diffable reloads

Phase-start SHA: record before Task 18.

### Task 18: Wire sidebar delete/refresh through applySubtreeDiff

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` (`reloadOutlineView` ~line 548; delete/refresh call sites), using the existing `applySubtreeDiff` (~line 1039).
- Test: sidebar test target (find via `grep -rl Sidebar Tests/`).

**Interfaces:**
- Consumes: existing `applySubtreeDiff(existingItem:rebuiltItem:parent:indexInParent:)`.
- Produces: delete and single-subtree refresh paths that apply surgical `NSOutlineView` row ops instead of full `reloadData()`.

- [ ] **Step 1: Re-read** `applySubtreeDiff` and the delete/refresh flow (`performDelete`, `reloadOutlineView`, and callers). Identify which callers rebuild a single subtree (candidates for the diff) vs. a genuine full-tree change (must stay full reload). Confirm `applySubtreeDiff` is currently unused on these paths.
- [ ] **Step 2: Write failing test:** deleting a known item from a small in-memory sidebar tree removes exactly that row and does not trigger a full `reloadData()` (assert via a subclass/spy counting `reloadData()` calls, or by asserting surgical `removeItems` behavior). Model it on any existing sidebar test harness.
- [ ] **Step 3: Run to verify fail** → FAIL.
- [ ] **Step 4: Implement:** route the delete path (and single-subtree refresh) through `applySubtreeDiff` / `removeItems(at:inParent:)`; keep full reload only for whole-tree changes. Preserve selection restoration.
- [ ] **Step 5: Run to verify pass** + sidebar target green → PASS.
- [ ] **Step 6: Commit** `perf: apply surgical outline diff on sidebar delete/refresh` with the Fable trailer.

### Task 19: OperationsPanelController row-level deltas

**Files:**
- Modify: `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift` (`reloadDataPreservingSelection` ~line 282; the change-reconciliation switch ~lines 135–189).
- Test: `Tests/LungfishAppTests/` operations-panel test (find or create).

**Interfaces:**
- Produces: `reloadDataPreservingSelection` and the change reconciler using `insertRows`/`removeRows`/`reloadRows` for the common add/update/remove cases; full reload only as a last-resort fallback on genuine mismatch.

- [ ] **Step 1: Re-read** the reconciliation switch and `reloadDataPreservingSelection`. Confirm the full-`reloadData()` fallback (line ~282) fires on common transitions.
- [ ] **Step 2: Write failing test:** adding one operation inserts one row (not a full reload); updating one operation reloads one row. Use a spy counting full reloads.
- [ ] **Step 3: Run to verify fail** → FAIL.
- [ ] **Step 4: Implement** row-level deltas; keep selection preservation; keep the coalescing (150 ms) intact.
- [ ] **Step 5: Run to verify pass** → PASS.
- [ ] **Step 6: Commit** `perf: row-level updates in operations panel` with the Fable trailer.

### Task 20: NVD / VCF / taxonomy result tables — targeted updates

**Files:**
- Modify: `Sources/LungfishNvdUI/NvdResultViewController.swift:352,439,480`; `Sources/LungfishApp/Views/Viewer/VCFDatasetViewController.swift` (post-filter reload path); taxonomy result table(s).
- Test: respective module test targets.

- [ ] **Step 1: Re-read** each reload site. For each, decide: can a filter/sort/selection change be expressed as targeted row ops, or is a full reload genuinely warranted (e.g., data source wholesale replaced)? Only convert the former.
- [ ] **Step 2–6:** per site, add a failing test asserting the targeted update, implement, verify, commit. Where a full reload is genuinely required, leave it and note why in the commit body. One commit per module.

### Phase 3 Gate

- [ ] Green baseline across touched modules (`LungfishAppTests`, `LungfishNvdUITests`).
- [ ] Reviewer panel over the phase diff; `code-reviewer` explicitly checks selection-preservation and that no row/index math can desync from the data source. Iterate to satisfaction.

---

## Phase 4: Large-dataset scaling (UX-altering, opt-in)

Phase-start SHA: record before Task 21. These change visible defaults — each new default gets an explicit regression test and existing expectations are updated deliberately.

**Pinned thresholds (decided in this plan):**
- "Very large" table threshold = **5,000 rows**. At/above this, the table defaults to a top-N window.
- Default top-N window = **1,000 rows**, with an explicit "Show all N,NNN rows" control that switches to the full set.
- Genotype/EsViritu/TaxTriage matrices: default to a **sample window of 200 columns** when cohort > 200, with a control to page/show-all.
(If a specific surface has a natural domain-appropriate default that differs, prefer it and note the deviation in the task's commit body.)

### Task 21: Top-N default for very large result tables

**Files:**
- Modify: the shared result table path if one exists (prefer adding this to `BatchTableView` in `LungfishKit` so all subclasses inherit it); else the specific large tables (VCF, taxonomy, NVD).
- Test: `Tests/LungfishKitTests/` (if in BatchTableView) or per-table test.

**Interfaces:**
- Produces: a `rowDisplayCap` mechanism on the shared table: when `unfilteredRows.count >= 5000`, `displayedRows` is capped at 1000 until "Show all" is invoked; a visible affordance shows the cap and total.

- [ ] **Step 1: Re-read** `BatchTableView` display pipeline (`configure(rows:)`, `displayedRows`, filter/sort) to find the single choke point where the cap applies cleanly. Confirm which large tables subclass it (grep).
- [ ] **Step 2: Write failing tests:** configuring with 6,000 rows displays 1,000 by default; invoking "show all" displays 6,000; configuring with 4,000 rows displays all 4,000 (below threshold). Assert the affordance text reflects the cap.
- [ ] **Step 3: Run to verify fail** → FAIL.
- [ ] **Step 4: Implement** the cap + "Show all" toggle in the shared table. Filtering/sorting operate on the full set; only the displayed window is capped. Programmatic full-population for tests/state remains available.
- [ ] **Step 5: Run to verify pass** → PASS. Then update any existing test that assumed all rows always render (search for tests asserting `numberOfRows`/`displayedRows.count == input.count` on large inputs) and adjust expectations deliberately, documenting each in the commit.
- [ ] **Step 6: Commit** `feat: cap very large result tables to a top-N window with Show all` with the Fable trailer.

### Task 22: Genotype matrix sample windowing

**Files:**
- Modify: `Sources/LungfishGenotypeUI/` matrix/outline view(s) (locate the column-per-sample renderer).
- Test: `Tests/LungfishGenotypeUITests/`.

- [ ] **Step 1: Re-read** the genotype matrix rendering. Confirm it renders one column per sample with no windowing (note: rendering was tightened in b951cd2f — confirm windowing is still absent). Identify the cohort-size input.
- [ ] **Step 2: Write failing test:** a cohort of 500 samples renders a 200-column window by default; a control expands it. A cohort of 150 renders all 150.
- [ ] **Step 3: Run to verify fail** → FAIL.
- [ ] **Step 4: Implement** the sample window (200) with a page/show-all control. Preserve selection and per-sample styling for windowed columns.
- [ ] **Step 5: Run to verify pass** + `LungfishGenotypeUITests` green (⊆ the 6 known environmental genotype failures) → PASS.
- [ ] **Step 6: Commit** `feat: window genotype matrix columns for large cohorts` with the Fable trailer.

### Task 23: EsViritu / TaxTriage large-surface windowing

**Files:**
- Modify: `Sources/LungfishEsVirituUI/`, `Sources/LungfishTaxTriageUI/` non-virtualized outlines/tables.
- Test: respective module targets.

- [ ] **Step 1: Re-read** each surface; confirm non-virtualized stack/full reload at scale (TaxTriage selection was already tightened in 4d70b6f1 — do not undo that; target the display-size dimension only).
- [ ] **Step 2–6:** per surface, add failing windowing test, implement (reuse the Task 21 cap where the surface is a `BatchTableView` subclass), verify, commit. One commit per module.

### Phase 4 Gate

- [ ] Green baseline; every UX-altering default has an explicit test; updated expectations are intentional and documented.
- [ ] Reviewer panel; `code-reviewer` verifies no data loss (full set always reachable via "Show all") and that provenance/export paths still see the FULL dataset, not the windowed view. This is a hard check — windowing must never leak into scientific export. Iterate to satisfaction.

---

## Phase 5: Architectural (highest risk; Fable does what it can)

Phase-start SHA: record before Task 24. For any item Fable cannot land with green tests and reviewer sign-off, STOP that item and write it to the Opus-deferral file instead of committing a partial change.

### Task 24: Off-main sidebar tree snapshot builder

**Files:**
- Create: `Sources/LungfishApp/Views/Sidebar/SidebarTreeSnapshotBuilder.swift` (or similar) — a `nonisolated`/actor builder producing an immutable tree snapshot off-main.
- Modify: `SidebarViewController` scan/reload paths to build off-main, then apply a generation-checked diff on `@MainActor` (reusing Task 18's `applySubtreeDiff`).
- Test: `Tests/LungfishAppTests/` snapshot-builder tests.

**Interfaces:**
- Produces: `SidebarTreeSnapshotBuilder.build(root:...) async -> SidebarTreeSnapshot` (immutable, Sendable); a main-actor apply step guarded by a `sidebarScanGeneration` counter.

- [ ] **Step 1: Re-read** the current main-actor tree build. Identify the pure, filesystem-reading portion (movable off-main) vs. the `NSOutlineView`/`SidebarItem` mutation (must stay on `@MainActor`). Confirm `SidebarItem` mutation cannot be moved; design an immutable Sendable snapshot as the off-main product.
- [ ] **Step 2: Write failing tests:** the builder produces a correct snapshot for a known temp directory tree off-main; applying a snapshot with a stale generation is dropped; applying the current-generation snapshot updates the tree.
- [ ] **Step 3: Run to verify fail** → FAIL.
- [ ] **Step 4: Implement** the off-main builder + generation-checked main-actor apply. Honor background→MainActor rules strictly. If, mid-implementation, this cannot be made correct/verifiable with Fable (e.g., `SidebarItem` graph is too entangled to snapshot safely), STOP, revert the partial work, and write an Opus-deferral entry (Task 26) describing the blocker and a proposed approach.
- [ ] **Step 5: Run to verify pass** + full sidebar target green → PASS.
- [ ] **Step 6: Commit** `perf: build sidebar tree off-main with generation-checked apply` with the Fable trailer. (Skip if deferred.)

### Task 25: Render coordinator — lift fetch scheduling out of draw

**Files:**
- Create: a render coordinator type keyed by viewport signature (location under `Views/Viewer/`).
- Modify: `SequenceViewerView+*` draw paths that currently schedule async fetches inline.
- Test: `Tests/LungfishAppTests/` coordinator tests.

**Interfaces:**
- Produces: a coordinator that, given a viewport signature (region + track set + options), schedules needed fetches once (deduped, generation-guarded) OUTSIDE `draw(_:)`; fetch completion invalidates only the affected track/lane rects.

- [ ] **Step 1: Re-read** the draw paths (`SequenceViewerView+Rendering`, `+Alignment`) to enumerate every fetch currently kicked off from or adjacent to `draw(_:)`. Map each to a viewport-signature input.
- [ ] **Step 2: Write failing tests:** the coordinator dedups identical signatures (one fetch for repeated draws of the same signature); a new signature supersedes an in-flight one (generation); completion invalidates only the named rect (assert via a spy).
- [ ] **Step 3: Run to verify fail** → FAIL.
- [ ] **Step 4: Implement** the coordinator; move scheduling out of `draw(_:)` so draw only reads cached data and requests-if-missing via the coordinator. Preserve existing generation-counter semantics. If this cannot be landed correctly/verifiably with Fable, STOP and write an Opus-deferral entry instead.
- [ ] **Step 5: Run to verify pass** + sequence-viewer target green → PASS.
- [ ] **Step 6: Commit** `perf: route viewport fetch scheduling through a render coordinator` with the Fable trailer. (Skip if deferred.)

### Task 26: Opus-deferral file

**Files:**
- Create: `docs/reports/2026-07-02-gui-perf-opus-deferrals.md`.

- [ ] **Step 1:** For every item this pass could NOT land with Fable (any stopped Task-24/25 item, plus anything discovered along the way), write one entry: symptom, file:line, why it exceeds a safe Fable change, and a proposed approach for a later Opus pass.
- [ ] **Step 2:** If NO items were deferred, still create the file stating "No items required deferral in this pass" with a one-line rationale, so the deliverable your ask specified exists.
- [ ] **Step 3: Commit** `docs: record GUI perf items deferred to a future Opus pass` with the Fable trailer.

### Phase 5 Gate

- [ ] Green baseline. Reviewer panel over the phase diff with extra scrutiny from `swift-expert` on the off-main/coordinator concurrency. Iterate to satisfaction.
- [ ] Confirm the Opus-deferral file exists and is accurate.

---

## Final: Branch completion

- [ ] Full green-bar verification (XCTest ⊆ known 9 environmental, swift-testing = 0).
- [ ] Invoke superpowers:finishing-a-development-branch to choose merge/PR/cleanup.
