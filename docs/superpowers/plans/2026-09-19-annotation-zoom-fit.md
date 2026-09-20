# Annotation Zoom Fit Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for the bounded implementation below. The user requested Astra diagnosis/planning, lower-cost implementation, and Sol Medium compilation. Do not start an additional build from the implementation agent.

**Goal:** Zoom to Annotation keeps the entire feature visible inside the real sequence canvas, including with the Inspector open and genotype labels visible.

**Architecture:** ReferenceFrame already maps its genomic start/end into a data rectangle that excludes the sample gutter and trailing padding. Remove navigation's second compensation for the same gutter and synchronize geometry from the actual SequenceViewerView before navigation. Retain current annotation padding and sequence-boundary behavior.

**Tech Stack:** Swift, AppKit, XCTest; LungfishApp.

**Spec:** User request in the current task, issue 3; screenshot N annotation at 28,273..<29,533 with displayed extent approximately 28,088..<29,474.

## Global Constraints

- Preserve all existing uncommitted changes; no reset, checkout, cleanup, commit, or unrelated refactor.
- No additional Inspector-width subtraction: the sequence canvas is already constrained to the center pane.
- No scientific output is created by this navigation fix; no new export/import/provenance path is involved.
- Compilation and tests run through the parent task's Sol Medium build owner, using the existing Xcode27/Swift6.4 configuration and test linker options. Implementation agent supplies test filters and waits for evidence.
- Coordinate shared-file edits with the parent: the multiselection work also touches ViewerViewController+AnnotationDrawer.swift, and hover work touches SequenceViewerView+Interaction.swift. Own only the zoom function in Interaction and the delayed recenter guard in AnnotationDrawer.

## Diagnosis and evidence

1. `ViewerViewController.swift`, ReferenceFrame at approximately line 4035: `dataPixelWidth = pixelWidth - leadingInset - trailingInset`; `screenPosition(for:)` already adds leadingInset, and scale divides by dataPixelWidth. The frame's `start` is therefore the genomic coordinate at the left edge of the **data** area.
2. `SequenceViewerView+Interaction.swift:1355`, `zoomToAnnotation`: computes length+10% padding, then subtracts `windowLength * navigationLeadingInsetPixels / pixelWidth` from the start while preserving windowLength. This shifts the end left and clips the feature. The screenshot's 1,386 bp span equals 1,260*1.1 exactly. Correct 28,210..<29,596 is shifted left about 122 bp to the reported 28,088..<29,474.
3. `ViewerViewController+BundleDisplay.swift:611`, `navigateToChromosomeAndPosition`: repeats this obsolete shift, imposes `max(800, actualWidth)`, and initially creates a ReferenceFrame with zero insets. The next layout updates it, causing inconsistent immediate geometry for narrow panes.
4. `ViewerViewController.viewDidLayout`, deferred redraw, and forceFullRedraw correctly read `viewerView.bounds.width` and set both insets. Resizing the Inspector already reaches this geometry path; no shell-layout fix is supported by the evidence.
5. Table context menu and Inspector dispatch `.zoomToAnnotationRequested`, which routes to `SequenceViewerView.zoomToAnnotation`. Mapping mode routes onward through `zoomToMappingAnnotation` and `MappingAnnotationActionCoordinator.zoomRegion`, then the shared cross-chromosome navigation function. Reference bundles embedded in ReferenceBundleViewportController use an embedded ViewerViewController and the same geometry model.
6. Annotation drawer single-selection schedules a 120 ms recenter callback. An immediate explicit zoom can be overwritten by this old callback. Add an identity/extents guard; do not introduce another delayed fit.
7. MSA has its own aligned-column zoom path in MultipleSequenceAlignmentViewController and no ReferenceFrame/gutter-shift path. Do not broaden this fix to MSA without a separate reproduction.

## Review Focus

