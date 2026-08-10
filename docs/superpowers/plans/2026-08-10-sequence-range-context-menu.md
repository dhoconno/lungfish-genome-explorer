# Sequence-Range Context Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the complete selected-range action set available from every `SequenceViewerView` context target while preserving target-specific commands and renaming the zoom command to **Zoom to Selected Region**.

**Architecture:** Keep target hit precedence and all existing selectors unchanged. Resolve one local context target, build its specialized `NSMenu` items, then append either one shared selected-range section or the existing general section before presenting one menu. The change remains local to `SequenceViewerView`; it does not change selection, extraction, scientific data, or provenance behavior.

**Tech Stack:** Swift 6, AppKit, XCTest, Swift Package Manager

## Global Constraints

- Preserve read → variant → annotation → alignment → sequence/background precedence.
- Preserve specialized actions, represented objects, enabled states, and closure-backed read menu targets.
- Preserve the current semantics of **Copy/Extract Visible Region**; only the selection zoom label changes.
- Do not add a generalized menu framework or alter `MiniBAMViewController`.
- Normalize separators so composed menus have no leading, trailing, or duplicate separators.
- Follow strict red-green-refactor: observe each focused regression fail before changing production code.

---

### Task 1: Compose target-specific and selected-range menus

**Files:**
- Create: `Tests/LungfishAppTests/SequenceViewerContextMenuTests.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`

- [ ] **Step 1: Add a failing sequence/background regression test**

Create a `@MainActor` XCTest fixture with a `SequenceViewerView`, set `testSetUserSelectionRange(100..<200)`, set an explicit context position, and request a non-presenting menu for a `.sequence` target. Assert the exact shared commands occur once:

```swift
[
    "Copy Visible Region",
    "Copy Visible Region as FASTA",
    "Extract Visible Region…",
    "Center View Here",
    "Zoom to Selected Region"
]
```

Also assert the zoom selector is `zoomToSelectionAction(_:)`, every shared item targets the view, and **Center View Here** carries the supplied genomic position.

Run:

```bash
swift test --filter SequenceViewerContextMenuTests
```

Expected: FAIL because the explicit context-target builder/test seam does not exist yet.

- [ ] **Step 2: Implement only the shared menu composer and test seam**

Add a local target model beside the interaction implementation:

```swift
enum SequenceViewerContextTarget {
    case read(AlignedRead)
    case variant(AnnotationSearchIndex.SearchResult)
    case annotation(SequenceAnnotation)
    case alignment([AlignmentFileMenuEntry])
    case sequence
}
```

Add `buildContextMenu(for:)`, a shared selected-range appender, and separator normalization. Reuse `addSelectionExtractionMenuItems(to:)`, `addCenterViewMenuItem(to:)`, and all existing selectors. Add a DEBUG seam in `SequenceViewerView.swift`:

```swift
func testBuildContextMenu(
    for target: SequenceViewerContextTarget,
    genomicPosition: Int
) -> NSMenu
```

The seam sets `contextMenuGenomicPosition` and returns the same menu used by production code.

Run the focused test and expect PASS.

- [ ] **Step 3: Add failing alignment and read composition tests**

For `.alignment([AlignmentFileMenuEntry(...)])`, assert **Show BAM in Finder** preserves `showAlignmentFileInFinderAction(_:)` and its URL payload, then assert all shared actions occur once. For `.read(read)`, assert the existing **Copy as FASTA (aligned orientation)** and **Extract Reads… (original reads)** items remain and all shared actions occur once.

Run the focused test and confirm the new assertions fail before production changes.

- [ ] **Step 4: Compose alignment and read actions**

Split alignment entry resolution from menu construction so a click inside the alignment track can resolve `.alignment([])` even when no file is revealable. Reuse `buildReadContextMenu(for:)` without replacing its closure-backed action targets. Append the shared section exactly once.

Run the focused test and expect PASS.

- [ ] **Step 5: Add failing variant and annotation composition tests**

Build representative `AnnotationSearchIndex.SearchResult` and `SequenceAnnotation` fixtures. Assert variant table/genotype commands and annotation commands retain their payloads. Assert annotation keeps **Zoom to Annotation** while both menus contain exactly one **Center View Here** and one **Zoom to Selected Region**.

Run the focused test and confirm the new assertions fail before production changes.

- [ ] **Step 6: Compose variant and annotation actions**

Refactor the existing presenting helpers into non-presenting specialized menu builders. Remove their duplicate shared center/selection-zoom items, retain annotation-specific zoom, and append the common selected-range section through `buildContextMenu(for:)`.

Run the focused test and expect PASS.

### Task 2: Route production right-clicks through one composed menu

**Files:**
- Modify: `Tests/LungfishAppTests/SequenceViewerContextMenuTests.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift`

- [ ] **Step 1: Add a failing no-selection composition test**

Clear the range and build a sequence/background menu. Assert it includes **Select All**, **Center View Here**, **Zoom to Fit**, and **Show in Inspector**, while omitting the visible-region copy/extraction actions and **Zoom to Selected Region**. Add a specialized-target no-selection assertion to prove its actions are retained ahead of the general section.

Run the focused test and confirm the new assertion fails before production changes.

- [ ] **Step 2: Refactor `rightMouseDown(with:)` to one target and one popup**

Keep current hit-test precedence and selection side effects. Resolve one `SequenceViewerContextTarget`, including `.alignment([])` when the point is in the alignment track but no file resolves, call `buildContextMenu(for:)`, and invoke `NSMenu.popUpContextMenu` once. When `selectionRange == nil`, append the existing general commands after any specialized commands.

Run:

```bash
swift test --filter SequenceViewerContextMenuTests
```

Expected: PASS.

- [ ] **Step 3: Run focused interaction regressions**

```bash
swift test --filter 'SequenceViewerContextMenuTests|ReadContextMenuTests|SequenceViewerReadVisibilityTests'
swift test --filter 'SequenceViewerReadHitTestIndexTests|SequenceViewerInteractionAsyncBundleReadTests|ViewportSelectionTests|SequenceMenuOperationTests'
```

Expected: PASS.

- [ ] **Step 4: Inspect the focused diff and commit**

Confirm the diff only affects context-menu composition, its DEBUG seam, and focused tests. Confirm no scientific transformation or extraction semantics changed.

```bash
git diff --check
git status --short
git add Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift Tests/LungfishAppTests/SequenceViewerContextMenuTests.swift
git commit -m "fix: unify sequence range context menus"
```

### Task 3: Verify and review

- [ ] **Step 1: Run the broader app test suite**

```bash
swift test --filter LungfishAppTests
```

Expected: PASS.

- [ ] **Step 2: Run independent code review**

Request review against the design and this plan. Resolve any correctness findings with another red-green cycle, then rerun the affected focused tests and the broader app suite.

- [ ] **Step 3: Confirm repository state**

```bash
git status --short --branch
git log -3 --oneline
```

Expected: clean feature branch containing the design, plan, and implementation commits.
