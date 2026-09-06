import AppKit
import XCTest
import LungfishIO
import LungfishCore
@testable import LungfishApp

@MainActor
final class MSAViewerChromeRoutingTests: XCTestCase {
    func testParentDrawerVisibilityReturnsAfterLeavingAlignment() async throws {
        let (directory, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: directory) }
        for wasOpen in [false, true] {
            let viewer = ViewerViewController()
            viewer.loadViewIfNeeded()
            viewer.toggleAnnotationDrawer()
            if !wasOpen { viewer.toggleAnnotationDrawer() }
            let drawer = try XCTUnwrap(viewer.annotationDrawerView)
            XCTAssertFalse(drawer.isHidden)

            try await viewer.displayMultipleSequenceAlignmentBundle(at: bundle.url)
            XCTAssertTrue(drawer.isHidden)
            viewer.toggleAnnotationDrawer()
            XCTAssertEqual(viewer.isAnnotationDrawerOpen, wasOpen)

            viewer.clearViewport()
            XCTAssertFalse(drawer.isHidden)
            XCTAssertEqual(viewer.isAnnotationDrawerOpen, wasOpen)
        }
    }

    func testReferenceContextActionSynchronizesInspectorAndIgnoresStaleViewer() async throws {
        let (directory, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: directory) }
        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayMultipleSequenceAlignmentBundleFromSidebar(at: bundle.url)
        for _ in 0..<200 where split.viewerController.multipleSequenceAlignmentViewController == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let controller = try XCTUnwrap(split.viewerController.multipleSequenceAlignmentViewController)
        let callback = try XCTUnwrap(controller.onReferenceRowChanged)
        callback(bundle.rows[1].id)
        let settings = split.inspectorController.viewModel.readStyleSectionViewModel
        XCTAssertEqual(settings.selectedMSAReferenceRowID, bundle.rows[1].id)
        XCTAssertEqual(settings.msaResidueIdentityDisplayMode, .dotsToReference)

        _ = split.beginDisplayRequest(identity: split.contentSelectionIdentity(url: directory, kind: "other"))
        callback(bundle.rows[0].id)
        XCTAssertEqual(settings.selectedMSAReferenceRowID, bundle.rows[1].id)
    }

    func testConsensusResetClearsInspectorReferenceAndIgnoresStaleViewer() async throws {
        let (directory, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: directory) }
        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayMultipleSequenceAlignmentBundleFromSidebar(at: bundle.url)
        for _ in 0..<200 where split.viewerController.multipleSequenceAlignmentViewController == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let controller = try XCTUnwrap(split.viewerController.multipleSequenceAlignmentViewController)
        let reset = try XCTUnwrap(controller.onConsensusComparisonRequested)
        let settings = split.inspectorController.viewModel.readStyleSectionViewModel
        controller.onReferenceRowChanged?(bundle.rows[1].id)
        reset()
        XCTAssertNil(settings.selectedMSAReferenceRowID)
        XCTAssertEqual(settings.msaResidueIdentityDisplayMode, .dotsToConsensus)

        controller.onReferenceRowChanged?(bundle.rows[0].id)
        _ = split.beginDisplayRequest(identity: split.contentSelectionIdentity(url: directory, kind: "other"))
        reset()
        XCTAssertEqual(settings.selectedMSAReferenceRowID, bundle.rows[0].id)
        XCTAssertEqual(settings.msaResidueIdentityDisplayMode, .dotsToReference)
    }

    func testInspectorComparisonChoiceKeepsReferenceAndDisplayModeConsistent() {
        let inspector = InspectorViewController()
        let settings = inspector.viewModel.readStyleSectionViewModel
        settings.msaReferenceRowOptions = [MSAReferenceRowOption(id: "row-2", name: "Second")]
        settings.selectMSAComparisonTarget(rowID: "row-2")
        XCTAssertEqual(settings.selectedMSAReferenceRowID, "row-2")
        XCTAssertEqual(settings.msaResidueIdentityDisplayMode, .dotsToReference)
        settings.selectMSAComparisonTarget(rowID: nil)
        XCTAssertNil(settings.selectedMSAReferenceRowID)
        XCTAssertEqual(settings.msaResidueIdentityDisplayMode, .dotsToConsensus)

        settings.msaConsensusHighGapThresholdPercent = 80
        let payload = inspector.makeReadDisplaySettingsPayload(from: settings)
        XCTAssertEqual(payload[NotificationUserInfoKey.msaReferenceRowID] as? String, "")
        XCTAssertEqual(payload[NotificationUserInfoKey.msaResidueIdentityDisplayMode] as? String, "dotsToConsensus")
    }

    private func makeBundle() throws -> (URL, MultipleSequenceAlignmentBundle) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("msa-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("alignment.fasta")
        try ">first\nACGT\n>second\nACCT\n".write(to: source, atomically: true, encoding: .utf8)
        let bundle = try MultipleSequenceAlignmentBundle.importAlignment(
            from: source, to: directory.appendingPathComponent("alignment.lungfishmsa")
        )
        return (directory, bundle)
    }
}
