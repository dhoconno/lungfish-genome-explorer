import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class PrimerAnalysisRoutingTests: XCTestCase {
    func testScannerKeepsInvalidAnalysisOpaqueAndRecognizesItsType() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Example.lungfishprimeranalysis")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("opaque input".utf8).write(to: bundle.appendingPathComponent("source.txt"))

        let node = SidebarProjectScanner.scanTree(from: bundle)
        XCTAssertEqual(node.type, .primerAnalysisBundle)
        XCTAssertEqual(node.title, "Example")
        XCTAssertTrue(node.children.isEmpty)
        XCTAssertTrue(node.type.isBundle)
        XCTAssertTrue(node.type.bundleCapabilities.canOpen)
        XCTAssertFalse(node.type.bundleCapabilities.canExportSequences)
        XCTAssertFalse(node.type.bundleCapabilities.canShowInInspector)
        XCTAssertTrue(ProjectDeletionPlanner.projectObjectDirectoryExtensions.contains("lungfishprimeranalysis"))
    }

    func testDocumentTypeRecognizesDirectoryForNativeOpenRoute() throws {
        let type = try XCTUnwrap(DocumentType.detect(from: URL(fileURLWithPath: "/example.lungfishprimeranalysis")))
        XCTAssertEqual(type, .lungfishPrimerAnalysisBundle)
        XCTAssertTrue(type.isDirectoryFormat)
    }

    func testNativeViewerIsRemovedWhenClearingOrSwitchingContentMode() {
        let viewer = ViewerViewController()
        viewer.loadViewIfNeeded()
        viewer.displayPrimerAnalysisBundle(at: URL(fileURLWithPath: "/absent.lungfishprimeranalysis"))
        XCTAssertNotNil(viewer.primerAnalysisViewController)
        viewer.clearViewport()
        XCTAssertNil(viewer.primerAnalysisViewController)
        viewer.displayPrimerAnalysisBundle(at: URL(fileURLWithPath: "/absent.lungfishprimeranalysis"))
        viewer.contentMode = .empty
        XCTAssertNil(viewer.primerAnalysisViewController)
    }

    func testSidebarSelectionInstallsNativeViewer() {
        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayContent(for: SidebarItem(title: "Example", type: .primerAnalysisBundle,
                                             url: URL(fileURLWithPath: "/absent.lungfishprimeranalysis")))
        XCTAssertNotNil(split.viewerController.primerAnalysisViewController)
        split.viewerController.clearViewport()
    }

    func testGenericInspectorDoesNotDiscoverOrRepairAnalysisProvenance() {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        inspector.updateProvenanceTarget(url: URL(fileURLWithPath: "/example.lungfishprimeranalysis"),
                                         sidebarType: .primerAnalysisBundle, displayName: "Example")
        XCTAssertNil(inspector.viewModel.provenanceSectionViewModel.currentItem)
    }

    func testQuickLookReplacesNativeViewer() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("preview".utf8).write(to: file)
        let viewer = ViewerViewController()
        viewer.loadViewIfNeeded()
        viewer.displayPrimerAnalysisBundle(at: URL(fileURLWithPath: "/absent.lungfishprimeranalysis"))
        viewer.displayQuickLookPreview(url: file)
        XCTAssertNil(viewer.primerAnalysisViewController)
        viewer.clearViewport()
    }
}
