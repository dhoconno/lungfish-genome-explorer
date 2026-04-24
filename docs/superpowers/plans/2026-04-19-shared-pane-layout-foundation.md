# Shared Pane Layout Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the first reusable pane-and-drawer foundation rollout so the broken metagenomics adopters share one raw split coordinator path and the main app shell has testable recommendation-suppression behavior.

**Architecture:** Keep the shared layout math in app-wide `Views/Layout` helpers, migrate remaining raw `TrackedDividerSplitView` controllers onto the shared coordinator and fill-container primitives, and move shell-specific sidebar recommendation state into a small helper that can be tested without relying on brittle `NSSplitViewController` geometry in the harness.

**Tech Stack:** Swift, AppKit, `NSSplitView`, `NSSplitViewController`, XCTest

---

### Task 1: Finish The Shared Raw Split Migration

**Files:**
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift`

- [ ] **Step 1: Keep the existing EsViritu divider regression coverage intact**

Run: `swift test --filter MetagenomicsLayoutModeTests/testEsVirituLiveWindowPreservesUserMovedVerticalDivider`
Expected: PASS before the migration, confirming the baseline behavior is already covered.

- [ ] **Step 2: Replace EsViritu's bespoke divider state with `TwoPaneTrackedSplitCoordinator`**

Edit `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift` so the controller:

```swift
private let splitCoordinator = TwoPaneTrackedSplitCoordinator()

public override func viewDidLayout() {
    super.viewDidLayout()
    guard splitCoordinator.needsInitialSplitValidation else { return }
    scheduleInitialSplitValidationIfNeeded()
}
```

and so the controller's split helpers delegate to the shared coordinator instead of maintaining local `didSetInitialSplitPosition`, `needsInitialSplitValidation`, `pendingInitialSplitValidation`, and tracked-divider synchronization state.

- [ ] **Step 3: Keep EsViritu's minimum extents and layout defaults explicit**

In the same file, add small local wrappers around the coordinator:

```swift
private func minimumExtents(for layout: MetagenomicsPanelLayout) -> (leading: CGFloat, trailing: CGFloat) {
    switch layout {
    case .detailLeading:
        return (250, 250)
    case .listLeading, .stacked:
        return (250, 250)
    }
}
```

and route `resetInitialSplitPositionIfNeeded()`, `hasValidInitialSplitPosition()`, `scheduleInitialSplitValidationIfNeeded()`, `applyInitialSplitPositionIfNeeded()`, `applyLayoutPreference()`, and `splitViewDidResizeSubviews(_:)` through the shared coordinator using those wrappers.

- [ ] **Step 4: Update tests to reflect the shared state source**

Adjust `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift` only if needed so the EsViritu tests keep asserting on public controller behavior rather than removed private state.

- [ ] **Step 5: Run the EsViritu-focused layout regression tests**

Run:
`swift test --filter MetagenomicsLayoutModeTests/testEsVirituLiveWindowKeepsBothPanesVisibleInListLeadingMode`
`swift test --filter MetagenomicsLayoutModeTests/testEsVirituLiveWindowHonorsListLeadingMinimumPaneWidths`
`swift test --filter MetagenomicsLayoutModeTests/testEsVirituLiveWindowPreservesUserMovedVerticalDivider`
`swift test --filter MetagenomicsLayoutModeTests/testEsVirituImmediateUserDividerMoveSurvivesDeferredValidation`

Expected: all PASS.

### Task 2: Extract Testable Shell Recommendation State

**Files:**
- Create: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Layout/SplitShellWidthCoordinator.swift`
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/MainSplitLayoutTests.swift`

- [ ] **Step 1: Write a failing shell-state test that does not depend on synthetic AppKit divider motion**

Add a test in `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/MainSplitLayoutTests.swift` that exercises a helper with this shape:

```swift
func testSidebarRecommendationIsIgnoredAfterExplicitUserResize() {
    let coordinator = SplitShellWidthCoordinator()
    coordinator.noteProgrammaticWidth(240)
    coordinator.noteObservedWidth(360)

    XCTAssertTrue(coordinator.hasExplicitUserResize)
    XCTAssertNil(
        coordinator.recommendedWidthToApply(
            proposedWidth: 420,
            minimumWidth: 180,
            maximumWidth: 720,
            currentWidth: 360,
            allowShrink: false
        )
    )
}
```

Run: `swift test --filter MainSplitLayoutTests/testSidebarRecommendationIsIgnoredAfterExplicitUserResize`
Expected: FAIL because the helper does not exist yet.

- [ ] **Step 2: Implement the shell-width helper**

Create `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Layout/SplitShellWidthCoordinator.swift`:

```swift
import CoreGraphics

