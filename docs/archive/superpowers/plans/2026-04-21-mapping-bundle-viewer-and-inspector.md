# Mapping Bundle Viewer and Inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans`. Steps use checkbox syntax for tracking.

**Goal:** Turn managed mapping results into a first-class mapping analysis surface with a classifier-style contig list, mapping-specific document inspector, layout controls, annotation-driven read extraction, and miniBAM-style zoom shortcut parity in the embedded BAM/reference viewer.

**Design input:** `/Users/dho/Documents/lungfish-genome-explorer/docs/superpowers/specs/2026-04-21-mapping-bundle-viewer-design.md`

**Review status:** Spec ratified by biologist, bioinformatics, and Swift/AppKit architecture reviewers. Residual implementation watchpoints:

- metric units must not be double-scaled
- provenance/result merge rules must stay deterministic
- shared annotation-action reuse must avoid a mapping-only fork
- toolbar behavior for `.mapping` must be reviewed explicitly during implementation
- annotation drawer persistence in mapping mode must be asserted in XCUI

**Architecture:** Introduce a dedicated `.mapping` viewport mode, persist rich mapping provenance in an optional sidecar, build a pure `MappingDocumentStateBuilder`, replace the mapping list with a reusable classifier-style table, refactor `MappingResultViewController` onto the shared split-layout foundation, and extend the embedded viewer with a mapping-aware annotation/extraction coordinator and miniBAM-style zoom shortcut handling.

**Tech Stack:** Swift, AppKit, SwiftUI, LungfishCore notifications, LungfishWorkflow mapping/extraction services, XCTest, deterministic XCUI, `swift test`, `xcodebuild`.

---

## File Structure

### Core Mapping State and Provenance

- Create: `Sources/LungfishWorkflow/Mapping/MappingProvenance.swift`
- Create: `Sources/LungfishApp/Views/Inspector/MappingDocumentStateBuilder.swift`
- Create: `Sources/LungfishApp/Views/Inspector/MappingInspectorSourceResolver.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingResult.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingRunRequest.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingRunRequest+SummaryParameters.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Test: `Tests/LungfishWorkflowTests/Mapping/MappingProvenanceTests.swift`
- Test: `Tests/LungfishAppTests/MappingDocumentStateBuilderTests.swift`

### Content Mode and Inspector Integration

- Create: `Sources/LungfishApp/Views/Results/Mapping/MappingPanelLayout.swift`
- Create: `Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift`
- Modify: `Sources/LungfishCore/Models/Notifications.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Test: `Tests/LungfishAppTests/InspectorMappingModeTests.swift`
- Test: `Tests/LungfishAppTests/MappingDocumentSectionTests.swift`

### Mapping Viewport Shell and Contig List

