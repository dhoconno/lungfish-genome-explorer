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

    func testAppDelegateMenuValidationAndDispatchUseResolvedEmbeddedViewer() throws {
        let windowController = MainWindowController()
        defer { windowController.close() }
        let split = windowController.mainSplitViewController!
        _ = split.view
        let root = split.viewerController!
        root.referenceFrame = frame(start: 50, end: 150)

        let embedded = ReferenceBundleViewportController()
        _ = embedded.view
        let target = embedded.activeSequenceViewerController
        target.referenceFrame = frame(start: 2_000, end: 6_000)
        root.referenceBundleViewportController = embedded

        let delegate = AppDelegate()
        delegate.mainWindowController = windowController
        windowController.window?.makeKeyAndOrderFront(nil)

        for action in [
            #selector(AppDelegate.zoomIn(_:)),
            #selector(AppDelegate.zoomOut(_:)),
            #selector(AppDelegate.zoomToFit(_:)),
            #selector(AppDelegate.zoomReset(_:)),
            #selector(AppDelegate.goToPosition(_:)),
        ] {
            let item = NSMenuItem(title: "Test", action: action, keyEquivalent: "")
            XCTAssertTrue(delegate.validateMenuItem(item), NSStringFromSelector(action))
        }

        delegate.zoomToFit(split.view)
        XCTAssertEqual(target.referenceFrame?.start, 0)
        XCTAssertEqual(target.referenceFrame?.end, 20_000)

        target.referenceFrame = frame(start: 2_000, end: 6_000)
        windowController.zoomIn(nil)
        XCTAssertEqual(target.referenceFrame?.start, 3_000)
        XCTAssertEqual(target.referenceFrame?.end, 5_000)

        target.referenceFrame = frame(start: 3_000, end: 5_000)
        delegate.zoomOut(split.view)
        XCTAssertEqual(target.referenceFrame?.start, 2_000)
        XCTAssertEqual(target.referenceFrame?.end, 6_000)

        target.referenceFrame = frame(start: 4_000, end: 8_000)
        delegate.zoomReset(split.view)
        XCTAssertEqual(target.referenceFrame?.start, 1_000)
        XCTAssertEqual(target.referenceFrame?.end, 11_000)

        delegate.goToPositionInputForTesting = "chr1:120-180"
        delegate.goToPosition(split.view)
        XCTAssertEqual(target.referenceFrame?.start, 119)
        XCTAssertEqual(target.referenceFrame?.end, 180)

        target.viewerView.testSetUserSelectionRange(11..<19)
        target.referenceFrame = frame(start: 119, end: 180)
        let menu = target.viewerView.testBuildContextMenu(for: .sequence, genomicPosition: 12)
        let zoomItem = try XCTUnwrap(menu.items.first { $0.title == "Zoom to Selected Region" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(zoomItem.action), to: zoomItem.target, from: zoomItem))
        XCTAssertEqual(target.referenceFrame?.start, 11)
        XCTAssertEqual(target.referenceFrame?.end, 19)

        XCTAssertEqual(root.referenceFrame?.start, 50)
        XCTAssertEqual(root.referenceFrame?.end, 150)
    }

    func testAppDelegateAndMainWindowDispatchUseAvailableDetachedViewerAheadOfEmbeddedViewer() throws {
        let windowController = MainWindowController()
        defer { windowController.close() }
        let split = windowController.mainSplitViewController!
        _ = split.view
        let root = split.viewerController!
        root.referenceFrame = frame(start: 50, end: 150)

        let embedded = ReferenceBundleViewportController()
        _ = embedded.view
        embedded.activeSequenceViewerController.referenceFrame = frame(start: 200, end: 400)
        root.referenceBundleViewportController = embedded

        let detached = ClassifierAlignmentEvidenceViewportController()
        _ = detached.viewController.view
        detached.viewer.referenceFrame = frame(start: 2_000, end: 6_000)
        detached.testSetAvailability(.available(reference: .notProvided, reason: nil))
        split.classifierAlignmentEvidenceViewport = detached

        let delegate = AppDelegate()
        delegate.mainWindowController = windowController
        windowController.window?.makeKeyAndOrderFront(nil)

        for action in [
            #selector(AppDelegate.zoomIn(_:)),
            #selector(AppDelegate.zoomOut(_:)),
            #selector(AppDelegate.zoomToFit(_:)),
            #selector(AppDelegate.zoomReset(_:)),
            #selector(AppDelegate.goToPosition(_:)),
        ] {
            let item = NSMenuItem(title: "Test", action: action, keyEquivalent: "")
            XCTAssertTrue(delegate.validateMenuItem(item), NSStringFromSelector(action))
        }

        windowController.zoomToFit(nil)
        XCTAssertEqual(detached.viewer.referenceFrame?.start, 0)
        XCTAssertEqual(detached.viewer.referenceFrame?.end, 20_000)

        detached.viewer.referenceFrame = frame(start: 2_000, end: 6_000)
        windowController.zoomIn(nil)
        XCTAssertEqual(detached.viewer.referenceFrame?.start, 3_000)
        XCTAssertEqual(detached.viewer.referenceFrame?.end, 5_000)

        detached.viewer.referenceFrame = frame(start: 3_000, end: 5_000)
        windowController.zoomOut(nil)
        XCTAssertEqual(detached.viewer.referenceFrame?.start, 2_000)
        XCTAssertEqual(detached.viewer.referenceFrame?.end, 6_000)

        detached.viewer.referenceFrame = frame(start: 4_000, end: 8_000)
        delegate.zoomReset(split.view)
        XCTAssertEqual(detached.viewer.referenceFrame?.start, 1_000)
        XCTAssertEqual(detached.viewer.referenceFrame?.end, 11_000)

        delegate.goToPositionInputForTesting = "chr1:300-350"
        delegate.goToPosition(split.view)
        XCTAssertEqual(detached.viewer.referenceFrame?.start, 299)
        XCTAssertEqual(detached.viewer.referenceFrame?.end, 350)

        detached.viewer.viewerView.testSetUserSelectionRange(21..<29)
        detached.viewer.referenceFrame = frame(start: 299, end: 350)
        let menu = detached.viewer.viewerView.testBuildContextMenu(for: .sequence, genomicPosition: 24)
        let zoomItem = try XCTUnwrap(menu.items.first { $0.title == "Zoom to Selected Region" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(zoomItem.action), to: zoomItem.target, from: zoomItem))
        XCTAssertEqual(detached.viewer.referenceFrame?.start, 21)
        XCTAssertEqual(detached.viewer.referenceFrame?.end, 29)

        XCTAssertEqual(embedded.activeSequenceViewerController.referenceFrame?.start, 200)
        XCTAssertEqual(embedded.activeSequenceViewerController.referenceFrame?.end, 400)
        XCTAssertEqual(root.referenceFrame?.start, 50)
        XCTAssertEqual(root.referenceFrame?.end, 150)
    }

    private func frame(start: Double, end: Double) -> ReferenceFrame {
        ReferenceFrame(chromosome: "chr1", start: start, end: end, pixelWidth: 800, sequenceLength: 20_000)
    }
}
