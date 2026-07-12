# Genotype Matrix Vertical-Scroll Synchronization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the pinned genotype columns and per-sample matrix rows aligned when either pane receives vertical scrolling.

**Architecture:** `GenotypeComparisonMatrixView` will register its existing bounds-change handler for both `NSClipView` instances. The handler will resolve the notification source, copy only its Y origin to the opposite content view, and use the existing reentrancy guard to prevent feedback. DEBUG-only hooks will simulate the two scroll inputs and expose offsets without widening the production API.

**Tech Stack:** Swift 6, AppKit (`NSScrollView`, `NSClipView`, `NSTableView`), XCTest.

---

### Task 1: Add a bidirectional-scroll regression test

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:2310-2375`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift:1108-1160`

- [ ] **Step 1: Add DEBUG-only scroll test hooks**

  Add these members to the existing `#if DEBUG` extension of
  `GenotypeComparisonMatrixView`, after `testingPinnedColumnTitles`:

  ```swift
  var testingPinnedVerticalScrollOffset: CGFloat {
      pinnedScrollView.contentView.bounds.origin.y
  }

  var testingSampleMatrixScrollOffset: NSPoint {
      scrollView.contentView.bounds.origin
  }

  func testingScrollPinnedPanel(toY y: CGFloat) {
      var origin = pinnedScrollView.contentView.bounds.origin
      origin.y = y
      pinnedScrollView.contentView.setBoundsOrigin(origin)
  }

  func testingScrollSampleMatrix(to origin: NSPoint) {
      scrollView.contentView.setBoundsOrigin(origin)
  }
  ```

  The hooks must set the real clip-view bounds so the test exercises the same
  notification path as a wheel scroll.

- [ ] **Step 2: Add the failing behavior test**

  In `GenotypeResultViewportTests`, add a helper beside
  `makeManySampleMatrix(sampleCount:)` that configures 32 distinct genotype
  rows for two samples. Then add this test:

  ```swift
  func testComparisonMatrixSynchronizesVerticalScrollingFromEitherPanel() {
      let matrix = makeScrollableComparisonMatrix()
      matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
      matrix.layoutSubtreeIfNeeded()

      matrix.testingScrollSampleMatrix(to: NSPoint(x: 37, y: 88))
      XCTAssertEqual(matrix.testingPinnedVerticalScrollOffset, 88, accuracy: 0.001)
      XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.x, 37, accuracy: 0.001)

      matrix.testingScrollPinnedPanel(toY: 132)
      XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.y, 132, accuracy: 0.001)
      XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.x, 37, accuracy: 0.001)
  }
  ```

  Construct each `ONTGenotypeCall` with the existing `makeCall` helper and
  genotypes such as `String(format: "Mafa-AG*%02d:01", index)`, so the table
  has enough rows to expose scrolling.

- [ ] **Step 3: Run the focused test to verify the regression**

  Run:

  ```bash
  swift test --filter GenotypeResultViewportTests/testComparisonMatrixSynchronizesVerticalScrollingFromEitherPanel
  ```

  Expected: FAIL at the assertion after `testingScrollPinnedPanel(toY: 132)`:
  the sample matrix remains at its previous Y offset because only its clip view
  is observed in the current implementation.

- [ ] **Step 4: Commit the regression test scaffolding**

  ```bash
  git add Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
  git commit -m "test: cover genotype matrix scroll synchronization"
  ```

### Task 2: Synchronize both vertical scroll inputs

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift:473-531`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift:after sample-window tests`

- [ ] **Step 1: Observe the pinned content view**

  Directly after the existing `NotificationCenter.default.addObserver` call for
  `scrollView.contentView`, register the same selector for
  `pinnedScrollView.contentView`:

  ```swift
  NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollViewBoundsChanged(_:)),
      name: NSView.boundsDidChangeNotification,
      object: pinnedScrollView.contentView
  )
  ```

- [ ] **Step 2: Replace the one-way handler with source-aware synchronization**

  Replace the handler body with:

  ```swift
  @objc private func scrollViewBoundsChanged(_ notification: Notification) {
      guard !suppressScrollSync,
            let sourceContentView = notification.object as? NSClipView else {
          return
      }

      let destinationContentView: NSClipView
      switch sourceContentView {
      case scrollView.contentView:
          destinationContentView = pinnedScrollView.contentView
      case pinnedScrollView.contentView:
          destinationContentView = scrollView.contentView
      default:
          return
      }

      let y = sourceContentView.bounds.origin.y
      guard destinationContentView.bounds.origin.y != y else { return }

      suppressScrollSync = true
      defer { suppressScrollSync = false }
      var destinationBounds = destinationContentView.bounds
      destinationBounds.origin.y = y
      destinationContentView.setBoundsOrigin(destinationBounds.origin)
  }
  ```

  This intentionally preserves `destinationBounds.origin.x`; horizontal motion
  continues to belong only to the sample matrix.

- [ ] **Step 3: Run the focused regression test**

  Run:

  ```bash
  swift test --filter GenotypeResultViewportTests/testComparisonMatrixSynchronizesVerticalScrollingFromEitherPanel
  ```

  Expected: PASS. Both assertions for vertical alignment pass and the sample
  matrix keeps its X offset of `37` after the pinned-panel scroll.

- [ ] **Step 4: Run the focused viewport suite**

  Run:

  ```bash
  swift test --filter GenotypeResultViewportTests
  ```

  Expected: PASS with no new failures.

- [ ] **Step 5: Inspect the patch and commit the implementation**

  Run:

  ```bash
  git diff --check
  git diff -- Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
  ```

  Then commit:

  ```bash
  git add Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
  git commit -m "fix: synchronize genotype matrix vertical scrolling"
  ```

### Task 3: Verify the completed branch

**Files:**
- Verify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Verify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Run the targeted build configuration check**

  Run:

  ```bash
  swift test --filter ReleaseBuildConfigurationTests
  ```

  Expected: PASS, confirming the source and test configuration remain valid for
  the release build path.

- [ ] **Step 2: Confirm branch cleanliness**

  Run:

  ```bash
  git status --short
  git log --oneline -3
  ```

  Expected: no working-tree changes; the design, regression-test, and fix
  commits are visible on `codex/sync-genotype-matrix-scroll`.
