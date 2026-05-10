# GitHub Issues 6-13 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the accepted alpha feedback in GitHub Issues #6 through #13 without weakening scientific provenance guarantees.

**Architecture:** Keep the fixes narrow and local: repository safety in `.gitignore`, operations-panel behavior in the operations UI/controller, table filtering and header metadata in the metagenomics table layer, workspace layout persistence in the shell controller, and alignment navigation in the existing viewer controllers. Prefer additive model fields with backward-compatible decoding so existing bundle view state and user defaults remain valid.

**Tech Stack:** Swift/AppKit, Swift Testing/XCTest, GitHub CLI, git worktrees.

---

### Task 1: Repository Safety For #6

**Files:**
- Modify: `.gitignore`
- Delete tracked accident: `.superpowers/brainstorm/71743-1775170024/state/server.log`
- Delete tracked accident: `.superpowers/brainstorm/71743-1775170024/state/server.pid`
- Test: shell checks with `git check-ignore` and `git status`

- [ ] **Step 1: Verify the accidentally tracked files are currently tracked**

Run:

```bash
git ls-files '.superpowers/**'
```

Expected before the fix: the two `.superpowers/brainstorm/.../state` files are listed.

- [ ] **Step 2: Replace `.gitignore` with a conservative deny-by-default allowlist**

Keep `*` as the first rule, then unignore directories and intentional source assets such as `.github/`, `AGENTS.md`, `Package.swift`, `Package.resolved`, `Lungfish.xcodeproj/`, `Sources/`, `Tests/`, `Resources/`, `docs/`, `scripts/`, `*.entitlements`, and other root files that are already tracked. Preserve explicit ignores for `.build/`, `build/`, `.worktrees/`, DerivedData, signing/notary scratch, local editor files, logs, pid files, and `.superpowers/brainstorm/**/state/`.

- [ ] **Step 3: Remove the accidentally tracked `.superpowers` state files**

Run:

```bash
git rm .superpowers/brainstorm/71743-1775170024/state/server.log \
  .superpowers/brainstorm/71743-1775170024/state/server.pid
```

- [ ] **Step 4: Verify intended files remain visible and generated files stay ignored**

Run:

```bash
git check-ignore -q .worktrees/example
git check-ignore -q .superpowers/brainstorm/example/state/server.log
git check-ignore -q build/Release/example.dmg
git check-ignore -q Sources/LungfishApp/App/AppDelegate.swift && exit 1 || true
git status --short
```

Expected: generated paths are ignored, tracked source paths are not ignored, and only the intended `.gitignore` plus `.superpowers` deletions are staged/visible.

### Task 2: Operations Panel Fixes For #12 And #13

**Files:**
- Modify: `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift`
- Test: `Tests/LungfishAppTests/GUIRegressionTests.swift`
- Test: `Tests/LungfishAppTests/DownloadCenterTests.swift`

- [ ] **Step 1: Write failing source-level tests**

Add tests asserting `OperationsPanelController.swift` no longer sets `isFloatingPanel = true` or uses `.nonactivatingPanel`, and that it contains user-visible `View Log` and `Reveal Log` actions plus accessibility identifiers for both.

- [ ] **Step 2: Run the focused tests and confirm the new tests fail**

Run:

```bash
swift test --filter 'OperationsPanelTests|DownloadCenterTests'
```

Expected: the new operations-panel tests fail on the current floating-panel/log-action implementation.

- [ ] **Step 3: Make the operations window layer normally**

Use a normal `NSWindow` or a non-floating panel style that can sit behind other app windows. Do not use `.nonactivatingPanel`, `.utilityWindow`, or `isFloatingPanel = true` as the default behavior.

- [ ] **Step 4: Add obvious log file actions**

Add a small log-action section beside the existing log display. On demand, format operation logs/failure detail into a local file under `~/Library/Logs/Lungfish/Operations/`, then:

```swift
NSWorkspace.shared.open(logURL)
NSWorkspace.shared.activateFileViewerSelecting([logURL])
```

Use clear button titles `View Log` and `Reveal Log`, accessibility identifiers, and the existing privacy boundary: write local diagnostics only; do not upload logs.

- [ ] **Step 5: Re-run the focused tests**

Run:

```bash
swift test --filter 'OperationsPanelTests|DownloadCenterTests'
```

Expected: pass.

### Task 3: Filter Semantics And Column Tooltips For #8 And #11

