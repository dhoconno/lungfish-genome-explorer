import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class InspectorNotificationScopingTests: XCTestCase {
    func testInspectorIgnoresSelectionNotificationFromDifferentWindowScope() {
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.testingWindowStateScope = WindowStateScope()

        let otherScope = WindowStateScope()
        let item = SidebarItem(
            title: "Other Window",
            type: .sequence,
            url: URL(fileURLWithPath: "/tmp/other.fasta")
        )

        inspector.testingHandleSidebarSelectionChanged(
            Notification(
                name: .sidebarSelectionChanged,
                object: nil,
                userInfo: [
                    "item": item,
                    NotificationUserInfoKey.windowStateScope: otherScope,
                ]
            )
        )

        XCTAssertNil(inspector.viewModel.selectedItem)
    }

    func testInspectorStillAcceptsLegacyUnscopedSelectionNotification() {
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.testingWindowStateScope = WindowStateScope()

        let item = SidebarItem(
            title: "Legacy",
            type: .sequence,
            url: URL(fileURLWithPath: "/tmp/legacy.fasta")
        )

        inspector.testingHandleSidebarSelectionChanged(
            Notification(
                name: .sidebarSelectionChanged,
                object: nil,
                userInfo: ["item": item]
            )
        )

        XCTAssertEqual(inspector.viewModel.selectedItem, "Legacy")
    }

    func testInspectorIgnoresScopedBatchManifestCachedFromDifferentWindow() {
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.testingWindowStateScope = WindowStateScope()
        inspector.viewModel.documentSectionViewModel.batchManifestStatus = .building

        inspector.testingHandleBatchManifestCached(
            Notification(
                name: .batchManifestCached,
                object: nil,
                userInfo: [NotificationUserInfoKey.windowStateScope: WindowStateScope()]
            )
        )

        XCTAssertEqual(inspector.viewModel.documentSectionViewModel.batchManifestStatus, .building)
    }

    func testInspectorStillAcceptsLegacyUnscopedBatchManifestCached() {
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.testingWindowStateScope = WindowStateScope()
        inspector.viewModel.documentSectionViewModel.batchManifestStatus = .building

        inspector.testingHandleBatchManifestCached(
            Notification(name: .batchManifestCached, object: nil)
        )

        XCTAssertEqual(inspector.viewModel.documentSectionViewModel.batchManifestStatus, .cached)
    }

    func testInspectorOriginatedAnnotationSettingsNotificationIncludesWindowScope() {
        let inspector = InspectorViewController()
        _ = inspector.view
        let scope = WindowStateScope()
        inspector.testingWindowStateScope = scope

        let capture = InspectorNotificationUserInfoCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .annotationSettingsChanged,
            object: inspector,
            queue: nil
        ) { notification in
            capture.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        inspector.resetAllAppearanceSettings()

        XCTAssertEqual(capture.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope, scope)
    }
}

private final class InspectorNotificationUserInfoCapture: @unchecked Sendable {
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