- Create: `Sources/LungfishApp/Views/Results/Mapping/MappingContigTableView.swift`
- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- Modify: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`
- Modify: `Tests/LungfishAppTests/MappingViewportRoutingTests.swift`

### Embedded Viewer Integration and Annotation Extraction

- Create: `Sources/LungfishApp/Views/Results/Mapping/MappingAnnotationActionCoordinator.swift`
- Create: `Sources/LungfishApp/Views/Shared/ZoomShortcutHandler.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift`
- Modify: `Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift`
- Test: `Tests/LungfishAppTests/MappingAnnotationActionCoordinatorTests.swift`
- Test: `Tests/LungfishAppTests/ViewerZoomShortcutHandlerTests.swift`
- Test: `Tests/LungfishWorkflowTests/Extraction/ReadExtractionServiceTests.swift`

### XCUI and End-to-End Validation

- Modify: `Tests/LungfishXCUITests/TestSupport/MappingRobot.swift`
- Modify: `Tests/LungfishXCUITests/MappingXCUITests.swift`
- Modify: `Tests/LungfishAppTests/AppUITestMappingBackendTests.swift`

This split gives clean ownership boundaries for provenance/state, inspector/mode plumbing, viewport shell/table work, and viewer/extraction work.

---

## Task 1: Add Mapping Provenance and Pure Document-State Builders

**Files:**

- Create: `Sources/LungfishWorkflow/Mapping/MappingProvenance.swift`
- Create: `Sources/LungfishApp/Views/Inspector/MappingDocumentStateBuilder.swift`
- Create: `Sources/LungfishApp/Views/Inspector/MappingInspectorSourceResolver.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/ManagedMappingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingResult.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingSummaryBuilder.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingRunRequest.swift`
- Modify: `Sources/LungfishWorkflow/Mapping/MappingRunRequest+SummaryParameters.swift`
- Modify: `Sources/LungfishApp/App/AppDelegate.swift`
- Tests: `Tests/LungfishWorkflowTests/Mapping/MappingProvenanceTests.swift`, `Tests/LungfishAppTests/MappingDocumentStateBuilderTests.swift`

- [ ] Write failing tests for:
  - provenance sidecar save/load round-trip
  - deterministic fallback when provenance is missing
  - metric-unit contract (`mappedReadPercent` and `coverageBreadth` are `0...100`, not fractions)
  - `MappingDocumentStateBuilder` source rows and artifact rows
  - original source reference bundle vs copied viewer bundle labeling

- [ ] Add `MappingProvenance` with:
  - exact argv arrays for mapper and `samtools` stages
  - mapper version
  - `samtools` version
  - resolved input/reference paths
  - original source reference bundle path
  - copied viewer bundle path
  - sample name
  - mode/preset ID and display label
  - `minimumMappingQuality`
  - `includeSecondary`
  - `includeSupplementary`
  - advanced arguments
  - runtime/timestamp
  - normalization flags derived from the run request

- [ ] Persist provenance from:
  - normal managed mapping runs
  - deterministic UI-test mapping backend

- [ ] Keep `MappingResult.load(from:)` as the required open path and layer provenance loading on top as optional.

- [ ] Add compatibility tests for:
  - legacy `mapping-result.json`-only analyses
  - stale/optional provenance fallback merge behavior

- [ ] Build `MappingDocumentStateBuilder` as a pure helper that merges:
  - `MappingResult`
  - optional `MappingProvenance`
  - project URL
  - source-path resolution

- [ ] Make degraded-mode builder output explicit when provenance or viewer bundle is missing.

- [ ] Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'MappingProvenanceTests|MappingDocumentStateBuilderTests'
```

Expected: pass.

---

## Task 2: Add `.mapping` Mode and Mapping Document Inspector

**Files:**

- Create: `Sources/LungfishApp/Views/Results/Mapping/MappingPanelLayout.swift`
- Create: `Sources/LungfishApp/Views/Inspector/Sections/MappingDocumentSection.swift`
- Modify: `Sources/LungfishCore/Models/Notifications.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainWindowController.swift`
- Modify: `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController.swift`
- Tests: `Tests/LungfishAppTests/InspectorMappingModeTests.swift`, `Tests/LungfishAppTests/MappingDocumentSectionTests.swift`

- [ ] Write failing tests for:
  - `.mapping` available-tab behavior
  - mapping document section selection over generic bundle content
  - layout preference persistence and notification
  - explicit degraded-mode inspector messaging
  - `.mapping` toolbar consumer behavior for the main window

- [ ] Introduce `.mapping` in `ViewportContentMode`.

- [ ] Audit every current content-mode consumer touched by:
  - toolbar item visibility/enabled state
  - inspector tabs
  - drawer visibility
  - viewer routing

- [ ] Add `MappingPanelLayout` with:
  - `detailLeading`
  - `listLeading`
  - `stacked`

- [ ] Extend `DocumentSectionViewModel` with mapping document state plus mapping layout preference.

- [ ] Add `MappingDocumentSection` with section order:
  1. header
  2. layout controls
  3. source data
  4. mapping context
  5. source artifacts

