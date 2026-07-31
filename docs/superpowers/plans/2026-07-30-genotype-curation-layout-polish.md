# Genotype Curation Layout Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the haplotype strip span the viewport and make the sample
curation cards fill, align, and reflow predictably.

**Architecture:** Preserve the existing split native matrix headers and
persistent hosted detail views. Change only presentation chrome and layout
constraints, with mounted geometry tests guarding against remounts, dead
space, clipping, and accessibility regressions.

**Tech Stack:** Swift 6, AppKit, SwiftUI, XCTest.

## Global Constraints

- Apply only to genotype-only views where the existing manual-haplotype UI is
  eligible.
- Do not change recipes, scientific projections, annotations, workbook
  publication, audit records, or provenance.
- Do not remount editor, comparison, or virtualized table views during reflow.
- Use semantic macOS colors and preserve 200% text-size behavior.

---

### Task 1: Full-width haplotype strip

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeViewportTests.swift`

**Interfaces:**
- Consumes: existing pinned/sample manual-haplotype band views.
- Produces: continuous semantic strip chrome and a compact disclosure control.

- [ ] **Step 1: Add failing mounted strip tests**

Mount an eligible matrix at a wide viewport and assert:

```swift
XCTAssertEqual(
    matrix.testingManualHaplotypeBandCoverageWidth,
    matrix.testingVisibleMatrixWidth,
    accuracy: 1
)
XCTAssertLessThan(
    matrix.testingManualHaplotypeDisclosureFrame.width,
    matrix.testingPinnedPaneWidth * 0.6
)
XCTAssertFalse(matrix.testingManualHaplotypeDisclosureIsBordered)
```

Also verify pinned and sample strip backgrounds/separators resolve to the same
semantic colors in light and dark appearances.

- [ ] **Step 2: Run the new tests and verify RED**

Run:

```bash
swift test --filter 'GenotypeManualHaplotypeAccessibilityTests|GenotypeManualHaplotypeViewportTests'
```

Expected: FAIL because the disclosure button still fills the pinned pane and
the strip does not expose continuous chrome/coverage.

- [ ] **Step 3: Implement compact continuous strip chrome**

Make the disclosure button borderless and size it from its intrinsic content
width plus a small inset. Draw matching `windowBackgroundColor` and
`separatorColor` chrome in both band views. Retain the existing icon, title,
expanded state, keyboard handling, tooltips, and row drawing.

- [ ] **Step 4: Verify strip tests**

Run the Task 1 filter again. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeManualHaplotypeAssignmentBand.swift \
  Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeViewportTests.swift
git commit -m "fix: extend manual haplotype strip"
```

### Task 2: Deterministic workbench width allocation

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeSampleComparisonPanelTests.swift`

**Interfaces:**
- Consumes: persistent assignment and evidence child views.
- Produces: explicit 62/38 wide layout and full-width stacked layout.

- [ ] **Step 1: Add failing real-host geometry tests**

Mount the real editor and trailing evidence hosts at 2,240 points and assert:

```swift
XCTAssertEqual(workbench.layoutMode, .sideBySide)
XCTAssertEqual(
    assignment.frame.width + evidence.frame.width + 16,
    workbench.bounds.width,
    accuracy: 1
)
XCTAssertEqual(
    evidence.frame.width / (workbench.bounds.width - 16),
    0.38,
    accuracy: 0.02
)
XCTAssertLessThan(evidence.frame.minX - assignment.frame.maxX, 17)
```

Verify child identities remain unchanged after wide-to-stacked-to-wide reflow.

- [ ] **Step 2: Run geometry tests and verify RED**

Run:

```bash
swift test --filter 'GenotypeResultViewportTests|GenotypeSampleComparisonPanelTests'
```

Expected: the real hosted evidence view hugs its intrinsic width and leaves a
large unused center gap.

- [ ] **Step 3: Add explicit wide constraints**

For side-by-side mode, constrain:

```swift
assignment.width = body.width * 0.62 - 8
evidence.width = body.width * 0.38 - 8
```

Use 520- and 360-point minimums. Raise the side-by-side entry/exit thresholds
so these minimums are satisfiable, including the existing typography-scale
adjustment. Keep stacked equal-width constraints required.

- [ ] **Step 4: Verify geometry and identity**

Run the Task 2 filter again. Expected: PASS with no center gap, no compressed
evidence pane, and stable child identities.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift \
  Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift \
  Tests/LungfishGenotypeUITests/GenotypeSampleComparisonPanelTests.swift
git commit -m "fix: allocate sample curation columns"
```

### Task 3: Matching top-aligned cards

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeSupportedAllelesPanel.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeSampleComparisonPanel.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeSupportedAllelesPanelTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeSampleComparisonPanelTests.swift`

**Interfaces:**
- Consumes: Task 2 workbench allocation.
- Produces: matching evidence/comparison card chrome and aligned top insets.

- [ ] **Step 1: Add failing card geometry and appearance tests**

Mount assignment/evidence and assignment/comparison modes and assert the card
top coordinates match within one point. Verify Supported Alleles exposes the
same corner radius, semantic fill/stroke, internal padding, and outer vertical
inset as the assignment card.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter 'GenotypeSupportedAllelesPanelTests|GenotypeSampleComparisonPanelTests'
```

Expected: Supported Alleles has no card chrome and Compare & Copy lacks the
shared outer vertical inset.

- [ ] **Step 3: Apply shared card treatment**

Wrap Supported Alleles in the existing rounded semantic card treatment and add
the same four-point vertical outer inset to Supported Alleles and Compare &
Copy. Keep the table height bounded and width-filling.

- [ ] **Step 4: Run final affected verification**

Run:

```bash
swift test --filter 'GenotypeManualHaplotypeAccessibilityTests|GenotypeManualHaplotypeViewportTests|GenotypeSupportedAllelesPanelTests|GenotypeSampleComparisonPanelTests|GenotypeResultViewportTests'
```

Also run:

```bash
LUNGFISH_RELEASE_PERFORMANCE_TEST=1 \
swift test --filter GenotypeManualHaplotypePerformanceTests
```

Expected: all feature tests and strict performance checks pass, except the
already documented unrelated matrix horizontal-scroller baseline if it
remains reproducible.

- [ ] **Step 5: Build the updated debug app**

Run the repository debug build and verify its signature:

```bash
swift build --disable-sandbox --arch arm64
./scripts/build-app.sh --configuration debug --skip-build
codesign --verify --deep --strict build/Debug/Lungfish.app
```

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "fix: align sample curation cards"
```

