# Mapping Annotation Drawer Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make mapped-read result viewers populate the Annotations drawer from the copied `.lungfishref` bundle, including existing drawer actions like zooming to an annotation.

**Architecture:** Keep embedded mapping viewers isolated from global inspector/toolbar notifications, but let them build their own local `AnnotationSearchIndex` immediately after `displayBundle(at:)` succeeds. Cover the regression with a focused `MappingResultViewController` test that exercises a real annotation SQLite database and verifies the embedded viewer gets a ready index.

**Tech Stack:** Swift 6.2, AppKit, XCTest, `LungfishApp`, `LungfishIO`, SQLite-backed `AnnotationSearchIndex`

---

### Task 1: Capture The Regression In Tests

**Files:**
- Modify: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`
- Reference: `Tests/LungfishAppTests/AnnotationTableDrawerVariantTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testEmbeddedViewerBuildsLocalAnnotationIndexForViewerBundle() throws {
    let bundleURL = try makeReferenceBundleWithAnnotationDatabase()
    let vc = MappingResultViewController()
    _ = vc.view

    vc.configureForTesting(result: makeMappingResult(viewerBundleURL: bundleURL))

    XCTAssertNotNil(vc.testEmbeddedAnnotationSearchIndex)
    XCTAssertFalse(vc.testEmbeddedAnnotationSearchIndex?.isBuilding ?? true)
    XCTAssertEqual(vc.testEmbeddedAnnotationSearchIndex?.entryCount, 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MappingResultViewControllerTests/testEmbeddedViewerBuildsLocalAnnotationIndexForViewerBundle`

Expected: FAIL because the embedded mapping viewer never receives a search index when global bundle notifications are suppressed.

### Task 2: Bootstrap The Embedded Viewer Index

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Mapping/MappingResultViewController.swift`
- Test: `Tests/LungfishAppTests/MappingResultViewControllerTests.swift`

- [ ] **Step 1: Add minimal embedded-viewer index bootstrap**

```swift
private func rebuildEmbeddedAnnotationIndexIfNeeded(for bundleURL: URL) {
    guard let bundle = embeddedViewerController.viewerView.currentReferenceBundle else {
        embeddedViewerController.annotationSearchIndex = nil
        return
    }

    let index = AnnotationSearchIndex()
    index.buildIndex(bundle: bundle, chromosomes: bundle.manifest.genome?.chromosomes ?? [])
    embeddedViewerController.annotationSearchIndex = index
}
```

- [ ] **Step 2: Call the bootstrap after `displayBundle(at:)` succeeds**

```swift
embeddedViewerController.clearViewport(statusMessage: "Loading mapping viewer...")
try embeddedViewerController.displayBundle(at: standardized)
rebuildEmbeddedAnnotationIndexIfNeeded(for: standardized)
loadedViewerBundleURL = standardized
```

- [ ] **Step 3: Run the focused test to verify it passes**

Run: `swift test --filter MappingResultViewControllerTests/testEmbeddedViewerBuildsLocalAnnotationIndexForViewerBundle`

Expected: PASS

- [ ] **Step 4: Run the surrounding mapping-viewer test file**

Run: `swift test --filter MappingResultViewControllerTests`

Expected: PASS