- [ ] Route `MainSplitViewController.displayMappingAnalysisFromSidebar(at:)` through `MappingDocumentStateBuilder` and update the inspector with mapping document state.

- [ ] Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'InspectorMappingModeTests|MappingDocumentSectionTests'
```

Expected: pass.

---

## Task 3: Rebuild the Mapping Viewport Shell on Shared Layout + Classifier Table Foundations

**Files:**

- Create: `Sources/LungfishApp/Views/Results/Mapping/MappingContigTableView.swift`
- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- Modify: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`
- Modify: `Tests/LungfishAppTests/MappingViewportRoutingTests.swift`

- [ ] Write failing tests for:
  - default sort is `Mapped Reads` descending, then contig name ascending
  - numeric and text per-column filters
  - classifier typography/row-height contract
  - layout swapping does not drop contig selection
  - degraded detail placeholder messaging when no viewer bundle is available
  - `Mean Identity` display stays in the approved unit contract

- [ ] Replace the hand-built `NSTableView` with `MappingContigTableView` using shared classifier table/filter infrastructure.

- [ ] Standardize visible columns:
  - `Contig`
  - `Length`
  - `Mapped Reads`
  - `% Mapped`
  - `Mean Depth`
  - `Coverage Breadth`
  - `Median MAPQ`
  - `Mean Identity`

- [ ] Ensure numeric filters use numeric operators and string filters use text operators.

- [ ] Refactor `MappingResultViewController` onto:
  - `TrackedDividerSplitView`
  - `TwoPaneTrackedSplitCoordinator`
  - `MappingPanelLayout`

- [ ] Preserve:
  - current contig selection
  - filter/sort state
  - viewer reload minimization when only layout changes

- [ ] Fix any existing metric-display bug revealed by the explicit unit contract.

- [ ] Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'MappingResultViewControllerTests|MappingViewportRoutingTests'
```

Expected: pass.

---

## Task 4: Add Shared Zoom Shortcut Handling and Mapping Annotation Actions

**Files:**

- Create: `Sources/LungfishApp/Views/Results/Mapping/MappingAnnotationActionCoordinator.swift`
- Create: `Sources/LungfishApp/Views/Shared/ZoomShortcutHandler.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/SequenceViewerView.swift`
- Modify: `Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift`
- Modify: `Sources/LungfishWorkflow/Extraction/ReadExtractionService.swift`
- Tests: `Tests/LungfishAppTests/MappingAnnotationActionCoordinatorTests.swift`, `Tests/LungfishAppTests/ViewerZoomShortcutHandlerTests.swift`, `Tests/LungfishWorkflowTests/Extraction/ReadExtractionServiceTests.swift`

- [ ] Write failing tests for:
  - `Command` `=`, `+`, `-`, `_`, `0` handling in embedded viewer context
  - context menu zoom actions on the mapping detail viewer
  - 0-based half-open annotation interval conversion to `samtools` regions
  - multi-interval annotation extraction producing canonicalized union region arguments without duplicate blocks
  - disabled actions when annotation bundle/chromosome is unavailable

- [ ] Extract common shortcut logic into `ZoomShortcutHandler` and wire it into:
  - full embedded viewer path
  - `MiniBAMViewController`

- [ ] Add mapping-host annotation action integration through a single shared path from the viewer/drawer, not a duplicated mapping-only menu fork.

- [ ] Build `MappingAnnotationActionCoordinator` to:
  - resolve the active `MappingResult`
  - convert annotation intervals to `samtools` regions
  - canonicalize discontinuous annotations into a union of non-overlapping blocks before extraction
  - apply padded bounding-region zoom for orientation
  - launch overlap-read extraction through `ReadExtractionService.extractByBAMRegion`
  - describe the extraction in `OperationCenter`

- [ ] Keep annotation extraction population aligned with the final normalized BAM; do not silently reintroduce filtered-out secondary/supplementary alignments.

- [ ] Run:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'MappingAnnotationActionCoordinatorTests|ViewerZoomShortcutHandlerTests|ReadExtractionServiceTests'
```