@MainActor
final class SplitShellWidthCoordinator {
    private(set) var lastObservedWidth: CGFloat?
    private(set) var hasExplicitUserResize = false
    private var isApplyingProgrammaticWidth = false

    func noteProgrammaticWidth(_ width: CGFloat) {
        isApplyingProgrammaticWidth = true
        lastObservedWidth = width
    }

    func finishProgrammaticWidth() {
        isApplyingProgrammaticWidth = false
    }

    func noteObservedWidth(_ width: CGFloat) {
        if let lastObservedWidth,
           !isApplyingProgrammaticWidth,
           abs(width - lastObservedWidth) >= 1 {
            hasExplicitUserResize = true
        }
        lastObservedWidth = width
    }

    func recommendedWidthToApply(
        proposedWidth: CGFloat,
        minimumWidth: CGFloat,
        maximumWidth: CGFloat,
        currentWidth: CGFloat,
        allowShrink: Bool
    ) -> CGFloat? {
        guard !hasExplicitUserResize else { return nil }
        let clamped = min(max(proposedWidth, minimumWidth), maximumWidth)
        let target = allowShrink ? clamped : max(currentWidth, clamped)
        return abs(target - currentWidth) >= 1 ? target : nil
    }
}
```

- [ ] **Step 3: Wire `MainSplitViewController` onto the helper**

Modify `/Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` so sidebar recommendation handling uses the helper:

```swift
private let sidebarWidthCoordinator = SplitShellWidthCoordinator()
```

and replace the controller-local `lastObservedSidebarWidth`, `isApplyingSidebarPreferredWidth`, and `userHasExplicitlyResizedSidebar` bookkeeping with calls to:
- `sidebarWidthCoordinator.recommendedWidthToApply(...)`
- `sidebarWidthCoordinator.noteProgrammaticWidth(...)`
- `sidebarWidthCoordinator.finishProgrammaticWidth()`
- `sidebarWidthCoordinator.noteObservedWidth(...)`

- [ ] **Step 4: Keep one integration-level shell smoke test**

Retain a light `MainSplitViewController` smoke test that only verifies a width recommendation can be processed in a live window without crashing, but move the snap-back suppression assertion to the helper unit test.

- [ ] **Step 5: Run the shell tests**

Run: `swift test --filter MainSplitLayoutTests`
Expected: PASS.

### Task 3: Verify The Shared Foundation End-To-End

**Files:**
- Modify: `/Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift` (only if one final expectation needs updating)

- [ ] **Step 1: Run the focused raw split regression tests**

Run:
`swift test --filter MetagenomicsLayoutModeTests/testNaoMgsLiveWindowResizesDetailDocumentWidthAfterDividerMove`
`swift test --filter MetagenomicsLayoutModeTests/testNvdLiveWindowResizesDetailDocumentWidthAfterDividerMove`
`swift test --filter MetagenomicsLayoutModeTests/testEsVirituLiveWindowPreservesUserMovedVerticalDivider`

Expected: all PASS.

- [ ] **Step 2: Run the broader metagenomics split suite**

Run: `swift test --filter MetagenomicsLayoutModeTests`
Expected: PASS.

- [ ] **Step 3: Build the debug app**

Run: `bash scripts/build-app.sh --configuration debug`
Expected: debug app build succeeds and updates `/Users/dho/Documents/lungfish-genome-explorer/build/Debug/Lungfish.app`.

- [ ] **Step 4: Commit**

```bash
git add /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Layout \
        /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift \
        /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift \
        /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Metagenomics/MetagenomicsPaneSizing.swift \
        /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift \
        /Users/dho/Documents/lungfish-genome-explorer/Sources/LungfishApp/Views/Metagenomics/NvdResultViewController.swift \
        /Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/MainSplitLayoutTests.swift \
        /Users/dho/Documents/lungfish-genome-explorer/Tests/LungfishAppTests/MetagenomicsLayoutModeTests.swift \
        /Users/dho/Documents/lungfish-genome-explorer/docs/superpowers/specs/2026-04-19-shared-pane-layout-foundation-design.md \
        /Users/dho/Documents/lungfish-genome-explorer/docs/superpowers/plans/2026-04-19-shared-pane-layout-foundation.md
git commit -m "refactor: share pane layout foundations"
```
