# Genotype Matrix Fixed Manual-Haplotype Header Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep sample names, read totals, and manual haplotype assignments fixed above genotype rows, with every unassigned em dash centered in its sample column.

**Architecture:** Extend `GenotypeMatrixHeaderView` with an optional lower manual-haplotype section and use the existing assignment snapshot as its value source. Both pinned and sample tables receive the same total native header height, so AppKit keeps the complete header fixed while vertically scrolling the table document; the sibling overlay/content-inset layout path is retired.

**Tech Stack:** Swift 6, AppKit `NSTableView`/`NSTableHeaderView`, XCTest, Swift Package Manager

---

### Task 1: Specify Fixed Header Geometry and Centered Values

**Files:**
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`

- [ ] **Step 1: Add read-only geometry hooks**

Add debug-only snapshots that expose the ordinary header section, manual section, table document row, sample-title/read bands, sample column rect, and manual text rect/alignment:

```swift
struct GenotypeMatrixFixedHeaderTestingSnapshot {
    let totalHeaderHeight: CGFloat
    let ordinaryHeaderRect: NSRect
    let manualSectionRect: NSRect
    let firstRowRectInMatrix: NSRect?
    let sampleTitleRect: NSRect?
    let sampleReadRect: NSRect?
}

struct GenotypeMatrixManualValueTestingSnapshot {
    let columnRect: NSRect
    let textRect: NSRect
    let alignment: NSTextAlignment
    let value: String
}
```

Expose `testingFixedHeaderSnapshot(sample:)`, `testingManualValueSnapshot(sample:locus:)`, and `testingScrollSampleMatrixVertically(to:)` without mutating production state beyond the same scrolling path already used by viewport tests.

- [ ] **Step 2: Write failing fixed-header tests**

Add tests equivalent to:

```swift
func testManualHaplotypeRowsAreContainedByFixedHeaderAndPreserveSampleHeader() throws {
    let matrix = configuredEligibleMatrix()
    matrix.layoutSubtreeIfNeeded()
    let before = try XCTUnwrap(matrix.testingFixedHeaderSnapshot(sample: "AnimalA"))

    XCTAssertGreaterThan(before.ordinaryHeaderRect.height, 0)
    XCTAssertGreaterThan(before.manualSectionRect.height, 0)
    XCTAssertFalse(try XCTUnwrap(before.sampleTitleRect).intersects(before.manualSectionRect))
    XCTAssertFalse(try XCTUnwrap(before.sampleReadRect).intersects(before.manualSectionRect))
    XCTAssertFalse(try XCTUnwrap(before.firstRowRectInMatrix).intersects(before.manualSectionRect))

    matrix.testingScrollSampleMatrixVertically(to: 240)
    matrix.layoutSubtreeIfNeeded()
    let after = try XCTUnwrap(matrix.testingFixedHeaderSnapshot(sample: "AnimalA"))
    XCTAssertEqual(after.ordinaryHeaderRect, before.ordinaryHeaderRect)
    XCTAssertEqual(after.manualSectionRect, before.manualSectionRect)
}

func testManualHaplotypeEmDashIsCenteredInSampleColumn() throws {
    let matrix = configuredEligibleMatrix()
    let snapshot = try XCTUnwrap(
        matrix.testingManualValueSnapshot(sample: "AnimalA", locus: "MHC-A")
    )
    XCTAssertEqual(snapshot.value, "—")
    XCTAssertEqual(snapshot.alignment, .center)
    XCTAssertEqual(snapshot.textRect.midX, snapshot.columnRect.midX, accuracy: 0.5)
}
```

Also assert collapsed and expanded total header heights and verify an ineligible haplotyped analysis has an empty manual section.

- [ ] **Step 3: Run tests to verify the current overlay fails**

Run:

```bash
swift test --filter 'GenotypeResultViewportTests/(testManualHaplotypeRowsAreContainedByFixedHeaderAndPreserveSampleHeader|testManualHaplotypeEmDashIsCenteredInSampleColumn|testManualHaplotypeFixedHeaderCollapsedExpandedAndIneligibleGeometry)'
```

Expected: at least the fixed containment test fails because the manual section is not part of `NSTableHeaderView`.

- [ ] **Step 4: Commit the red tests**

```bash
git add Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift
git commit -m "test: cover fixed manual haplotype matrix header"
```

### Task 2: Render Manual Assignments Inside Native Table Headers

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift`

- [ ] **Step 1: Add reusable header-section layout**

Define a value-semantic layout helper in `GenotypeManualHaplotypeAssignmentBand.swift`:

```swift
struct GenotypeManualHaplotypeHeaderLayout {
    let ordinaryHeaderHeight: CGFloat
    let rowHeight: CGFloat
    let isEligible: Bool
    let isExpanded: Bool

    var manualRowCount: Int { isEligible ? (isExpanded ? 8 : 1) : 0 }
    var manualSectionHeight: CGFloat { rowHeight * CGFloat(manualRowCount) }
    var totalHeight: CGFloat { ordinaryHeaderHeight + manualSectionHeight }

    func manualSectionRect(in bounds: NSRect) -> NSRect {
        NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: manualSectionHeight
        )
    }
}
```

Use the view's flipped coordinate system consistently and add focused unit assertions if AppKit's table header coordinate direction requires the ordinary and manual rects to be swapped.

- [ ] **Step 2: Extend `GenotypeMatrixHeaderView`**

Add header configuration closures/state for:

```swift
var ordinaryHeaderHeight: (() -> CGFloat)?
var manualHaplotypeLayout: (() -> GenotypeManualHaplotypeHeaderLayout)?
var manualHaplotypeSnapshot: (() -> GenotypeManualHaplotypeAssignmentBandSnapshot)?
var sampleNameForColumn: ((Int) -> String?)?
var drawsManualHaplotypeLocusLabels = false
var onManualHaplotypeDisclosureChanged: ((Bool) -> Void)?
```

Limit existing `drawHeaderCell`, chiclet positioning, mouse handling, and selector-button frames to the ordinary header rect. Draw the disclosure/locus labels in the pinned header and assignment values in the sample header. Create each assignment text rect by symmetrically insetting its column rect and set `NSMutableParagraphStyle.alignment = .center`.

- [ ] **Step 3: Replace overlay/inset layout**

In `GenotypeComparisonMatrixView`:

```swift
private func applyManualHaplotypeBandPresentation() {
    let layout = currentManualHaplotypeHeaderLayout
    pinnedScrollView.contentInsets.top = 0
    scrollView.contentInsets.top = 0
    pinnedScrollView.automaticallyAdjustsContentInsets = true
    scrollView.automaticallyAdjustsContentInsets = true
    pinnedTableView.headerView?.frame.size.height = layout.totalHeight
    tableView.headerView?.frame.size.height = layout.totalHeight
    setHeaderViewsNeedDisplay()
}
```

Remove `manualHaplotypePinnedBand` and `manualHaplotypeSampleBand` from the sibling view hierarchy and stop positioning them in `layout()`. Route disclosure changes, snapshots, tooltips, selective redraw, horizontal geometry, and debug hooks through the two `GenotypeMatrixHeaderView` instances.

- [ ] **Step 4: Run the new tests**

Run the Task 1 filter again.

Expected: all three fixed-header tests pass.

- [ ] **Step 5: Run all manual-haplotype viewport and accessibility tests**

Run:

```bash
swift test --filter GenotypeResultViewportTests.testManualHaplotype
swift test --filter GenotypeManualHaplotypeAccessibilityTests
```

Expected: all selected tests pass, including scroll/reorder/resize alignment, tooltips, typography, disclosure, and ineligible analysis behavior.

- [ ] **Step 6: Commit the implementation**

```bash
git add Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift
git commit -m "fix: keep manual haplotypes in matrix header"
```

### Task 3: Regression Verification and Debug Build

**Files:**
- Modify only if a regression is found:
  - `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
  - `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift`
  - `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Run the complete viewport suite**

Run:

```bash
swift test --filter GenotypeResultViewportTests
```

Expected: all viewport tests pass.

- [ ] **Step 2: Run the package suite**

Run:

```bash
swift test
```

Expected: all package tests pass with no new failures.

- [ ] **Step 3: Build the debug app**

Run:

```bash
./scripts/build-app.sh --configuration debug --log-dir build/logs
test -x build/Debug/Lungfish.app/Contents/MacOS/Lungfish
/usr/bin/codesign --verify --deep --strict --verbose=4 build/Debug/Lungfish.app
```

Expected: a launchable, deeply code-signed `build/Debug/Lungfish.app` is produced with bundle identifier `com.lungfish.browser.debug`.

- [ ] **Step 4: Quit older debug/release instances and launch the new app**

Resolve all processes matching `^.*/Lungfish.app/Contents/MacOS/Lungfish$`, inspect their executable paths, send `TERM` only to those Lungfish processes, and run:

```bash
open -na build/Debug/Lungfish.app
```

Expected: exactly one new debug instance is running.

- [ ] **Step 5: Perform visual smoke checks**

Open a genotype-only bundle and verify:

1. sample names and read totals are visible;
2. manual haplotype rows remain fixed during vertical scrolling;
3. genotype rows never paint over the header;
4. unassigned em dashes are centered;
5. horizontal scrolling and column resizing preserve alignment;
6. a haplotyped analysis retains its unchanged viewport.

- [ ] **Step 6: Commit any verified follow-up corrections**

```bash
git add Sources/LungfishGenotypeUI Tests/LungfishGenotypeUITests
git commit -m "test: verify fixed genotype haplotype header"
```

Skip this commit if verification required no further source changes.
