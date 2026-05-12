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

    func testInspectorRejectsScopedMetadataImportRequestFromDifferentWindow() {
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.testingWindowStateScope = WindowStateScope()

        let accepted = inspector.testingHandleMetadataImportRequested(
            Notification(
                name: .metagenomicsMetadataImportRequested,
                object: nil,
                userInfo: [NotificationUserInfoKey.windowStateScope: WindowStateScope()]
            )
        )

        XCTAssertFalse(accepted)
    }

    func testInspectorStillAcceptsLegacyUnscopedMetadataImportRequest() {
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.testingWindowStateScope = WindowStateScope()

        let accepted = inspector.testingHandleMetadataImportRequested(
            Notification(name: .metagenomicsMetadataImportRequested, object: nil)
        )

        XCTAssertTrue(accepted)
    }

    func testFASTQAnalysisNavigationDoesNotUseGlobalActiveProjectOrMainWindow() throws {
        let inspectorURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/InspectorViewController.swift")
        let source = try String(contentsOf: inspectorURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "@objc private func handleFASTQDatasetLoaded"))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: "viewModel.selectedTab = .bundle"))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(
            body.contains("DocumentManager.shared.activeProject"),
            "FASTQ analysis manifest/navigation should resolve project state from the window scope, not the global active project"
        )
        XCTAssertFalse(
            body.contains("mainWindowController"),
            "FASTQ analysis navigation should target the scoped window rather than the most recent global main window"
        )
        XCTAssertTrue(
            body.contains("NotificationUserInfoKey.windowStateScope"),
            "Analysis navigation should carry window scope so only the originating sidebar responds"
        )
    }

    func testInspectorVariantSampleMetadataWritesUseWindowScopedWriteGuard() throws {
        let inspectorURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Inspector/InspectorViewController.swift")
        let source = try String(contentsOf: inspectorURL, encoding: .utf8)

        let sampleUpdateBody = try sourceBody(
            named: "private func updateSampleSection",
            endingBefore: "/// Presents an open panel for importing sample metadata from TSV/CSV.",
            in: source
        )
        XCTAssertTrue(sampleUpdateBody.contains("canWriteProjectOutputs"))
        XCTAssertTrue(sampleUpdateBody.contains("workflowName: \"Sample metadata edit\""))

        let importBody = try sourceBody(
            named: "private func presentMetadataImportPanel(variantDBURLs: [URL], bundle: ReferenceBundle)",
            endingBefore: "private func makeReadDisplaySettingsPayload",
            in: source
        )
        XCTAssertTrue(importBody.contains("canWriteProjectOutputs"))
        XCTAssertTrue(importBody.contains("workflowName: \"Sample metadata import\""))
    }

    private func sourceBody(named startNeedle: String, endingBefore endNeedle: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startNeedle))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: endNeedle))
        return String(source[start.lowerBound..<end.lowerBound])
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