**Files:**
- Modify: `Sources/LungfishApp/Views/Metagenomics/ColumnFilter.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/TaxonomyTableView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/BatchTableView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/ViralDetectionTableView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- Test: `Tests/LungfishAppTests/ColumnFilterIntegrationTests.swift`

- [ ] **Step 1: Write failing model tests**

Add tests for `ColumnFilter(isInverted: true)` on text and numeric filters, plus a `ColumnFilterSet` or equivalent composition model that supports `.all` and `.any`.

- [ ] **Step 2: Run the filter tests and confirm failure**

Run:

```bash
swift test --filter ColumnFilter
```

Expected: the new inverted/composed filter tests fail before implementation.

- [ ] **Step 3: Implement backward-compatible filter models**

Make `ColumnFilter` `Codable` and `Equatable`, add `isInverted: Bool = false`, and ensure `matchesString` / `matchesNumeric` apply inversion after evaluating the base predicate. Add a tiny `ColumnFilterComposition` enum and helper that evaluates active filters as AND or OR.

- [ ] **Step 4: Wire existing metagenomics tables through the shared evaluator**

Replace hand-written `allSatisfy` loops with the shared evaluator. Keep default composition as AND to preserve current behavior. Add menu entries for exclude filters and AND/OR composition where table context menus already expose filtering.

- [ ] **Step 5: Add reusable column metadata**

Add a small `TableColumnMetadata` helper that builds header tooltips from title, unit, and description. Apply it to classifier/metagenomics table columns with scientific metric units where known; leave generic columns with descriptions only.

- [ ] **Step 6: Re-run column filter tests**

Run:

```bash
swift test --filter ColumnFilter
```

Expected: pass.

### Task 4: Session/Layout First Pass For #7 And #10

**Files:**
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/App/MainMenu.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Modify: `Sources/LungfishCore/Bundles/BundleViewState.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift`
- Test: `Tests/LungfishAppTests/WorkspaceShellLayoutTests.swift`
- Test: add or extend bundle view-state tests in `Tests/LungfishCoreTests/`

- [ ] **Step 1: Write failing tests for viewer focus and expanded view state**

Add tests that the shell can collapse both side panes into a focused viewer mode and restore them, and that `BundleViewState` round-trips newly persisted fields for variant filter text and sample display state.

- [ ] **Step 2: Run focused layout/view-state tests and confirm failure**

Run:

```bash
swift test --filter 'WorkspaceShellLayoutTests|BundleViewState'
```

- [ ] **Step 3: Add focus/restore side-pane commands**

Add `focusViewer()` and `restoreSidePanes()` on `MainSplitViewController`, wire menu actions, and persist the same sidebar/inspector collapsed defaults that already exist. This makes the main app panes collapsible as a coherent first pass without adding draggable editor panes.

- [ ] **Step 4: Persist more bundle view state**

Extend `BundleViewState` with backward-compatible optional fields for `variantFilterText` and enough sample-display state to restore visible/hidden samples and genotype row display. Save/restore through `ViewerViewController+BundleDisplay.swift`.

- [ ] **Step 5: Re-run focused layout/view-state tests**

Run:

```bash
swift test --filter 'WorkspaceShellLayoutTests|BundleViewState'
```

Expected: pass.

### Task 5: Alignment Interaction First Pass For #9

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift`
- Test: `Tests/LungfishAppTests/ReadTrackRendererTests.swift`
- Test: add focused viewport interaction tests if an existing test seam is present

- [ ] **Step 1: Write failing tests or source invariants for gesture hooks**

Add tests or source-level assertions that sequence/alignment views implement `scrollWheel(with:)` for horizontal/vertical pan and `magnify(with:)` for pinch zoom, and that these route through existing zoom/pan methods rather than duplicating rendering logic.

- [ ] **Step 2: Run focused viewer tests and confirm failure**

Run:

```bash
swift test --filter 'ReadTrackRendererTests|Viewer'
```

- [ ] **Step 3: Implement native-feeling pan and pinch**

For sequence and read alignment views, translate trackpad deltas into viewport movement and pinch magnification into existing zoom methods, preserving the viewport center and clamping to sequence bounds. Keep keyboard/menu zoom behavior unchanged.

- [ ] **Step 4: Re-run focused viewer tests**

Run:

```bash
swift test --filter 'ReadTrackRendererTests|Viewer'
```

Expected: pass.

### Task 6: Integration, Issue Closure, And Release Hygiene

**Files:**
- Modify: `docs/release-notes/` only if a new release note draft is needed
- GitHub Issues: #6 through #13

- [ ] **Step 1: Run integrated test coverage**

Run:

```bash
swift test --filter 'DownloadCenterTests|OperationsPanelTests|ColumnFilter|WorkspaceShellLayoutTests|BundleViewState|ReadTrackRendererTests|Viewer'
git diff --check
```

- [ ] **Step 2: Run full test suite if focused tests pass**

Run:

```bash
swift test
```

- [ ] **Step 3: Commit and push the implementation branch**

Run:

```bash
git status --short
git add .
git commit -m "Fix accepted alpha GitHub issues"
git push origin codex/issues-6-13
```

- [ ] **Step 4: Comment on and close fixed issues**

For each of #6-#13, add a short comment naming the shipped fix and verification, then close the issue. If any issue is only partially addressed, leave it open and explain the remaining scope explicitly.
