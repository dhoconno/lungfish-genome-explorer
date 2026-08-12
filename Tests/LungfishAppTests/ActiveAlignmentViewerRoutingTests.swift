import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class ActiveAlignmentViewerRoutingTests: XCTestCase {
    func testActiveFullSequenceViewerResolvesDetachedThenEmbeddedThenRoot() {
        let split = MainSplitViewController()
        _ = split.view
        let root = split.viewerController!
        root.referenceFrame = frame(start: 5, end: 15)

        let embedded = ReferenceBundleViewportController()
        _ = embedded.view
        embedded.activeSequenceViewerController.referenceFrame = frame(start: 20, end: 30)
        root.referenceBundleViewportController = embedded

        XCTAssertTrue(split.activeFullSequenceViewerController === embedded.activeSequenceViewerController)

        let detached = ClassifierAlignmentEvidenceViewportController()
        _ = detached.viewController.view
        detached.viewer.referenceFrame = frame(start: 25, end: 35)
        detached.testSetAvailability(.available(reference: .notProvided, reason: nil))
        split.classifierAlignmentEvidenceViewport = detached

        XCTAssertTrue(split.activeFullSequenceViewerController === detached.viewer)

        detached.testSetAvailability(.unavailable("evidence changed"))

        XCTAssertTrue(split.activeFullSequenceViewerController === embedded.activeSequenceViewerController)

        root.referenceBundleViewportController = nil

        XCTAssertTrue(split.activeFullSequenceViewerController === root)
    }

    func testActiveFullSequenceViewerActionsMutateOnlyResolvedViewer() {
        let split = MainSplitViewController()
        _ = split.view
        let root = split.viewerController!
        root.referenceFrame = frame(start: 5, end: 15)

        let embedded = ReferenceBundleViewportController()
        _ = embedded.view
        embedded.activeSequenceViewerController.referenceFrame = frame(start: 20, end: 30)
        root.referenceBundleViewportController = embedded

        let target = try! XCTUnwrap(split.activeFullSequenceViewerController)
        target.zoomToFit()
        XCTAssertEqual(target.referenceFrame?.start, 0)
        XCTAssertEqual(target.referenceFrame?.end, 40)
        XCTAssertEqual(root.referenceFrame?.start, 5)
        XCTAssertEqual(root.referenceFrame?.end, 15)

        target.zoomIn()
        XCTAssertEqual(target.referenceFrame?.start, 10)
        XCTAssertEqual(target.referenceFrame?.end, 30)

        target.zoomOut()
        target.zoomReset()
        target.setExplicitAlignmentSelection(contig: "chr1", start: 11, end: 19)
        target.zoomToSelectedRegion()

        XCTAssertEqual(target.referenceFrame?.start, 11)
        XCTAssertEqual(target.referenceFrame?.end, 19)
        XCTAssertEqual(root.referenceFrame?.start, 5)
        XCTAssertEqual(root.referenceFrame?.end, 15)
    }

    private func frame(start: Double, end: Double) -> ReferenceFrame {
        ReferenceFrame(chromosome: "chr1", start: start, end: end, pixelWidth: 800, sequenceLength: 40)
    }
}
