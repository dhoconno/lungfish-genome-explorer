# MHC Sequence Detail Resizing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the MHC GenBank/FASTA/EMBL detail reader flow across the entire resized pane and keep its viewport height synchronized with the pane.

**Architecture:** Retain the existing one-view `NSScrollView`/`NSTextView` hierarchy. Change the text container from unbounded, content-sized width to viewport-tracking width and remove the post-render `sizeToFit()` that overrides AppKit sizing. Auto Layout continues to determine the scroll viewport height.

**Tech Stack:** Swift 6, AppKit, XCTest.

---

### Task 1: Capture the resizing regression

**Files:**

- Modify: `Tests/LungfishGenotypeUITests/GenotypeAlleleSequenceDetailViewTests.swift`

- [x] **Step 1: Write the failing resize test**

Replace the prior fixed-width horizontal-reachability assertion with a test that renders a record, lays out a compact `640 × 360` detail view, resizes it to `1,280 × 720`, and asserts both values below:

```swift
XCTAssertEqual(text.frame.width, scroll.contentSize.width, accuracy: 1)
XCTAssertEqual(scroll.frame.height, view.bounds.height - formatControl.frame.maxY - 8, accuracy: 1)
```

- [x] **Step 2: Run the focused test and verify it fails**

Run:

```bash
swift test --filter GenotypeAlleleSequenceDetailViewTests/testSequenceReaderTracksResizedPaneWidthAndHeight
```

Expected: failure because the current unbounded document view is wider than the scroll viewport after the resize.

### Task 2: Make the reader viewport-responsive

**Files:**

- Modify: `Sources/LungfishGenotypeUI/GenotypeAlleleSequenceDetailView.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeAlleleSequenceDetailViewTests.swift`

- [x] **Step 1: Configure text to track the scroll viewport width**

Set the text view to be vertically resizable but not horizontally resizable. Set its text container to use the available viewport width and enable `widthTracksTextView`:

```swift
textView.isVerticallyResizable = true
textView.isHorizontallyResizable = false
textView.textContainer?.containerSize = NSSize(
    width: CGFloat.greatestFiniteMagnitude,
    height: CGFloat.greatestFiniteMagnitude
)
textView.textContainer?.widthTracksTextView = true
textView.textContainer?.heightTracksTextView = false
```

- [x] **Step 2: Let Auto Layout and the text system size the document**

Remove `textView.sizeToFit()` from `render()`. Rendering must only replace the string, allowing the document view to respond to the clip view’s current dimensions.

- [x] **Step 3: Run the focused test and verify it passes**

Run:

```bash
swift test --filter GenotypeAlleleSequenceDetailViewTests/testSequenceReaderTracksResizedPaneWidthAndHeight
```

Expected: PASS.

### Task 3: Verify existing behavior and build a debug app

**Files:**

- Modify: `Sources/LungfishGenotypeUI/GenotypeAlleleSequenceDetailView.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeAlleleSequenceDetailViewTests.swift`

- [x] **Step 1: Run the detail-view and viewport suites**

Run:

```bash
swift test --filter 'GenotypeAlleleSequenceDetailViewTests|GenotypeResultViewportTests'
```

Expected: all selected tests pass.

- [x] **Step 2: Build the Debug app**

Run the repository’s Debug build command from the worktree and verify its application bundle identifies itself as Lungfish Debug.

- [x] **Step 3: Commit the isolated fix**

```bash
git add Sources/LungfishGenotypeUI/GenotypeAlleleSequenceDetailView.swift Tests/LungfishGenotypeUITests/GenotypeAlleleSequenceDetailViewTests.swift docs/superpowers
git commit -m "fix: resize MHC sequence detail reader"
```
