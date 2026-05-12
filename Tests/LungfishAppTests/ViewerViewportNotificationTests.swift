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

    func testViewerOriginatedContentModeNotificationIncludesWindowScope() {
        let viewer = ViewerViewController()
        let scope = WindowStateScope()
        viewer.windowStateScope = scope

        let capture = ViewerNotificationUserInfoCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .viewportContentModeDidChange,
            object: viewer,
            queue: nil
        ) { notification in
            capture.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        viewer.contentMode = .mapping

        XCTAssertEqual(capture.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope, scope)
    }

    func testViewerOriginatedBundleLoadNotificationIncludesWindowScope() {
        let viewer = ViewerViewController()
        let scope = WindowStateScope()
        viewer.windowStateScope = scope

        let capture = ViewerNotificationUserInfoCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .bundleDidLoad,
            object: viewer,
            queue: nil
        ) { notification in
            capture.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        viewer.publishBundleDidLoadNotification(
            userInfo: [NotificationUserInfoKey.bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishref")]
        )

        XCTAssertEqual(capture.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope, scope)
    }

    func testSequenceViewerAnnotationSelectionNotificationIncludesWindowScope() {
        let viewer = SequenceViewerView()
        let scope = WindowStateScope()
        viewer.windowStateScope = scope
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "GeneA",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 10, end: 40)]
        )

        let capture = ViewerNotificationUserInfoCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .annotationSelected,
            object: viewer,
            queue: nil
        ) { notification in
            capture.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        viewer.postAnnotationSelectedNotification(annotation)

        XCTAssertEqual(capture.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope, scope)
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

private final class ViewerNotificationUserInfoCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedUserInfo: [AnyHashable: Any]?

    var userInfo: [AnyHashable: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return capturedUserInfo
    }

    func record(_ notification: Notification) {
        lock.lock()
        capturedUserInfo = notification.userInfo
        lock.unlock()
    }
}
