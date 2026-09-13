import AppKit
import XCTest
import LungfishIO
@testable import LungfishApp

@MainActor
final class PrimerAnalysisRoutingTests: XCTestCase {
    func testOrderDirectoryRoutesToOrderViewportAndClearsItsInspector() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "primer-order", isBatch: false), to: root)
        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayContent(for: .init(title: "Reviewed primer order", type: .analysisResult, url: root))
        XCTAssertNotNil(split.viewerController.primerAnalysisViewController)
        XCTAssertTrue(split.inspectorController.viewModel.primerAnalysisDocument?.isOrder == true)
        XCTAssertEqual(split.inspectorController.viewModel.availableTabs, [.bundle, .files, .provenance])
        split.viewerController.clearViewport()
        XCTAssertNil(split.viewerController.primerAnalysisViewController)
        XCTAssertNil(split.inspectorController.viewModel.primerAnalysisDocument)
    }

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
        XCTAssertTrue(node.type.bundleCapabilities.canShowInInspector)
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
        XCTAssertEqual(split.inspectorController.viewModel.primerAnalysisDocument?.bundleURL,
                       URL(fileURLWithPath: "/absent.lungfishprimeranalysis"))
        XCTAssertEqual(split.inspectorController.viewModel.availableTabs, [.bundle, .files, .provenance])
        split.viewerController.clearViewport()
        XCTAssertNil(split.inspectorController.viewModel.primerAnalysisDocument)
        XCTAssertFalse(split.inspectorController.viewModel.availableTabs.contains(.files))
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
