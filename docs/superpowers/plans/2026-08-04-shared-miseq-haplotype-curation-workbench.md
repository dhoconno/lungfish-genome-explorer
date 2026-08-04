# Shared miSeq Haplotype Curation Workbench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the haplotyped miSeq Genotype Matrix lower pane selection-driven and render the same shared haplotype assignment card used by full-length genotype-only review.

**Architecture:** A controller policy exposes the detail scroll view for every raw genotype matrix that supports sample curation. A reusable SwiftUI assignment card receives workflow-neutral row presentations and callbacks, while the existing manual and effective editor models remain separate persistence adapters.

**Tech Stack:** Swift 6, AppKit, SwiftUI, Combine, XCTest, Lungfish annotation audit store.

---

## File Map

- Modify `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift` to exercise native column selection and real pane visibility.
- Modify `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift` to apply one sample-curation visibility policy.
- Create `Sources/LungfishGenotypeUI/GenotypeHaplotypeAssignmentEditorCard.swift` for the shared assignment-card presentation.
- Modify `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift` to adapt the manual model to the shared card.
- Modify `Sources/LungfishGenotypeUI/GenotypeEffectiveHaplotypeEditor.swift` to adapt the effective miSeq model to the shared card.
- Modify editor and accessibility tests to prove both adapters use the shared view without changing persistence behavior.

### Task 1: Reproduce the Hidden Workbench Through the Real UI Path

**Files:**
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Add a native-selection regression test**

Configure the synchronized haplotyped-miSeq fixture, enter matrix mode, assert
`testingCohortSummaryIsHidden == true`, and select Sample-A with:

```swift
controller.testingComparisonMatrix.testingSelectMatrixTargets([
    .column(sample: "Sample-A"),
])
```

Assert the detail scroll view is visible, one workbench is mounted, and the
effective editor sample is `Sample-A`.

- [ ] **Step 2: Add an empty-selection assertion**

Clear matrix targets through the same callback and assert no workbench and no
arranged detail subviews remain while the cohort summary stays hidden.

- [ ] **Step 3: Run the focused test and confirm failure**

Run:

```bash
swift test --filter GenotypeResultViewportTests/testHaplotypedMiSeqMatrixSelectionControlsVisibleCurationPane
```

Expected: failure because the cohort summary is visible and the detail scroll
view is hidden.

- [ ] **Step 4: Commit the red test**

```bash
git add Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "test: reproduce hidden miSeq curation workbench"
```

### Task 2: Correct Matrix Detail Visibility

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Add one curation-matrix policy**

Add a private computed policy equivalent to:

```swift
private var rawMatrixUsesSampleCurationDetail: Bool {
    isGenotypeOnlyResult
        || presentationPolicy?.appliesToHaplotypedMiSeq == true
}
```

Use it in `applySummaryViewModeVisibility()` so a visible raw matrix hides the
cohort panel, shows the detail scroll view, and hides call evidence.

- [ ] **Step 2: Make no-selection content empty**

In `showEmptySelection()`, omit the instructional caption when the visible raw
matrix uses sample curation detail. Continue publishing a nil selection state.

- [ ] **Step 3: Run focused viewport tests**

Run:

```bash
swift test --filter GenotypeResultViewportTests/testHaplotypedMiSeqMatrixSelectionControlsVisibleCurationPane
swift test --filter GenotypeResultViewportTests/testGenotypeOnly
```

Expected: the new test and existing genotype-only tests pass.

- [ ] **Step 4: Commit the visibility fix**

```bash
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "fix: show miSeq haplotype workbench for column selection"
```

### Task 3: Extract the Shared Assignment Card

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeHaplotypeAssignmentEditorCard.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeEffectiveHaplotypeEditor.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeEditorTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeEffectiveHaplotypeEditorTests.swift`

- [ ] **Step 1: Add failing shared-card identity tests**

Expose an internal testing identifier on the shared card and assert both
hosting views contain `shared-haplotype-assignment-card`. Retain assertions for
manual `MHC-DRB` and effective `MHC-DR` field identifiers.

- [ ] **Step 2: Run the focused editor tests and confirm failure**

Run:

```bash
swift test --filter GenotypeManualHaplotypeEditorTests
swift test --filter GenotypeEffectiveHaplotypeEditorTests
```

Expected: failure because no shared card exists.

- [ ] **Step 3: Define workflow-neutral presentation values**

Create shared row and slot values carrying the locus label, H1/H2 labels,
completion suggestions, color token, validation text, and accessibility
identifiers. Create a shared card with callbacks for Save, retry, reload, edit,
clear, and the optional Compare & Copy action.

- [ ] **Step 4: Convert both editors to thin adapters**

Map `GenotypeManualHaplotypeEditorModel.rows` and
`GenotypeEffectiveHaplotypeEditorModel.rows` into shared rows. Keep manual
orphan warnings and Compare & Copy as optional shared-card content. Do not
change either model's save callback or storage types.

- [ ] **Step 5: Run editor, accessibility, and viewport tests**

Run:

```bash
swift test --filter GenotypeManualHaplotypeEditorTests
swift test --filter GenotypeEffectiveHaplotypeEditorTests
swift test --filter GenotypeManualHaplotypeAccessibilityTests
swift test --filter GenotypeResultViewportTests/testHaplotypedMiSeq
```

Expected: all tests pass.

- [ ] **Step 6: Commit the shared card**

```bash
git add Sources/LungfishGenotypeUI/GenotypeHaplotypeAssignmentEditorCard.swift Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift Sources/LungfishGenotypeUI/GenotypeEffectiveHaplotypeEditor.swift Tests/LungfishGenotypeUITests
git commit -m "refactor: share genotype haplotype assignment card"
```

### Task 4: Full Verification and Debug Build

**Files:**
- Modify only if a regression requires a focused correction.

- [ ] **Step 1: Run the complete genotype UI suite**

```bash
swift test --filter LungfishGenotypeUITests
```

Expected: zero failures.

- [ ] **Step 2: Build the Debug app**

```bash
xcodebuild -project Lungfish.xcodeproj -scheme Lungfish -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **` and `build/Build/Products/Debug/Lungfish.app`.

- [ ] **Step 3: Check the branch**

```bash
git diff --check
git status --short
```

Expected: no whitespace errors and no unintended files.

