import AppKit
import XCTest
import LungfishIO
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