- A pane narrower than 800 points must use its real width immediately.
- Genotype gutters must not shift requested genomic extents a second time.
- Opening/resizing Inspector after a fit changes screen scale while preserving the entire fitted interval.
- Features touching chromosome ends retain clamped valid coordinates and remain contained.
- Old annotation-selection recenter work must not override a newer explicit zoom/pan/navigation.

## Task 1: Fit annotation and explicit navigation into current canvas

**Files:**
- Modify `Sources/LungfishApp/Views/Viewer/SequenceViewerView+Interaction.swift`, only `zoomToAnnotation`.
- Modify `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift`, only `navigateToChromosomeAndPosition`.
- Create `Tests/LungfishAppTests/AnnotationZoomFitTests.swift`.

**Interfaces:** Keep existing public navigation and notification signatures. Do not add dependencies or change ReferenceFrame coordinate semantics.

- [ ] Add focused behavioral tests. Build the controller with `loadView()` as existing SequenceViewerContextMenuTests does; set canvas.frame explicitly, set `_cachedVariantDataStartX = 120` for a deterministic gutter, and install a ReferenceFrame. The core failing test is:

```swift
import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore

@MainActor
final class AnnotationZoomFitTests: XCTestCase {
    func testAnnotationFitKeepsWholeFeatureInsideNarrowCanvasWithGutter() throws {
        let controller = ViewerViewController()
        controller.loadView()
        let canvas = controller.viewerView!
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        canvas._cachedVariantDataStartX = 120
        controller.referenceFrame = ReferenceFrame(
            chromosome: "NC_045512.2", start: 0, end: 29_903,
            pixelWidth: 1_000, sequenceLength: 29_903)
        let annotation = SequenceAnnotation(
            type: .gene, name: "N", chromosome: "NC_045512.2",
            intervals: [AnnotationInterval(start: 28_273, end: 29_533)])

        canvas.zoomToAnnotation(annotation)

        let frame = try XCTUnwrap(controller.referenceFrame)
        XCTAssertEqual(frame.start, 28_210, accuracy: 0.001)
        XCTAssertEqual(frame.end, 29_596, accuracy: 0.001)
        XCTAssertEqual(frame.pixelWidth, 600)
        XCTAssertEqual(frame.leadingInset, 120)
        XCTAssertGreaterThanOrEqual(frame.screenPosition(for: 28_273), frame.leadingInset)
        XCTAssertLessThanOrEqual(frame.screenPosition(for: 29_533),
                                 canvas.bounds.width - frame.trailingInset)
    }
}
```

- [ ] Add test for `navigateToChromosomeAndPosition(chromosome: "chr2", chromosomeLength: 29_903, start: 28_210, end: 29_596)` with the same 600-point canvas/gutter. Assert exact requested extents, width600, insets120/12, both endpoints within the data rectangle, and frame.chromosome `chr2`. This exercises mapping's final navigation path without constructing a BAM fixture.
- [ ] Add an integration test that creates an N annotation, obtains its region from `MappingAnnotationActionCoordinator.zoomRegion`, navigates using that region, and asserts both annotation endpoints are visible. Preserve mapping's current 50bp/minimum and 2% padding policy.
- [ ] Add a table of direct annotation fit cases: 0..<20 on a 100bp chromosome, 80..<100, 0..<100, 50..<51; test with gutter0 and gutter120. Require 0<=frame.start, frame.end<=100, feature bounds contained, and positive scale. Exact start/end equality is only needed for the N reproduction.
- [ ] Add resize regression: fit N at width1000, then set canvas width600 and invoke `controller.viewDidLayout()`; assert the original genomic extents remain unchanged and both feature endpoints remain in the data rectangle.
- [ ] Have the Sol build owner run `AnnotationZoomFitTests` and confirm the new N fit/narrow navigation assertions fail before production changes.
- [ ] In direct annotation zoom, synchronize `frame.pixelWidth` with `max(1, Int(bounds.width))` when bounds.width>0, and set `frame.leadingInset = variantDataStartX` plus `frame.trailingInset = ReferenceFrame.defaultTrailingInset`. Remove maxPixelWidth/insetPixels/leadingInsetBP calculations. Start becomes:

