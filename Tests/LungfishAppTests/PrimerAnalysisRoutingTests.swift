import AppKit
import XCTest
import LungfishIO
import LungfishKit
@testable import LungfishApp
@testable import LungfishOperations

/// A surface that never opens, so the route's catch has a `SurfaceError` to put into words.
@MainActor
private final class RefusingSurface: ResultViewport {
    let controller = NSViewController()
    let kind: SurfaceKind

    init(kind: SurfaceKind) {
        self.kind = kind
    }

    var viewController: NSViewController { controller }
    var surfaceKind: SurfaceKind { kind }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        throw SurfaceError.notInstalled(kind)
    }
}

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
        // Primer analysis provenance belongs to its own read-only viewer, not the
        // generic Inspector (SidebarItem.swift's .primerAnalysisBundle case,
        // deliberately canShowInInspector: false).
        XCTAssertFalse(node.type.bundleCapabilities.canShowInInspector)
        XCTAssertTrue(ProjectDeletionPlanner.projectObjectDirectoryExtensions.contains("lungfishprimeranalysis"))
    }

    func testDocumentTypeRecognizesDirectoryForNativeOpenRoute() throws {
        let type = try XCTUnwrap(DocumentType.detect(from: URL(fileURLWithPath: "/example.lungfishprimeranalysis")))
        XCTAssertEqual(type, .lungfishPrimerAnalysisBundle)
        XCTAssertTrue(type.isDirectoryFormat)
    }

    // Opening a primer analysis widened a 1400pt project window to 1535pt:
    // the hosting view turned SwiftUI's ideal width into constraints that
    // outranked the window size. The viewport must not size the window.
    func testPrimerViewportsDoNotSizeTheWindow() throws {
        let viewer = ViewerViewController()
        viewer.loadViewIfNeeded()
        try viewer.displayPrimerAnalysisBundle(at: URL(fileURLWithPath: "/absent.lungfishprimeranalysis"))
        let analysis = try XCTUnwrap(viewer.primerAnalysisViewController as? PrimerAnalysisHostingController)
        XCTAssertTrue(analysis.sizingOptions.isEmpty)
        try viewer.displayPrimerOrder(at: URL(fileURLWithPath: "/absent.lungfishprimerorder"))
        let order = try XCTUnwrap(viewer.primerAnalysisViewController as? PrimerOrderHostingController)
        XCTAssertTrue(order.sizingOptions.isEmpty)
    }

    func testNativeViewerIsRemovedWhenClearingOrSwitchingContentMode() throws {
        let viewer = ViewerViewController()
        viewer.loadViewIfNeeded()
        try viewer.displayPrimerAnalysisBundle(at: URL(fileURLWithPath: "/absent.lungfishprimeranalysis"))
        XCTAssertNotNil(viewer.primerAnalysisViewController)
        viewer.clearViewport()
        XCTAssertNil(viewer.primerAnalysisViewController)
        try viewer.displayPrimerAnalysisBundle(at: URL(fileURLWithPath: "/absent.lungfishprimeranalysis"))
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

    /// HOST-UX SF2. A primer analysis that does not open says what happened and what to
    /// try. `localizedDescription` alone dropped the error's own next step.
    func testAPrimerAnalysisThatDoesNotOpenSaysWhatToTry() {
        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        let kind = SurfaceKind.bundle(.primerAnalysis)
        split.viewerController.surfaceHost.registry.register(kind) { RefusingSurface(kind: kind) }
        split.displayContent(for: SidebarItem(title: "Example", type: .primerAnalysisBundle,
                                             url: URL(fileURLWithPath: "/absent.lungfishprimeranalysis")))
        let words = split.viewerController.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("Unable to open the primer analysis."), words)
        XCTAssertTrue(words.contains("did not open"), words)
        XCTAssertTrue(words.contains("Select the item again."), words)
    }

    /// HOST-UX SF2, the primer order catch.
    func testAPrimerOrderThatDoesNotOpenSaysWhatToTry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "primer-order", isBatch: false), to: root)
        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        let kind = SurfaceKind.analysis(.primerOrder)
        split.viewerController.surfaceHost.registry.register(kind) { RefusingSurface(kind: kind) }
        split.displayContent(for: .init(title: "Reviewed primer order", type: .analysisResult, url: root))
        let words = split.viewerController.statusBar.positionLabel.stringValue
        XCTAssertTrue(words.contains("Unable to open the primer order."), words)
        XCTAssertTrue(words.contains("did not open"), words)
        XCTAssertTrue(words.contains("Select the item again."), words)
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
        let previews = RecordingFilePreviewRenderer.install(on: viewer)
        try viewer.displayPrimerAnalysisBundle(at: URL(fileURLWithPath: "/absent.lungfishprimeranalysis"))
        viewer.displayQuickLookPreview(url: file)
        XCTAssertNil(viewer.primerAnalysisViewController)
        XCTAssertEqual(previews.renderedURLs, [file])
        viewer.clearViewport()
    }
}
