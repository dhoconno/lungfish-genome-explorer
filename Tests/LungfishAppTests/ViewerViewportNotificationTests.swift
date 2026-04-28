import XCTest
@testable import LungfishApp
import LungfishCore

@MainActor
final class ViewerViewportNotificationTests: XCTestCase {
    func testPrimaryViewerPublishesContentModeChanges() {
        let viewer = ViewerViewController()
        let notification = XCTNSNotificationExpectation(
            name: .viewportContentModeDidChange,
            object: viewer
        )

        viewer.contentMode = .mapping

        wait(for: [notification], timeout: 0.1)
    }

    func testEmbeddedViewerSuppressesContentModeChanges() {
        let viewer = ViewerViewController()
        viewer.publishesGlobalViewportNotifications = false

        let notification = XCTNSNotificationExpectation(
            name: .viewportContentModeDidChange,
            object: viewer
        )
        notification.isInverted = true

        viewer.contentMode = .mapping

        wait(for: [notification], timeout: 0.1)
    }

    func testEmbeddedViewerSuppressesBundleLoadNotifications() {
        let viewer = ViewerViewController()
        viewer.publishesGlobalViewportNotifications = false

        let notification = XCTNSNotificationExpectation(
            name: .bundleDidLoad,
            object: viewer
        )
        notification.isInverted = true

        viewer.publishBundleDidLoadNotification(
            userInfo: [NotificationUserInfoKey.bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishref")]
        )

        wait(for: [notification], timeout: 0.1)
    }

    func testMaskingDepthChangeDoesNotInvalidateConsensusCache() {
        let viewer = ViewerViewController()
        _ = viewer.view

        viewer.viewerView.cachedConsensusRegion = GenomicRegion(
            chromosome: "chr1",
            start: 100,
            end: 200
        )
        viewer.viewerView.consensusMinDepthSetting = 8
        viewer.viewerView.consensusMaskingMinDepthSetting = 8

        NotificationCenter.default.post(
            name: .readDisplaySettingsChanged,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.consensusMaskingMinDepth: 14
            ]
        )

        XCTAssertEqual(viewer.viewerView.consensusMaskingMinDepthSetting, 14)
        XCTAssertNotNil(viewer.viewerView.cachedConsensusRegion)
        XCTAssertEqual(viewer.viewerView.cachedConsensusRegion?.chromosome, "chr1")
        XCTAssertEqual(viewer.viewerView.cachedConsensusRegion?.start, 100)
        XCTAssertEqual(viewer.viewerView.cachedConsensusRegion?.end, 200)
        XCTAssertEqual(viewer.viewerView.consensusMinDepthSetting, 8)
    }

    func testVisibleAlignmentTrackSelectionInvalidatesAlignmentCaches() {
        let viewer = ViewerViewController()
        _ = viewer.view

        viewer.viewerView.cachedReadRegion = GenomicRegion(chromosome: "chr1", start: 10, end: 20)
        viewer.viewerView.cachedDepthRegion = GenomicRegion(chromosome: "chr1", start: 10, end: 20)
        viewer.viewerView.cachedConsensusRegion = GenomicRegion(chromosome: "chr1", start: 10, end: 20)

        NotificationCenter.default.post(
            name: .readDisplaySettingsChanged,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.visibleAlignmentTrackID: "track-derived"
            ]
        )

        XCTAssertEqual(viewer.viewerView.visibleAlignmentTrackIDSetting, "track-derived")
        XCTAssertNil(viewer.viewerView.cachedReadRegion)
        XCTAssertNil(viewer.viewerView.cachedDepthRegion)
        XCTAssertNil(viewer.viewerView.cachedConsensusRegion)
    }

    func testLayoutMarksViewerForImmediateRedrawBeforeDeferredRedrawFires() {
        let viewer = ViewerViewController()
        _ = viewer.view
        let invalidationCount = viewer.viewerView.testDisplayInvalidationCount

        viewer.view.setFrameSize(NSSize(width: 960, height: 540))
        viewer.viewDidLayout()

        XCTAssertEqual(viewer.viewerView.testDisplayInvalidationCount, invalidationCount + 1)
    }
}