Expected: pass.

---

## Task 5: Expand Deterministic XCUI Coverage and Produce a Fresh Debug Build

**Files:**

- Modify: `Tests/LungfishXCUITests/TestSupport/MappingRobot.swift`
- Modify: `Tests/LungfishXCUITests/MappingXCUITests.swift`
- Modify: `Tests/LungfishAppTests/AppUITestMappingBackendTests.swift`

- [ ] Extend `MappingRobot` with helpers for:
  - toggling inspector layouts
  - manipulating mapping table filters and sort
  - sending `Command` zoom shortcuts to the embedded mapping viewer
  - opening/filtering the annotation drawer
  - triggering annotation zoom/extraction actions
  - asserting mapping document inspector sections

- [ ] Add deterministic XCUI tests for:
  - mapping result opens
  - layout controls swap left/right and stacked modes
  - table filter + sort behavior
  - zoom shortcuts in the embedded viewer
  - annotation drawer remains visible and functional in mapping mode
  - annotation zoom
  - annotation overlap-read extraction launch
  - degraded-mode placeholder messaging
  - mapping document inspector content

- [ ] Run focused verification:

```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer --filter 'MappingProvenanceTests|MappingDocumentStateBuilderTests|InspectorMappingModeTests|MappingDocumentSectionTests|MappingResultViewControllerTests|MappingViewportRoutingTests|MappingAnnotationActionCoordinatorTests|ViewerZoomShortcutHandlerTests|ReadExtractionServiceTests'
```

```bash
xcodebuild -project /Users/dho/Documents/lungfish-genome-explorer/Lungfish.xcodeproj -scheme Lungfish -configuration Debug -destination 'platform=macOS,arch=arm64' test -only-testing:LungfishXCUITests/MappingXCUITests
```

```bash
xcodebuild -project /Users/dho/Documents/lungfish-genome-explorer/Lungfish.xcodeproj -scheme Lungfish -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

Expected:

- tests pass
- a fresh Debug build is produced
- the app bundle is ready for manual review

---

## Suggested Subagent Split

These are the intended ownership boundaries for implementation.

### Worker 1: Provenance + Inspector Data

Owns:

- `Sources/LungfishWorkflow/Mapping/MappingProvenance.swift`
- `Sources/LungfishApp/Views/Inspector/MappingDocumentStateBuilder.swift`
- `Sources/LungfishApp/Views/Inspector/MappingInspectorSourceResolver.swift`
- `ManagedMappingPipeline` / `AppDelegate` provenance wiring
- related tests

### Worker 2: Mapping Mode + Inspector + Viewport Shell

Owns:

- `.mapping` mode plumbing
- `MappingPanelLayout`
- `MappingDocumentSection`
- `DocumentSection` / `InspectorViewController` / `MainSplitViewController` integration
- `MappingContigTableView`
- `MappingResultViewController`
- related tests

### Worker 3: Embedded Viewer Actions + XCUI

Owns:

- `ZoomShortcutHandler`
- viewer/annotation action wiring
- `MappingAnnotationActionCoordinator`
- extraction integration
- `MiniBAMViewController` shared shortcut migration
- XCUI robot/tests
- related tests

All workers must assume the worktree is shared and dirty. No worker may revert unrelated edits.

---

## Completion Criteria

- Mapping analyses open in `.mapping` mode.
- Mapping document state is built outside the inspector and loaded deterministically from result + optional provenance.
- The mapping contig list behaves like classifier tables, including typography, sorting, and per-column filters.
- Mapping layout controls live in the `Document` inspector and drive the shared split coordinator.
- The embedded viewer supports miniBAM-style zoom shortcuts in mapping context.
- Annotation rows can zoom the view and launch CLI-backed overlap-read extraction.
- Missing provenance or viewer bundle degrades gracefully with explicit messaging.
- Focused unit tests, app tests, and mapping XCUI tests pass.
- A fresh Debug build is produced for review.