```swift
var newStart = Double(annotation.start) - padding
var newEnd = newStart + windowLength
```

Keep current sequence-bound clamps and redraw/status behavior. If the view width is zero before layout, preserve a positive existing frame width; the next layout will synchronize it. Never create a hard minimum of 800 for a live positive width.

- [ ] In shared navigation, remove the whole leadingInsetPx/shiftBP branch. Choose `effectiveWidth = max(1, Int(viewerView.bounds.width))` for positive bounds; otherwise use `max(1, referenceFrame?.pixelWidth ?? 1)`. Keep clampedStart/clampedEnd as the requested genomic interval. After creating the ReferenceFrame, assign its leadingInset from `viewerView.variantDataStartX` and trailingInset from the constant before updating ruler/status. Log `referenceFrame.scale` rather than the obsolete total-width scale if keeping the scale log.
- [ ] Have the Sol build owner run the focused suite plus MappingAnnotationActionCoordinatorTests and SequenceViewerContextMenuTests. Inspect actual output before claiming pass.

## Task 2: Prevent delayed annotation recenter from replacing a newer zoom

**Files:**
- Modify `Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift`, only the 120ms delayed recenter block in `handleAnnotationDrawerSelection`.
- Extend `Tests/LungfishAppTests/AnnotationZoomFitTests.swift`.

**Interfaces:** No delegate changes. Root owns the multiselection delegate additions in this same file.

- [ ] Add async test: controller.loadView(), canvas frame600x300, initial chr1 frame length29_903; create `AnnotationSearchIndex.SearchResult(name: "N", chromosome: "chr1", start: 28_273, end: 29_533, trackId: "annotations", type: "gene", strand: "+")`; call `controller.annotationDrawer(AnnotationTableDrawerView(), didSelectAnnotation: result)`, then immediately `controller.viewerView.zoomToAnnotation` with the matching annotation. Capture the fitted start/end. Allow 200ms on MainActor via `try await Task.sleep(for: .milliseconds(200))`; assert start/end are still the captured fit. Add the same pending-callback case followed by explicit `navigateToChromosomeAndPosition` to chr2 and assert chromosome/extents are not restored to chr1.
- [ ] Have the Sol build owner confirm the delayed-callback test failure.
- [ ] Capture the frame identity and extents immediately after initial navigation, before scheduling the work:

```swift
let scheduledFrame = referenceFrame
let scheduledStart = scheduledFrame?.start
let scheduledEnd = scheduledFrame?.end
```

At the start of the closure, after obtaining self/frame, add:

```swift
guard frame === scheduledFrame,
      frame.start == scheduledStart,
      frame.end == scheduledEnd else { return }
```

This retains the old recovery only while its own original navigation is still current. Width/inset-only layout changes do not alter start/end and remain eligible. A direct zoom mutates extents; another navigation replaces frame identity.

- [ ] Have Sol rerun focused tests plus AnnotationTableDrawerVariantTests, VariantTrackVisibilityTests, and ViewerViewportNotificationTests after parent integration. Do not duplicate compilation in this agent.

## Final acceptance and handoff

- [ ] Parent reviews only the owned hunks and verifies uncommitted prior work is retained.
- [ ] In the Debug app, use the provided N annotation with Inspector open and sample gutter visible; choose Zoom to Annotation from Inspector and table/track context menu. Both ends must show with padding. Resize Inspector, repeat in a narrow viewer, and test a chromosome-end annotation.
- [ ] Parent's Sol owner produces the requested Debug build via the project's canonical debug packaging workflow after all four user issues are integrated. This plan alone does not claim a tested build or GUI reproduction.
