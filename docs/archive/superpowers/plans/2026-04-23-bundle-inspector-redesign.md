# Bundle Inspector Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the mapping/bundle Inspector into stable text-labeled tabs, separate reversible view controls from durable BAM workflows, and make filtered alignments separately accessible and explicitly revealed after creation.

**Architecture:** Keep the existing mapping document builder and BAM filtering service, but refactor the Inspector shell around four semantics: `Bundle`, `Selected Item`, `View`, and `Derived`. Reuse `ReadStyleSectionViewModel` as shared state, add explicit alignment-inventory and visible-alignment selection state, and route that selection into the viewer so derived BAMs can be isolated from the source BAM after creation.

**Tech Stack:** Swift, SwiftUI/AppKit, XCTest, LungfishApp Inspector/viewer controllers, LungfishWorkflow BAM filtering service

---

## File Structure

### Modified Files

- `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
  - Add new tab model, text-labeled picker, split tab content, visible-alignment synchronization, and post-filter reveal state.
- `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
  - Keep shared view-model state but decompose view responsibilities into selection/view/derived sections.
- `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
  - Add bundle-scoped alignment inventory and support visible-track switching from the bundle tab.
- `Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift`
  - Rename mapping sections, remove layout ownership, and include alignment inventory.
- `Sources/LungfishCore/Models/Notifications.swift`
  - Add visible-alignment track selection notification key.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
  - Apply visible-alignment selection and invalidate caches when it changes.
- `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
  - Filter reads/depth/consensus operations by the selected visible alignment track.
- `Tests/LungfishAppTests/InspectorMappingModeTests.swift`
  - Update expected tabs and inspector wiring assertions.
- `Tests/LungfishAppTests/InspectorAssemblyModeTests.swift`
  - Update label/source assertions for the renamed tab shell.
- `Tests/LungfishAppTests/WindowAppearanceTests.swift`
  - Assert the Inspector uses text-labeled tabs, not icon-only tabs.
- `Tests/LungfishAppTests/AlignmentFilterInspectorStateTests.swift`
  - Cover visible-alignment state preservation and filtered-alignment defaults.
- `Tests/LungfishAppTests/ReadStyleSectionViewModelTests.swift`
  - Cover visible-track state reset/preservation behavior.
- `Tests/LungfishAppTests/MappingDocumentSectionTests.swift`
  - Assert mapping section labels and removal of layout controls from the bundle tab.
- `Tests/LungfishAppTests/ViewerViewportNotificationTests.swift`
  - Cover viewer application of visible-alignment selection.

## Task 1: Lock The Shell Contract In Tests

**Files:**
- Modify: `Tests/LungfishAppTests/InspectorMappingModeTests.swift`
- Modify: `Tests/LungfishAppTests/InspectorAssemblyModeTests.swift`
- Modify: `Tests/LungfishAppTests/WindowAppearanceTests.swift`
- Modify: `Tests/LungfishAppTests/MappingDocumentSectionTests.swift`

- [ ] **Step 1: Write failing shell and labeling assertions**
- [ ] **Step 2: Run**

```bash
swift test --filter InspectorMappingModeTests
swift test --filter InspectorAssemblyModeTests
swift test --filter WindowAppearanceTests
swift test --filter MappingDocumentSectionTests
```

- [ ] **Step 3: Make the Inspector shell match the new labels and tab set**
- [ ] **Step 4: Re-run the same tests until green**

## Task 2: Add Bundle-Scoped Alignment Inventory And Visible-Track State

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- Modify: `Tests/LungfishAppTests/AlignmentFilterInspectorStateTests.swift`
- Modify: `Tests/LungfishAppTests/ReadStyleSectionViewModelTests.swift`

- [ ] **Step 1: Write failing view-model tests for visible-track preservation/reset**
- [ ] **Step 2: Run**

```bash
swift test --filter AlignmentFilterInspectorStateTests
swift test --filter ReadStyleSectionViewModelTests
```

- [ ] **Step 3: Add visible-track selection state and alignment inventory models**
- [ ] **Step 4: Render bundle-tab alignment inventory and track-switch affordances**
- [ ] **Step 5: Re-run the same tests until green**

## Task 3: Split Selection/View/Derived Content In The Inspector

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift`

- [ ] **Step 1: Add or refactor section views so `Selected Item`, `View`, and `Derived` are truly separate**
- [ ] **Step 2: Move mapping layout controls into `View`**
- [ ] **Step 3: Rename mapping overview section headers**
- [ ] **Step 4: Re-run the shell tests**

```bash
swift test --filter InspectorMappingModeTests
swift test --filter MappingDocumentSectionTests
```

## Task 4: Route Visible Alignment Selection Into The Viewer

**Files:**
- Modify: `Sources/LungfishCore/Models/Notifications.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
- Modify: `Tests/LungfishAppTests/ViewerViewportNotificationTests.swift`

- [ ] **Step 1: Write failing viewer tests for the new visible-alignment setting**
- [ ] **Step 2: Run**

```bash
swift test --filter ViewerViewportNotificationTests
```

- [ ] **Step 3: Add the notification key and apply it in the viewer controller**
- [ ] **Step 4: Filter reads/depth/consensus by the selected visible alignment track when present**
- [ ] **Step 5: Re-run the viewer tests until green**

## Task 5: Make Filtered Alignment Completion Explicit

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`
- Modify: `Tests/LungfishAppTests/InspectorFilteredAlignmentWorkflowTests.swift`

- [ ] **Step 1: Add failing tests around post-create reveal/select state where practical**
- [ ] **Step 2: Run**

```bash
swift test --filter InspectorFilteredAlignmentWorkflowTests
```

- [ ] **Step 3: On successful BAM filtering, mark the new track as recently derived, switch visible alignment selection to it, and expose explicit source-preservation messaging**
- [ ] **Step 4: Re-run the filtered-workflow tests until green**

## Task 6: Final Verification

**Files:**
- Verify only

- [ ] **Step 1: Run the focused test suite**

```bash
swift test --filter InspectorMappingModeTests
swift test --filter InspectorAssemblyModeTests
swift test --filter WindowAppearanceTests
swift test --filter AlignmentFilterInspectorStateTests
swift test --filter ReadStyleSectionViewModelTests
swift test --filter MappingDocumentSectionTests
swift test --filter ViewerViewportNotificationTests
swift test --filter InspectorFilteredAlignmentWorkflowTests
```

- [ ] **Step 2: If focused tests pass, run a broader regression slice**

```bash
swift test --filter MappingResultViewControllerTests
swift test --filter BAMVariantCallingDialogRoutingTests
swift test --filter SequenceViewerReadVisibilityTests
```

- [ ] **Step 3: Review `git diff` for label regressions and unintended Inspector mode changes**

## Notes

- Preserve internal type names such as `DocumentSection` where it keeps the patch smaller; the user-facing behavior is what matters.
- Do not claim the redesign is complete until the focused tests above pass with fresh output.
